// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';

interface IFeeModule {
  /// @notice Get the factory that the fee module belongs to
  function factory() external view returns (IPoolFactory);

  /// @notice Get the fee for a given pool swap. Accounts for default and dynamic fees
  /// @dev Fee is denominated in bips. Reserves are the pre-swap reserves of the pool
  /// @dev A fee above the factory's `MAX_BASE_FEE` is ignored, falling back to `defaultFee`
  /// @param _pool The pool to get the fee for
  /// @param _caller The swap initiator
  /// @param _amount0In The token0 input amount of the swap, zero when token0 is not an input
  /// @param _amount1In The token1 input amount of the swap, zero when token1 is not an input
  /// @param _reserve0 The pre-swap token0 reserve of the pool
  /// @param _reserve1 The pre-swap token1 reserve of the pool
  /// @return _fee The fee for the given swap
  function getFee(
    address _pool,
    address _caller,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint24 _fee);
}
