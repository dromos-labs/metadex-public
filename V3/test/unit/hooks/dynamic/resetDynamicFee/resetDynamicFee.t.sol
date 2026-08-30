// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookResetDynamicFee is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.resetDynamicFee(address(0));
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenThePoolDoesntExist() external whenCallerIsFeeManager {
    // It should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(address(0), false);
    dynamicSwapFeeHook.resetDynamicFee(address(0));
  }

  modifier whenPoolExists() {
    _mockAndExpectIsPool(pool, true);
    _;
  }

  function test_WhenThePoolExists() external whenCallerIsFeeManager whenPoolExists {
    // It should set the fee cap and the scaling factor to 0
    // It should disable the initial fee
    // It should set the initial fee to 0
    // It should emit a {DynamicFeeReset} event

    // Set initial fee before reset to verify it gets cleared
    dynamicSwapFeeHook.setInitialFee(pool, 1000);
    // Set base fee to verify it is unchanged
    dynamicSwapFeeHook.setCustomFee(pool, 1000);

    vm.expectEmit();
    emit IDynamicSwapFeeHook.DynamicFeeReset(pool);

    dynamicSwapFeeHook.resetDynamicFee(pool);

    (uint24 _baseFee, uint24 _feeCap, uint64 _scalingFactor, bool _initialFeeEnabled, uint24 _initialFee) =
      dynamicSwapFeeHook.dynamicFeeConfig(pool);

    // should be unchanged
    assertEq(_baseFee, 1000);
    assertEq(_feeCap, 0);
    assertEq(_scalingFactor, 0);
    assertEq(_initialFeeEnabled, false);
    assertEqUint(_initialFee, 0);
  }
}
