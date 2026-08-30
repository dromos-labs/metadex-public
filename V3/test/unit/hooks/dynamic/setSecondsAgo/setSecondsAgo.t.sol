// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookSetSecondsAgo is UnitDynamicSwapFeeHookBase {
  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.setSecondsAgo(0);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenSecondsAgoIsLessThanMinimumSecondsAgo() external whenCallerIsFeeManager {
    // It should revert with "ISA"
    vm.expectRevert(bytes('ISA'));
    dynamicSwapFeeHook.setSecondsAgo(0);
  }

  function test_WhenSecondsAgoIsHigherThanMaximumSecondsAgo() external whenCallerIsFeeManager {
    uint32 _higher = dynamicSwapFeeHook.MAX_SECONDS_AGO() + 1;

    // It should revert with "ISA"
    vm.expectRevert(bytes('ISA'));
    dynamicSwapFeeHook.setSecondsAgo(_higher);
  }

  function test_WhenSecondsAgoIsCorrectAmount(uint32 _secondsAgo) external whenCallerIsFeeManager {
    _secondsAgo = uint32(
      bound(
        uint256(_secondsAgo),
        uint256(dynamicSwapFeeHook.MIN_SECONDS_AGO()),
        uint256(dynamicSwapFeeHook.MAX_SECONDS_AGO()) - 1
      )
    );

    // It should set the new secondsAgo
    // It should emit a {SecondsAgoSet} event
    vm.expectEmit();
    emit IDynamicSwapFeeHook.SecondsAgoSet(_secondsAgo);
    dynamicSwapFeeHook.setSecondsAgo({_secondsAgo: _secondsAgo});

    assertEq(dynamicSwapFeeHook.secondsAgo(), _secondsAgo);
  }
}
