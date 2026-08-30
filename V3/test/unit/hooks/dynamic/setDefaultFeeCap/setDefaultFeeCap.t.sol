// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetDefaultFeeCap is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.prank(caller);
    dynamicSwapFeeHook.setDefaultFeeCap(0);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenDefaultFeeCapIsHigherThanMaxFeeCap() external whenCallerIsFeeManager {
    uint256 _higher = dynamicSwapFeeHook.MAX_FEE_CAP() + 1;
    // It should revert with "MFC"
    vm.expectRevert(bytes('MFC'));
    dynamicSwapFeeHook.setDefaultFeeCap(_higher);
  }

  modifier whenDefaultFeeCapIsLessThanOrEqualToMaxFeeCap() {
    _;
  }

  function test_WhenDefaultFeeCapIsZero()
    external
    whenCallerIsFeeManager
    whenDefaultFeeCapIsLessThanOrEqualToMaxFeeCap
  {
    // it should revert with "FC0"
    vm.expectRevert(bytes('FC0'));
    dynamicSwapFeeHook.setDefaultFeeCap(0);
  }

  function test_WhenDefaultFeeCapIsGtZero(uint256 _defaultFeeCap)
    external
    whenCallerIsFeeManager
    whenDefaultFeeCapIsLessThanOrEqualToMaxFeeCap
  {
    _defaultFeeCap = bound(_defaultFeeCap, 1, dynamicSwapFeeHook.MAX_FEE_CAP());

    // It should set defaultFeeCap
    // It should emit a {DefaultFeeCapSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.DefaultFeeCapSet(_defaultFeeCap);
    dynamicSwapFeeHook.setDefaultFeeCap(_defaultFeeCap);

    assertEq(dynamicSwapFeeHook.defaultFeeCap(), _defaultFeeCap);
  }
}
