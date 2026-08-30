// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

contract UnitVoterPaymentsModulesetRestricted is BaseVoterPaymentsModule {
  function _grantFeeManager(address _account) internal {
    _setRole(_vpm.FEE_MANAGER(), _account);
  }

  function test_WhenTheCallerDoesNotHoldTheFeeManagerRole(address _caller, bytes4 _sig, bool _value) external {
    // it should revert with AccessControlUnauthorizedAccount
    _assumeFuzzable(_caller);
    bytes32 _feeManagerRole = _vpm.FEE_MANAGER();

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _feeManagerRole)
    );
    vm.prank(_caller);
    _vpm.setRestricted(_sig, _value);
  }

  modifier whenTheCallerHoldsTheFeeManagerRole() {
    _;
  }

  function test_WhenTogglingToTrue(bytes4 _sig, address _feeManager) external whenTheCallerHoldsTheFeeManagerRole {
    // it should set restricted[sig] to true
    // it should emit RestrictedSet
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    vm.prank(_feeManager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.RestrictedSet(_sig, true);
    _vpm.setRestricted(_sig, true);
    assertTrue(_vpm.restricted(_sig));
  }

  function test_WhenTogglingToFalse(bytes4 _sig, address _feeManager) external whenTheCallerHoldsTheFeeManagerRole {
    // it should set restricted[sig] to false
    // it should emit RestrictedSet
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _setRestricted(_sig, true);
    vm.prank(_feeManager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.RestrictedSet(_sig, false);
    _vpm.setRestricted(_sig, false);
    assertFalse(_vpm.restricted(_sig));
  }

  function test_WhenTheValueIsUnchanged(
    bytes4 _sig,
    address _feeManager,
    bool _value
  ) external whenTheCallerHoldsTheFeeManagerRole {
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _setRestricted(_sig, _value);

    vm.recordLogs();
    vm.prank(_feeManager);
    _vpm.setRestricted(_sig, _value);

    // it should not emit RestrictedSet
    assertEq(vm.getRecordedLogs().length, 0);
    // it should leave the restricted flag unchanged
    assertEq(_vpm.restricted(_sig), _value);
  }
}
