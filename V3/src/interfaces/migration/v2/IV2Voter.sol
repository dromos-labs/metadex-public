// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Voter Interface
 * @notice Minimal V2 Voter interface used by Migration
 */
interface IV2Voter {
  /**
   * @notice Called by users to vote for pools. Votes distributed proportionally based on weights.
   *         Can only vote or deposit into a managed NFT once per epoch.
   *         Can only vote for gauges that have not been killed.
   * @dev Weights are distributed proportional to the sum of the weights in the array.
   *      Throws if length of _poolVote and _weights do not match.
   * @param _tokenId Id of veNFT you are voting with.
   * @param _poolVote Array of pools you are voting for.
   * @param _weights Weights of pools.
   */
  function vote(uint256 _tokenId, address[] calldata _poolVote, uint256[] calldata _weights) external;

  /**
   * @notice Called by users to reset voting state. Required if you wish to make changes to
   *         veNFT state (e.g. merge, split, deposit into managed etc).
   *         Cannot reset in the same epoch that you voted in.
   *         Can vote or deposit into a managed NFT again after reset.
   * @param _tokenId Id of veNFT you are reseting.
   */
  function reset(uint256 _tokenId) external;

  /**
   * @notice Claim fees for a given NFT.
   * @dev Utility to help batch fee claims.
   * @param _fees Array of FeesVotingReward contracts to collect from.
   * @param _tokens Array of tokens that are used as fees.
   * @param _tokenId Id of veNFT that you wish to claim fees for.
   */
  function claimFees(address[] memory _fees, address[][] memory _tokens, uint256 _tokenId) external;

  /**
   * @notice Claim bribes for a given NFT.
   * @dev Utility to help batch bribe claims.
   * @param _bribes Array of BribeVotingReward contracts to collect from.
   * @param _tokens Array of tokens that are used as bribes.
   * @param _tokenId Id of veNFT that you wish to claim bribes for.
   */
  function claimBribes(address[] memory _bribes, address[][] memory _tokens, uint256 _tokenId) external;

  /**
   * @notice Kills a gauge. The gauge will not receive any new emissions and cannot be deposited into.
   *         Can still withdraw from gauge.
   * @dev Throws if not called by emergency council.
   *      Throws if gauge already killed.
   * @param _gauge .
   */
  function killGauge(address _gauge) external;

  /**
   * @notice Revives a killed gauge. Gauge will receive emissions and deposits again.
   * @dev Throws if not called by emergency council.
   *      Throws if gauge is not killed.
   * @param _gauge .
   */
  function reviveGauge(address _gauge) external;

  /**
   * @notice Address of Minter
   * @return Address of the Minter contract
   */
  function minter() external view returns (address);

  /**
   * @notice Returns the current emergency council.
   * @return _emergencyCouncil Address of the current emergency council.
   */
  function emergencyCouncil() external view returns (address _emergencyCouncil);
}
