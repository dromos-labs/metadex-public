// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IMultiConverter} from 'V3/interfaces/relay/entrypoints/IMultiConverter.sol';

import {MultiEntrypoint} from 'V3/relay/entrypoints/MultiEntrypoint.sol';

/**
 * @title  MultiConverter
 * @notice Converter entrypoint bound to one Relay; it holds the CONVERTER role on that Relay. It
 *         keeps two mutable sets: allowed target tokens and excluded input tokens. Only the bound
 *         Relay's owner can change these sets. On each call, the keeper
 *         picks one configured target token and converts a reward into it. Used with Protocol L2
 *         Relays only.
 */
contract MultiConverter is MultiEntrypoint, IMultiConverter {
  /// @notice Bind the factory registry and the Relay, then set the initial target and excluded token sets.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay Relay this Converter serves; its owner gates the config.
  /// @param _initialTargets Target tokens allowed for conversion, set at deployment.
  /// @param _initialExcluded Input tokens to exclude at deploy.
  constructor(
    IFactoryRegistry _factoryRegistry,
    IRelayEntrypoint _relay,
    address[] memory _initialTargets,
    address[] memory _initialExcluded
  ) MultiEntrypoint(_factoryRegistry, _relay, _initialTargets, _initialExcluded) {}

  /// @inheritdoc IMultiConverter
  function swapAndConvert(SwapParams calldata _params, address _targetToken) external nonReentrant {
    _requireBoundRelay(_params.relay);
    _requireConvertible(_params.tokenIn, _targetToken);
    uint256 _delta = _pullSwapAndValidate(_params, _targetToken);
    IRelayEntrypoint(_params.relay).notifyReward(_targetToken, _delta);
  }

  /// @inheritdoc IMultiConverter
  /// @dev Without this a reward the Relay collects directly in a target token could never be
  ///      distributed, since the swap path refuses `tokenIn == targetToken`.
  function convertIdleBalance(address _relay, address _targetToken) external nonReentrant {
    _requireBoundRelay(_relay);
    _requireTarget(_targetToken);
    _convertIdleBalance(_relay, _targetToken);
  }
}
