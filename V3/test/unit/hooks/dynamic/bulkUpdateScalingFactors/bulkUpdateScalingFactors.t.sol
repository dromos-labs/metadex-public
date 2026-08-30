// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookBulkUpdateScalingFactors is UnitDynamicSwapFeeHookBase {
  uint64 public scalingFactor1 = 1e5;
  uint64 public scalingFactor2 = 100 * 1e6;
  uint64 public scalingFactor3 = 1e18;

  uint64[] internal _scalingFactors;

  function test_WhenCallerIsNotFeeManager() external {
    // It should revert with "NFM"
    vm.expectRevert(bytes('NFM'));

    _mockAndExpectSwapFeeManager(address(1));
    vm.startPrank(caller);
    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);
  }

  modifier whenCallerIsFeeManager() {
    _mockAndExpectSwapFeeManager(caller);
    vm.startPrank(caller);
    _;
    vm.stopPrank();
  }

  function test_WhenPoolsArrayAndScalingFactorsArrayAreNotTheSameLength() external whenCallerIsFeeManager {
    // It should revert with "LMM"
    _pools.push(address(1));
    _pools.push(address(2));
    _scalingFactors.push(scalingFactor1);

    vm.expectRevert(bytes('LMM'));
    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);
  }

  modifier whenPoolsArrayAndScalingFactorsArrayAreTheSameLength() {
    _pools.push(pool1);
    _pools.push(pool2);
    _pools.push(pool3);

    _scalingFactors.push(scalingFactor1);
    _scalingFactors.push(scalingFactor2);
    _scalingFactors.push(scalingFactor3);
    _;
  }

  function test_WhenOneOfThePoolsIsInvalid()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndScalingFactorsArrayAreTheSameLength
  {
    // It should revert
    vm.expectRevert(bytes('PNP'));
    _mockAndExpectIsPool(_pools[0], false);
    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);
  }

  modifier whenAllPoolsAreValid() {
    _mockAndExpectIsPool(pool1, true);
    _mockAndExpectIsPool(pool2, true);
    _mockAndExpectIsPool(pool3, true);
    _;
  }

  function test_WhenOneOfThePoolsFeeCapIsNotSet()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndScalingFactorsArrayAreTheSameLength
  {
    _mockAndExpectIsPool(pool1, true);
    // It should revert with "ISF"
    vm.expectRevert(bytes('ISF'));
    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);
  }

  modifier whenAllThePoolsHaveASetFeeCap() {
    for (uint256 _i; _i < _pools.length; ++_i) {
      _setFeeCap(address(dynamicSwapFeeHook), _pools[_i], 50_000);
    }
    _;
  }

  function test_WhenOneOfScalingFactorIsBiggerThanMaxScalingFactor()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndScalingFactorsArrayAreTheSameLength
    whenAllThePoolsHaveASetFeeCap
  {
    _mockAndExpectIsPool(pool1, true);

    // It should revert with "ISF"
    _scalingFactors[0] = uint64(dynamicSwapFeeHook.MAX_SCALING_FACTOR() + 1);

    vm.expectRevert(bytes('ISF'));
    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);
  }

  function test_WhenAllTheScalingFactorsAreBelowMaxScalingFactor()
    external
    whenCallerIsFeeManager
    whenPoolsArrayAndScalingFactorsArrayAreTheSameLength
    whenAllPoolsAreValid
    whenAllThePoolsHaveASetFeeCap
  {
    // It should update the scaling factor for all the pools
    // It should emit a {ScalingFactorSet} event for all the pools

    for (uint256 _i; _i < _pools.length; ++_i) {
      vm.expectEmit();
      emit IDynamicSwapFeeHook.ScalingFactorSet(_pools[_i], _scalingFactors[_i]);
    }

    dynamicSwapFeeHook.bulkUpdateScalingFactors(_pools, _scalingFactors);

    (,, uint64 scalingFactor,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[0]);
    assertEq(scalingFactor, scalingFactor1);

    (,, scalingFactor,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[1]);
    assertEq(scalingFactor, scalingFactor2);

    (,, scalingFactor,,) = dynamicSwapFeeHook.dynamicFeeConfig(_pools[2]);
    assertEq(scalingFactor, scalingFactor3);
  }
}
