// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IAccessControlEnumerable} from '@openzeppelin/contracts/access/extensions/IAccessControlEnumerable.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {VoterPaymentsModule} from 'V3/vpm/VoterPaymentsModule.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

contract UnitVoterPaymentsModule is BaseVoterPaymentsModule {
  function test_ConstructorWhenTheVEAddressIsZero() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterPaymentsModule.ZeroAddress.selector);
    new VoterPaymentsModule(address(0), _feeManagerAdmin);
  }

  function test_ConstructorWhenTheFeeManagerAdminIsZero() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterPaymentsModule.ZeroAddress.selector);
    new VoterPaymentsModule(_ve, address(0));
  }

  function test_ConstructorWhenEveryCheckPasses() external view {
    // it should set VE to the provided address
    assertEq(address(_vpm.VOTING_ESCROW()), _ve);
    // it should make FEE_MANAGER administered by FEE_MANAGER_ADMIN_ROLE
    assertEq(_vpm.getRoleAdmin(_vpm.FEE_MANAGER()), _vpm.FEE_MANAGER_ADMIN_ROLE());
    // it should make FEE_MANAGER_ADMIN_ROLE self administered
    assertEq(_vpm.getRoleAdmin(_vpm.FEE_MANAGER_ADMIN_ROLE()), _vpm.FEE_MANAGER_ADMIN_ROLE());
    // it should grant FEE_MANAGER_ADMIN_ROLE to the fee manager admin
    assertTrue(_vpm.hasRole(_vpm.FEE_MANAGER_ADMIN_ROLE(), _feeManagerAdmin));
  }

  function test_AdminRoleSelfRotationWhenAnAdminGrantsTheAdminRoleToANewHolder(
    address _newAdmin,
    address _feeManager
  ) external {
    // it should let the new holder grant the operational role
    _assumeFuzzable(_newAdmin);
    _assumeFuzzable(_feeManager);
    bytes32 _adminRole = _vpm.FEE_MANAGER_ADMIN_ROLE();
    bytes32 _operationalRole = _vpm.FEE_MANAGER();

    vm.prank(_feeManagerAdmin);
    _vpm.grantRole(_adminRole, _newAdmin);
    assertTrue(_vpm.hasRole(_adminRole, _newAdmin));

    vm.prank(_newAdmin);
    _vpm.grantRole(_operationalRole, _feeManager);
    assertTrue(_vpm.hasRole(_operationalRole, _feeManager));
  }

  function test_SupportsInterfaceWhenTheQueriedInterfaceIsIVoterPaymentsModule() external view {
    // it should return true
    assertTrue(_vpm.supportsInterface(type(IVoterPaymentsModule).interfaceId));
  }

  function test_SupportsInterfaceWhenTheQueriedInterfaceIsIERC165() external view {
    // it should return true
    assertTrue(_vpm.supportsInterface(type(IERC165).interfaceId));
  }

  function test_SupportsInterfaceWhenTheQueriedInterfaceIsIAccessControl() external view {
    // it should return true
    assertTrue(_vpm.supportsInterface(type(IAccessControl).interfaceId));
  }

  function test_SupportsInterfaceWhenTheQueriedInterfaceIsRandom(bytes4 _id) external view {
    // it should return false
    vm.assume(_id != type(IVoterPaymentsModule).interfaceId);
    vm.assume(_id != type(IERC165).interfaceId);
    vm.assume(_id != type(IAccessControl).interfaceId);
    vm.assume(_id != type(IAccessControlEnumerable).interfaceId);
    assertFalse(_vpm.supportsInterface(_id));
  }

  function test_RevokeRoleWhenRevokingTheLastHolderOfTheFeeManagerAdminRole() external {
    // FEE_MANAGER_ADMIN_ROLE is self-administering and seeded with a single holder (_feeManagerAdmin).
    bytes32 _adminRole = _vpm.FEE_MANAGER_ADMIN_ROLE();

    // it should revert with LastRoleHolder
    vm.prank(_feeManagerAdmin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _adminRole));
    _vpm.revokeRole(_adminRole, _feeManagerAdmin);
  }

  function test_RevokeRoleWhenRevokingANonLastHolderOfTheFeeManagerAdminRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _feeManagerAdmin);
    bytes32 _adminRole = _vpm.FEE_MANAGER_ADMIN_ROLE();
    vm.prank(_feeManagerAdmin);
    _vpm.grantRole(_adminRole, _second);

    vm.prank(_feeManagerAdmin);
    _vpm.revokeRole(_adminRole, _second);

    // it should remove the role from the holder
    assertFalse(_vpm.hasRole(_adminRole, _second));
  }

  function test_RenounceRoleWhenRenouncingTheLastHolderOfTheFeeManagerAdminRole() external {
    bytes32 _adminRole = _vpm.FEE_MANAGER_ADMIN_ROLE();

    // it should revert with LastRoleHolder
    vm.prank(_feeManagerAdmin);
    vm.expectRevert(abi.encodeWithSelector(IGuardedAccessControlEnumerable.LastRoleHolder.selector, _adminRole));
    _vpm.renounceRole(_adminRole, _feeManagerAdmin);
  }

  function test_RenounceRoleWhenRenouncingANonLastHolderOfTheFeeManagerAdminRole(address _second) external {
    _assumeFuzzable(_second);
    vm.assume(_second != _feeManagerAdmin);
    bytes32 _adminRole = _vpm.FEE_MANAGER_ADMIN_ROLE();
    vm.prank(_feeManagerAdmin);
    _vpm.grantRole(_adminRole, _second);

    // it should remove the role from the caller
    vm.prank(_second);
    _vpm.renounceRole(_adminRole, _second);

    assertFalse(_vpm.hasRole(_adminRole, _second));
  }
}
