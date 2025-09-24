// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {
  DEALLOC_GAUGE,
  MAXTIME,
  MIN_REDEEM_AMOUNT,
  PRECISION,
  WEEK,
  ZERO_GAUGE
} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {LeafStorage} from 'V3/voter/LeafVoterStorageLayout.sol';

/**
 * @title LeafAllocationLibrary
 * @notice LeafVoter's gauge-allocation and settlement logic, extracted as an externally linked library so the
 *         LeafVoter runtime stays under the EIP-170 size limit. Entries take the LeafVoter's state as one
 *         storage struct; auth and orchestrator sends stay in the LeafVoter, which passes the FactoryRegistry
 *         handle in so external reads stay lazy and run only on the paths that need them.
 */
library LeafAllocationLibrary {
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeCast for uint256;

  /**
   * @notice Everything the bridged gauge-allocation entry needs besides the snapshot and the gauge list,
   *         bundled so the entry takes a single memory argument instead of a stack-deep argument list.
   * @param tokenId The tokenId being allocated.
   * @param expiry Absolute root-stamped deadline; past it the vote reverts `AllocationExpired`.
   * @param emissionsPerVP Requested global emissions-per-VP scalar carried by the message.
   * @param refreshEmissionsPerVP Whether this message is the newest scalar the leaf has seen.
   * @param refreshShape Whether this message is the newest for the token's shape.
   */
  struct BridgedGaugeAllocationInput {
    uint256 tokenId;
    uint48 expiry;
    uint256 emissionsPerVP;
    bool refreshEmissionsPerVP;
    bool refreshShape;
  }

  /**
   * @notice Inputs one allocation pass carries besides the incoming list, bundled so `_processAllocation`
   *         keeps its non-viaIR stack headroom.
   * @param tokenId The tokenId to process.
   * @param newSnapshot Token state to apply against.
   * @param factoryRegistry FactoryRegistry the per-gauge emission caps are read from.
   */
  struct AllocationPassInput {
    uint256 tokenId;
    IVoterCommon.TokenSnapshot newSnapshot;
    IFactoryRegistry factoryRegistry;
  }

  /*//////////////////////////////////////////////////////////////
                          ALLOCATION ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The whole body of `LeafVoter.applyGaugeAllocations` past its access gates: validates the message,
   *         settles, refreshes the scalar and shape, and distributes the budget over the gauges.
   * @dev Returns the deallocation amount instead of dispatching it; the caller owns the orchestrator send.
   * @param _leafStorage LeafVoter state the distribution is applied to.
   * @param _input Message fields besides the snapshot and the gauge list.
   * @param _newSnapshot The message's VE shape.
   * @param _gauges Requested per-gauge allocation, strictly ascending.
   * @param _factoryRegistry FactoryRegistry queried for per-gauge emission caps and reward contracts.
   * @return _callParamsList One entry per touched gauge, checkpoints already driven.
   * @return _deallocAmount Sentinel amount, already taken off the chain budget; the caller dispatches it.
   */
  function applyGaugeAllocations(
    LeafStorage storage _leafStorage,
    BridgedGaugeAllocationInput memory _input,
    IVoterCommon.TokenSnapshot calldata _newSnapshot,
    IVoterCommon.GaugeAllocation[] calldata _gauges,
    IFactoryRegistry _factoryRegistry
  ) external returns (ILeafVoter.CheckpointData[] memory _callParamsList, uint128 _deallocAmount) {
    // Past its root-stamped deadline the vote reverts, so the transport stops treating it as deliverable.
    if (_input.expiry < block.timestamp) revert ILeafVoter.AllocationExpired();

    // A `CooldownActive` revert rolls the whole message back, so the reduction is only spent once the
    // distribution applies and the transport redelivers after the cooldown elapses.
    ILeafVoter.TokenState storage _tokenState = _leafStorage.tokenStates[_input.tokenId];
    _consumeCooldownReduction(_leafStorage, _input.tokenId, _tokenState.lastAllocated);

    // Root ships the list with no count cap, so the leaf is the only place it is bounded; an oversized list
    // would make the orchestrator's forward loop undeliverable.
    if (_gauges.length > _leafStorage.maxGauges) revert ILeafVoter.ExceedsMaxGauges();

    // The leaf is the authoritative budget enforcer: its budget can sit below root's booked amount in flight.
    // Until the budget lands this reverts and the transport redelivers.
    _requireExactBudget(_tokenState.chainAllocation, _gauges);

    // Close the accrual out at the old rate, before distributing and before the scalar override.
    _settleIndex(_leafStorage);

    // Gauge votes are far more frequent than chain allocations, so the newest one refreshes the scalar too; the
    // orchestrator's gate proves it is the newest the leaf has seen. Masked to zero while Suspended.
    if (_input.refreshEmissionsPerVP) _setEmissionsPerVP(_leafStorage, _input.emissionsPerVP);

    _tokenState.lastAllocated = uint48(block.timestamp);

    // `_resolveShape` runs in its own frame for non-viaIR stack room.
    (_callParamsList, _deallocAmount) = _distributeGauges({
      _leafStorage: _leafStorage,
      _tokenId: _input.tokenId,
      _gauges: _gauges,
      _snapshot: _resolveShape(_leafStorage, _input.tokenId, _input.refreshShape, _newSnapshot),
      _factoryRegistry: _factoryRegistry
    });
  }

  /**
   * @notice The whole body of `LeafVoter.allocateGauges` past its access gates: validates the list against the
   *         chain budget and status, settles, and distributes the budget over the gauges.
   * @dev Returns the deallocation amount instead of dispatching it; the caller owns the orchestrator send.
   * @param _leafStorage LeafVoter state the distribution is applied to.
   * @param _tokenId The tokenId whose chain budget is redistributed.
   * @param _gauges Requested per-gauge allocation, strictly ascending.
   * @param _factoryRegistry FactoryRegistry queried for per-gauge emission caps and reward contracts.
   * @return _deallocAmount Sentinel amount, already taken off the chain budget; the caller dispatches it.
   */
  function allocateGauges(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    IVoterCommon.GaugeAllocation[] calldata _gauges,
    IFactoryRegistry _factoryRegistry
  ) external returns (uint128 _deallocAmount) {
    ILeafVoter.TokenState storage _tokenState = _leafStorage.tokenStates[_tokenId];

    // 1. Same reduction source as the bridged path, so a `reduceCooldown` grant helps a local vote too.
    _consumeCooldownReduction(_leafStorage, _tokenId, _tokenState.lastAllocated);

    // 2. The vote books the LATEST shape: when a chain message stashed a fresher one, `_processAllocation`
    //    unwinds at the stored shape and re-applies at this one, leaving latest == stored. Only seeding is
    //    checked here; expiry is gated after list validation, where the list composition is known.
    IVoterCommon.TokenSnapshot memory _snapshot = _leafStorage.latestTokenSnapshot[_tokenId];
    if (_snapshot.staked == 0) revert ILeafVoter.StakeSnapshotMissing();

    // 3. Validate the list in one pass: at most `maxGauges` entries, strictly ascending, non-zero amounts, and a
    //    total matching `chainAllocation`.
    uint256 _gaugesLength = _gauges.length;
    if (_gaugesLength > _leafStorage.maxGauges) revert ILeafVoter.ExceedsMaxGauges();
    address _prevGauge = address(0);
    uint128 _total = 0;
    // slither-disable-next-line uninitialized-local
    bool _hasDealloc;
    for (uint256 _i; _i < _gaugesLength; ++_i) {
      IVoterCommon.GaugeAllocation calldata _allocation = _gauges[_i];
      // Strictly ascending: deduplicates and rejects address(0), except as the first entry, where it is the
      // `ZERO_GAUGE` idle sink and still the lowest address.
      if (_i != 0 && _allocation.gauge <= _prevGauge) revert IVoterCommon.GaugesNotStrictlyAscending();
      if (_allocation.allocated == 0) revert IVoterCommon.ZeroAllocation();
      if (_allocation.gauge == DEALLOC_GAUGE) _hasDealloc = true;
      _total += _allocation.allocated;
      _prevGauge = _allocation.gauge;
    }
    uint128 _budget = _tokenState.chainAllocation;
    // The vote must allocate the whole budget; idle VP is an explicit `ZERO_GAUGE` entry, never a backfill.
    if (_total != _budget) revert ILeafVoter.ChainAllocationMismatch();

    // An expired stake can no longer back weight and a sunset chain takes no new placement, so in either
    // case the only local vote left is the lone sentinel return. Mirrors root's dispatch gate; a bridged
    // vote stays ungated and lands at rate zero instead, since a delivery revert would strand the message.
    bool _deallocOnly = _gaugesLength == 1 && _hasDealloc;
    if (!_deallocOnly) {
      if (!_snapshot.isPermanent && _snapshot.stakeEnd <= block.timestamp) revert IVoterCommon.StakeExpired();
      if (_leafStorage.chainStatus == IVoterCommon.ChainStatus.Sunset) revert IVoterCommon.SunsetDeallocOnly();
    }

    // 4. Anchor the cooldown at this allocation.
    _tokenState.lastAllocated = uint48(block.timestamp);

    // 5. Bring the chain accumulator current; the local path never overrides `emissionsPerVP`.
    _settleIndex(_leafStorage);

    // 6. Distribute, checkpoint and emit.
    (, _deallocAmount) = _distributeGauges(_leafStorage, _tokenId, _gauges, _snapshot, _factoryRegistry);
  }

  /**
   * @notice The whole body of `LeafVoter.applyChainAllocation` past its access gate: settles, refreshes the
   *         scalar and shape, grows the chain budget and parks the delta on the `ZERO_GAUGE` sink.
   * @param _leafStorage LeafVoter state the allocation is applied to.
   * @param _tokenId The tokenId whose chain budget grows.
   * @param _allocationDelta Voting power added to the chain budget.
   * @param _emissionsPerVP Requested global emissions-per-VP scalar carried by the message.
   * @param _refreshEmissionsPerVP Whether this message is the newest scalar the leaf has seen.
   * @param _refreshShape Whether this message is the newest for the token's shape.
   * @param _snapshot The message's VE shape.
   */
  function applyChainAllocation(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint256 _emissionsPerVP,
    bool _refreshEmissionsPerVP,
    bool _refreshShape,
    IVoterCommon.TokenSnapshot calldata _snapshot
  ) external {
    // Close the accrual out at the old rate. Unconditional: the `ZERO_GAUGE` park below needs a current index.
    _settleIndex(_leafStorage);

    // Only the newest message carries the live scalar. The setter masks it to zero while Suspended, where root
    // sends the period to surplus, so no unfunded emissions accrue.
    if (_refreshEmissionsPerVP) _setEmissionsPerVP(_leafStorage, _emissionsPerVP);

    // Only the token's newest message advances the shape, so a stale one cannot roll it back.
    if (_refreshShape) _leafStorage.latestTokenSnapshot[_tokenId] = _snapshot;

    // While no weight is booked, keep the stored shape at the latest so the park below books a fresh one. Once
    // weight exists it stays at what it was applied with, or a later unwind would use the wrong stakeEnd.
    if (_leafStorage.allocatedGauges[_tokenId].length() == 0 && _leafStorage.allocations[_tokenId][ZERO_GAUGE] == 0) {
      _leafStorage.tokenSnapshot[_tokenId] = _leafStorage.latestTokenSnapshot[_tokenId];
    }

    // Additive, so order does not matter against the leaf-first `deallocate` decrement and a reordered message
    // cannot resurrect a deallocated budget. `lastAllocated` is untouched: the cooldown is gauge-only.
    uint128 _newBudget = _leafStorage.tokenStates[_tokenId].chainAllocation + _allocationDelta;
    _leafStorage.tokenStates[_tokenId].chainAllocation = _newBudget;

    // Park it on `ZERO_GAUGE` (cap 0) with the STORED shape, so its emission share goes to surplus and
    // `Σ gauge weight (incl ZERO_GAUGE) == chainAllocation` holds under one shape a later vote can unwind.
    // Swap the park to the new total: slope flooring makes per-park triples non-additive, so the sink must
    // hold `contribution(total)` for the aggregate unwind in `_processAllocation` to cancel exactly.
    if (_allocationDelta > 0) {
      IVoterCommon.TokenSnapshot memory _parkShape = _leafStorage.tokenSnapshot[_tokenId];
      uint128 _oldParked = _leafStorage.allocations[_tokenId][ZERO_GAUGE];
      _swapZeroGaugePark({
        _leafStorage: _leafStorage,
        _tokenId: _tokenId,
        _oldTotal: _oldParked,
        _newTotal: _oldParked + _allocationDelta,
        _oldEnd: _parkShape.stakeEnd,
        _newEnd: _parkShape.stakeEnd,
        _oldIsPermanent: _parkShape.isPermanent,
        _newIsPermanent: _parkShape.isPermanent
      });
    }

    emit ILeafVoter.ChainAllocated(_tokenId, _allocationDelta, _newBudget, _leafStorage.emissionsPerVP);
  }

  /**
   * @notice The whole body of `LeafVoter.applyEmergencyDeallocation` past its access gates: settles, unwinds
   *         every gauge and re-parks the surviving budget on the `ZERO_GAUGE` sink.
   * @param _leafStorage LeafVoter state the deallocation is applied to.
   * @param _tokenId The tokenId root drained.
   * @param _amount Voting power root drained to CHAIN0.
   * @param _factoryRegistry FactoryRegistry queried for per-gauge emission caps and reward contracts.
   */
  function applyEmergencyDeallocation(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    uint128 _amount,
    IFactoryRegistry _factoryRegistry
  ) external {
    // Root already drained `_amount` to CHAIN0 while Suspended (see `Voter.emergencyDeallocate`).
    _settleIndex(_leafStorage);
    uint128 _budget = _leafStorage.tokenStates[_tokenId].chainAllocation;
    // Subtract rather than zero, so order does not matter against pre-drain `AllocateChain` deltas. A post-resume
    // delta over-subtracts, so governance must not resume before this lands (see `Voter.setChainStatus`).
    uint128 _shortfall = _amount >= _budget ? 0 : _budget - _amount;
    // Unwind every gauge and re-park the survivor on the sink; an empty list clears the token. No sentinel, so
    // this path sends no deallocation return.
    IVoterCommon.GaugeAllocation[] memory _idle = new IVoterCommon.GaugeAllocation[](_shortfall > 0 ? 1 : 0);
    if (_shortfall > 0) {
      _idle[0] = IVoterCommon.GaugeAllocation({gauge: ZERO_GAUGE, allocated: _shortfall, data: ''});
    }
    // The latest shape, not the stored one: an expired stored shape would park the survivor as zero weight and
    // leave `chainAllocation` unbacked. `_processAllocation` still unwinds the old gauges at the stored shape.
    (ILeafVoter.CheckpointData[] memory _callParamsList,) = _processAllocation(
      _leafStorage,
      AllocationPassInput({
        tokenId: _tokenId, newSnapshot: _leafStorage.latestTokenSnapshot[_tokenId], factoryRegistry: _factoryRegistry
      }),
      _idle
    );

    // Match root's drain: the budget becomes the surviving amount, now parked on `ZERO_GAUGE`. Written before the
    // checkpoints so every effect lands ahead of the external calls they make.
    _leafStorage.tokenStates[_tokenId].chainAllocation = _shortfall;

    _driveCheckpoints(_leafStorage, _tokenId, _callParamsList, _factoryRegistry);

    emit ILeafVoter.EmergencyDeallocationApplied(_tokenId);
  }

  /*//////////////////////////////////////////////////////////////
                       GAUGE LIFECYCLE ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The whole body of `LeafVoter.registerGauge` past its access gate: seeds the gauge's cursors at the
   *         settled chain accumulators.
   * @param _leafStorage LeafVoter state the gauge is registered in.
   * @param _gauge Gauge to register. Reverts `ZeroAddress` for the zero address.
   * @param _activate Whether the gauge starts activated.
   */
  function registerGauge(LeafStorage storage _leafStorage, address _gauge, bool _activate) external {
    if (_gauge == address(0)) revert IVoterCommon.ZeroAddress();
    ILeafVoter.GaugeState storage _state = _leafStorage.gaugeStates[_gauge];
    if (_state.isRegistered) revert ILeafVoter.GaugeAlreadyRegistered();

    // Bring the chain accumulator current so the gauge anchors at now. A no-op
    // when a prior message pre-settled past block.timestamp, in which case the
    // existing logical cursor seeds the gauge.
    _settleIndex(_leafStorage);

    _state.isRegistered = true;
    _state.isActivated = _activate;
    _state.lastSettlement = _leafStorage.lastSettlement;
    _state.lastIndex = _leafStorage.index;
    _state.lastTimeIndex = _leafStorage.timeIndex;
    _state.point.ts = _leafStorage.lastSettlement;

    emit ILeafVoter.GaugeRegistered(_gauge, _activate, _leafStorage.lastSettlement);
    if (_activate) {
      emit ILeafVoter.GaugeActivated(_gauge, _leafStorage.lastSettlement);
    }
  }

  /**
   * @notice The whole body of `LeafVoter.activateGauge` past its access gate: settles the gauge to now, then
   *         activates it.
   * @param _leafStorage LeafVoter state the gauge is activated in.
   * @param _gauge Gauge to activate. Reverts `GaugeNotRegistered` for an unregistered gauge or the sink.
   * @param _factoryRegistry FactoryRegistry the gauge's emission cap is read from.
   */
  function activateGauge(LeafStorage storage _leafStorage, address _gauge, IFactoryRegistry _factoryRegistry) external {
    ILeafVoter.GaugeState storage _state = _leafStorage.gaugeStates[_gauge];
    if (!_state.isRegistered || _gauge == ZERO_GAUGE) revert ILeafVoter.GaugeNotRegistered();
    if (_state.isActivated) revert ILeafVoter.GaugeAlreadyActivated();

    // Inactive gauges are never routable, so the registration-to-activation
    // window is weightless. Settling still advances the gauge cursor to now,
    // anchoring post-activation accrual at activation instead of registration.
    _settleIndex(_leafStorage);
    _settleGauge(_leafStorage, _gauge, _factoryRegistry);

    // Set after the settle so the persisted struct copy does not overwrite it.
    _state.isActivated = true;
    emit ILeafVoter.GaugeActivated(_gauge, _leafStorage.lastSettlement);
  }

  /**
   * @notice The whole body of `LeafVoter.settleGauge`: settles the chain accumulators and the gauge, then
   *         returns the gauge's cumulative reward share.
   * @param _leafStorage LeafVoter state the gauge is settled in.
   * @param _gauge Gauge to settle. Any input address is accepted; an unregistered one returns zero unsettled.
   * @param _factoryRegistry FactoryRegistry the gauge's emission cap is read from.
   * @return _cumulativeRewardShare The gauge's settled cumulative reward share (`ceiling`).
   */
  function settleGauge(
    LeafStorage storage _leafStorage,
    address _gauge,
    IFactoryRegistry _factoryRegistry
  ) external returns (uint256 _cumulativeRewardShare) {
    // 1. Return zero without settling, so the entrypoint never reverts on any input address. An unregistered
    //    gauge has no seeded cursor, so a walk would step from the unix epoch.
    if (!_leafStorage.gaugeStates[_gauge].isRegistered) return 0;

    // 2. Settle the accumulator so the gauge walks against a current index.
    _settleIndex(_leafStorage);

    // 3. Accrues the gauge's cumulative reward share (`ceiling`) with no call into the gauge: the caller takes
    //    the delta since its own cursor from the returned cumulative.
    _settleGauge(_leafStorage, _gauge, _factoryRegistry);

    _cumulativeRewardShare = _leafStorage.gaugeStates[_gauge].ceiling;
  }

  /**
   * @notice The whole body of `LeafVoter.forfeitEmissions` past its reentrancy gate: clamps and accrues the
   *         surplus a gauge reports.
   * @param _leafStorage LeafVoter state the surplus is accrued in.
   * @param _gauge Gauge that reported the surplus. Reverts `GaugeNotRegistered` for an unregistered gauge.
   * @param _amount Surplus the gauge cannot distribute (Idle Gauge, Early Exit).
   */
  function forfeitEmissions(LeafStorage storage _leafStorage, address _gauge, uint128 _amount) external {
    if (!_leafStorage.gaugeStates[_gauge].isRegistered) revert ILeafVoter.GaugeNotRegistered();

    // The emitted amount can be below `_amount`: the helper clamps to the gauge's claimable headroom.
    uint128 _accrued = _accrueReportedSurplus(_leafStorage, _gauge, _amount);
    emit ILeafVoter.EmissionsForfeited(_gauge, _accrued);
  }

  /*//////////////////////////////////////////////////////////////
                    EMISSIONS AND REWARDS ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The accounting of `LeafVoter.mintEmissions`: validates the claim against the gauge's settled
   *         entitlement and books it as claimed. The caller mints and forwards to the emissions handler.
   * @param _leafStorage LeafVoter state the claim is booked in.
   * @param _gauge Gauge claiming its emissions. Reverts `GaugeNotRegistered` for an unregistered gauge.
   * @param _amounts Per-recipient amounts summed into the claim. The caller validates the recipients array.
   * @return _amountToMint Total claim booked; zero means nothing to mint.
   */
  function mintEmissions(
    LeafStorage storage _leafStorage,
    address _gauge,
    uint128[] calldata _amounts
  ) external returns (uint128 _amountToMint) {
    ILeafVoter.GaugeState storage _state = _leafStorage.gaugeStates[_gauge];
    if (!_state.isRegistered) revert ILeafVoter.GaugeNotRegistered();

    uint256 _amountsLength = _amounts.length;
    for (uint256 _i; _i < _amountsLength; ++_i) {
      _amountToMint += _amounts[_i];
    }
    if (_amountToMint == 0) return 0;

    // A claim cannot exceed the settled entitlement left after prior claims and surplus. The gauge settles and
    // flushes its surplus through `forfeitEmissions` in the same transaction, so this never reads a stale one.
    uint128 _claimable = _state.ceiling - _state.claimed - _state.surplus;
    if (_amountToMint > _claimable) revert ILeafVoter.CeilingExceeded();
    _state.claimed += _amountToMint;
  }

  /**
   * @notice The accounting of `LeafVoter.redeem`: validates, burns the receipt tokens and builds the redeem
   *         payload. The caller owns the orchestrator dispatch.
   * @param _leafStorage LeafVoter state the surplus aggregate is read from.
   * @param _receiptToken Per-chain `ReceiptToken` burned on redeem.
   * @param _amount Receipt amount to redeem; reverts `AmountTooLow` under `MIN_REDEEM_AMOUNT`.
   * @param _recipient Root-chain recipient of the redeemed amount.
   * @return _payload Encoded `RedeemMessageBody` for the caller to dispatch.
   */
  function redeem(
    LeafStorage storage _leafStorage,
    IReceiptToken _receiptToken,
    uint256 _amount,
    address _recipient
  ) external returns (bytes memory _payload) {
    if (_amount < MIN_REDEEM_AMOUNT) revert ILeafVoter.AmountTooLow();
    if (_recipient == address(0)) revert IVoterCommon.ZeroAddress();

    _receiptToken.burn(msg.sender, _amount);

    IVoterCommon.RedeemMessageBody memory _body = IVoterCommon.RedeemMessageBody({
      amount: _amount, recipient: _recipient, surplusAccrued: _leafStorage.surplusAccrued
    });
    _payload = abi.encode(_body);
  }

  /**
   * @notice The claim loops of `LeafVoter.claimRewards`: claims fees and incentives from lists of
   *         VotingRewardsManagers. The caller owns the authorization gates.
   * @param _tokenId The veNFT token ID to claim for.
   * @param _recipient Address that receives claimed rewards.
   * @param _feeClaims Fee claim requests to forward.
   * @param _incentiveClaims Incentive claim requests to forward.
   * @param _factoryRegistry FactoryRegistry each VotingRewardsManager is validated against.
   */
  function claimRewards(
    uint256 _tokenId,
    address _recipient,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims,
    IFactoryRegistry _factoryRegistry
  ) external {
    _claimFees(_tokenId, _recipient, _feeClaims, _factoryRegistry);
    _claimIncentives(_tokenId, _recipient, _incentiveClaims, _factoryRegistry);
  }

  /*//////////////////////////////////////////////////////////////
                         CHAIN STATUS ENTRY
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The state change of `LeafVoter.setChainStatus`: settles at the old rate, stores the status and masks
   *         the scalar. The caller owns the transition-matrix checks.
   * @param _leafStorage LeafVoter state the status is written to.
   * @param _status Validated status to store.
   */
  function applyChainStatus(LeafStorage storage _leafStorage, IVoterCommon.ChainStatus _status) external {
    // Settle up to the flip at the old rate; the flip timestamp is the accrual boundary.
    _settleIndex(_leafStorage);

    _leafStorage.chainStatus = _status;

    // Root sends a suspended or sunset chain's emissions to surplus, so park the scalar at zero and the leaf
    // stops crediting gauges for the same period, until the first dispatch after a resume to Active. Status
    // written first, so the setter's mask sees the new status.
    if (_status == IVoterCommon.ChainStatus.Suspended || _status == IVoterCommon.ChainStatus.Sunset) {
      _setEmissionsPerVP(_leafStorage, 0);
    }
  }

  /*//////////////////////////////////////////////////////////////
                             VIEW ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice The whole body of `LeafVoter.projectedCumulativeRewardShare`: the settle walk, read-only, with an
   *         unsettled tail projected at the live rate.
   * @param _leafStorage LeafVoter state the projection reads.
   * @param _gauge Gauge to project. An unregistered gauge returns zero.
   * @param _factoryRegistry FactoryRegistry the gauge's emission cap is read from.
   * @return _cumulativeRewardShare The gauge's cumulative reward share projected to now.
   */
  function projectedCumulativeRewardShare(
    LeafStorage storage _leafStorage,
    address _gauge,
    IFactoryRegistry _factoryRegistry
  ) external view returns (uint256 _cumulativeRewardShare) {
    ILeafVoter.GaugeState memory _state = _leafStorage.gaugeStates[_gauge];
    // An unregistered gauge never accrues, same zero `settleGauge` returns.
    if (!_state.isRegistered) return 0;

    uint48 _to = uint48(block.timestamp);
    if (_to <= _state.lastSettlement) return _state.ceiling;

    // The walk `_settleGauge` runs, read-only: an unsettled tail is projected at the live rate.
    uint128 _cap = _gauge == ZERO_GAUGE ? 0 : _factoryRegistry.emissionCap(_gauge);
    (uint128 _effectiveShare,) = _walkGauge(_leafStorage, _gauge, _cap, _state, _to);
    _cumulativeRewardShare = _state.ceiling + _effectiveShare;
  }

  /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Apply `(_allocated, _stakeEnd)` to `_gauge`'s point and slope schedule, evaluated at
   *         `lastSettlement`.
   * @dev A zero contribution has no effect. A caller that needs to gate on one resolves `contribution` itself
   *      before calling.
   * @param _leafStorage LeafVoter state the gauge point and slope schedule live in.
   * @param _gauge Gauge whose state is being written.
   * @param _allocated AERO amount allocated to the gauge.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   */
  function applyContribution(
    LeafStorage storage _leafStorage,
    address _gauge,
    uint128 _allocated,
    uint48 _stakeEnd,
    bool _isPermanent
  ) internal {
    (int128 _bias, int128 _slope, int128 _perm) = contribution(_leafStorage, _allocated, _stakeEnd, _isPermanent);

    IVoterCommon.Point storage _gaugePoint = _leafStorage.gaugeStates[_gauge].point;
    if (_isPermanent) {
      _gaugePoint.permanentStakeBalance += uint128(_perm);
    } else {
      _gaugePoint.bias += _bias;
      _gaugePoint.slope += _slope;
      _leafStorage.gaugeSlopeChanges[_gauge][_stakeEnd] += _slope;
    }
  }

  /**
   * @notice Reverse `(_allocated, _stakeEnd)` on `_gauge`'s point and slope schedule, evaluated at
   *         `lastSettlement`.
   * @dev Sign-flipped mirror of `applyContribution`; a pair carrying the same `_allocated` cancels exactly.
   * @param _leafStorage LeafVoter state the gauge point and slope schedule live in.
   * @param _gauge Gauge whose state is being written.
   * @param _allocated AERO amount the gauge currently holds for this position.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   */
  function unwindContribution(
    LeafStorage storage _leafStorage,
    address _gauge,
    uint128 _allocated,
    uint48 _stakeEnd,
    bool _isPermanent
  ) internal {
    (int128 _bias, int128 _slope, int128 _perm) = contribution(_leafStorage, _allocated, _stakeEnd, _isPermanent);

    IVoterCommon.Point storage _gaugePoint = _leafStorage.gaugeStates[_gauge].point;
    if (_isPermanent) {
      _gaugePoint.permanentStakeBalance -= uint128(_perm);
    } else {
      _gaugePoint.bias -= _bias;
      _gaugePoint.slope -= _slope;
      _leafStorage.gaugeSlopeChanges[_gauge][_stakeEnd] -= _slope;
    }
  }

  /**
   * @notice Derive the signed `(bias, slope, perm)` contribution of an AERO allocation.
   * @dev `_isPermanent` takes the permanent path. Otherwise `_stakeEnd <= lastSettlement` returns the zero
   *      triple: the walk already fired the scheduled slope reduction (or the stake is withdrawn, `stakeEnd 0`),
   *      so a removal cannot over-subtract.
   * @dev `_slope = _allocated / MAXTIME` truncates, so an allocation below `MAXTIME` wei (~1.26e-10 AERO at 18
   *      decimals) rounds to zero weight while still using storage and triggering a dispatch. Matches Curve VE.
   * @param _leafStorage LeafVoter state `lastSettlement` is read from.
   * @param _allocated AERO amount allocated to a chain.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   * @return _bias Time-decaying contribution.
   * @return _slope Decay rate contribution.
   * @return _perm Non-decaying contribution from permanent stakes.
   */
  function contribution(
    LeafStorage storage _leafStorage,
    uint128 _allocated,
    uint48 _stakeEnd,
    bool _isPermanent
  ) internal view returns (int128 _bias, int128 _slope, int128 _perm) {
    if (_isPermanent) {
      _perm = SafeCastLibrary.toInt128(_allocated);
      return (_bias, _slope, _perm);
    }
    uint48 _asOf = _leafStorage.lastSettlement;
    if (_stakeEnd <= _asOf) return (_bias, _slope, _perm);

    _slope = SafeCastLibrary.toInt128(_allocated / MAXTIME);
    _bias = _slope * int128(uint128(_stakeEnd - _asOf));
  }

  /*//////////////////////////////////////////////////////////////
                          PRIVATE HELPERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Clamp the surplus a gauge reports through `forfeitEmissions` to the claimable headroom, then flush
   *         it into the gauge's surplus and the chain aggregate.
   * @param _leafStorage LeafVoter state the surplus is accrued in.
   * @param _gauge Gauge that reported the surplus.
   * @param _reported Surplus the gauge cannot distribute (Idle Gauge, Early Exit).
   * @return _accrued Surplus accrued after clamping to the claimable headroom.
   */
  function _accrueReportedSurplus(
    LeafStorage storage _leafStorage,
    address _gauge,
    uint128 _reported
  ) private returns (uint128 _accrued) {
    ILeafVoter.GaugeState storage _state = _leafStorage.gaugeStates[_gauge];
    uint128 _maxReportable = _state.ceiling - _state.claimed - _state.surplus;
    if (_reported > _maxReportable) _reported = _maxReportable;
    _state.surplus += _reported;
    _leafStorage.surplusAccrued += _reported;
    _accrued = _reported;
  }

  /**
   * @notice Claims fees from a list of VotingRewardsManagers.
   * @dev Unregistered managers emit `FeeClaimFailed` and are skipped. Registered-manager reverts bubble so an
   *      inbound claim message can be retried.
   * @param _tokenId The veNFT token ID to claim for.
   * @param _recipient Address that receives claimed fees.
   * @param _feeClaims Fee claim requests to forward.
   * @param _factoryRegistry FactoryRegistry each VotingRewardsManager is validated against.
   */
  function _claimFees(
    uint256 _tokenId,
    address _recipient,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    IFactoryRegistry _factoryRegistry
  ) private {
    uint256 _feeClaimsLength = _feeClaims.length;
    for (uint256 _i; _i < _feeClaimsLength; ++_i) {
      ILeafVoter.FeeClaim calldata _feeClaim = _feeClaims[_i];
      address _votingRewardsManager = _feeClaim.votingRewardsManager;
      if (_factoryRegistry.rewardsToGauge(_votingRewardsManager) == address(0)) {
        emit ILeafVoter.FeeClaimFailed(_tokenId, _votingRewardsManager, _feeClaim.maxCheckpoints);
        continue;
      }

      IVotingRewardsManager(_votingRewardsManager)
        .claimFees({_tokenId: _tokenId, _recipient: _recipient, _maxCheckpoints: _feeClaim.maxCheckpoints});
      emit ILeafVoter.FeeClaimSucceeded(_tokenId, _votingRewardsManager, _recipient, _feeClaim.maxCheckpoints);
    }
  }

  /**
   * @notice Claims incentives from a list of VotingRewardsManagers.
   * @dev Unregistered managers emit `IncentiveClaimFailed` and are skipped. Registered-manager reverts bubble so an
   *      inbound claim message can be retried.
   * @param _tokenId The veNFT token ID to claim for.
   * @param _recipient Address that receives claimed incentives.
   * @param _incentiveClaims Incentive claim requests to forward.
   * @param _factoryRegistry FactoryRegistry each VotingRewardsManager is validated against.
   */
  function _claimIncentives(
    uint256 _tokenId,
    address _recipient,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims,
    IFactoryRegistry _factoryRegistry
  ) private {
    uint256 _incentiveClaimsLength = _incentiveClaims.length;
    for (uint256 _i; _i < _incentiveClaimsLength; ++_i) {
      ILeafVoter.IncentiveClaim calldata _incentiveClaim = _incentiveClaims[_i];
      address _votingRewardsManager = _incentiveClaim.votingRewardsManager;
      if (_factoryRegistry.rewardsToGauge(_votingRewardsManager) == address(0)) {
        emit ILeafVoter.IncentiveClaimFailed({
          _tokenId: _tokenId,
          _votingRewardsManager: _votingRewardsManager,
          _programId: _incentiveClaim.programId,
          _maxCheckpoints: _incentiveClaim.maxCheckpoints
        });
        continue;
      }

      IVotingRewardsManager(_votingRewardsManager)
        .claimIncentives({
        _tokenId: _tokenId,
        _recipient: _recipient,
        _programId: _incentiveClaim.programId,
        _maxCheckpoints: _incentiveClaim.maxCheckpoints
      });
      emit ILeafVoter.IncentiveClaimSucceeded({
        _tokenId: _tokenId,
        _votingRewardsManager: _votingRewardsManager,
        _programId: _incentiveClaim.programId,
        _recipient: _recipient,
        _maxCheckpoints: _incentiveClaim.maxCheckpoints
      });
    }
  }

  /**
   * @notice Resolve the shape a gauge distribution books at, taking the message shape when it is fresh.
   * @dev A stale message keeps the stored `latestTokenSnapshot`, so an outdated position never comes back.
   * @param _leafStorage LeafVoter state the stored shape lives in.
   * @param _tokenId The tokenId being allocated.
   * @param _refreshShape Whether this message is the newest for the token's shape.
   * @param _newSnapshot The message's VE shape.
   * @return _shape The shape to book the distribution at.
   */
  function _resolveShape(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    bool _refreshShape,
    IVoterCommon.TokenSnapshot calldata _newSnapshot
  ) private returns (IVoterCommon.TokenSnapshot memory _shape) {
    if (_refreshShape) {
      _leafStorage.latestTokenSnapshot[_tokenId] = _newSnapshot;
      _shape = _newSnapshot;
    } else {
      _shape = _leafStorage.latestTokenSnapshot[_tokenId];
    }
  }

  /**
   * @notice Enforce the gauge-allocation cooldown for `_tokenId`, applying and consuming its accumulated one-shot
   *         reduction. Shared by the bridged and the local path.
   * @dev Spends only the shortfall: the reduction is clamped to the cooldown still remaining, so a vote past the
   *      cooldown spends nothing and the rest is kept for one that needs it.
   * @dev Reverts `CooldownActive` before any state change, so a reverted message spends nothing.
   * @param _leafStorage LeafVoter state the cooldown config and reduction live in.
   * @param _tokenId Token whose cooldown is being gated.
   * @param _lastAllocated Timestamp of the token's prior gauge allocation.
   */
  function _consumeCooldownReduction(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    uint48 _lastAllocated
  ) private {
    uint48 _allocationCooldown = _leafStorage.allocationCooldown;
    uint48 _now = uint48(block.timestamp);
    // Subtract rather than compare against `_lastAllocated + _allocationCooldown`, which can overflow `uint48`.
    uint48 _elapsed = _now > _lastAllocated ? _now - _lastAllocated : 0;
    uint48 _remainingCooldown = _elapsed < _allocationCooldown ? _allocationCooldown - _elapsed : 0;

    if (_remainingCooldown == 0) return;

    uint48 _accumulated = _leafStorage.accumulatedCooldownReduction[_tokenId];
    if (_accumulated < _remainingCooldown) revert ILeafVoter.CooldownActive();

    _leafStorage.accumulatedCooldownReduction[_tokenId] = _accumulated - _remainingCooldown;
  }

  /**
   * @notice Shared tail of the local and bridged gauge-allocation paths: distribute, checkpoint, emit.
   * @dev The callers own everything before this — auth, validation, shape source, funding, scalar refresh — and
   *      dispatch the returned deallocation amount after this returns.
   * @param _leafStorage LeafVoter state the distribution is applied to.
   * @param _tokenId The tokenId being allocated.
   * @param _gauges The requested per-gauge allocation.
   * @param _snapshot The shape to book against: stored for the local path, from the message for the bridged one.
   * @param _factoryRegistry FactoryRegistry queried for per-gauge emission caps and reward contracts.
   * @return _callParamsList One entry per touched gauge, checkpoints already driven.
   * @return _deallocAmount Sentinel amount, already taken off the chain budget; the caller dispatches it.
   */
  function _distributeGauges(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    IVoterCommon.GaugeAllocation[] calldata _gauges,
    IVoterCommon.TokenSnapshot memory _snapshot,
    IFactoryRegistry _factoryRegistry
  ) private returns (ILeafVoter.CheckpointData[] memory _callParamsList, uint128 _deallocAmount) {
    (_callParamsList, _deallocAmount) = _processAllocation(
      _leafStorage,
      AllocationPassInput({tokenId: _tokenId, newSnapshot: _snapshot, factoryRegistry: _factoryRegistry}),
      _gauges
    );
    _driveCheckpoints(_leafStorage, _tokenId, _callParamsList, _factoryRegistry);
    emit ILeafVoter.GaugesAllocated(_tokenId, _gauges, _leafStorage.emissionsPerVP);
  }

  /**
   * @notice Apply an allocation pass for a tokenId: overwrite the snapshot, then process the union of the prior
   *         allocated set and the incoming allocations. Used by the bridged and the local path.
   * @dev Makes no external call beyond the emission-cap reads. Returns the checkpoint entries and the
   *      deallocation amount for the caller to drive and dispatch after it returns.
   * @dev Unregistered or unactivated targets, and any `ZERO_GAUGE` idle entry, sum into one `ZERO_GAUGE` write.
   * @param _leafStorage LeafVoter state the pass is applied to.
   * @param _input Pass inputs besides the incoming list.
   * @param _newAllocations Incoming allocations, strictly ascending. Idle VP is an explicit `ZERO_GAUGE` entry.
   * @return _callParamsList One entry per touched gauge, trimmed to the entries written.
   * @return _deallocAmount Sentinel amount, already taken off the chain budget here.
   */
  function _processAllocation(
    LeafStorage storage _leafStorage,
    AllocationPassInput memory _input,
    IVoterCommon.GaugeAllocation[] memory _newAllocations
  ) private returns (ILeafVoter.CheckpointData[] memory _callParamsList, uint128 _deallocAmount) {
    IVoterCommon.TokenSnapshot memory _oldSnapshot = _leafStorage.tokenSnapshot[_input.tokenId];
    IVoterCommon.TokenSnapshot memory _newSnapshot = _input.newSnapshot;

    // Copy taken at entry: loop 1 writes to the set do not reach it, so loop 2 sees the gauges present at entry.
    address[] memory _oldGauges = _leafStorage.allocatedGauges[_input.tokenId].values();

    ILeafVoter.AllocationContext memory _context = ILeafVoter.AllocationContext({
      tokenId: _input.tokenId,
      oldSnapshot: _oldSnapshot,
      newSnapshot: _newSnapshot,
      expired: !_newSnapshot.isPermanent && _newSnapshot.stakeEnd <= _leafStorage.lastSettlement,
      canVoteForZeroCapGauges: _leafStorage.tokenStates[_input.tokenId].canVoteForZeroCapGauges,
      list: new ILeafVoter.CheckpointData[](_oldGauges.length + _newAllocations.length),
      entryCount: 0,
      zeroGaugeAllocation: 0,
      deallocAmount: 0
    });

    // Contributions resolve against the cached copies, so the write can happen anywhere here. Skipping the
    // SSTORE when nothing changed is the hot path for a local allocation.
    if (
      _oldSnapshot.staked != _newSnapshot.staked || _oldSnapshot.stakeEnd != _newSnapshot.stakeEnd
        || _oldSnapshot.isPermanent != _newSnapshot.isPermanent
    ) {
      _leafStorage.tokenSnapshot[_input.tokenId] = _newSnapshot;
    }

    // Loop 1 walks the incoming allocations: a non-zero prior amount means the gauge is already in the set, and
    // no duplicates means each read comes before any same-gauge write. Loop 2 is skipped when all are kept.
    uint256 _keptCount = 0;
    // Lengths uncached on purpose: this runs at the non-via-ir stack ceiling, two more locals tip it over.
    for (uint256 _i; _i < _newAllocations.length; ++_i) {
      uint128 _oldAllocationAmount = _leafStorage.allocations[_input.tokenId][_newAllocations[_i].gauge];
      IVoterCommon.GaugeAllocation memory _newAllocation = _newAllocations[_i];

      if (_oldAllocationAmount > 0 && _newAllocation.gauge != ZERO_GAUGE) {
        _keptCount++;
      }

      _processGauge({
        _leafStorage: _leafStorage,
        _context: _context,
        _factoryRegistry: _input.factoryRegistry,
        _gauge: _newAllocation.gauge,
        _oldAllocated: _oldAllocationAmount,
        _newAllocated: _newAllocation.allocated,
        _data: _newAllocation.data
      });
    }

    // Loop 2: a gauge missing from the incoming list was removed. Runs in its own frame for non-viaIR stack
    // room. Gauges loop 1 dropped as dust are found there and skipped.
    if (_keptCount < _oldGauges.length) {
      _removeMissingGauges(_leafStorage, _context, _input.factoryRegistry, _newAllocations, _oldGauges);
    }

    // `ZERO_GAUGE` lives outside `allocatedGauges`, so neither loop above reaches it: unwind the old park
    // against the old snapshot, apply the new one against the new snapshot.

    uint128 _priorZeroGauge = _leafStorage.allocations[_input.tokenId][ZERO_GAUGE];
    uint128 _newZeroGauge = _context.expired ? 0 : _context.zeroGaugeAllocation;
    if (_priorZeroGauge > 0 || _newZeroGauge > 0) {
      _swapZeroGaugePark({
        _leafStorage: _leafStorage,
        _tokenId: _input.tokenId,
        _oldTotal: _priorZeroGauge,
        _newTotal: _newZeroGauge,
        _oldEnd: _oldSnapshot.stakeEnd,
        _newEnd: _newSnapshot.stakeEnd,
        _oldIsPermanent: _oldSnapshot.isPermanent,
        _newIsPermanent: _newSnapshot.isPermanent
      });
    }

    // Take the sentinel amount off the budget here, but hand it back so the caller dispatches the return after
    // the checkpoints: the transport refunds to a caller-supplied address, so dispatching gives up control.
    _deallocAmount = _context.deallocAmount;
    if (_deallocAmount > 0) _leafStorage.tokenStates[_input.tokenId].chainAllocation -= _deallocAmount;

    // Trim to entries actually written.
    _callParamsList = _context.list;
    uint256 _writtenCount = _context.entryCount;
    assembly ('memory-safe') {
      mstore(_callParamsList, _writtenCount)
    }
  }

  /**
   * @notice Remove every prior gauge missing from the incoming list, processing each at a new allocation of
   *         zero.
   * @dev The lookup binary-searches, so it needs `_newAllocations` strictly ascending. Own frame, so
   *      `_processAllocation` keeps non-viaIR stack headroom.
   * @param _leafStorage LeafVoter state the pass is applied to.
   * @param _context The pass context, written in place.
   * @param _factoryRegistry FactoryRegistry the emission-cap gate reads.
   * @param _newAllocations Incoming allocations, strictly ascending.
   * @param _oldGauges Gauges the token had weight on at pass entry.
   */
  function _removeMissingGauges(
    LeafStorage storage _leafStorage,
    ILeafVoter.AllocationContext memory _context,
    IFactoryRegistry _factoryRegistry,
    IVoterCommon.GaugeAllocation[] memory _newAllocations,
    address[] memory _oldGauges
  ) private {
    for (uint256 _i; _i < _oldGauges.length; ++_i) {
      address _gauge = _oldGauges[_i];
      if (!_inAllocations(_newAllocations, _gauge)) {
        _processGauge({
          _leafStorage: _leafStorage,
          _context: _context,
          _factoryRegistry: _factoryRegistry,
          _gauge: _gauge,
          _oldAllocated: _leafStorage.allocations[_context.tokenId][_gauge],
          _newAllocated: 0,
          _data: ''
        });
      }
    }
  }

  /**
   * @notice Per-gauge sequence for one allocation pass. The three classes are the same steps gated by
   *         `(_oldAllocated > 0, _wantsApply)`: removed, new and kept.
   * @dev A non-zero `_oldAllocated` also means the gauge is in `allocatedGauges` with a non-dust contribution
   *      to unwind. Writes `_context` in place, plus at most one record and one set transition.
   * @param _leafStorage LeafVoter state the pass is applied to.
   * @param _context The pass context, written in place.
   * @param _factoryRegistry FactoryRegistry the emission-cap gate reads.
   * @param _gauge Gauge under consideration.
   * @param _oldAllocated Prior allocation for the gauge, zero marks a new gauge.
   * @param _newAllocated Incoming allocation for the gauge, zero marks a removal.
   * @param _data Opaque per-gauge payload carried into the result entry.
   */
  function _processGauge(
    LeafStorage storage _leafStorage,
    ILeafVoter.AllocationContext memory _context,
    IFactoryRegistry _factoryRegistry,
    address _gauge,
    uint128 _oldAllocated,
    uint128 _newAllocated,
    bytes memory _data
  ) private {
    // The sentinel amount means "return that voting power to root": never parked, stored, settled or added to
    // the voted set, only summed here for `_processAllocation` to take off the budget after the pass.
    if (_gauge == DEALLOC_GAUGE) {
      _context.deallocAmount += _newAllocated;
      return;
    }

    // An explicit idle park. Summed like redirected weight, for the `ZERO_GAUGE` block at the end of
    // `_processAllocation` to unwind the prior park and apply the new total. Never settled here.
    if (_gauge == ZERO_GAUGE) {
      _context.zeroGaugeAllocation += _newAllocated;
      return;
    }

    bool _hadOld = _oldAllocated > 0;
    bool _wantsApply;

    {
      // Only registered, activated gauges are routable; inactivity is an absolute gate no whitelist bypasses.
      // An activated gauge with a zeroed emission cap routes only whitelisted tokenIds, positioning them for
      // fee recovery. The whitelist bypasses this cap gate alone: settlement still applies the zero cap, so
      // the recorded weight earns no emissions. The cap read is skipped whenever it cannot change the outcome.
      ILeafVoter.GaugeState storage _gaugeState = _leafStorage.gaugeStates[_gauge];
      bool _routable = _gaugeState.isRegistered && _gaugeState.isActivated;
      if (_routable && _newAllocated > 0 && !_context.canVoteForZeroCapGauges) {
        _routable = _factoryRegistry.emissionCap(_gauge) > 0;
      }

      _wantsApply = _routable && !_context.expired && _newAllocated > 0;

      // Redirected weight parks on `ZERO_GAUGE`, whatever its class: a never-registered target, a registered
      // inactive gauge or a zero-cap gauge the tokenId is not whitelisted for. An expired stake contributes
      // nothing anywhere.
      if (!_routable && !_context.expired) {
        _context.zeroGaugeAllocation += _newAllocated;
      }
    }

    // Would the apply write anything? A decaying allocation below MAXTIME wei resolves to the zero triple.
    // Evaluated at `lastSettlement`, which `_settleGauge` never advances, so this gate and the apply agree.
    // Scoped so the triple frees its stack slots before the settle, which the non-via-ir pipeline needs.
    bool _wouldWrite = false;
    if (_wantsApply) {
      (int128 _bias, int128 _slope, int128 _perm) =
        contribution(_leafStorage, _newAllocated, _context.newSnapshot.stakeEnd, _context.newSnapshot.isPermanent);
      _wouldWrite = _bias != 0 || _slope != 0 || _perm != 0;
    }

    // No prior position and nothing to write leaves no trace: settling a dust target would advance its cursor
    // and credit its ceiling for weight it never held.
    if (!_hadOld && !_wouldWrite) return;

    // Settle at the old weight before the weight change below. Gauges read their cumulative share themselves
    // through `settleGauge`, so this pass only records the entry.
    // slither-disable-next-line uninitialized-local
    ILeafVoter.CheckpointData memory _entry;
    _settleGauge(_leafStorage, _gauge, _factoryRegistry);

    // The old stakeEnd, so the reversal matches what the prior allocation registered. An expired old snapshot
    // resolves to the zero triple, so nothing is over-subtracted.
    if (_hadOld) {
      unwindContribution(
        _leafStorage, _gauge, _oldAllocated, _context.oldSnapshot.stakeEnd, _context.oldSnapshot.isPermanent
      );
    }

    // The dust gate already dropped zero-weight allocations, so dust leaves no record, set entry or checkpoint.
    if (_wouldWrite) {
      applyContribution(
        _leafStorage, _gauge, _newAllocated, _context.newSnapshot.stakeEnd, _context.newSnapshot.isPermanent
      );
      _leafStorage.allocations[_context.tokenId][_gauge] = _newAllocated;
    }

    // slither-disable-next-line unused-return
    if (_wouldWrite && !_hadOld) _leafStorage.allocatedGauges[_context.tokenId].add(_gauge);
    if (!_wouldWrite && _hadOld) {
      delete _leafStorage.allocations[_context.tokenId][_gauge];
      // slither-disable-next-line unused-return
      _leafStorage.allocatedGauges[_context.tokenId].remove(_gauge);
    }

    // The entry carries the allocation it was recorded at: checkpoints are external calls driven in a loop, and
    // re-reading per call would let the first reward contract reenter and change what the rest see. A cleared
    // position checkpoints at zero.
    if (_hadOld || _wouldWrite) {
      _entry.gauge = _gauge;
      _entry.allocated = _wouldWrite ? _newAllocated : 0;
      if (_wouldWrite) _entry.data = _data;
      _context.list[_context.entryCount++] = _entry;
    }
  }

  /**
   * @notice The one writer of `emissionsPerVP`: parks the scalar at zero while the chain is `Suspended` or
   *         `Sunset`.
   * @dev Root sends a suspended or sunset chain's accrual to surplus, so a non-zero scalar stored during either
   *      would credit gauges with emissions root never funds. In-flight root messages can still land after the
   *      flip, so the mask holds against them too.
   * @dev `_settleIndex` accrues at the stored scalar and knows nothing about the status, so every
   *      `emissionsPerVP` write MUST go through this setter for that to hold.
   * @param _leafStorage LeafVoter state the scalar and status live in.
   * @param _emissionsPerVP Requested global emissions-per-VP scalar.
   * @return _applied Scalar actually stored: `_emissionsPerVP`, or zero while `Suspended` or `Sunset`.
   */
  function _setEmissionsPerVP(
    LeafStorage storage _leafStorage,
    uint256 _emissionsPerVP
  ) private returns (uint256 _applied) {
    IVoterCommon.ChainStatus _status = _leafStorage.chainStatus;
    bool _masked = _status == IVoterCommon.ChainStatus.Suspended || _status == IVoterCommon.ChainStatus.Sunset;
    _applied = _masked ? 0 : _emissionsPerVP;
    _leafStorage.emissionsPerVP = _applied;
  }

  /**
   * @notice Settle the chain accumulators (`index`, `timeIndex`) up to now, snapshotting both at every weekly
   *         boundary crossed.
   * @dev Walks weekly boundaries from `lastSettlement`: each whole segment advances both accumulators and
   *      records `indexAtBoundary`/`timeIndexAtBoundary`, then the trailing partial segment advances them to
   *      now. Does nothing when `lastSettlement` is already at or past now.
   * @dev Writes no rate. Callers overwrite `emissionsPerVP` after this returns, so the accrual settles at the
   *      old rate.
   * @param _leafStorage LeafVoter state the accumulators live in.
   */
  function _settleIndex(LeafStorage storage _leafStorage) private {
    uint48 _to = uint48(block.timestamp);
    if (_to <= _leafStorage.lastSettlement) return;

    uint48 _cursor = _leafStorage.lastSettlement;
    uint256 _index = _leafStorage.index;
    uint256 _timeIndex = _leafStorage.timeIndex;
    uint256 _emissionsPerVP = _leafStorage.emissionsPerVP;

    // Bank both accumulators in locals and flush once after the walk, as root's `_settleGlobalIndex` does.
    // `timeIndex` accrues the scalar weighted by absolute time (origin at the unix epoch), stored doubled
    // (`∫2t·dt = t^2`) so the halving defers to a single divide during per-gauge settlement.
    uint48 _nextBoundary = _nextWeekBoundary(_cursor);
    while (_nextBoundary <= _to) {
      _index += _emissionsPerVP * (_nextBoundary - _cursor);
      _timeIndex += _emissionsPerVP * (_timestampSquared(_nextBoundary) - _timestampSquared(_cursor));
      _leafStorage.indexAtBoundary[_nextBoundary] = _index;
      _leafStorage.timeIndexAtBoundary[_nextBoundary] = _timeIndex;
      _cursor = _nextBoundary;
      _nextBoundary += WEEK;
    }
    if (_to > _cursor) {
      _index += _emissionsPerVP * (_to - _cursor);
      _timeIndex += _emissionsPerVP * (_timestampSquared(_to) - _timestampSquared(_cursor));
    }

    _leafStorage.index = _index;
    _leafStorage.timeIndex = _timeIndex;
    _leafStorage.lastSettlement = _to;
  }

  /**
   * @notice Swap the `ZERO_GAUGE` idle park from `_oldTotal` under `_oldEnd` to `_newTotal` under `_newEnd`.
   * @dev Slope flooring makes per-park triples non-additive, so the sink holds one aggregate `contribution(total)`
   *      that a later unwind cancels exactly. Both the additive top-up (`applyChainAllocation`) and the shape
   *      swap (`_processAllocation`) route through here so the two paths cannot drift. Settles first so the
   *      contribution walk runs against a current index; callers gate on having something to do before calling.
   * @param _leafStorage LeafVoter state the park is swapped in.
   * @param _tokenId veNFT id whose park is being swapped.
   * @param _oldTotal Park amount currently held on `ZERO_GAUGE`.
   * @param _newTotal Park amount to hold after the swap.
   * @param _oldEnd Stake expiry the old park was booked under.
   * @param _newEnd Stake expiry the new park is booked under.
   * @param _oldIsPermanent Permanence flag the old park was booked under.
   * @param _newIsPermanent Permanence flag the new park is booked under.
   */
  function _swapZeroGaugePark(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    uint128 _oldTotal,
    uint128 _newTotal,
    uint48 _oldEnd,
    uint48 _newEnd,
    bool _oldIsPermanent,
    bool _newIsPermanent
  ) private {
    // `ZERO_GAUGE`'s cap is forced to zero inside `_settleGauge`, so the registry handle is never consulted.
    _settleGauge(_leafStorage, ZERO_GAUGE, IFactoryRegistry(address(0)));
    if (_oldTotal > 0) unwindContribution(_leafStorage, ZERO_GAUGE, _oldTotal, _oldEnd, _oldIsPermanent);
    if (_newTotal > 0) applyContribution(_leafStorage, ZERO_GAUGE, _newTotal, _newEnd, _newIsPermanent);
    if (_oldTotal != _newTotal) _leafStorage.allocations[_tokenId][ZERO_GAUGE] = _newTotal;
  }

  /**
   * @notice Settle `_gauge` against the settled chain `index`: walk its point to `lastSettlement` under its
   *         per-gauge cap, then flush the surplus, cumulative reward share (`ceiling`) and cursors to storage.
   * @dev Call after `_settleIndex`, so the walk runs against a current `index`. Makes no call into the gauge,
   *      which reads its cumulative reward share itself through `settleGauge`.
   * @dev Produces only cap-excess surplus. Idle Gauge and Early Exit surplus arrive through `forfeitEmissions`.
   * @param _leafStorage LeafVoter state the gauge is settled in.
   * @param _gauge Gauge to settle. Callers must remap an unregistered address to `ZERO_GAUGE` first, or the walk
   *               starts from the unix epoch: registration seeds the cursor, activated or not, the same way the
   *               constructor seeds `ZERO_GAUGE`.
   * @param _factoryRegistry FactoryRegistry the gauge's emission cap is read from; unused for `ZERO_GAUGE`.
   */
  function _settleGauge(LeafStorage storage _leafStorage, address _gauge, IFactoryRegistry _factoryRegistry) private {
    ILeafVoter.GaugeState memory _state = _leafStorage.gaugeStates[_gauge];

    uint48 _to = _leafStorage.lastSettlement;

    // No new period since the previous settlement: nothing to walk or flush.
    if (_to == _state.lastSettlement) return;

    // Step 1: resolve the cap and walk the gauge through its expiry boundaries, summing the capped
    // `effectiveShare` and the cap-excess `surplusDelta`. `ZERO_GAUGE` emits nothing, so a zero cap sends its
    // whole walked allocation to surplus.
    uint128 _cap = _gauge == ZERO_GAUGE ? 0 : _factoryRegistry.emissionCap(_gauge);

    (uint128 _effectiveShare, uint128 _surplusDelta) = _walkGauge(_leafStorage, _gauge, _cap, _state, _to);

    // Clamp a sub-zero weight to keep the gauge operational, and emit from here since the view walk cannot. It
    // does not affect the share accrued above, so the settle and projection walks stay in sync.
    int256 _resolvedWeight = int256(uint256(_state.point.permanentStakeBalance)) + _state.point.bias;
    if (_resolvedWeight < 0) {
      emit ILeafVoter.GaugeWeightClamped(_gauge, _resolvedWeight);
      _state.point.bias = 0;
      _state.point.slope = 0;
    }

    // Step 2: flush the surplus to the chain aggregate and credit the effective share to `ceiling`, the
    // cumulative reward share that only ever increases and that the gauge diffs against its own cursor.
    _leafStorage.surplusAccrued += _surplusDelta;
    _state.ceiling += _effectiveShare;
    _state.lastIndex = _leafStorage.index;
    _state.lastTimeIndex = _leafStorage.timeIndex;
    _state.lastSettlement = _to;
    _leafStorage.gaugeStates[_gauge] = _state;
  }

  /**
   * @notice Checkpoint a tokenId's allocation on a gauge's reward contract.
   * @param _tokenId The tokenId being checkpointed.
   * @param _callParams Settled entry carrying the gauge and checkpoint payload.
   * @param _stakeEnd Shape the caller read once before the loop, so every entry uses the same value.
   * @param _factoryRegistry FactoryRegistry the gauge's reward contract is read from.
   */
  function _checkpointReward(
    uint256 _tokenId,
    ILeafVoter.CheckpointData memory _callParams,
    uint48 _stakeEnd,
    IFactoryRegistry _factoryRegistry
  ) private {
    address _gauge = _callParams.gauge;
    if (_gauge == ZERO_GAUGE) return;

    address _rewards = _factoryRegistry.gaugeToRewards(_gauge);
    if (_rewards == address(0)) return;

    // Everything comes from the entry and the caller's shape, never re-read here: these run as a loop of
    // external calls, so a reward contract that reenters cannot alter what the next one is checkpointed against.
    IVotingRewardsManager(_rewards).checkpoint(_tokenId, _callParams.allocated, _stakeEnd, _callParams.data);
  }

  /**
   * @notice Drive the per-gauge reward checkpoints for a processed allocation. Run by every path that processes
   *         an allocation.
   * @dev Makes no call into the gauge, which reads its cumulative share from `settleGauge`. A reverting reward
   *      contract fails the whole call.
   * @param _leafStorage LeafVoter state the checkpoint shape is read from.
   * @param _tokenId Token whose gauge checkpoints are driven.
   * @param _callParamsList Per-gauge checkpoint entries from `_processAllocation`.
   * @param _factoryRegistry FactoryRegistry each gauge's reward contract is read from.
   */
  function _driveCheckpoints(
    LeafStorage storage _leafStorage,
    uint256 _tokenId,
    ILeafVoter.CheckpointData[] memory _callParamsList,
    IFactoryRegistry _factoryRegistry
  ) private {
    // Read once, before the loop: the calls below hand control to reward contracts, and every entry must be
    // checkpointed against the same shape.
    uint48 _stakeEnd = _leafStorage.tokenSnapshot[_tokenId].stakeEnd;
    uint256 _length = _callParamsList.length;
    for (uint256 _i; _i < _length; ++_i) {
      _checkpointReward(_tokenId, _callParamsList[_i], _stakeEnd, _factoryRegistry);
    }
  }

  /**
   * @notice Chain `index` and `timeIndex` at `_timestamp`, valid whether or not the chain is settled to it.
   * @dev Before `lastSettlement` returns the boundary snapshots, at it the live accumulators, past it the
   *      projection at the current `emissionsPerVP` (linear for `index`, doubled-quadratic for `timeIndex`). This
   *      equals what the settle path would write, since every rate change settles both accumulators first and
   *      `emissionsPerVP` holds constant between, so the settle and projection walks never diverge.
   * @param _leafStorage LeafVoter state the accumulators are read from.
   * @param _timestamp Timestamp to read the chain accumulators at.
   * @return _projectedIndex Chain `index` at `_timestamp`.
   * @return _projectedTimeIndex Chain `timeIndex` at `_timestamp`.
   */
  function _projectedChainAt(
    LeafStorage storage _leafStorage,
    uint48 _timestamp
  ) private view returns (uint256 _projectedIndex, uint256 _projectedTimeIndex) {
    uint48 _settledAt = _leafStorage.lastSettlement;
    if (_timestamp < _settledAt) {
      return (_leafStorage.indexAtBoundary[_timestamp], _leafStorage.timeIndexAtBoundary[_timestamp]);
    }
    if (_timestamp == _settledAt) return (_leafStorage.index, _leafStorage.timeIndex);
    uint256 _emissionsPerVP = _leafStorage.emissionsPerVP;
    return (
      _leafStorage.index + _emissionsPerVP * (_timestamp - _settledAt),
      _leafStorage.timeIndex + _emissionsPerVP * (_timestampSquared(_timestamp) - _timestampSquared(_settledAt))
    );
  }

  /**
   * @notice Walk `_gauge` from `_state.lastSettlement` to `_to`, summing `(effectiveShare, surplusDelta)` over
   *         the weekly segments at a per-second emission cap of `_cap`.
   * @dev The walk exists because the cap is applied per segment: gauge weight decays at every boundary, so one
   *      cap over the whole span would give a different answer. The cap excess goes to surplus.
   * @dev View-only. Writes the in-memory `_state` point and cursors (`lastIndex`, `lastTimeIndex`,
   *      `lastSettlement`); the caller persists them with `ceiling`, and clamps a sub-zero weight afterwards,
   *      which does not affect the accrued share.
   * @param _leafStorage LeafVoter state the chain accumulators and slope schedule are read from.
   * @param _gauge Gauge whose slope schedule and weight to walk.
   * @param _cap Per-second emission cap. `type(uint128).max` is the uncapped sentinel, and the per-segment
   *             `_cap * duration` saturates rather than overflowing, so a near-max cap is also uncapped.
   * @param _state In-memory copy of the gauge's state; its point and cursors are written in place.
   * @param _to Walk target: `lastSettlement` on the settle path, `block.timestamp` on the projection path.
   * @return _effectiveShare Sum of per-segment capped shares over the walk.
   * @return _surplusDelta Sum of per-segment `(allocated - effective)` cap excess.
   */
  function _walkGauge(
    LeafStorage storage _leafStorage,
    address _gauge,
    uint128 _cap,
    ILeafVoter.GaugeState memory _state,
    uint48 _to
  ) private view returns (uint128 _effectiveShare, uint128 _surplusDelta) {
    // `_state.lastIndex`/`lastTimeIndex` ride along as the running cursors through the walk; the callers overwrite
    // or discard them afterwards, so using them as scratch keeps `_walkGauge` in stack budget.
    uint48 _nextBoundary = _nextWeekBoundary(_state.lastSettlement);

    while (_nextBoundary <= _to) {
      (uint128 _segmentEffective, uint128 _segmentSurplus) = _accrueGaugeSegment({
        _leafStorage: _leafStorage,
        _state: _state,
        _gauge: _gauge,
        _segmentEnd: _nextBoundary,
        _atBoundary: true,
        _cap: _cap
      });
      _effectiveShare += _segmentEffective;
      _surplusDelta += _segmentSurplus;
      _nextBoundary += WEEK;
    }

    // Final partial segment: no slope reduction, the target is not a boundary.
    (uint128 _tailEffective, uint128 _tailSurplus) = _accrueGaugeSegment({
      _leafStorage: _leafStorage, _state: _state, _gauge: _gauge, _segmentEnd: _to, _atBoundary: false, _cap: _cap
    });
    _effectiveShare += _tailEffective;
    _surplusDelta += _tailSurplus;

    _state.point.ts = _to;
  }

  /**
   * @notice Decay `_state.point` to `_segmentEnd`, price the segment, and advance the cursors in place.
   * @dev Split out of `_walkGauge` for stack headroom under non-viaIR. Reads `_state.lastIndex`/`lastTimeIndex` as
   *      the running chain-index cursors and advances them to `_segmentEnd`, along with `bias`, `slope` (at a
   *      boundary) and `lastSettlement`. Priced exactly via `_segmentAccrual`; see it for the two-index form.
   * @param _leafStorage LeafVoter state the accumulators and slope schedule are read from.
   * @param _state In-memory gauge state; its point and cursors are written.
   * @param _gauge Gauge whose slope schedule to read at a boundary.
   * @param _segmentEnd Segment end timestamp (a weekly boundary, or the walk target).
   * @param _atBoundary Whether `_segmentEnd` is a weekly boundary that fires a slope reduction.
   * @param _cap Per-second emission cap. `type(uint128).max` is uncapped.
   * @return _effective Capped share credited over the segment.
   * @return _surplus Cap excess over the segment.
   */
  function _accrueGaugeSegment(
    LeafStorage storage _leafStorage,
    ILeafVoter.GaugeState memory _state,
    address _gauge,
    uint48 _segmentEnd,
    bool _atBoundary,
    uint128 _cap
  ) private view returns (uint128 _effective, uint128 _surplus) {
    (uint256 _indexDelta, uint256 _timeIndexDelta) = _projectedChainAt(_leafStorage, _segmentEnd);
    _indexDelta -= _state.lastIndex;
    _timeIndexDelta -= _state.lastTimeIndex;
    int128 _slope = _state.point.slope; // slope over the segment, before any boundary reduction
    uint48 _duration = _segmentEnd - _state.lastSettlement;
    uint256 _capShare = _calculateCapShare(_duration, _cap);
    _state.point.bias -= _slope * int128(uint128(_duration));
    // Weight at the segment end, the whole `permanent + bias` sum floored at zero. Root's `_weightOf` floors only
    // the bias; the forms match unless slope-truncation dust drives a desynced point sub-zero.
    int256 _signedWeight = int256(uint256(_state.point.permanentStakeBalance)) + _state.point.bias;
    uint256 _endWeight = _signedWeight > 0 ? uint256(_signedWeight) : 0;

    (_effective, _surplus) = _segmentAccrual({
      _endWeight: _endWeight,
      _slopeMagnitude: _slope > 0 ? uint256(uint128(_slope)) : 0,
      _segmentEnd: _segmentEnd,
      _indexDelta: _indexDelta,
      _timeIndexDelta: _timeIndexDelta,
      _capShare: _capShare
    });

    if (_atBoundary) {
      // Floored at zero, as root's walk does: a schedule entry surviving a defensive clamp must not drive the
      // slope negative, where decay turns into growth. A healthy slope always covers its schedule.
      _slope -= _leafStorage.gaugeSlopeChanges[_gauge][_segmentEnd];
      _state.point.slope = _slope > 0 ? _slope : int128(0);
    }
    _state.lastIndex += _indexDelta;
    _state.lastTimeIndex += _timeIndexDelta;
    _state.lastSettlement = _segmentEnd;
  }

  /**
   * @notice Report whether `_gauge` appears in `_allocations`.
   * @dev Binary search, so it needs the strictly ascending order root enforces on dispatch and the local
   *      `allocateGauges` enforces in its sum loop.
   * @param _allocations Incoming allocations, strictly ascending by gauge.
   * @param _gauge Gauge to look for.
   * @return _found True when `_gauge` is present.
   */
  function _inAllocations(
    IVoterCommon.GaugeAllocation[] memory _allocations,
    address _gauge
  ) private pure returns (bool _found) {
    uint256 _low = 0;
    uint256 _high = _allocations.length;
    while (_low < _high) {
      uint256 _mid = (_low + _high) >> 1;
      address _at = _allocations[_mid].gauge;
      if (_at == _gauge) return true;
      if (_at < _gauge) _low = _mid + 1;
      else _high = _mid;
    }
    return false;
  }

  /**
   * @notice The timestamp squared, widened first. The absolute (unix-epoch) origin is shared by root and leaf,
   *         so their rounded accruals stay consistent.
   * @param _timestamp Timestamp to square.
   * @return _squared `_timestamp^2`.
   */
  function _timestampSquared(uint48 _timestamp) private pure returns (uint256 _squared) {
    _squared = uint256(_timestamp) * _timestamp;
  }

  /**
   * @notice Snap a timestamp up to the next `WEEK`-aligned boundary on the unix-epoch grid.
   * @dev Strictly greater than `_ts`: a timestamp on a boundary maps to the next one, as root's walk does.
   * @param _ts Timestamp to snap.
   * @return _boundary First `WEEK`-aligned boundary after `_ts`.
   */
  function _nextWeekBoundary(uint48 _ts) private pure returns (uint48 _boundary) {
    _boundary = (_ts / WEEK + 1) * WEEK;
  }

  /**
   * @notice Calculate the maximum share of emissions for a given duration and emissions cap.
   * @dev Saturates at `type(uint128).max` instead of overflowing.
   * @param _segmentDuration of the window for which the share is being calculated
   * @param _cap the per second cap of AERO emissions
   * @return _capShare the maximum amount of emissions allowed for the duration
   */
  function _calculateCapShare(uint128 _segmentDuration, uint128 _cap) private pure returns (uint128 _capShare) {
    uint256 _product = uint256(_cap) * _segmentDuration;
    return _product > type(uint128).max ? type(uint128).max : uint128(_product);
  }

  /**
   * @notice Resolve one walk segment's capped emission share and cap excess, exact for a linear weight against a
   *         piecewise-constant scalar.
   * @dev Prices `allocated` with the same form as root's `_segmentAccrual` (see it for the derivation and the
   *      sub-additivity guarantee), then caps: `effective = min(allocated, capShare)`, `surplus = allocated -
   *      effective`.
   * @param _endWeight Floored gauge weight at the segment end (`max(permanent + bias, 0)`).
   * @param _slopeMagnitude Decay slope magnitude over the segment; `0` for a permanent stake.
   * @param _segmentEnd Segment end timestamp.
   * @param _indexDelta Chain `index` growth across the segment.
   * @param _timeIndexDelta Chain `timeIndex` (doubled, time-weighted) growth across the segment.
   * @param _capShare Maximum share the cap allows over the segment (`cap * duration`, saturated).
   * @return _effective Capped share credited to the gauge.
   * @return _surplus Cap excess (`allocated - effective`).
   */
  function _segmentAccrual(
    uint256 _endWeight,
    uint256 _slopeMagnitude,
    uint48 _segmentEnd,
    uint256 _indexDelta,
    uint256 _timeIndexDelta,
    uint256 _capShare
  ) private pure returns (uint128 _effective, uint128 _surplus) {
    // End weight against the plain accumulator, plus the decay add-back when the segment decays; a permanent
    // stake (`slope == 0`) skips the second term.
    uint256 _segmentAllocated = Math.mulDiv(_endWeight, _indexDelta, PRECISION);
    if (_slopeMagnitude != 0) {
      // 2 * ∫(segmentEnd - t) * scalar dt >= 0.
      uint256 _addBack = 2 * uint256(_segmentEnd) * _indexDelta - _timeIndexDelta;
      _segmentAllocated += Math.mulDiv(_slopeMagnitude, _addBack, 2 * PRECISION);
    }

    // A zero-length final segment gets a zero cap share and contributes nothing.
    uint256 _segmentEffective = _segmentAllocated < _capShare ? _segmentAllocated : _capShare;
    // The narrowing is safe under `_capShare`, but the excess can exceed uint128 on a gauge-weight desync, so
    // it fails fast instead of truncating into `surplusAccrued`.
    _effective = uint128(_segmentEffective);
    _surplus = (_segmentAllocated - _segmentEffective).toUint128();
  }

  /**
   * @notice Require a gauge list to allocate exactly the chain budget.
   * @dev Reverts `ChainAllocationMismatch` unless `Σ _gauges.allocated == _budget`. Idle VP must be an explicit
   *      `ZERO_GAUGE` entry: a remainder is never backfilled.
   * @dev Own frame, so `applyGaugeAllocations` keeps non-viaIR stack headroom.
   * @param _budget The tokenId's chain budget on this leaf.
   * @param _gauges The requested per-gauge allocation.
   */
  function _requireExactBudget(uint128 _budget, IVoterCommon.GaugeAllocation[] calldata _gauges) private pure {
    // slither-disable-next-line uninitialized-local
    uint128 _total;
    uint256 _gaugesLength = _gauges.length;
    for (uint256 _i; _i < _gaugesLength; ++_i) {
      _total += _gauges[_i].allocated;
    }
    if (_total != _budget) revert ILeafVoter.ChainAllocationMismatch();
  }
}
