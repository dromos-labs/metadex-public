// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IVotingCheckpoints
 * @notice Interface for all VotingCheckpoints implementations
 */
interface IVotingCheckpoints {
  /**
   * @notice Reward voting power checkpoint for a veNFT at a timestamp
   * @param bias Decaying voting power at the checkpoint timestamp
   * @param slope Rate at which decaying voting power decreases over time
   * @param ts Timestamp when the checkpoint was recorded
   * @param permanent Permanent voting power at the checkpoint timestamp
   */
  struct UserPoint {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanent;
  }

  /**
   * @notice Aggregate reward voting power checkpoint at a timestamp
   * @param bias Decaying voting power at the checkpoint timestamp
   * @param slope Rate at which decaying voting power decreases over time
   * @param ts Timestamp when the checkpoint was recorded
   * @param permanentStakeBalance Total permanent voting power at the checkpoint timestamp
   * @param zeroSupplySeconds Cumulative seconds where reward voting supply was zero before this checkpoint
   */
  struct GlobalPoint {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanentStakeBalance;
    uint48 zeroSupplySeconds;
  }

  /**
   * @notice Emitted when a veNFT's voting weight allocation is updated
   * @param _from The address that triggered the checkpoint
   * @param _tokenId The veNFT's token ID
   * @param _weight The veNFT's updated voting weight allocation
   */
  event Checkpoint(address indexed _from, uint256 indexed _tokenId, uint256 _weight);

  /**
   * @notice Emitted when a veNFT's voting weight allocation is reset to zero
   * @param _from The address that triggered the reset
   * @param _tokenId The veNFT's token ID
   */
  event Reset(address indexed _from, uint256 indexed _tokenId);

  /**
   * @notice Returns the maximum number of week-boundary iterations per checkpoint call
   * @return The maximum checkpoint iteration count
   */
  function MAX_CHECKPOINT_ITERATIONS() external view returns (uint256);

  /**
   * @notice Origin timestamp the time-weighted accumulators are measured against
   * @return The accumulator origin timestamp
   */
  function ACCUMULATOR_ORIGIN() external view returns (uint256);

  /**
   * @notice Returns the total permanent stake balance deposited in the contract
   * @return The aggregate permanent stake balance
   */
  function permanentStakeBalance() external view returns (uint128);

  /**
   * @notice Returns the latest global reward checkpoint index
   * @return The current global checkpoint index
   */
  function globalCheckpointIndex() external view returns (uint256);

  /**
   * @notice Returns the latest reward checkpoint index for a veNFT
   * @param _tokenId The ID of the veNFT
   * @return The latest user reward checkpoint index
   */
  function userRewardCheckpointIndex(uint256 _tokenId) external view returns (uint256);

  /**
   * @notice Returns the accumulated slope changes to be applied at a given timestamp
   * @dev    Tracks changes in voting power decay at stake expiry timestamps
   * @param _timestamp The timestamp to query
   * @return The stored slope change at the given timestamp
   */
  function slopeChanges(uint256 _timestamp) external view returns (int128);

  /**
   * @notice Returns the expiration timestamp for a veNFT at its latest checkpoint
   * @param _tokenId The token ID to query
   * @return The stake expiration timestamp
   */
  function stakeExpiry(uint256 _tokenId) external view returns (uint256);

  /**
   * @notice Returns the global reward checkpoint stored at a given index
   * @param _index The global checkpoint index to query
   * @return The global reward point at the given index
   */
  function globalRewardPointHistory(uint256 _index) external view returns (GlobalPoint memory);

  /**
   * @notice Returns a veNFT's reward checkpoint stored at a given index
   * @param _tokenId The ID of the veNFT
   * @param _index The user checkpoint index to query
   * @return The user reward point at the given index
   */
  function userRewardPointHistory(uint256 _tokenId, uint256 _index) external view returns (UserPoint memory);

  /**
   * @notice Returns the index of the latest global reward point at or prior to a given timestamp
   * @dev    The timestamp must not be in the future
   * @param _timestamp The timestamp to query the supply index for
   * @return The index of the supply checkpoint
   */
  function getPriorSupplyIndex(uint256 _timestamp) external view returns (uint256);

  /**
   * @notice Total voting power currently deposited across all veNFTs
   * @return The sum of all active voting weights
   */
  function totalSupply() external view returns (uint256);

  /**
   * @notice Calculates the total decayed voting power in the contract at a given timestamp
   * @param _timestamp The timestamp to query the total voting power for
   * @return The total decayed voting power at the given timestamp
   */
  function supplyAt(uint256 _timestamp) external view returns (uint256);

  /**
   * @notice Returns the index of the latest reward point for a veNFT at or prior to a given timestamp
   * @dev    The timestamp must not be in the future
   * @param _tokenId The token ID to query
   * @param _timestamp The timestamp to query the index for
   * @return The index of the veNFT's balance checkpoint
   */
  function getPriorBalanceIndex(uint256 _tokenId, uint256 _timestamp) external view returns (uint256);

  /**
   * @notice Calculates the decayed voting power allocated by a veNFT as of a given timestamp
   * @param _tokenId The token ID to query
   * @param _timestamp The timestamp to query the veNFT's voting power for
   * @return The veNFT's decayed voting power at the given timestamp
   */
  function balanceOfNFTAt(uint256 _tokenId, uint256 _timestamp) external view returns (uint256);
}
