// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Interface for CLPool swap hooks that can override pre-swap fees and/or apply post-swap fees.
interface ISwapHook {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Swap context passed to hook entry points.
  /// @param caller `msg.sender` address that initiated the swap.
  /// @param recipient Recipient of the swap output.
  /// @param zeroForOne True for token0 -> token1 swaps, false otherwise.
  /// @param amountSpecified The exact amount specified by the swapper (either input or output).
  /// @param sqrtPriceLimitX96 Swap price limit.
  /// @param data Optional calldata supplied to the swap call.
  /// @param sqrtPriceX96 Square root price of the pool:
  ///        In {beforeSwap} represents a PRE-SWAP sqrt price.
  ///        In {afterSwap} represents a POST-SWAP sqrt price.
  /// @param tick Tick of the pool:
  ///        In {beforeSwap} represents a PRE-SWAP tick.
  ///        In {afterSwap} represents a POST-SWAP tick.
  struct SwapParams {
    address caller;
    address recipient;
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
    bytes data;
    uint160 sqrtPriceX96;
    int24 tick;
  }

  /// @notice Post-swap state passed to the {afterSwap} entry-point.
  /// @param amountSpecifiedRemaining Remaining specified amount after the swap loop conclusion.
  /// @param amountCalculated Amount computed by the swap loop before any post-swap fee adjustment.
  /// @param fee The fee applied during the swap loop.
  /// @param hasUpdatedFees Whether swap fees were updated during execution.
  /// @param feeGrowthGlobalX128 The global fee growth of the input token after the swap loop.
  /// @param gaugeFee Fee amount paid to staked liquidity.
  /// @param liquidity In-range liquidity at the end of the swap loop.
  /// @param stakedLiquidity In-range staked liquidity at the end of the swap loop.
  /// @param tickCumulative The post-swap value of the tick accumulator, computed only if an initialized tick is crossed.
  /// @param secondsPerLiquidityCumulativeX128 The post-swap value of the seconds per liquidity
  ///        accumulator, computed only if an initialized tick is crossed.
  /// @param computedLatestObservation Whether the latest observation was computed during the swap.
  struct AfterSwapParams {
    int256 amountSpecifiedRemaining;
    int256 amountCalculated;
    uint24 fee;
    bool hasUpdatedFees;
    uint256 feeGrowthGlobalX128;
    uint128 gaugeFee;
    uint128 liquidity;
    uint128 stakedLiquidity;
    int56 tickCumulative;
    uint160 secondsPerLiquidityCumulativeX128;
    bool computedLatestObservation;
  }

  /// @notice Call context of `flash` function.
  /// @param caller `msg.sender` address that initiated flash execution.
  /// @param recipient Recipient of the flash loaned tokens.
  /// @param amount0 Amount of token0 to flash loan.
  /// @param amount1 Amount of token1 to flash loan.
  /// @param data Optional calldata supplied to the flash call.
  struct FlashParams {
    address caller;
    address recipient;
    uint256 amount0;
    uint256 amount1;
    bytes data;
  }

  /*////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Queries the swap fee that the hook would charge in the swap loop.
  /// @param _pool Address of the pool making the query.
  /// @param _swapParams Swap context and pre-swap pool state.
  /// @return _fee The fee that would be applied in the swap loop, in pips.
  function getBeforeSwapFee(address _pool, SwapParams memory _swapParams) external view returns (uint24 _fee);

  /// @notice Queries the swap fee that the hook would charge after the swap loop.
  /// @param _pool Address of the pool making the query.
  /// @param _swapParams Swap context and post-swap pool state.
  /// @param _afterSwapParams Post-swap execution state and oracle/liquidity context.
  /// @return _fee The fee that would be applied after the swap loop, in pips.
  function getAfterSwapFee(
    address _pool,
    SwapParams memory _swapParams,
    AfterSwapParams memory _afterSwapParams
  ) external view returns (uint24 _fee);

  /// @notice Queries the flash loan fee that the hook would charge for a given flash context.
  /// @param _pool Address of the pool making the query.
  /// @param _flashParams Arguments passed to the flash function.
  /// @return _fee The fee that would be applied to flash loaned amounts, in pips.
  function getFlashFee(address _pool, FlashParams memory _flashParams) external view returns (uint24 _fee);

  /*////////////////////////////////////////////////////////////
                              WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the fee to apply inside the swap loop.
  /// @param _swapParams Swap context and PRE-SWAP pool state.
  /// @return _fee The fee to apply throughout the swap loop.
  function beforeSwap(SwapParams memory _swapParams) external returns (uint24 _fee);

  /// @notice Returns the pips fee to apply after the swap loop conclusion.
  /// @dev The fee is redirected exclusively to the Gauge.
  /// @param _swapParams Swap context and POST-SWAP pool state.
  /// @param _afterSwapParams POST-SWAP execution state and oracle/liquidity context.
  /// @return _fee A post-swap fee to apply to the non-exact input/output part
  ///         of the swap that's credited to the gauge.
  function afterSwap(
    SwapParams memory _swapParams,
    AfterSwapParams memory _afterSwapParams
  ) external returns (uint24 _fee);

  /// @notice Returns the fee to apply to `amount0/1` in `flash` function.
  /// @param _flashParams Arguments passed to the `flash` function.
  /// @return _fee Fee to apply to flash loaned amounts.
  function beforeFlash(FlashParams memory _flashParams) external returns (uint24 _fee);
}
