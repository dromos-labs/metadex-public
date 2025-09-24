// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IRelayModule} from 'V3/interfaces/relay/IRelayModule.sol';

/// @title  IRelayIcaModule
/// @notice Module that drives one Relay's interchain account, so rewards claimed to a leaf chain can be moved from
///         there. It is not an entrypoint: it holds no Relay role and never touches the Relay's balances.
/// @dev The module has one seat, the keeper, and it is the only party that can move anything. The seat is not the
///      keeper's to pass on: only the served Relay's admin moves it. Filling the seat waits out the Relay's own
///      `entrypointTimelock`, the same delay that governs repointing a `leafRecipient`, because the seat commands the
///      rewards already sitting in the interchain account and repointing the recipient cannot reach those. Emptying
///      it is immediate, so a compromised keeper is frozen out in one call.
interface IRelayIcaModule is IRelayModule {
  /*//////////////////////////////////////////////////////////////
                              STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice One remote call the interchain account runs when the plan is revealed.
  /// @dev Mirrors Hyperlane's `CallLib.Call` field for field rather than importing it, the way
  ///      `IInterchainAccountRouter` mirrors the router's selectors. The order and the types have to match exactly:
  ///      the commitment hashes `abi.encode(calls)`, so a differing layout produces a commitment the destination can
  ///      never match. `to` is a word because Hyperlane supports non-EVM targets.
  /// @param to Target of the call, left-padded.
  /// @param value Native the account spends on the call, out of its own balance on the leaf.
  /// @param data Calldata of the call.
  struct RemoteCall {
    bytes32 to;
    uint256 value;
    bytes data;
  }

  /// @notice One reward sale the keeper asks for, on the leaf.
  /// @dev The module writes everything else. The keeper is left with what root cannot check: the leaf address of the
  ///      token, how much of it to sell, the route, and the floor the sale has to clear.
  /// @param tokenIn Leaf address of the reward token being sold.
  /// @param amountIn Exact amount to sell. Exact rather than a share, because the account's balance is not readable
  ///        from root and the swap command rejects a percentage from a user payer.
  /// @param family Pool family the route runs through.
  /// @param pools Forward-ordered pools in the route.
  /// @param minAmountOut Floor the sale has to clear, enforced by the leaf's own Metarouter.
  struct SwapLeg {
    address tokenIn;
    uint256 amountIn;
    PoolFamily family;
    address[] pools;
    uint256 minAmountOut;
  }

  /// @notice Everything one dispatch needs, beyond what the module already holds.
  /// @param domain Hyperlane domain of the leaf the plan runs on.
  /// @param legs Sales the plan performs, in order. At least one, unless the plan sweeps.
  /// @param sweepHeldOutToken Whether to bridge the output token the account already holds along with the sales'
  ///        output. A reward paid in the output token itself never passes through a sale, so this is the only way
  ///        it goes home. Set it on a plan with no sales at all to bridge nothing but that balance.
  /// @param leafMessageFee Native the account spends on the leaf to dispatch the bridge. It comes out of the
  ///        account's own balance there, so the account has to be funded on that chain before a plan can land.
  /// @param leafDeadline Timestamp after which the leaf's Metarouter batch reverts.
  /// @param messageFee Native this module forwards for the root-side commit and reveal dispatch.
  /// @param hookMetadata Standard hook metadata for the reveal message. Nothing on root quotes it.
  struct PlanParams {
    uint32 domain;
    SwapLeg[] legs;
    bool sweepHeldOutToken;
    uint256 leafMessageFee;
    uint256 leafDeadline;
    uint256 messageFee;
    bytes hookMetadata;
  }

  /// @notice What the plan on one leaf is built against.
  /// @dev Every field is a destination the plan hands value to, so the whole struct waits out a delay rather than
  ///      moving through a plain setter. A wrong `metarouter` is handed an allowance over the account's reward
  ///      tokens, and a wrong `bridge` keeps the collateral while reporting the right token, which is all
  ///      `CrosschainLib.bridgeToken` checks. Neither is an operational mistake; both are theft.
  /// @param metarouter Metarouter on the leaf the plan's batch runs through.
  /// @param outToken The single token every sale on that leaf ends in, and the only one bridged back.
  /// @param bridge Warp route carrying `outToken` from that leaf to root.
  struct LeafConfig {
    address metarouter;
    address outToken;
    address bridge;
  }

  /// @notice A leaf configuration waiting out its delay.
  /// @param config Proposed configuration; a zero `metarouter` means no proposal is live.
  /// @param proposedAt Timestamp the proposal was stamped at.
  struct PendingLeafConfig {
    LeafConfig config;
    uint48 proposedAt;
  }

  /// @notice A keeper waiting out its delay before it can take the seat.
  /// @param keeper Proposed keeper; zero when no proposal is live.
  /// @param proposedAt Timestamp the proposal was stamped at.
  struct PendingKeeper {
    address keeper;
    uint48 proposedAt;
  }

  /*//////////////////////////////////////////////////////////////
                               EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the Relay's admin proposes a keeper, starting its delay.
  /// @param keeper Proposed keeper.
  /// @param executableAt Timestamp from which the proposal may be executed.
  event KeeperProposed(address indexed keeper, uint256 executableAt);

  /// @notice Emitted when a live keeper proposal is dropped without ever taking the seat.
  /// @dev Only `clearKeeper` drops a proposal this way. A proposal consumed by `executeKeeper` is announced by
  ///      `KeeperSet` instead, which already carries the outcome.
  /// @param keeper Proposed keeper that was dropped.
  event KeeperProposalDropped(address indexed keeper);

  /// @notice Emitted when the seat changes hands.
  /// @param previousKeeper Keeper that held the seat, zero on the first one.
  /// @param keeper Keeper that holds it now, zero when the seat was emptied.
  event KeeperSet(address indexed previousKeeper, address indexed keeper);

  /// @notice Emitted when the Relay's admin proposes a leaf configuration, starting its delay.
  /// @param domain Leaf domain the configuration is for.
  /// @param config Proposed configuration.
  /// @param executableAt Timestamp from which the proposal may be executed.
  event LeafConfigProposed(uint32 indexed domain, LeafConfig config, uint256 executableAt);

  /// @notice Emitted when a live leaf-configuration proposal is dropped without ever taking effect.
  /// @param domain Leaf domain the dropped proposal was for.
  event LeafConfigProposalDropped(uint32 indexed domain);

  /// @notice Emitted when a leaf configuration takes effect.
  /// @param domain Leaf domain the configuration is for.
  /// @param config Configuration now in effect; a zero `metarouter` means it was cleared.
  event LeafConfigSet(uint32 indexed domain, LeafConfig config);

  /// @notice Emitted when the keeper dispatches a plan.
  /// @dev Carries the whole plan on purpose. The commitment travels alone, so the calls and the salt behind it have
  ///      to be recoverable by whoever reveals them on the leaf, and `revealAndExecute` is open to anyone holding
  ///      the preimage. Without this event an armed commitment could never be executed.
  /// @param keeper Keeper that dispatched it.
  /// @param domain Leaf domain the plan runs on.
  /// @param salt Blinding value the commitment was hashed with.
  /// @param commitment Commitment the destination account will match the reveal against.
  /// @param calls ABI-encoded `RemoteCall[]` the account will run.
  event PlanDispatched(address indexed keeper, uint32 indexed domain, bytes32 salt, bytes32 commitment, bytes calls);

  /*//////////////////////////////////////////////////////////////
                               ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a caller other than the seated keeper tries to drive the module.
  error NotKeeper();

  /// @notice Thrown when a caller other than the served Relay's admin tries to move the seat.
  error NotRelayAdmin();

  /// @notice Thrown when executing a keeper proposal that does not exist.
  error KeeperNotProposed();

  /// @notice Thrown when executing a keeper proposal whose delay has not elapsed.
  error KeeperTimelockNotElapsed();

  /// @notice Thrown when executing a leaf-configuration proposal that does not exist.
  error LeafConfigNotProposed();

  /// @notice Thrown when executing a leaf-configuration proposal whose delay has not elapsed.
  error LeafConfigTimelockNotElapsed();

  /// @notice Thrown when a configuration names Hyperlane domain zero, which no warp route accepts.
  error ZeroDomain();

  /// @notice Thrown when a plan names a leaf that has no configuration in effect.
  error LeafConfigMissing();

  /// @notice Thrown when a plan carries no sales and sweeps nothing, which would bridge nothing and still pay a
  ///         message fee.
  error NoSwapLegs();

  /// @notice Thrown when a sale names no amount, which the swap command rejects anyway.
  error ZeroAmountIn();

  /// @notice Thrown when a sale names no floor, which would leave it unbounded on the leaf.
  error ZeroMinOut();

  /// @notice Thrown when a sale names an empty route.
  error EmptyRoute();

  /// @notice Thrown when a sale sells the output token, which the bridge leg already sweeps.
  error SameToken();

  /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Propose the keeper that will drive this module, starting its delay.
  /// @dev Only the served Relay's admin, read live off the Relay, so a Relay that changes hands or promotes to L2
  ///      carries the module with it.
  /// @dev One live proposal at a time: proposing again replaces it and restarts the delay.
  /// @param _keeper Address to seat once the delay elapses; zero is refused, since `clearKeeper` empties the seat.
  function proposeKeeper(address _keeper) external;

  /// @notice Seat the proposed keeper once its delay has elapsed.
  /// @dev The delay is the served Relay's `entrypointTimelock`, read live, so the seat matches the window the Relay
  ///      gives its depositors everywhere else. That window is what the delay is for: the seat commands the rewards
  ///      already claimed into the interchain account, which repointing `leafRecipient` cannot reach, and the Maxi
  ///      tier has no sweep and no L2 promotion, so this would otherwise be its admin's one instant path to that
  ///      balance.
  function executeKeeper() external;

  /// @notice Empty the seat, and drop any live proposal with it.
  /// @dev Immediate on purpose, and the reason the delay above is one-sided: it only removes a capability, so it is
  ///      how the admin freezes a compromised keeper out in one call. Nothing is stranded, since the admin can
  ///      always propose another.
  function clearKeeper() external;

  /// @notice Propose the configuration a leaf's plans are built against, starting its delay.
  /// @dev Every field is a destination the plan hands value to, so this is the same shape as the keeper seat and the
  ///      Relay's own `leafRecipient`: propose, wait, execute.
  /// @param _domain Leaf domain the configuration is for.
  /// @param _config Configuration to propose. No field may be zero.
  function proposeLeafConfig(uint32 _domain, LeafConfig calldata _config) external;

  /// @notice Put a proposed leaf configuration into effect once its delay has elapsed.
  /// @param _domain Leaf domain whose proposal is executed.
  function executeLeafConfig(uint32 _domain) external;

  /// @notice Drop a leaf's configuration and any live proposal for it, at once.
  /// @dev Immediate, unlike putting one into effect: clearing only stops plans from being dispatched to that leaf.
  /// @param _domain Leaf domain to clear.
  function clearLeafConfig(uint32 _domain) external;

  /// @notice Dispatch a swap-and-bridge plan for the interchain account on one leaf.
  /// @dev The module writes the plan. The account approves the leaf's Metarouter once per token sold, then runs one
  ///      batch on it: every sale is an exact-input swap whose output the router keeps and tracks, and the last
  ///      command bridges the whole tracked balance of the output token to the Relay on root. So a compromised
  ///      keeper can misprice a sale, and cannot send anything anywhere the configuration did not already name.
  /// @dev `sweepHeldOutToken` adds one command that funds the Metarouter from the account before the bridge, so
  ///      the output token the account already holds goes home too. Root cannot know that balance, so the plan
  ///      grants an unlimited allowance ahead of the batch and revokes it after. All three calls run in the same
  ///      reveal, so the allowance never outlives the transaction that opens it.
  /// @dev The commitment is hashed here rather than off-chain, which is what pins the plan. Its preimage goes out in
  ///      `PlanDispatched`, since the destination needs the calls and the salt to execute what was armed.
  /// @dev The account spends its own native on the leaf for the bridge dispatch, so it has to hold native there.
  /// @param _params The plan.
  function dispatchPlan(PlanParams calldata _params) external payable;

  /// @notice Send this module's native balance to `_to`.
  /// @dev The Metarouter refunds a batch's unspent native to its caller, which is this module.
  /// @dev An empty balance reverts rather than passing silently, so a recovery that moved nothing is never
  ///      mistaken for one that worked.
  /// @param _to Recipient of the balance.
  function sweepNative(address _to) external;

  /// @notice Send this module's whole balance of `_token` to `_to`.
  /// @dev Same reason as `sweepNative`: the Metarouter returns a batch's tracked token balances to this module.
  /// @dev An empty balance reverts, which also covers a token whose `balanceOf` reverts: solady reads that as zero
  ///      rather than bubbling it up, so without this the sweep of a paused token would report success and move
  ///      nothing.
  /// @param _token Token to move out.
  /// @param _to Recipient of the balance.
  function sweepToken(address _token, address _to) external;

  /// @notice Address this module's interchain account resolves to on `_domain` under the enrolled configuration.
  /// @dev This is the address to register as the Relay's `leafRecipient` for that chain, and the two sides are
  ///      keyed differently: `_domain` is a Hyperlane domain, while `leafRecipient` is keyed by EVM chain id and
  ///      compared against `block.chainid` when a claim lands. Nothing in `V3/src` maps between the two, so the
  ///      caller holds both identifiers for the same chain itself. Passing a chain id here reverts in Hyperlane
  ///      whenever no router is enrolled under that number; the case to watch is a chain id that collides with a
  ///      different enrolled domain, which returns a plausible account derived for the wrong chain.
  /// @param _domain Destination Hyperlane domain.
  /// @return _account The remote account address.
  function interchainAccount(uint32 _domain) external view returns (address _account);

  /// @notice Address this module's interchain account resolves to under a custom router and ISM.
  /// @dev A zero router is refused rather than derived. The Metarouter reads a destination pair the same way
  ///      `CrosschainLib` does, and it only takes the custom branch on a nonzero router: it rejects a zero router
  ///      carrying an ISM outright, and reads an all-zero pair as the enrolled configuration, which resolves through
  ///      a different derivation. Either zero-router answer would therefore be an address no batch of this module's
  ///      can reach. Read the enrolled account through the `_domain` overload instead.
  /// @param _router Custom destination interchain account router.
  /// @param _ism Custom destination interchain security module; zero delegates to Hyperlane's default verifier.
  /// @return _account The remote account address.
  function interchainAccount(address _router, address _ism) external view returns (address _account);

  /*//////////////////////////////////////////////////////////////
                                VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @notice Address allowed to drive the module. Zero until the Relay's admin fills the seat.
  /// @return _keeper The seated keeper.
  function keeper() external view returns (address _keeper);

  /// @notice The configuration a leaf's plans are built against. A zero `metarouter` means none is in effect.
  /// @param _domain Leaf domain to read.
  /// @return _metarouter Metarouter the plan's batch runs through.
  /// @return _outToken Token every sale ends in and the only one bridged.
  /// @return _bridge Warp route carrying `_outToken` to root.
  function leafConfig(uint32 _domain) external view returns (address _metarouter, address _outToken, address _bridge);

  /// @notice The leaf-configuration proposal waiting out its delay, if any.
  /// @param _domain Leaf domain to read.
  /// @return _config Proposed configuration; a zero `metarouter` means no proposal is live.
  /// @return _proposedAt Timestamp the proposal was stamped at.
  function pendingLeafConfig(uint32 _domain) external view returns (LeafConfig memory _config, uint48 _proposedAt);

  /// @notice Number of plans this module has dispatched, which is what keeps two identical plans apart.
  /// @dev The destination rejects a commitment that is already armed, so the salt carries this counter.
  /// @return _nonce The count.
  function planNonce() external view returns (uint256 _nonce);

  /// @notice Hyperlane domain of the root chain, where every bridge leg lands.
  /// @return _domain The root domain.
  function ROOT_DOMAIN() external view returns (uint32 _domain);

  /// @notice The keeper proposal waiting out its delay, if any.
  /// @return _keeper Proposed keeper; zero when no proposal is live.
  /// @return _proposedAt Timestamp the proposal was stamped at.
  function pendingKeeper() external view returns (address _keeper, uint48 _proposedAt);

  /// @notice Relay whose admin seats this module's keeper.
  /// @return _relay The served Relay.
  function RELAY() external view returns (IRelayEntrypoint _relay);

  /// @notice Metarouter every batch runs through.
  /// @return _metarouter The bound Metarouter.
  function METAROUTER() external view returns (IMetarouter _metarouter);

  /// @notice Interchain account router the bound Metarouter derives accounts with.
  /// @return _icaRouter The interchain account router.
  function ICA_ROUTER() external view returns (IInterchainAccountRouter _icaRouter);
}
