// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Root Voting Rewards Factory Interface
 * @notice Minimal interface used to configure cross-chain reward recipients
 */
interface IV2RootVotingRewardsFactory {
  /**
   * @notice Sets the reward recipient for the caller on a leaf chain
   * @param _chainId Identifier of the leaf chain
   * @param _recipient Address that receives rewards on the leaf chain
   */
  function setRecipient(uint256 _chainId, address _recipient) external;
}
