// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {Ownable} from '@solady/auth/Ownable.sol';
import {OwnableRoles} from '@solady/auth/OwnableRoles.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';
import {RelayModuleLib} from 'V3/relay/libraries/RelayModuleLib.sol';

import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IRelayLeafModule} from 'V3/interfaces/relay/leaf/IRelayLeafModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title  RelayLeafModule
 * @notice One Relay's reward custody on one leaf chain: it claims the Relay's fees and incentives to itself, sells
 *         them for a single output token, and bridges that token to the Relay on root.
 * @dev    Every batch is written here, never taken from the caller. A swap is one exact-input sale of a reward
 *         token, funded by this module, paid to this module, on a route that ends in `OUT_TOKEN`. A bridge always
 *         lands on `RELAY`.
 *         A keeper cannot take the sold proceeds: `sweepToken` refuses `OUT_TOKEN` and every bridge pays
 *         `RELAY`. A compromised keeper still keeps four things: the swap price, any reward token not sold yet,
 *         the native balance, and the fee it lets the warp route keep on the overload it gates. The owner is
 *         the seat trusted with the proceeds instead. It revokes a keeper in one call, or sends the whole
 *         `OUT_TOKEN` balance to any address it names through `rescueOutToken`.
 * @dev    Access is solady's OwnableRoles. The owner grants and revokes the `KEEPER` bit, and moves its own seat
 *         through `transferOwnership` or the two-step handover. Renouncing is disabled so the proceeds always
 *         have a seat that can reach them.
 * @dev    One module per Relay per chain: its balance belongs to whoever configured it as their recipient, so two
 *         Relays sharing one would share the proceeds.
 */
contract RelayLeafModule is OwnableRoles, ReentrancyGuardTransient, IRelayLeafModule {
  using SafeTransferLib for address;

  /// @notice Share of the bridged amount the warp route may keep as its fee on the permissionless bridge, in pips.
  /// @dev Handed to the Metarouter as a `Pips` ceiling, so the router resolves it against the amount it bridges.
  uint256 private constant _MAX_BRIDGE_FEE_PIPS = 10_000;

  /// @inheritdoc IRelayLeafModule
  uint256 public constant KEEPER = 1 << 0;

  /// @inheritdoc IRelayLeafModule
  address public immutable RELAY;

  /// @inheritdoc IRelayLeafModule
  ILeafVoter public immutable LEAF_VOTER;

  /// @inheritdoc IRelayLeafModule
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @inheritdoc IRelayLeafModule
  uint256 public immutable TOKEN_ID;

  /// @inheritdoc IRelayLeafModule
  address public immutable OUT_TOKEN;

  /// @inheritdoc IRelayLeafModule
  address public immutable BRIDGE;

  /// @inheritdoc IRelayLeafModule
  uint32 public immutable ROOT_DOMAIN;

  /// @inheritdoc IRelayLeafModule
  uint256 public immutable MIN_BRIDGE_AMOUNT;

  /// @notice Restrict to a Metarouter the registry approves.
  /// @dev Carried by every call that hands this module's balance to a router. The approved set is the only bound the
  ///      permissionless bridge has, and on the keeper's calls it still limits where the balance can be routed.
  /// @dev A modifier rather than a line inside a helper, so each call declares all of its gates in its own signature
  ///      and no reader has to open a balance getter to find one.
  /// @param _router Metarouter the batch runs on.
  modifier onlyApprovedRouter(address _router) {
    if (!FACTORY_REGISTRY.isMetaRouterApproved(_router)) revert RouterNotApproved();
    _;
  }

  /// @notice Binds the module to one Relay, one sAERO, one output token and one bridge, and seats its owner.
  /// @dev The bridge is checked against the output token here, so a mismatched pair cannot be deployed and then
  ///      discovered with rewards already sitting in it.
  /// @dev No keeper is granted here, so a fresh module can swap nothing. Keeping the seat out of the constructor is
  ///      what makes the module's address independent of who drives it.
  /// @param _relay The Relay on root every bridge lands at.
  /// @param _leafVoter The LeafVoter claims run through; also the source of the registry.
  /// @param _tokenId The Relay's sAERO.
  /// @param _outToken The only token this module bridges.
  /// @param _bridge The warp route carrying `_outToken` to root.
  /// @param _rootDomain The Hyperlane domain of the root chain.
  /// @param _owner The address that grants keepers and may rescue the output token.
  /// @param _minBridgeAmount Smallest balance the open bridge accepts; zero means no floor.
  constructor(
    address _relay,
    ILeafVoter _leafVoter,
    uint256 _tokenId,
    address _outToken,
    address _bridge,
    uint32 _rootDomain,
    address _owner,
    uint256 _minBridgeAmount
  ) {
    if (
      _relay == address(0) || address(_leafVoter) == address(0) || _outToken == address(0) || _bridge == address(0)
        || _owner == address(0)
    ) revert ZeroAddress();
    if (_tokenId == 0) revert ZeroTokenId();
    if (_rootDomain == 0) revert ZeroDomain();
    if (ITokenRouter(_bridge).token() != _outToken) revert BridgeTokenMismatch();

    IFactoryRegistry _factoryRegistry = _leafVoter.FACTORY_REGISTRY();
    if (address(_factoryRegistry) == address(0)) revert ZeroAddress();

    _initializeOwner(_owner);

    RELAY = _relay;
    LEAF_VOTER = _leafVoter;
    FACTORY_REGISTRY = _factoryRegistry;
    TOKEN_ID = _tokenId;
    OUT_TOKEN = _outToken;
    BRIDGE = _bridge;
    ROOT_DOMAIN = _rootDomain;
    MIN_BRIDGE_AMOUNT = _minBridgeAmount;
  }

  /// @notice Accept the native a bridge refunds. `bridge` spends only the value attached to it, so native sent here
  ///         ahead of one funds nothing; an overpaying caller's refund lands here too, and only a keeper moves it.
  receive() external payable {}

  /// @inheritdoc IRelayLeafModule
  function claim(
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external nonReentrant {
    LEAF_VOTER.claimRewards(TOKEN_ID, address(this), _feeClaims, _incentiveClaims);
    emit Claimed(msg.sender);
  }

  /// @inheritdoc IRelayLeafModule
  function swap(SwapParams calldata _params)
    external
    nonReentrant
    onlyRoles(KEEPER)
    onlyApprovedRouter(_params.router)
  {
    if (_params.minAmountOut == 0) revert ZeroMinOut();
    if (_params.tokenIn == OUT_TOKEN) revert SameToken();
    // A route ending elsewhere turns the balance into a token this module can neither sell nor bridge, and one the
    // keeper can sweep.
    if (_routeOutput(_params.pools, _params.tokenIn) != OUT_TOKEN) revert RouteNotToOutToken();

    (bytes memory _commands, bytes[] memory _inputs) = _buildSwap(_params);

    _params.tokenIn.safeApproveWithRetry(_params.router, _params.amountIn);
    IMetarouter(_params.router).execute(_commands, _inputs, _params.deadline);
    _params.tokenIn.safeApproveWithRetry(_params.router, 0);

    emit Swapped(_params.tokenIn, _params.amountIn, _params.minAmountOut);
  }

  /// @inheritdoc IRelayLeafModule
  function bridge(address _metarouter) external payable nonReentrant onlyApprovedRouter(_metarouter) {
    uint256 _amount = _bridgeableBalance();
    if (_amount < MIN_BRIDGE_AMOUNT) revert BelowMinBridge();
    // Fixed rather than taken from the caller: `maxFee` is the only bound on what the warp route may keep, and this
    // call is permissionless, so a caller-named ceiling would let anyone donate the balance away.
    _dispatchBridge(
      _metarouter, _amount, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _MAX_BRIDGE_FEE_PIPS})
    );
  }

  /// @inheritdoc IRelayLeafModule
  function bridge(
    address _metarouter,
    uint256 _maxFee
  ) external payable nonReentrant onlyRoles(KEEPER) onlyApprovedRouter(_metarouter) {
    _dispatchBridge(
      _metarouter, _bridgeableBalance(), IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _maxFee})
    );
  }

  /// @inheritdoc IRelayLeafModule
  function sweepNative(address _to) external nonReentrant onlyRoles(KEEPER) {
    RelayModuleLib.sweepNative(_to);
  }

  /// @inheritdoc IRelayLeafModule
  function sweepToken(address _token, address _to) external nonReentrant onlyRoles(KEEPER) {
    // Kept here rather than in the library: the proceeds guard is this module's own, since only it
    // has an output token the keeper must not be able to take.
    if (_token == OUT_TOKEN) revert CannotSweepOutToken();
    RelayModuleLib.sweepToken(_token, _to);
  }

  /// @inheritdoc IRelayLeafModule
  function rescueOutToken(address _to) external nonReentrant onlyOwner {
    if (_to == address(0)) revert ZeroAddress();

    uint256 _amount = IERC20(OUT_TOKEN).balanceOf(address(this));
    if (_amount == 0) revert NothingToSweep();

    OUT_TOKEN.safeTransfer(_to, _amount);
    emit OutTokenRescued(_to, _amount);
  }

  /// @inheritdoc Ownable
  /// @dev Disabled: a vacant owner seat would leave `rescueOutToken` with no caller and the keeper set frozen, with
  ///      the bridge immutable. Handing the module over is `transferOwnership` or the two-step handover.
  function renounceOwnership() public payable virtual override {
    revert OwnershipRenounceDisabled();
  }

  /// @notice Funds the batch with the output token and bridges it to the Relay on root.
  /// @dev The batch is built here rather than taken from the caller: the funding leg and the bridge leg both name
  ///      amounts and addresses this contract already holds as immutables.
  /// @param _metarouter Metarouter to dispatch through.
  /// @param _amount Amount of `OUT_TOKEN` the batch spends.
  /// @param _maxFee Ceiling on the fee the warp route may keep, absolute or in pips of `_amount`.
  function _dispatchBridge(address _metarouter, uint256 _amount, IMetarouter.BalanceSpend memory _maxFee) private {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.FUND_ERC20)), bytes1(uint8(Commands.BRIDGE_TOKEN)));
    IMetarouter.BalanceSpend memory _spend =
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount});

    bytes[] memory _inputs = new bytes[](2);
    _inputs[0] = abi.encode(OUT_TOKEN, _spend);
    _inputs[1] = abi.encode(
      IMetarouter.BridgeTokenParams({
        token: OUT_TOKEN,
        bridge: BRIDGE,
        spend: _spend,
        messageFee: msg.value,
        maxFee: _maxFee,
        domain: ROOT_DOMAIN,
        recipient: RELAY,
        // A named recipient never derives an interchain account, so the config stays empty.
        icaConfig: IMetarouter.IcaConfig({router: address(0), ism: address(0)})
      })
    );

    OUT_TOKEN.safeApproveWithRetry(_metarouter, _amount);
    IMetarouter(_metarouter).execute{value: msg.value}(_commands, _inputs, block.timestamp);
    OUT_TOKEN.safeApproveWithRetry(_metarouter, 0);

    emit Bridged(msg.sender, _amount);
  }

  /// @notice Reads the balance a bridge would hand to the batch.
  /// @return _amount The module's whole `OUT_TOKEN` balance.
  function _bridgeableBalance() private view returns (uint256 _amount) {
    _amount = IERC20(OUT_TOKEN).balanceOf(address(this));
    if (_amount == 0) revert NothingToBridge();
  }

  /// @notice Writes the one-command batch that sells `tokenIn` into `OUT_TOKEN`.
  /// @dev Built here rather than taken from the caller: the payer, the recipient and the token sold are this
  ///      module's, so the keeper is left with the router, the route, the amount and the floor.
  /// @param _params The sale.
  /// @return _commands The command byte.
  /// @return _inputs The encoded sale, index-aligned with `_commands`.
  function _buildSwap(SwapParams calldata _params)
    private
    view
    returns (bytes memory _commands, bytes[] memory _inputs)
  {
    uint256 _command = _params.family == PoolFamily.CL ? Commands.CL_SWAP_EXACT_IN : Commands.V2_SWAP_EXACT_IN;
    _commands = abi.encodePacked(bytes1(uint8(_command)));

    _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.SwapExactInParams({
        pools: _params.pools,
        tokenIn: _params.tokenIn,
        amountIn: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _params.amountIn}),
        payerIsUser: true,
        minAmountOut: _params.minAmountOut,
        recipient: address(this)
      })
    );
  }

  /// @notice Walks a forward-ordered route and returns the token its last hop pays out.
  /// @dev Reads only `token0`/`token1`, which both pool families answer. A contract that lies here still fails the
  ///      router's own `FACTORY_REGISTRY.targetToFactory` and `IPoolFactory.isPool` checks, so it never swaps.
  /// @param _pools Route pools.
  /// @param _tokenIn Input token of the first pool.
  /// @return _tokenOut Token the last pool pays out.
  function _routeOutput(address[] memory _pools, address _tokenIn) private view returns (address _tokenOut) {
    uint256 _length = _pools.length;
    if (_length == 0) revert InvalidRoute();

    _tokenOut = _tokenIn;
    for (uint256 _i; _i < _length; ++_i) {
      address _token0 = IPool(_pools[_i]).token0();
      address _token1 = IPool(_pools[_i]).token1();
      if (_tokenOut == _token0) _tokenOut = _token1;
      else if (_tokenOut == _token1) _tokenOut = _token0;
      else revert InvalidRoute();
    }
  }
}
