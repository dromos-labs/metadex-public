// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

/**
 * @title INonfungiblePositionManager
 * @notice Minimal view of the concentrated-liquidity `NonfungiblePositionManager` used by the Metarouter's CL position
 *         commands: the ERC721 custody surface plus mint, liquidity changes, fee collection, burn, and the position
 *         read the handlers need to resolve a position's tokens.
 * @dev The upstream manager ships in the `metadex-slipstream` repo, which is not remapped into this repo, so the
 *      selectors and structs the commands call are mirrored here as one self-contained interface. It inherits `IERC721`
 *      because the manager is an ERC721 and the router uses its custody calls (`ownerOf`, `approve`, `transferFrom`,
 *      `safeTransferFrom`) alongside the position calls. Struct field names and the `positions` tuple are kept verbatim
 *      so they match the manager's ABI.
 */
interface INonfungiblePositionManager is IERC721 {
  /**
   * @notice Arguments for `mint`.
   * @param token0 First pool token, sorted ascending.
   * @param token1 Second pool token, sorted ascending.
   * @param tickSpacing Tick spacing identifying the pool alongside its tokens.
   * @param tickLower Lower tick of the position range.
   * @param tickUpper Upper tick of the position range.
   * @param amount0Desired Maximum `token0` to contribute.
   * @param amount1Desired Maximum `token1` to contribute.
   * @param amount0Min Minimum `token0` to contribute, as a slippage bound.
   * @param amount1Min Minimum `token1` to contribute, as a slippage bound.
   * @param recipient Address the minted position is transferred to.
   * @param deadline Timestamp after which the mint reverts.
   * @param sqrtPriceX96 Price to initialize the pool with when it does not yet exist; ignored when zero.
   */
  struct MintParams {
    address token0;
    address token1;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint256 deadline;
    uint160 sqrtPriceX96;
  }

  /**
   * @notice Arguments for `increaseLiquidity`.
   * @param tokenId Position to add liquidity to.
   * @param amount0Desired Maximum `token0` to contribute.
   * @param amount1Desired Maximum `token1` to contribute.
   * @param amount0Min Minimum `token0` to contribute, as a slippage bound.
   * @param amount1Min Minimum `token1` to contribute, as a slippage bound.
   * @param deadline Timestamp after which the increase reverts.
   */
  struct IncreaseLiquidityParams {
    uint256 tokenId;
    uint256 amount0Desired;
    uint256 amount1Desired;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  /**
   * @notice Arguments for `decreaseLiquidity`.
   * @param tokenId Position to remove liquidity from.
   * @param liquidity Liquidity to remove, accounted to the position's owed tokens.
   * @param amount0Min Minimum `token0` accounted, as a slippage bound.
   * @param amount1Min Minimum `token1` accounted, as a slippage bound.
   * @param deadline Timestamp after which the decrease reverts.
   */
  struct DecreaseLiquidityParams {
    uint256 tokenId;
    uint128 liquidity;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  /**
   * @notice Arguments for `collect`.
   * @param tokenId Position whose owed tokens are collected.
   * @param recipient Address receiving the collected tokens.
   * @param amount0Max Maximum `token0` to collect.
   * @param amount1Max Maximum `token1` to collect.
   */
  struct CollectParams {
    uint256 tokenId;
    address recipient;
    uint128 amount0Max;
    uint128 amount1Max;
  }

  /**
   * @notice Creates a new position wrapped in an NFT.
   * @param params Mint arguments encoded as `MintParams`.
   * @return tokenId Id of the minted position.
   * @return liquidity Liquidity of the minted position.
   * @return amount0 `token0` contributed.
   * @return amount1 `token1` contributed.
   */
  function mint(MintParams calldata params)
    external
    payable
    returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

  /**
   * @notice Adds liquidity to an existing position, paid by the caller.
   * @param params Increase arguments encoded as `IncreaseLiquidityParams`.
   * @return liquidity Liquidity added to the position.
   * @return amount0 `token0` contributed.
   * @return amount1 `token1` contributed.
   */
  function increaseLiquidity(IncreaseLiquidityParams calldata params)
    external
    payable
    returns (uint128 liquidity, uint256 amount0, uint256 amount1);

  /**
   * @notice Removes liquidity from a position, accounting it to the position's owed tokens.
   * @param params Decrease arguments encoded as `DecreaseLiquidityParams`.
   * @return amount0 `token0` accounted to the position's owed tokens.
   * @return amount1 `token1` accounted to the position's owed tokens.
   */
  function decreaseLiquidity(DecreaseLiquidityParams calldata params)
    external
    payable
    returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Collects owed tokens from a position to the recipient.
   * @param params Collect arguments encoded as `CollectParams`.
   * @return amount0 `token0` collected.
   * @return amount1 `token1` collected.
   */
  function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

  /**
   * @notice Burns a position, which must hold no liquidity and no owed tokens.
   * @param tokenId Position to burn.
   */
  function burn(uint256 tokenId) external payable;

  /**
   * @notice Returns the position associated with a token id.
   * @param tokenId Position to read.
   * @return nonce Permit nonce.
   * @return operator Approved operator for the position.
   * @return token0 First pool token.
   * @return token1 Second pool token.
   * @return tickSpacing Tick spacing of the pool.
   * @return tickLower Lower tick of the position range.
   * @return tickUpper Upper tick of the position range.
   * @return liquidity Liquidity held by the position.
   * @return feeGrowthInside0LastX128 `token0` fee growth snapshot at the last position action.
   * @return feeGrowthInside1LastX128 `token1` fee growth snapshot at the last position action.
   * @return tokensOwed0 Uncollected `token0` owed to the position.
   * @return tokensOwed1 Uncollected `token1` owed to the position.
   */
  function positions(uint256 tokenId)
    external
    view
    returns (
      uint96 nonce,
      address operator,
      address token0,
      address token1,
      int24 tickSpacing,
      int24 tickLower,
      int24 tickUpper,
      uint128 liquidity,
      uint256 feeGrowthInside0LastX128,
      uint256 feeGrowthInside1LastX128,
      uint128 tokensOwed0,
      uint128 tokensOwed1
    );
}
