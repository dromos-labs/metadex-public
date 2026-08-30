// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

contract UnitLeafVoterRevokeRole is BaseLeafVoter {
  function test_WhenRevokingTheLastHolderOfASelfAdministeringRole() external {
    // GOVERNANCE_ROLE administers itself, so the sole governor can revoke its own last seat.
    vm.prank(_GOVERNOR);
    // it should revert with LastRoleHolder
    vm.expectRevert(
      abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, Roles.GOVERNANCE_ROLE)
    );
    _leafVoter.revokeRole(Roles.GOVERNANCE_ROLE, _GOVERNOR);
  }

  function test_WhenRevokingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _GOVERNOR);
    vm.prank(_GOVERNOR);
    _leafVoter.grantRole(Roles.GOVERNANCE_ROLE, _second);
    // The arrange must have landed, so a grant regression fails here instead of passing the case vacuously.
    assertTrue(_leafVoter.hasRole(Roles.GOVERNANCE_ROLE, _second));

    // it should remove the role from the holder
    vm.prank(_GOVERNOR);
    _leafVoter.revokeRole(Roles.GOVERNANCE_ROLE, _second);

    assertFalse(_leafVoter.hasRole(Roles.GOVERNANCE_ROLE, _second));
  }
}
