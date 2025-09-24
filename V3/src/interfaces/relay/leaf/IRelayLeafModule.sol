// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayModule} from 'V3/interfaces/relay/IRelayModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title  IRelayLeafModule
 * @notice The leaf-side custody a Relay's rewards pass through on their way back to root.
 * @dev Access is solady's OwnableRoles: `owner`, `grantRoles`, `revokeRoles`, `transferOwnership` and the two-step
 *      handover come from there and are not repeated here.
 */
interface IRelayLeafModule is IRelayModule {
  /*//////////////////////////////////////////////////////////////
                              STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice A sale a keeper requests. The module writes the Metarouter batch from it.
  /// @param router Metarouter to run the batch on; it must be approved by governance.
  /// @param tokenIn Reward token being sold.
  /// @param amountIn Amount of `tokenIn` the router may take.
  /// @param minAmountOut Floor on the measured `OUT_TOKEN` increase.
  /// @param deadline Timestamp after which the batch reverts.
  /// @param family Pool family every pool in `pools` belongs to.
  /// @param pools Forward-ordered route from `tokenIn` to `OUT_TOKEN`.
  struct SwapParams {
    address router;
    address tokenIn;
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 deadline;
    PoolFamily family;
    address[] pools;
  }

  /*//////////////////////////////////////////////////////////////
                               EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when rewards are claimed into this module.
  /// @param caller Address that triggered the claim.
  event Claimed(address indexed caller);

  /// @notice Emitted when a swap lands.
  /// @param tokenIn Token that was sold.
  /// @param amountIn Amount the router was allowed to take.
  /// @param minAmountOut Floor the sale named.
  event Swapped(address indexed tokenIn, uint256 amountIn, uint256 minAmountOut);

  /// @notice Emitted when the module sends its `OUT_TOKEN` balance to the Relay on root.
  /// @dev Records the dispatch, not the arrival: the transfer completes on root later.
  /// @param caller Address that triggered the bridge.
  /// @param amount Amount handed to the bridge, before its own fee.
  event Bridged(address indexed caller, uint256 amount);

  /// @notice Emitted when the owner moves the output token out of the module.
  /// @param to Recipient the owner named.
  /// @param amount Amount moved, always the module's whole `OUT_TOKEN` balance.
  event OutTokenRescued(address indexed to, uint256 amount);

  /*//////////////////////////////////////////////////////////////
                               ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the module is bound to token id zero, which is never a real sAERO.
  error ZeroTokenId();

  /// @notice Thrown when the module is bound to Hyperlane domain zero, which no warp route accepts.
  error ZeroDomain();

  /// @notice Thrown when the bridge does not carry the module's output token.
  error BridgeTokenMismatch();

  /// @notice Thrown on `renounceOwnership`: a vacant owner seat would leave the proceeds with no way out, so the
  ///         ownership can only be handed over.
  error OwnershipRenounceDisabled();

  /// @notice Thrown when a swap names no output floor, which would leave the sale unchecked.
  error ZeroMinOut();

  /// @notice Thrown when the named router is not approved by governance.
  error RouterNotApproved();

  /// @notice Thrown when a swap sells the output token instead of a reward.
  error SameToken();

  /// @notice Thrown when a route is empty or has a pool that does not pair the running token.
  error InvalidRoute();

  /// @notice Thrown when a route ends in a token other than `OUT_TOKEN`.
  error RouteNotToOutToken();

  /// @notice Thrown when a bridge is attempted with no output token held.
  error NothingToBridge();

  /// @notice Thrown when the open bridge finds less than `MIN_BRIDGE_AMOUNT`.
  error BelowMinBridge();

  /// @notice Thrown when a sweep names `OUT_TOKEN`, which a keeper may only move through `bridge`.
  error CannotSweepOutToken();

  /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Claims the Relay's accrued fees and incentives on this chain into this module.
  /// @dev Permissionless. The recipient is written here rather than taken from the caller, and the LeafVoter skips
  ///      any target that fails its own registry check, so a hostile array wastes the caller's gas and nothing else.
  /// @dev `LeafVoter.claimRewards` only admits the sAERO's seated operator. The Relay owner seats this module from
  ///      root through `proposeOperator` and `executeOperator`, behind the entrypoint timelock. The module cannot
  ///      seat itself, so a deploy alone does not make claims work.
  /// @param _feeClaims Fee claim requests forwarded to the LeafVoter.
  /// @param _incentiveClaims Incentive claim requests forwarded to the LeafVoter.
  function claim(
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external;

  /// @notice Sells a reward token for the output token.
  /// @dev Keeper only. The module writes the batch itself: one exact-input sale of `tokenIn`, funded by this module,
  ///      paid to this module, through the route the keeper names. The route must end in `OUT_TOKEN`, and it is
  ///      checked before any approval is set. A sale split across routes is several calls, each with its own floor.
  /// @dev The keeper still picks the price: `minAmountOut` is its own, this call only rejects zero, and the router
  ///      enforces it on the sale. The per-call loss ceiling is `amountIn`. There is no ceiling across calls.
  /// @param _params The sale.
  function swap(SwapParams calldata _params) external;

  /// @notice Sends the whole output-token balance to the Relay on root.
  /// @dev Permissionless, because the caller decides nothing about where the value goes: the token, the bridge,
  ///      the destination domain, the recipient and the fee ceiling are all fixed. The caller picks the Metarouter
  ///      from the approved set and attaches the message fee, and whatever the route leaves unspent is refunded to
  ///      this module rather than to them.
  /// @dev The fee ceiling is one percent of the balance, and the balance must reach `MIN_BRIDGE_AMOUNT`. Both keep
  ///      an open call from feeding the warp route dust. A balance that fails either needs the keeper overload or
  ///      `rescueOutToken`.
  /// @dev What lands on root is the warp route's counterpart of `OUT_TOKEN`, not this address, and it arrives as a
  ///      plain ERC20 credit that nothing here auto-accounts. Choose `OUT_TOKEN` so its root counterpart is already
  ///      a registered reward token of the Relay, or one a Converter entrypoint can convert: a Maxi and a level-1
  ///      Protocol Relay cannot grow their registry after creation.
  /// @param _metarouter Metarouter to dispatch through; it must be approved by governance.
  function bridge(address _metarouter) external payable;

  /// @notice Sends the whole output-token balance to the Relay on root, under a fee ceiling the keeper names.
  /// @dev Keeper only: this is for a route whose token fee is above the one percent the permissionless overload
  ///      derives. A caller-named ceiling on that open call would let anyone hand the balance to the warp route, so
  ///      the ceiling moves with the role. Nothing else in the batch changes, so the bridge still pays `RELAY`.
  /// @dev The floor does not apply here, so this is also how a tail below `MIN_BRIDGE_AMOUNT` goes home.
  /// @param _metarouter Metarouter to dispatch through; it must be approved by governance.
  /// @param _maxFee Largest amount of `OUT_TOKEN` the warp route may keep as its fee.
  function bridge(address _metarouter, uint256 _maxFee) external payable;

  /// @notice Send this module's native balance to `_to`.
  /// @dev Keeper only.
  /// @param _to Recipient of the balance.
  function sweepNative(address _to) external;

  /// @notice Send this module's whole balance of `_token` to `_to`.
  /// @dev Keeper only. `OUT_TOKEN` is refused so a compromised keeper cannot take proceeds it has already sold.
  /// @dev An empty balance reverts, which also covers a token whose `balanceOf` reverts: solady reads that as zero
  ///      rather than bubbling it up, so the sweep of a paused token would otherwise report success and move nothing.
  /// @param _token Token to move out; `OUT_TOKEN` is refused.
  /// @param _to Recipient of the balance.
  function sweepToken(address _token, address _to) external;

  /// @notice Send this module's whole `OUT_TOKEN` balance to `_to`.
  /// @dev Owner only. This is the escape for a bridge that no longer delivers, whether it is paused, deprecated or
  ///      unenrolled from `ROOT_DOMAIN`. Without it the proceeds would sit at this address forever, since the bridge
  ///      is immutable and a redeploy lands at a new module. A keeper never gets this door.
  /// @param _to Recipient of the balance.
  function rescueOutToken(address _to) external;

  /*//////////////////////////////////////////////////////////////
                                VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @notice Role bit that drives the module: swaps, the keeper bridge and both sweeps. Granted and revoked by the
  ///         owner through solady's `grantRoles` and `revokeRoles`, with no delay either way.
  /// @return _role The KEEPER role bit.
  function KEEPER() external view returns (uint256 _role);

  /// @notice The Relay this module serves, on the root chain. Every bridge lands here.
  /// @dev Held as a plain address: it is root-chain code, so nothing on this chain can call it.
  /// @return _relay The Relay.
  function RELAY() external view returns (address _relay);

  /// @notice The LeafVoter this module claims through.
  /// @return _leafVoter The LeafVoter.
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);

  /// @notice The registry that decides which routers a swap or bridge may run on.
  /// @return _factoryRegistry The registry, read from the LeafVoter at construction.
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry _factoryRegistry);

  /// @notice The Relay's sAERO, whose rewards this module claims.
  /// @return _tokenId The token id.
  function TOKEN_ID() external view returns (uint256 _tokenId);

  /// @notice The only token this module bridges. Every reward is swapped into it first.
  /// @return _outToken The output token.
  function OUT_TOKEN() external view returns (address _outToken);

  /// @notice The warp route that carries `OUT_TOKEN` to root.
  /// @dev Immutable on purpose. A bridge is asynchronous, so unlike a swap its result cannot be measured here; a
  ///      caller-named route could keep the tokens and report nothing.
  /// @return _bridge The bridge.
  function BRIDGE() external view returns (address _bridge);

  /// @notice The Hyperlane domain of the root chain.
  /// @return _domain The domain.
  function ROOT_DOMAIN() external view returns (uint32 _domain);

  /// @notice The smallest `OUT_TOKEN` balance the open bridge accepts; zero means no floor.
  /// @dev Sized to the token. A floor at or above one hundred times the route's fixed fee keeps the one percent
  ///      ceiling from ever refusing an open bridge, and makes a griefer's dust bridges impossible.
  /// @return _minBridgeAmount The floor, in `OUT_TOKEN` units.
  function MIN_BRIDGE_AMOUNT() external view returns (uint256 _minBridgeAmount);
}
