// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowGrantRole is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheVpmRoleAdmin(address _caller, address _vpm) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _vpmAdmin);
    bytes32 _vpmRole = _ve.VPM_ROLE();

    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _ve.VPM_ADMIN_ROLE())
    );
    vm.prank(_caller);
    _ve.grantRole(_vpmRole, _vpm);
  }

  function test_WhenGrantingTheVpmRoleToAValidCandidate(address _candidate) external {
    _assumeFuzzable(_candidate);
    bytes32 _vpmRole = _ve.VPM_ROLE();

    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _candidate);

    // it should grant the vpm role to the candidate
    assertTrue(_ve.hasRole(_vpmRole, _candidate));
  }

  function test_WhenGrantingANonVpmRoleToAValidCandidate(address _account) external {
    _assumeFuzzable(_account);
    vm.assume(_account != _vpmAdmin); // _vpmAdmin already holds VPM_ADMIN_ROLE
    bytes32 _vpmAdminRole = _ve.VPM_ADMIN_ROLE();

    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmAdminRole, _account);

    // it should grant the non vpm role to the candidate
    assertTrue(_ve.hasRole(_vpmAdminRole, _account));
  }

  function test_WhenTheCandidateAlreadyHoldsTheVpmRole(address _candidate) external {
    _assumeFuzzable(_candidate);
    bytes32 _vpmRole = _ve.VPM_ROLE();
    // Seed the holder with a first grant so the second grant exercises the idempotent path.
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _candidate);

    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _candidate);

    // it should keep the vpm role on the holder
    assertTrue(_ve.hasRole(_vpmRole, _candidate));
  }
}
