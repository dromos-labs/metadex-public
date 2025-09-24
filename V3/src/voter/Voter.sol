// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {AllocationLogicLibrary} from 'V3/libraries/AllocationLogicLibrary.sol';
import {MAX_MESSAGE_LIFETIME, MIN_MESSAGE_LIFETIME} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {GuardedAccessControlEnumerable} from 'V3/access/GuardedAccessControlEnumerable.sol';
import {VoterStorageBase} from 'V3/voter/VoterStorageBase.sol';

/**
 * @title Voter
 * @notice Root-chain hub for cross-chain AERO allocation. Owns each chain's ceiling and point plus the global
 *         emissions scalar, keeps every token's allocations, and routes payloads to the MessageOrchestrator.
 * @dev Inheritance order is load-bearing: `GuardedAccessControlEnumerable` takes slots 0 and 1, so
 *      `VoterStorageBase`'s struct holder starts at slot 2 and every field keeps its original V3 Voter slot.
 */
contract Voter is GuardedAccessControlEnumerable, ReentrancyGuardTransient, VoterStorageBase {
  using EnumerableSet for EnumerableSet.UintSet;
  using SafeERC20 for IERC20;

  /*//////////////////////////////////////////////////////////////
                                CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  uint256 public constant CHAIN0 = 0;

  /// @inheritdoc IVoter
  uint256 public constant TOKEN0 = 0;

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  IRootMessageOrchestrator public immutable ORCHESTRATOR;

  /// @inheritdoc IVoter
  IVotingEscrow public immutable VOTING_ESCROW;

  /// @inheritdoc IVoter
  IMinter public immutable MINTER;

  /// @inheritdoc IVoter
  IERC20 public immutable TOKEN;

  /*//////////////////////////////////////////////////////////////
                                MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restricts the call to VotingEscrow, which owns the chain0 ledger.
   */
  modifier onlyVotingEscrow() {
    if (msg.sender != address(VOTING_ESCROW)) revert NotVotingEscrow();
    _;
  }

  /**
   * @notice Restricts the call to the owner of `_tokenId`, or an address VotingEscrow says it approved.
   */
  modifier onlyAuthorizedForToken(uint256 _tokenId) {
    if (!VOTING_ESCROW.isAuthorized(msg.sender, _tokenId)) revert NotAuthorized();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sets dependencies, allocation parameters and roles, anchors `totalPoint` at deployment, and seeds
   *         `CHAIN0` as the idle sink. Every other chain is added later through `registerChain`.
   * @dev `CHAIN0` is never registered, allocated to, or messaged. Its point timestamp is seeded so the first
   *      allocation does not walk from zero; its `lastIndex`/`lastTimeIndex` default to 0, matching
   *      `index`/`timeIndex`. Its `Active` status is permanent — `setChainStatus` reverts on `CHAIN0`.
   * @dev `GOVERNANCE_ROLE` admins itself and `CONFIG_ADMIN_ROLE`, which admins every operational role. The
   *      exception is `SPLITTER_CONFIG_ROLE`, which directs future team-share emissions and is therefore
   *      administered by `GOVERNANCE_ROLE` directly. Nobody gets `DEFAULT_ADMIN_ROLE`, so the OZ master slot
   *      stays empty.
   * @param _orchestrator Root-side MessageOrchestrator address
   * @param _votingEscrow VotingEscrow the Voter reads stakes from
   * @param _minter Minter the Voter reads the emission rate from. May be a predicted address with no code yet,
   *                so Voter and Minter can be deployed in either order despite their circular references
   * @param _token Emissions token, the same token `_minter` mints. Passed directly instead of read from the
   *               Minter so construction makes no external calls
   * @param _adapterAuthority Adapter-config holder on the MessageOrchestrator; gates no entrypoint here
   * @param _governor Initial `GOVERNANCE_ROLE` holder
   * @param _configAdmin Initial `CONFIG_ADMIN_ROLE` holder
   * @param _allocationLifetime Message lifetime stamped onto every gauge dispatch as an absolute expiry
   * @param _messageLifetime Message lifetime stamped onto every claim and operator dispatch as an absolute expiry
   */
  constructor(
    address _orchestrator,
    address _votingEscrow,
    address _minter,
    address _token,
    address _adapterAuthority,
    address _governor,
    address _configAdmin,
    uint48 _allocationLifetime,
    uint48 _messageLifetime
  ) {
    if (
      _orchestrator == address(0) || _votingEscrow == address(0) || _minter == address(0) || _token == address(0)
        || _adapterAuthority == address(0) || _governor == address(0) || _configAdmin == address(0)
    ) {
      revert ZeroAddress();
    }
    if (_allocationLifetime < MIN_MESSAGE_LIFETIME) revert AllocationLifetimeTooLow();
    if (_allocationLifetime > MAX_MESSAGE_LIFETIME) revert AllocationLifetimeTooHigh();
    if (_messageLifetime < MIN_MESSAGE_LIFETIME) revert MessageLifetimeTooLow();
    if (_messageLifetime > MAX_MESSAGE_LIFETIME) revert MessageLifetimeTooHigh();

    ORCHESTRATOR = IRootMessageOrchestrator(_orchestrator);
    VOTING_ESCROW = IVotingEscrow(_votingEscrow);
    MINTER = IMinter(_minter);
    TOKEN = IERC20(_token);
    _voterStorage.allocationLifetime = _allocationLifetime;
    _voterStorage.messageLifetime = _messageLifetime;
    uint48 _initTimestamp = uint48(block.timestamp);
    _voterStorage.totalPoint.ts = _initTimestamp;
    _voterStorage.lastGlobalSettlement = _initTimestamp;
    _voterStorage.chainStates[CHAIN0].point.ts = _initTimestamp;
    _voterStorage.chainStates[CHAIN0].status = ChainStatus.Active;

    _setRoleAdmin(Roles.GOVERNANCE_ROLE, Roles.GOVERNANCE_ROLE);
    _setRoleAdmin(Roles.CONFIG_ADMIN_ROLE, Roles.GOVERNANCE_ROLE);
    _setRoleAdmin(Roles.VOTER_CONFIG_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.CHAIN_CONFIG_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.CHAIN_STATUS_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.ADAPTER_CONFIG_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.NATIVE_WITHDRAWER_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.RELAY_DEPLOYER_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.FACTORY_REGISTRY_ADMIN_ROLE, Roles.CONFIG_ADMIN_ROLE);
    _setRoleAdmin(Roles.SPLITTER_CONFIG_ROLE, Roles.GOVERNANCE_ROLE);
    _grantRole(Roles.GOVERNANCE_ROLE, _governor);
    _grantRole(Roles.CONFIG_ADMIN_ROLE, _configAdmin);
    _grantRole(Roles.ADAPTER_CONFIG_ROLE, _adapterAuthority);
    _grantRole(Roles.NATIVE_WITHDRAWER_ROLE, _governor);
    _grantRole(Roles.SPLITTER_CONFIG_ROLE, _governor);
  }

  /*//////////////////////////////////////////////////////////////
                          EXTERNAL ENTRIES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  function allocateChains(
    uint256 _tokenId,
    ChainAllocationDispatch[] calldata _chainDispatches,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    // An empty list sends nothing, so attached value would sit trapped here.
    if (_chainDispatches.length == 0 && msg.value != 0) revert UnexpectedValue();

    // Read all live state once, before anything is sent. `_requireLive` rejects a withdrawn (`staked == 0`) or
    // expired stake, so a stale booking can never be re-anchored as permanent VP.
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = AllocationLogicLibrary.prepareChainAllocations({
      _voterStorage: _voterStorage,
      _tokenId: _tokenId,
      _allocations: _chainDispatches,
      _snapshot: _allocationSnapshot({_tokenId: _tokenId, _requireLive: true})
    });

    // Send last: the transport refunds leftover fee to `_refundRecipient`, handing it control flow.
    _dispatchBatch(IMessageOrchestrator.MessageType.AllocateChain, _dispatches, msg.value, _refundRecipient);
  }

  /// @inheritdoc IVoter
  function allocateGauges(
    uint256 _tokenId,
    uint256 _chainId,
    GaugeAllocation[] calldata _gauges,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    // Read all live state once and build, then send.
    AllocationLogicLibrary.GaugeAllocationInput memory _input = AllocationLogicLibrary.GaugeAllocationInput({
      tokenId: _tokenId,
      chainId: _chainId,
      gasLimit: _gasLimit,
      value: msg.value,
      allocationLifetime: _voterStorage.allocationLifetime,
      snapshot: _allocationSnapshot({_tokenId: _tokenId, _requireLive: false})
    });
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = AllocationLogicLibrary.prepareGaugeAllocation(_voterStorage, _input, _gauges);

    _dispatchBatch(IMessageOrchestrator.MessageType.AllocateGauge, _dispatches, msg.value, _refundRecipient);
  }

  /// @inheritdoc IVoter
  function allocate(
    uint256 _tokenId,
    ChainAllocationDispatch[] calldata _chainDispatches,
    GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    // Every read happens before every send: a send hands control to the caller-chosen refund address, which can
    // reenter the VotingEscrow (not covered by this contract's guard) and grow the stake between the messages.
    // slither-disable-next-line uninitialized-local
    uint256 _gaugeBatchFee;
    // slither-disable-next-line uninitialized-local
    uint256 _chainBatchFee;
    {
      uint256 _chainDispatchesLength = _chainDispatches.length;
      for (uint256 _i; _i < _chainDispatchesLength; ++_i) {
        _chainBatchFee += _chainDispatches[_i].value;
      }
      uint256 _gaugeDispatchesLength = _gaugeDispatches.length;
      for (uint256 _i; _i < _gaugeDispatchesLength; ++_i) {
        _gaugeBatchFee += _gaugeDispatches[_i].value;
      }
    }
    // Fix the split upfront: each batch forwards its own value below, so a surplus would sit trapped here and a
    // deficit would underfund the second batch.
    if (msg.value != _chainBatchFee + _gaugeBatchFee) revert UnexpectedValue();

    // 1. Read all live state once, so both batches describe one consistent position.
    AllocationSnapshot memory _snapshot = _allocationSnapshot({_tokenId: _tokenId, _requireLive: true});

    // 2. Chain phase: apply all local accounting and build. Writes the budgets the gauge phase reads back, and
    //    re-anchors the shape, so the per-entry StaleShape check cannot trip mid-batch.
    IRootMessageOrchestrator.ChainDispatch[] memory _chainBatch = AllocationLogicLibrary.prepareChainAllocations({
      _voterStorage: _voterStorage, _tokenId: _tokenId, _allocations: _chainDispatches, _snapshot: _snapshot
    });

    // 3. Gauge phase: validate and settle each entry against those budgets and the step-1 snapshot.
    IRootMessageOrchestrator.ChainDispatch[] memory _gaugeBatch = AllocationLogicLibrary.prepareGaugeBatch({
      _voterStorage: _voterStorage,
      _tokenId: _tokenId,
      _gaugeDispatches: _gaugeDispatches,
      _allocationLifetime: _voterStorage.allocationLifetime,
      _snapshot: _snapshot
    });

    // 4. Send: chains first, then gauges. Nothing is read past here, so a reentrant refund recipient has nothing
    //    left to influence.
    _dispatchBatch(IMessageOrchestrator.MessageType.AllocateChain, _chainBatch, _chainBatchFee, _refundRecipient);
    _dispatchBatch(IMessageOrchestrator.MessageType.AllocateGauge, _gaugeBatch, _gaugeBatchFee, _refundRecipient);
  }

  /// @inheritdoc IVoter
  function burn(uint128 _amount) external nonReentrant onlyVotingEscrow {
    AllocationLogicLibrary.applyBurn(_voterStorage, _amount, MINTER);
  }

  /// @inheritdoc IVoter
  function rebalanceChain0(
    IVotingEscrow.SourceDelta[] calldata _sources,
    IVotingEscrow.DestinationDelta[] calldata _destinations
  ) external nonReentrant onlyVotingEscrow {
    // VE calls this on every rebalance; tolerate an empty batch rather than touching state.
    if (_sources.length == 0 && _destinations.length == 0) return;

    AllocationLogicLibrary.rebalanceChain0({
      _voterStorage: _voterStorage,
      _votingEscrow: VOTING_ESCROW,
      _sources: _sources,
      _destinations: _destinations,
      _minter: MINTER
    });
  }

  /// @inheritdoc IVoter
  function reduceCooldown(
    uint256 _tokenId,
    uint256 _chainId,
    uint48 _reduction,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant {
    // 1. Caller must be a whitelisted VPM. No per-token approval: a reduction is a benefit the VPM grants.
    if (!VOTING_ESCROW.isAuthorizedVPM(msg.sender)) revert NotVoterPaymentsModule();

    // 2. The leaf accrues reductions additively, so a zero grant would be a no-op message.
    if (_reduction == 0) revert ZeroReduction();

    // 3. Root holds no reduction state, so the grant only exists once the leaf accrues it.
    AllocationLogicLibrary.requireDispatchableChain(_voterStorage, _chainId, _gasLimit);

    emit CooldownReductionDispatched(_tokenId, _chainId, _reduction);

    // 4. The leaf stores it and spends it on the next gauge allocation.
    _dispatchSingleChain({
      _msgType: IMessageOrchestrator.MessageType.ReduceCooldown,
      _chainId: _chainId,
      _gasLimit: _gasLimit,
      _payload: abi.encode(ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction})),
      _refundRecipient: _refundRecipient,
      _nativeValue: msg.value,
      _chargeDeallocationReturn: false
    });
  }

  /// @inheritdoc IVoter
  function claimRewards(
    uint256 _tokenId,
    ClaimRewardsParams[] calldata _claimRewardsParams,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    if (_claimRewardsParams.length == 0) revert EmptyClaimRewardsParams();

    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = AllocationLogicLibrary.prepareClaimRewardsDispatches({
      _voterStorage: _voterStorage,
      _tokenId: _tokenId,
      _claimRewardsParams: _claimRewardsParams,
      _messageLifetime: _voterStorage.messageLifetime
    });

    _dispatchBatch(IMessageOrchestrator.MessageType.ClaimRewards, _dispatches, msg.value, _refundRecipient);
  }

  /// @inheritdoc IVoter
  function donate(uint256 _chainId, uint256 _amount) external nonReentrant {
    if (!_voterStorage.chains.contains(_chainId)) revert ChainNotRegistered(_chainId);
    if (_amount == 0) revert ZeroAmount();

    _voterStorage.chainStates[_chainId].donatedBuffer += _amount;

    emit Donated(_chainId, msg.sender, _amount);

    TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
  }

  /**
   * @inheritdoc IVoter
   * @dev `CeilingExceeded` must stay a revert. A leaf settled ahead of root can put its books a bounded step
   *      past this ceiling; the revert rolls the nonce back and the transport redelivers once accrual covers
   *      it. Catching it here or in `route` burns the receipt with no claim against it.
   */
  function processRedeem(
    uint256 _originChainId,
    uint256 _amount,
    address _recipient,
    uint256 _surplusAccrued
  ) external nonReentrant {
    if (msg.sender != address(ORCHESTRATOR)) revert NotAuthorized();
    if (!_voterStorage.chains.contains(_originChainId)) revert ChainNotRegistered(_originChainId);
    // Redeem mints on root, so reject a Suspended (possibly compromised) origin; the transport redelivers later.
    if (_voterStorage.chainStates[_originChainId].status == ChainStatus.Suspended) revert RouteSuspended();

    AllocationLogicLibrary.settleChain(_voterStorage, _originChainId);
    ChainState storage _chainState = _voterStorage.chainStates[_originChainId];

    uint256 _newSurplusReported;
    uint256 _minted;
    uint256 _donated;
    uint256 _buffered = _chainState.donatedBuffer;
    {
      // Max rule: advance only if the report exceeds what root already processed.
      uint256 _surplusStored = _chainState.reportedSurplus;
      _newSurplusReported = _surplusAccrued > _surplusStored ? _surplusAccrued : _surplusStored;

      uint256 _reserved = _newSurplusReported + _chainState.totalRedeemed;
      uint256 _ceiling = _chainState.ceiling;

      // Mint up to the ceiling headroom; the remainder draws on the chain's donated buffer.
      uint256 _headroom = _ceiling > _reserved ? _ceiling - _reserved : 0;
      _minted = Math.min(_amount, _headroom);
      // The Minter rejects mints under its minimum, so a sliver of headroom would stall a redeem the buffer
      // can cover in full; pay it entirely from the buffer instead. When the buffer cannot absorb it either,
      // the mint reverts AmountTooLow and the transport redelivers once enough headroom accrues.
      if (_minted != 0 && _buffered >= _amount && _minted < MINTER.MIN_MINT_AMOUNT()) _minted = 0;
      _donated = _amount - _minted;

      // The headroom bound on the minted leg is the per-chain inflation backstop, and it holds only while
      // the ceiling accrues in sync with the leaf. The Minter's emission cap is the protocol-wide backstop
      // on the minted leg alone; a mint over it reverts `MINTER.mint`, rolling this redeem back for
      // redelivery as `CeilingExceeded` does. The donated buffer
      // extends only the redeem payout with tokens the Voter already holds, paid out instead of minted, so
      // solvency charges the buffer for the actual draw alone. A report may advance past the chain's mint
      // entitlement here, so buffer covered redeems keep clearing after the ceiling stops growing in Sunset.
      // `spendableSurplus` clamps the stored report back to `ceiling - totalRedeemed`, so the buffer backed
      // excess never becomes a `spendSurplus` mint while the donation stays payable to future redeems.
      if (_donated > _buffered) revert CeilingExceeded();

      if (_newSurplusReported > _surplusStored) _chainState.reportedSurplus = _newSurplusReported;
    }

    _chainState.totalRedeemed += _minted;
    if (_donated != 0) {
      _chainState.donatedBuffer = _buffered - _donated;
      emit BufferDrawn(_originChainId, _donated);
      TOKEN.safeTransfer(_recipient, _donated);
    }

    if (_minted != 0) MINTER.mint(_minted, _recipient);

    emit RedeemProcessed(_originChainId, _recipient, _amount, _newSurplusReported);
  }

  /**
   * @inheritdoc IVoter
   * @dev Not `nonReentrant` on purpose: the `RootLocalAdapter` delivers the round trip synchronously, while
   *      the originating entrypoint still holds the shared guard. Safety rests on the orchestrator-only gate
   *      and the `AllocationLogicLibrary.creditDeallocation` clamp (a duplicate credits nothing); it makes no
   *      untrusted calls.
   */
  function processDeallocation(uint256 _originChainId, uint256 _tokenId, uint128 _amount) external {
    if (msg.sender != address(ORCHESTRATOR)) revert NotAuthorized();
    if (!_voterStorage.chains.contains(_originChainId)) revert ChainNotRegistered(_originChainId);

    uint128 _credit = AllocationLogicLibrary.creditDeallocation({
      _voterStorage: _voterStorage,
      _originChainId: _originChainId,
      _tokenId: _tokenId,
      _amount: _amount,
      _minter: MINTER
    });

    emit DeallocationProcessed(_originChainId, _tokenId, _credit);
  }

  /// @inheritdoc IVoter
  function emergencyDeallocate(
    uint256 _tokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    // Suspended only. A sunset chain keeps its normal exit paths, and a dead or compromised one flips to
    // Suspended first, so this stays the recovery route when the leaf or transport goes dark mid wind-down.
    if (!AllocationLogicLibrary.isChainInStatus(_voterStorage, _chainId, ChainStatus.Suspended)) {
      revert ChainNotSuspended(_chainId);
    }
    // Second gate, reset on every suspend, so each suspension re-authorizes deliberately; see
    // `setEmergencyDeallocationAllowed` for why enabling needs no drain.
    if (!_voterStorage.emergencyDeallocationAllowed[_chainId]) revert EmergencyDeallocationNotAllowed(_chainId);
    AllocationLogicLibrary.requireDestinationGas(_chainId, _gasLimit);

    // A suspended leaf cannot confirm a removal, so the owner pulls the whole booked amount back to `CHAIN0`
    // directly; a later leaf `deallocate` clamps to zero on the same path.
    uint128 _credit = AllocationLogicLibrary.creditDeallocation({
      _voterStorage: _voterStorage,
      _originChainId: _chainId,
      _tokenId: _tokenId,
      _amount: _voterStorage.allocationChainAmounts[_tokenId][_chainId],
      _minter: MINTER
    });
    if (_credit == 0) revert NothingToDeallocate();

    emit EmergencyDeallocated(_chainId, _tokenId, _credit);

    // Ship the unwind so the leaf re-syncs when next deliverable; skips the active-chain gate by design. The
    // leaf drops stale pre-drain `AllocateChain` deltas by nonce, so none can revive the cleared position.
    _dispatchSingleChain({
      _msgType: IMessageOrchestrator.MessageType.EmergencyDeallocate,
      _chainId: _chainId,
      _gasLimit: _gasLimit,
      _payload: abi.encode(EmergencyDeallocateMessage({tokenId: _tokenId, amount: _credit})),
      _refundRecipient: _refundRecipient,
      _nativeValue: msg.value,
      _chargeDeallocationReturn: false
    });
  }

  /// @inheritdoc IVoter
  function parkOnChain0(uint256 _tokenId) external nonReentrant onlyVotingEscrow {
    // The parked contribution anchors at the live shape, and an expired stake has no live weight to book.
    (uint128 _staked, uint48 _stakeEnd, bool _isPermanent) = _requireLiveStake(_tokenId);

    AllocationLogicLibrary.parkOnChain0({
      _voterStorage: _voterStorage,
      _votingEscrow: VOTING_ESCROW,
      _tokenId: _tokenId,
      _stake: TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: _isPermanent}),
      _minter: MINTER
    });
  }

  /// @inheritdoc IVoter
  function clearToken(uint256 _tokenId) external nonReentrant onlyVotingEscrow {
    // TOKEN0 is the sink for burned permanent VP; clearing it would wipe the burn ledger.
    if (_tokenId == TOKEN0) revert Token0NotClearable();

    // No point is touched: `withdraw` only accepts an expired stake, so this token's weight already decayed out
    // of every point and unwinding here would subtract twice. The set is bounded by the registered chains.
    uint256[] memory _chainIds = _voterStorage.allocationChainIds[_tokenId].values();
    uint256 _length = _chainIds.length;
    for (uint256 _i; _i < _length; ++_i) {
      delete _voterStorage.allocationChainAmounts[_tokenId][_chainIds[_i]];
    }
    _voterStorage.allocationChainIds[_tokenId].clear();

    // `lastStakeEnd` matters on revival: `0` encodes a permanent shape, so a leftover expiry would anchor a
    // revived position at the wrong shape.
    delete _voterStorage.tokenStates[_tokenId];

    emit TokenCleared(_tokenId, _chainIds);
  }

  /*//////////////////////////////////////////////////////////////
                                  CONFIG
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  function setAllocationLifetime(uint48 _allocationLifetime) external onlyRole(Roles.VOTER_CONFIG_ROLE) {
    if (_allocationLifetime < MIN_MESSAGE_LIFETIME) revert AllocationLifetimeTooLow();
    if (_allocationLifetime > MAX_MESSAGE_LIFETIME) revert AllocationLifetimeTooHigh();
    _voterStorage.allocationLifetime = _allocationLifetime;
    emit AllocationLifetimeSet(_allocationLifetime);
  }

  /// @inheritdoc IVoter
  function setMessageLifetime(uint48 _messageLifetime) external onlyRole(Roles.VOTER_CONFIG_ROLE) {
    if (_messageLifetime < MIN_MESSAGE_LIFETIME) revert MessageLifetimeTooLow();
    if (_messageLifetime > MAX_MESSAGE_LIFETIME) revert MessageLifetimeTooHigh();
    _voterStorage.messageLifetime = _messageLifetime;
    emit MessageLifetimeSet(_messageLifetime);
  }

  /// @inheritdoc IVoter
  function registerChain(uint256 _chainId) external onlyRole(Roles.CHAIN_CONFIG_ROLE) {
    if (_chainId == CHAIN0) revert Chain0NotConfigurable();
    if (!_voterStorage.chains.add(_chainId)) revert ChainAlreadyRegistered(_chainId);

    // Settle first so the cursors planted below describe the registration instant.
    AllocationLogicLibrary.settleGlobalIndex(_voterStorage);

    ChainState storage _state = _voterStorage.chainStates[_chainId];
    _state.point.ts = uint48(block.timestamp);
    // Start both cursors at the current accumulators so the chain accrues nothing for time before registration;
    // they must move in lockstep, else the first settle prices the decay term off a stale zero cursor.
    _state.lastIndex = _voterStorage.index;
    _state.lastTimeIndex = _voterStorage.timeIndex;
    // The enum default is `None`, so a registered chain has to be activated here.
    _state.status = ChainStatus.Active;

    emit ChainRegistered(_chainId);
  }

  /// @inheritdoc IVoter
  function setChainStatus(uint256 _chainId, ChainStatus _status) external onlyRole(Roles.CHAIN_STATUS_ROLE) {
    _requireRegisteredChain(_chainId);
    if (_status == ChainStatus.None) revert InvalidStatus();
    ChainStatus _currentStatus = _voterStorage.chainStates[_chainId].status;
    if (_currentStatus == _status) revert ChainStatusUnchanged();
    // Suspended only exits to Active or Sunset. Under Paused the ceiling resumes accruing while the leaf
    // distributes nothing (its scalar is zeroed on entry) and no message path exists to resync it.
    if (_currentStatus == ChainStatus.Suspended && _status == ChainStatus.Paused) {
      revert InvalidChainStatusTransition();
    }
    // Sunset only exits to Suspended, the kill switch and the mandatory first leg of a reactivation: the
    // suspend closes the exit paths on both sides, so the in-flight deallocation set drains before any
    // resume (see the procedure on `IVoter.setChainStatus`).
    if (_currentStatus == ChainStatus.Sunset && _status != ChainStatus.Suspended) {
      revert InvalidChainStatusTransition();
    }
    // Settle under the current status so unbooked accrual lands in the right bucket.
    AllocationLogicLibrary.settleChain(_voterStorage, _chainId);
    _voterStorage.chainStates[_chainId].status = _status;
    // Every suspension re-authorizes emergency deallocation on its own; the resume-side checklist that keeps
    // a late leaf `Deallocate` from double-counting lives on `IVoter.setChainStatus`.
    if (_status == ChainStatus.Suspended) {
      _voterStorage.emergencyDeallocationAllowed[_chainId] = false;
      emit EmergencyDeallocationAllowedSet(_chainId, false);
    }
    emit ChainStatusSet(_chainId, _status);
  }

  /// @inheritdoc IVoter
  function setEmergencyDeallocationAllowed(uint256 _chainId, bool _allowed) external onlyRole(Roles.CHAIN_STATUS_ROLE) {
    _requireRegisteredChain(_chainId);
    _voterStorage.emergencyDeallocationAllowed[_chainId] = _allowed;
    emit EmergencyDeallocationAllowedSet(_chainId, _allowed);
  }

  /// @inheritdoc IVoter
  function setOperator(
    uint256 _tokenId,
    uint256 _chainId,
    address _operator,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable nonReentrant onlyAuthorizedForToken(_tokenId) {
    _requireRegisteredChain(_chainId);
    if (_voterStorage.chainStates[_chainId].status == ChainStatus.Paused) revert ChainPaused(_chainId);
    AllocationLogicLibrary.requireDestinationGas(_chainId, _gasLimit);

    emit OperatorSet(_tokenId, _chainId, _operator);

    _dispatchSingleChain({
      _msgType: IMessageOrchestrator.MessageType.SetOperator,
      _chainId: _chainId,
      _gasLimit: _gasLimit,
      _payload: abi.encode(
        OperatorMessage({
          tokenId: _tokenId, expiry: uint48(block.timestamp) + _voterStorage.messageLifetime, operator: _operator
        })
      ),
      _refundRecipient: _refundRecipient,
      _nativeValue: msg.value,
      _chargeDeallocationReturn: false
    });
  }

  /// @inheritdoc IVoter
  function spendSurplus(
    uint256 _chainId,
    uint256 _amount,
    address _recipient
  ) external nonReentrant onlyRole(Roles.GOVERNANCE_ROLE) {
    if (_recipient == address(0)) revert ZeroAddress();
    // Settling an unregistered chain would walk week boundaries from the epoch, so gate first.
    if (_chainId != CHAIN0 && !_voterStorage.chains.contains(_chainId)) revert ChainNotRegistered(_chainId);

    // Bring the pot current. A Suspended chain books its pending accrual into cumulativeSuspendedSurplus
    // and CHAIN0 books its lazily settled ceiling growth.
    AllocationLogicLibrary.settleChain(_voterStorage, _chainId);

    uint256 _spendable = spendableSurplus(_chainId);
    if (_amount > _spendable) revert InsufficientSurplus(_chainId, _spendable);

    _voterStorage.chainStates[_chainId].surplusSpent += _amount;

    MINTER.mint(_amount, _recipient);

    emit SurplusSpent(_chainId, _recipient, _amount);
  }

  /*//////////////////////////////////////////////////////////////
                                  VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  function isSuspended(uint256 _chainId) external view returns (bool _isSuspended) {
    _isSuspended = _voterStorage.chainStates[_chainId].status == ChainStatus.Suspended;
  }

  /// @inheritdoc IVoter
  function donatedBuffer(uint256 _chainId) external view returns (uint256 _amount) {
    _amount = _voterStorage.chainStates[_chainId].donatedBuffer;
  }

  /// @inheritdoc IVoter
  function allocating(uint256 _tokenId) external view returns (bool _isAllocating) {
    uint128 _committed = _voterStorage.tokenStates[_tokenId].committed;
    _isAllocating = _committed != 0 && _committed != _voterStorage.allocationChainAmounts[_tokenId][CHAIN0];
  }

  /// @inheritdoc IVoter
  /// @dev CHAIN0 never redeems so its whole ceiling is dead value. Other chains own two dead pots, the leaf
  ///      attested undistributed surplus and the accrual diverted while Suspended. The reported pot is clamped
  ///      to the remaining mint entitlement `ceiling - totalRedeemed`. `processRedeem` can store a report past
  ///      that entitlement when donations back the payout, and spending the excess would mint value the buffer
  ///      still owes future redeems, paying the same donated backing twice.
  /// @dev The subtraction cannot underflow. Every raw term is increment-only, redeems mint only inside
  ///      `ceiling - reportedSurplus - totalRedeemed` headroom so the clamped pot never decreases, and spends
  ///      are capped at the pot.
  function spendableSurplus(uint256 _chainId) public view returns (uint256 _spendable) {
    ChainState storage _state = _voterStorage.chainStates[_chainId];
    uint256 _pot = _chainId == CHAIN0
      ? _state.ceiling
      : Math.min(_state.reportedSurplus, _state.ceiling - _state.totalRedeemed) + _state.cumulativeSuspendedSurplus;
    _spendable = _pot - _state.surplusSpent;
  }

  /*//////////////////////////////////////////////////////////////
                            INTERNAL HELPERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Forwards a single-chain payload to the MessageOrchestrator with its native value.
   * @dev Each single-chain dispatch forwards the caller's full value; the orchestrator owns the split.
   * @param _msgType Message type stamped onto the envelope
   * @param _chainId Destination chain
   * @param _gasLimit Destination `handle()` gas budget
   * @param _payload Abi-encoded message body
   * @param _refundRecipient Address that receives any leftover IGP fee
   * @param _nativeValue Native value forwarded, covering any retained cost plus the fee
   * @param _chargeDeallocationReturn Whether the orchestrator keeps this chain's deallocation return cost
   */
  function _dispatchSingleChain(
    IMessageOrchestrator.MessageType _msgType,
    uint256 _chainId,
    uint256 _gasLimit,
    bytes memory _payload,
    address _refundRecipient,
    uint256 _nativeValue,
    bool _chargeDeallocationReturn
  ) internal {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: _chargeDeallocationReturn,
      payload: _payload
    });
    _dispatchBatch(_msgType, _dispatches, _nativeValue, _refundRecipient);
  }

  /**
   * @notice Hands a built batch to the MessageOrchestrator. The only place this contract calls it.
   * @dev One send site keeps the ordering rule checkable: a send is where the refund address regains control,
   *      so callers must have finished reading and writing before they reach here.
   * @dev Skips the call for an empty batch, a valid local-only allocation with nothing to ship.
   * @param _msgType Message type every entry in the batch carries
   * @param _dispatches Built dispatch entries
   * @param _nativeValue Native value forwarded, covering any retained cost plus the transport fees
   * @param _refundRecipient Address the transport refunds leftover fee to
   */
  function _dispatchBatch(
    IMessageOrchestrator.MessageType _msgType,
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches,
    uint256 _nativeValue,
    address _refundRecipient
  ) internal {
    if (_dispatches.length == 0) return;
    ORCHESTRATOR.dispatch{value: _nativeValue}(_msgType, _dispatches, _refundRecipient);
  }

  /**
   * @notice Rejects `CHAIN0` and unregistered chains; the shared precondition of the per-chain config setters.
   * @param _chainId Chain whose setter is being invoked
   */
  function _requireRegisteredChain(uint256 _chainId) internal view {
    if (_chainId == CHAIN0) revert Chain0NotConfigurable();
    if (!_voterStorage.chains.contains(_chainId)) revert ChainNotRegistered(_chainId);
  }

  /**
   * @notice Reads the tokenId's live VE stake, mirroring every field the VotingEscrow holds.
   * @dev VotingEscrow keeps `end == 0` for permanent stakes, so the fields are passed through unchanged.
   * @param _tokenId Token whose stake is being read
   * @return _staked Live VE staked AERO
   * @return _stakeEnd VE stake expiry, `0` for permanent stakes
   * @return _isPermanent True for a permanent stake
   */
  function _liveStake(uint256 _tokenId) internal view returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent) {
    IVotingEscrow.StakedBalance memory _stake = VOTING_ESCROW.staked(_tokenId);
    _staked = _stake.amount;
    _stakeEnd = _stake.end;
    _isPermanent = _stake.isPermanent;
  }

  /**
   * @notice Reads the live stake and reverts `StakeExpired` unless it is funded and unexpired.
   * @dev `staked == 0` catches a withdrawn token: `withdraw` zeroes the VE entry without burning the NFT, so the
   *      amount is the only tell. A permanent stake never expires; a decaying one expires at its `stakeEnd`.
   * @param _tokenId Token whose stake is being read
   * @return _staked Live VE staked AERO
   * @return _stakeEnd Week-aligned stake expiry, `0` for permanent stakes
   * @return _isPermanent True for a permanent stake
   */
  function _requireLiveStake(uint256 _tokenId)
    internal
    view
    returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent)
  {
    (_staked, _stakeEnd, _isPermanent) = _liveStake(_tokenId);
    if (_staked == 0 || (!_isPermanent && _stakeEnd <= block.timestamp)) revert StakeExpired();
  }

  /**
   * @notice Reads every live external input an allocation needs, once, before anything is sent.
   * @dev The one place these reads happen. A dispatch refunds leftover fee to a caller-supplied address, which
   *      can then reenter the VotingEscrow (`nonReentrant` here does not cover it), so re-reading the stake or
   *      rate after a send would let one call emit two messages describing different positions.
   * @param _tokenId veNFT id being allocated
   * @param _requireLive True to reject a withdrawn or expired stake; false to read it as-is
   * @return _snapshot Live stake plus the emission rate every payload in the call is priced with
   */
  function _allocationSnapshot(
    uint256 _tokenId,
    bool _requireLive
  ) internal view returns (AllocationSnapshot memory _snapshot) {
    (uint128 _staked, uint48 _stakeEnd, bool _isPermanent) =
      _requireLive ? _requireLiveStake(_tokenId) : _liveStake(_tokenId);
    _snapshot = AllocationSnapshot({
      staked: _staked, stakeEnd: _stakeEnd, emissionRate: MINTER.emissionRate(), isPermanent: _isPermanent
    });
  }
}
