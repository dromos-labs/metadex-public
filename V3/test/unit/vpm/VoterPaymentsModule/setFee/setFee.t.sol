// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

contract UnitVoterPaymentsModulesetFee is BaseVoterPaymentsModule {
  function _grantFeeManager(address _account) internal {
    _setRole(_vpm.FEE_MANAGER(), _account);
  }

  function test_WhenTheCallerDoesNotHoldTheFeeManagerRole(
    address _caller,
    bytes4 _sig,
    address _target,
    uint128 _rate
  ) external {
    // it should revert with AccessControlUnauthorizedAccount
    _assumeFuzzable(_caller);
    _rate = uint128(bound(_rate, 0, MAX_PIPS));
    bytes32 _feeManagerRole = _vpm.FEE_MANAGER();

    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _feeManagerRole)
    );
    vm.prank(_caller);
    _vpm.setFee(_sig, _target, _rate);
  }

  modifier whenTheCallerHoldsTheFeeManagerRole() {
    _;
  }

  function test_WhenTheRateExceedsPIPS(
    bytes4 _sig,
    address _feeManager,
    address _target,
    uint128 _rate
  ) external whenTheCallerHoldsTheFeeManagerRole {
    // it should revert with InvalidFeeRate
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _rate = uint128(bound(_rate, MAX_PIPS + 1, type(uint128).max));

    vm.prank(_feeManager);
    vm.expectRevert(IVoterPaymentsModule.InvalidFeeRate.selector);
    _vpm.setFee(_sig, _target, _rate);
  }

  modifier whenTheRateIsWithinBounds() {
    _;
  }

  function test_WhenTheEntryIsAlreadyRegisteredAtTheSameRate(
    bytes4 _sig,
    address _feeManager,
    address _caller,
    uint128 _rate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheRateIsWithinBounds {
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _rate = uint128(bound(_rate, 0, MAX_PIPS));
    // Seed an already-registered entry at the same rate.
    _setFee(_sig, _caller, true, _rate);

    vm.recordLogs();
    vm.prank(_feeManager);
    _vpm.setFee(_sig, _caller, _rate);

    // it should not emit FeeSet
    assertEq(vm.getRecordedLogs().length, 0);
    // it should leave the fee record unchanged
    (bool _storedRegistered, uint128 _storedRate) = _vpm.fees(_sig, _caller);
    assertTrue(_storedRegistered);
    assertEq(_storedRate, _rate);
  }

  function test_WhenTheEntryIsAlreadyRegisteredAtADifferentRate(
    bytes4 _sig,
    address _feeManager,
    address _caller,
    uint128 _oldRate,
    uint128 _newRate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheRateIsWithinBounds {
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _oldRate = uint128(bound(_oldRate, 0, MAX_PIPS));
    _newRate = uint128(bound(_newRate, 0, MAX_PIPS));
    vm.assume(_oldRate != _newRate);
    // Seed an already-registered entry at the old rate.
    _setFee(_sig, _caller, true, _oldRate);
    IVoterPaymentsModule.CallerInfo memory _expectedEntry = IVoterPaymentsModule.CallerInfo(true, _newRate);

    // it should emit FeeSet
    vm.prank(_feeManager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.FeeSet(_sig, _caller, _expectedEntry);
    _vpm.setFee(_sig, _caller, _newRate);

    // it should store the new rate
    (bool _storedRegistered, uint128 _storedRate) = _vpm.fees(_sig, _caller);
    assertTrue(_storedRegistered);
    assertEq(_storedRate, _newRate);
  }

  function test_WhenCallerIsTheDefaultSentinelAddressZero(
    bytes4 _sig,
    address _feeManager,
    uint128 _rate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheRateIsWithinBounds {
    // it should store the rate with registered true
    // it should emit FeeSet
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    _rate = uint128(bound(_rate, 0, MAX_PIPS));
    IVoterPaymentsModule.CallerInfo memory _expectedEntry = IVoterPaymentsModule.CallerInfo(true, _rate);

    vm.prank(_feeManager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.FeeSet(_sig, address(0), _expectedEntry);
    _vpm.setFee(_sig, address(0), _rate);

    (bool _storedRegistered, uint128 _storedRate) = _vpm.fees(_sig, address(0));
    assertTrue(_storedRegistered);
    assertEq(_storedRate, _rate);
  }

  function test_WhenCallerIsAConcreteAddress(
    bytes4 _sig,
    address _feeManager,
    address _caller,
    uint128 _rate
  ) external whenTheCallerHoldsTheFeeManagerRole whenTheRateIsWithinBounds {
    // it should store the rate with registered true
    // it should emit FeeSet
    _assumeFuzzable(_feeManager);
    _grantFeeManager(_feeManager);
    vm.assume(_caller != address(0));
    _rate = uint128(bound(_rate, 0, MAX_PIPS));
    IVoterPaymentsModule.CallerInfo memory _expectedEntry = IVoterPaymentsModule.CallerInfo(true, _rate);

    vm.prank(_feeManager);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.FeeSet(_sig, _caller, _expectedEntry);
    _vpm.setFee(_sig, _caller, _rate);

    (bool _storedRegistered, uint128 _storedRate) = _vpm.fees(_sig, _caller);
    assertTrue(_storedRegistered);
    assertEq(_storedRate, _rate);
  }
}
