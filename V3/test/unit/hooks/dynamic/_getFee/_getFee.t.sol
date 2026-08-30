// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHook_GetFee is UnitDynamicSwapFeeHookBase {
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

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFee(pool, caller);

    /// @dev This branch will be triggered
    (uint24 _firstFeeToUse, uint256 _firstFeeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it computes and returns the first swap fee to use and store
    assertEqUint(_feeToUse, _firstFeeToUse);
    assertEq(_feeToStore, _firstFeeToStore);
  }

  function test_WhenFirstTxFeeIsNotZero(
    address _pool,
    uint256 _firstTxInitialFee,
    uint256 _zeroFeeProbability
  ) external {
    _firstTxInitialFee = bound(_firstTxInitialFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());
    _zeroFeeProbability = bound(_zeroFeeProbability, 0, 100);

    // Numbers from [0,100] don't have an equal probability here,
    // but it's a workaround to trigger occasional 0 fee usage.
    if (_zeroFeeProbability > 95) _firstTxInitialFee = dynamicSwapFeeHook.ZERO_FEE_INDICATOR();

    mockDynamicSwapFeeHook.tstoreFirstTxInitialFee(_pool, _firstTxInitialFee);
    // block fee isn't used, just need to bypass the first if branch.
    _setBlockFee(address(mockDynamicSwapFeeHook), _pool, block.number, 1);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFee(_pool, caller);

    // it returns the intial fee
    if (_firstTxInitialFee == dynamicSwapFeeHook.ZERO_FEE_INDICATOR()) assertEq(uint256(_feeToUse), 0);
    else assertEq(uint256(_feeToUse), _firstTxInitialFee);

    assertEq(_feeToStore, 0);
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

    if (_blockFee == mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()) {
      _blockFee++;
    }

    _setBlockFee(address(mockDynamicSwapFeeHook), _pool, _blockNumber, _blockFee);
    vm.roll(_blockNumber);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFee(_pool, caller);

    // it returns (block fee, 0)
    assertEq(uint256(_feeToUse), _blockFee.mulDivUp(1e6 - _discount, 1e6));
    assertEq(_feeToStore, 0);
  }

  function test_WhenBlockFeeIsZERO_FEE_INDICATOR(address _pool, uint256 _blockNumber) external {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);

    _setBlockFee(address(mockDynamicSwapFeeHook), _pool, _blockNumber, mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR());

    vm.roll(_blockNumber);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFee(_pool, caller);

    // it returns (0, 0)
    assertEq(uint256(_feeToUse), 0);
    assertEq(_feeToStore, 0);
  }
}
