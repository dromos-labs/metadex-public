// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';

contract UnitVotingEscrowRevokeRole is BaseVotingEscrow {
  function test_WhenTheVpmRoleAdminRevokesTheRoleFromAHolder(address _holder) external {
    _assumeFuzzable(_holder);
    bytes32 _vpmRole = _ve.VPM_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _holder);

    vm.prank(_vpmAdmin);
    _ve.revokeRole(_vpmRole, _holder);

    // it should remove the vpm role from the holder
    assertFalse(_ve.hasRole(_vpmRole, _holder));
    // it should no longer mark the holder as authorized via isAuthorizedVPM
    assertFalse(_ve.isAuthorizedVPM(_holder));
  }

  function test_WhenTheCallerIsNotTheVpmRoleAdmin(address _caller, address _holder) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _vpmAdmin);
    bytes32 _vpmRole = _ve.VPM_ROLE();

    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _ve.VPM_ADMIN_ROLE())
    );
    vm.prank(_caller);
    _ve.revokeRole(_vpmRole, _holder);
  }

  function test_WhenRevokingTheLastHolderOfASelfAdministeringRole() external {
    // VPM_ADMIN_ROLE is self-administering and seeded with a single holder (_vpmAdmin).
    bytes32 _adminRole = _ve.VPM_ADMIN_ROLE();

    // it should revert with LastRoleHolder
    vm.prank(_vpmAdmin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _adminRole));
    _ve.revokeRole(_adminRole, _vpmAdmin);
  }

  function test_WhenRevokingANonLastHolderOfASelfAdministeringRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _vpmAdmin);
    bytes32 _adminRole = _ve.VPM_ADMIN_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_adminRole, _second);

    vm.prank(_vpmAdmin);
    _ve.revokeRole(_adminRole, _second);

    // it should remove the role from the holder
    assertFalse(_ve.hasRole(_adminRole, _second));
  }
}
