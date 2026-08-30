// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter} from 'V3-test/unit/voter/BaseVoter.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

contract UnitVoterRevokeRole is BaseVoter {
  function test_WhenRevokingTheLastHolderOfASelfAdministeringRole() external {
    // GOVERNANCE_ROLE administers itself, so the sole governor can revoke its own last seat.
    vm.prank(_GOVERNOR);
    // it should revert with LastRoleHolder
    vm.expectRevert(
      abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, Roles.GOVERNANCE_ROLE)
    );
    _voter.revokeRole(Roles.GOVERNANCE_ROLE, _GOVERNOR);
  }

  function test_WhenRevokingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _GOVERNOR);
    vm.prank(_GOVERNOR);
    _voter.grantRole(Roles.GOVERNANCE_ROLE, _second);
    // The arrange must have landed, so a grant regression fails here instead of passing the case vacuously.
    assertTrue(_voter.hasRole(Roles.GOVERNANCE_ROLE, _second));

    // it should remove the role from the holder
    vm.prank(_GOVERNOR);
    _voter.revokeRole(Roles.GOVERNANCE_ROLE, _second);

    assertFalse(_voter.hasRole(Roles.GOVERNANCE_ROLE, _second));
  }
}
