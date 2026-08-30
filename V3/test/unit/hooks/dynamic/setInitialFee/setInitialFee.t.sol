// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetInitialFee is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // it should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setInitialFee({_pool: pool, _fee: 1000});
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenPoolDoesNotExist() external whenCallerIsFeeManager {
    // it should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(address(0), false);
    dynamicSwapFeeHook.setInitialFee(address(0), 1000);
  }

  modifier whenPoolExists() {
    _mockAndExpectIsPool(pool, true);
    _;
  }

  function test_WhenFeeExceedsMAX_FEE_CAPAndIsNotZERO_FEE_INDICATOR() external whenCallerIsFeeManager whenPoolExists {
    uint24 _higher = uint24(dynamicSwapFeeHook.MAX_FEE_CAP() + 1);

    // it should revert with "MIF"
    vm.expectRevert(bytes('MIF'));
    dynamicSwapFeeHook.setInitialFee(pool, _higher);
  }

  function test_WhenFeeIsValid(uint24 _initialFee) external whenCallerIsFeeManager whenPoolExists {
    _initialFee = uint24(bound(_initialFee, 0, dynamicSwapFeeHook.MAX_FEE_CAP()));

    // it should set initialFeeEnabled to true
    // it should set initialFee
    // it should emit an {InitialFeeSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.InitialFeeSet(pool, _initialFee);
    dynamicSwapFeeHook.setInitialFee(pool, _initialFee);

    (,,, bool _initialFeeEnabled, uint24 _initFee) = dynamicSwapFeeHook.dynamicFeeConfig(pool);
    assertTrue(_initialFeeEnabled);
    assertEq(_initFee, _initialFee);
  }
}
