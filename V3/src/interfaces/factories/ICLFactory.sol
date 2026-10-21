// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLFactory
/// @notice Concentrated-liquidity factory functions used by the dynamic swap fee hook and the Metarouter's CL
///         position commands.
interface ICLFactory {
  /// @notice Returns the manager authorized to configure swap fees.
  function swapFeeManager() external view returns (address);

  /// @notice Returns whether an address is a pool created by the factory.
  function isPool(address _pool) external view returns (bool);

  /// @notice Returns the default fee for a tick spacing.
  function tickSpacingToFee(int24 _tickSpacing) external view returns (uint24);

  /// @notice Returns the discount registry.
  function discountRegistry() external view returns (address);

  /// @notice Returns the concentrated-liquidity pool tape.
  function clPoolTape() external view returns (address);

  /// @notice Returns the canonical position manager issuing positions for this factory's pools.
  /// @dev Immutable and nonzero upstream, paired with the manager's own `factory` getter. Returned as an `address` to
  ///      mirror the upstream ABI and keep this interface free of a position-manager import.
  /// @return The nonfungible position manager paired with this factory.
  function positionManager() external view returns (address);
}
