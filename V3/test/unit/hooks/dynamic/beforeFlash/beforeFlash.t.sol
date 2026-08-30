// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {ISwapHook} from 'V3/interfaces/hooks/ISwapHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookBeforeFlash is UnitDynamicSwapFeeHookBase {
  using FixedPointMathLib for uint256;

  int24 public constant TICK_SPACING_60 = 60;

  function test_WhenCallerIsntPool(address _addr) external {
    _mockAndExpectIsPool(_addr, false);

    ISwapHook.FlashParams memory _flashParams;

    // it reverts with CNP
    vm.expectRevert(bytes('CNP'));

    vm.prank(_addr);
    dynamicSwapFeeHook.beforeFlash(_flashParams);
  }

  modifier whenCallerIsPool() {
    _mockAndExpectIsPool(pool, true);
    vm.startPrank(pool);
    _;
    vm.stopPrank();
  }

  function test_WhenBaseFeeIsZERO_FEE_INDICATOR() external whenCallerIsPool {
    _setBaseFee(address(dynamicSwapFeeHook), pool, uint24(dynamicSwapFeeHook.ZERO_FEE_INDICATOR()));

    ISwapHook.FlashParams memory _flashParams;

    uint24 _fee = dynamicSwapFeeHook.beforeFlash(_flashParams);

    // it returns 0
    assertEq(uint256(_fee), 0);
  }

  function test_WhenBaseFeeIsZero(uint24 _tickSpacingFee) external whenCallerIsPool {
    _tickSpacingFee = uint24(bound(_tickSpacingFee, 1, mockDynamicSwapFeeHook.MAX_BASE_FEE()));

    _setBaseFee(address(dynamicSwapFeeHook), pool, 0);

    ISwapHook.FlashParams memory _flashParams;

    _mockAndExpectTickSpacing(pool, TICK_SPACING_60);
    _mockAndExpectTickSpacingToFee(TICK_SPACING_60, _tickSpacingFee);

    uint24 _fee = dynamicSwapFeeHook.beforeFlash(_flashParams);

    // it returns tick spacing fee
    assertEqUint(_fee, _tickSpacingFee);
  }

  function test_WhenBaseFeeIsNotZero(uint256 _baseFee) external whenCallerIsPool {
    _baseFee = bound(_baseFee, 1, mockDynamicSwapFeeHook.MAX_BASE_FEE());
    _setBaseFee(address(dynamicSwapFeeHook), pool, uint24(_baseFee));

    ISwapHook.FlashParams memory _flashParams;

    uint24 _fee = dynamicSwapFeeHook.beforeFlash(_flashParams);

    // it returns base fee
    assertEq(uint256(_fee), _baseFee);
  }
}
