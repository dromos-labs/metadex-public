// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {ISwapHook} from 'V3/interfaces/hooks/ISwapHook.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {ICLFactory} from 'V3/interfaces/factories/ICLFactory.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHookAfterSwap is UnitDynamicSwapFeeHookBase {
  using FixedPointMathLib for uint256;

  int256 internal constant _AMOUNT_SPEC_FLOOR = 1e6; // to avoid pips rounding to zero.
  uint24 internal constant _PIPS = 1e6;

  function test_WhenCallerIsntPool(address _caller) external {
    ISwapHook.SwapParams memory _swapParams;
    ISwapHook.AfterSwapParams memory _afterSwapParams;

    // it reverts with CNP
    vm.expectRevert(bytes('CNP'));

    _mockAndExpectIsPool(_caller, false);

    vm.prank(_caller);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  modifier whenCallerIsPool() {
    _mockAndExpectIsPool(pool, true);
    vm.startPrank(pool);
    _;
    vm.stopPrank();
  }

  function test_WhenClPoolTapeIsAddressZero() external whenCallerIsPool {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.clPoolTape.selector);
    vm.mockCall(clFactory, 0, _data, abi.encode(address(0)));
    vm.expectCall(clFactory, _data);

    ISwapHook.SwapParams memory _swapParams;
    ISwapHook.AfterSwapParams memory _afterSwapParams;

    // it returns
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  modifier whenClPoolTapeIsntAddressZero() {
    _mockAndExpectCLPoolTape();
    _;
  }

  modifier whenSwapIsZeroForOne(ISwapHook.SwapParams memory _swapParams) {
    _swapParams.zeroForOne = true;
    _;
  }

  modifier whenSwapIsExactInput() {
    _;
  }

  function test_WhenSwapIsExactInput(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    // it passes volume0 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume0 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    // it passes volume1 as amountCalculated
    uint256 _volume1 = uint256(-_afterSwapParams.amountCalculated);

    // it passes fee0 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume0, _afterSwapParams.fee, _PIPS));

    // it passes fee1 as 0
    // it passes tick as afterSwapParams.tick
    // it calls record
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: _fee,
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenMevFeeIsGt0(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) whenSwapIsExactInput {
    _dynamicFee = uint24(bound(_dynamicFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP() - 1));

    _afterSwapParams.fee =
      uint24(bound(uint256(_afterSwapParams.fee), _dynamicFee + 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    // it passes volume0 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume0 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    uint256 _volume1 = uint256(-_afterSwapParams.amountCalculated);

    (uint256 _feeAmount, uint256 _mevFeeAmount) = (0, 0);
    uint24 _expectedMevFee = _afterSwapParams.fee - _dynamicFee;

    if (_expectedMevFee != 0) {
      _feeAmount = _volume0.mulDivUp(_dynamicFee, MAX_PIPS);
      _mevFeeAmount = _volume0.mulDivUp(_expectedMevFee, MAX_PIPS);
    }

    // it passes mevFee0 as mev fee amount
    // it passes mevFee1 as 0
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: uint128(_feeAmount + _mevFeeAmount),
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: uint128(_mevFeeAmount),
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenToxic(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) whenSwapIsExactInput {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    // it passes volume0 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume0 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    // it passes volume1 as amountCalculated
    uint256 _volume1 = uint256(-_afterSwapParams.amountCalculated);

    // it passes fee0 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume0, _afterSwapParams.fee, MAX_PIPS));

    // it passes mevVolume0 as volume0
    // it passes mevVolume1 as volume1
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: _fee,
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: uint128(_volume0),
        mevVolume1: uint128(_volume1),
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, true);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  modifier whenSwapIsExactOutput() {
    _;
  }

  function test_WhenSwapIsExactOutput(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    // it passes volume0 as amountCalculated
    uint256 _volume0 = uint256(_afterSwapParams.amountCalculated);

    // it passes volume1 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume1 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));

    // it passes fee0 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume0, _afterSwapParams.fee, _PIPS));

    // it passes fee1 as 0
    // it passes tick as afterSwapParams.tick
    // it calls record
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: _fee,
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenMevFeeIsGt0_(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) whenSwapIsExactOutput {
    _dynamicFee = uint24(bound(_dynamicFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP() - 1));

    _afterSwapParams.fee =
      uint24(bound(uint256(_afterSwapParams.fee), _dynamicFee + 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    uint256 _volume0 = uint256(_afterSwapParams.amountCalculated);

    uint256 _volume1 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));

    (uint256 _feeAmount, uint256 _mevFeeAmount) = (0, 0);
    uint24 _expectedMevFee = _afterSwapParams.fee - _dynamicFee;

    if (_expectedMevFee != 0) {
      _feeAmount = _volume0.mulDivUp(_dynamicFee, MAX_PIPS);
      _mevFeeAmount = _volume0.mulDivUp(_expectedMevFee, MAX_PIPS);
    }

    // it passes mevFee0 as mev fee amount
    // it passes mevFee1 as 0
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: uint128(_feeAmount + _mevFeeAmount),
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: uint128(_mevFeeAmount),
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenDynamicFeeIsGtAfterSwapFee(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) whenSwapIsExactOutput {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _dynamicFee = uint24(bound(_dynamicFee, _afterSwapParams.fee + 1, type(uint24).max));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    uint256 _volume0 = uint256(_afterSwapParams.amountCalculated);
    uint256 _volume1 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume0, _afterSwapParams.fee, _PIPS));

    // it passes mevFee0 as 0
    // it passes mevFee1 as 0
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: _fee,
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    // Stores dynamic fee > afterSwapParams.fee => afterSwapParams.fee is used.
    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenToxic_(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsZeroForOne(_swapParams) whenSwapIsExactOutput {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    // it passes volume0 as amountCalculated
    uint256 _volume0 = uint256(_afterSwapParams.amountCalculated);

    // it passes volume1 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume1 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));

    // it passes fee0 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume0, _afterSwapParams.fee, _PIPS));

    // it passes mevVolume0 as volume0
    // it passes mevVolume1 as volume1
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: _fee,
        fee1: 0,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: uint128(_volume0),
        mevVolume1: uint128(_volume1),
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, true);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  modifier whenSwapIsOneForZero(ISwapHook.SwapParams memory _swapParams) {
    _swapParams.zeroForOne = false;
    _;
  }

  modifier whenSwapIsExactInput_() {
    _;
  }

  function test_WhenSwapIsExactInput_(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    // it passes volume0 as amountCalculated
    uint256 _volume0 = uint256(-_afterSwapParams.amountCalculated);

    // it passes volume1 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume1 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);

    // it passes fee1 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it calls record
    // it passes fee0 as 0
    // it passes tick as afterSwapParams.tick
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenMevFeeIsGt0__(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactInput_ {
    _dynamicFee = uint24(bound(_dynamicFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP() - 1));

    _afterSwapParams.fee =
      uint24(bound(uint256(_afterSwapParams.fee), _dynamicFee + 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    uint256 _volume0 = uint256(-_afterSwapParams.amountCalculated);

    uint256 _volume1 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);

    (uint256 _feeAmount, uint256 _mevFeeAmount) = (0, 0);
    uint24 _expectedMevFee = _afterSwapParams.fee - _dynamicFee;

    if (_expectedMevFee != 0) {
      _feeAmount = _volume1.mulDivUp(_dynamicFee, MAX_PIPS);
      _mevFeeAmount = _volume1.mulDivUp(_expectedMevFee, MAX_PIPS);
    }

    // it passes mevFee0 as 0
    // it passes mevFee1 as mev fee amount
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: uint128(_feeAmount + _mevFeeAmount),
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: uint128(_mevFeeAmount),
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenDynamicFeeIsGtAfterSwapFee_(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactInput_ {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _dynamicFee = uint24(bound(_dynamicFee, _afterSwapParams.fee + 1, type(uint24).max));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    uint256 _volume0 = uint256(-_afterSwapParams.amountCalculated);
    uint256 _volume1 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it passes mevFee0 as 0
    // it passes mevFee1 as 0
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    // Stores dynamic fee > afterSwapParams.fee => afterSwapParams.fee is used.
    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenToxic__(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactInput_ {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified =
      bound(_swapParams.amountSpecified, _AMOUNT_SPEC_FLOOR, type(int256).max / int256(uint256(_afterSwapParams.fee)));
    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, 0, _swapParams.amountSpecified);
    _afterSwapParams.amountCalculated = bound(_afterSwapParams.amountCalculated, type(int256).min, -1);

    if (_afterSwapParams.amountCalculated == type(int256).min) {
      _afterSwapParams.amountCalculated += 1;
    }

    uint256 _volume0 = uint256(-_afterSwapParams.amountCalculated);
    uint256 _volume1 = uint256(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining);
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it passes mevVolume0 as volume0
    // it passes mevVolume1 as volume1
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: uint128(_volume0),
        mevVolume1: uint128(_volume1),
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, true);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  modifier whenSwapIsExactOutput_() {
    _;
  }

  function test_WhenSwapIsExactOutput_(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    // it passes volume0 as diff between amountSpecified and amountSpecifiedRemaining
    uint256 _volume0 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));

    // it passes volume1 as amountCalculated
    uint256 _volume1 = uint256(_afterSwapParams.amountCalculated);

    // it passes fee1 as fee from input amount
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it calls record
    // it passes fee0 as 0
    // it passes tick as afterSwapParams.tick

    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenMevFeeIsGt0___(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactOutput_ {
    _dynamicFee = uint24(bound(_dynamicFee, 1, mockDynamicSwapFeeHook.MAX_FEE_CAP() - 1));

    _afterSwapParams.fee =
      uint24(bound(uint256(_afterSwapParams.fee), _dynamicFee + 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    uint256 _volume0 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));
    uint256 _volume1 = uint256(_afterSwapParams.amountCalculated);

    (uint256 _feeAmount, uint256 _mevFeeAmount) = (0, 0);
    uint24 _expectedMevFee = _afterSwapParams.fee - _dynamicFee;

    if (_expectedMevFee != 0) {
      _feeAmount = _volume1.mulDivUp(_dynamicFee, MAX_PIPS);
      _mevFeeAmount = _volume1.mulDivUp(_expectedMevFee, MAX_PIPS);
    }

    // it passes mevFee0 as 0
    // it passes mevFee1 as mev fee amount
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: uint128(_feeAmount + _mevFeeAmount),
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: uint128(_mevFeeAmount),
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenDynamicFeeIsGtAfterSwapFee__(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams,
    uint24 _dynamicFee
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactOutput_ {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _dynamicFee = uint24(bound(_dynamicFee, _afterSwapParams.fee + 1, type(uint24).max));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    uint256 _volume0 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));
    uint256 _volume1 = uint256(_afterSwapParams.amountCalculated);
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it passes mevFee0 as 0
    // it passes mevFee1 as 0
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: 0,
        mevVolume1: 0,
        tick: _swapParams.tick
      })
    );

    // Stores dynamic fee > afterSwapParams.fee => afterSwapParams.fee is used.
    mockDynamicSwapFeeHook.tstoreMevData(pool, _dynamicFee, false);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }

  function test_WhenToxic___(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external whenCallerIsPool whenClPoolTapeIsntAddressZero whenSwapIsOneForZero(_swapParams) whenSwapIsExactOutput_ {
    _afterSwapParams.fee = uint24(bound(uint256(_afterSwapParams.fee), 1, mockDynamicSwapFeeHook.MAX_FEE_CAP()));

    _swapParams.amountSpecified = bound(_swapParams.amountSpecified, type(int256).min, -1);

    if (_swapParams.amountSpecified == type(int256).min) {
      _swapParams.amountSpecified += 1;
    }

    _afterSwapParams.amountSpecifiedRemaining =
      bound(_afterSwapParams.amountSpecifiedRemaining, _swapParams.amountSpecified, 0);
    _afterSwapParams.amountCalculated =
      bound(_afterSwapParams.amountCalculated, 1, type(int256).max / int256(uint256(_afterSwapParams.fee)));

    uint256 _volume0 = uint256(-(_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining));
    uint256 _volume1 = uint256(_afterSwapParams.amountCalculated);
    uint128 _fee = uint128(FixedPointMathLib.mulDivUp(_volume1, _afterSwapParams.fee, _PIPS));

    // it passes mevVolume0 as volume0
    // it passes mevVolume1 as volume1
    _mockAndExpectRecord(
      pool,
      ICLPoolTape.CLPoolTapeData({
        fee0: 0,
        fee1: _fee,
        volume0: uint128(_volume0),
        volume1: uint128(_volume1),
        mevFee0: 0,
        mevFee1: 0,
        mevVolume0: uint128(_volume0),
        mevVolume1: uint128(_volume1),
        tick: _swapParams.tick
      })
    );

    mockDynamicSwapFeeHook.tstoreMevData(pool, _afterSwapParams.fee, true);
    mockDynamicSwapFeeHook.afterSwap(_swapParams, _afterSwapParams);
  }
}
