// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IBaseTokenExtensions
/// @notice Interface for token custom behavior shared by every protocol token.
interface IBaseTokenExtensions {
  /// @notice Thrown when an address parameter is the zero address.
  error ZeroAddress();
}
