// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @title IVoter
 * @notice Root-chain Voter: types, errors and external surface for spreading veNFT voting power across chains.
 *         `CHAIN0` is the idle sink where parked power earns nothing; `TOKEN0` holds burned permanent power.
 */
interface IVoter is IVoterCommon, IAccessControl {
  /*//////////////////////////////////////////////////////////////
                                 STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice One chain's additive voting-power delta plus its dispatch params.
   * @dev `allocateChains` is additive and partial and owns only the chain-level ledger; gauges are an
   *      `allocateGauges` / `allocate` concern.
   * @param chainId Target chain identifier; strictly ascending across the input array, `CHAIN0` absent.
   * @param delta AERO to ADD to this chain, drawn only from CHAIN0-parked power. `0` is a refresh poke.
   * @param gasLimit Destination gas for the leaf `handle()` call. Zero only for the in-process root-chain entry.
   * @param value Native fee forwarded to the orchestrator. Zero only for the root-chain entry.
   */
  struct ChainAllocationDispatch {
    uint256 chainId;
    uint128 delta;
    uint256 gasLimit;
    uint256 value;
  }

  /**
   * @notice One chain's gauge distribution in a composed `allocate` call, with its dispatch params.
   * @dev `allocate` checks the list against the `allocationChainAmounts` written earlier in the same call, then
   *      runs the `allocateGauges` core, so `DEALLOC_GAUGE` is accepted and its return cost comes from `value`.
   * @param chainId Target chain identifier; strictly ascending across the `_gaugeDispatches` array.
   * @param gasLimit Destination gas for the leaf `handle()` call. Zero only for the in-process root-chain entry.
   * @param value Native fee forwarded to the orchestrator for this chain's gauge message.
   * @param gauges Per-gauge allocations on `chainId`, strictly ascending by gauge address.
   */
  struct GaugeAllocationDispatch {
    uint256 chainId;
    uint256 gasLimit;
    uint256 value;
    GaugeAllocation[] gauges;
  }

  /**
   * @notice Reward claim request and dispatch params for one chain.
   * @param chainId Target chain identifier; strictly ascending across the input array.
   * @param gasLimit Destination gas for the leaf `ClaimRewards` handler. Zero only for the in-process root chain.
   * @param value Native fee forwarded to the orchestrator. Zero only for the root-chain entry.
   * @param recipient Address that receives claimed rewards on the leaf.
   * @param feeClaims Fee claim requests forwarded to the leaf voter.
   * @param incentiveClaims Incentive claim requests forwarded to the leaf voter.
   */
  struct ClaimRewardsParams {
    uint256 chainId;
    uint256 gasLimit;
    uint256 value;
    address recipient;
    ILeafVoter.FeeClaim[] feeClaims;
    ILeafVoter.IncentiveClaim[] incentiveClaims;
  }

  /**
   * @notice Per-tokenId record written on every `allocateChains`.
   * @param committed AERO size at the last allocation; unmoved when VE `staked` grows without a new allocation.
   * @param lastStakeEnd Stake expiry at the last allocation; `0` for a permanent stake.
   * @param lastAllocated Timestamp of the last chain-level allocation.
   * @param isPermanent True for a permanent stake; the permanence signal the point math reads.
   */
  struct TokenState {
    uint128 committed;
    uint48 lastStakeEnd;
    uint48 lastAllocated;
    bool isPermanent;
  }

  /**
   * @notice Per-chain state read and written together along the allocate, settle and redeem pipelines.
   * @dev Ceiling accrues the chain weight against the global scalar over each week segment, exact for permanent
   *      and decaying stakes alike. It reads two global accumulators: `index` (the scalar summed over time) and
   *      `timeIndex` (the scalar summed weighted by absolute unix-epoch time, doubled). A decaying segment credits
   *      its end weight against the first plus a slope correction from the second, so an infrequently-settled
   *      chain accrues the same as a finely-settled one. With `Σ chainWeight == totalWeight`, `Σ ceilings` tracks
   *      the minter schedule.
   * @param point Aggregate voting power for the chain.
   * @param ceiling Cumulative emissions the chain may claim.
   * @param totalRedeemed Total `TOKEN` minted for the chain via redeem. Only ever increases.
   * @param reportedSurplus High-water mark of unused-emissions surplus reported to root. Only ever increases.
   *        Feeds the chain's `spendSurplus` pot, clamped there to `ceiling - totalRedeemed`. May exceed that
   *        entitlement when the accepting redeem was backed by the donated buffer.
   * @param cumulativeSuspendedSurplus Would-be ceiling growth caught while the chain is `Suspended`. Only ever
   *        increases. Part of the chain's `spendSurplus` pot, netted against `surplusSpent`.
   * @param surplusSpent Cumulative surplus minted via `spendSurplus`. Only ever increases. Netted against the
   *        chain's pot to bound further spends.
   * @param lastIndex The chain's cursor into the global `index`, set at its last ceiling settlement.
   * @param lastTimeIndex The chain's cursor into the global `timeIndex`, set at its last ceiling settlement.
   * @param donatedBuffer Donated `TOKEN` held for the chain's redeems, drawn once its ceiling is exhausted.
   * @param status Operational status of the chain.
   */
  struct ChainState {
    Point point;
    uint256 ceiling;
    uint256 totalRedeemed;
    uint256 reportedSurplus;
    uint256 cumulativeSuspendedSurplus;
    uint256 surplusSpent;
    uint256 lastIndex;
    uint256 lastTimeIndex;
    uint256 donatedBuffer;
    ChainStatus status;
  }

  /**
   * @notice Live external state read once at the top of an allocation call, before anything is dispatched.
   * @dev Every dispatch hands control to a caller-supplied refund address that can reenter the VotingEscrow,
   *      outside this contract's guard; reading once keeps every message of one call on the same position.
   * @param staked Live VE staked amount.
   * @param stakeEnd Live VE stake expiry; `0` for a permanent stake.
   * @param emissionRate Minter emission rate backing every root rate and payload in the call.
   * @param isPermanent True for a permanent stake, carried through to the leaf snapshot.
   */
  struct AllocationSnapshot {
    uint128 staked;
    uint48 stakeEnd;
    uint256 emissionRate;
    bool isPermanent;
  }

  /**
   * @notice Per-tokenId token and VE state read once when the allocation pipeline starts. Pipeline-local.
   * @param veStaked Current VE-staked AERO; the cap the booked total must stay within.
   * @param prevCommitted The token's booked total at the prior allocation.
   * @param veStakeEnd Current stake expiry; `0` for a permanent stake.
   * @param oldStakeEnd `tokenStates[_tokenId].lastStakeEnd` at the prior allocation.
   * @param veIsPermanent True for the live permanent stake, shipped to the leaf snapshot and used by the point math.
   * @param oldIsPermanent True for the stored permanent shape (`tokenStates[_tokenId].isPermanent`).
   */
  struct AllocationContext {
    uint128 veStaked;
    uint128 prevCommitted;
    uint48 veStakeEnd;
    uint48 oldStakeEnd;
    bool veIsPermanent;
    bool oldIsPermanent;
  }

  /*//////////////////////////////////////////////////////////////
                                 EVENTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Emitted when permanent voting power parked on `TOKEN0` / `CHAIN0` is burned.
   * @param _caller Address that triggered the burn (the VotingEscrow's default VPM).
   * @param _amount AERO removed from `TOKEN0`'s committed and from the chain0 and total permanent balances.
   */
  event Burned(address indexed _caller, uint128 _amount);

  /**
   * @notice Emitted when a batch of chain0 allocation moves is mirrored from a VotingEscrow rebalance.
   * @param _sources Source deltas drained from the chain0 ledger, as forwarded by VotingEscrow.
   * @param _destinations Destination deltas credited to the chain0 ledger, mint sentinels already resolved.
   */
  event Chain0Rebalanced(IVotingEscrow.SourceDelta[] _sources, IVotingEscrow.DestinationDelta[] _destinations);

  /**
   * @notice Emitted when a cooldown reduction is dispatched to a leaf. Root keeps no reduction state.
   * @param _tokenId veNFT id whose cooldown reduction is being dispatched.
   * @param _chainId Destination chain the reduction applies to.
   * @param _reduction Reduction shipped to the leaf, in seconds.
   */
  event CooldownReductionDispatched(uint256 indexed _tokenId, uint256 indexed _chainId, uint48 _reduction);

  /**
   * @notice Emitted when a reward claim is dispatched to a leaf.
   * @param _tokenId veNFT id whose rewards are being claimed.
   * @param _chainId Destination chain the reward claim targets.
   * @param _recipient Address that receives any claimed rewards.
   */
  event RewardsClaimDispatched(uint256 indexed _tokenId, uint256 indexed _chainId, address indexed _recipient);

  /**
   * @notice Emitted when a `Redeem` message is processed and the recipient is paid.
   * @param _chainId Source chain id of the processed redeem message.
   * @param _recipient Address that received the `TOKEN`.
   * @param _amount Amount of `TOKEN` the recipient received, minted and, past the ceiling, paid from the
   *                chain's donated buffer.
   * @param _surplusReported Reported surplus high-water mark recorded for the chain after the redeem.
   */
  event RedeemProcessed(
    uint256 indexed _chainId, address indexed _recipient, uint256 _amount, uint256 _surplusReported
  );

  /**
   * @notice Emitted when `TOKEN` is donated into a chain's redeem buffer.
   * @param _chainId Chain whose donated buffer was credited.
   * @param _donor Address the donation was pulled from.
   * @param _amount Amount of `TOKEN` added to the buffer.
   */
  event Donated(uint256 indexed _chainId, address indexed _donor, uint256 _amount);

  /**
   * @notice Emitted when a redeem draws on a chain's donated buffer for the part its ceiling cannot cover.
   * @param _chainId Chain whose donated buffer was drawn.
   * @param _amount Amount of `TOKEN` paid out of the buffer instead of minted.
   */
  event BufferDrawn(uint256 indexed _chainId, uint256 _amount);

  /**
   * @notice Emitted when a `Deallocate` message is processed and the power is credited back to `CHAIN0`.
   * @param _chainId Origin chain id the voting power was deallocated from.
   * @param _tokenId veNFT id whose voting power was returned to `CHAIN0`.
   * @param _amount Voting power credited to `CHAIN0`, clamped to the token's origin-chain balance.
   */
  event DeallocationProcessed(uint256 indexed _chainId, uint256 indexed _tokenId, uint128 _amount);

  /**
   * @notice Emitted when a token owner pulls power off a `Suspended` chain via `emergencyDeallocate`.
   * @param _chainId Chain id the voting power was pulled from.
   * @param _tokenId veNFT id whose voting power was returned to `CHAIN0`.
   * @param _amount Voting power credited to `CHAIN0`, equal to the token's booked balance on the chain.
   */
  event EmergencyDeallocated(uint256 indexed _chainId, uint256 indexed _tokenId, uint128 _amount);

  /**
   * @notice Emitted when a token's chain budgets are allocated via `allocateChains` or `allocate`.
   * @param _tokenId veNFT id whose chain allocation was applied.
   * @param _allocations The per-chain dispatch batch; each `delta` is added to that chain's booked budget.
   */
  event ChainsAllocated(uint256 indexed _tokenId, ChainAllocationDispatch[] _allocations);

  /**
   * @notice Emitted when a token's gauge distribution for a chain is dispatched to the leaf.
   * @param _tokenId veNFT id whose gauges were allocated.
   * @param _chainId Destination chain the gauge distribution targets.
   * @param _gauges The requested per-gauge allocation shipped to the leaf.
   */
  event GaugesAllocated(uint256 indexed _tokenId, uint256 indexed _chainId, GaugeAllocation[] _gauges);

  /**
   * @notice Emitted when a withdrawn token's root allocation ledger is cleared.
   * @param _tokenId veNFT id whose ledger was cleared.
   * @param _clearedChains Chains the token still had booked amounts on, all dropped by this call.
   */
  event TokenCleared(uint256 indexed _tokenId, uint256[] _clearedChains);

  /**
   * @notice Emitted when a token's unbooked voting power is parked onto `CHAIN0` via `parkOnChain0`.
   * @param _tokenId veNFT id whose voting power was parked.
   * @param _amount Voting power booked onto `CHAIN0`.
   */
  event ParkedOnChain0(uint256 indexed _tokenId, uint128 _amount);

  /**
   * @notice Emitted when the gauge-message lifetime is updated.
   * @param _allocationLifetime New lifetime in seconds, stamped onto every gauge dispatch as an absolute expiry.
   */
  event AllocationLifetimeSet(uint48 _allocationLifetime);

  /**
   * @notice Emitted when the claim and operator message lifetime is updated.
   * @param _messageLifetime New lifetime in seconds, stamped onto every claim and operator dispatch as an absolute
   *                       expiry.
   */
  event MessageLifetimeSet(uint48 _messageLifetime);

  /**
   * @notice Emitted when a new chain is registered.
   * @param _chainId Newly registered chain id.
   */
  event ChainRegistered(uint256 indexed _chainId);

  /**
   * @notice Emitted when a chain's operational status changes.
   * @param _chainId Chain whose status was updated.
   * @param _status New status.
   */
  event ChainStatusSet(uint256 indexed _chainId, ChainStatus _status);

  /**
   * @notice Emitted when a chain's emergency-deallocation authorization switch is set.
   * @param _chainId Chain whose switch was updated.
   * @param _allowed `true` authorizes `emergencyDeallocate` for the current suspension.
   */
  event EmergencyDeallocationAllowedSet(uint256 indexed _chainId, bool _allowed);

  /**
   * @notice Emitted when a tokenId's per-chain operator is updated.
   * @param _tokenId Token whose operator was updated.
   * @param _chainId Chain the operator applies to.
   * @param _operator New operator address. Zero clears the slot.
   */
  event OperatorSet(uint256 indexed _tokenId, uint256 indexed _chainId, address _operator);

  /**
   * @notice Emitted when governance mints accumulated surplus via `spendSurplus`.
   * @param _chainId Chain whose surplus pot was spent.
   * @param _recipient Address that received the minted `TOKEN`.
   * @param _amount Amount of `TOKEN` minted from the pot.
   */
  event SurplusSpent(uint256 indexed _chainId, address indexed _recipient, uint256 _amount);

  /*//////////////////////////////////////////////////////////////
                                 ERRORS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Thrown when an operation requires an `Active` chain.
   * @param _chainId Chain that is not `Active`.
   */
  error ChainNotActive(uint256 _chainId);

  /**
   * @notice Thrown when an operation is unavailable while a chain is `Paused`.
   * @param _chainId Chain that is `Paused`.
   */
  error ChainPaused(uint256 _chainId);

  /**
   * @notice Thrown when a dispatch targets a chain that is neither `Active` nor `Sunset`.
   * @param _chainId Chain that does not accept dispatches.
   */
  error ChainNotActiveOrSunset(uint256 _chainId);

  /// @notice Thrown when a redeem plus the reserved surplus cannot be covered by the ceiling and donated buffer.
  error CeilingExceeded();

  /// @notice Thrown when the caller is not authorized to call the function.
  error NotAuthorized();

  /**
   * @notice Thrown by `allocateGauges` / `allocate` when Σ gauge `allocated` — including any `DEALLOC_GAUGE` or
   *         explicit `ZERO_GAUGE` idle entry — does not exactly equal the token's power booked on the chain.
   * @dev Root repeats the leaf's check, so a mis-summed vote is rejected before dispatch, not after a round trip.
   * @param _chainId Chain whose booked allocation the gauge sum did not match.
   */
  error ChainAllocationMismatch(uint256 _chainId);

  /**
   * @notice Thrown by `allocate` when `_gaugeDispatches` chainIds are not strictly ascending, which also
   *         rejects duplicates and `CHAIN0`.
   */
  error GaugeDispatchesNotStrictlyAscending();

  /**
   * @notice Thrown when a non-root-chain dispatch entry carries a zero `gasLimit`. The root-chain entry
   *         (`chainId == block.chainid`) is exempt: it is forwarded in-process with no destination metering.
   * @param _chainId Chain missing a `gasLimit`.
   */
  error MissingDestinationGasLimit(uint256 _chainId);

  /**
   * @notice Thrown when allocation chainIds are not strictly ascending, which also rejects duplicates and
   *         `CHAIN0`.
   */
  error AllocationsNotStrictlyAscending();

  /// @notice Thrown when claim chainIds are not strictly ascending, which also rejects duplicates and `CHAIN0`.
  error ClaimRewardsParamsNotStrictlyAscending();

  /// @notice Thrown when `claimRewards` is called without any per-chain params or a param contains no reward claims.
  error EmptyClaimRewardsParams();

  /// @notice Thrown by `burn` when the requested amount exceeds `tokenStates[TOKEN0].committed`.
  error InsufficientCommitted();

  /// @notice Thrown by `burn` or `rebalanceChain0` when the amount exceeds a source's chain0 allocation.
  error InsufficientChain0Allocation();

  /**
   * @notice Thrown by `rebalanceChain0` when a destination already holding chain0 allocation has a stored
   *         `lastStakeEnd` that differs from the live VE stake expiry.
   * @dev Reconcile it via `allocateChains` first, otherwise its old and new entries would span two stakeEnds.
   */
  error DstShapeStale();

  /**
   * @notice Thrown by the standalone `allocateGauges` when the live stake shape no longer matches the stored
   *         root shape (`lastStakeEnd`).
   * @dev The gauge path does not re-anchor root's chain state, so a mismatch would desync leaf gauge accrual
   *      from the ceiling. Reconcile with an empty `allocateChains(tokenId, [], recipient)` and retry.
   */
  error StaleShape();

  /**
   * @notice Thrown by the gauge dispatch path when the token has been withdrawn (`staked == 0`).
   * @dev A withdrawn token holds no allocation on any chain, so its only gauge message is the empty no-op.
   *      Blocking it stops a `{staked: 0, stakeEnd: 0}` shape from ever reaching a leaf, where it would be
   *      mistaken for a permanent stake.
   */
  error StakeWithdrawn();

  /// @notice Thrown by `reduceCooldown` when `msg.sender` does not pass `VotingEscrow.isAuthorizedVPM`.
  error NotVoterPaymentsModule();

  /// @notice Thrown by a VotingEscrow-only entrypoint when the caller is not the VotingEscrow.
  error NotVotingEscrow();

  /**
   * @notice Thrown when an `allocationLifetime` below `MIN_MESSAGE_LIFETIME` is configured, a lifetime short enough
   *         to expire gauge dispatches in transit.
   */
  error AllocationLifetimeTooLow();

  /**
   * @notice Thrown when an `allocationLifetime` above `MAX_MESSAGE_LIFETIME` is configured, a lifetime long enough
   *         to push the stamped uint48 expiry toward overflow.
   */
  error AllocationLifetimeTooHigh();

  /**
   * @notice Thrown when a `messageLifetime` below `MIN_MESSAGE_LIFETIME` is configured, a lifetime short enough to
   *         expire claim and operator dispatches in transit.
   */
  error MessageLifetimeTooLow();

  /**
   * @notice Thrown when a `messageLifetime` above `MAX_MESSAGE_LIFETIME` is configured, a lifetime long enough to
   *         push the stamped uint48 expiry toward overflow.
   */
  error MessageLifetimeTooHigh();

  /// @notice Thrown by `burn` when `_amount` is zero, a call that would only emit a misleading event.
  error ZeroAmount();

  /// @notice Thrown by `reduceCooldown` when the requested reduction is zero, a no-op message.
  error ZeroReduction();

  /// @notice Thrown when `clearToken` targets `TOKEN0`, which holds burned power and is not a user token.
  error Token0NotClearable();

  /// @notice Thrown when a per-chain setter is called with `CHAIN0`, whose state is fixed at construction.
  error Chain0NotConfigurable();

  /**
   * @notice Thrown when `registerChain` is called for an already registered chain.
   * @param _chainId Chain that was already registered.
   */
  error ChainAlreadyRegistered(uint256 _chainId);

  /**
   * @notice Thrown when a per-chain setter targets a chain that has not been registered.
   * @param _chainId Chain that is not in `_chains`.
   */
  error ChainNotRegistered(uint256 _chainId);

  /**
   * @notice Thrown by `processRedeem` when the origin chain is `Suspended`: redeem mints on root, so it waits
   *         for resume and the transport redelivers.
   */
  error RouteSuspended();

  /**
   * @notice Thrown when `emergencyDeallocate` targets a chain that is not `Suspended`.
   * @param _chainId Chain whose status is not `Suspended`.
   */
  error ChainNotSuspended(uint256 _chainId);

  /**
   * @notice Thrown when `emergencyDeallocate` runs on a chain whose emergency switch is off.
   * @dev Governance enables it per suspension via `setEmergencyDeallocationAllowed`; it resets on every suspend.
   * @param _chainId Chain whose switch is not enabled.
   */
  error EmergencyDeallocationNotAllowed(uint256 _chainId);

  /// @notice Thrown when `emergencyDeallocate` targets a token with nothing booked on the suspended chain.
  error NothingToDeallocate();

  /**
   * @notice Thrown when `spendSurplus` requests more than the chain's spendable surplus.
   * @param _chainId Chain whose pot was insufficient.
   * @param _spendable Spendable surplus after settling the chain.
   */
  error InsufficientSurplus(uint256 _chainId, uint256 _spendable);

  /*//////////////////////////////////////////////////////////////
                                EXTERNAL
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Add voting power to the tokenId's chains — additive and partial, chain-level ledger only.
   * @dev Approved-or-owner of `_tokenId` per `VotingEscrow`. Each `delta` is ADDED to that chain from
   *      CHAIN0-parked power (`Σ delta ≤ chain0Parked`, else `InsufficientChain0Allocation`); unbooked power
   *      must pass `parkOnChain0` first, and reductions go leaf-first through `deallocate`, never here.
   * @dev A `delta == 0` entry is a refresh poke, allowed on any Active chain even with no position there, that
   *      makes the leaf settle its index and re-read `emissionsPerVP`. A changed stake shape re-anchors every
   *      allocated chain locally, with no extra messages.
   * @param _tokenId veNFT id to allocate with.
   * @param _chainDispatches Per-chain delta + dispatch params; strictly ascending chainIds, `CHAIN0` absent.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function allocateChains(
    uint256 _tokenId,
    ChainAllocationDispatch[] calldata _chainDispatches,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Distribute a tokenId's already-assigned chain budget across gauges on one chain.
   * @dev Approved-or-owner of `_tokenId` per `VotingEscrow`. Root keeps no gauge state. The cooldown lives on the
   *      leaf, which reverts while it runs so the transport redelivers, and spends any pending reduction there.
   * @dev Full overwrite: `_gauges` must sum to EXACTLY the chain budget (else `ChainAllocationMismatch`), idle
   *      power is an explicit `ZERO_GAUGE` entry with no automatic backfill, and gauges left out are cleared.
   * @dev Open while the chain is `Active` or `Sunset`. A sunset chain only accepts the lone `DEALLOC_GAUGE`
   *      sentinel returning the whole budget; any other list, empty included, reverts `SunsetDeallocOnly`.
   *      New power cannot enter because `allocateChains` stays closed.
   * @dev An expired stake may only submit the lone `DEALLOC_GAUGE` sentinel returning its whole budget; any
   *      other list reverts `StakeExpired`.
   * @param _tokenId veNFT id to distribute gauge weight for.
   * @param _chainId Destination chain the gauges live on.
   * @param _gauges Per-gauge allocations, strictly ascending by address. Empty clears the token's gauge weight.
   * @param _gasLimit Destination gas budget for the leaf `handle()` call.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function allocateGauges(
    uint256 _tokenId,
    uint256 _chainId,
    GaugeAllocation[] calldata _gauges,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Assign chain budgets and distribute gauges for a tokenId in a single call.
   * @dev Approved-or-owner of `_tokenId` per `VotingEscrow`. Phase 1 runs the `allocateChains` pipeline, phase 2
   *      checks each gauge list against the budgets just written and runs the `allocateGauges` core, so both sets
   *      of rules apply unchanged.
   * @dev `msg.value` must equal `Σ _chainDispatches.value + Σ _gaugeDispatches.value`, else `UnexpectedValue`.
   *      Every `_gaugeDispatches` chain must be registered and `Active` or `Sunset`; a `Sunset` entry only
   *      accepts the lone `DEALLOC_GAUGE` list.
   * @param _tokenId veNFT id to allocate with.
   * @param _chainDispatches Per-chain delta + dispatch params; strictly ascending chainIds, `CHAIN0` absent.
   * @param _gaugeDispatches Per-chain gauge distributions; strictly ascending chainIds, `CHAIN0` absent.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function allocate(
    uint256 _tokenId,
    ChainAllocationDispatch[] calldata _chainDispatches,
    GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Dispatches fee and incentive reward claims to leaf voters.
   * @dev Approved-or-owner of `_tokenId` per `VotingEscrow`. Claim chainIds must be registered, `Active` or
   *      `Sunset`, and strictly ascending. A non-root entry must provide destination gas. `msg.value` must equal
   *      the sum of entry values.
   * @dev Each payload encodes `_tokenId`, an absolute expiry of `block.timestamp + messageLifetime`, the recipient,
   *      and both claim arrays. Fees are processed before incentives. The expiry bounds how long a stalled claim
   *      stays executable on the leaf: the recipient is fixed at dispatch, so without it a claim held back past a
   *      root-side token transfer could still pay the previous owner, including fees accrued after dispatch.
   * @param _tokenId veNFT id to claim rewards for.
   * @param _claimRewardsParams Per-chain reward claims and dispatch params.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function claimRewards(
    uint256 _tokenId,
    ClaimRewardsParams[] calldata _claimRewardsParams,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Donate `TOKEN` into a chain's redeem buffer, extra headroom redeems draw on once the chain's
   *         ceiling is exhausted.
   * @dev Permissionless. Pulls the amount from the caller, so it needs a prior approval. The buffer is tracked
   *      next to the ceiling, never inside it: the ceiling stays pure accrued state and donated headroom stays
   *      auditable on its own. Reverts `ChainNotRegistered` or `ZeroAmount`.
   * @param _chainId Registered chain whose donated buffer is credited.
   * @param _amount Amount of `TOKEN` to pull from the caller into the buffer.
   */
  function donate(uint256 _chainId, uint256 _amount) external;

  /**
   * @notice Inbound handler for `Redeem` messages from a leaf chain.
   * @dev `ORCHESTRATOR` only. Applies the surplus max rule and the buffer solvency check before paying. The
   *      part of the amount the ceiling covers is minted; any remainder is paid from the chain's donated
   *      buffer, which keeps supply neutral for donated headroom. Reverts `CeilingExceeded` when the buffer
   *      cannot cover the payout the ceiling headroom leaves unpaid, so the transport redelivers once accrual
   *      or donations cover it. A surplus report may be stored past the chain's mint entitlement;
   *      `spendableSurplus` clamps that excess out of the pot, so the buffer never funds a surplus mint.
   * @dev A minted leg below the Minter's `MIN_MINT_AMOUNT` is paid entirely from the buffer when it can
   *      absorb the full amount, so a sliver of headroom never stalls a covered redeem; otherwise the mint
   *      reverts `AmountTooLow` and the transport redelivers once enough headroom accrues.
   * @param _originChainId Source chain id of the inbound `Redeem` message.
   * @param _amount Amount of `TOKEN` to pay the recipient.
   * @param _recipient Address that receives the `TOKEN`.
   * @param _surplusAccrued Surplus accumulator snapshot reported by the leaf chain.
   */
  function processRedeem(uint256 _originChainId, uint256 _amount, address _recipient, uint256 _surplusAccrued) external;

  /**
   * @notice Inbound handler for a `Deallocate` message: credit the power back to the token's `CHAIN0` balance
   *         once the leaf confirms the removal.
   * @dev `ORCHESTRATOR` only. Clamps `_amount` to the token's current origin-chain allocation, so a late or
   *      duplicate message credits nothing, then moves it to `CHAIN0` at the stored shape and refreshes rates.
   * @dev Carries no reentrancy guard, so a root-colocated leaf's synchronous return can land while the
   *      allocation entrypoint that started it still holds the shared guard.
   * @param _originChainId Origin chain id the voting power was deallocated from.
   * @param _tokenId veNFT id whose voting power is being returned.
   * @param _amount Voting power the leaf reports as deallocated; clamped on receipt.
   */
  function processDeallocation(uint256 _originChainId, uint256 _tokenId, uint128 _amount) external;

  /**
   * @notice Pull a token's booked voting power off a `Suspended` chain back to `CHAIN0`, without the leaf
   *         confirmation that chain can no longer send, and ship the leaf a matching unwind.
   * @dev Token owner or approved operator; `msg.value` funds the transport fee and excess is refunded. Reverts
   *      `ChainNotSuspended`, `EmergencyDeallocationNotAllowed` (see `setEmergencyDeallocationAllowed`),
   *      `NothingToDeallocate`, or `MissingDestinationGasLimit` on a zero `_gasLimit` for a non-root chain.
   * @dev Full-drains at the stored shape through the same credit path as `processDeallocation`, so a later leaf
   *      `deallocate` clamps to zero. The chain MUST NOT resume before the unwind lands — see `setChainStatus`.
   *      A sunset chain keeps its normal exit paths; when its leaf or transport goes dark mid wind-down,
   *      governance flips it to `Suspended` and this becomes the exit of last resort.
   * @param _tokenId veNFT id whose voting power is being pulled back.
   * @param _chainId Suspended chain id to pull the voting power from.
   * @param _gasLimit Destination gas budget for the leaf `handle()` call.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function emergencyDeallocate(
    uint256 _tokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Book a token's unbooked voting power (`staked - committed`) onto `CHAIN0`, where it earns nothing but
   *         becomes available to chain allocations, VPM rebalances, `burn` and stake reshapes.
   * @dev VotingEscrow only (`NotVotingEscrow`); it calls this on every deposit and on every shape change it does
   *      not otherwise report, so the ledger mirrors the live stake. An expired stake reverts `StakeExpired`.
   * @dev Anchors at the live `stakeEnd`, re-anchoring an older-shape position first, so it never reverts on a
   *      stale shape. Leaves `lastAllocated` untouched, so parking never moves the cooldown anchor.
   * @param _tokenId veNFT id whose unbooked voting power is parked.
   */
  function parkOnChain0(uint256 _tokenId) external;

  /**
   * @notice Drop a withdrawn token's root allocation ledger so a later revival starts from a clean slate.
   * @dev VotingEscrow only (`NotVotingEscrow`), called from `withdraw` once the stake is zeroed. Clears
   *      `tokenStates` and every `allocationChainAmounts` entry; `TOKEN0` reverts `Token0NotClearable`, and a
   *      second call does nothing. A stale `lastStakeEnd` would revive the position at the wrong shape.
   * @dev Deliberately touches no weight: the expired stake's bias already decayed to zero, so unwinding the
   *      points would subtract twice and break `Σ per-chain == totalPoint`. No ceiling or scalar is resampled.
   * @param _tokenId veNFT id being cleared.
   */
  function clearToken(uint256 _tokenId) external;

  /**
   * @notice Burn voting power parked on `TOKEN0` / `CHAIN0`.
   * @dev `VOTING_ESCROW` only; it burns the matching accumulator stake and forwards the burn here.
   * @param _amount AERO amount to burn from `tokenStates[TOKEN0].committed`.
   */
  function burn(uint128 _amount) external;

  /**
   * @notice Mirror a batch of `rebalanceUnderlying` moves onto the chain0 ledger.
   * @dev `VOTING_ESCROW` only. Sources are drained and destinations credited independently: `rebalanceUnderlying`
   *      conserves totals, so the per-tokenId net deltas hold however the equal totals are sliced, and a source
   *      equal to a destination is allowed: its legs cancel out.
   * @dev Settles chain0 and `totalPoint` once for the batch, then recomputes chain0's rate once. Stake-end
   *      ordering is left to VotingEscrow; only `InsufficientChain0Allocation` and `DstShapeStale` are checked.
   * @param _sources Source deltas drained from the chain0 ledger, as forwarded by VotingEscrow.
   * @param _destinations Destination deltas credited to the chain0 ledger, mint sentinels already resolved.
   */
  function rebalanceChain0(
    IVotingEscrow.SourceDelta[] calldata _sources,
    IVotingEscrow.DestinationDelta[] calldata _destinations
  ) external;

  /**
   * @notice Dispatch a cooldown reduction for `_tokenId` to a leaf.
   * @dev Caller must pass `VOTING_ESCROW.isAuthorizedVPM`. `_reduction` must be non-zero, `_chainId` registered
   *      and `Active` or `Sunset`, `_gasLimit` non-zero off the root chain; `msg.value` funds the transport fee.
   *      Open under `Sunset` so a holder deep in cooldown can still land the exit vote before it expires.
   * @dev Root stores nothing: the leaf accrues the reduction additively and spends it, clamped to its
   *      `allocationCooldown`, on the next gauge allocation, so grants stack and message order does not matter.
   * @param _tokenId veNFT id whose cooldown is being reduced.
   * @param _chainId Destination chain the reduction applies to.
   * @param _reduction Requested reduction in seconds, added to the leaf's pending reduction.
   * @param _gasLimit Destination gas budget for the leaf `handle()` call.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function reduceCooldown(
    uint256 _tokenId,
    uint256 _chainId,
    uint48 _reduction,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Set the gauge-message lifetime stamped onto every gauge dispatch as an absolute expiry.
   * @dev `VOTER_CONFIG_ROLE`. The leaf rejects an expired message with `AllocationExpired`, so a lifetime below
   *      `MIN_MESSAGE_LIFETIME` reverts `AllocationLifetimeTooLow` here rather than expiring dispatches in transit.
   *      A lifetime above `MAX_MESSAGE_LIFETIME` reverts `AllocationLifetimeTooHigh` so the stamped expiry can
   *      never overflow uint48.
   * @param _allocationLifetime New lifetime, in seconds.
   */
  function setAllocationLifetime(uint48 _allocationLifetime) external;

  /**
   * @notice Set the message lifetime stamped onto every claim and operator dispatch as an absolute expiry.
   * @dev `VOTER_CONFIG_ROLE`. Bounds how long a dispatched claim or operator update stays executable on the leaf:
   *      past the expiry the leaf drops it with `ExpiredMessageDropped`, so a stalled message cannot land after the
   *      token changed hands on root. A lifetime below `MIN_MESSAGE_LIFETIME` reverts `MessageLifetimeTooLow` here
   *      rather than expiring dispatches in transit. A lifetime above `MAX_MESSAGE_LIFETIME` reverts
   *      `MessageLifetimeTooHigh` so the stamped expiry can never overflow uint48.
   * @param _messageLifetime New lifetime, in seconds.
   */
  function setMessageLifetime(uint48 _messageLifetime) external;

  /**
   * @notice Register a new chain with the protocol.
   * @dev `CHAIN_CONFIG_ROLE`. Seeds the chain's settlement cursors and sets `Active`. Reverts on `CHAIN0`, whose
   *      state is fixed at construction, and on an already registered chain.
   * @param _chainId Chain id to register.
   */
  function registerChain(uint256 _chainId) external;

  /**
   * @notice Update a registered chain's operational status.
   * @dev `CHAIN_STATUS_ROLE`. Reverts on `CHAIN0`, unregistered chains, a `None` target and same-value writes;
   *      `Suspended` only exits to `Active` or `Sunset`, `Sunset` only exits to `Suspended`, and entering
   *      `Suspended` resets
   *      `emergencyDeallocationAllowed` to `false`. Root and leaf are set independently:
   *      suspend or sunset leaf first, resume root first, so the gap under-emits.
   * @dev Before resuming from `Suspended`, governance MUST first switch
   *      `setEmergencyDeallocationAllowed` off — an emergency
   *      unwind created mid-checklist would invalidate every check below — and then confirm, in this order:
   *      (1) every root->leaf message dispatched to the chain has landed or expired (`allocationLifetime` bounds
   *      the gauge-vote wait) — a straggler landing after the resume can spawn a leaf `Deallocate` or reinstall
   *      a stale pre-halt `emissionsPerVP`, while one landing before the resume is harmless;
   *      (2) every leaf `Deallocate` the chain dispatched has been consumed by root — one consumed after a
   *      resume-and-reallocate double-counts the power; (3) every `EmergencyDeallocate` sent during a
   *      suspension reached the leaf — resuming early leaves the leaf budget under root.
   * @dev Once the LEAF itself is back to `Active` (root resumes first), dispatch a zero-delta `allocateChains`
   *      refresh poke: it restores the zeroed leaf scalar and its higher nonce outranks any straggler's rate.
   *      Dispatched earlier, it lands masked to zero on the still-`Suspended` or still-`Sunset` leaf and spends
   *      its nonce for nothing, leaving the chain under-emitting until another rate-bearing message arrives.
   * @dev `Sunset` is expected to be terminal in practice; the transition out is an escape hatch. Reactivating
   *      a sunset chain routes through `Suspended` on both sides, and the matrix enforces the first leg:
   *      suspend the leaf (closes local `allocateGauges`, so it stops dispatching returns), suspend root
   *      (stops dealloc dispatches, `allocateChains` already closed), reconcile leaf `Deallocated` against
   *      root `DeallocationProcessed` until the in-flight set drains, then resume per the checklist above.
   *      Direct `Sunset` -> `Active` would be unsafe: returns carry no expiry, so one dispatched before the
   *      resume can land after a token re-allocates and be credited against the new booking, double-counting
   *      that power. Suspending both sides first is what makes the in-flight set finite; waiting under
   *      `Sunset` alone never closes it, because tokens keep dispatching new returns while you wait.
   * @param _chainId Chain whose status is being updated.
   * @param _status New status.
   */
  function setChainStatus(uint256 _chainId, ChainStatus _status) external;

  /**
   * @notice Enable or disable emergency deallocation for a registered chain.
   * @dev `CHAIN_STATUS_ROLE`; reverts on an unregistered chain. Second gate on `emergencyDeallocate` next to the
   *      `Suspended` requirement, and it resets to `false` on every suspend.
   * @dev Enabling needs no drain: consuming a leaf `Deallocate` while `Suspended` is always safe, since the
   *      clamp in `processDeallocation` meets a booking that cannot be refilled. Requiring a drain here would
   *      also block emergencies indefinitely when the leaf->root path is down (returns carry no expiry). The
   *      binding checklist sits on the resume instead — see `setChainStatus`.
   * @param _chainId Chain whose switch is being set.
   * @param _allowed `true` authorizes `emergencyDeallocate` for the current suspension.
   */
  function setEmergencyDeallocationAllowed(uint256 _chainId, bool _allowed) external;

  /**
   * @notice Set the per-tokenId operator for a chain and send the new value to the leaf.
   * @dev `VOTING_ESCROW.isAuthorized(msg.sender, _tokenId)`. Reverts on `CHAIN0`, unregistered or `Paused`
   *      chains, and a zero `_gasLimit` off the root chain. `Suspended` remains available so the owner can replace
   *      or clear a stale operator, and `Sunset` so the operator running the local exit vote can still be rotated.
   *      Always dispatches, so the leaf mirror stays in sync.
   * @dev The message carries an absolute expiry of `block.timestamp + messageLifetime`; past it the leaf rejects the
   *      update, so a stalled message cannot install an operator chosen before the token changed hands on root.
   *      Known behavior: the leaf mirror still persists across root-side token transfers, so a new owner must
   *      reset the operator on every leaf themselves.
   * @param _tokenId Token whose operator is being set.
   * @param _chainId Chain the operator applies to.
   * @param _operator New operator address. Zero clears the slot.
   * @param _gasLimit Destination gas budget for the leaf `handle()` call.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function setOperator(
    uint256 _tokenId,
    uint256 _chainId,
    address _operator,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable;

  /**
   * @notice Mint accumulated surplus that would otherwise never be distributed.
   * @dev `GOVERNANCE_ROLE`. Surplus is entitlement that never minted, so leaving it alone keeps it deflationary
   *      and remains the default. Each chain owns one pot netted against `surplusSpent`. For `CHAIN0` the pot is
   *      its whole ceiling, since idle power settles a ceiling nothing ever redeems. For a registered chain it is
   *      `reportedSurplus` clamped to the remaining mint entitlement `ceiling - totalRedeemed`, plus
   *      `cumulativeSuspendedSurplus`, both dead to redeems. The clamp keeps buffer backed report excess out of
   *      the pot until ceiling accrual covers it.
   * @dev Settles the chain first, so a `Suspended` chain's pending accrual and `CHAIN0`'s lazily settled ceiling
   *      growth are spendable in the same call. Works for any registered status including `Suspended`, which is
   *      how governance recovers surplus stranded by a suspension.
   * @dev Never reduces redeem headroom. `processRedeem` does not read `surplusSpent`, and the pots hold value no
   *      receipt holder can claim. The minter adds the team share on top, same as redeems, and reverts
   *      `AmountTooLow` below `MIN_MINT_AMOUNT`.
   * @param _chainId Chain whose surplus pot is being spent. `CHAIN0` or a registered chain.
   * @param _amount Amount of `TOKEN` to mint from the pot.
   * @param _recipient Address that receives the minted `TOKEN`.
   */
  function spendSurplus(uint256 _chainId, uint256 _amount, address _recipient) external;

  /*//////////////////////////////////////////////////////////////
                                VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Reserved chainId for idle voting power: it settles and swaps into `totalPoint`, but never receives
   *         a dispatch and never redeems its ceiling.
   * @return _chain0 The reserved idle chainId.
   */
  function CHAIN0() external view returns (uint256 _chain0);

  /**
   * @notice Reserved tokenId of the permanent veNFT holding burned voting power, moved there via
   *         `rebalanceChain0` before `burn`.
   * @return _token0 The reserved sink tokenId.
   */
  function TOKEN0() external view returns (uint256 _token0);

  /**
   * @notice Root-side MessageOrchestrator the Voter dispatches batched allocations through.
   * @return _orchestrator MessageOrchestrator contract.
   */
  function ORCHESTRATOR() external view returns (IRootMessageOrchestrator _orchestrator);

  /**
   * @notice Minter that issues `TOKEN` on redeem and supplies the emission rate. Set at deployment, immutable.
   * @return _minter The bound minter.
   */
  function MINTER() external view returns (IMinter _minter);

  /**
   * @notice The emissions token, the same token `MINTER` mints. Donations are held and paid out in it.
   * @return _token The emissions token.
   */
  function TOKEN() external view returns (IERC20 _token);

  /**
   * @notice VotingEscrow the Voter reads tokenId stakes from.
   * @return _votingEscrow VotingEscrow contract.
   */
  function VOTING_ESCROW() external view returns (IVotingEscrow _votingEscrow);

  /**
   * @notice Allocated AERO per `(tokenId, chainId)`; Σ across chains equals `tokenStates(tokenId).committed`.
   * @param _tokenId veNFT id.
   * @param _chainId Target chain identifier.
   * @return _allocated AERO amount allocated to the chain.
   */
  function allocationChainAmounts(uint256 _tokenId, uint256 _chainId) external view returns (uint128 _allocated);

  /**
   * @notice Aggregate per-chain state (point, ceiling, redeem accumulators, packed small fields).
   * @param _chainId Target chain identifier.
   * @return _point Aggregate voting power for the chain.
   * @return _ceiling Cumulative emissions the chain may claim.
   * @return _totalRedeemed Total `TOKEN` minted for the chain via redeem.
   * @return _reportedSurplus High-water mark of unused-emissions surplus reported to root for the chain.
   * @return _cumulativeSuspendedSurplus Would-be ceiling growth caught while the chain was `Suspended`.
   * @return _surplusSpent Cumulative surplus minted for the chain via `spendSurplus`.
   * @return _lastIndex The chain's cursor into the global `index` at its last ceiling settlement.
   * @return _lastTimeIndex The chain's cursor into the global `timeIndex` at its last ceiling settlement.
   * @return _donatedBuffer Donated `TOKEN` held for the chain's redeems, drawn once its ceiling is exhausted.
   * @return _status Operational status of the chain.
   */
  function chainStates(uint256 _chainId)
    external
    view
    returns (
      Point memory _point,
      uint256 _ceiling,
      uint256 _totalRedeemed,
      uint256 _reportedSurplus,
      uint256 _cumulativeSuspendedSurplus,
      uint256 _surplusSpent,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      uint256 _donatedBuffer,
      ChainStatus _status
    );

  /**
   * @notice Scheduled slope reduction at a stake expiry for a chain.
   * @param _chainId Target chain identifier.
   * @param _expiry Expiry timestamp.
   * @return _slopeChange Slope reduction scheduled at `_expiry`.
   */
  function chainSlopeChanges(uint256 _chainId, uint48 _expiry) external view returns (int128 _slopeChange);

  /**
   * @notice Gauge-message lifetime stamped onto every gauge dispatch as an absolute expiry.
   * @return _allocationLifetime Lifetime, in seconds.
   */
  function allocationLifetime() external view returns (uint48 _allocationLifetime);

  /**
   * @notice Claim and operator message lifetime stamped onto every claim and operator dispatch as an absolute expiry.
   * @return _messageLifetime Lifetime, in seconds.
   */
  function messageLifetime() external view returns (uint48 _messageLifetime);

  /**
   * @notice Donated `TOKEN` held for a chain's redeems, drawn once the chain's ceiling is exhausted.
   * @dev Convenience view over `chainStates`. Tracked next to the ceiling, never credited into it, so the
   *      ceiling keeps tracking the minter schedule and donated headroom stays auditable on its own.
   * @param _chainId Chain whose donated buffer is being read.
   * @return _amount `TOKEN` available to the chain's redeems beyond its ceiling.
   */
  function donatedBuffer(uint256 _chainId) external view returns (uint256 _amount);

  /**
   * @notice Aggregate voting power across all chains.
   * @return _bias Current voting power.
   * @return _slope Rate of decay per second.
   * @return _ts Timestamp of last resolution.
   * @return _permanentStakeBalance Non-decaying voting power from permanent stakes.
   */
  function totalPoint() external view returns (int128 _bias, int128 _slope, uint48 _ts, uint128 _permanentStakeBalance);

  /**
   * @notice Global emissions accumulator: the running integral of `emissionsPerVP` over time. Every chain's
   *         ceiling accrues off it, paired with `timeIndex` (see `ChainState`).
   * @return _index Current accumulator value, `PRECISION`-scaled.
   */
  function index() external view returns (uint256 _index);

  /**
   * @notice Global time-weighted emissions accumulator: `emissionsPerVP` integrated against absolute (unix-epoch)
   *         time, stored doubled. Paired with `index` it prices a decaying chain's ceiling exactly across a
   *         scalar change.
   * @return _timeIndex Current time-weighted accumulator value, doubled and `PRECISION`-scaled.
   */
  function timeIndex() external view returns (uint256 _timeIndex);

  /**
   * @notice Global emissions per unit voting power since the last touch, `PRECISION`-scaled
   *         (`emissionRate * PRECISION / totalWeight`). Drives the `index` advance and is shipped to leaves.
   * @return _emissionsPerVP The current scalar.
   */
  function emissionsPerVP() external view returns (uint256 _emissionsPerVP);

  /**
   * @notice Value of `index` at each week boundary the global settle has crossed.
   * @dev Chain ceilings accrue one segment per boundary, so root partitions time exactly like the leaf's gauge
   *      walk. A chain touched more often than its gauges are settled would otherwise accrue less than the leaf
   *      credits, and the difference is unredeemable.
   * @param _boundary Week-aligned timestamp.
   * @return _index Accumulator value recorded at that boundary.
   */
  function indexAtBoundary(uint48 _boundary) external view returns (uint256 _index);

  /**
   * @notice Value of `timeIndex` at each week boundary the global settle has crossed.
   * @param _boundary Week-aligned timestamp.
   * @return _timeIndex Time-weighted accumulator value recorded at that boundary.
   */
  function timeIndexAtBoundary(uint48 _boundary) external view returns (uint256 _timeIndex);

  /**
   * @notice Timestamp the global accumulators were last advanced to.
   * @return _lastGlobalSettlement The settle cursor.
   */
  function lastGlobalSettlement() external view returns (uint48 _lastGlobalSettlement);

  /**
   * @notice Scheduled slope reduction at a stake expiry, aggregated across chains.
   * @param _expiry Expiry timestamp.
   * @return _slopeChange Slope reduction scheduled at `_expiry`.
   */
  function totalSlopeChanges(uint48 _expiry) external view returns (int128 _slopeChange);

  /*//////////////////////////////////////////////////////////////
                                  VIEWS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Whether the route from a given chain is currently suspended. Read by
   *         `RootMessageOrchestrator.route` before it hands an inbound payload to a typed handler.
   * @dev Strictly `Suspended`: a `Sunset` chain returns false, since its exits stay open. Off-chain monitors
   *      tracking a wind-down must read the chain status instead of this flag.
   * @param _chainId Source chain id to check.
   * @return _isSuspended Whether the route from `_chainId` is suspended.
   */
  function isSuspended(uint256 _chainId) external view returns (bool _isSuspended);

  /**
   * @notice Surplus currently spendable for a chain via `spendSurplus`.
   * @dev Computed from stored values, so it is a floor rather than a quote. `CHAIN0`'s ceiling and a `Suspended`
   *      chain's accrual lag until their next settle, and `spendSurplus` settles before checking, so the
   *      executable amount is at least this value.
   * @dev A registered chain's reported surplus counts only up to the remaining mint entitlement
   *      `ceiling - totalRedeemed`. Report excess accepted against the donated buffer stays out of the pot, so
   *      the same donated backing cannot pay a redeem and fund a surplus mint.
   * @param _chainId Chain whose spendable surplus is being read.
   * @return _spendable Spendable surplus for the chain.
   */
  function spendableSurplus(uint256 _chainId) external view returns (uint256 _spendable);

  /**
   * @notice Whether emergency deallocation is currently authorized for a chain.
   * @dev Second gate on `emergencyDeallocate`; reset to `false` on every suspend.
   * @param _chainId Chain to check.
   * @return _allowed Whether `emergencyDeallocate` is authorized for `_chainId`.
   */
  function emergencyDeallocationAllowed(uint256 _chainId) external view returns (bool _allowed);

  /**
   * @notice Chains the tokenId currently holds a non-zero allocation on, in storage order.
   * @dev `CHAIN0` may be present alongside cross-chain allocations.
   * @param _tokenId veNFT id.
   * @return _chainIds Chain ids the tokenId has allocated on.
   */
  function allocationChainIds(uint256 _tokenId) external view returns (uint256[] memory _chainIds);

  /**
   * @notice Chains registered via `registerChain`, in storage order. `CHAIN0` is never present.
   * @return _chainIds Registered chain ids.
   */
  function chains() external view returns (uint256[] memory _chainIds);

  /**
   * @notice Whether the tokenId directs any voting power to a non-CHAIN0 chain.
   * @param _tokenId veNFT id.
   * @return _isAllocating True when the tokenId has non-CHAIN0 allocation.
   */
  function allocating(uint256 _tokenId) external view returns (bool _isAllocating);

  /**
   * @notice Per-tokenId voting record captured on the last allocation.
   * @param _tokenId veNFT id.
   * @return _committed Committed size.
   * @return _lastStakeEnd Stake end captured at the last allocation.
   * @return _lastAllocated Timestamp of the last allocation.
   * @return _isPermanent True when the stored shape is permanent.
   */
  function tokenStates(uint256 _tokenId)
    external
    view
    returns (uint128 _committed, uint48 _lastStakeEnd, uint48 _lastAllocated, bool _isPermanent);
}
