// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

contract UnitVotingEscrowRenounceRole is BaseVotingEscrow {
  function test_WhenRenouncingTheLastHolderOfASelfAdministeringRole() external {
    // VPM_ADMIN_ROLE is self-administering and seeded with a single holder (_vpmAdmin).
    bytes32 _adminRole = _ve.VPM_ADMIN_ROLE();

    // it should revert with LastRoleHolder
    vm.prank(_vpmAdmin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _adminRole));
    _ve.renounceRole(_adminRole, _vpmAdmin);
  }

  function test_WhenRenouncingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _vpmAdmin);
    bytes32 _adminRole = _ve.VPM_ADMIN_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_adminRole, _second);

    // it should remove the role from the caller
    vm.prank(_second);
    _ve.renounceRole(_adminRole, _second);

    assertFalse(_ve.hasRole(_adminRole, _second));
  }
}
