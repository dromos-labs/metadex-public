// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {VolatileGetAmountBase} from 'V3-test/unit/pools/VolatilePool/VolatileGetAmountBase.sol';

contract UnitVolatilePoolGetAmountInWithTotalFee is VolatileGetAmountBase {
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
    _seedReserves(_reserve0, _reserve1);

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
    (_reserveIn, _reserveOut, _amountOut, _fee) = _boundExactOut(_reserveIn, _reserveOut, _amountOut, _fee);
    address _tokenOut = _outIsToken0 ? _token0 : _token1;
    (uint256 _reserve0, uint256 _reserve1) = _outIsToken0 ? (_reserveOut, _reserveIn) : (_reserveIn, _reserveOut);
    _seedReserves(_reserve0, _reserve1);

    uint256 _afterFee = _expectedIn(_amountOut, _reserveIn, _reserveOut);
    (uint256 _amount0In, uint256 _amount1In) = _outIsToken0 ? (uint256(0), _afterFee) : (_afterFee, uint256(0));
    // it should quote the fee for the curve input from the factory
    _mockFeeForAmountIn(_amount0In, _amount1In, _reserve0, _reserve1, _fee);

    // it should match the inverse formula grossed up by the fee
    assertEq(_pool.getAmountInWithTotalFee(_amountOut, _tokenOut), _grossUp(_afterFee, _fee));
  }

  function test_WhenTestingAKnownExample()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _r0 = 8100e18;
    uint256 _r1 = 900e18;
    uint256 _fee = 1000;
    _seedReserves(_r0, _r1);

    // _amountInAfterFee = 8100 * 90 / (900 - 90) = 900
    _mockFeeForAmountIn(900e18, 0, _r0, _r1, _fee);

    // it should return the correct getAmountIn
    assertEq(_pool.getAmountInWithTotalFee(90e18, _token1), 1000e18 - 1);
  }

  function test_WhenTheFeeFloorsToZero()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    _seedReserves(2000, 3000);

    _mockFeeForAmountIn(1, 0, 2000, 3000, 100);

    // it should quote the minimal input
    assertEq(_pool.getAmountInWithTotalFee(1, _token1), 1);
  }

  function test_WhenTheReservesAreLarge()
    external
    whenTheRequestedOutputIsGtZero
    whenTheRequestedOutputIsLtTheOutputReserve
  {
    uint256 _reserve = 2 ** 200;
    uint256 _amountOut = 2 ** 100;
    _seedReserves(_reserve, _reserve);

    // the reserve times the output overflows a uint256 while the quote itself rounds up to a + 2
    _mockFeeForAmountIn(_amountOut + 2, 0, _reserve, _reserve, 0);

    // it should quote the inverse without overflowing
    assertEq(_pool.getAmountInWithTotalFee(_amountOut, _token1), _amountOut + 2);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _boundExactOut(
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _amountOut,
    uint256 _fee
  ) internal pure returns (uint256, uint256, uint256, uint256) {
    _reserve0 = bound(_reserve0, 1, type(uint112).max);
    _reserve1 = bound(_reserve1, 2, type(uint112).max);
    _amountOut = bound(_amountOut, 1, _reserve1 - 1);
    _fee = bound(_fee, 0, _MAX_BPS - 1);
    return (_reserve0, _reserve1, _amountOut, _fee);
  }
}
