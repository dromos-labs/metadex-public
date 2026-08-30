// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDynamicSwapFeeHook, ISwapHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';

import {DynamicSwapFeeHook} from 'V3/hooks/dynamic/DynamicSwapFeeHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHook is UnitDynamicSwapFeeHookBase {
  function test_InitialState() public view {
    assertEq(dynamicSwapFeeHook.MAX_BASE_FEE(), 30_000);
    assertEq(dynamicSwapFeeHook.MAX_FEE_CAP(), 50_000);
    assertEq(dynamicSwapFeeHook.MAX_SCALING_FACTOR(), 1e18);
    assertEq(dynamicSwapFeeHook.defaultScalingFactor(), 100 * dynamicSwapFeeHook.SCALING_PRECISION());
    assertEq(dynamicSwapFeeHook.defaultFeeCap(), 20_000);
    assertEqUint(dynamicSwapFeeHook.MIN_SECONDS_AGO(), 1);
    assertEqUint(dynamicSwapFeeHook.MAX_SECONDS_AGO(), 65_535);
    assertEq(address(dynamicSwapFeeHook.FACTORY()), clFactory);
    assertEqUint(dynamicSwapFeeHook.secondsAgo(), 600);
  }

  function test_RevertIf_DefaultFeeCapIsHigherThanMaxFeeCap() public {
    vm.expectRevert(bytes('MFC'));
    new DynamicSwapFeeHook({
      _factory: clFactory, _defaultScalingFactor: 1000, _defaultFeeCap: 50_001, _pools: _pools, _fees: _fees
    });
  }

  function test_RevertIf_DefaultFeeCapIsZero() public {
    vm.expectRevert(bytes('FC0'));
    new DynamicSwapFeeHook({
      _factory: clFactory, _defaultScalingFactor: 1000, _defaultFeeCap: 0, _pools: _pools, _fees: _fees
    });
  }

  function test_RevertIf_DefaultScalingFactorIsHigherThanMaxScalingFactorCap() public {
    vm.expectRevert(bytes('ISF'));
    new DynamicSwapFeeHook({
      _factory: clFactory, _defaultScalingFactor: 1e18 + 1, _defaultFeeCap: 20_000, _pools: _pools, _fees: _fees
    });
  }

  function test_RevertIf_FactoryIsZeroAddress() public {
    vm.expectRevert(bytes('FZA'));
    new DynamicSwapFeeHook({
      _factory: address(0), _defaultScalingFactor: 1e18, _defaultFeeCap: 20_000, _pools: _pools, _fees: _fees
    });
  }

  function test_DeployEmitsEvents() public {
    vm.expectEmit();
    emit IDynamicSwapFeeHook.DefaultScalingFactorSet(1e18);

    vm.expectEmit();
    emit IDynamicSwapFeeHook.DefaultFeeCapSet(50_000);

    vm.expectEmit();
    emit IDynamicSwapFeeHook.CustomFeeSet(pool, 1000);

    address[] memory _pools = new address[](1);
    _pools[0] = pool;

    uint24[] memory _fees = new uint24[](1);
    _fees[0] = 1000;

    _mockAndExpectIsPool(pool, true);

    new DynamicSwapFeeHook({
      _factory: clFactory, _defaultScalingFactor: 1e18, _defaultFeeCap: 50_000, _pools: _pools, _fees: _fees
    });
  }

  /*////////////////////////////////////////////////////////////
                              GETTERS
  ////////////////////////////////////////////////////////////*/

  function test_GetAfterSwapFee() external view {
    ISwapHook.SwapParams memory _swapParams;
    ISwapHook.AfterSwapParams memory _afterSwapParams;

    assertEq(dynamicSwapFeeHook.getAfterSwapFee(pool, _swapParams, _afterSwapParams), 0);
  }

  function test_GetFlashFee(uint256 _baseFee) external {
    _baseFee = bound(_baseFee, 1, mockDynamicSwapFeeHook.MAX_BASE_FEE());
    _setBaseFee(address(dynamicSwapFeeHook), pool, uint24(_baseFee));

    ISwapHook.FlashParams memory _flashParams;

    assertEq(uint256(dynamicSwapFeeHook.getFlashFee(pool, _flashParams)), _baseFee);
  }
}
