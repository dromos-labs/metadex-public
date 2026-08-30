// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Minter Interface
 * @notice Minimal V2 Minter interface used by Migration
 */
interface IV2Minter {
  /**
   * @notice Allows epoch governor to modify the tail emission rate by at most 1 basis point
   *         per epoch to a maximum of 100 basis points or to a minimum of 1 basis point.
   *         Note: the very first nudge proposal must take place the week prior
   *         to the tail emission schedule starting.
   * @dev Throws if not epoch governor.
   *      Throws if not currently in tail emission schedule.
   *      Throws if already nudged this epoch.
   *      Throws if nudging above maximum rate.
   *      Throws if nudging below minimum rate.
   *      This contract is coupled to EpochGovernor as it requires three option simple majority voting.
   */
  function nudge() external;

  /**
   * @notice Returns the current tail emission rate in basis points
   * @return The current tail emission rate
   */
  function tailEmissionRate() external view returns (uint256);
}
