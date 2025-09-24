// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Root Voting Reward Interface
 * @notice Minimal interface used to identify cross-chain v2 reward contracts
 */
interface IV2RootVotingReward {
  /**
   * @notice Returns the chain where rewards are paid
   * @return The reward chain identifier
   */
  function chainid() external view returns (uint256);
}
