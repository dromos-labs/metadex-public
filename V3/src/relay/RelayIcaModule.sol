// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IRelayIcaModule} from 'V3/interfaces/relay/IRelayIcaModule.sol';
import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';
import {RelayModuleLib} from 'V3/relay/libraries/RelayModuleLib.sol';

/**
 * @title  RelayIcaModule
 * @notice Drives one Relay's interchain account. A Relay claims its leaf-chain rewards to an address it configures
 *         per chain; pointing that address at this module's interchain account is what lets those rewards be moved
 *         later, since only this module can make that account act.
 * @dev    One deployment per Relay, and the binding is in code rather than in the deployment. The account is derived
 *         from the caller of the Metarouter, so a module shared by two Relays would give them one shared account:
 *         either Relay's keeper could then move the other's rewards.
 * @dev    This is not an entrypoint. It holds no role on the Relay and never calls `pull`, `compound` or
 *         `notifyReward`. Its own keeper drives it, and the only thing it reads off the Relay is the admin that
 *         designates that keeper. The Relay does not know it exists.
 * @dev    The two seats are split on purpose. The keeper moves the rewards but cannot pass its seat on, and the
 *         Relay's admin names the keeper but cannot compose a batch without first naming itself, in public, a
 *         timelock ahead. So the party that governs the Relay decides who moves its rewards, and rotating that party
 *         is two calls rather than a redeploy.
 * @dev    The delay is one-sided on purpose: filling the seat waits it out, emptying the seat is immediate. The
 *         delay guards a capability that already commands the balance, while emptying only removes one.
 */
contract RelayIcaModule is IRelayIcaModule {
  /// @notice Share of the bridged amount each leaf's warp route may keep as its fee, in pips.
  /// @dev Fixed rather than named per plan: `maxFee` is the only bound on what the route keeps, and the plan is
  ///      composed here precisely so the keeper names no destination and no ceiling.
  uint256 private constant _MAX_BRIDGE_FEE_PIPS = 10_000;

  /// @inheritdoc IRelayIcaModule
  IRelayEntrypoint public immutable RELAY;

  /// @inheritdoc IRelayIcaModule
  IMetarouter public immutable METAROUTER;

  /// @inheritdoc IRelayIcaModule
  IInterchainAccountRouter public immutable ICA_ROUTER;

  /// @inheritdoc IRelayIcaModule
  uint32 public immutable ROOT_DOMAIN;

  /// @inheritdoc IRelayIcaModule
  address public keeper;

  /// @inheritdoc IRelayIcaModule
  PendingKeeper public pendingKeeper;

  /// @inheritdoc IRelayIcaModule
  uint256 public planNonce;

  /// @notice The configuration each leaf's plans are built against.
  mapping(uint32 domain => LeafConfig config) internal _leafConfig;

  /// @notice The leaf configuration waiting out its delay, per domain.
  mapping(uint32 domain => PendingLeafConfig pending) internal _pendingLeafConfig;

  /// @notice Restrict to the seated keeper. An empty seat admits nobody: `msg.sender` is never the zero address.
  modifier onlyKeeper() {
    if (msg.sender != keeper) revert NotKeeper();
    _;
  }

  /// @notice Restrict to the served Relay's admin, read live off the Relay.
  modifier onlyRelayAdmin() {
    if (msg.sender != RELAY.owner()) revert NotRelayAdmin();
    _;
  }

  /// @notice Bind the Relay this module serves and the Metarouter its batches run through.
  /// @dev The interchain account router is read from the Metarouter rather than passed in: the two must agree for
  ///      the derived account to be the one the Metarouter's commands reach.
  /// @dev The keeper seat starts empty, so a fresh module can move nothing at all. The Relay's admin fills it with
  ///      `proposeKeeper` and `executeKeeper`, the same pair that rotates it later. The seat is left out of the
  ///      constructor to keep the deployed bytecode a function of the Relay alone, which is what makes the module's
  ///      address derivable before it exists.
  /// @param _relay Relay whose admin designates this module's keeper.
  /// @param _metarouter Metarouter every batch runs through.
  /// @param _rootDomain Hyperlane domain of the root chain, where every bridge leg lands.
  constructor(IRelayEntrypoint _relay, IMetarouter _metarouter, uint32 _rootDomain) {
    if (address(_relay) == address(0) || address(_metarouter) == address(0)) revert ZeroAddress();
    if (_rootDomain == 0) revert ZeroDomain();
    RELAY = _relay;
    METAROUTER = _metarouter;
    ROOT_DOMAIN = _rootDomain;

    IInterchainAccountRouter _icaRouter = _metarouter.ICA_ROUTER();
    if (address(_icaRouter) == address(0)) revert ZeroAddress();
    ICA_ROUTER = _icaRouter;
  }

  /// @notice Accept the native a batch refunds. `execute` spends only the value attached to it, so native sent here
  ///         ahead of one funds nothing; a batch's refund lands here, and only the keeper moves it.
  receive() external payable {}

  /// @inheritdoc IRelayIcaModule
  function proposeKeeper(address _keeper) external onlyRelayAdmin {
    // Zero is refused: emptying the seat is what `clearKeeper` is for, and accepting it here would give the same
    // outcome a delay it does not need.
    if (_keeper == address(0)) revert ZeroAddress();

    pendingKeeper = PendingKeeper({keeper: _keeper, proposedAt: uint48(block.timestamp)});
    // The Relay's delay is read only once the candidate has passed, so a refused argument never pays for the call.
    emit KeeperProposed(_keeper, block.timestamp + _timelock());
  }

  /// @inheritdoc IRelayIcaModule
  function executeKeeper() external onlyRelayAdmin {
    PendingKeeper memory _proposal = pendingKeeper;
    if (_proposal.keeper == address(0)) revert KeeperNotProposed();
    // Same as above: an absent proposal is rejected without touching the Relay.
    if (block.timestamp < uint256(_proposal.proposedAt) + _timelock()) revert KeeperTimelockNotElapsed();

    delete pendingKeeper;
    address _previousKeeper = keeper;
    keeper = _proposal.keeper;
    emit KeeperSet(_previousKeeper, _proposal.keeper);
  }

  /// @inheritdoc IRelayIcaModule
  function clearKeeper() external onlyRelayAdmin {
    // The two halves are separate state and are announced separately: dropping a proposal that never took the seat
    // is not the seat changing hands, and a clear that moved nothing writes nothing and emits nothing.
    address _proposed = pendingKeeper.keeper;
    if (_proposed != address(0)) {
      delete pendingKeeper;
      emit KeeperProposalDropped(_proposed);
    }

    address _seated = keeper;
    if (_seated != address(0)) {
      delete keeper;
      emit KeeperSet(_seated, address(0));
    }
  }

  /// @inheritdoc IRelayIcaModule
  function proposeLeafConfig(uint32 _domain, LeafConfig calldata _config) external onlyRelayAdmin {
    if (_domain == 0) revert ZeroDomain();
    if (_config.metarouter == address(0) || _config.outToken == address(0) || _config.bridge == address(0)) {
      revert ZeroAddress();
    }

    _pendingLeafConfig[_domain] = PendingLeafConfig({config: _config, proposedAt: uint48(block.timestamp)});
    emit LeafConfigProposed(_domain, _config, block.timestamp + _timelock());
  }

  /// @inheritdoc IRelayIcaModule
  function executeLeafConfig(uint32 _domain) external onlyRelayAdmin {
    PendingLeafConfig memory _proposal = _pendingLeafConfig[_domain];
    if (_proposal.config.metarouter == address(0)) revert LeafConfigNotProposed();
    if (block.timestamp < uint256(_proposal.proposedAt) + _timelock()) revert LeafConfigTimelockNotElapsed();

    delete _pendingLeafConfig[_domain];
    _leafConfig[_domain] = _proposal.config;
    emit LeafConfigSet(_domain, _proposal.config);
  }

  /// @inheritdoc IRelayIcaModule
  function clearLeafConfig(uint32 _domain) external onlyRelayAdmin {
    // The two halves are separate state and are announced separately, the same way the keeper seat is: dropping a
    // proposal that never took effect is not the configuration changing, and a clear that changed nothing is silent.
    if (_pendingLeafConfig[_domain].config.metarouter != address(0)) {
      delete _pendingLeafConfig[_domain];
      emit LeafConfigProposalDropped(_domain);
    }

    if (_leafConfig[_domain].metarouter != address(0)) {
      delete _leafConfig[_domain];
      emit LeafConfigSet(_domain, LeafConfig({metarouter: address(0), outToken: address(0), bridge: address(0)}));
    }
  }

  /// @inheritdoc IRelayIcaModule
  function dispatchPlan(PlanParams calldata _params) external payable onlyKeeper {
    LeafConfig memory _config = _leafConfig[_params.domain];
    if (_config.metarouter == address(0)) revert LeafConfigMissing();
    if (_params.legs.length == 0 && !_params.sweepHeldOutToken) revert NoSwapLegs();

    bytes memory _calls = abi.encode(_buildPlan(_params, _config));
    bytes32 _salt = keccak256(abi.encode(address(this), ++planNonce));
    bytes32 _commitment = _commitmentFor(_salt, _calls);

    _dispatchCommitment(_params, _commitment);
    emit PlanDispatched(msg.sender, _params.domain, _salt, _commitment, _calls);
  }

  /// @inheritdoc IRelayIcaModule
  function sweepNative(address _to) external onlyKeeper {
    RelayModuleLib.sweepNative(_to);
  }

  /// @inheritdoc IRelayIcaModule
  function sweepToken(address _token, address _to) external onlyKeeper {
    RelayModuleLib.sweepToken(_token, _to);
  }

  /// @inheritdoc IRelayIcaModule
  function interchainAccount(uint32 _domain) external view returns (address _account) {
    _account = ICA_ROUTER.getRemoteInterchainAccount(_domain, address(METAROUTER), _salt());
  }

  /// @inheritdoc IRelayIcaModule
  function interchainAccount(address _router, address _ism) external view returns (address _account) {
    if (_router == address(0)) revert ZeroAddress();
    _account = ICA_ROUTER.getRemoteInterchainAccount(address(METAROUTER), _router, _ism, _salt());
  }

  /// @inheritdoc IRelayIcaModule
  function leafConfig(uint32 _domain) external view returns (address _metarouter, address _outToken, address _bridge) {
    LeafConfig memory _config = _leafConfig[_domain];
    return (_config.metarouter, _config.outToken, _config.bridge);
  }

  /// @inheritdoc IRelayIcaModule
  function pendingLeafConfig(uint32 _domain) external view returns (LeafConfig memory _config, uint48 _proposedAt) {
    PendingLeafConfig memory _pending = _pendingLeafConfig[_domain];
    return (_pending.config, _pending.proposedAt);
  }

  /// @notice The delay a keeper proposal waits out, taken from the served Relay.
  /// @dev Read off `IRelay` rather than the entrypoint slice this module otherwise uses: the slice deliberately
  ///      leaves out the config struct, and hand-copying it here would be a duplicate with no compiler check.
  /// @return _delay The Relay's `entrypointTimelock`, which its own initialization refuses to leave at zero.
  function _timelock() internal view returns (uint256 _delay) {
    _delay = IRelay(address(RELAY)).relayConfig().entrypointTimelock;
  }

  /// @notice The salt the Metarouter passes to the interchain account router, which is its own caller.
  /// @return _userSalt This module's address, left-padded.
  function _salt() internal view returns (bytes32 _userSalt) {
    _userSalt = bytes32(uint256(uint160(address(this))));
  }

  /// @notice Dispatches the commitment to the account, through this module's own Metarouter.
  /// @dev The Metarouter passes its caller as the account salt, which is this module, so the commitment arms the
  ///      account this module advertises and no other.
  /// @param _params The plan.
  /// @param _commitment Commitment the destination will match the reveal against.
  function _dispatchCommitment(PlanParams calldata _params, bytes32 _commitment) private {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.ExecuteCrosschainParams({
        domain: _params.domain,
        commitment: _commitment,
        messageFee: _params.messageFee,
        // Native fees: the ERC20 fee flow needs a router version this module does not assume.
        tokenFee: 0,
        hook: address(0),
        hookMetadata: _params.hookMetadata,
        icaConfig: IMetarouter.IcaConfig({router: address(0), ism: address(0)})
      })
    );

    METAROUTER.execute{value: msg.value}(_commands, _inputs, block.timestamp);
  }

  /// @notice Writes the calls the interchain account runs on the leaf.
  /// @dev One approval per token sold, then a single Metarouter batch. Each sale is funded by the account itself
  ///      (`payerIsUser`), which is why the token needs an approval, and pays its output to the leaf's Metarouter,
  ///      which tracks it. The last command bridges the whole tracked balance of the output token, so the plan
  ///      never has to know what the sales produced.
  /// @dev A sweep adds a funding command ahead of the bridge, so the output token the account already holds is
  ///      bridged with the sales' output. Its amount resolves on the leaf, against the account's own balance,
  ///      which is why the allowance around it is unlimited and revoked by the call after the batch.
  /// @param _params The plan.
  /// @param _config Configuration the leaf's plans are built against.
  /// @return _calls The calls, in order.
  function _buildPlan(
    PlanParams calldata _params,
    LeafConfig memory _config
  ) private view returns (RemoteCall[] memory _calls) {
    // Composed first: it is what vets the sales, so a malformed one reverts before anything else is built.
    (bytes memory _commands, bytes[] memory _inputs) = _buildBatch(_params, _config);
    RemoteCall[] memory _approvals = _buildApprovals(_params, _config.metarouter);

    bool _sweep = _params.sweepHeldOutToken;
    uint256 _count = _approvals.length;
    uint256 _batchIndex = _sweep ? _count + 1 : _count;
    _calls = new RemoteCall[](_sweep ? _count + 3 : _count + 1);

    for (uint256 _i; _i < _count; ++_i) {
      _calls[_i] = _approvals[_i];
    }

    if (_sweep) {
      _calls[_count] = RemoteCall({
        to: _toWord(_config.outToken),
        value: 0,
        data: abi.encodeCall(IERC20.approve, (_config.metarouter, type(uint256).max))
      });
      _calls[_batchIndex + 1] = RemoteCall({
        to: _toWord(_config.outToken), value: 0, data: abi.encodeCall(IERC20.approve, (_config.metarouter, 0))
      });
    }

    _calls[_batchIndex] = RemoteCall({
      to: _toWord(_config.metarouter),
      // The account's own native on the leaf pays the bridge dispatch.
      value: _params.leafMessageFee,
      data: abi.encodeCall(IMetarouter.execute, (_commands, _inputs, _params.leafDeadline))
    });
  }

  /// @notice Writes the Metarouter batch the plan's single batch call carries.
  /// @dev This is where the sales are vetted, so it runs before the rest of the plan is composed.
  /// @dev A route that ends somewhere other than the output token cannot misdirect value: the output stays with the
  ///      Metarouter, the bridge leg finds nothing to spend and the batch reverts, and the leaf's closure returns
  ///      the tracked balance to the account. Root cannot check the route, since the pools are leaf addresses.
  /// @param _params The plan.
  /// @param _config Configuration the leaf's plans are built against.
  /// @return _commands The batch's commands, in order.
  /// @return _inputs The input of each command.
  function _buildBatch(
    PlanParams calldata _params,
    LeafConfig memory _config
  ) private view returns (bytes memory _commands, bytes[] memory _inputs) {
    uint256 _legs = _params.legs.length;
    uint256 _bridgeIndex = _params.sweepHeldOutToken ? _legs + 1 : _legs;

    _commands = new bytes(_bridgeIndex + 1);
    _inputs = new bytes[](_bridgeIndex + 1);

    for (uint256 _i; _i < _legs; ++_i) {
      SwapLeg calldata _leg = _params.legs[_i];
      if (_leg.amountIn == 0) revert ZeroAmountIn();
      if (_leg.minAmountOut == 0) revert ZeroMinOut();
      if (_leg.pools.length == 0) revert EmptyRoute();
      // Selling the output token is what the bridge leg already does with the whole balance.
      if (_leg.tokenIn == _config.outToken) revert SameToken();

      _commands[_i] =
        bytes1(uint8(_leg.family == PoolFamily.CL ? Commands.CL_SWAP_EXACT_IN : Commands.V2_SWAP_EXACT_IN));
      _inputs[_i] = abi.encode(
        IMetarouter.SwapExactInParams({
          pools: _leg.pools,
          tokenIn: _leg.tokenIn,
          amountIn: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _leg.amountIn}),
          payerIsUser: true,
          minAmountOut: _leg.minAmountOut,
          recipient: _config.metarouter
        })
      );
    }

    if (_bridgeIndex != _legs) {
      // Pips against the account's own balance: root cannot know what a reward paid in the output token left there.
      _commands[_legs] = bytes1(uint8(Commands.FUND_ERC20));
      _inputs[_legs] =
        abi.encode(_config.outToken, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}));
    }

    _commands[_bridgeIndex] = bytes1(uint8(Commands.BRIDGE_TOKEN));
    _inputs[_bridgeIndex] = abi.encode(
      IMetarouter.BridgeTokenParams({
        token: _config.outToken,
        bridge: _config.bridge,
        // The whole tracked balance: the sales' output is not knowable from root.
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
        messageFee: _params.leafMessageFee,
        maxFee: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _MAX_BRIDGE_FEE_PIPS}),
        domain: ROOT_DOMAIN,
        recipient: address(RELAY),
        // A named recipient never derives an interchain account, so the config stays empty.
        icaConfig: IMetarouter.IcaConfig({router: address(0), ism: address(0)})
      })
    );
  }

  /// @notice Writes one approval per token the plan sells.
  /// @dev The approvals are separate calls, so all of them land before the batch runs. A token two sales share
  ///      therefore gets one approval for their total: an approval per sale would leave the last one's amount,
  ///      not the sum, and the batch would revert once the sales together asked for more than that.
  /// @param _params The plan.
  /// @param _metarouter Metarouter the approvals name as the spender.
  /// @return _calls One approval per token sold.
  function _buildApprovals(
    PlanParams calldata _params,
    address _metarouter
  ) private pure returns (RemoteCall[] memory _calls) {
    uint256 _legs = _params.legs.length;
    address[] memory _tokens = new address[](_legs);
    uint256[] memory _amounts = new uint256[](_legs);
    uint256 _count = 0;

    for (uint256 _i; _i < _legs; ++_i) {
      address _tokenIn = _params.legs[_i].tokenIn;

      uint256 _slot = _count;
      for (uint256 _j; _j < _count; ++_j) {
        if (_tokens[_j] == _tokenIn) {
          _slot = _j;
          break;
        }
      }
      if (_slot == _count) {
        _tokens[_count] = _tokenIn;
        ++_count;
      }
      _amounts[_slot] += _params.legs[_i].amountIn;
    }

    _calls = new RemoteCall[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _calls[_i] = RemoteCall({
        to: _toWord(_tokens[_i]), value: 0, data: abi.encodeCall(IERC20.approve, (_metarouter, _amounts[_i]))
      });
    }
  }

  /// @notice The commitment the destination account matches a reveal against.
  /// @dev Hyperlane's own formula, from `OwnableMulticall.revealAndExecute`: the salt blinds the calls, and the
  ///      destination recomputes this hash over the revealed array. Computing it here is what pins the plan, and it
  ///      also binds this module to that formula: a router whose formula differs would never match a commitment
  ///      from here, and the only fix is to redeploy the module, which moves its address and the interchain
  ///      account with it, so whatever sits in the old account has to be moved out first.
  /// @param _salt Blinding value.
  /// @param _calls ABI-encoded `RemoteCall[]`.
  /// @return _commitment The commitment.
  function _commitmentFor(bytes32 _salt, bytes memory _calls) private pure returns (bytes32 _commitment) {
    _commitment = keccak256(abi.encodePacked(_salt, _calls));
  }

  /// @notice Left-pads an address into the word Hyperlane's call target is.
  /// @param _value Address to pad.
  /// @return _word The padded word.
  function _toWord(address _value) private pure returns (bytes32 _word) {
    _word = bytes32(uint256(uint160(_value)));
  }
}
