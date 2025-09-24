// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/**
 * @title  IRelay
 * @notice The base Relay surface: types, events, errors and every external member of RelayBase.
 *         Tier-specific members live on the concrete subclasses.
 */
interface IRelay {
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                      ENUMS                                         __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice The Relay tier, set at deployment; it decides the access model and the reward-processing flexibility.
  /// @dev Maxi: permissionless deposits.
  ///      ProtocolL1: whitelist-gated, fixed entrypoints.
  ///      ProtocolL2: whitelist-gated, mutable entrypoints, sweep.
  enum RelayType {
    Maxi,
    ProtocolL1,
    ProtocolL2
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     STRUCTS                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Relay-level configuration, set at initialization.
  /// @param tokenId The Relay's own sAERO that aggregates all pooled weight.
  /// @param minDeposit Minimum requestable deposit (dust guard).
  /// @param keeperWindow Time the keeper has to process a deposit before it becomes processable permissionlessly.
  /// @param minWithdrawal Minimum shares per withdraw registration (dust guard); a holder whose whole free
  ///        position is smaller may still exit it in one go.
  /// @param entrypointTimelock Exit-window delay (seconds) before a proposed L2 entrypoint can attach; non-zero.
  /// @param lockWeeks Lock horizon in weeks re-extended on each allocation; zero means a permanent stake.
  /// @param evacuationWindow Seconds a queued withdrawal may wait unpaid (from its registration) before anyone may
  ///        permanently close the Relay and start the evacuation. Fixed at creation, non-zero.
  /// @param name Relay display name, also the stem of the satellite-token names at creation;
  ///        mutable via `setName`.
  /// @param symbol Stem of the satellite-token symbols; no setter.
  struct RelayConfig {
    uint256 tokenId;
    uint256 minDeposit;
    uint256 keeperWindow;
    uint256 minWithdrawal;
    uint256 entrypointTimelock;
    uint48 lockWeeks;
    uint48 evacuationWindow;
    string name;
    string symbol;
  }

  /// @notice Initialization inputs for a freshly cloned Relay. The factory names `vpm`, `governor`
  ///         and `voteAdapter` from its own immutables, never the creator.
  /// @param admin Initial owner: it holds the admin gates and manages every role bit.
  /// @param keeper Initial KEEPER, granted the role.
  /// @param voter Initial VOTER_ROLE operator, or zero to skip; rotatable by the owner afterwards.
  /// @param compounder Entrypoint granted COMPOUNDER, or zero to skip; immutable on Maxi/L1.
  ///        Naming neither entrypoint is rejected unless the Relay starts as L2, which attaches later.
  /// @param converter Entrypoint granted CONVERTER, or zero to skip; immutable on Maxi/L1.
  /// @param bootstrapOwner Non-zero recipient of the bootstrap PT/YT pair minted 1:1 against the seed stake.
  /// @param rewardToken First reward token to register, or zero to leave the registry empty for KEEPER.
  ///        Naming it here pins it in the same call that names the entrypoints it must match.
  /// @param entrypointVetoer Holder of ENTRYPOINT_VETOER, or zero to run the timelock without a veto.
  ///        Only seatable here: the public role paths refuse the bit, so an empty seat can never be
  ///        filled later. Only the Protocol tier reads it.
  /// @param vpm Non-zero VoterPaymentsModule the Relay starts on.
  /// @param governor Non-zero Governor the Relay starts casting into; movable through `setGovernor`.
  /// @param voteAdapter Non-zero adapter every cast is encoded by; movable through `setGovernor`.
  /// @param startAsLevel2 True to start a Protocol Relay directly as L2; tiers without an L2 path reject it.
  /// @param ytTransferable True to deploy the yield token transferable; false makes it soulbound.
  ///        Immutable switch on the YT clone; tiers with an allow list reject true.
  /// @param config Relay configuration; the factory stamps `tokenId` and `lockWeeks` from the seed stake.
  struct InitParams {
    address admin;
    address keeper;
    address voter;
    address compounder;
    address converter;
    address bootstrapOwner;
    address rewardToken;
    address entrypointVetoer;
    IVoterPaymentsModule vpm;
    IGovernor governor;
    IRelayVoteAdapter voteAdapter;
    bool startAsLevel2;
    bool ytTransferable;
    RelayConfig config;
  }

  /// @notice One entry of the deposit queue: a queued async deposit that waits for processing.
  ///         Processing deletes the entry, which refunds its storage and marks the id consumed.
  /// @param recipient Address the shares mint to, named at request.
  /// @param requestedAt Request timestamp; after `keeperWindow` anyone can process the entry. Zero
  ///        marks a consumed entry, because a live one always stamps its request's block timestamp.
  /// @param tokenId Depositing sAERO the weight came from; only the `DepositProcessed` event reads it.
  /// @param amount Staking weight moved into the Relay sAERO and held on chain0.
  /// @dev The queue stores no link to the next entry. Ids run in sequence from one and are never
  ///      reused, so every id up to `tail` was issued and the next id is always this id plus one.
  ///      Deleting a consumed entry keeps that derivation intact — the id holds its place in the
  ///      walk order — but a path that reused an id would break it and must store an explicit link.
  struct PendingDeposit {
    address recipient;
    uint48 requestedAt;
    uint128 tokenId;
    uint128 amount;
  }

  /// @notice A reserved exit sitting in the FIFO withdraw queue until the drain settles it.
  /// @param holder Owner of the escrowed shares, credited the weight on drain.
  /// @param registeredAt Registration timestamp, stamped once and never moved; anchors the
  ///        evacuation clock when the entry reaches the head of the queue.
  /// @param mintFresh Whether the drain routes the weight to a freshly minted sAERO.
  /// @param shares Shares the holder locked in place (non-transferable), burned when the entry settles.
  /// @param destination Destination sAERO the weight returns to, zero when `mintFresh` is set.
  /// @dev Packs into two slots. `MINT_SENTINEL` lives only at the API boundary, because a sentinel
  ///      inside `destination`'s 72-bit range would collide with a real token id: registration
  ///      folds it into `mintFresh`, and the `withdrawals` getter and the events rebuild it.
  struct WithdrawEntry {
    address holder;
    uint48 registeredAt;
    bool mintFresh;
    uint128 shares;
    uint72 destination;
  }

  /// @notice A proposed leaf claim recipient waiting out its timelock.
  /// @param recipient Address the claims for the chain would move to.
  /// @param proposedAt Timestamp the proposal was stamped; the delay runs from here.
  struct PendingRecipient {
    address recipient;
    uint48 proposedAt;
  }

  /// @notice A proposed leaf operator waiting out its timelock.
  /// @param operator Address that would be named operator of the Relay's sAERO on the chain.
  /// @param proposedAt Timestamp the proposal was stamped; the delay runs from here.
  struct PendingOperator {
    address operator;
    uint48 proposedAt;
  }

  /// @notice One ERC-20 leg of a sweep, moved from the Relay's own balance on root (root-only, no
  ///         cross-chain dispatch).
  /// @param token Token to sweep, held by the Relay on root.
  /// @param recipient Destination of the swept tokens.
  /// @param amount Amount to move.
  struct ERC20Sweep {
    address token;
    address recipient;
    uint256 amount;
  }

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                      EVENTS                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Emitted when the owner adds or removes an address from the allow list gating deposits and
  ///         holder-to-holder yield-token transfers (both ends must be listed).
  /// @param account Address whose permission changed.
  /// @param allowed True when permitted, false when revoked.
  event AllowListSet(address indexed account, bool allowed);

  /// @notice Emitted when the owner hard-kicks an account: de-listed, rewards settled, and its free
  ///         position forced into the withdraw queue.
  /// @param account Account that was kicked.
  /// @param shares Free shares forced into the withdraw queue (zero when it held none).
  event Kicked(address indexed account, uint256 shares);

  /// @notice Emitted on the one-way promotion of a Protocol L1 Relay to Protocol L2.
  /// @param admin Address the ownership moved to at promotion.
  event PromotedToLevel2(address indexed admin);

  /// @notice Emitted when the owner proposes attaching an entrypoint on an L2 Relay.
  /// @param role Entrypoint role proposed (COMPOUNDER or CONVERTER).
  /// @param account Entrypoint address proposed for the role.
  /// @param executableAt Timestamp from which the proposal may be executed (`now + entrypointTimelock`).
  event EntrypointProposed(uint256 indexed role, address indexed account, uint256 executableAt);

  /// @notice Emitted when ENTRYPOINT_VETOER cancels a pending entrypoint proposal.
  /// @param role Entrypoint role the cancelled proposal targeted.
  /// @param account Entrypoint address the cancelled proposal targeted.
  event EntrypointVetoed(uint256 indexed role, address indexed account);

  /// @notice Emitted on every successful allocation cast against the Voter.
  /// @param caller Holder of VOTER_ROLE that sent the allocation.
  event Allocated(address indexed caller);

  /// @notice Emitted when the Relay is permanently closed.
  /// @param caller Address that closed the Relay (anyone once a withdrawal has waited the full window unpaid,
  ///        KEEPER at will).
  event Closed(address indexed caller);

  /// @notice Emitted when an evacuation dispatches one chain's full pull-out on a closed Relay.
  ///         Fires again on every re-dispatch.
  /// @param caller Address that triggered the evacuation (permissionless once closed).
  event Evacuated(address indexed caller);

  /// @notice Emitted when a depositor requests an async deposit.
  /// @param tokenId Depositing sAERO.
  /// @param recipient Share recipient named at request.
  /// @param amount Net staking weight received by the Relay sAERO, after the VPM protocol fee.
  /// @param id Deposit-queue id the entry was appended under, addressing it for individual processing.
  event DepositRequested(uint256 indexed tokenId, address indexed recipient, uint256 amount, uint256 id);

  /// @notice Emitted when a pending deposit is processed and its shares mint.
  /// @param tokenId Depositing sAERO.
  /// @param recipient Share recipient recorded at request.
  /// @param amount Staking weight admitted into the live backing.
  /// @param sharesMinted Shares minted at the current ratio.
  event DepositProcessed(uint256 indexed tokenId, address indexed recipient, uint256 amount, uint256 sharesMinted);

  /// @notice Emitted when a holder reserves an exit on the withdraw queue.
  /// @param holder Owner of the escrowed shares.
  /// @param shares Shares escrowed into the queue.
  /// @param destination Destination sAERO, or the mint sentinel for a fresh one.
  /// @param id Id the exit was appended under; ids run in sequence from one.
  event WithdrawRegistered(address indexed holder, uint256 shares, uint256 destination, uint256 id);

  /// @notice Emitted when the drain settles a queued exit.
  /// @param holder Owner credited the returned weight.
  /// @param sharesBurnt Escrowed shares burned to settle the exit.
  /// @param amount Net staking weight received by the destination sAERO, after the VPM protocol fee.
  /// @param destinationTokenId Destination sAERO that received the weight (freshly minted on fallback).
  event WithdrawProcessed(address indexed holder, uint256 sharesBurnt, uint256 amount, uint256 destinationTokenId);

  /// @notice Emitted when a reward token is registered in the accumulator registry.
  /// @param token Reward token added.
  event RewardTokenAdded(address indexed token);

  /// @notice Emitted when a reward token that never distributed anything leaves the registry.
  /// @param token Reward token dropped.
  event RewardTokenRemoved(address indexed token);

  /// @notice Emitted when the Relay moves to another VoterPaymentsModule.
  /// @param vpm The module every later deposit and withdrawal moves weight through.
  event VoterPaymentsModuleSet(address indexed vpm);

  /// @notice Emitted when the Relay is pointed at another Governor.
  /// @param governor The Governor every later `expressVote` casts into.
  /// @param voteAdapter The adapter translating casts for it.
  event GovernorSet(address indexed governor, address indexed voteAdapter);

  /// @notice Emitted when the Relay's display name changes.
  /// @param oldName The name being replaced.
  /// @param newName The name from here on.
  event NameChanged(string oldName, string newName);

  /// @notice Emitted when a reward batch advances a token's per-share accumulator.
  /// @param token Reward token notified.
  /// @param amount Amount accounted: what the advanced index can pay out, rounded up. The rest of
  ///        the batch stays un-accounted for the next notify.
  /// @param newIndex Accumulator index after the batch.
  event RewardNotified(address indexed token, uint256 amount, uint256 newIndex);

  /// @notice Emitted when a holder claims accrued reward in a token.
  /// @param holder Holder whose accrual was settled.
  /// @param token Reward token claimed.
  /// @param to Recipient of the payout.
  /// @param amount Amount transferred out.
  event RewardClaimed(address indexed holder, address indexed token, address indexed to, uint256 amount);

  /// @notice Emitted on every successful compound into the Relay sAERO.
  /// @param amount TOKEN amount staked into the underlying position.
  event Compounded(uint256 amount);

  /// @notice Emitted when donated staking weight is recognized into the backing.
  /// @param amount Donated weight folded into `totalBacking` and the idle chain0 pool.
  event DonationsProcessed(uint256 amount);

  /// @notice Emitted once at initialization when the two satellite tokens are cloned and bound.
  /// @param principalToken The principal token (PT) clone: priced position, withdraw right.
  /// @param yieldToken The yield token (YT) clone: the balance the reward accumulator reads.
  event RelayTokensDeployed(address principalToken, address yieldToken);

  /// @notice Emitted when the owner sets (or clears) the recipient that fee/incentive claims for a leaf
  ///         chain land at on that chain.
  /// @param chainId Leaf chain the recipient applies to.
  /// @param recipient Configured claim recipient, or zero when cleared.
  event LeafRecipientSet(uint256 indexed chainId, address indexed recipient);

  /// @notice Emitted when the owner proposes a new recipient for a leaf chain's fee/incentive claims.
  /// @param chainId Leaf chain the proposed recipient applies to.
  /// @param recipient Proposed claim recipient.
  /// @param executableAt Timestamp from which the proposal may be executed (`now + entrypointTimelock`).
  event LeafRecipientProposed(uint256 indexed chainId, address indexed recipient, uint256 executableAt);

  /// @notice Emitted when an operator is proposed for a leaf chain.
  /// @param chainId Leaf chain the operator would act on.
  /// @param operator Address proposed as operator.
  /// @param executableAt Timestamp the proposal can be executed at.
  event OperatorProposed(uint256 indexed chainId, address indexed operator, uint256 executableAt);

  /// @notice Emitted when an operator update is sent to a leaf chain.
  /// @param chainId Leaf chain the update was sent to.
  /// @param operator Address named operator; zero clears the seat.
  /// @dev The leaf applies it when the message arrives, so this records the dispatch and not the
  ///      landing. A message that expires in transit leaves the leaf on its previous operator.
  event OperatorDispatched(uint256 indexed chainId, address indexed operator);

  /// @notice Emitted when a pending operator proposal is cancelled.
  /// @param chainId Leaf chain whose proposal was cancelled.
  event OperatorProposalCancelled(uint256 indexed chainId);

  /// @notice Emitted when a principal-token holder expresses a preference on a governance proposal
  ///         and the Relay casts their slice of its weight.
  /// @param proposalId Proposal the preference applies to.
  /// @param holder Principal-token holder expressing the preference.
  /// @param support Support the holder requested: 0 Against, 1 For, 2 Abstain, 255 fractional.
  /// @param weightUsed Voting weight consumed from the holder's snapshot slice by this call.
  /// @param params The params the holder supplied (empty for nominal support, three packed `uint128`
  ///        weights for fractional).
  event VoteExpressed(
    uint256 indexed proposalId, address indexed holder, uint8 support, uint256 weightUsed, bytes params
  );

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                  CUSTOM ERRORS                                     __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Thrown when the caller is not authorized over the source sAERO through the VPM.
  error NotAuthorized();

  /// @notice Thrown when the named VoterPaymentsModule is not one the escrow authorizes.
  error ModuleNotAuthorized();

  /// @notice Thrown at construction when the Relay does not own the sAERO it is being bound to.
  error NotTokenOwner();

  /// @notice Thrown at construction when the bound sAERO carries no initial stake (the seed that
  ///         blocks the first-depositor inflation attack).
  error ZeroInitialDeposit();

  /// @notice Thrown on a permissioned Relay when a deposit or share transfer hits an address not on the allow list.
  error NotAllowed();

  /// @notice Thrown when a requested deposit is below the configured minimum.
  error BelowMinimumDeposit();

  /// @notice Thrown when a requested deposit would mint zero shares at the current share ratio.
  error ZeroShares();

  /// @notice Thrown when a registered withdrawal is zero, or below the configured minimum without being the
  ///         holder's whole free position.
  error BelowMinimumWithdrawal();

  /// @notice Thrown when processing the deposit queue with nothing pending.
  error NoPendingDeposits();

  /// @notice Thrown when processing donations finds no surplus staked weight to recognize.
  error NoDonations();

  /// @notice Thrown when processing a deposit id that was never issued.
  error DepositNotFound();

  /// @notice Thrown when processing a deposit entry that was already processed.
  error DepositAlreadyProcessed();

  /// @notice Thrown when an amount exceeds the un-accounted balance on hand (`balanceOf - accountedBalance`).
  error RewardExceedsBalance();

  /// @notice Thrown when a zero address is supplied where a non-zero one is required.
  error ZeroAddress();

  /// @notice Thrown at construction when a queue's minimum amount is zero. A zero floor admits a
  ///         zero-amount entry, and a zero-share exit permanently stalls the withdraw FIFO.
  error ZeroQueueFloor();

  /// @notice Thrown when registering a withdrawal for more shares than the caller has free
  ///         (un-escrowed). An open Relay checks both satellites; a closed one checks the
  ///         principal alone.
  error InsufficientFreeShares();

  /// @notice Thrown when a transfer would move shares the holder has escrowed into the withdraw queue.
  error EscrowedSharesLocked();

  /// @notice Thrown on `renounceOwnership`: a vacant owner seat would freeze every owner-gated path,
  ///         so the ownership can only be handed over.
  error OwnershipRenounceDisabled();

  /// @notice Thrown when a public grant, revoke or renounce names a restricted role: COMPOUNDER and
  ///         CONVERTER move only through `initialize` and the L2 attachment flow, and
  ///         ENTRYPOINT_VETOER only through `initialize` and `transferVetoer`.
  error EntrypointRoleRestricted();

  /// @notice Thrown on the permissionless deposit path when the named entry is still within keeperWindow.
  error KeeperWindowNotElapsed();

  /// @notice Thrown when initializing a Relay with a zero entrypoint timelock.
  error InvalidEntrypointTimelock();

  /// @notice Thrown when a Relay whose entrypoints are fixed at initialization names neither a
  ///         compounder nor a converter: rewards reaching it could never be processed. A Relay
  ///         starting as Protocol L2 is exempt, it attaches entrypoints through the timelocked flow.
  error MissingEntrypoint();

  /// @notice Thrown when registering an exit whose destination is the Relay's own sAERO.
  error InvalidDestination();

  /// @notice Thrown when notifying or claiming a token not in the reward registry.
  error UnknownRewardToken();

  /// @notice Thrown when adding a reward token already present in the registry.
  error RewardTokenAlreadyAdded();

  /// @notice Thrown when a Maxi or Protocol L1 Relay tries to register a second reward token.
  error RewardRegistryLocked();

  /// @notice Thrown when registering a reward token would exceed `MAX_REWARD_TOKENS`.
  error RewardRegistryFull();

  /// @notice Thrown when registering a reward token that holds no code, which no claim could
  ///         ever transfer out.
  error RewardTokenNotAContract();

  /// @notice Thrown when registering the Relay itself or one of its satellites as a reward token.
  error InvalidRewardToken();

  /// @notice Thrown when dropping a reward token that already distributed a batch, whose holders
  ///         would lose the rights it left behind.
  error RewardTokenPaid();

  /// @notice Thrown when promoting a Relay that is not Protocol L1, or initializing a tier without
  ///         an L2 path with `startAsLevel2`.
  error NotPromotable();

  /// @notice Thrown when initializing an allow-listed tier with a transferable yield token: a
  ///         kicked holder who sold YT would have no pair left to burn, so eviction would be a no-op.
  error TransferableYieldTokenNotAllowed();

  /// @notice Thrown when a satellite token implementation holds no code, which a clone of it cannot report.
  error ImplementationNotAContract();

  /// @notice Thrown when a cloned satellite token did not come out bound to this Relay with the
  ///         requested transferability.
  error SatelliteNotInitialized();

  /// @notice Thrown when a Level-2-only action (e.g. sweep) runs on a Maxi or Protocol L1 Relay.
  error NotLevel2();

  /// @notice Thrown when proposing an entrypoint for a role other than COMPOUNDER or CONVERTER.
  error InvalidEntrypointRole();

  /// @notice Thrown when executing an entrypoint attachment that was never proposed.
  error EntrypointNotProposed();

  /// @notice Thrown when executing an entrypoint attachment before its timelock has elapsed.
  error EntrypointTimelockNotElapsed();

  /// @notice Thrown when executing a leaf recipient that was never proposed, or already landed.
  error LeafRecipientNotProposed();

  /// @notice Thrown when executing a proposed leaf recipient before its timelock has elapsed.
  error LeafRecipientTimelockNotElapsed();

  /// @notice Thrown when executing an operator for a chain that has no proposal pending.
  error OperatorNotProposed();

  /// @notice Thrown when executing an operator proposal before its timelock has elapsed.
  error OperatorTimelockNotElapsed();

  /// @notice Thrown when an allocation, a deposit request or a close reaches a permanently
  ///         closed Relay.
  error RelayClosed();

  /// @notice Thrown when evacuating an open Relay: the dispatch requires the closed state.
  error RelayNotClosed();

  /// @notice Thrown when a flexible-vote cast would send calldata whose selector is not the
  ///         Governor's fractional cast, so a rotated Governor cannot bear arbitrary authority.
  error UnexpectedCastSelector();

  /// @notice Thrown at initialization when the evacuation window is zero, which would let anyone
  ///         close a working Relay.
  error InvalidEvacuationWindow();

  /// @notice Thrown at initialization when the keeper window is zero, which would make the overdue
  ///         drain permissionless from the first block.
  error InvalidKeeperWindow();

  /// @notice Thrown at initialization when `lockWeeks` disagrees with the seed stake's permanence:
  ///         a permanent seed with non-zero `lockWeeks` would revert every lock extension, and a
  ///         time-locked seed with zero `lockWeeks` would silently decay.
  error LockWeeksMismatch();

  /// @notice Thrown at initialization when `lockWeeks` reaches past the escrow's MAXTIME once its
  ///         week floor is applied, which would make the lock refresh fail part of every week.
  error LockWeeksTooLong();

  /// @notice Thrown when closing a Relay whose withdraw queue is empty.
  error NoQueuedWithdrawal();

  /// @notice Thrown when closing a Relay before the oldest queued withdrawal has waited a full evacuation window.
  error EvacuationWindowNotElapsed();

  /// @notice Thrown when closing a Relay whose oldest queued withdrawal the free chain0 weight can pay: the remedy
  ///         is a drain, not a shutdown.
  error HeadIsCovered();

  /// @notice Thrown when an evacuation names a chain holding no booked weight.
  error NothingToEvacuate();

  /// @notice Thrown when an allocation carries no chain and no gauge dispatches.
  error EmptyAllocation();

  /// @notice Thrown when an allocation's growth exceeds the free chain0 weight minus the priced
  ///         withdrawal reserve, which the queue is owed before anything else is allocated.
  error InsufficientFreeWeight();

  /// @notice Thrown when a claim resolves to a zero payout.
  error NothingToClaim();

  /// @notice Thrown when a leaf-chain claim has no configured recipient (it cannot dispatch to zero).
  error RecipientNotSet();

  /// @notice Thrown when a root claim is funded with msg.value (no cross-chain dispatch, no fee).
  error NoValueOnRootClaim();

  /// @notice Thrown when notifying a reward while the share supply is zero.
  error NoSupply();

  /// @notice Thrown when compounding into a Relay with no principal outstanding, where the added
  ///         backing would have no claimant.
  error NoPrincipalSupply();

  /// @notice Thrown when a reward batch is too small to advance the per-share index (it would floor
  ///         to zero and lock as owed-but-undistributed).
  error RewardTooSmall();

  /// @notice Thrown when the caller held no principal token at the proposal snapshot.
  error NoVotingPower();

  /// @notice Thrown when the caller has already consumed their full slice on this proposal.
  error AlreadyVoted();

  /// @notice Thrown when the requested fractional weights exceed the caller's remaining slice.
  error ExceedsRemainingSlice();

  /// @notice Thrown when governance support is not 0/1/2/255, or the params length disagrees with it.
  error InvalidSupport();

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    FUNCTIONS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Initializes a freshly cloned Relay. Callable once, by the factory, in the
  ///         clone-creation transaction.
  /// @param _params Initialization inputs (operators, entrypoints, tier flag, configuration).
  function initialize(InitParams memory _params) external;

  /// @notice Requests an async deposit from the caller's sAERO, crediting the eventual shares to
  ///         the sAERO's current owner. No shares mint here: the entry waits on the deposit queue
  ///         until the keeper processes it, or anyone after it ages past `keeperWindow`.
  /// @param _tokenId Source sAERO whose weight enters the Relay.
  /// @param _amount Staking weight pulled from the source sAERO; the Relay records the net weight
  ///        after the VPM protocol fee.
  function requestDeposit(uint256 _tokenId, uint256 _amount) external;

  /// @notice Requests an async deposit from the caller's sAERO, naming the share recipient.
  /// @param _tokenId Source sAERO whose weight enters the Relay.
  /// @param _amount Staking weight pulled from the source sAERO (gross of the VPM protocol fee).
  /// @param _recipient Address the shares mint to at admission.
  function requestDeposit(uint256 _tokenId, uint256 _amount, address _recipient) external;

  /// @notice Keeper entry that processes pending deposits in request order and mints shares.
  /// @param _maxEntries Max deposit-queue entries to visit this call; a consumed entry the walk
  ///        visits spends budget like a live one.
  /// @dev The keeper triggers the entrypoints first so existing holders capture the reward batch,
  ///      then processes deposits so fresh shares mint at the settled ratio.
  function processPending(uint256 _maxEntries) external;

  /// @notice Permissionless liveness fallback: process the named pending deposits after each one
  ///         ages past `keeperWindow`, so neither the keeper nor a backlog can block an entry.
  /// @param _ids Deposit-queue ids to process, in the given order.
  /// @dev Reverts on an empty ids array, an id that was never issued, an entry that was already
  ///      processed, or an entry that is still inside the keeper window.
  function processOverduePending(uint256[] calldata _ids) external;

  /// @notice Registers an exit: escrows `_shares` into the FIFO withdraw queue, to be settled later
  ///         against the idle chain0 weight. Permissionless; cannot be cancelled.
  /// @param _shares Shares to escrow and burn at drain.
  /// @param _destination Existing sAERO the weight is sent to, or MINT_SENTINEL for a freshly minted
  ///        one. Read at settlement rather than now; only the Relay's own sAERO is rejected.
  /// @dev Escrowed shares stay on the holder, accruing rewards until burned, but are locked in
  ///      place. On a closed Relay the free-share cover is asked of the principal alone, so a
  ///      holder that sold its yield side can still leave; the drain mirrors this and burns only
  ///      the principal past closure, leaving the yield token its claim on the reward tail.
  function registerOnWithdrawQueue(uint256 _shares, uint256 _destination) external;

  /// @notice Drains up to `_maxEntries` queued exits against the free chain0 weight, read live from
  ///         the Voter. Permissionless: exits only ever route to their registered destinations.
  /// @param _maxEntries Max exits to settle this call.
  /// @dev The drain stops early when the free weight no longer covers the next exit.
  function processWithdrawals(uint256 _maxEntries) external;

  /// @notice Allocates the pooled voting power: forwards the caller's chain and gauge dispatches to
  ///         the Voter in one composed call. The Relay stores no strategy.
  /// @param _chainDispatches Per-chain additive deltas funded from the idle chain0 weight, with
  ///        their dispatch funding; strictly ascending. A zero delta only refreshes the chain's
  ///        stored shape.
  /// @param _gaugeDispatches Per-chain gauge overwrites with their dispatch funding. A list must
  ///        cover the chain's booked amount exactly; a `DEALLOC_GAUGE` entry starts a leaf-first
  ///        return of that amount to chain0, its return cost paid from the entry's `value`.
  /// @param _refundRecipient Recipient of any unused dispatch value, refunded by the transport.
  /// @dev The Relay checks only the withdrawal reserve and the closed flag; the Voter validates
  ///      everything else (ordering, chain status, gauge budgets, the msg.value split).
  function allocate(
    IVoter.ChainAllocationDispatch[] calldata _chainDispatches,
    IVoter.GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external payable;

  /// @notice Refreshes the Relay sAERO's lock to its configured horizon. Permissionless; a no-op
  ///         on permanent Relays.
  function extendLock() external;

  /// @notice Permanently closes the Relay. Permissionless when the oldest queued withdrawal has waited a full
  ///         evacuation window and the free chain0 weight cannot pay it; KEEPER closes at will. The allocated
  ///         chains come home afterwards through `evacuate`, one per call.
  function close() external;

  /// @notice Pulls the named chain's full booked weight back to chain0 on a closed Relay.
  ///         Permissionless, and a chain whose message never applied can be re-dispatched.
  /// @param _chainId Allocated chain whose full booked weight returns; the Voter enforces its own
  ///        chain rules on the dispatch.
  /// @param _gasLimit Destination gas for the leaf message; msg.value covers the dispatch fee and
  ///        the chain's deallocation return cost, quoted off-chain.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  function evacuate(uint256 _chainId, uint256 _gasLimit, address _refundRecipient) external payable;

  /// @notice Pulls the Relay's weight off a suspended chain straight back to chain0 through the
  ///         Voter's emergency path. KEEPER-gated while the Relay is open; permissionless once
  ///         closed.
  /// @param _chainId Suspended chain whose full booked weight returns.
  /// @param _gasLimit Destination gas for the emergency message to the leaf.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  /// @dev The Voter enforces its own preconditions (the chain is Suspended and emergency
  ///      deallocation is enabled for it) and credits chain0 synchronously.
  function emergencyDeallocate(uint256 _chainId, uint256 _gasLimit, address _refundRecipient) external payable;

  /// @notice Expresses a governance preference as a principal-token holder: the Relay casts a
  ///         fractional vote with its own sAERO, sized to the caller's snapshot slice.
  /// @param _proposalId Proposal being voted on.
  /// @param _support Preference: 0 Against, 1 For, 2 Abstain (empty params, spends the whole
  ///        remaining slice), or 255 fractional (params carry three packed `uint128` weights).
  /// @param _params Counting-module params matching `_support`.
  /// @param _reason Free-form reason string forwarded to the Governor.
  /// @dev Permissionless: the slice itself is the gate — a caller with no checkpointed principal
  ///      at the snapshot prices to zero and is rejected.
  function expressVote(uint256 _proposalId, uint8 _support, bytes calldata _params, string calldata _reason) external;

  /// @notice Hands `_amount` of `_token` to the calling entrypoint for swapping; the swap output
  ///         must land back on the Relay.
  /// @param _token Reward token to pull out to the entrypoint.
  /// @param _amount Amount to transfer to the caller.
  /// @dev Gated to either entrypoint role. Bounded to the un-accounted balance, so an entrypoint
  ///      can never pull reward tokens already owed to claimants.
  function pull(address _token, uint256 _amount) external;

  /// @notice Appreciation lane: stakes `_amount` of TOKEN held by the Relay into the Relay sAERO,
  ///         raising the backing without minting shares.
  /// @param _amount TOKEN amount to stake into the Relay sAERO.
  /// @dev Bounded to the un-accounted TOKEN, so it can never stake TOKEN already owed to claimants.
  function compound(uint256 _amount) external;

  /// @notice Moves this Relay onto another VoterPaymentsModule.
  /// @param _vpm The module to move to; it must be one the escrow currently authorizes.
  function setVoterPaymentsModule(IVoterPaymentsModule _vpm) external;

  /// @notice Points this Relay at another Governor, naming the adapter that speaks its dialect.
  ///         The slice math and the consumption ledger stay on the Relay; only the snapshot read
  ///         and the cast encoding go through the adapter.
  /// @param _governor The Governor every later `expressVote` casts into.
  /// @param _voteAdapter The adapter translating casts for it; both must be non-zero.
  function setGovernor(IGovernor _governor, IRelayVoteAdapter _voteAdapter) external;

  /// @notice Recognizes donated staking weight (staked directly into the Relay sAERO) into the
  ///         backing — the same accounting as `compound`, minus the VE call.
  /// @dev Keeper-gated for ordering: donations are recognized before the vote that allocates them.
  function processDonations() external;

  /// @notice Registers a reward token so the accumulator settles it. Maxi/L1 lock the registry
  ///         after the first token; L2 grows it up to `MAX_REWARD_TOKENS`.
  /// @param _token Reward token to add to the registry.
  /// @dev Late registration needs no bootstrapping: index and checkpoints default to zero, so the
  ///      first `notifyReward` accrues proportionally to current holders.
  function addRewardToken(address _token) external;

  /// @notice Drops a reward token that never distributed anything, reopening its registry slot.
  /// @param _token Reward token to drop.
  /// @dev The undo of a misregistration, and the only way back on the single-slot tiers, where the
  ///      first token otherwise closes the registry for good. A token that ever paid stays: the
  ///      accumulator settles and claims only registered tokens, so dropping it would freeze the
  ///      rights it left behind.
  function removeRewardToken(address _token) external;

  /// @notice Proposes the recipient that fee/incentive claims for `_chainId` land at on that chain.
  /// @param _chainId Leaf chain the recipient applies to.
  /// @param _recipient Address claims for that chain would be sent to; zero is rejected, since
  ///        disabling a chain is `clearLeafRecipient` and needs no delay.
  /// @dev Pointing claims at a new address hands reward custody to it, the same economic move as
  ///      attaching an entrypoint, so it waits out the same delay. Claims keep resolving to the
  ///      current recipient meanwhile, and the claim wrapper is permissionless, so anyone can move
  ///      the outstanding accrual to the current custody before a proposal lands. One live proposal
  ///      per chain: proposing again replaces it and restarts the delay.
  function proposeLeafRecipient(uint256 _chainId, address _recipient) external;

  /// @notice Lands the proposed recipient for `_chainId` once its timelock has elapsed.
  /// @param _chainId Leaf chain whose proposal is executed.
  function executeLeafRecipient(uint256 _chainId) external;

  /// @notice Disables Relay-orchestrated claims for `_chainId` and cancels any proposal pending
  ///         for it.
  /// @param _chainId Leaf chain to disable.
  /// @dev Immediate, with no delay: it only removes a capability, so a compromised transport is cut
  ///      off at once. It is also the cancel path for a proposal made in error. It only closes the
  ///      `claimRewards` route: an operator seated on the chain keeps claiming there on its own,
  ///      and leaves through `revokeOperator`.
  function clearLeafRecipient(uint256 _chainId) external;

  /// @notice Proposes the operator of the Relay's sAERO on `_chainId`.
  /// @param _chainId Leaf chain the operator would act on.
  /// @param _operator Address proposed as operator; zero is rejected, since clearing the seat is
  ///        `revokeOperator` and needs no delay.
  /// @dev An operator can call `claimRewards` on the leaf naming any recipient it likes, and on its
  ///      own schedule. Naming one therefore hands over the same reward custody `leafRecipient`
  ///      does, by a route that does not read `leafRecipient` at all, so it waits out the same
  ///      delay. Without it the delay on `leafRecipient` would be worth nothing: an owner could
  ///      seat an operator instead and take the same value immediately. The seat is not only
  ///      claims: on a leaf where governance enabled local voting, the operator can also
  ///      redistribute the Relay's gauge allocations (`LeafVoter.allocateGauges`). One live
  ///      proposal per chain: proposing again replaces it and restarts the delay.
  function proposeOperator(uint256 _chainId, address _operator) external;

  /// @notice Sends the proposed operator for `_chainId` to that chain, once its timelock elapsed.
  /// @param _chainId Leaf chain whose proposal is executed.
  /// @param _gasLimit Destination gas budget for the leaf call.
  /// @param _refundRecipient Address that receives unused dispatch value.
  /// @dev Payable: the Voter charges for the cross-chain message, paid from `msg.value`.
  function executeOperator(uint256 _chainId, uint256 _gasLimit, address _refundRecipient) external payable;

  /// @notice Clears the operator on `_chainId` and cancels any proposal pending for it.
  /// @param _chainId Leaf chain to clear the seat on.
  /// @param _gasLimit Destination gas budget for the leaf call.
  /// @param _refundRecipient Address that receives unused dispatch value.
  /// @dev No delay, since it only removes a capability. It reaches the seat through the Voter, so
  ///      it carries the Voter's own limits: it reverts on `CHAIN0`, on an unregistered chain, and
  ///      on a `Paused` one. A paused chain is the gap worth knowing about, because the leaf keeps
  ///      honouring the seated operator while it lasts: `LeafVoter.claimRewards` has no chain-status
  ///      gate. Cancelling the proposal still works there, through `cancelOperator`; emptying the
  ///      seat has to wait for the chain to leave `Paused`.
  function revokeOperator(uint256 _chainId, uint256 _gasLimit, address _refundRecipient) external payable;

  /// @notice Cancels the operator proposal pending for `_chainId`, if any.
  /// @param _chainId Leaf chain whose proposal is dropped.
  /// @dev Root-only and free: it touches no chain state and sends no message, so it works whatever
  ///      the Voter thinks of the chain. That is the point. `revokeOperator` also drops the
  ///      proposal, but it reverts with the dispatch, so it cannot cancel one aimed at a chain the
  ///      Voter refuses to message. Without this path such a proposal would sit there forever, and
  ///      one named for `CHAIN0` could never be executed nor removed.
  function cancelOperator(uint256 _chainId) external;

  /// @notice Replaces the Relay's display name, read by frontends and analytics.
  /// @param _name The new name.
  /// @dev Not the ERC-20 `name()` of either satellite token; those are fixed at initialization and
  ///      a rename leaves them untouched. They must stay fixed: Solady builds the EIP-712 domain
  ///      from `name()`, so a moved name would void every unspent `permit` and delegation signature.
  function setName(string calldata _name) external;

  /// @notice Accumulator lane: distributes `_amount` of `_token` to all current holders by
  ///         advancing its per-share index.
  /// @param _token Reward token being distributed.
  /// @param _amount Batch size to spread across the current share supply.
  /// @dev `_amount` cannot exceed the un-accounted balance that actually arrived. Reverts on an
  ///      unregistered token or zero supply.
  function notifyReward(address _token, uint256 _amount) external;

  /// @notice Pays out the caller's accrued reward in `_token` to `_to`, without burning shares.
  /// @param _token Reward token to claim.
  /// @param _to Recipient of the payout.
  /// @return _amount Reward amount transferred.
  function claim(address _token, address _to) external returns (uint256 _amount);

  /// @notice Claims the Relay's accrued fee and incentive rewards for `_chainId` to the recipient
  ///         configured for that chain, funding the dispatch with msg.value. Permissionless
  ///         pass-through to the Voter.
  /// @param _chainId Chain to claim rewards on: the local chain for a root claim, a leaf otherwise.
  /// @param _gasLimit Destination gas budget for the leaf claim dispatch (ignored on a root claim).
  /// @param _feeClaims Fee claim requests forwarded to the Voter; the keeper picks and sizes them.
  /// @param _incentiveClaims Incentive claim requests forwarded to the Voter; the keeper picks and
  ///        sizes them.
  /// @dev The recipient is read from per-chain config, never from the caller, so a caller can only
  ///      fund and trigger. A root claim must carry zero value.
  function claimRewards(
    uint256 _chainId,
    uint256 _gasLimit,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external payable;

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                  VIEW FUNCTIONS                                    __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Total reward in `_token` claimable by `_holder` right now: settled pending plus the
  ///         not-yet-settled accrual since their last checkpoint.
  /// @param _holder Holder to price.
  /// @param _token Reward token to price.
  /// @return _amount Claimable reward amount.
  function claimable(address _holder, address _token) external view returns (uint256 _amount);

  /// @notice Whether `_token` is in the reward registry (gates `notifyReward` and `claim`).
  /// @param _token Token to check.
  /// @return _registered True when the token is registered.
  function isRewardToken(address _token) external view returns (bool _registered);

  /// @notice The registered reward tokens, in registration order.
  /// @return _tokens The reward-token registry as an array.
  function rewardTokens() external view returns (address[] memory _tokens);

  /// @notice The Relay tier, for on-chain discovery. Implemented by each concrete subclass.
  /// @return _relayType The tier (Maxi, ProtocolL1 or ProtocolL2).
  function relayType() external view returns (RelayType _relayType);

  /// @notice The Relay's configuration block (tokenId, minimums, queue limits, caps, name/symbol).
  /// @return _config The full configuration struct.
  function relayConfig() external view returns (RelayConfig memory _config);

  /// @notice TOKEN-denominated weight backing the current shares, priced against the PT supply.
  /// @return _backing The backing counter (see `totalBacking` for the donation-inflation guard).
  function assetsBacking() external view returns (uint256 _backing);

  /// @notice Withdraw destination sentinel: route the weight to a freshly minted sAERO.
  /// @return _sentinel The mint sentinel value.
  function MINT_SENTINEL() external view returns (uint256 _sentinel);

  /// @notice Hard cap on the reward-token registry, bounding the per-transfer settle loop's gas.
  /// @return _max The maximum number of registered reward tokens (10).
  function MAX_REWARD_TOKENS() external view returns (uint256 _max);

  /// @notice Fixed-point scaling factor for the per-share reward accumulator.
  /// @return _scale The accumulator scaling factor (1e18).
  function ACC_SCALE() external view returns (uint256 _scale);

  /// @notice VotingEscrow that custodies the staked TOKEN; weight only moves through the VPM.
  /// @return _votingEscrow The VotingEscrow contract.
  function VOTING_ESCROW() external view returns (IVotingEscrow _votingEscrow);

  /// @notice Voter that owns allocation, the vote cooldown and cross-chain dispatch.
  /// @return _voter The Voter contract.
  function VOTER() external view returns (IVoter _voter);

  /// @notice The underlying protocol TOKEN staked behind the sAERO, read from VotingEscrow.
  /// @return _token The protocol TOKEN address.
  function TOKEN() external view returns (address _token);

  /// @notice Implementation cloned as the principal token (PT): a checkpointed RelayToken
  ///         (`RelayTokenVotes`), so governance can price a holder's weight at a past timepoint.
  /// @return _implementation The principal-token implementation address.
  function PRINCIPAL_TOKEN_IMPLEMENTATION() external view returns (address _implementation);

  /// @notice Implementation cloned as the yield token (YT): the plain RelayToken, no checkpoints.
  /// @return _implementation The yield-token implementation address.
  function YIELD_TOKEN_IMPLEMENTATION() external view returns (address _implementation);

  /// @notice Wrapped native token every native inflow is wrapped into.
  /// @return _wrappedNative The wrapped native token address.
  function WRAPPED_NATIVE() external view returns (address _wrappedNative);

  /// @notice The principal token (PT): the priced position carrying the withdraw right.
  /// @return _principalToken The principal token clone.
  function principalToken() external view returns (IRelayToken _principalToken);

  /// @notice The yield token (YT): the balance the reward accumulator reads.
  /// @return _yieldToken The yield token clone.
  function yieldToken() external view returns (IRelayToken _yieldToken);

  /// @notice Deposit-queue entries by id: async deposits that wait for processing. A consumed
  ///         entry is deleted, so it reads back as all zeroes; the history lives in the events.
  /// @param _id Deposit-queue id to read.
  /// @return _recipient Address the shares mint to, named at request.
  /// @return _requestedAt Timestamp the deposit was requested; zero once the entry is consumed.
  /// @return _tokenId Source sAERO of the pending deposit.
  /// @return _amount Staking weight queued by the deposit.
  function pendingDeposits(uint256 _id)
    external
    view
    returns (address _recipient, uint48 _requestedAt, uint128 _tokenId, uint128 _amount);

  /// @notice Bookkeeping of the deposit queue (see `DenseQueue.Queue`).
  /// @return _head Earliest id the walk must still visit (possibly a consumed entry), or zero.
  /// @return _tail Last issued id, or zero while no request was made.
  /// @return _count Outstanding (live) entries.
  function depositList() external view returns (uint40 _head, uint40 _tail, uint40 _count);

  /// @notice Total net weight queued across all pending (not yet admitted) deposits. Together with
  ///         `totalBacking` it accounts for every unit the Relay itself staked; anything above both
  ///         is donated weight.
  /// @return _weight The queued, not yet admitted deposit weight.
  function pendingDepositWeight() external view returns (uint256 _weight);

  /// @notice TOKEN-denominated weight backing the current shares: admitted deposits plus compounds
  ///         minus withdrawals. An internal counter, never read from `balanceOf` or `VE.staked()`,
  ///         so a donation cannot inflate the share price.
  /// @return _backing The current backing counter.
  function totalBacking() external view returns (uint256 _backing);

  /// @notice VoterPaymentsModule this Relay currently moves weight through; movable because the
  ///         module the Relay started on can lose its escrow authorization.
  /// @return _vpm The VoterPaymentsModule contract.
  function VPM() external view returns (IVoterPaymentsModule _vpm);

  /// @notice Governor `expressVote` casts into. Set at initialization, movable through `setGovernor`.
  /// @return _governor The Governor contract.
  function governor() external view returns (IGovernor _governor);

  /// @notice Adapter translating casts into the Governor's dialect, consulted by STATICCALL only.
  ///         Set at initialization, movable through `setGovernor`.
  /// @return _voteAdapter The vote adapter.
  function voteAdapter() external view returns (IRelayVoteAdapter _voteAdapter);

  /// @notice Reward-token balance already notified into the accumulator and not yet claimed; the
  ///         un-accounted remainder is all notify/compound may spend.
  ///         Invariant: `balanceOf(token) >= accountedBalance[token]`.
  /// @param _token Token to read.
  /// @return _accounted The accounted (notified, unclaimed) balance for the token.
  function accountedBalance(address _token) external view returns (uint256 _accounted);

  /// @notice Per-token accumulator: reward-per-share scaled by ACC_SCALE, advanced by `notifyReward`.
  /// @param _token Token to read.
  /// @return _index The per-share accumulator for the token.
  function rewardIndex(address _token) external view returns (uint256 _index);

  /// @notice Per-(holder, token) snapshot of `rewardIndex` at the holder's last settle.
  /// @param _holder Holder to read.
  /// @param _token Token to read.
  /// @return _checkpoint The holder's last-settled index for the token.
  function userCheckpoint(address _holder, address _token) external view returns (uint256 _checkpoint);

  /// @notice Per-(holder, token) reward settled into a claimable balance but not yet claimed.
  /// @param _holder Holder to read.
  /// @param _token Token to read.
  /// @return _pending The holder's settled, unclaimed reward for the token.
  function pendingReward(address _holder, address _token) external view returns (uint256 _pending);

  /// @notice Registered exits awaiting drain, stored by id. A settled exit is deleted, so it reads
  ///         back as all zeroes; the history lives in the events.
  /// @param _id Withdraw-queue id to read.
  /// @return _holder Owner of the escrowed shares for the entry.
  /// @return _registeredAt Registration timestamp anchoring the evacuation clock.
  /// @return _shares Shares escrowed by the entry.
  /// @return _destination Destination sAERO, or `MINT_SENTINEL` when the exit mints a fresh one.
  function withdrawals(uint256 _id)
    external
    view
    returns (address _holder, uint48 _registeredAt, uint256 _shares, uint256 _destination);

  /// @notice Bookkeeping of the withdraw queue (see `DenseQueue.Queue`).
  /// @return _head Id of the oldest exit that still waits, or zero when the queue is drained.
  /// @return _tail Last issued id, or zero while no exit was ever registered.
  /// @return _count Outstanding (undrained) exits.
  function withdrawQueue() external view returns (uint40 _head, uint40 _tail, uint40 _count);

  /// @notice Total shares escrowed across all queued withdrawals not yet drained; the drain
  ///         settles these against the idle chain0 weight.
  /// @return _shares The escrowed, undrained share total.
  function pendingWithdrawalShares() external view returns (uint256 _shares);

  /// @notice Shares each holder has locked into the withdraw queue: still on the holder's balances,
  ///         accruing rewards until burned, but locked in place. One counter locks the PT/YT pair
  ///         in equal units.
  /// @param _holder Holder to read.
  /// @return _shares The holder's escrowed (queued, undrained) share amount.
  function escrowedShares(address _holder) external view returns (uint256 _shares);

  /// @notice Whether the Relay is permanently closed. A closed Relay only winds down: no new
  ///         allocations, no new deposit requests; exits keep settling as returns land.
  /// @return _closed True once the Relay has been closed.
  function closed() external view returns (bool _closed);

  /// @notice Per-leaf-chain recipient that fee/incentive claims land at on that chain. Zero
  ///         disables Relay-orchestrated claims for the chain; a seated operator claims regardless.
  /// @param _chainId Leaf chain to read.
  /// @return _recipient The configured claim recipient for the chain (zero when unset).
  function leafRecipient(uint256 _chainId) external view returns (address _recipient);

  /// @notice Recipient proposed for a leaf chain, waiting out its timelock. Zero recipient means
  ///         nothing is pending.
  /// @param _chainId Leaf chain to read.
  /// @return _recipient The proposed claim recipient.
  /// @return _proposedAt Timestamp the proposal was stamped.
  function pendingLeafRecipient(uint256 _chainId) external view returns (address _recipient, uint48 _proposedAt);

  /// @notice The operator proposal pending for a leaf chain, if any.
  /// @param _chainId Leaf chain to read.
  /// @return _operator Address proposed as operator; zero when nothing is pending.
  /// @return _proposedAt Timestamp the proposal was stamped.
  function pendingOperator(uint256 _chainId) external view returns (address _operator, uint48 _proposedAt);

  /// @notice Governance weight each holder has already spent on a proposal, bounded by their
  ///         snapshot slice. Lives here rather than in the governance library, so relinking it
  ///         cannot reset what a holder spent. Keyed by Governor: proposal ids hash the proposal's
  ///         actions and not the Governor's address, so a rotation could otherwise inherit a
  ///         colliding id's consumption.
  /// @param _governor Governor the spend was booked against.
  /// @param _proposalId Proposal to read.
  /// @param _holder Holder to read.
  /// @return _used Weight already consumed from the holder's slice for the proposal.
  function usedGovernanceWeight(
    address _governor,
    uint256 _proposalId,
    address _holder
  ) external view returns (uint256 _used);
}
