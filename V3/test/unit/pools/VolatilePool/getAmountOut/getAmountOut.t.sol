// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VolatileGetAmountBase} from 'V3-test/unit/pools/VolatilePool/VolatileGetAmountBase.sol';

contract UnitVolatilePoolGetAmountOut is VolatileGetAmountBase {
  function test_WhenTheReservesAreNotPassedAsParameter(
    uint256 _amountIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee,
    bool _swapToken0In
  ) external {
    (_amountIn, _reserve0, _reserve1, _fee) = _boundInputs(_amountIn, _reserve0, _reserve1, _fee);
    address _tokenIn = _swapToken0In ? _token0 : _token1;
    _seedReserves(_reserve0, _reserve1);

    (uint256 _amount0In, uint256 _amount1In) = _swapToken0In ? (_amountIn, uint256(0)) : (uint256(0), _amountIn);
    _mockBaseFee(_amount0In, _amount1In, _reserve0, _reserve1, _fee);

    // it should match the constant-product formula against state reserves
    assertEq(_pool.getAmountOut(_amountIn, _tokenIn), _expectedOut(_amountIn, _tokenIn, _reserve0, _reserve1, _fee));
  }

  function test_WhenTheReservesArePassedAsParameter(
    uint256 _amountIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee,
    bool _swapToken0In
  ) external {
    (_amountIn, _reserve0, _reserve1, _fee) = _boundInputs(_amountIn, _reserve0, _reserve1, _fee);
    address _tokenIn = _swapToken0In ? _token0 : _token1;

    (uint256 _amount0In, uint256 _amount1In) = _swapToken0In ? (_amountIn, uint256(0)) : (uint256(0), _amountIn);
    _mockBaseFee(_amount0In, _amount1In, _reserve0, _reserve1, _fee);

    // it should match the constant-product formula against the supplied reserves
    assertEq(
      _pool.getAmountOut(_amountIn, _tokenIn, _reserve0, _reserve1),
      _expectedOut(_amountIn, _tokenIn, _reserve0, _reserve1, _fee)
    );
  }
}
