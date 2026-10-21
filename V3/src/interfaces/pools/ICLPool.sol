// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICLPool
 * @notice Concentrated-liquidity pool surface required by Metarouter swaps.
 */
interface ICLPool {
  /**
   * @notice Executes an exact-input swap for positive `_amountSpecified` or an exact-output swap for a negative one.
   * @param _recipient Address receiving the output token.
   * @param _zeroForOne Whether token0 is exchanged for token1.
   * @param _amountSpecified Exact input amount or negated exact output amount.
   * @param _sqrtPriceLimitX96 Terminal square-root-price boundary.
   * @param _data Data forwarded to `uniswapV3SwapCallback`.
   * @return _amount0 Signed token0 balance change of the pool.
   * @return _amount1 Signed token1 balance change of the pool.
   */
  function swap(
    address _recipient,
    bool _zeroForOne,
    int256 _amountSpecified,
    uint160 _sqrtPriceLimitX96,
    bytes calldata _data
  ) external returns (int256 _amount0, int256 _amount1);

  /**
   * @notice Returns the pool type identifier used to validate Metarouter routes.
   * @return _poolType Canonical CL pool type label.
   */
  function POOL_TYPE() external view returns (bytes32 _poolType);

  /**
   * @notice Factory that deployed the pool.
   * @return _factory Pool factory address.
   */
  function factory() external view returns (address _factory);

  /**
   * @notice Pool token sorted first by address.
   * @return _token0 First pool token.
   */
  function token0() external view returns (address _token0);

  /**
   * @notice Pool token sorted second by address.
   * @return _token1 Second pool token.
   */
  function token1() external view returns (address _token1);
}
