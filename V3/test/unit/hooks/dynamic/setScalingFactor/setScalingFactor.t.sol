// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetScalingFactor is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setScalingFactor(address(0), 0);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenPoolDoesntExist() external whenCallerIsFeeManager {
    // It should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(address(0), false);
    dynamicSwapFeeHook.setScalingFactor(address(0), 1);
  }

  modifier whenPoolExists() {
    _mockAndExpectIsPool(pool, true);
    _;
  }

  function test_WhenFeeCapIsSetTo0() external whenCallerIsFeeManager whenPoolExists {
    // It should revert with "ISF"
    vm.expectRevert(bytes('ISF'));
    dynamicSwapFeeHook.setScalingFactor(pool, 1);
  }

  modifier whenFeeCapIsNot0() {
    _setFeeCap(address(dynamicSwapFeeHook), pool, 1111);
    _;
  }

  function test_WhenScalingFactorIsHigherThanMaxScalingFactorCap()
    external
    whenCallerIsFeeManager
    whenPoolExists
    whenFeeCapIsNot0
  {
    uint64 _higher = uint64(dynamicSwapFeeHook.MAX_SCALING_FACTOR() + 1);

    // It should revert with "ISF"
    vm.expectRevert(bytes('ISF'));
    dynamicSwapFeeHook.setScalingFactor(pool, _higher);
  }

  function test_WhenScalingFactorIsLessThanMaxScalingFactorCap(uint64 _newScalingFactor)
    external
    whenCallerIsFeeManager
    whenPoolExists
    whenFeeCapIsNot0
  {
    _newScalingFactor = uint64(bound(_newScalingFactor, 0, dynamicSwapFeeHook.MAX_SCALING_FACTOR()));

    // It should set scaling factor
    // It should emit a {ScalingFactorSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.ScalingFactorSet(pool, _newScalingFactor);
    dynamicSwapFeeHook.setScalingFactor(pool, _newScalingFactor);

    (,, uint64 _k,,) = dynamicSwapFeeHook.dynamicFeeConfig(pool);
    assertEqUint(_k, _newScalingFactor);
  }
}
