// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {AccessControlEnumerable} from '@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

/// @title GuardedAccessControlEnumerable
/// @notice AccessControlEnumerable that blocks removing the last holder of a self-administering role, which would
///         permanently freeze that role.
abstract contract GuardedAccessControlEnumerable is AccessControlEnumerable, IGuardedAccessControlEnumerable {
  /// @notice Block removing the last holder of a self-administering role, which would permanently freeze it.
  /// @dev Covers both `revokeRole` and `renounceRole` (both funnel through `_revokeRole`). Only self-administering
  ///      roles (admin == role) are guarded; operable roles stay fully revocable and re-grantable by their admin.
  /// @param _role Role being revoked.
  /// @param _account Holder losing the role.
  /// @return _revoked Whether the role was held and removed.
  function _revokeRole(
    bytes32 _role,
    address _account
  ) internal override(AccessControlEnumerable) returns (bool _revoked) {
    if (getRoleAdmin(_role) == _role && hasRole(_role, _account) && getRoleMemberCount(_role) == 1) {
      revert LastRoleHolder(_role);
    }
    return super._revokeRole(_role, _account);
  }
}
