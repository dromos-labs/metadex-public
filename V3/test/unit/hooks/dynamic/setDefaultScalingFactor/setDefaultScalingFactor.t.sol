// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetDefaultScalingFactor is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setDefaultScalingFactor({_defaultScalingFactor: 1});
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenDefaultScalingFactorIsHigherThanMaxScalingFactorCap() external whenCallerIsFeeManager {
    uint256 _higher = dynamicSwapFeeHook.MAX_SCALING_FACTOR() + 1;

    // It should revert with "ISF"
    vm.expectRevert(bytes('ISF'));
    dynamicSwapFeeHook.setDefaultScalingFactor(_higher);
  }

  function test_WhenDefaultScalingFactorIsLessThanMaxScalingFactorCap(uint256 _newScalingFactor)
    external
    whenCallerIsFeeManager
  {
    _newScalingFactor = bound(_newScalingFactor, 1, dynamicSwapFeeHook.MAX_SCALING_FACTOR());

    // It should set default scaling factor
    // It should emit a {DefaultScalingFactorSet} event

    vm.expectEmit();
    emit IDynamicSwapFeeHook.DefaultScalingFactorSet(_newScalingFactor);
    dynamicSwapFeeHook.setDefaultScalingFactor(_newScalingFactor);

    assertEq(dynamicSwapFeeHook.defaultScalingFactor(), _newScalingFactor);
  }
}
