// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StableGetAmountBase} from 'V3-test/unit/pools/StablePool/StableGetAmountBase.sol';

contract UnitStablePoolGetAmountOut is StableGetAmountBase {
  function test_WhenTheReservesAreNotPassedAsParameter(
    uint256 _amountIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee,
    bool _swapToken0In
  ) external {
    (_amountIn, _reserve0, _reserve1, _fee) = _boundInputs(_amountIn, _reserve0, _reserve1, _fee);
    address _tokenIn = _swapToken0In ? _token0 : _token1;
    _seedReserves(address(_pool), _reserve0, _reserve1);

    (uint256 _amount0In, uint256 _amount1In) = _swapToken0In ? (_amountIn, uint256(0)) : (uint256(0), _amountIn);
    _mockBaseFee(address(_pool), _amount0In, _amount1In, _reserve0, _reserve1, _fee);

    uint256 _amountOut = _pool.getAmountOut(_amountIn, _tokenIn);

    // it should preserve the stable curve invariant against state reserves
    _assertSwapPreservesK(_amountIn, _tokenIn, _reserve0, _reserve1, _amountOut, _fee);
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
    _mockBaseFee(address(_pool), _amount0In, _amount1In, _reserve0, _reserve1, _fee);

    uint256 _amountOut = _pool.getAmountOut(_amountIn, _tokenIn, _reserve0, _reserve1);

    // it should preserve the stable curve invariant against the supplied reserves
    _assertSwapPreservesK(_amountIn, _tokenIn, _reserve0, _reserve1, _amountOut, _fee);
  }
}
