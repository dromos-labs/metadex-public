// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

import {GuardedAccessControlEnumerableForTest} from 'V3-test/unit/access/GuardedAccessControlEnumerableForTest.sol';

contract UnitGuardedAccessControlEnumerable is TestHelpers {
  GuardedAccessControlEnumerableForTest internal _guarded;

  address internal _admin = makeAddr('Admin');

  bytes32 internal _selfAdminRole;
  bytes32 internal _operableRole;

  function setUp() external {
    _guarded = new GuardedAccessControlEnumerableForTest(_admin);
    _selfAdminRole = _guarded.SELF_ADMIN_ROLE();
    _operableRole = _guarded.OPERABLE_ROLE();
  }

  function test_RevokeRoleWhenTheRoleIsNotSelfAdministering(address _holder) external {
    _assumeFuzzable(_holder);
    vm.assume(_holder != _admin);
    vm.prank(_admin);
    _guarded.grantRole(_operableRole, _holder);

    vm.prank(_admin);
    _guarded.revokeRole(_operableRole, _holder);

    // it should remove the role from the holder
    assertFalse(_guarded.hasRole(_operableRole, _holder));
  }

  function test_RevokeRoleWhenTheRoleIsSelfAdministeringButTheAccountIsNotAHolder(address _account) external {
    _assumeFuzzable(_account);
    vm.assume(_account != _admin);

    // The account never held the role, so the guard's `hasRole` check short-circuits and no revert occurs.
    vm.prank(_admin);
    _guarded.revokeRole(_selfAdminRole, _account);

    // it should leave the role membership unchanged
    assertFalse(_guarded.hasRole(_selfAdminRole, _account));
    assertEq(_guarded.getRoleMemberCount(_selfAdminRole), 1);
  }

  function test_RevokeRoleWhenRevokingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _admin);
    vm.prank(_admin);
    _guarded.grantRole(_selfAdminRole, _second);

    vm.prank(_admin);
    _guarded.revokeRole(_selfAdminRole, _second);

    // it should remove the role from the holder
    assertFalse(_guarded.hasRole(_selfAdminRole, _second));
  }

  function test_RevokeRoleWhenRevokingTheLastHolderOfASelfAdministeringRole() external {
    // it should revert with LastRoleHolder
    vm.prank(_admin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _selfAdminRole));
    _guarded.revokeRole(_selfAdminRole, _admin);
  }

  function test_RenounceRoleWhenRenouncingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _admin);
    vm.prank(_admin);
    _guarded.grantRole(_selfAdminRole, _second);

    // it should remove the role from the caller
    vm.prank(_second);
    _guarded.renounceRole(_selfAdminRole, _second);

    assertFalse(_guarded.hasRole(_selfAdminRole, _second));
  }

  function test_RenounceRoleWhenRenouncingTheLastHolderOfASelfAdministeringRole() external {
    // it should revert with LastRoleHolder
    vm.prank(_admin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _selfAdminRole));
    _guarded.renounceRole(_selfAdminRole, _admin);
  }
}
