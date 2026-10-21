// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IArbSys {
  /**
   * @notice Returns the current Arbitrum L2 block number
   * @return The current Arbitrum L2 block number
   */
  function arbBlockNumber() external view returns (uint256);
}
