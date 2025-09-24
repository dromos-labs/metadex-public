// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';

/// @title IExactOutFeeQuoter
/// @notice Resolves the total swap fee of an exact output
interface IExactOutFeeQuoter {
  /// @notice Get the factory that the quoter belongs to
  /// @return _factory The pool factory
  function FACTORY() external view returns (IPoolFactory _factory);

  /// @notice Returns the total fee to gross up an exact output quote with
  /// @param _pool The pool being quoted
  /// @param _caller The swap initiator
  /// @param _amount0InAfterFee The token0 input the curve requires after the fee, zero when token0 is not an input
  /// @param _amount1InAfterFee The token1 input the curve requires after the fee, zero when token1 is not an input
  /// @param _reserve0 The pre-swap token0 reserve of the pool
  /// @param _reserve1 The pre-swap token1 reserve of the pool
  /// @return _fee The total fee in basis points
  function getFeeForAmountIn(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee);
}
