// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title  IRelayModule
/// @notice What every Relay module has in common: the sweeps that get value back out. A module is a
///         satellite of one Relay that holds a balance between calls while holding no role on the
///         Relay itself, so it needs a way to recover what a batch leaves behind. The events and the
///         errors are declared once here.
/// @dev Who may sweep, and how that party is seated, are the implementing module's own. This
///      interface fixes the shape of the sweeps, never their policy.
interface IRelayModule {
  /// @notice Pool family a swap route runs through. Each family has its own exact-input command on the Metarouter.
  /// @dev Shared by the modules: both compose Metarouter swap batches, and the command byte is the only thing the
  ///      family selects.
  enum PoolFamily {
    V2,
    CL
  }

  /// @notice Emitted when the module's native balance is swept out.
  /// @param to Recipient the keeper named.
  /// @param amount Amount moved, always the module's whole balance.
  event NativeSwept(address indexed to, uint256 amount);

  /// @notice Emitted when one of the module's token balances is swept out.
  /// @param token Token moved.
  /// @param to Recipient the keeper named.
  /// @param amount Amount moved, always the module's whole balance of that token.
  event TokenSwept(address indexed token, address indexed to, uint256 amount);

  /// @notice Thrown when an address argument is zero.
  error ZeroAddress();

  /// @notice Thrown when a native transfer out of the module fails.
  error NativeTransferFailed();

  /// @notice Thrown when a sweep finds nothing to move.
  error NothingToSweep();
}
