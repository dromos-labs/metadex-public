// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLGaugeFactory
/// @notice Concentrated-liquidity gauge factory functions used by the Metarouter's position manager resolution.
interface ICLGaugeFactory {
  /// @notice Address of the NonfungiblePositionManager used to create nfts that gauges will accept
  /// @dev Immutable and nonzero upstream, set to the manager of the CL factory the gauge factory serves. Returned as
  ///      an `address` to mirror the upstream ABI and keep this interface free of a position-manager import.
  /// @return The nonfungible position manager the factory's gauges accept.
  function nft() external view returns (address);
}
