// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

contract UnitVoterPaymentsModulegetFee is BaseVoterPaymentsModule {
  modifier whenTheCallerIsRegistered() {
    _;
  }

  function test_WhenTheCallerRateIsBelowTheDefault(
    bytes4 _sig,
    address _caller,
    uint128 _defaultRate,
    uint128 _callerRate
  ) external whenTheCallerIsRegistered {
    // it should return the caller rate
    vm.assume(_caller != address(0));
    _defaultRate = uint128(bound(_defaultRate, 2, MAX_PIPS));
    _callerRate = uint128(bound(_callerRate, 0, _defaultRate - 1));

    _setFee(_sig, address(0), true, _defaultRate);
    _setFee(_sig, _caller, true, _callerRate);

    assertEq(_vpm.getFee(_sig, _caller), _callerRate);
  }

  function test_WhenTheCallerRateIsAboveTheDefault(
    bytes4 _sig,
    address _caller,
    uint128 _defaultRate,
    uint128 _callerRate
  ) external whenTheCallerIsRegistered {
    // it should return the default rate
    vm.assume(_caller != address(0));
    _defaultRate = uint128(bound(_defaultRate, 0, MAX_PIPS - 1));
    _callerRate = uint128(bound(_callerRate, _defaultRate + 1, MAX_PIPS));

    _setFee(_sig, address(0), true, _defaultRate);
    _setFee(_sig, _caller, true, _callerRate);

    assertEq(_vpm.getFee(_sig, _caller), _defaultRate);
  }

  function test_WhenTheCallerRateEqualsTheDefault(
    bytes4 _sig,
    address _caller,
    uint128 _rate
  ) external whenTheCallerIsRegistered {
    // it should return the default rate
    vm.assume(_caller != address(0));
    _rate = uint128(bound(_rate, 0, MAX_PIPS));

    _setFee(_sig, address(0), true, _rate);
    _setFee(_sig, _caller, true, _rate);

    assertEq(_vpm.getFee(_sig, _caller), _rate);
  }

  modifier whenTheCallerIsUnregistered() {
    _;
  }

  function test_WhenRestrictedIsTrue(
    bytes4 _sig,
    address _caller,
    uint128 _defaultRate
  ) external whenTheCallerIsUnregistered {
    // it should revert with NotRegistered
    vm.assume(_caller != address(0));
    _defaultRate = uint128(bound(_defaultRate, 0, MAX_PIPS));
    _setFee(_sig, address(0), true, _defaultRate);
    _setRestricted(_sig, true);

    vm.expectRevert(IVoterPaymentsModule.NotRegistered.selector);
    _vpm.getFee(_sig, _caller);
  }

  function test_WhenRestrictedIsFalse(
    bytes4 _sig,
    address _caller,
    uint128 _defaultRate
  ) external whenTheCallerIsUnregistered {
    // it should return the default rate
    vm.assume(_caller != address(0));
    _defaultRate = uint128(bound(_defaultRate, 0, MAX_PIPS));
    _setFee(_sig, address(0), true, _defaultRate);

    assertEq(_vpm.getFee(_sig, _caller), _defaultRate);
  }
}
