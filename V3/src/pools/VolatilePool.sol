// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {Pool} from 'V3/pools/Pool.sol';

/// @title VolatilePool
/// @notice Aerodrome V2 constant-product pool.
contract VolatilePool is Pool {
  /// @inheritdoc IPool
  bytes32 public constant POOL_TYPE = 'V2_VOLATILE';

  /// @inheritdoc Pool
  function _getAmountOut(
    uint256 amountIn,
    address tokenIn,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view override returns (uint256) {
    (uint256 reserveIn, uint256 reserveOut) = tokenIn == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
    return (amountIn * reserveOut) / (reserveIn + amountIn);
  }

  /// @inheritdoc Pool
  function _getAmountIn(
    uint256 amountOut,
    address tokenOut,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view override returns (uint256) {
    (uint256 reserveOut, uint256 reserveIn) = tokenOut == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
    return Math.mulDiv(reserveIn, amountOut, reserveOut - amountOut, Math.Rounding.Ceil);
  }

  /// @inheritdoc Pool
  function _k(uint256 x, uint256 y) internal pure override returns (uint256) {
    return x * y;
  }

  /// @inheritdoc Pool
  function _poolName(string memory _symbol0, string memory _symbol1) internal pure override returns (string memory) {
    return string(abi.encodePacked('VolatileV2 AMM - ', _symbol0, '/', _symbol1));
  }

  /// @inheritdoc Pool
  function _poolSymbol(string memory _symbol0, string memory _symbol1) internal pure override returns (string memory) {
    return string(abi.encodePacked('vAMMV2-', _symbol0, '/', _symbol1));
  }
}
