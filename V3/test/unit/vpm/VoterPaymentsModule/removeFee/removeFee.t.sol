// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

contract UnitVoterPaymentsModuleremoveFee is BaseVoterPaymentsModule {
  function test_WhenTheCallerDoesNotHoldTheFeeManagerRole(address _caller, bytes4 _sig, address _target) external {
    // it should revert with AccessControlUnauthorizedAccount
    _assumeFuzzable(_caller);
    bytes32 _feeManagerRole = _vpm.FEE_MANAGER();
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _feeManagerRole)
    );
    vm.prank(_caller);
    _vpm.removeFee(_sig, _target);
  }

  modifier whenTheCallerHoldsTheFeeManagerRole() {
    _;
  }

  function test_WhenTheTargetIsTheDefaultSlot(
    bytes4 _sig,
    address _manager
  ) external whenTheCallerHoldsTheFeeManagerRole {
    // it should revert with CannotRemoveDefault
    _assumeFuzzable(_manager);
    _setRole(_vpm.FEE_MANAGER(), _manager);
    vm.prank(_manager);
    vm.expectRevert(IVoterPaymentsModule.CannotRemoveDefault.selector);
    _vpm.removeFee(_sig, address(0));
  }

  modifier whenTheTargetIsAConcreteAddress() {
    _;
  }

  function test_WhenTheTargetHasNoRegisteredRecord(
    bytes4 _sig,
    address _manager,
    address _caller
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheTargetIsAConcreteAddress {
    // it should revert with NotRegistered
    _assumeFuzzable(_manager);
    vm.assume(_caller != address(0));
    _setRole(_vpm.FEE_MANAGER(), _manager);
    vm.prank(_manager);
    vm.expectRevert(IVoterPaymentsModule.NotRegistered.selector);
    _vpm.removeFee(_sig, _caller);
  }

  function test_WhenTheRecordIsRegisteredAndTheOperationIsRestricted(
    bytes4 _sig,
    address _manager,
    address _caller,
    uint128 _callerRate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheTargetIsAConcreteAddress {
    // it should clear the record
    // it should emit FeeRemoved
    _assumeFuzzable(_manager);
    vm.assume(_caller != address(0));
    _setRole(_vpm.FEE_MANAGER(), _manager);
    _callerRate = uint128(bound(_callerRate, 0, uint128(MAX_PIPS)));
    _setFee(_sig, _caller, true, _callerRate);
    _setRestricted(_sig, true);

    vm.prank(_manager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.FeeRemoved(_sig, _caller);
    _vpm.removeFee(_sig, _caller);

    (bool _registered,) = _vpm.fees(_sig, _caller);
    assertFalse(_registered);
  }

  function test_WhenTheRecordIsRegisteredAndTheOperationIsNotRestricted(
    bytes4 _sig,
    address _manager,
    address _caller,
    uint128 _defaultRate,
    uint128 _callerRate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheTargetIsAConcreteAddress {
    // it should clear the record
    // it should leave the target resolving to the default rate
    // it should emit FeeRemoved
    _assumeFuzzable(_manager);
    vm.assume(_caller != address(0));
    _setRole(_vpm.FEE_MANAGER(), _manager);
    _defaultRate = uint128(bound(_defaultRate, 0, uint128(MAX_PIPS)));
    _callerRate = uint128(bound(_callerRate, 0, uint128(MAX_PIPS)));
    _setFee(_sig, address(0), true, _defaultRate);
    _setFee(_sig, _caller, true, _callerRate);

    vm.prank(_manager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.FeeRemoved(_sig, _caller);
    _vpm.removeFee(_sig, _caller);

    (bool _registered,) = _vpm.fees(_sig, _caller);
    assertFalse(_registered);
    // Unregistered and not restricted, so the effective rate falls back to the operation default.
    assertEq(_vpm.getFee(_sig, _caller), _defaultRate);
  }
}
