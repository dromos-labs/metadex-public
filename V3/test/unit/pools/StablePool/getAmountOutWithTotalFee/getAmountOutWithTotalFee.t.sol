// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StableGetAmountBase} from 'V3-test/unit/pools/StablePool/StableGetAmountBase.sol';

contract UnitStablePoolGetAmountOutWithTotalFee is StableGetAmountBase {
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
    _seedReserves(address(_pool), _reserve0, _reserve1);
    (uint256 _amount0In, uint256 _amount1In) = _swapToken0In ? (_amountIn, uint256(0)) : (uint256(0), _amountIn);

    // it should query the fee
    _mockTotalFee(address(_pool), _amount0In, _amount1In, _reserve0, _reserve1, _fee);

    uint256 _amountOut = _pool.getAmountOutWithTotalFee(_amountIn, _tokenIn);

    // it should preserve the stable curve invariant
    _assertSwapPreservesK(_amountIn, _tokenIn, _reserve0, _reserve1, _amountOut, _fee);
  }

  function test_WhenTestingAConcreteExample() external whenQuotingAnExactInputSwap {
    uint256 _r0 = 1_000_000e18;
    uint256 _r1 = 1_000_000e18;
    uint256 _fee = 1000;
    _seedReserves(address(_pool), _r0, _r1);

    _mockTotalFee(address(_pool), 1e18, 0, _r0, _r1, _fee);

    // it should return the concrete example amountOut
    assertEq(_pool.getAmountOutWithTotalFee(1e18, _token0), 0.9e18 - 1);
  }
}
