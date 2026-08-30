// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetMevTaxModule is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // it should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.prank(caller);
    dynamicSwapFeeHook.setMevTaxModule(address(0));
  }

  function test_WhenCallerIsFeeManager(address _newMevTaxModule) external {
    _mockAndExpectSwapFeeManager(caller);

    // it should emit a {MevTaxModuleSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.MevTaxModuleSet(_newMevTaxModule);

    vm.prank(caller);
    dynamicSwapFeeHook.setMevTaxModule(_newMevTaxModule);

    // it should set the new mevTaxModule
    assertEq(address(dynamicSwapFeeHook.mevTaxModule()), _newMevTaxModule);
  }
}
