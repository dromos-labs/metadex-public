// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {PriorityFeeMevTaxModule} from 'V3/fees/PriorityFeeMevTaxModule.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitPriorityFeeMevTaxModule is TestHelpers {
  uint64 internal constant _PRIORITY_FEE_MULTIPLIER = 25_000_000;
  uint96 internal constant _MIN_THRESHOLD = 3e8;
  uint96 internal constant _BASE_FEE_FACTOR = 5;

  PriorityFeeMevTaxModule internal _mevTaxModule;
  address internal _owner = makeAddr('owner');

  function setUp() external {
    _mevTaxModule = new PriorityFeeMevTaxModule(_owner, _PRIORITY_FEE_MULTIPLIER, _MIN_THRESHOLD, _BASE_FEE_FACTOR);
  }

  function test_ConstructorWhenTheInitialOwnerIsTheZeroAddress() external {
    // it should revert with OwnableInvalidOwner
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new PriorityFeeMevTaxModule(address(0), _PRIORITY_FEE_MULTIPLIER, _MIN_THRESHOLD, _BASE_FEE_FACTOR);
  }

  function test_ConstructorWhenDeployingAValidContract(
    address _newOwner,
    uint64 _multiplier,
    uint96 _minThreshold,
    uint96 _baseFeeFactor
  ) external {
    vm.assume(_newOwner != address(0));

    // it should emit MultiplierSet
    vm.expectEmit();
    emit IMevTaxModule.MultiplierSet(_multiplier);
    // it should emit MinThresholdSet
    vm.expectEmit();
    emit IMevTaxModule.MinThresholdSet(_minThreshold);
    // it should emit BaseFeeFactorSet
    vm.expectEmit();
    emit IMevTaxModule.BaseFeeFactorSet(_baseFeeFactor);

    PriorityFeeMevTaxModule _module = new PriorityFeeMevTaxModule(_newOwner, _multiplier, _minThreshold, _baseFeeFactor);

    // it should set the owner
    assertEq(_module.owner(), _newOwner);
    // it should set the priority fee multiplier
    assertEq(_module.priorityFeeMultiplier(), _multiplier);
    // it should set the min threshold
    assertEq(_module.minThreshold(), _minThreshold);
    // it should set the base fee factor
    assertEq(_module.baseFeeFactor(), _baseFeeFactor);
  }

  function test_SetMultiplierWhenTheCallerIsNotTheOwner(address _caller) external {
    vm.assume(_caller != _owner);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _mevTaxModule.setMultiplier(_PRIORITY_FEE_MULTIPLIER);
  }

  function test_SetMultiplierWhenTheCallerIsTheOwner(uint64 _multiplier) external {
    // it should emit MultiplierSet
    _expectEmit(address(_mevTaxModule));
    emit IMevTaxModule.MultiplierSet(_multiplier);

    vm.prank(_owner);
    _mevTaxModule.setMultiplier(_multiplier);

    // it should set the priority fee multiplier
    assertEq(_mevTaxModule.priorityFeeMultiplier(), _multiplier);
  }

  function test_SetMinThresholdWhenTheCallerIsNotTheOwner(address _caller) external {
    vm.assume(_caller != _owner);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _mevTaxModule.setMinThreshold(_MIN_THRESHOLD);
  }

  function test_SetMinThresholdWhenTheCallerIsTheOwner(uint96 _minThreshold) external {
    // it should emit MinThresholdSet
    _expectEmit(address(_mevTaxModule));
    emit IMevTaxModule.MinThresholdSet(_minThreshold);

    vm.prank(_owner);
    _mevTaxModule.setMinThreshold(_minThreshold);

    // it should set the min threshold
    assertEq(_mevTaxModule.minThreshold(), _minThreshold);
  }

  function test_SetBaseFeeFactorWhenTheCallerIsNotTheOwner(address _caller) external {
    vm.assume(_caller != _owner);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _mevTaxModule.setBaseFeeFactor(_BASE_FEE_FACTOR);
  }

  function test_SetBaseFeeFactorWhenTheCallerIsTheOwner(uint96 _baseFeeFactor) external {
    // it should emit BaseFeeFactorSet
    _expectEmit(address(_mevTaxModule));
    emit IMevTaxModule.BaseFeeFactorSet(_baseFeeFactor);

    vm.prank(_owner);
    _mevTaxModule.setBaseFeeFactor(_baseFeeFactor);

    // it should set the base fee factor
    assertEq(_mevTaxModule.baseFeeFactor(), _baseFeeFactor);
  }
}
