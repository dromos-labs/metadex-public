// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IFeeDistribution
 * @notice Interface for all FeeDistribution implementations
 */
interface IFeeDistribution {
  /**
   * @notice Snapshot of the per-token fee accumulators at a global checkpoint index
   * @param feeReward0 The fee accumulator for token0 at the checkpoint
   * @param feeReward1 The fee accumulator for token1 at the checkpoint
   * @param feeReward0xTime The time-weighted fee accumulator for token0 at the checkpoint
   * @param feeReward1xTime The time-weighted fee accumulator for token1 at the checkpoint
   */
  struct FeeSnapshot {
    uint256 feeReward0;
    uint256 feeReward1;
    uint256 feeReward0xTime;
    uint256 feeReward1xTime;
  }

  /**
   * @notice Emitted when the gauge's pending fees are credited to the fee accumulator
   * @param _gauge The gauge whose pending fees were credited
   * @param _token The fee token that was credited
   * @param _amount The amount of fees credited to the accumulator, rounded up to the smallest token unit
   */
  event NotifyFeesAmount(address indexed _gauge, address indexed _token, uint256 _amount);

  /**
   * @notice Returns the gauge linked to this rewards contract
   * @return The address of the gauge
   */
  function gauge() external view returns (address);

  /**
   * @notice Returns the gauge factory that deployed the linked gauge
   * @return The address of the gauge factory
   */
  function gaugeFactory() external view returns (address);

  /**
   * @notice Returns the first fee token for the pool
   * @return The address of the first fee token
   */
  function token0() external view returns (address);

  /**
   * @notice Returns the second fee token for the pool
   * @return The address of the second fee token
   */
  function token1() external view returns (address);

  /**
   * @notice The gauge's pending token0 fees as of the last fee update
   * @dev Pending gauge fees already credited to the accumulator or buffer
   * @return The pending gauge fees in token0 at the last fee update
   */
  function lastPendingFees0() external view returns (uint256);

  /**
   * @notice The gauge's pending token1 fees as of the last fee update
   * @dev Pending gauge fees already credited to the accumulator or buffer
   * @return The pending gauge fees in token1 at the last fee update
   */
  function lastPendingFees1() external view returns (uint256);

  /**
   * @notice Buffered fee amount in token0
   * @dev Sub-threshold accruals waiting for a future fee accumulator advance
   * @return The buffered amount for token0
   */
  function bufferedFees0() external view returns (uint256);

  /**
   * @notice Buffered fee amount in token1
   * @dev Sub-threshold accruals waiting for a future fee accumulator advance
   * @return The buffered amount for token1
   */
  function bufferedFees1() external view returns (uint256);

  /**
   * @notice Timestamp of the last fee accumulator update
   * @return The timestamp of the last update
   */
  function lastFeeUpdate() external view returns (uint256);

  /**
   * @notice Fee accumulator for both fee tokens
   * @dev Monotonically non-decreasing
   * @return The reward per unit of voting power in token0
   * @return The reward per unit of voting power in token1
   * @return The time-weighted reward per unit of voting power in token0
   * @return The time-weighted reward per unit of voting power in token1
   */
  function feeRewardPerVotingPower() external view returns (uint256, uint256, uint256, uint256);

  /**
   * @notice Snapshot of the global fee accumulators at a given global checkpoint index
   * @dev Written during checkpoint/reset after each global point is recorded.
   *      Indexed by the same `globalCheckpointIndex` counter used for _globalRewardPointHistory.
   * @param _checkpointIndex The global checkpoint index
   * @return The token0 accumulator value at that checkpoint
   * @return The token1 accumulator value at that checkpoint
   * @return The time-weighted token0 accumulator value at that checkpoint
   * @return The time-weighted token1 accumulator value at that checkpoint
   */
  function feeRewardPerVotingPowerAt(uint256 _checkpointIndex)
    external
    view
    returns (uint256, uint256, uint256, uint256);
}
