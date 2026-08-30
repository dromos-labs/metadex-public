// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookBulkUpdateFees is UnitDynamicSwapFeeHookBase {
  uint24 public fee1 = 1000;
  uint24 public fee2 = 1111;
  uint24 public fee3 = 420;

  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(0));
    vm.prank(caller);
    dynamicSwapFeeHook.bulkUpdateFees(_pools, _fees);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenPoolsArrayAndFeesArrayAreNotTheSameLength() external whenCallerIsFeeManager {
    // It should revert with "LMM"
    _pools.push(address(1));
    _pools.push(address(2));
    _fees.push(1);

    vm.expectRevert(bytes('LMM'));
    dynamicSwapFeeHook.bulkUpdateFees(_pools, _fees);
  }

  modifier whenPoolsArrayAndFeesArrayAreTheSameLength() {
    _pools.push(pool1);
    _pools.push(pool2);
    _pools.push(pool3);

    _fees.push(fee1);
    _fees.push(fee2);
    _fees.push(fee3);
    _;
  }

  function test_WhenOneOfTheFeeIsBiggerThanMaxFee()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeesArrayAreTheSameLength
  {
    // It should revert with "MBF"
    _fees[0] = uint24(dynamicSwapFeeHook.MAX_BASE_FEE() + 1);
    vm.expectRevert(bytes('MBF'));
    dynamicSwapFeeHook.bulkUpdateFees(_pools, _fees);
  }

  modifier whenAllTheFeesAreSmallerThanMaxFee() {
    _;
  }

  function test_WhenThePoolIsInvalid()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeesArrayAreTheSameLength
    whenAllTheFeesAreSmallerThanMaxFee
  {
    // It should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(_pools[0], false);
    dynamicSwapFeeHook.bulkUpdateFees(_pools, _fees);
  }

  function test_WhenThePoolIsValid()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeesArrayAreTheSameLength
    whenAllTheFeesAreSmallerThanMaxFee
  {
    _mockAndExpectIsPool(pool1, true);
    _mockAndExpectIsPool(pool2, true);
    _mockAndExpectIsPool(pool3, true);

    // It should update the fee for the pool
    // It should emit a {CustomFeeSet} event for all three pools
    for (uint256 _i; _i < _pools.length; ++_i) {
      vm.expectEmit();
      emit IDynamicSwapFeeHook.CustomFeeSet(_pools[_i], _fees[_i]);
    }

    dynamicSwapFeeHook.bulkUpdateFees(_pools, _fees);

    assertEq(dynamicSwapFeeHook.customFee(_pools[0]), fee1);
    assertEq(dynamicSwapFeeHook.customFee(_pools[1]), fee2);
    assertEq(dynamicSwapFeeHook.customFee(_pools[2]), fee3);
  }
}
