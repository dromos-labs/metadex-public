// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowSetArtProxy is BaseVotingEscrow {
  function test_WhenTheCallerDoesNotHoldTheArtProxyAdminRole(address _caller, address _proxy) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _artProxyAdmin);

    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(
      abi.encodeWithSelector(
        IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _ve.ART_PROXY_ADMIN_ROLE()
      )
    );
    vm.prank(_caller);
    _ve.setArtProxy(_proxy);
  }

  function test_WhenTheProxyIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IVotingEscrow.ZeroAddress.selector);
    vm.prank(_artProxyAdmin);
    _ve.setArtProxy(address(0));
  }

  function test_WhenTheProxyIsUnchanged() external {
    address _current = _ve.artProxy();

    vm.recordLogs();
    vm.prank(_artProxyAdmin);
    _ve.setArtProxy(_current);

    // it should not emit any event
    assertEq(vm.getRecordedLogs().length, 0);
    // it should leave the art proxy unchanged
    assertEq(_ve.artProxy(), _current);
  }

  function test_WhenTheCallerHoldsTheArtProxyAdminRole(address _proxy) external {
    vm.assume(_proxy != address(0));
    vm.assume(_proxy != _ve.artProxy());

    // it should emit the ArtProxyUpdated event
    _expectEmit(address(_ve));
    emit IVotingEscrow.ArtProxyUpdated(_proxy);
    // it should emit the BatchMetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.BatchMetadataUpdate(0, type(uint256).max);

    vm.prank(_artProxyAdmin);
    _ve.setArtProxy(_proxy);

    // it should update the art proxy address
    assertEq(_ve.artProxy(), _proxy);
  }
}
