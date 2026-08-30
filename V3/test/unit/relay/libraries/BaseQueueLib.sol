// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {QueueLibHarness} from 'V3-test/unit/relay/harnesses/QueueLibHarness.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';

/**
 * @title BaseQueueLib
 * @notice Base for QueueLib unit tests: storage-owning harness, mocked VotingEscrow/VPM, and queue-seeding helpers.
 */
abstract contract BaseQueueLib is TestHelpers {
  /// @dev Drain budget the tests pass; tests seed at most a handful of entries, so it covers all.
  uint256 internal constant _MAX_DRAIN_ENTRIES = 10;

  /// @dev Maximum entries a fuzzed queue seed produces.
  uint256 internal constant _MAX_SEEDED_DEPOSITS = 3;

  /// @dev Mirrors QueueLib's `_MINT_SENTINEL` (and RelayBase's public MINT_SENTINEL).
  uint256 internal constant _MINT_SENTINEL = type(uint256).max;

  /// @dev Fixed relay sAERO id used across withdraw tests; an opaque key with no arithmetic role.
  uint256 internal constant _RELAY_TOKEN_ID = 8888;

  /// @notice One fuzz parameter describing a whole deposit queue (single stack slot for the tight legacy stack limit).
  /// @param count Entry count, bounded to [1, max seeded].
  /// @param baseTokenId Base id; entries take consecutive ids so per-entry owner mocks never collide.
  /// @param amounts Per-entry amounts.
  /// @param requestedAts Per-entry request times.
  struct DepositQueueSeed {
    uint256 count;
    uint256 baseTokenId;
    uint256[3] amounts;
    uint256[3] requestedAts;
  }

  /// @notice One fuzz parameter describing a whole withdraw queue; holders derive per index and destinations default to the mint sentinel.
  /// @param head Ring head.
  /// @param count Entry count, bounded to [1, max seeded].
  /// @param shares Per-entry escrowed shares.
  /// @param escrowSurpluses Extra escrow beyond the entry (holders can have several queued exits); asserted as the escrow remainder.
  /// @param feeBps VPM protocol-fee rate on the gross weight, bounded to [0, 10_000] per test.
  struct WithdrawQueueSeed {
    uint256 head;
    uint256 count;
    uint256[3] shares;
    uint256[3] escrowSurpluses;
    uint256 feeBps;
  }

  QueueLibHarness internal _queue;
  address internal _votingEscrow;
  address internal _vpm;
  address internal _principalToken;
  address internal _yieldToken;

  function setUp() public virtual {
    _votingEscrow = _mockContract('VotingEscrow');
    _vpm = _mockContract('VoterPaymentsModule');
    _principalToken = _mockContract('PrincipalToken');
    _yieldToken = _mockContract('YieldToken');
    _queue = new QueueLibHarness();

    // The drains pair mint/burn on the satellites; the mocks accept every call so each test only
    // asserts the calls it expects.
    vm.mockCall(_principalToken, abi.encodeWithSelector(IRelayToken.mint.selector), abi.encode());
    vm.mockCall(_yieldToken, abi.encodeWithSelector(IRelayToken.mint.selector), abi.encode());
    vm.mockCall(_principalToken, abi.encodeWithSelector(IRelayToken.burn.selector), abi.encode());
    vm.mockCall(_yieldToken, abi.encodeWithSelector(IRelayToken.burn.selector), abi.encode());
  }

  /// @dev Expect the pair mint both satellites perform for one admitted entry.
  function _expectPairMint(address _recipient, uint256 _shares) internal {
    vm.expectCall(_principalToken, abi.encodeCall(IRelayToken.mint, (_recipient, _shares)));
    vm.expectCall(_yieldToken, abi.encodeCall(IRelayToken.mint, (_recipient, _shares)));
  }

  /// @dev Expect the pair burn both satellites perform for one settled exit.
  function _expectPairBurn(address _holder, uint256 _shares) internal {
    vm.expectCall(_principalToken, abi.encodeCall(IRelayToken.burn, (_holder, _shares)));
    vm.expectCall(_yieldToken, abi.encodeCall(IRelayToken.burn, (_holder, _shares)));
  }

  /// @dev Seed the deposit queue with `_entries` in request order: consecutive ids from one, the
  ///      head at the first.
  function _seedDepositQueue(IRelay.PendingDeposit[] memory _entries) internal {
    for (uint256 _i; _i < _entries.length; ++_i) {
      _queue.setPendingDeposit(_i + 1, _entries[_i]);
    }
    _queue.setDepositList(DenseQueue.Queue({head: 1, tail: uint40(_entries.length), count: uint40(_entries.length)}));
  }

  /// @dev Append one deposit entry at the queue's tail, the way `registerDeposit` does: the
  ///      bookkeeping issues the id, the caller stores the entry under it. Driven through the real
  ///      `append` so the seed follows the same rule production does.
  function _appendDeposit(IRelay.PendingDeposit memory _entry) internal {
    uint40 _id = _queue.appendDeposit();
    _queue.setPendingDeposit(_id, _entry);
  }

  /// @dev Bound and seed a fuzzed deposit queue. Per-entry amounts stay within a quarter of the uint128
  ///      VE-weight ceiling so a full seed plus the backing always fits uint128 (the global staked-TOKEN cap).
  ///      Each entry stores its own per-index recipient, mirroring what `registerDeposit` records.
  function _seedFuzzedDepositQueue(DepositQueueSeed memory _seed) internal {
    _seed.count = bound(_seed.count, 1, _MAX_SEEDED_DEPOSITS);
    _seed.baseTokenId = bound(_seed.baseTokenId, 0, type(uint128).max - _MAX_SEEDED_DEPOSITS);
    IRelay.PendingDeposit[] memory _entries = new IRelay.PendingDeposit[](_seed.count);
    for (uint256 _i; _i < _seed.count; ++_i) {
      _entries[_i] = IRelay.PendingDeposit({
        recipient: _recipientAt(_i),
        // A zero timestamp marks a consumed entry, so a live seed starts at one.
        requestedAt: uint48(bound(_seed.requestedAts[_i], 1, type(uint48).max - 1)),
        tokenId: uint128(_seed.baseTokenId + _i),
        amount: uint128(bound(_seed.amounts[_i], 1, uint256(type(uint128).max) / 4))
      });
    }
    _seedDepositQueue(_entries);
  }

  /// @dev Read the deposit entry at the queue's head.
  function _headDeposit() internal view returns (IRelay.PendingDeposit memory _entry) {
    _entry = _depositAt(0);
  }

  /// @dev Read the deposit entry stored under `_id`.
  function _depositById(uint256 _id) internal view returns (IRelay.PendingDeposit memory _entry) {
    (_entry.recipient, _entry.requestedAt, _entry.tokenId, _entry.amount) = _queue.pendingDeposits(_id);
  }

  /// @dev Whether the entry under `_id` was consumed: processing deletes the entry, so a zeroed
  ///      request timestamp is the marker (a live entry always stamps a non-zero one).
  function _isConsumed(uint256 _id) internal view returns (bool _consumed) {
    _consumed = _depositById(_id).requestedAt == 0;
  }

  /// @dev Read the deposit entry `_offset` ids past the queue's head (a consumed id reads zeroes).
  function _depositAt(uint256 _offset) internal view returns (IRelay.PendingDeposit memory _entry) {
    (uint40 _head,,) = _queue.depositList();
    _entry = _depositById(uint256(_head) + _offset);
  }

  /// @dev Outstanding (live) entries on the deposit queue.
  function _listCount() internal view returns (uint256 _count) {
    (,, uint40 _outstanding) = _queue.depositList();
    _count = _outstanding;
  }

  /// @dev Sum of all outstanding (live) entries' amounts, sweeping the whole queue. A consumed
  ///      entry is deleted, so its zeroed amount adds nothing.
  function _totalSeededAmount() internal view returns (uint256 _total) {
    (uint40 _head, uint40 _tail,) = _queue.depositList();
    if (_head == 0) return _total;
    for (uint256 _id = _head; _id <= _tail; ++_id) {
      _total += _depositById(_id).amount;
    }
  }

  /// @dev Deterministic per-index recipient address, stable across repeated calls.
  function _recipientAt(uint256 _index) internal returns (address _recipient) {
    _recipient = makeAddr(string.concat('recipient', vm.toString(_index)));
  }

  /// @dev Deterministic per-index holder address, stable across repeated calls.
  function _holderAt(uint256 _index) internal returns (address _holder) {
    _holder = makeAddr(string.concat('holder', vm.toString(_index)));
  }

  /// @dev Bound and seed a fuzzed withdraw queue. Per-entry shares stay within a quarter of the
  ///      uint128 ceiling so any seed total fits the supply and backing bounds.
  function _seedFuzzedWithdrawQueue(WithdrawQueueSeed memory _seed) internal {
    _seed.head = bound(_seed.head, 1, type(uint32).max);
    _seed.count = bound(_seed.count, 1, _MAX_SEEDED_DEPOSITS);
    _queue.setWithdrawQueue(
      DenseQueue.Queue({
        head: uint40(_seed.head), tail: uint40(_seed.head + _seed.count - 1), count: uint40(_seed.count)
      })
    );
    for (uint256 _i; _i < _seed.count; ++_i) {
      uint256 _shares = bound(_seed.shares[_i], 1, uint256(type(uint128).max) / 4);
      _queue.setWithdrawal(
        _seed.head + _i,
        IRelay.WithdrawEntry({
          holder: _holderAt(_i),
          registeredAt: uint48(block.timestamp),
          mintFresh: true,
          shares: uint128(_shares),
          destination: 0
        })
      );
      _queue.setEscrowedShares(_holderAt(_i), _shares + bound(_seed.escrowSurpluses[_i], 0, type(uint64).max));
    }
  }

  /// @dev Read the withdraw entry `_offset` ids past the queue's head.
  function _withdrawAt(uint256 _offset) internal view returns (IRelay.WithdrawEntry memory _entry) {
    (uint40 _head,,) = _queue.withdrawQueue();
    (_entry.holder, _entry.registeredAt, _entry.mintFresh, _entry.shares, _entry.destination) =
      _queue.withdrawals(uint256(_head) + _offset);
  }

  /// @dev Sum of all outstanding withdraw entries' shares — the production `pendingWithdrawalShares`.
  function _totalSeededWithdrawShares() internal view returns (uint256 _total) {
    uint256 _count = _queueCount();
    for (uint256 _i; _i < _count; ++_i) {
      _total += _withdrawAt(_i).shares;
    }
  }

  /// @dev Overwrite the head withdraw entry's destination (seeds default to the mint path), folding
  ///      the sentinel into the flag the way registration does.
  function _setHeadWithdrawalDestination(uint256 _destination) internal {
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    _entry.mintFresh = _destination == _MINT_SENTINEL;
    _entry.destination = _entry.mintFresh ? 0 : uint72(_destination);
    (uint40 _head,,) = _queue.withdrawQueue();
    _queue.setWithdrawal(_head, _entry);
  }

  /// @dev Build a withdraw-drain context in one line (open Relay).
  function _withdrawContext(
    uint256 _maxEntries,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _freeWeight,
    uint256 _pendingWithdrawalShares
  ) internal view returns (QueueLib.WithdrawContext memory _ctx) {
    _ctx = _withdrawContext(_maxEntries, _totalSupply, _totalBacking, _freeWeight, _pendingWithdrawalShares, false);
  }

  /// @dev Build a withdraw-drain context in one line, naming the closed flag (which is what turns
  ///      off the yield-side burn).
  function _withdrawContext(
    uint256 _maxEntries,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _freeWeight,
    uint256 _pendingWithdrawalShares,
    bool _closed
  ) internal view returns (QueueLib.WithdrawContext memory _ctx) {
    _ctx = QueueLib.WithdrawContext({
      maxEntries: _maxEntries,
      totalSupply: _totalSupply,
      totalBacking: _totalBacking,
      freeWeight: _freeWeight,
      pendingWithdrawalShares: _pendingWithdrawalShares,
      relayTokenId: _RELAY_TOKEN_ID,
      principalToken: IRelayToken(_principalToken),
      yieldToken: IRelayToken(_yieldToken),
      closed: _closed
    });
  }

  /// @dev Mock (and expect) the VPM weight move for one exit; on the mint path the VPM answers
  ///      with the fresh id, a named destination returns no minted ids.
  /// @dev The recipient rides along only on the mint path, where it owns the sAERO the escrow creates.
  ///      A named destination already has an owner, and the escrow refuses a non-mint leg that carries
  ///      a recipient at all, so expecting one here would pin a call the escrow would reject.
  function _mockWithdrawToNFT(uint256 _destination, uint256 _amount, address _holder, uint256 _mintedId) internal {
    IVotingEscrow.DestinationDelta[] memory _deltas = new IVotingEscrow.DestinationDelta[](1);
    // forge-lint: disable-next-line(unsafe-typecast)
    _deltas[0] = IVotingEscrow.DestinationDelta({
      tokenId: _destination, amount: uint128(_amount), recipient: _destination == _MINT_SENTINEL ? _holder : address(0)
    });
    uint256[] memory _mintedIds;
    if (_destination == _MINT_SENTINEL) {
      _mintedIds = new uint256[](1);
      _mintedIds[0] = _mintedId;
    }
    _mockAndExpect(
      _vpm, abi.encodeCall(IVoterPaymentsModule.withdrawToNFT, (_RELAY_TOKEN_ID, _deltas)), abi.encode(_mintedIds)
    );
  }

  /// @dev Mock (and expect) `VE.staked(_tokenId)` with the lock shape the destination rule reads.
  function _mockStaked(uint256 _tokenId, uint48 _end, bool _isPermanent) internal {
    _mockAndExpect(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.staked, (_tokenId)),
      abi.encode(IVotingEscrow.StakedBalance({amount: 0, end: _end, isPermanent: _isPermanent}))
    );
  }

  /// @dev Mock the post-move `staked(_settledId)` read measuring the net weight delivered (fee = gross - net).
  ///      The settled sAERO is a fresh mint, so its baseline is zero and the observed delta is exactly `_net`.
  function _mockSettledStake(uint256 _settledId, uint256 _net) internal {
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.staked, (_settledId)),
      // forge-lint: disable-next-line(unsafe-typecast)
      abi.encode(IVotingEscrow.StakedBalance({amount: uint128(_net), end: 0, isPermanent: true}))
    );
  }

  /// @dev Mock the three `staked(_tokenId)` reads a SURVIVING named destination takes — lock check,
  ///      pre-move baseline (zero) and post-move measurement — so the drain observes exactly `_net` delivered.
  function _mockStakedSurviving(uint256 _tokenId, uint48 _end, bool _isPermanent, uint256 _net) internal {
    bytes memory _calldata = abi.encodeCall(IVotingEscrow.staked, (_tokenId));
    bytes[] memory _returns = new bytes[](3);
    _returns[0] = abi.encode(IVotingEscrow.StakedBalance({amount: 0, end: _end, isPermanent: _isPermanent}));
    _returns[1] = _returns[0];
    // forge-lint: disable-next-line(unsafe-typecast)
    _returns[2] = abi.encode(IVotingEscrow.StakedBalance({amount: uint128(_net), end: _end, isPermanent: _isPermanent}));
    vm.mockCalls(_votingEscrow, _calldata, _returns);
    vm.expectCall(_votingEscrow, _calldata);
  }

  /// @dev Expect one `WithdrawProcessed` event from the harness (the library emits under delegatecall).
  function _expectWithdrawProcessed(address _holder, uint256 _shares, uint256 _amount, uint256 _settledId) internal {
    _expectEmit(address(_queue));
    emit IRelay.WithdrawProcessed(_holder, _shares, _amount, _settledId);
  }

  /// @dev Outstanding entries in the seeded ring.
  function _queueCount() internal view returns (uint256 _count) {
    (,, uint40 _outstanding) = _queue.withdrawQueue();
    _count = _outstanding;
  }

  /// @dev Build a deposit-processing context in one line (the keeper walk reads no window).
  function _depositContext(
    uint256 _maxEntries,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) internal view returns (QueueLib.DepositContext memory _ctx) {
    _ctx = _depositContext(_maxEntries, 0, _totalBacking, _totalSupply);
  }

  /// @dev Build a deposit-processing context in one line, naming the keeper window (the by-id
  ///      path's overdue bound).
  function _depositContext(
    uint256 _maxEntries,
    uint256 _keeperWindow,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) internal view returns (QueueLib.DepositContext memory _ctx) {
    _ctx = QueueLib.DepositContext({
      maxEntries: _maxEntries,
      keeperWindow: _keeperWindow,
      totalBacking: _totalBacking,
      totalSupply: _totalSupply,
      closed: false,
      principalToken: IRelayToken(_principalToken),
      yieldToken: IRelayToken(_yieldToken)
    });
  }

  /// @dev Re-bound the head entry's amount in place and return the updated entry.
  function _reboundHeadDepositAmount(
    uint256 _min,
    uint256 _max
  ) internal returns (IRelay.PendingDeposit memory _entry) {
    (uint40 _head,,) = _queue.depositList();
    _entry = _depositById(_head);
    _entry.amount = uint128(bound(_entry.amount, _min, _max));
    _queue.setPendingDeposit(_head, _entry);
  }

  /// @dev Expect one `DepositProcessed` event from the harness (the library emits under delegatecall).
  function _expectDepositProcessed(uint256 _tokenId, address _recipient, uint256 _amount, uint256 _shares) internal {
    _expectEmit(address(_queue));
    emit IRelay.DepositProcessed(_tokenId, _recipient, _amount, _shares);
  }
}
