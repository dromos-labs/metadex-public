// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLPoolState
/// @notice Minimal redeclaration of the concentrated-liquidity pool's mutable-state getters, limited to the members
/// this codebase integrates against. Not a complete pool interface.
interface ICLPoolState {
  /// @notice Reads the pool's packed primary state slot.
  /// @return sqrtPriceX96 Current sqrt(token1/token0) price as a Q64.96 value.
  /// @return tick Current tick.
  /// @return observationIndex Index of the most recently written oracle observation.
  /// @return observationCardinality Number of observations currently stored.
  /// @return observationCardinalityNext Number of observations the pool will grow to.
  /// @return unlocked Whether the pool is free of an in-flight reentrancy lock.
  function slot0()
    external
    view
    returns (
      uint160 sqrtPriceX96,
      int24 tick,
      uint16 observationIndex,
      uint16 observationCardinality,
      uint16 observationCardinalityNext,
      bool unlocked
    );

  /// @notice Reads the timestamp through which staked-liquidity accumulators were last settled.
  /// @return The last-updated timestamp.
  function lastUpdated() external view returns (uint48);

  /// @notice Reads the stored seconds-per-staked-liquidity accumulator.
  /// @return The Q128.128 stored seconds per staked liquidity cumulative.
  function secondsPerStakedLiquidityCumulativeX128() external view returns (uint160);

  /// @notice Reads one entry of the pool's oracle observation ring.
  /// @param index Position in the observation array.
  /// @return blockTimestamp Timestamp the observation was written at.
  /// @return tickCumulative Running tick-seconds total at that timestamp.
  /// @return secondsPerLiquidityCumulativeX128 Running seconds-per-in-range-liquidity total, as a Q128.128 value.
  /// @return initialized Whether the entry holds usable data.
  function observations(uint256 index)
    external
    view
    returns (uint32 blockTimestamp, int56 tickCumulative, uint160 secondsPerLiquidityCumulativeX128, bool initialized);
}
