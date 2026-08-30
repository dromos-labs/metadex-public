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
 * @notice The shared flow every entrypoint runs: check KEEPER on the Relay, pull the input token,
 *         approve and run the MetaRouter swap (the output lands on this contract), check the
 *         measured output against `minAmountOut`, then forward it to the Relay. Each concrete
 *         entrypoint adds only the final step (compound vs notify) on top of `_pullSwapAndValidate`.
 * @dev Stateless and Relay-agnostic: holds no per-Relay state, so one deployment can serve many
 *      Relays. The MetaRouter is untrusted, so output is measured on this contract's own balance,
 *      which no protocol flow ever credits.
 */
abstract contract BaseEntrypoint is IBaseEntrypoint, ReentrancyGuardTransient {
  using SafeTransferLib for address;

  /// @inheritdoc IBaseEntrypoint
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @notice Sets the registry that decides which routers a swap may run on.
  /// @param _factoryRegistry Factory registry address.
  /// @dev The router is per call, not an immutable: governance can retire a router without
  ///      redeploying, which matters on Maxi/L1 where the entrypoint set is fixed at deploy.
  constructor(IFactoryRegistry _factoryRegistry) {
    if (address(_factoryRegistry) == address(0)) revert ZeroAddress();
    FACTORY_REGISTRY = _factoryRegistry;
  }

  // The balance-before/after read pair is the point of this function: the delta is the swap
  // output. The reads are on this contract's own balance, which no protocol flow credits.
  // slither-disable-start reentrancy-balance
  /// @notice Run the common flow and return how much `_tokenOut` the swap delivered to the Relay.
  /// @param _params Keeper-supplied swap request.
  /// @param _tokenOut The token to measure on this contract: its balance increase is the swap
  ///        output (TOKEN for compound, the target token for convert).
  /// @return _delta Output amount measured here and forwarded to the Relay (>= minAmountOut).
  /// @dev Reads this contract's `_tokenOut` balance before and after `execute`; the difference is
  ///      the output, since the MetaRouter is told to route it here. A fee-on-transfer `_tokenOut`
  ///      would deliver the Relay less than the forwarded `_delta`; reward tokens are
  ///      governance-vetted, which excludes those. `safeApproveWithRetry` tolerates tokens that
  ///      revert on a non-zero-to-non-zero approve (forceApprove semantics).
  function _pullSwapAndValidate(SwapParams calldata _params, address _tokenOut) internal returns (uint256 _delta) {
    _requireKeeper(_params.relay);
    if (_params.minAmountOut == 0) revert ZeroMinOut();
    // The keeper names the router, but only governance decides which ones are usable.
    if (!FACTORY_REGISTRY.isMetaRouterApproved(_params.router)) revert RouterNotApproved();
    // A same-token pull would distort the balance-delta measurement below; a balance that already
    // arrives in the right token goes through the idle-balance path instead.
    if (_params.tokenIn == _tokenOut) revert SameToken();

    uint256 _balanceBefore = IERC20(_tokenOut).balanceOf(address(this));

    // The MetaRouter sends the output to this contract; the recipient is encoded in `commands`.
    IRelayEntrypoint(_params.relay).pull(_params.tokenIn, _params.amountIn);
    _params.tokenIn.safeApproveWithRetry(_params.router, _params.amountIn);
    IMetarouter(_params.router).execute(_params.commands, _params.inputs, _params.deadline);
    // The untrusted router must not keep any leftover approval.
    _params.tokenIn.safeApproveWithRetry(_params.router, 0);

    // Trust the measured balance, not the router's return, then forward the output to the Relay.
    _delta = IERC20(_tokenOut).balanceOf(address(this)) - _balanceBefore;
    if (_delta < _params.minAmountOut) revert InsufficientOutput();
    _tokenOut.safeTransfer(_params.relay, _delta);

    // Return the input the router did not spend, read by balance so a fee-on-transfer input cannot overstate it.
    uint256 _leftover = IERC20(_params.tokenIn).balanceOf(address(this));
    if (_leftover != 0) _params.tokenIn.safeTransfer(_params.relay, _leftover);
  }

  // slither-disable-end reentrancy-balance

  /// @notice Compounds the Relay's idle TOKEN balance: keeper gate, measure, compound.
  /// @param _relay Relay whose idle balance is compounded.
  /// @dev The shared tail of every `compoundIdleBalance`; concrete entrypoints run their own
  ///      guards (bound relay) before calling in.
  function _compoundIdleBalance(address _relay) internal {
    _requireKeeper(_relay);
    address _token = IRelayEntrypoint(_relay).TOKEN();
    uint256 _amount = _requireIdleBalance(_relay, _token);
    IRelayEntrypoint(_relay).compound(_amount);
  }

  /// @notice Converts the Relay's idle `_targetToken` balance into a claimable reward.
  /// @param _relay Relay whose idle balance is distributed.
  /// @param _targetToken Reward token to measure and notify.
  /// @dev The shared tail of every `convertIdleBalance`; concrete entrypoints run their own
  ///      guards (bound relay, allowed target) before calling in.
  function _convertIdleBalance(address _relay, address _targetToken) internal {
    _requireKeeper(_relay);
    uint256 _amount = _requireIdleBalance(_relay, _targetToken);
    IRelayEntrypoint(_relay).notifyReward(_targetToken, _amount);
  }

  /// @notice Gates the caller on the Relay's KEEPER role.
  /// @param _relay Relay whose role set decides who the keeper is.
  function _requireKeeper(address _relay) internal view {
    IRelayEntrypoint _relayContract = IRelayEntrypoint(_relay);
    if (!_relayContract.hasAnyRole(msg.sender, _relayContract.KEEPER())) revert NotKeeper();
  }

  /// @notice Measures what the Relay can still spend of `_token`, refusing an empty result.
  /// @param _relay Relay holding the balance.
  /// @param _token Token to measure.
  /// @return _amount The Relay's unaccounted balance of `_token`.
  /// @dev `balanceOf - accountedBalance` is the same bound `pull`, `compound` and `notifyReward`
  ///      draw against; the whole balance would include amounts already owed to claimants.
  function _requireIdleBalance(address _relay, address _token) internal view returns (uint256 _amount) {
    _amount = IERC20(_token).balanceOf(_relay) - IRelayEntrypoint(_relay).accountedBalance(_token);
    if (_amount == 0) revert NoIdleBalance();
  }
}
