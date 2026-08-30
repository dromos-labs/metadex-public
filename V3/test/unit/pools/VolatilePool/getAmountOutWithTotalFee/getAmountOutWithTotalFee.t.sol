// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VolatileGetAmountBase} from 'V3-test/unit/pools/VolatilePool/VolatileGetAmountBase.sol';

contract UnitVolatilePoolGetAmountOutWithTotalFee is VolatileGetAmountBase {
  modifier whenQuotingAnExactInputSwap() {
    _;
  }

  function test_WhenQuotingAnExactInputSwap(
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

    // it should query the fee
    _mockTotalFee(_amount0In, _amount1In, _reserve0, _reserve1, _fee);

    // it should quote the amountOut taking the fee into account
    assertEq(
      _pool.getAmountOutWithTotalFee(_amountIn, _tokenIn), _expectedOut(_amountIn, _tokenIn, _reserve0, _reserve1, _fee)
    );
  }

  function test_WhenTestingAConcreteExample() external whenQuotingAnExactInputSwap {
    uint256 _r0 = 8100e18;
    uint256 _r1 = 900e18;
    uint256 _fee = 1000;
    _seedReserves(_r0, _r1);

    _mockTotalFee(1000e18, 0, _r0, _r1, _fee);

    // it should return the concrete example amountOut
    // amountOut = 900 * 900 / (8100 + 900) = 90
    assertEq(_pool.getAmountOutWithTotalFee(1000e18, _token0), 90e18);
  }
}
