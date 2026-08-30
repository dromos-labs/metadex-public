// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookBulkUpdateFeeCaps is UnitDynamicSwapFeeHookBase {
  uint24 public feeCap1 = 1;
  uint24 public feeCap2 = 1000;
  uint24 public feeCap3 = 50_000;

  uint24[] internal _feeCaps;

  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.bulkUpdateFeeCaps(_pools, _feeCaps);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenPoolsArrayAndFeeCapsArrayAreNotTheSameLength() external whenCallerIsFeeManager {
    // It should revert with "LMM"
    _pools.push(address(1));
    _pools.push(address(2));
    _feeCaps.push(feeCap1);

    vm.expectRevert(bytes('LMM'));
    dynamicSwapFeeHook.bulkUpdateFeeCaps(_pools, _feeCaps);
  }

  modifier whenPoolsArrayAndFeeCapsArrayAreTheSameLength() {
    _pools.push(pool1);
    _pools.push(pool2);
    _pools.push(pool3);

    _feeCaps.push(feeCap1);
    _feeCaps.push(feeCap2);
    _feeCaps.push(feeCap3);
    _;
  }

  function test_WhenOneOfThePoolsIsInvalid()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeeCapsArrayAreTheSameLength
  {
    // It should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(_pools[0], false);
    dynamicSwapFeeHook.bulkUpdateFeeCaps(_pools, _feeCaps);
  }

  modifier whenAllPoolsAreValid() {
    _mockAndExpectIsPool(pool1, true);
    _mockAndExpectIsPool(pool2, true);
    _mockAndExpectIsPool(pool3, true);
    _;
  }

  function test_WhenOneOfTheFeeCapIs0() external whenCallerIsFeeManager whenPoolsArrayAndFeeCapsArrayAreTheSameLength {
    _mockAndExpectIsPool(pool1, true);
    // It should revert with "FC0"
    _feeCaps[0] = 0;
    vm.expectRevert(bytes('FC0'));
    dynamicSwapFeeHook.bulkUpdateFeeCaps(_pools, _feeCaps);
  }

  function test_WhenOneOfTheFeeCapIsBiggerThanMaxFeeCap()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeeCapsArrayAreTheSameLength
  {
    _mockAndExpectIsPool(pool1, true);
    // It should revert with "MFC"
    _feeCaps[0] = uint24(dynamicSwapFeeHook.MAX_FEE_CAP() + 1);
    vm.expectRevert(bytes('MFC'));
    dynamicSwapFeeHook.bulkUpdateFeeCaps(_pools, _feeCaps);
  }

  function test_WhenAllTheFeeCapsAreWithinRange()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndFeeCapsArrayAreTheSameLength
    whenAllPoolsAreValid
  {
    // It should update the fee cap for all the pools
    // It should emit a {FeeCapSet} event for all the pools
    for (uint256 _i; _i < _pools.length; ++_i) {
      vm.expectEmit();
      emit IDynamicSwapFeeHook.FeeCapSet(_pools[_i], _feeCaps[_i]);
    }

    dynamicSwapFeeHook.bulkUpdateFeeCaps({_pools: _pools, _feeCaps: _feeCaps});

    (, uint24 _feeCap,,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[0]);
    assertEq(_feeCap, feeCap1);

    (, _feeCap,,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[1]);
    assertEq(_feeCap, feeCap2);

    (, _feeCap,,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[2]);
    assertEq(_feeCap, feeCap3);
  }
}
