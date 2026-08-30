// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {GuardedAccessControlEnumerable} from 'V3/access/GuardedAccessControlEnumerable.sol';

/// @title GuardedAccessControlEnumerableForTest
/// @notice Minimal concrete GuardedAccessControlEnumerable used to unit-test the last-role-holder guard in isolation.
contract GuardedAccessControlEnumerableForTest is GuardedAccessControlEnumerable {
  /// @notice Self-administering role (its own admin), which the guard protects from losing its last holder.
  bytes32 public constant SELF_ADMIN_ROLE = keccak256('SELF_ADMIN_ROLE');

  /// @notice Operable role administered by SELF_ADMIN_ROLE (admin != role), which the guard never blocks.
  bytes32 public constant OPERABLE_ROLE = keccak256('OPERABLE_ROLE');

  /// @param _admin Initial holder of the self-administering role.
  constructor(address _admin) {
    _setRoleAdmin(SELF_ADMIN_ROLE, SELF_ADMIN_ROLE);
    _setRoleAdmin(OPERABLE_ROLE, SELF_ADMIN_ROLE);
    _grantRole(SELF_ADMIN_ROLE, _admin);
  }
}
