// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/**
 * @title  BaseEntrypoint (abstract)
 * @notice The shared flow every entrypoint runs: check the Relay, check KEEPER on the Relay, pull
 *         the input token, approve and run the MetaRouter swap (the output lands on this contract),
 *         validate the measured output against `minAmountOut`, forward it to the Relay, then
 *         compound the output or notify the Relay's idle target balance as a reward. Each concrete
 *         entrypoint picks the side to run and adds its own config guards.
 * @dev Bound to one Relay at deploy, so whatever this contract holds belongs to that Relay. The
 *      MetaRouter is untrusted, so the output is measured as the change in this contract's own
 *      balance. The MetaRouter returns every token it tracked here, so a route token other than
 *      `tokenIn` and the output can stay behind; `sweepToRelay` sends it back.
 */
abstract contract BaseEntrypoint is IBaseEntrypoint, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  /// @inheritdoc IBaseEntrypoint
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @inheritdoc IBaseEntrypoint
  IRelayEntrypoint public immutable RELAY;

  /// @notice Sets the router registry and the Relay this entrypoint serves.
  /// @dev The router is per call, not an immutable: governance can retire a router without
  ///      redeploying, which matters on Maxi/L1 where the entrypoint set is fixed at deploy. The
  ///      Relay may not exist yet: a Maxi or L1 Relay names its entrypoints at creation, so they
  ///      are deployed first against its predicted address.
  /// @param _factoryRegistry Factory registry address.
  /// @param _relay The only Relay this entrypoint serves.
  constructor(IFactoryRegistry _factoryRegistry, IRelayEntrypoint _relay) {
    if (address(_factoryRegistry) == address(0)) revert ZeroAddress();
    if (address(_relay) == address(0)) revert ZeroAddress();
    FACTORY_REGISTRY = _factoryRegistry;
    RELAY = _relay;
  }

  /// @inheritdoc IBaseEntrypoint
  function sweepToRelay(address[] calldata _tokens) external nonReentrant {
    _requireKeeper();
    for (uint256 _i; _i < _tokens.length; ++_i) {
      uint256 _amount = IERC20(_tokens[_i]).balanceOf(address(this));
      if (_amount == 0) continue;
      _tokens[_i].safeTransfer(address(RELAY), _amount);
      emit SweptToRelay(_tokens[_i], _amount);
    }
  }

  /// @notice Swaps `_params.tokenIn` into the Relay's TOKEN and compounds the output.
  /// @param _params Keeper-supplied swap request.
  function _swapAndCompound(SwapParams calldata _params) internal {
    _requireKeeper();
    uint256 _delta = _pullSwapAndValidate(_params, RELAY.TOKEN());
    RELAY.compound(_delta);
  }

  /// @notice Swaps `_params.tokenIn` into `_targetToken` and converts the Relay's idle balance of it
  ///         into a claimable reward.
  /// @dev A batch whose index delta still floors to zero reverts with `RewardTooSmall`.
  /// @param _params Keeper-supplied swap request.
  /// @param _targetToken Reward token the swap outputs and the Relay distributes.
  function _swapAndConvert(SwapParams calldata _params, address _targetToken) internal {
    _requireKeeper();
    _pullSwapAndValidate(_params, _targetToken);
    RELAY.notifyReward(_targetToken, _requireIdleBalance(_targetToken));
  }

  // The balance-before/after read pair is the point of this function: the delta is the swap output.
  // slither-disable-start reentrancy-balance
  /// @notice Pulls the input token, runs the swap and forwards the validated output to the Relay.
  /// @dev Reads this contract's `_tokenOut` balance before and after `execute`; the difference is
  ///      the output, since the MetaRouter is told to route it here. A fee-on-transfer `_tokenOut`
  ///      would deliver the Relay less than the forwarded `_delta`; reward tokens are
  ///      governance-vetted, which excludes those. `safeApproveWithRetry` tolerates tokens that
  ///      revert on a non-zero-to-non-zero approve (forceApprove semantics).
  /// @param _params Keeper-supplied swap request.
  /// @param _tokenOut The token to measure on this contract: its balance increase is the swap
  ///        output (TOKEN for compound, the target token for convert).
  /// @return _delta Output amount measured here and forwarded to the Relay (>= minAmountOut).
  function _pullSwapAndValidate(SwapParams calldata _params, address _tokenOut) internal returns (uint256 _delta) {
    if (_params.minAmountOut == 0) revert ZeroMinOut();
    // The keeper names the router, but only governance decides which ones are usable.
    if (!FACTORY_REGISTRY.isMetaRouterApproved(_params.router)) revert RouterNotApproved();
    // A same-token pull would distort the balance-delta measurement below; a balance that already
    // arrives in the right token goes through the idle-balance path instead.
    if (_params.tokenIn == _tokenOut) revert SameToken();

    uint256 _balanceBefore = IERC20(_tokenOut).balanceOf(address(this));

    // The MetaRouter sends the output to this contract; the recipient is encoded in `commands`.
    RELAY.pull(_params.tokenIn, _params.amountIn);
    _params.tokenIn.safeApproveWithRetry(_params.router, _params.amountIn);
    IMetarouter(_params.router).execute(_params.commands, _params.inputs, _params.deadline);
    // The untrusted router must not keep any leftover approval.
    _params.tokenIn.safeApproveWithRetry(_params.router, 0);

    // Trust the measured balance, not the router's return, then forward the output to the Relay.
    _delta = IERC20(_tokenOut).balanceOf(address(this)) - _balanceBefore;
    if (_delta < _params.minAmountOut) revert InsufficientOutput();
    _tokenOut.safeTransfer(address(RELAY), _delta);

    // Return the input the router did not spend, read by balance so a fee-on-transfer input cannot overstate it.
    uint256 _leftover = IERC20(_params.tokenIn).balanceOf(address(this));
    if (_leftover != 0) _params.tokenIn.safeTransfer(address(RELAY), _leftover);

    emit Swapped(
      address(RELAY), _params.router, _params.tokenIn, _params.amountIn, _tokenOut, _params.minAmountOut, _delta
    );
  }

  // slither-disable-end reentrancy-balance

  /// @notice Compounds the Relay's idle TOKEN balance: keeper gate, measure, compound.
  /// @dev The shared tail of every `compoundIdleBalance`.
  function _compoundIdleBalance() internal {
    _requireKeeper();
    RELAY.compound(_requireIdleBalance(RELAY.TOKEN()));
  }

  /// @notice Converts the Relay's idle `_targetToken` balance into a claimable reward.
  /// @dev The shared tail of every `convertIdleBalance`; the Multi variants check the allowed
  ///      target before calling in.
  /// @param _targetToken Reward token to measure and notify.
  function _convertIdleBalance(address _targetToken) internal {
    _requireKeeper();
    RELAY.notifyReward(_targetToken, _requireIdleBalance(_targetToken));
  }

  /// @notice Gates the caller on the Relay's KEEPER role.
  function _requireKeeper() internal view {
    if (!RELAY.hasAnyRole(msg.sender, RELAY.KEEPER())) revert NotKeeper();
  }

  /// @notice Measures what the Relay can still spend of `_token`, refusing an empty result.
  /// @param _token Token to measure.
  /// @return _amount The Relay's unaccounted balance of `_token`.
  /// @dev `balanceOf - accountedBalance` is the same bound `pull`, `compound` and `notifyReward`
  ///      draw against; the whole balance would include amounts already owed to claimants and the rake.
  function _requireIdleBalance(address _token) internal view returns (uint256 _amount) {
    _amount = IERC20(_token).balanceOf(address(RELAY)) - RELAY.accountedBalance(_token);
    if (_amount == 0) revert NoIdleBalance();
  }
}
