// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @title ILeafVoter
 * @notice Leaf-chain Voter: turns per-chain reward rates and per-tokenId allocations into per-gauge emission
 *         rates, and exposes the claim surface for gauges and the redeem surface for `ReceiptToken` holders.
 * @dev Root drives two paths through the Leaf MessageOrchestrator: `applyChainAllocation` sets the chain budget
 *      and emissions scalar (no cooldown), `applyGaugeAllocations` spreads it over gauges (cooldown per chain).
 * @dev An operator drives local redistributions through `allocateGauges`. Settlement state advances lazily.
 */
interface ILeafVoter is IVoterCommon, IAccessControl {
  /*//////////////////////////////////////////////////////////////
                                 STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Per-gauge settlement state, kept in one mapping so `_settleGauge` touches contiguous slots.
   * @param ceiling Cumulative effective share credited to the gauge; only ever increases.
   * @param claimed Cumulative emissions minted by claims; only ever increases, capped at `ceiling - surplus`.
   * @param lastSettlement Timestamp of this gauge's last settlement.
   * @param isRegistered Produced by an approved factory; gates routing and makes `settleGauge` a no-op if unset.
   * @param isActivated Registered gauges start inactive and route as unregistered until this flips.
   * @param surplus Cumulative forfeited surplus, clamped per report; `ceiling >= claimed + surplus` always holds.
   * @param lastIndex Chain `index` at this gauge's last settlement.
   * @param lastTimeIndex Chain `timeIndex` at this gauge's last settlement.
   * @param point Decaying weight, resolved through `gaugeSlopeChanges` during settlement.
   */
  struct GaugeState {
    uint128 ceiling;
    uint128 claimed;
    uint48 lastSettlement;
    bool isRegistered;
    bool isActivated;
    uint128 surplus;
    uint256 lastIndex;
    uint256 lastTimeIndex;
    Point point;
  }

  /**
   * @notice Packed per-tokenId allocation state; the gating fields share one slot.
   * @param operator Address authorized to run the local `allocateGauges` for this tokenId.
   * @param lastAllocated Timestamp of the last allocation; the cooldown counts from here.
   * @param canVoteForZeroCapGauges Whether the tokenId may route weight onto activated gauges whose emission
   *                                cap is zero.
   * @param chainAllocation Chain budget the tokenId may distribute, from its last root allocation.
   */
  struct TokenState {
    address operator;
    uint48 lastAllocated;
    bool canVoteForZeroCapGauges;
    uint128 chainAllocation;
  }

  /**
   * @notice Per-gauge checkpoint entry returned by `_processAllocation` to drive the reward checkpoint.
   * @dev Self-contained: checkpoints are external calls in a loop, so storage is not re-read between them.
   * @dev `ZERO_GAUGE` never appears in the array.
   * @param gauge Gauge this entry checkpoints.
   * @param allocated Allocation checkpointed against, captured at record time so reentrancy cannot change it.
   * @param data Opaque payload for the reward checkpoint; empty when the entry only clears a position (zero).
   */
  struct CheckpointData {
    address gauge;
    uint128 allocated;
    bytes data;
  }

  /**
   * @notice Fee claim request forwarded through the LeafVoter.
   * @param votingRewardsManager VotingRewardsManager to claim fees from.
   * @param maxCheckpoints Maximum number of user checkpoints to process.
   */
  struct FeeClaim {
    address votingRewardsManager;
    uint256 maxCheckpoints;
  }

  /**
   * @notice Incentive claim request forwarded through the LeafVoter.
   * @param votingRewardsManager VotingRewardsManager to claim incentives from.
   * @param programId Incentive program ID to claim from.
   * @param maxCheckpoints Maximum number of user checkpoints to process.
   */
  struct IncentiveClaim {
    address votingRewardsManager;
    uint256 programId;
    uint256 maxCheckpoints;
  }

  /**
   * @notice Mutable context threaded by memory reference through one `_processAllocation` pass.
   * @param tokenId The tokenId being processed.
   * @param oldSnapshot Token state at entry; unwinds resolve against its `stakeEnd`.
   * @param newSnapshot Incoming token state; applies resolve against its `stakeEnd`.
   * @param expired True when the new stake already expired at `lastSettlement`; skips the apply side.
   * @param canVoteForZeroCapGauges Read once from the token state; lets `_processGauge` skip the emission cap
   *                                gate instead of redirecting the weight to `ZERO_GAUGE`.
   * @param list Result entries, sized to the union upper bound and trimmed at return.
   * @param entryCount Number of entries written to `list` so far.
   * @param zeroGaugeAllocation Weight to park on `ZERO_GAUGE`: the explicit idle entry plus redirected gauges.
   * @param deallocAmount Weight routed to `DEALLOC_GAUGE`, returned to root after the pass; never persisted.
   */
  struct AllocationContext {
    uint256 tokenId;
    TokenSnapshot oldSnapshot;
    TokenSnapshot newSnapshot;
    bool expired;
    bool canVoteForZeroCapGauges;
    CheckpointData[] list;
    uint256 entryCount;
    uint128 zeroGaugeAllocation;
    uint128 deallocAmount;
  }

  /*//////////////////////////////////////////////////////////////
                                 EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when a gauge completes a claim through `mintEmissions`.
   * @param _gauge Gauge that invoked `mintEmissions`.
   * @param _recipients Recipients passed by the gauge, typically the LP and the referral leg.
   * @param _amounts Per-leg amounts of `ReceiptToken` allocated to each recipient.
   */
  event EmissionsMinted(address indexed _gauge, address[] _recipients, uint128[] _amounts);

  /**
   * @notice Emitted when `ReceiptToken` is redeemed and the `Redeem` message is dispatched to root.
   * @param _redeemer Address whose `ReceiptToken` was burned.
   * @param _recipient Address that receives the minted `TOKEN` on root.
   * @param _amount Amount burned, equal to the `TOKEN` to mint on root.
   */
  event Redeemed(address indexed _redeemer, address indexed _recipient, uint256 _amount);

  /**
   * @notice Emitted when a fee claim targets an unregistered VotingRewardsManager and the LeafVoter continues.
   * @param _tokenId The veNFT token ID whose fee claim failed.
   * @param _votingRewardsManager VotingRewardsManager targeted by the failed fee claim.
   * @param _maxCheckpoints Maximum number of user checkpoints requested for the failed fee claim.
   */
  event FeeClaimFailed(uint256 indexed _tokenId, address indexed _votingRewardsManager, uint256 _maxCheckpoints);

  /**
   * @notice Emitted when a forwarded fee claim completes without reverting.
   * @param _tokenId The veNFT token ID whose fee claim succeeded.
   * @param _votingRewardsManager VotingRewardsManager targeted by the successful fee claim.
   * @param _recipient Address that received any claimed fees.
   * @param _maxCheckpoints Maximum number of user checkpoints requested for the fee claim.
   */
  event FeeClaimSucceeded(
    uint256 indexed _tokenId, address indexed _votingRewardsManager, address indexed _recipient, uint256 _maxCheckpoints
  );

  /**
   * @notice Emitted when an incentive claim targets an unregistered VotingRewardsManager and the LeafVoter continues.
   * @param _tokenId The veNFT token ID whose incentive claim failed.
   * @param _votingRewardsManager VotingRewardsManager targeted by the failed incentive claim.
   * @param _programId Incentive program ID whose claim failed.
   * @param _maxCheckpoints Maximum number of user checkpoints requested for the failed incentive claim.
   */
  event IncentiveClaimFailed(
    uint256 indexed _tokenId, address indexed _votingRewardsManager, uint256 indexed _programId, uint256 _maxCheckpoints
  );

  /**
   * @notice Emitted when a forwarded incentive claim completes without reverting.
   * @param _tokenId The veNFT token ID whose incentive claim succeeded.
   * @param _votingRewardsManager VotingRewardsManager targeted by the successful incentive claim.
   * @param _programId Incentive program ID whose claim succeeded.
   * @param _recipient Address that received any claimed incentives.
   * @param _maxCheckpoints Maximum number of user checkpoints requested for the incentive claim.
   */
  event IncentiveClaimSucceeded(
    uint256 indexed _tokenId,
    address indexed _votingRewardsManager,
    uint256 indexed _programId,
    address _recipient,
    uint256 _maxCheckpoints
  );

  /**
   * @notice Emitted when a token's parked `DEALLOC_GAUGE` balance is drained and sent back to root.
   * @param _tokenId veNFT id whose parked voting power was deallocated.
   * @param _amount Voting power returned to root's `CHAIN0`.
   */
  event Deallocated(uint256 indexed _tokenId, uint128 _amount);

  /**
   * @notice Emitted when an `EmergencyDeallocate` message re-syncs a token's position with root.
   * @param _tokenId veNFT id whose position on the chain was reduced.
   */
  event EmergencyDeallocationApplied(uint256 indexed _tokenId);

  /**
   * @notice Emitted when `_walkGauge` clamps a sub-zero resolved weight; signals an ordering or arithmetic bug.
   * @param _gauge The gauge whose resolved weight underflowed.
   * @param _detectedWeight The negative resolved weight seen before clamping.
   */
  event GaugeWeightClamped(address indexed _gauge, int256 _detectedWeight);

  /**
   * @notice Emitted when a registered gauge forfeits surplus emissions it cannot distribute.
   * @param _gauge The gauge that forfeited the surplus.
   * @param _amount Surplus accrued after clamping, which may be less than the reported amount.
   */
  event EmissionsForfeited(address indexed _gauge, uint128 _amount);

  /**
   * @notice Emitted when the leaf message orchestrator updates a tokenId's operator.
   * @param _tokenId The tokenId whose operator was updated.
   * @param _operator The new operator address.
   */
  event OperatorSet(uint256 indexed _tokenId, address indexed _operator);

  /**
   * @notice Emitted when a `ReduceCooldown` message accrues a tokenId's cooldown reduction.
   * @param _tokenId The tokenId whose accumulated cooldown reduction increased.
   * @param _reduction Seconds added by this message.
   * @param _accumulated New total in seconds, clamped at `maxAccumulatedCooldownReduction`.
   */
  event CooldownReductionApplied(uint256 indexed _tokenId, uint48 _reduction, uint48 _accumulated);

  /**
   * @notice Emitted when a tokenId's can-vote-for-zero-cap-gauges flag is updated.
   * @param _tokenId The tokenId whose flag was updated.
   * @param _allowed The new flag value.
   */
  event CanVoteForZeroCapGaugesSet(uint256 indexed _tokenId, bool _allowed);

  /**
   * @notice Emitted when the local-voting master switch is set.
   * @param _enabled True once local `allocateGauges` is open.
   */
  event LocalVotingEnabledSet(bool _enabled);

  /**
   * @notice Emitted when the local allocation cooldown is updated.
   * @param _allocationCooldown The new cooldown duration in seconds.
   */
  event AllocationCooldownSet(uint48 _allocationCooldown);

  /**
   * @notice Emitted when the per-chain gauge-count cap is updated.
   * @param _maxGauges The new cap on gauges a tokenId may allocate to locally.
   */
  event MaxGaugesSet(uint256 _maxGauges);

  /**
   * @notice Emitted when the cap on a tokenId's accumulated cooldown reduction is updated.
   * @param _maxAccumulatedCooldownReduction New accumulation cap, in seconds.
   */
  event MaxAccumulatedCooldownReductionSet(uint48 _maxAccumulatedCooldownReduction);

  /**
   * @notice Emitted when the chain's operational status is updated.
   * @param _status The new chain status.
   */
  event ChainStatusSet(ChainStatus _status);

  /**
   * @notice Emitted when a chain-allocation message is applied for a tokenId.
   * @param _tokenId The tokenId whose chain budget was updated.
   * @param _allocationDelta Additive delta this message applied (may be zero on a resync).
   * @param _chainAllocation The resulting chain budget.
   * @param _emissionsPerVP Stored scalar after the call, `PRECISION`-scaled; zero while `Suspended`.
   */
  event ChainAllocated(
    uint256 indexed _tokenId, uint128 _allocationDelta, uint128 _chainAllocation, uint256 _emissionsPerVP
  );

  /**
   * @notice Emitted when a tokenId's gauge distribution is applied, locally or bridged.
   * @param _tokenId The tokenId whose gauges were allocated.
   * @param _allocations Requested allocation; unroutable gauges may be redirected, so booked weight can differ.
   * @param _emissionsPerVP Stored scalar after the call, `PRECISION`-scaled; zero while `Suspended`.
   */
  event GaugesAllocated(uint256 indexed _tokenId, GaugeAllocation[] _allocations, uint256 _emissionsPerVP);

  /**
   * @notice Emitted when a gauge is registered, active or not.
   * @param gauge The registered gauge.
   * @param activated Whether the gauge activated at registration.
   * @param registrationCursor The chain `lastSettlement` the gauge's
   *                           settlement cursor was seeded from.
   */
  event GaugeRegistered(address indexed gauge, bool activated, uint48 registrationCursor);

  /**
   * @notice Emitted when a gauge is activated, either at registration or
   *         through delayed activation.
   * @param gauge The activated gauge.
   * @param activationCursor The effective activation cursor, the chain
   *                         `lastSettlement` the gauge was anchored to.
   */
  event GaugeActivated(address indexed gauge, uint48 activationCursor);

  /*//////////////////////////////////////////////////////////////
                                 ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the caller is neither the veNFT's registered operator nor the Leaf MessageOrchestrator.
  error NotAuthorized();

  /**
   * @notice Thrown when a cross-chain entrypoint is called by anything but the Leaf MessageOrchestrator.
   */
  error NotMessageOrchestrator();

  /**
   * @notice Thrown when the local `allocateGauges` is called by anything but the tokenId's operator.
   */
  error NotOperator();

  /**
   * @notice Thrown when a gauge allocation runs before the per-chain cooldown has elapsed.
   * @dev Gates on `allocationCooldown` minus the token's accumulated reduction, consumed on a passing call.
   */
  error CooldownActive();

  /**
   * @notice Thrown by `applyGaugeAllocations` past the root-stamped `expiry`; root must re-dispatch.
   */
  error AllocationExpired();

  /**
   * @notice Thrown when a gauge-lifecycle entrypoint is called by an address other than the GaugeManager.
   */
  error NotGaugeManager();

  /**
   * @notice Thrown by `registerGauge` when the gauge is already registered.
   */
  error GaugeAlreadyRegistered();

  /**
   * @notice Thrown by `activateGauge` when the gauge is already activated.
   */
  error GaugeAlreadyActivated();

  /**
   * @notice Thrown by `allocateGauges` while local voting is disabled, which is the default.
   */
  error LocalVotingDisabled();

  /**
   * @notice Thrown when a local `allocateGauges` runs before any chain allocation seeded the stake shape.
   * @dev Defense in depth: `applyChainAllocation` seeds the shape first, so this should be unreachable. It
   *      stops a distribution against the default permanent shape if that ordering ever breaks.
   */
  error StakeSnapshotMissing();

  /**
   * @notice Thrown when the allocated amounts do not exactly equal the tokenId's `chainAllocation`.
   * @dev Counts the `DEALLOC_GAUGE` sentinel and the explicit `ZERO_GAUGE` idle entry; there is no backfill.
   */
  error ChainAllocationMismatch();

  /**
   * @notice Thrown when a local allocation targets more gauges than `maxGauges`.
   * @dev The cap keeps a tokenId's gauge set within the bound root's reduction-message gas budgeting assumes.
   */
  error ExceedsMaxGauges();

  /**
   * @notice Thrown by `activateGauge` for an unregistered gauge, and by `forfeitEmissions` for a non-gauge caller.
   */
  error GaugeNotRegistered();

  /**
   * @notice Thrown when `mintEmissions` is invoked with `_recipients.length != _amounts.length`.
   */
  error ArrayLengthMismatch();

  /**
   * @notice Thrown when the redeem amount is smaller than `MIN_REDEEM_AMOUNT`.
   */
  error AmountTooLow();

  /**
   * @notice Thrown when `mintEmissions` claims more than `ceiling - claimed - surplus`.
   */
  error CeilingExceeded();

  /**
   * @notice Thrown when `mintEmissions`, `redeem` or `allocateGauges` is called while the chain status is
   *         neither `Active` nor `Sunset`.
   */
  error ChainNotActiveOrSunset();

  /*//////////////////////////////////////////////////////////////
                                EXTERNAL
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Mints `ReceiptToken` to the `EmissionsHandler` and calls it back per recipient. Gauge only.
   * @dev Reverts `ChainNotActiveOrSunset` unless the chain is `Active` or `Sunset`, though the settled entitlement
   *      survives the pause. Reverts `GaugeNotRegistered` for other callers and `CeilingExceeded` above the
   *      gauge's headroom `ceiling - claimed - surplus`.
   * @dev `claimed` is raised before the mint; the callback MUST NOT rely on further `LeafVoter` writes.
   * @param _recipients Recipients for the per-leg delivery (LP, referral).
   * @param _amounts Per-leg amounts of `ReceiptToken`.
   */
  function mintEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external;

  /**
   * @notice Burns the caller's `ReceiptToken` and dispatches a `Redeem` message to root to mint `TOKEN`.
   * @dev Reverts `ChainNotActiveOrSunset` unless the chain is `Active` or `Sunset`, and `AmountTooLow` below
   *      `MIN_REDEEM_AMOUNT`.
   * @dev `surplusAccrued` rides in the payload so root books it into `reportedSurplus`.
   * @param _amount Amount of `ReceiptToken` to burn and `TOKEN` to mint on root.
   * @param _recipient Address that receives the minted `TOKEN` on root.
   * @param _gasLimit Execution gas reserved for the destination handler.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function redeem(uint256 _amount, address _recipient, uint256 _gasLimit, address _refundRecipient) external payable;

  /**
   * @notice Claims fee and incentive rewards through the LeafVoter in one transaction.
   * @dev Callable by the veNFT's registered operator or the Leaf MessageOrchestrator. Fee claims are processed
   *      before incentive claims. Unregistered managers are skipped; registered-manager reverts bubble to make an
   *      inbound claim message retryable.
   * @param _tokenId The veNFT token ID to claim for.
   * @param _recipient Address to receive the claimed rewards.
   * @param _feeClaims Fee claim requests to forward.
   * @param _incentiveClaims Incentive claim requests to forward.
   */
  function claimRewards(
    uint256 _tokenId,
    address _recipient,
    FeeClaim[] calldata _feeClaims,
    IncentiveClaim[] calldata _incentiveClaims
  ) external;

  /**
   * @notice Applies a chain-level allocation from root. Leaf MessageOrchestrator only.
   * @dev Additive, never an overwrite, so it cannot resurrect a budget `deallocate` already removed. Carries no
   *      gauges, is never cooldown-gated, and never reverts on a well-formed call. Runs while `Suspended` with
   *      the scalar forced to zero (root diverts that period to surplus); delta and snapshot still apply.
   * @param _tokenId Originating tokenId.
   * @param _allocationDelta Voting power added to the tokenId's chain budget (always an increase).
   * @param _emissionsPerVP New global emissions per voting power, `PRECISION`-scaled; zero while `Suspended`.
   * @param _refreshEmissionsPerVP Newest chain allocation seen; only then is `_emissionsPerVP` written.
   * @param _refreshShape Newest shape the token has seen; only then is `latestTokenSnapshot` updated.
   * @param _snapshot Live VE shape; seeds `tokenSnapshot` while no gauge weight is booked.
   */
  function applyChainAllocation(
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint256 _emissionsPerVP,
    bool _refreshEmissionsPerVP,
    bool _refreshShape,
    TokenSnapshot calldata _snapshot
  ) external;

  /**
   * @notice Applies a gauge distribution from root. Leaf MessageOrchestrator only.
   * @dev Full overwrite: omitted gauges are cleared and budget above `Σ _gauges` parks on `ZERO_GAUGE`.
   * @dev Reverts `CooldownActive` while the cooldown runs, so the transport redelivers later without spending
   *      the token's reduction, and `AllocationExpired` past `_expiry`.
   * @param _tokenId Originating tokenId.
   * @param _expiry Root-stamped deadline; the message expires once `block.timestamp` passes it.
   * @param _emissionsPerVP Global emissions-per-VP scalar at dispatch, `PRECISION`-scaled.
   * @param _refreshEmissionsPerVP Newest message the leaf has seen; only then is `_emissionsPerVP` written.
   * @param _refreshShape Newest shape the token has seen. If false, the vote books at the stored shape instead.
   * @param _newSnapshot Live sAERO position state at dispatch time.
   * @param _gauges Per-gauge allocations on this chain.
   * @return _callParamsList One entry per touched gauge whose reward checkpoint this call already drove.
   */
  function applyGaugeAllocations(
    uint256 _tokenId,
    uint48 _expiry,
    uint256 _emissionsPerVP,
    bool _refreshEmissionsPerVP,
    bool _refreshShape,
    TokenSnapshot calldata _newSnapshot,
    GaugeAllocation[] calldata _gauges
  ) external returns (CheckpointData[] memory _callParamsList);

  /**
   * @notice Adds `_reduction` to a tokenId's accumulated cooldown reduction. Leaf MessageOrchestrator only.
   * @dev Additive, so grants stack and order does not matter; the `uint48` add reverts on overflow.
   * @param _tokenId veNFT id whose accumulated cooldown reduction increases.
   * @param _reduction Seconds added.
   */
  function applyCooldownReduction(uint256 _tokenId, uint48 _reduction) external;

  /**
   * @notice Clears a token's gauge distribution here and cuts its chain budget. Leaf MessageOrchestrator only.
   * @dev Subtracts rather than zeroes, so order against `AllocateChain` deltas booked before the drain does not
   *      matter; the surviving budget parks on `ZERO_GAUGE`. Clamped at zero, so `_amount >= chainAllocation`
   *      is the full unwind. Runs whatever the chain status is.
   * @dev Clamping under-corrects a post-resume delta, so governance must not resume the chain until
   *      `EmergencyDeallocationApplied` signals delivery (see `IVoter.setChainStatus`).
   * @param _tokenId veNFT id whose position on the chain is reduced.
   * @param _amount Chain budget root drained; subtracted from `chainAllocation` (clamped at zero).
   */
  function applyEmergencyDeallocation(uint256 _tokenId, uint128 _amount) external;

  /**
   * @notice Sets a tokenId's operator. Leaf MessageOrchestrator only.
   * @dev Unconditional overwrite that never reverts on a well-formed call; `address(0)` clears it.
   * @param _tokenId The tokenId whose operator is being assigned.
   * @param _operator The new operator address, or `address(0)` to clear.
   */
  function setOperator(uint256 _tokenId, address _operator) external;

  /**
   * @notice Spreads the tokenId's `chainAllocation` budget across gauges. Operator only.
   * @dev Reverts `ChainNotActiveOrSunset`, `LocalVotingDisabled`, `NotOperator`, `CooldownActive`,
   *      `StakeSnapshotMissing`, `ExceedsMaxGauges`, and `ChainAllocationMismatch`. Entries must be strictly
   *      ascending with non-zero amounts. An expired stake may only submit the lone `DEALLOC_GAUGE` sentinel
   *      returning its whole budget; any other list reverts `StakeExpired`. A sunset chain accepts only that
   *      same lone sentinel; any other list, empty included, reverts `SunsetDeallocOnly`.
   * @dev `payable` because a `DEALLOC_GAUGE` entry returns that amount to root in the same call, so `msg.value`
   *      must cover the quoted transport fee (excess refunded). No sentinel, no value needed.
   * @param _tokenId The tokenId to allocate with.
   * @param _gauges Full overwrite: omitted gauges are cleared, budget above `Σ _gauges` parks on `ZERO_GAUGE`.
   */
  function allocateGauges(uint256 _tokenId, GaugeAllocation[] calldata _gauges) external payable;

  /**
   * @notice Register a gauge on the voter, initializing the gauge state that
   *         settlement and allocation read.
   * @dev GaugeManager only. Settles the chain index to `block.timestamp`, then
   *      seeds the gauge's settlement cursor from the chain cursor. Reverts on
   *      the zero address and an already-registered gauge. Relationship
   *      validation is owned by `FactoryRegistry.registerGauge` in the same
   *      transaction. Emits `GaugeRegistered`, plus `GaugeActivated` when the
   *      module activates at registration.
   * @param _gauge The gauge address to register.
   * @param _activate Whether the gauge activates at registration, from the
   *                  creating module's activation policy.
   */
  function registerGauge(address _gauge, bool _activate) external;

  /**
   * @notice Activate a registered gauge so later allocations reach it instead of `ZERO_GAUGE`. Activation is
   *         one-way.
   * @dev GaugeManager only. Settles the chain index to `block.timestamp`, then settles the gauge so its cursor
   *      advances from registration to activation. Inactive gauges are never routable, so the settled window is
   *      weightless. Reverts `GaugeNotRegistered` for an unregistered gauge and `ZERO_GAUGE`, and
   *      `GaugeAlreadyActivated` for an activated gauge. Emits `GaugeActivated` with the effective activation
   *      cursor.
   * @param _gauge The registered gauge address to activate.
   */
  function activateGauge(address _gauge) external;

  /**
   * @notice Settles the chain index and then `_gauge`, returning its cumulative reward share. Permissionless.
   * @dev Returns `0` without settling for an unregistered gauge, so it never reverts. Never calls the gauge.
   * @param _gauge The gauge to settle.
   * @return _cumulativeRewardShare Cumulative capped effective-share (TOKEN units) after settling.
   */
  function settleGauge(address _gauge) external returns (uint256 _cumulativeRewardShare);

  /**
   * @notice Forfeits surplus the caller cannot distribute (Idle Gauge, Early Exit). Registered gauge only.
   * @dev Reverts `GaugeNotRegistered`. `_amount` is clamped to the headroom `ceiling - claimed - surplus`, then
   *      added to the gauge's `surplus` and to the chain-level `surplusAccrued`.
   * @param _amount The surplus the calling gauge is forfeiting.
   */
  function forfeitEmissions(uint128 _amount) external;

  /**
   * @notice Sets whether a tokenId may route weight onto activated gauges whose emission cap is zero,
   *         positioning for fee recovery while the zero cap keeps the gauge's emissions in surplus. When unset,
   *         such allocations redirect to `ZERO_GAUGE`. Inactive gauges are never routable regardless of this
   *         flag.
   * @dev `TOKEN_WHITELIST_ROLE` only.
   * @param _tokenId The tokenId whose flag is being set.
   * @param _allowed The new flag value.
   */
  function setCanVoteForZeroCapGauges(uint256 _tokenId, bool _allowed) external;

  /**
   * @notice Opens or closes the local `allocateGauges` path. `VOTER_CONFIG_ROLE` only.
   * @dev Defaults to false; while closed `allocateGauges` reverts `LocalVotingDisabled`, bridged path unchanged.
   * @param _enabled New switch value.
   */
  function setLocalVotingEnabled(bool _enabled) external;

  /**
   * @notice Sets the minimum seconds between local allocations for a tokenId. `VOTER_CONFIG_ROLE` only.
   * @param _allocationCooldown The new cooldown duration in seconds.
   */
  function setAllocationCooldown(uint48 _allocationCooldown) external;

  /**
   * @notice Sets the cap on a tokenId's accumulated cooldown reduction. `VOTER_CONFIG_ROLE` only.
   * @dev `applyCooldownReduction` clamps here instead of reverting, so a redelivery never reverts forever.
   * @dev Zero is the default and disables reductions. Any cap at or above `allocationCooldown` is unbounded.
   * @param _maxAccumulatedCooldownReduction The new accumulation cap, in seconds.
   */
  function setMaxAccumulatedCooldownReduction(uint48 _maxAccumulatedCooldownReduction) external;

  /**
   * @notice Sets the per-chain cap on gauges a tokenId may allocate to locally. `VOTER_CONFIG_ROLE` only.
   * @dev Leaf-owned; root enforces nothing here. Zero is the default and bricks `allocateGauges`.
   * @param _maxGauges The new gauge-count cap.
   */
  function setMaxGauges(uint256 _maxGauges) external;

  /**
   * @notice Sets the chain's operational status. `CHAIN_STATUS_ROLE` only.
   * @dev Rejects a `None` target (`InvalidStatus`) and same-value writes; `Suspended` only exits to `Active`
   *      or `Sunset` and `Sunset` only exits to `Suspended` (`InvalidChainStatusTransition`). Settles the
   *      index at the old rate up to the flip; a pre-settling message can bank accrual past it, so the
   *      boundary is `max(flip, lastSettlement)`.
   * @dev Reactivating a sunset leaf routes through `Suspended` first, so the in-flight deallocation set can
   *      drain before the resume — see the procedure on `IVoter.setChainStatus`.
   * @dev Entering `Suspended` or `Sunset` forces `emissionsPerVP` to zero until the first root dispatch after
   *      a resume to `Active`. `allocateGauges`, `redeem` and `mintEmissions` stay open
   *      under `Active` and `Sunset` and close under everything else; `Deallocate` still dispatches. Flip leaf
   *      before root when suspending or sunsetting and resume root before leaf, so the gap under-emits.
   * @param _status The new chain status.
   */
  function setChainStatus(ChainStatus _status) external;

  /**
   * @notice Projects a gauge's cumulative reward share to `block.timestamp` without writing.
   * @dev Equals what `settleGauge(_gauge)` would return in this block. Returns `0` for an unregistered gauge.
   * @param _gauge The gauge to project.
   * @return _cumulativeRewardShare Projected cumulative capped effective-share (TOKEN units).
   */
  function projectedCumulativeRewardShare(address _gauge) external view returns (uint256 _cumulativeRewardShare);

  /*//////////////////////////////////////////////////////////////
                                VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Sink for weight aimed at gauges that cannot receive emissions; it accrues there as surplus.
   *         Allocations to unregistered or unactivated gauges, and to zero-cap gauges the tokenId is not
   *         whitelisted for, are redirected here.
   * @return _zeroGauge The sink address (`address(0)`).
   */
  function ZERO_GAUGE() external view returns (address _zeroGauge);

  /**
   * @notice Minimum redeem amount, `1_000_000` (one unit in pips), so the Splitter share cannot round to zero.
   * @return _minRedeemAmount The minimum redeem amount.
   */
  function MIN_REDEEM_AMOUNT() external view returns (uint256 _minRedeemAmount);

  /**
   * @notice Leaf-side messaging orchestrator this voter dispatches through. Set at deployment, immutable.
   * @return _orchestrator The bound leaf messaging orchestrator.
   */
  function ORCHESTRATOR() external view returns (ILeafMessageOrchestrator _orchestrator);

  /**
   * @notice `ReceiptToken` burned on redeem. Set at deployment, immutable.
   * @return _receiptToken The bound `ReceiptToken`.
   */
  function RECEIPT_TOKEN() external view returns (IReceiptToken _receiptToken);

  /**
   * @notice `EmissionsHandler` that receives `ReceiptToken` from `mintEmissions` and the callback.
   * @return _emissionsHandler Configured handler.
   */
  function EMISSIONS_HANDLER() external view returns (address _emissionsHandler);

  /**
   * @notice FactoryRegistry queried for per-gauge emission caps and reward
   *         contracts during settlement. Set at deployment, immutable.
   * @return _factoryRegistry The configured FactoryRegistry.
   */
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry _factoryRegistry);

  /**
   * @notice GaugeManager authorized for the gauge-lifecycle writes,
   *         `registerGauge` and `activateGauge`. Set at deployment, immutable.
   * @return _gaugeManager The configured GaugeManager.
   */
  function GAUGE_MANAGER() external view returns (address _gaugeManager);

  /**
   * @notice Operational status, `Active` by default. `allocateGauges`, `redeem` and `mintEmissions` stay open
   *         under `Active` and `Sunset` and are blocked under every other value.
   * @return _status Current chain status.
   */
  function chainStatus() external view returns (ChainStatus _status);

  /**
   * @notice Latest emissions-per-VP scalar from root; written only on a fresh message, zero while `Suspended`
   *         or `Sunset`.
   * @return _emissionsPerVP Global emissions per unit voting power, `PRECISION`-scaled.
   */
  function emissionsPerVP() external view returns (uint256 _emissionsPerVP);

  /**
   * @notice Cumulative AERO rewards per unit of chain weight; only ever increases.
   * @return _index Current accumulator index.
   */
  function index() external view returns (uint256 _index);

  /**
   * @notice Time-weighted chain accumulator: `emissionsPerVP` integrated against absolute (unix-epoch) time,
   *         stored doubled. Paired with `index` it prices a decaying gauge's share exactly across a scalar
   *         change, matching root.
   * @return _timeIndex Current time-weighted accumulator value, doubled.
   */
  function timeIndex() external view returns (uint256 _timeIndex);

  /**
   * @notice Timestamp `index` is settled to. May be ahead of `block.timestamp` after a pre-settling message.
   * @return _ts Last chain settlement timestamp.
   */
  function lastSettlement() external view returns (uint48 _ts);

  /**
   * @notice Snapshot of `index` at each weekly boundary; per-gauge settlement reads it for per-segment shares.
   * @param _boundary Weekly-aligned timestamp.
   * @return _indexSnapshot Value of `index` snapshotted at `_boundary`.
   */
  function indexAtBoundary(uint48 _boundary) external view returns (uint256 _indexSnapshot);

  /**
   * @notice Snapshot of `timeIndex` at each weekly boundary; per-gauge settlement reads it for the slope correction.
   * @param _boundary Weekly-aligned timestamp.
   * @return _timeIndexSnapshot Value of `timeIndex` snapshotted at `_boundary`.
   */
  function timeIndexAtBoundary(uint48 _boundary) external view returns (uint256 _timeIndexSnapshot);

  /**
   * @notice Whether a gauge is activated for direct allocation routing. Cheaper than reading `gaugeStates`.
   * @param _gauge Gauge address to query.
   * @return _isActivated Whether the gauge is activated.
   */
  function isActivated(address _gauge) external view returns (bool _isActivated);

  /**
   * @notice Per-gauge settlement state.
   * @param _gauge Gauge address to query.
   * @return _ceiling Cumulative effective share credited to the gauge.
   * @return _claimed Cumulative emissions minted by the claim flow.
   * @return _lastSettlement Timestamp of the gauge's last settlement.
   * @return _isRegistered Whether the gauge was produced by an approved factory.
   * @return _isActivated Whether the gauge is activated for direct allocation routing.
   * @return _surplus Cumulative surplus attributed to the gauge.
   * @return _lastIndex Snapshot of `index` at the gauge's last settlement.
   * @return _lastTimeIndex Snapshot of `timeIndex` at the gauge's last settlement.
   * @return _point Decaying weight of the gauge.
   */
  function gaugeStates(address _gauge)
    external
    view
    returns (
      uint128 _ceiling,
      uint128 _claimed,
      uint48 _lastSettlement,
      bool _isRegistered,
      bool _isActivated,
      uint128 _surplus,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      Point memory _point
    );

  /**
   * @notice Scheduled slope reduction for a gauge at a weekly expiry boundary.
   * @param _gauge Gauge address to query.
   * @param _expiry Expiry timestamp.
   * @return _slopeDelta Slope reduction scheduled at `_expiry`.
   */
  function gaugeSlopeChanges(address _gauge, uint48 _expiry) external view returns (int128 _slopeDelta);

  /**
   * @notice Packed per-tokenId allocation state.
   * @dev `chainAllocation` is raised by `applyChainAllocation`, cut by `applyEmergencyDeallocation` (clamped at
   *      zero), and bounds the incoming gauge sum.
   * @param _tokenId veNFT id to query.
   * @return _operator The tokenId's operator, or `address(0)` if unset.
   * @return _lastAllocated Last-allocated timestamp.
   * @return _canVoteForZeroCapGauges True when the token may route weight onto activated zero-cap gauges.
   * @return _chainAllocation Chain allocation budget for the tokenId.
   */
  function tokenStates(uint256 _tokenId)
    external
    view
    returns (address _operator, uint48 _lastAllocated, bool _canVoteForZeroCapGauges, uint128 _chainAllocation);

  /**
   * @notice Shape the token's booked gauge weight is measured with. Read by reward contracts at checkpoint.
   * @param _tokenId veNFT id to query.
   * @return _staked AERO staked in the position at dispatch time.
   * @return _stakeEnd Stake expiry; `0` for a permanent stake.
   * @return _isPermanent True for a permanent stake.
   */
  function tokenSnapshot(uint256 _tokenId) external view returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent);

  /**
   * @notice Newest root-dispatched `TokenSnapshot` for a tokenId, applied or not.
   * @dev Never behind `tokenSnapshot`; the next gauge-iterating operation consumes it and the two match again.
   * @param _tokenId veNFT id to query.
   * @return _staked AERO staked in the position at dispatch time.
   * @return _stakeEnd Stake expiry; `0` for a permanent stake.
   * @return _isPermanent True for a permanent stake.
   */
  function latestTokenSnapshot(uint256 _tokenId)
    external
    view
    returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent);

  /**
   * @notice Per-`(tokenId, effective gauge)` allocated weight; redirected weight aggregates on `ZERO_GAUGE`.
   * @param _tokenId veNFT id to query.
   * @param _gauge Effective gauge address to query.
   * @return _allocated Weight the tokenId currently has on the gauge.
   */
  function allocations(uint256 _tokenId, address _gauge) external view returns (uint128 _allocated);

  /**
   * @notice Cumulative AERO on this chain that will not be redeemed; only ever increases, sent in every REDEEM.
   * @return _surplus Cumulative surplus.
   */
  function surplusAccrued() external view returns (uint256 _surplus);

  /**
   * @notice Whether the local `allocateGauges` path is open. False until governance opens it.
   * @return _enabled Current switch value.
   */
  function localVotingEnabled() external view returns (bool _enabled);

  /**
   * @notice Minimum seconds between local allocations for a tokenId.
   * @return _cooldown Cooldown duration.
   */
  function allocationCooldown() external view returns (uint48 _cooldown);

  /**
   * @notice Cap on a tokenId's accumulated cooldown reduction. Zero, the default, disables reductions.
   * @return _maxAccumulatedCooldownReduction The accumulation cap, in seconds.
   */
  function maxAccumulatedCooldownReduction() external view returns (uint48 _maxAccumulatedCooldownReduction);

  /**
   * @notice Per-chain cap on gauges a tokenId may allocate to locally. Leaf-owned; root holds no equivalent.
   * @return _maxGauges The gauge-count cap.
   */
  function maxGauges() external view returns (uint256 _maxGauges);

  /**
   * @notice Reduction accrued for a tokenId, in seconds; the next allocation consumes it, clamped to the cooldown.
   * @param _tokenId veNFT id.
   * @return _reduction Accumulated reduction in seconds, or zero if none.
   */
  function accumulatedCooldownReduction(uint256 _tokenId) external view returns (uint48 _reduction);

  /*//////////////////////////////////////////////////////////////
                                  VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Operator authorized to run the local `allocateGauges` for a tokenId.
   * @param _tokenId veNFT id to query.
   * @return _operator The tokenId's operator, or `address(0)` if unset.
   */
  function operator(uint256 _tokenId) external view returns (address _operator);

  /**
   * @notice Effective gauges the tokenId has weight on. Excludes `ZERO_GAUGE`: read parked weight with
   *         `allocations(_tokenId, ZERO_GAUGE)`.
   * @param _tokenId veNFT id to query.
   * @return _gauges The set's values as a memory array.
   */
  function allocatedGauges(uint256 _tokenId) external view returns (address[] memory _gauges);
}
