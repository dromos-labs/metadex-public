// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {ISwapHook} from 'V3/interfaces/hooks/ISwapHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookGetBeforeSwapFee is UnitDynamicSwapFeeHookBase {
  using FixedPointMathLib for uint256;

  function test_WhenBlockFeeIsZero(uint256 _baseFee, uint256 _blockNumber, uint256 _discount) external {
    _baseFee = bound(_baseFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP());
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);
    _discount = bound(_discount, 1, 1e6);

    _setBaseFee(address(mockDynamicSwapFeeHook), pool, uint24(_baseFee));
    _mockAndExpectSlot0(pool, 0, 0);
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_discount));

    vm.roll(_blockNumber);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    vm.prank(caller);
    uint24 _fee = mockDynamicSwapFeeHook.getBeforeSwapFee(pool, _swapParams);

    /// @dev This branch will be triggered
    (uint24 _firstFeeToUse,) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it computes and returns the first flash fee to use
    assertEqUint(_fee, _firstFeeToUse);
  }

  function test_WhenFirstTxInitialFeeIsNotZero(uint256 _firstTxInitialFee, uint256 _zeroFeeProbability) external {
    _firstTxInitialFee = bound(_firstTxInitialFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());
    _zeroFeeProbability = bound(_zeroFeeProbability, 0, 100);

    // Numbers from [0,100] don't have an equal probability here,
    // but it's a workaround to trigger occasional 0 fee usage.
    if (_zeroFeeProbability > 95) _firstTxInitialFee = dynamicSwapFeeHook.ZERO_FEE_INDICATOR();

    mockDynamicSwapFeeHook.tstoreFirstTxInitialFee(pool, _firstTxInitialFee);
    // block fee isn't used, just need to bypass the first if branch.
    _setBlockFee(address(mockDynamicSwapFeeHook), pool, block.number, 1);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    vm.prank(caller);
    uint24 _fee = mockDynamicSwapFeeHook.getBeforeSwapFee(pool, _swapParams);

    // it returns first tx initial fee
    if (_firstTxInitialFee == mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()) assertEq(uint256(_fee), 0);
    else assertEq(uint256(_fee), _firstTxInitialFee);
  }

  function test_WhenBlockFeeIsNotZERO_FEE_INDICATOR(
    address _pool,
    uint256 _blockNumber,
    uint256 _blockFee,
    uint256 _discount
  ) external {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);
    _blockFee = bound(_blockFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());
    _discount = bound(_discount, 1, 1e6);

    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(_pool, caller, uint24(_discount));

    if (_blockFee == dynamicSwapFeeHook.ZERO_FEE_INDICATOR()) {
      _blockFee++;
    }

    _setBlockFee(address(dynamicSwapFeeHook), _pool, _blockNumber, _blockFee);
    vm.roll(_blockNumber);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    vm.prank(caller);
    uint24 _fee = dynamicSwapFeeHook.getBeforeSwapFee(_pool, _swapParams);

    // it returns block fee
    assertEq(uint256(_fee), _blockFee.mulDivUp(1e6 - _discount, 1e6));
  }

  function test_WhenBlockFeeIsZERO_FEE_INDICATOR(address _pool, uint256 _blockNumber) external {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);

    _setBlockFee(address(dynamicSwapFeeHook), _pool, _blockNumber, dynamicSwapFeeHook.ZERO_FEE_INDICATOR());

    vm.roll(_blockNumber);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    vm.prank(caller);
    uint24 _fee = dynamicSwapFeeHook.getBeforeSwapFee(_pool, _swapParams);

    // it returns 0
    assertEq(uint256(_fee), 0);
  }
}
