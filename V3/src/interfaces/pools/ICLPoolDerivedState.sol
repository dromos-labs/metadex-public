// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLPoolDerivedState
/// @notice Minimal redeclaration of the concentrated-liquidity pool's computed (non-stored) getters, limited to the
/// members this codebase integrates against. Not a complete pool interface.
interface ICLPoolDerivedState {
  /// @notice Reads the pool's oracle accumulators at one or more past points in time.
  /// @param secondsAgos How far back, in seconds, each requested sample sits relative to the current block.
  /// @return tickCumulatives Running tick-seconds total at each requested point.
  /// @return secondsPerLiquidityCumulativeX128s Running seconds-per-in-range-liquidity total, as a Q128.128 value, at
  /// each requested point.
  function observe(uint32[] calldata secondsAgos)
    external
    view
    returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);

  /// @notice Reads the seconds-per-staked-liquidity accumulator brought forward to the current block.
  /// @return The Q128.128 accumulator value.
  function getSecondsPerStakedLiquidityCumulativeX128() external view returns (uint160);
}
