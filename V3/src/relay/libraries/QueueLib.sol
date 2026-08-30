// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayState} from 'V3/interfaces/relay/IRelayState.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/**
 * @title  QueueLib
 * @notice Runs the Relay's deposit and withdraw queues: share pricing, backing and escrow
 *         bookkeeping, destination resolution, the VPM weight moves and the pair mints/burns on
 *         the satellites. Both queues are id-addressed with no size limit. Deposits: the keeper
 *         processes entries in order, and anyone can process one entry after `keeperWindow`.
 *         Withdrawals stay a strict FIFO that anyone can drain from the head.
 * @dev    EXTERNAL (linked) library, delegatecalled (EIP-170), so the pair mints and burns reach
 *         the satellites as the Relay. Each loop prices against a running supply counter instead
 *         of re-reading `totalSupply` per entry.
 */
library QueueLib {
  using DenseQueue for DenseQueue.Queue;
  using SafeCastLibrary for uint256;

  /// @notice Inputs of a deposit processing call: the Relay-side counters the pricing runs
  ///         against, and the bound of the path being taken.
  /// @param maxEntries Max deposit-queue entries to visit; only read by the ordered walk.
  /// @param keeperWindow Age (seconds) after which anyone can process an entry; only read by the
  ///        by-id path.
  /// @param totalBacking Current backing counter.
  /// @param totalSupply Current share supply.
  /// @param closed Whether the Relay is permanently closed; a closed Relay mints the principal alone.
  /// @param principalToken The PT satellite clone the shares mint on.
  /// @param yieldToken The YT satellite clone the shares mint on.
  struct DepositContext {
    uint256 maxEntries;
    uint256 keeperWindow;
    uint256 totalBacking;
    uint256 totalSupply;
    bool closed;
    IRelayToken principalToken;
    IRelayToken yieldToken;
  }

  /// @notice Outcome of a deposit processing call. The call performs the pair mints itself,
  ///         so no mint list crosses the library boundary.
  /// @param totalBacking The backing counter after it admits each processed entry's principal.
  /// @param count Number of entries the call processed.
  struct DepositResult {
    uint256 totalBacking;
    uint256 count;
  }

  /// @notice Inputs of a withdraw drain: the Relay-side counters the loop prices against.
  /// @param maxEntries Max exits to settle this call.
  /// @param totalSupply Current share supply (escrowed shares included; they burn after the call).
  /// @param totalBacking Current backing counter.
  /// @param freeWeight The free chain0 weight, read live from the Voter by the caller. Only this
  ///        weight can fund exits, so weight that is still coming back from deallocations can never
  ///        make the drain and the Voter disagree.
  /// @param pendingWithdrawalShares Total shares escrowed across queued, undrained withdrawals.
  /// @param relayTokenId The Relay's sAERO the weight leaves from.
  /// @param principalToken Principal satellite; each settled exit burns its escrowed shares on it.
  /// @param yieldToken Yield satellite; burns in step with the principal while the Relay is open.
  /// @param closed Whether the Relay is permanently closed, which turns off the yield-side burn so
  ///        the reward tail keeps its denominator; see `processWithdrawals`.
  struct WithdrawContext {
    uint256 maxEntries;
    uint256 totalSupply;
    uint256 totalBacking;
    uint256 freeWeight;
    uint256 pendingWithdrawalShares;
    uint256 relayTokenId;
    IRelayToken principalToken;
    IRelayToken yieldToken;
    bool closed;
  }

  /// @notice Outcome of a withdraw drain: the new counters and the settled count. The escrow
  ///         releases and the pair burns are performed inside the drain, so no burn list crosses
  ///         the library boundary.
  /// @param totalBacking The backing counter after debiting every settled exit.
  /// @param pendingWithdrawalShares The escrowed-share total after removing every settled exit.
  /// @param count Number of exits actually settled (the drain stops at the first unaffordable one).
  struct WithdrawResult {
    uint256 totalBacking;
    uint256 pendingWithdrawalShares;
    uint256 count;
  }

  /// @notice The source request plus the Relay-side counters used by `registerDeposit`'s guards.
  ///         Bundled into one struct so the external call stays within the stack limit of the
  ///         legacy (non-IR) compiler pipeline.
  /// @param tokenId Source sAERO whose weight enters the Relay.
  /// @param recipient Address the eventual shares mint to, named by the requester.
  /// @param amount Staking weight pulled from the source sAERO, before the VPM protocol fee is
  ///        subtracted.
  /// @param relayTokenId The Relay's sAERO the weight lands in.
  /// @param minDeposit Relay-level dust floor the net amount is checked against.
  /// @param totalSupply Current share supply, used by the zero-share guard.
  /// @param totalBacking Current backing counter, used by the zero-share guard.
  /// @param principalToken The PT satellite clone, banned as a share recipient.
  /// @param yieldToken The YT satellite clone, banned as a share recipient.
  /// @param closed Whether the Relay is permanently closed (a closed Relay takes no new weight).
  struct RegisterDepositContext {
    uint256 tokenId;
    address recipient;
    uint256 amount;
    uint256 relayTokenId;
    uint256 minDeposit;
    uint256 totalSupply;
    uint256 totalBacking;
    address principalToken;
    address yieldToken;
    bool closed;
  }

  /// @notice The exit request plus the Relay-side readings `registerExit`'s guards check. Bundled
  ///         into one struct so the external call stays within the stack limit of the legacy
  ///         (non-IR) compiler pipeline.
  /// @param principalToken The PT satellite clone, whose free balance must cover the escrow.
  /// @param yieldToken The YT satellite clone, whose free balance must cover the escrow while the
  ///        Relay is open. A closed Relay drops this side of the cover; see `registerExit`.
  /// @param shares Shares to escrow and burn at drain.
  /// @param destination sAERO the weight is sent to at settlement, or the mint sentinel for a fresh
  ///        one. Only the Relay sAERO is rejected; see `registerExit`.
  /// @param relayTokenId The Relay's own sAERO, banned as a destination.
  /// @param minWithdrawal Relay-level dust floor the exit is checked against.
  /// @param closed Whether the Relay is permanently closed, which opens the principal-only exit.
  struct RegisterExitContext {
    IRelayToken principalToken;
    IRelayToken yieldToken;
    uint256 shares;
    uint256 destination;
    uint256 relayTokenId;
    uint256 minWithdrawal;
    bool closed;
  }

  /// @notice The Voter's chain id for idle weight: free (unallocated) weight stays on this chain.
  uint256 internal constant _CHAIN0 = 0;

  /// @notice Withdraw destination sentinel: route the weight to a freshly minted sAERO. Mirrors VE's
  ///         `rebalanceUnderlying` mint convention (and RelayBase's public MINT_SENTINEL).
  uint256 internal constant _MINT_SENTINEL = type(uint256).max;

  /// @notice Register an async deposit: guard the request, move the requested weight into the
  ///         Relay sAERO through the VPM, guard the net amount and append it to the deposit queue.
  ///         The caller runs the tier check (allow list) and credits the returned net amount to the
  ///         pending-deposit counter.
  /// @param _list Deposit-queue bookkeeping (the Relay's storage).
  /// @param _deposits Deposit-queue entries by id.
  /// @param _votingEscrow VotingEscrow, read for the caller's authorization and the net-amount
  ///        delta around the VPM move.
  /// @param _vpm VoterPaymentsModule the weight moves in through (called as the Relay).
  /// @param _ctx The source request plus the Relay-side counters the guards price against.
  /// @return _netAmount Net weight the Relay sAERO actually received.
  /// @dev Delegatecalled, so `msg.sender` is the requester. The VPM fee is observed as a
  ///      staked-amount delta, so the dust and zero-share guards run on the net amount. The lock
  ///      rule is not checked here; VE enforces it inside `rebalanceUnderlying`.
  function registerDeposit(
    DenseQueue.Queue storage _list,
    mapping(uint256 id => IRelay.PendingDeposit deposit) storage _deposits,
    IVotingEscrow _votingEscrow,
    IVoterPaymentsModule _vpm,
    RegisterDepositContext memory _ctx
  ) external returns (uint256 _netAmount) {
    // A closed Relay only lets existing weight leave: no new weight enters.
    if (_ctx.closed) revert IRelay.RelayClosed();

    // The caller must be the owner or an approved operator/spender of the source sAERO.
    if (!_votingEscrow.isAuthorized(msg.sender, _ctx.tokenId)) revert IRelay.NotAuthorized();

    // Shares minted to address(0) are lost, and Maxi runs no allow-list that would catch it.
    if (_ctx.recipient == address(0)) revert IRelay.ZeroAddress();

    // A pair minted to a satellite or to the Relay itself could never move again. A mint crosses no
    // transfer gate, so the admission side names those recipients itself.
    if (_ctx.recipient == _ctx.principalToken || _ctx.recipient == _ctx.yieldToken || _ctx.recipient == address(this)) {
      revert IRelayToken.InvalidRecipient();
    }

    uint256 _stakedBefore = uint256(_votingEscrow.staked(_ctx.relayTokenId).amount);

    // recipient address(0): no mint, the destination is the existing relayTokenId.
    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](1);
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _ctx.tokenId, amount: _ctx.amount.toUint128()});
    // The returned mint id is always zero here; the net amount is measured from the staked balance.
    // slither-disable-next-line unused-return
    _vpm.depositIntoNFT(_sources, _ctx.relayTokenId, address(0));

    // Net weight actually received: the request minus the VPM protocol fee.
    _netAmount = uint256(_votingEscrow.staked(_ctx.relayTokenId).amount) - _stakedBefore;

    if (_netAmount < _ctx.minDeposit) revert IRelay.BelowMinimumDeposit();
    if (_ctx.totalSupply != 0 && _netAmount * _ctx.totalSupply < _ctx.totalBacking) revert IRelay.ZeroShares();

    // The bookkeeping issues the id; the queue stores no link, so the entry after `_id` is always
    // `_id + 1` and `tail` marks the end.
    uint40 _id = _list.append();
    _deposits[_id] = IRelay.PendingDeposit({
      recipient: _ctx.recipient,
      requestedAt: uint48(block.timestamp),
      tokenId: _ctx.tokenId.toUint128(),
      amount: _netAmount.toUint128()
    });

    emit IRelay.DepositRequested(_ctx.tokenId, _ctx.recipient, _netAmount, _id);
  }

  /// @notice Registers the caller's exit: guards the request, then escrows the shares into the FIFO
  ///         withdraw queue. The caller credits the shares to its pending-withdrawal counter.
  /// @param _queue Bookkeeping of the withdraw FIFO.
  /// @param _withdrawals Registered exits by id.
  /// @param _escrowedShares Per-holder escrowed (queued, undrained) shares.
  /// @param _ctx The exit request plus the Relay-side readings the guards check.
  /// @dev Delegatecalled, so `msg.sender` is the registering holder. One escrow counter locks the
  ///      PT/YT pair in equal units.
  /// @dev A closed Relay asks the free-share cover of the principal alone. While open, demanding
  ///      the yield side keeps a holder from selling the reward stream and still taking the
  ///      principal that funds it; once closed nothing accrues again, so the requirement would only
  ///      trap holders who sold. The drain mirrors this and stops burning the yield side past
  ///      closure; see `processWithdrawals`.
  /// @dev The destination is taken as given, with one exception: the sAERO stays transferable while
  ///      the entry waits, and an unusable destination falls back to a fresh sAERO at settlement.
  ///      The exception is the Relay sAERO itself, whose source and destination legs net out inside
  ///      the VPM, so with a nonzero fee the drain's delivered-amount measurement would underflow
  ///      and wedge the shared FIFO head.
  /// @dev The size floor is `min(free position, minWithdrawal)`, never `minWithdrawal` alone.
  ///      `minDeposit` is denominated in weight and `minWithdrawal` in shares, so a price per share
  ///      above one prices a valid deposit into fewer shares than the exit floor asks for, and a
  ///      floor that ignored the position would lock it in for good. A zero exit stays refused.
  function registerExit(
    DenseQueue.Queue storage _queue,
    mapping(uint256 id => IRelay.WithdrawEntry entry) storage _withdrawals,
    mapping(address holder => uint256 shares) storage _escrowedShares,
    RegisterExitContext memory _ctx
  ) external {
    if (_ctx.destination == _ctx.relayTokenId) revert IRelay.InvalidDestination();

    // The entry holds the destination in 72 bits, so a wider one is refused rather than truncated
    // onto an unrelated sAERO. Only the mint sentinel is legitimately outside that range.
    bool _mintFresh = _ctx.destination == _MINT_SENTINEL;
    if (!_mintFresh && _ctx.destination > type(uint72).max) revert IRelay.InvalidDestination();

    uint256 _escrowed = _escrowedShares[msg.sender];
    uint256 _principal = _ctx.principalToken.balanceOf(msg.sender);
    uint256 _needed = _escrowed + _ctx.shares;
    if (_principal < _needed) revert IRelay.InsufficientFreeShares();
    if (!_ctx.closed && _ctx.yieldToken.balanceOf(msg.sender) < _needed) revert IRelay.InsufficientFreeShares();

    uint256 _free = _principal - _escrowed;
    uint256 _floor = _free < _ctx.minWithdrawal ? _free : _ctx.minWithdrawal;
    if (_ctx.shares == 0 || _ctx.shares < _floor) revert IRelay.BelowMinimumWithdrawal();

    appendExit(_queue, _withdrawals, _escrowedShares, msg.sender, _ctx.shares, _ctx.destination, _mintFresh);
  }

  /// @notice Walk the deposit queue from its head: visit up to `_ctx.maxEntries` entries in request
  ///         order and process each live entry at the simulated totalBacking/totalSupply ratio,
  ///         deleting it as it settles.
  /// @param _list Deposit-queue bookkeeping (the Relay's storage).
  /// @param _deposits Deposit-queue entries by id.
  /// @param _ctx Relay-side counters the loop prices against, plus the satellite pair to mint on.
  /// @return _result The new backing and the processed count.
  /// @dev Reverts when nothing is pending. The budget counts visited entries, not settled ones,
  ///      so a run of consumed entries cannot make the walk unbounded. A closed Relay mints the
  ///      principal alone.
  function processDeposits(
    DenseQueue.Queue storage _list,
    mapping(uint256 id => IRelay.PendingDeposit deposit) storage _deposits,
    DepositContext memory _ctx
  ) external returns (DepositResult memory _result) {
    DenseQueue.Queue memory _queueCache = _list;
    if (_queueCache.isEmpty()) revert IRelay.NoPendingDeposits();

    _result.totalBacking = _ctx.totalBacking;
    uint256 _supply = _ctx.totalSupply;

    // A wider cursor than the id type: `++_cursor` past the last id must not revert on overflow.
    uint256 _cursor = _queueCache.head;
    for (uint256 _i; _i < _ctx.maxEntries && _queueCache.exists(_cursor); ++_i) {
      // A skip over a consumed entry reads only the entry's first slot: a live entry always
      // carries its request timestamp.
      IRelay.PendingDeposit storage _stored = _deposits[_cursor];
      if (_stored.requestedAt != 0) {
        IRelay.PendingDeposit memory _entry = _stored;
        // Effects before the mints: the delete prevents a second processing (and refunds the
        // entry's slots), and the mint hook re-enters the Relay's settle path.
        delete _deposits[_cursor];
        --_queueCache.count;
        ++_result.count;
        (_result.totalBacking, _supply) = _processEntry(_entry, _ctx, _result.totalBacking, _supply);
      }
      ++_cursor;
    }

    // Each entry before the cursor is consumed: the head moves to the first entry the walk did
    // not visit, or to zero when the walk reached the end of the queue.
    _queueCache.head = _queueCache.nextHead(_cursor);
    _list.store(_queueCache);
  }

  /// @notice Process the named pending deposits, in the given order, after each one has aged past
  ///         the keeper window. The permissionless liveness path: anyone can process one entry on
  ///         its own, so no backlog before it can block it.
  /// @param _list Deposit-queue bookkeeping (the Relay's storage).
  /// @param _deposits Deposit-queue entries by id.
  /// @param _ids Deposit-queue ids to process.
  /// @param _ctx Relay-side counters the loop prices against, plus the satellite pair to mint on.
  /// @return _result The new backing and the processed count.
  /// @dev Reverts on an empty ids array, an id that was never issued, an entry that was already
  ///      processed, or an entry that is still inside the keeper window: the caller controls the
  ///      array, so a bad id is an error, never a skip.
  function processOverdueDeposits(
    DenseQueue.Queue storage _list,
    mapping(uint256 id => IRelay.PendingDeposit deposit) storage _deposits,
    uint256[] calldata _ids,
    DepositContext memory _ctx
  ) external returns (DepositResult memory _result) {
    if (_ids.length == 0) revert IRelay.NoPendingDeposits();

    DenseQueue.Queue memory _queueCache = _list;
    _result.totalBacking = _ctx.totalBacking;
    uint256 _supply = _ctx.totalSupply;

    for (uint256 _i; _i < _ids.length; ++_i) {
      uint256 _id = _ids[_i];
      if (!_queueCache.exists(_id)) revert IRelay.DepositNotFound();

      IRelay.PendingDeposit memory _entry = _deposits[_id];
      // A consumed entry is deleted, so its zeroed timestamp is the already-processed marker.
      if (_entry.requestedAt == 0) revert IRelay.DepositAlreadyProcessed();
      // The age comparison cannot underflow (requestedAt never exceeds the current timestamp),
      // whatever the configured window. An entry aged exactly the window is already processable.
      if (block.timestamp - uint256(_entry.requestedAt) < _ctx.keeperWindow) {
        revert IRelay.KeeperWindowNotElapsed();
      }

      // Effects before the mints, as in the ordered walk.
      delete _deposits[_id];
      --_queueCache.count;
      ++_result.count;
      // The single cheap head step. The new head can also be a consumed entry; the walk's budget
      // pays for longer advances, never this path.
      if (_id == _queueCache.head) _queueCache.head = _queueCache.nextHead(_id + 1);

      (_result.totalBacking, _supply) = _processEntry(_entry, _ctx, _result.totalBacking, _supply);
    }

    _list.store(_queueCache);
  }

  /// @notice Drain up to `_ctx.maxEntries` queued exits in FIFO order against the idle chain0
  ///         weight, routing each exit's weight out through the VPM.
  /// @param _queue Bookkeeping of the withdraw FIFO.
  /// @param _withdrawals Registered exits by id.
  /// @param _votingEscrow VotingEscrow, read for the destination lock check.
  /// @param _escrowedShares Per-holder escrowed (queued, undrained) shares (the Relay's storage).
  /// @param _vpm VoterPaymentsModule the weight routes out through (called as the Relay).
  /// @param _ctx Relay-side counters the loop prices against, plus the satellite pair to burn on.
  /// @return _result The new counters and the settled count.
  /// @dev Stops at the first exit the free chain0 weight cannot cover — a withdrawal may never
  ///      move allocated weight, and funds return asynchronously, so pausing here is a normal
  ///      state rather than an error. When the named destination cannot legally receive the weight
  ///      under VE's monotonic unlock rule, the drain falls back to minting a fresh sAERO so the
  ///      exit never reverts.
  function processWithdrawals(
    DenseQueue.Queue storage _queue,
    mapping(uint256 id => IRelay.WithdrawEntry entry) storage _withdrawals,
    mapping(address holder => uint256 shares) storage _escrowedShares,
    IVotingEscrow _votingEscrow,
    IVoterPaymentsModule _vpm,
    WithdrawContext memory _ctx
  ) external returns (WithdrawResult memory _result) {
    DenseQueue.Queue memory _queueCache = _queue;
    uint256 _entries = Math.min(_ctx.maxEntries, _queueCache.count);
    _result.totalBacking = _ctx.totalBacking;
    _result.pendingWithdrawalShares = _ctx.pendingWithdrawalShares;

    // A wider cursor than the id type: settling the last id increments past it, which must not
    // revert on overflow.
    uint256 _cursor = _queueCache.head;

    // Each settled exit's VPM move debits the Voter's chain0 in the same transaction, so the
    // decrement on the context's free weight mirrors the live ledger exactly.
    for (uint256 i; i < _entries; ++i) {
      // Read only the shares before the cover check: a drain that stops on an uncovered head
      // does not pay for the fields it never uses.
      IRelay.WithdrawEntry storage _stored = _withdrawals[_cursor];
      uint256 _amount = (uint256(_stored.shares) * _result.totalBacking) / _ctx.totalSupply;

      // Only free chain0 weight can leave; stop once it no longer covers the head exit in full.
      if (_amount > _ctx.freeWeight) break;
      IRelay.WithdrawEntry memory _entry = _stored;
      // Settling deletes the entry, which refunds its slots; the escrow release below and the
      // event are the remaining record. The drain only ever consumes the head, so the ids it
      // settles are consecutive.
      delete _withdrawals[_cursor];
      ++_cursor;
      --_queueCache.count;

      // The next exit prices at the post-burn ratio.
      _ctx.totalSupply -= _entry.shares;
      _result.totalBacking -= _amount;
      _ctx.freeWeight -= _amount;
      _result.pendingWithdrawalShares -= _entry.shares;
      ++_result.count;

      _routeWithdrawal(_votingEscrow, _vpm, _ctx.relayTokenId, _entry, _amount);

      // Release the escrow BEFORE either satellite burns and fires the hook back into the Relay.
      _escrowedShares[_entry.holder] -= _entry.shares;
      _ctx.principalToken.burn(_entry.holder, _entry.shares);

      // The yield side burns only while the Relay is open. Past closure the fee tail of the final
      // votes still arrives an epoch later, and the yield supply is that distribution's
      // denominator: burning at exit would size each holder's slice by exit order, and a drained
      // queue would strand the tail behind `NoSupply`. The yield token is the receipt for the tail.
      if (!_ctx.closed) _ctx.yieldToken.burn(_entry.holder, _entry.shares);
    }

    // A call that settles nothing leaves the queue untouched, so it writes no storage.
    if (_result.count != 0) {
      _queueCache.head = _queueCache.nextHead(_cursor);
      _queue.store(_queueCache);
    }
  }

  /// @notice Require an uncovered head exit: a full evacuation window has passed since its
  ///         registration AND the free chain0 weight cannot pay it. This is the permissionless
  ///         closing gate.
  /// @param _queue Bookkeeping of the withdraw FIFO (the Relay's storage).
  /// @param _withdrawals Registered exits by id (the Relay's storage).
  /// @param _voter The Voter holding the free chain0 weight.
  /// @param _tokenId The Relay's sAERO whose free weight prices the head.
  /// @dev Reads the Relay back through its own ABI rather than taking these as parameters, which is
  ///      deliberate and measured: hoisting the reads to the call site costs the Relay 313 B of
  ///      EIP-170 bytecode. Keep the reads in here.
  function requireUncoveredHead(
    DenseQueue.Queue storage _queue,
    mapping(uint256 id => IRelay.WithdrawEntry entry) storage _withdrawals,
    IVoter _voter,
    uint256 _tokenId
  ) external view {
    DenseQueue.Queue memory _queueCache = _queue;
    // Revert when no exit is waiting in the queue.
    if (_queueCache.isEmpty()) revert IRelay.NoQueuedWithdrawal();

    // Revert while the evacuation window since the head's registration has not elapsed. The drain
    // only consumes the head, so the head id is always the oldest exit that still waits. The check
    // reads two of the entry's fields, so a storage pointer skips the third slot.
    IRelay.WithdrawEntry storage _head = _withdrawals[_queueCache.head];
    IRelayState _relay = IRelayState(address(this));
    if (block.timestamp < _head.registeredAt + uint256(_relay.relayConfig().evacuationWindow)) {
      revert IRelay.EvacuationWindowNotElapsed();
    }

    // Revert if the free chain0 weight can pay the head: a processWithdrawals call settles it.
    uint256 _amount = (uint256(_head.shares) * _relay.totalBacking()) / _relay.principalToken().totalSupply();
    if (_amount <= _voter.allocationChainAmounts(_tokenId, _CHAIN0)) revert IRelay.HeadIsCovered();
  }

  /// @notice The one queue append behind every exit: bank the escrow and store the entry.
  /// @dev Internal on purpose, so the two callers reach it inlined: `registerExit` here for a
  ///      holder-initiated exit, and `RelayRewardsLib.ejectHolder` for an owner eviction. Both run
  ///      their own guards first; this function trusts its inputs.
  /// @param _queue Bookkeeping of the withdraw FIFO.
  /// @param _withdrawals Registered exits by id.
  /// @param _escrowedShares Per-holder escrowed (queued, undrained) shares.
  /// @param _holder Holder whose shares escrow.
  /// @param _shares Shares to escrow and burn at drain.
  /// @param _destination Destination sAERO, ignored when `_mintFresh` is set.
  /// @param _mintFresh Whether the drain routes the weight to a freshly minted sAERO.
  function appendExit(
    DenseQueue.Queue storage _queue,
    mapping(uint256 id => IRelay.WithdrawEntry entry) storage _withdrawals,
    mapping(address holder => uint256 shares) storage _escrowedShares,
    address _holder,
    uint256 _shares,
    uint256 _destination,
    bool _mintFresh
  ) internal {
    _escrowedShares[_holder] += _shares;
    uint40 _id = _queue.append();
    // registeredAt never moves: the evacuation clock measures from registration, not from
    // becoming the head.
    _withdrawals[_id] = IRelay.WithdrawEntry({
      holder: _holder,
      registeredAt: uint48(block.timestamp),
      mintFresh: _mintFresh,
      shares: _shares.toUint128(),
      destination: _mintFresh ? 0 : _destination.toUint72()
    });
    emit IRelay.WithdrawRegistered(_holder, _shares, _mintFresh ? _MINT_SENTINEL : _destination, _id);
  }

  /// @notice Price one pending deposit at the running ratio, mint its pair and emit the
  ///         `DepositProcessed` event. The one pricing block behind both deposit paths.
  /// @param _entry The entry to process; the caller already deleted it from the queue's storage.
  /// @param _ctx The processing context that carries the satellite pair to mint on.
  /// @param _backing Running backing counter before this entry.
  /// @param _supply Running share supply before this entry.
  /// @return _newBacking Running backing counter after admitting this entry's principal.
  /// @return _newSupply Running share supply after this entry's mint.
  /// @dev The supply==0/backing==0 one-to-one branch is unreachable in production (initialize
  ///      mints the seed 1:1), kept as defense-in-depth. An entry whose shares round down to zero
  ///      still processes: its principal becomes an explicit donation.
  function _processEntry(
    IRelay.PendingDeposit memory _entry,
    DepositContext memory _ctx,
    uint256 _backing,
    uint256 _supply
  ) private returns (uint256 _newBacking, uint256 _newSupply) {
    uint256 _shares = _supply == 0 || _backing == 0 ? _entry.amount : (uint256(_entry.amount) * _supply) / _backing;

    // The next entry prices at the post-mint ratio.
    _newBacking = _backing + _entry.amount;
    _newSupply = _supply + _shares;

    // A closed Relay mints the principal alone.
    _ctx.principalToken.mint(_entry.recipient, _shares);
    if (!_ctx.closed) _ctx.yieldToken.mint(_entry.recipient, _shares);

    emit IRelay.DepositProcessed(_entry.tokenId, _entry.recipient, _entry.amount, _shares);
  }

  /// @notice Route one settled exit's weight out through the VPM and emit its settlement.
  /// @param _votingEscrow VotingEscrow, read for the destination lock check and the net-amount delta.
  /// @param _vpm VoterPaymentsModule the weight routes out through (called as the Relay).
  /// @param _relayTokenId The Relay's sAERO the weight leaves from.
  /// @param _entry The exit being settled (holder, shares, named destination).
  /// @param _amount Gross weight leaving the Relay sAERO for this exit.
  /// @dev Split out of `processWithdrawals` to keep the legacy (non-IR) pipeline under its stack limit.
  function _routeWithdrawal(
    IVotingEscrow _votingEscrow,
    IVoterPaymentsModule _vpm,
    uint256 _relayTokenId,
    IRelay.WithdrawEntry memory _entry,
    uint256 _amount
  ) private {
    // A destination whose lock fails VE's monotonic unlock rule falls back to a fresh sAERO, so
    // the exit never reverts on a short-locked destination.
    uint256 _destination = _entry.destination;
    bool _mintFresh = _entry.mintFresh;
    if (!_mintFresh && _destinationFallsShort(_votingEscrow, _relayTokenId, _destination)) _mintFresh = true;

    // Snapshot the destination stake so the net delivered amount is measured as a delta.
    uint256 _destinationBefore = _mintFresh ? 0 : uint256(_votingEscrow.staked(_destination).amount);

    // The recipient is only meaningful on the mint path; the escrow rejects a non-mint leg that
    // carries one (`NonMintRecipientNotAllowed`), so the field stays empty otherwise.
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta({
      tokenId: _mintFresh ? _MINT_SENTINEL : _destination,
      amount: _amount.toUint128(),
      recipient: _mintFresh ? _entry.holder : address(0)
    });
    uint256[] memory _mintedIds = _vpm.withdrawToNFT(_relayTokenId, _destinations);

    uint256 _settled = _mintFresh ? _mintedIds[0] : _destination;

    // The counters stay debited by the gross `_amount`: the VPM fee is borne by the exiting
    // holder, not the remaining ones.
    uint256 _netAmount = uint256(_votingEscrow.staked(_settled).amount) - _destinationBefore;
    emit IRelay.WithdrawProcessed(_entry.holder, _entry.shares, _netAmount, _settled);
  }

  /// @notice Whether a named withdraw destination cannot legally receive weight from the Relay sAERO
  ///         under VE's monotonic unlock rule, forcing the drain to mint a fresh sAERO instead.
  /// @param _votingEscrow VotingEscrow holding both stakes.
  /// @param _relayTokenId The Relay's sAERO (the source of the weight).
  /// @param _destination Candidate destination sAERO the holder named at registration.
  /// @return _short True when the destination's lock falls short of the Relay's.
  /// @dev A permanent source (the base Relay) forces a permanent destination; a non-permanent source
  ///      (the custom-period subclass) requires the destination's unlock to be no earlier than its
  ///      own. A permanent destination always satisfies the rule.
  function _destinationFallsShort(
    IVotingEscrow _votingEscrow,
    uint256 _relayTokenId,
    uint256 _destination
  ) private view returns (bool _short) {
    IVotingEscrow.StakedBalance memory _source = _votingEscrow.staked(_relayTokenId);
    IVotingEscrow.StakedBalance memory _dst = _votingEscrow.staked(_destination);
    _short = _source.isPermanent ? !_dst.isPermanent : (!_dst.isPermanent && _dst.end < _source.end);
  }
}
