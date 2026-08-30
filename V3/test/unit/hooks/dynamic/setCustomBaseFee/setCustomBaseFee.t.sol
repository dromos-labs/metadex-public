// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetCustomBaseFee is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setCustomFee(address(0), 0);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenCustomFeeIsGtMaxBaseFeeAndNotZeroFeeIndicator() external whenCallerIsFeeManager {
    uint24 _higher = uint24(dynamicSwapFeeHook.MAX_BASE_FEE() + 1);

    // it should revert with "MBF"
    vm.expectRevert(bytes('MBF'));
    dynamicSwapFeeHook.setCustomFee(pool, _higher);
  }

  function test_WhenPoolIsInvalid() external whenCallerIsFeeManager {
    // it should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(pool, false);
    dynamicSwapFeeHook.setCustomFee(pool, 1);
  }

  modifier whenPoolIsValid() {
    _mockAndExpectIsPool(pool, true);
    _;
  }

  function test_WhenCustomFeeIsZeroFeeIndicator() external whenCallerIsFeeManager whenPoolIsValid {
    // it should emit CustomFeeSet
    vm.expectEmit();
    emit IDynamicSwapFeeHook.CustomFeeSet(pool, uint24(dynamicSwapFeeHook.ZERO_FEE_INDICATOR()));
    dynamicSwapFeeHook.setCustomFee(pool, uint24(dynamicSwapFeeHook.ZERO_FEE_INDICATOR()));

    (uint24 _baseFee,,,,) = dynamicSwapFeeHook.dynamicFeeConfig(pool);

    // it should set custom fee to zero fee indicator
    assertEq(_baseFee, dynamicSwapFeeHook.ZERO_FEE_INDICATOR());
  }

  function test_WhenCustomFeeIsNotZeroFeeIndicator(uint24 _newBaseFee) external whenCallerIsFeeManager whenPoolIsValid {
    _newBaseFee = uint24(bound(_newBaseFee, 1, dynamicSwapFeeHook.MAX_BASE_FEE()));

    // it should emit CustomFeeSet
    vm.expectEmit();
    emit IDynamicSwapFeeHook.CustomFeeSet(pool, _newBaseFee);
    dynamicSwapFeeHook.setCustomFee(pool, _newBaseFee);

    (uint24 _baseFee,,,,) = dynamicSwapFeeHook.dynamicFeeConfig(pool);

    // it should set custom fee
    assertEq(_baseFee, _newBaseFee);
  }
}
