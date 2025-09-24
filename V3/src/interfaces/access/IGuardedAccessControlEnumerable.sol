// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title GuardedAccessControlEnumerable interface
/// @notice Shared surface for AccessControlEnumerable extensions that block orphaning a self-administering role.
interface IGuardedAccessControlEnumerable {
  /// @notice Thrown when revoking or renouncing would remove the last holder of a self-administering role,
  ///         permanently freezing that role.
  /// @param role Role whose last holder cannot be removed.
  error LastRoleHolder(bytes32 role);
}
