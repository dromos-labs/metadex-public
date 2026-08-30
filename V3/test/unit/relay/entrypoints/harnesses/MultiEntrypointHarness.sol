// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';

import {MultiEntrypoint} from 'V3/relay/entrypoints/MultiEntrypoint.sol';

/**
 * @title  MultiEntrypointHarness
 * @notice Concrete MultiEntrypoint for unit tests (the base is abstract): it adds no swap functions of
 *         its own and surfaces the internal swap-guard helpers so their revert logic can be asserted
 *         directly. The config surface (setters/views) and the constructor are tested on this harness
 *         as the plain base.
 */
contract MultiEntrypointHarness is MultiEntrypoint {
  /// @notice Forward the MetaRouter, Relay and initial sets to MultiEntrypoint.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay Bound Relay.
  /// @param _initialTargets Convert target tokens to allow at deploy.
  /// @param _initialExcluded Input tokens to exclude at deploy.
  constructor(
    IFactoryRegistry _factoryRegistry,
    IRelayEntrypoint _relay,
    address[] memory _initialTargets,
    address[] memory _initialExcluded
  ) MultiEntrypoint(_factoryRegistry, _relay, _initialTargets, _initialExcluded) {}

  /// @notice Expose the bound-relay guard.
  /// @param _relay Relay the swap addresses.
  function requireBoundRelay(address _relay) external view {
    _requireBoundRelay(_relay);
  }

  /// @notice Expose the convertible-pair guard.
  /// @param _tokenIn Reward token being swapped.
  /// @param _targetToken Chosen convert target.
  function requireConvertible(address _tokenIn, address _targetToken) external view {
    _requireConvertible(_tokenIn, _targetToken);
  }

  /// @notice Expose the not-excluded guard.
  /// @param _tokenIn Reward token being swapped.
  function requireNotExcluded(address _tokenIn) external view {
    _requireNotExcluded(_tokenIn);
  }
}
