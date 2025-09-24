// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';

/**
 * @title IGaugeCreationModule
 * @notice Universal surface of a GaugeManager creation module. Each module
 *         owns its target-class creation validation and activation policy, so
 *         only delayed activation and the manager reference are shared. The
 *         creation entrypoint shape is per-module and the GaugeManager
 *         authorizes registered caller addresses, never a creation signature.
 */
interface IGaugeCreationModule {
  /**
   * @notice Thrown when a zero address is invalid.
   */
  error ZeroAddress();

  /**
   * @notice Run this module's delayed-activation policy and activate the gauge
   *         through the GaugeManager.
   * @param _gauge The gauge to activate.
   */
  function activate(address _gauge) external;

  /**
   * @notice GaugeManager this module forwards lifecycle requests to.
   * @return _gaugeManager The GaugeManager.
   */
  function GAUGE_MANAGER() external view returns (IGaugeManager _gaugeManager);
}
