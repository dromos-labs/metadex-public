// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {StableGetAmountBase} from 'V3-test/unit/pools/StablePool/StableGetAmountBase.sol';

contract UnitStablePoolGetAmountInWithTotalFee is StableGetAmountBase {
  /// @dev reserve cap values to prevent the `_getAmountIn` calculation from reverting
  uint256 internal constant _MIN_RESERVE = 1e20;
  uint256 internal constant _MAX_RESERVE = 1e27;

  /// @dev Keeps the grossed up amounts of two nearby fees distinct
  uint256 internal constant _MIN_AMOUNT_OUT = 10_000;

  function test_WhenTheRequestedOutputEqZero() external view {
    // it should return zero
    assertEq(_pool.getAmountInWithTotalFee(0, _token1), 0);
  }

  modifier whenTheRequestedOutputIsGtZero() {
    _;
  }

  function test_WhenTheRequestedOutputIsGteTheOutputReserve(
    uint256 _reserveOut,
    uint256 _reserveIn,
    uint256 _amountOut,
    bool _outIsToken0
  ) external whenTheRequestedOutputIsGtZero {
    _reserveOut = bound(_reserveOut, 1, type(uint256).max - 1);
    _reserveIn = bound(_reserveIn, _reserveOut + 1, type(uint256).max);
    _amountOut = bound(_amountOut, _reserveOut, _reserveIn - 1);
    (uint256 _reserve0, uint256 _reserve1) = _outIsToken0 ? (_reserveOut, _reserveIn) : (_reserveIn, _reserveOut);
    _seedReserves(address(_pool), _reserve0, _reserve1);

    // it should revert with InsufficientLiquidity
    vm.expectRevert(IPool.InsufficientLiquidity.selector);
    _pool.getAmountInWithTotalFee(_amountOut, _outIsToken0 ? _token0 : _token1);
  }

  modifier whenTheRequestedOutputIsLtTheOutputReserve() {
    _;
  }

  function test_WhenTheRequestedOutputIsLtTheOutputReserve(
    uint256 _reserveIn,
    uint256 _reserveOut,
    uint256 _amountOut,
    uint256 _fee,
    bool _outIsToken0
  ) external whenTheRequestedOutputIsGtZero whenTheRequestedOutputIsLtTheOutputReserve {
    _reserveIn = bound(_reserveIn, _MIN_RESERVE, _MAX_RESERVE);
    _reserveOut = bound(_reserveOut, _MIN_RESERVE, _MAX_RESERVE);
    _amountOut = bound(_amountOut, 1, (_reserveOut * 9) / 10);
    _fee = bound(_fee, 0, _MAX_BPS - 1);
    address _tokenOut = _outIsToken0 ? _token0 : _token1;
    (uint256 _reserve0, uint256 _reserve1) = _outIsToken0 ? (_reserveOut, _reserveIn) : (_reserveIn, _reserveOut);
    _seedReserves(address(_pool), _reserve0, _reserve1);

    uint256 _afterFee = _getAmountInAfterFee(_pool, _amountOut, _tokenOut);
    uint256 _grossedUp = _grossUp(_afterFee, _fee);
    (uint256 _amount0In, uint256 _amount1In) = _outIsToken0 ? (uint256(0), _afterFee) : (_afterFee, uint256(0));
    // it should quote the fee for the curve input from the factory
    _mockFeeForAmountIn(address(_pool), _amount0In, _amount1In, _reserve0, _reserve1, _fee);

    // it should gross up the zero fee quote by the fee
    assertEq(_pool.getAmountInWithTotalFee(_amountOut, _tokenOut), _grossedUp);
    // it should quote an input that preserves the invariant
    _assertSwapPreservesK(_grossedUp, _outIsToken0 ? _token1 : _token0, _reserve0, _reserve1, _amountOut, _fee);
  }

  function test_WhenTestingAKnownExample()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _r0 = 2000e18;
    uint256 _r1 = 1000e6;
    uint256 _fee = 2000;
    IPool _stablePool = _deployPool(18, 6);
    _seedReserves(address(_stablePool), _r0, _r1);

    _mockFeeForAmountIn(address(_stablePool), 0, 1000e6, _r0, _r1, _fee);

    // it should return the correct getAmountIn
    assertEq(_stablePool.getAmountInWithTotalFee(1000e18, _token0), 1250e6 - 1);
  }

  function test_WhenTheFeeFloorsToZero()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _reserve = 1000e18;
    _seedReserves(address(_pool), _reserve, _reserve);

    _mockFeeForAmountIn(address(_pool), 2, 0, _reserve, _reserve, 100);

    // it should quote the minimal input
    assertEq(_pool.getAmountInWithTotalFee(1, _token1), 2);
  }

  function test_WhenQuotingWithDifferentDecimals()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _r0 = 2000e18;
    uint256 _r1 = 1000e6;
    uint256 _expectedIn = 683_718_677_945_245_618_540;
    IPool _stablePool = _deployPool(18, 6);
    _seedReserves(address(_stablePool), _r0, _r1);

    _mockFeeForAmountIn(address(_stablePool), _expectedIn, 0, _r0, _r1, 0);

    // it should return the correct getAmountIn
    assertEq(_stablePool.getAmountInWithTotalFee(500e6, _token1), _expectedIn);
  }

  function test_WhenGetAmountInRoundsUp()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _r0 = 2000e18;
    uint256 _r1 = 1000e6;
    uint256 _expectedIn = 768_524_935;
    IPool _stablePool = _deployPool(18, 6);
    _seedReserves(address(_stablePool), _r0, _r1);

    _mockFeeForAmountIn(address(_stablePool), 0, _expectedIn, _r0, _r1, 0);

    // it should return the correct getAmountIn
    assertEq(_stablePool.getAmountInWithTotalFee(777e18, _token0), _expectedIn);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev At a zero fee the view returns the curve inverse
  function _getAmountInAfterFee(
    IPool _target,
    uint256 _amountOut,
    address _tokenOut
  ) internal returns (uint256 _afterFee) {
    vm.mockCall(_mockFactory, abi.encodeWithSelector(IPoolFactory.getFeeForAmountIn.selector), abi.encode(uint256(0)));
    _afterFee = _target.getAmountInWithTotalFee(_amountOut, _tokenOut);
    vm.clearMockedCalls();
  }
}
