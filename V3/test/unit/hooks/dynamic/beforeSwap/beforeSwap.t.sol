// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {ISwapHook} from 'V3/interfaces/hooks/ISwapHook.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookBeforeSwap is UnitDynamicSwapFeeHookBase {
  using FixedPointMathLib for uint256;

  function test_WhenCallerIsntPool(address _caller) external {
    _mockAndExpectIsPool(_caller, false);

    ISwapHook.SwapParams memory _swapParams;

    // it reverts with CNP
    vm.expectRevert(bytes('CNP'));

    vm.prank(_caller);
    dynamicSwapFeeHook.beforeSwap(_swapParams);
  }

  modifier whenCallerIsPool() {
    _mockAndExpectIsPool(pool, true);
    vm.startPrank(pool);
    _;
    vm.stopPrank();
  }

  modifier whenBlockFeeIsZero() {
    // it is zero by default.
    _;
  }

  function test_WhenInitialFeeIsEnabled(
    uint256 _baseFee,
    uint256 _initialFee,
    uint256 _zeroFeeProbability
  ) external whenCallerIsPool whenBlockFeeIsZero {
    _baseFee = bound(_baseFee, 1, mockDynamicSwapFeeHook.MAX_BASE_FEE());
    _initialFee = bound(_initialFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP());
    _zeroFeeProbability = bound(_zeroFeeProbability, 0, 100);

    // Numbers from [0,100] don't have an equal probability here,
    // but it's a workaround to trigger occasional 0 fee usage.
    if (_zeroFeeProbability > 95) _initialFee = mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR();

    _setBaseFee(address(mockDynamicSwapFeeHook), pool, uint24(_baseFee));
    _setInitialFeeEnabled(address(mockDynamicSwapFeeHook), pool, true);
    _setInitialFee(address(mockDynamicSwapFeeHook), pool, uint24(_initialFee));

    _mockAndExpectSlot0(pool, 0, 0);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    // Expected values
    (, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, _swapParams.caller);

    uint24 _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);

    if (_initialFee == mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()) {
      // it returns the initial fee
      assertEq(_fee, 0);
      // it stores the initial fee as first tx initial fee
      assertEq(mockDynamicSwapFeeHook.tloadFirstTxInitialFee(pool), mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR());
    } else {
      // it returns the initial fee
      assertEq(_fee, _initialFee);
      // it stores the initial fee as first tx initial fee
      assertEq(mockDynamicSwapFeeHook.tloadFirstTxInitialFee(pool), _initialFee);
    }

    // it stores the first swap fee as block fee
    uint256 _storedBlockFee = mockDynamicSwapFeeHook.blockFee(pool, block.number);
    assertEq(_storedBlockFee, _feeToStore);
  }

  function test_WhenInitialFeeIsNotEnabled(
    uint256 _baseFee,
    uint256 _discount
  ) external whenCallerIsPool whenBlockFeeIsZero {
    _baseFee = bound(_baseFee, 1, mockDynamicSwapFeeHook.MAX_BASE_FEE());
    _discount = bound(_discount, 1, 1e6);

    _setBaseFee(address(mockDynamicSwapFeeHook), pool, uint24(_baseFee));
    _mockAndExpectSlot0(pool, 0, 0);
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_discount));

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    // Expected values
    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, _swapParams.caller);

    uint24 _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);

    // it computes and returns the first swap fee
    assertEqUint(_fee, _feeToUse);

    // it stores the swap fee as block fee
    uint256 _storedBlockFee = mockDynamicSwapFeeHook.blockFee(pool, block.number);
    assertEq(_storedBlockFee, _feeToStore);
  }

  function test_WhenFirstTxInitialFeeIsNotZero(
    uint256 _firstTxInitialFee,
    uint256 _zeroFeeProbability,
    uint256 _blockFee
  ) external whenCallerIsPool {
    _firstTxInitialFee = bound(_firstTxInitialFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());
    _zeroFeeProbability = bound(_zeroFeeProbability, 0, 100);
    _blockFee = bound(_blockFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());

    // Numbers from [0,100] don't have an equal probability here,
    // but it's a workaround to trigger occasional 0 fee usage.
    if (_zeroFeeProbability > 95) _firstTxInitialFee = dynamicSwapFeeHook.ZERO_FEE_INDICATOR();

    uint256 _blockNumber = block.number;

    mockDynamicSwapFeeHook.tstoreFirstTxInitialFee(pool, _firstTxInitialFee);
    _setBlockFee(address(mockDynamicSwapFeeHook), pool, _blockNumber, _blockFee);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    uint24 _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);

    // it returns first tx initial fee
    if (_firstTxInitialFee == mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()) assertEq(uint256(_fee), 0);
    else assertEq(uint256(_fee), _firstTxInitialFee);

    // it doesn't update block fee
    uint256 _storedBlockFee = mockDynamicSwapFeeHook.blockFee(pool, block.number);
    assertEq(_storedBlockFee, _blockFee);

    /// @dev Calling it the 2nd time in the same tx in the same bock yields the same fee.
    _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);
    assertEq(_blockNumber, block.number); // ensure that we're in the same block.

    if (_firstTxInitialFee == mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()) assertEq(uint256(_fee), 0);
    else assertEq(uint256(_fee), _firstTxInitialFee);

    /// @dev Other pools do not use first tx init fee.
    vm.startPrank(caller);
    _mockAndExpectIsPool(caller, true);

    _setBlockFee(address(mockDynamicSwapFeeHook), caller, _blockNumber, _blockFee);
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(caller, caller, 0);

    _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);
    assertEq(_fee, _blockFee);

    vm.stopPrank();
  }

  function test_WhenBlockFeeIsNotZERO_FEE_INDICATOR(
    uint256 _blockNumber,
    uint256 _discount,
    uint256 _blockFee
  ) external whenCallerIsPool {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);
    _discount = bound(_discount, 1, 1e6);
    _blockFee = bound(_blockFee, 1, dynamicSwapFeeHook.MAX_FEE_CAP());

    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_discount));

    _setBlockFee(address(dynamicSwapFeeHook), pool, _blockNumber, _blockFee);
    vm.roll(_blockNumber);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    uint24 _fee = dynamicSwapFeeHook.beforeSwap(_swapParams);

    // it returns block fee
    assertEqUint(_fee, _blockFee.mulDivUp(1e6 - _discount, 1e6));

    // it doesn't update block fee
    uint256 _storedBlockFee = dynamicSwapFeeHook.blockFee(pool, _blockNumber);
    assertEq(_storedBlockFee, _blockFee);
  }

  function test_WhenBlockFeeIsZERO_FEE_INDICATOR(uint256 _blockNumber) external whenCallerIsPool {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);

    _setBlockFee(address(dynamicSwapFeeHook), pool, _blockNumber, dynamicSwapFeeHook.ZERO_FEE_INDICATOR());

    vm.roll(_blockNumber);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    uint24 _fee = dynamicSwapFeeHook.beforeSwap(_swapParams);

    // it returns 0
    assertEqUint(_fee, 0);

    // it doesn't update block fee
    uint256 _storedBlockFee = dynamicSwapFeeHook.blockFee(pool, _blockNumber);
    assertEq(_storedBlockFee, dynamicSwapFeeHook.ZERO_FEE_INDICATOR());
  }

  function test_WhenMevFeeIsGtZeroAndToxic(
    uint256 _blockNumber,
    uint256 _discount,
    uint256 _blockFee,
    uint256 _mevFee
  ) external whenCallerIsPool {
    _blockNumber = bound(_blockNumber, 1, type(uint64).max);
    _discount = bound(_discount, 1, 1e6);
    _blockFee = bound(_blockFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP());

    // MEV module has its own cap, so this one is somewhat artificial.
    _mevFee = bound(_mevFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP());

    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_discount));

    _setBlockFee(address(mockDynamicSwapFeeHook), pool, _blockNumber, _blockFee);
    vm.roll(_blockNumber);

    _setMevTaxModule(address(mockDynamicSwapFeeHook));
    _mockAndExpectGetMevTax(uint24(_mevFee), true);

    ISwapHook.SwapParams memory _swapParams;
    _swapParams.caller = caller;

    vm.record();

    uint24 _fee = mockDynamicSwapFeeHook.beforeSwap(_swapParams);

    /// @dev Sanity check that no SSTOREs were executed.
    (, bytes32[] memory _sstores) = vm.accesses(address(mockDynamicSwapFeeHook));
    assertEq(_sstores.length, 0);

    uint256 _paidFee = _blockFee.mulDivUp(1e6 - _discount, 1e6);

    // it stores dynamic fee and toxic in transient storage
    (uint24 _transientDynamicFee, bool _transientToxic) = mockDynamicSwapFeeHook.tloadMevData(pool);
    assertEq(_transientDynamicFee, _paidFee);
    assertEq(_transientToxic, true);

    // it returns the sum of mev fee and block fee
    assertEq(_fee, _mevFee + _paidFee);

    // it doesn't update block fee
    uint256 _storedBlockFee = mockDynamicSwapFeeHook.blockFee(pool, _blockNumber);
    assertEq(_storedBlockFee, _blockFee);
  }
}
