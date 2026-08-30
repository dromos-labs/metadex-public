// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetFeeCap is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setFeeCap(address(0), 0);
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
    dynamicSwapFeeHook.setFeeCap(address(0), 1);
  }

  modifier whenPoolExists() {
    _mockAndExpectIsPool(pool, true);
    _;
  }

  function test_WhenFeeCapIs0() external whenCallerIsFeeManager whenPoolExists {
    // It should revert with "MFC"
    vm.expectRevert(bytes('FC0'));
    dynamicSwapFeeHook.setFeeCap(pool, 0);
  }

  function test_WhenFeeCapIsHigherThanMaxFee() external whenCallerIsFeeManager whenPoolExists {
    uint24 _higher = uint24(dynamicSwapFeeHook.MAX_FEE_CAP() + 1);

    // It should revert with "MFC"
    vm.expectRevert(bytes('MFC'));
    dynamicSwapFeeHook.setFeeCap(pool, _higher);
  }

  function test_WhenFeeCapIsBiggerThan0AndLessThanOrEqualToMaxFeeCap(uint24 _newFeeCap)
    external
    whenCallerIsFeeManager
    whenPoolExists
  {
    _newFeeCap = uint24(bound(_newFeeCap, 1, dynamicSwapFeeHook.MAX_FEE_CAP()));

    // It should set feeCap
    // It should emit a {FeeCapSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.FeeCapSet(pool, _newFeeCap);
    dynamicSwapFeeHook.setFeeCap(pool, _newFeeCap);

    (, uint24 _feeCap,,,) = dynamicSwapFeeHook.dynamicFeeConfig(pool);
    assertEq(_feeCap, _newFeeCap);
  }
}
