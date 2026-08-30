// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {VotingEscrow} from 'V3/core/VotingEscrow.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowConstructor is BaseVotingEscrow {
  function test_WhenTheTokenAddressIsZero() external {
    IVotingEscrow.Contracts memory _contracts = _defaultContracts();
    _contracts.token = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_contracts, _defaultAdmins());
  }

  function test_WhenTheVoterAddressIsZero() external {
    IVotingEscrow.Contracts memory _contracts = _defaultContracts();
    _contracts.voter = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_contracts, _defaultAdmins());
  }

  function test_WhenTheArtProxyAddressIsZero() external {
    IVotingEscrow.Contracts memory _contracts = _defaultContracts();
    _contracts.artProxy = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_contracts, _defaultAdmins());
  }

  function test_WhenTheVpmRoleAdminAddressIsZero() external {
    IVotingEscrow.Admins memory _admins = _defaultAdmins();
    _admins.vpmAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_defaultContracts(), _admins);
  }

  function test_WhenTheArtProxyAdminAddressIsZero() external {
    IVotingEscrow.Admins memory _admins = _defaultAdmins();
    _admins.artProxyAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_defaultContracts(), _admins);
  }

  function test_WhenTheBurnFeesAdminAddressIsZero() external {
    IVotingEscrow.Admins memory _admins = _defaultAdmins();
    _admins.burnFeesAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    new VotingEscrow(_defaultContracts(), _admins);
  }

  function test_WhenTheContractIsDeployed() external view {
    // it should set the token
    assertEq(address(_ve.TOKEN()), _token);
    // it should set the voter
    assertEq(address(_ve.VOTER()), _voter);
    // it should set the art proxy
    assertEq(_ve.artProxy(), _artProxy);
    // it should grant the vpm role admin role to the vpm role admin
    assertTrue(_ve.hasRole(_ve.VPM_ADMIN_ROLE(), _vpmAdmin));
    // it should grant the art proxy admin role to the configured admin
    assertTrue(_ve.hasRole(_ve.ART_PROXY_ADMIN_ROLE(), _artProxyAdmin));
    // it should grant the burn fees admin role to the configured admin
    assertTrue(_ve.hasRole(_ve.BURN_FEES_ADMIN_ROLE(), _burnFeesAdmin));
    // it should set the vpm role admin as the admin of the vpm role
    assertEq(_ve.getRoleAdmin(_ve.VPM_ROLE()), _ve.VPM_ADMIN_ROLE());
    // it should set the vpm role admin role as self administered
    assertEq(_ve.getRoleAdmin(_ve.VPM_ADMIN_ROLE()), _ve.VPM_ADMIN_ROLE());
    // it should set the art proxy admin role as self administered
    assertEq(_ve.getRoleAdmin(_ve.ART_PROXY_ADMIN_ROLE()), _ve.ART_PROXY_ADMIN_ROLE());
    // it should set the burn fees admin as the admin of the burn fees role
    assertEq(_ve.getRoleAdmin(_ve.BURN_FEES_ROLE()), _ve.BURN_FEES_ADMIN_ROLE());
    // it should set the burn fees admin role as self administered
    assertEq(_ve.getRoleAdmin(_ve.BURN_FEES_ADMIN_ROLE()), _ve.BURN_FEES_ADMIN_ROLE());
    // it should not grant the default admin role to the deployer
    assertFalse(_ve.hasRole(_ve.DEFAULT_ADMIN_ROLE(), _deployer));
    // it should record the initial point history timestamp
    assertEq(_ve.pointHistory(0).ts, block.timestamp);
  }
}
