// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLPoolConstants
/// @notice Minimal redeclaration of the concentrated-liquidity pool's effectively-immutable getters, limited to the
/// members this codebase integrates against. Not a complete pool interface.
interface ICLPoolConstants {
  /// @notice The spacing between usable ticks.
  /// @return The tick spacing.
  function tickSpacing() external view returns (int24);
}
