// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';

import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/**
 * @title  BaseEntrypointHarness
 * @notice Concrete BaseEntrypoint for unit tests: surfaces the internal `_pullSwapAndValidate`
 *         skeleton so its keeper gate, pull/approve/execute sequence and delta check can be asserted
 *         directly. Adds no state.
 */
contract BaseEntrypointHarness is BaseEntrypoint {
  /// @notice Bind the factory registry; see BaseEntrypoint.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  constructor(IFactoryRegistry _factoryRegistry) BaseEntrypoint(_factoryRegistry) {}

  /// @notice Expose the shared pull-swap-validate skeleton.
  /// @param _params Keeper-supplied swap request.
  /// @param _tokenOut Token whose entrypoint balance delta is the swap output.
  /// @return _delta Output measured here and forwarded to the Relay.
  function pullSwapAndValidate(SwapParams calldata _params, address _tokenOut) external returns (uint256 _delta) {
    _delta = _pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice Expose the shared keeper gate every path runs.
  /// @param _relay Relay whose role set decides who the keeper is.
  function requireKeeper(address _relay) external view {
    _requireKeeper(_relay);
  }

  /// @notice Expose the unaccounted-balance read the idle paths run.
  /// @param _relay Relay holding the balance.
  /// @param _token Token to measure.
  /// @return _amount The Relay's unaccounted balance of `_token`.
  function requireIdleBalance(address _relay, address _token) external view returns (uint256 _amount) {
    _amount = _requireIdleBalance(_relay, _token);
  }
}
