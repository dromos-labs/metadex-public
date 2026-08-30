// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Emergency Council Interface
 * @notice Minimal interface for managing Velodrome v2 gauges
 */
interface IV2EmergencyCouncil {
  /**
   * @notice Kills a root gauge
   * @param _gauge Address of the root gauge to kill
   */
  function killRootGauge(address _gauge) external;

  /**
   * @notice Kills a leaf gauge and dispatches the corresponding leaf-chain message
   * @param _gauge Address of the root gauge linked to the leaf gauge to kill
   */
  function killLeafGauge(address _gauge) external;

  /**
   * @notice Revives a root gauge
   * @param _gauge Address of the root gauge to revive
   */
  function reviveRootGauge(address _gauge) external;

  /**
   * @notice Revives a leaf gauge and dispatches the corresponding leaf-chain message
   * @param _gauge Address of the root gauge linked to the leaf gauge to revive
   */
  function reviveLeafGauge(address _gauge) external;

  /**
   * @notice Transfers ownership of the emergency council
   * @param _newOwner Address of the new emergency council owner
   */
  function transferOwnership(address _newOwner) external;

  /**
   * @notice Returns the owner of the emergency council
   * @return _owner Address of the emergency council owner
   */
  function owner() external view returns (address _owner);
}
