// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IStablePool} from 'V3/interfaces/pools/IStablePool.sol';

import {Pool} from 'V3/pools/Pool.sol';

/// @title StablePool
/// @notice Aerodrome V2 stable-swap pool.
contract StablePool is Pool, IStablePool {
  /// @inheritdoc IStablePool
  uint256 public constant MINIMUM_K = 10 ** 10;

  /// @inheritdoc IPool
  bytes32 public constant POOL_TYPE = 'V2_STABLE';

  /// @inheritdoc Pool
  function _getAmountOut(
    uint256 _amountIn,
    address _tokenIn,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view override returns (uint256) {
    uint256 _targetK = _k(_reserve0, _reserve1);
    _reserve0 = (_reserve0 * 1e18) / _decimals0;
    _reserve1 = (_reserve1 * 1e18) / _decimals1;
    (uint256 _reserveA, uint256 _reserveB) = _tokenIn == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
    _amountIn = _tokenIn == token0 ? (_amountIn * 1e18) / _decimals0 : (_amountIn * 1e18) / _decimals1;
    uint256 _amountOut = _reserveB - _getY(_amountIn + _reserveA, _targetK, _reserveB);
    return (_amountOut * (_tokenIn == token0 ? _decimals1 : _decimals0)) / 1e18;
  }

  /// @inheritdoc Pool
  function _getAmountIn(
    uint256 _amountOut,
    address _tokenOut,
    uint256 _reserve0,
    uint256 _reserve1
  ) internal view override returns (uint256) {
    uint256 _targetK = _k(_reserve0, _reserve1);
    _reserve0 = (_reserve0 * 1e18) / _decimals0;
    _reserve1 = (_reserve1 * 1e18) / _decimals1;
    (uint256 _reserveOut, uint256 _reserveIn) = _tokenOut == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
    (uint256 _decimalsOut, uint256 _decimalsIn) =
      _tokenOut == token0 ? (_decimals0, _decimals1) : (_decimals1, _decimals0);
    _amountOut = Math.ceilDiv(_amountOut * 1e18, _decimalsOut);
    if (_amountOut >= _reserveOut) revert InsufficientLiquidity();
    uint256 _newReserveIn = _getY(_reserveOut - _amountOut, _targetK, _reserveIn);
    return Math.ceilDiv((_newReserveIn - _reserveIn) * _decimalsIn, 1e18);
  }

  /// @inheritdoc Pool
  function _k(uint256 _x, uint256 _y) internal view override returns (uint256) {
    uint256 _scaledX = (_x * 1e18) / _decimals0;
    uint256 _scaledY = (_y * 1e18) / _decimals1;
    uint256 _a = Math.mulDiv(_scaledX, _scaledY, 1e18);
    uint256 _b = Math.mulDiv(_scaledX, _scaledX, 1e18) + Math.mulDiv(_scaledY, _scaledY, 1e18);
    return Math.mulDiv(_a, _b, 1e18); // x^3*y + y^3*x
  }

  /// @inheritdoc Pool
  function _mintValidation(uint256 _amount0, uint256 _amount1) internal view override {
    if ((_amount0 * 1e18) / _decimals0 != (_amount1 * 1e18) / _decimals1) revert DepositsNotEqual();
    if (_k(_amount0, _amount1) <= MINIMUM_K) revert BelowMinimumK();
  }

  /// @inheritdoc Pool
  function _kThresholdValidation(uint256 _x, uint256 _y) internal view override {
    if (_k(_x, _y) == 0) revert KIsZero();
  }

  /// @inheritdoc Pool
  function _poolName(string memory _symbol0, string memory _symbol1) internal pure override returns (string memory) {
    return string(abi.encodePacked('StableV2 AMM - ', _symbol0, '/', _symbol1));
  }

  /// @inheritdoc Pool
  function _poolSymbol(string memory _symbol0, string memory _symbol1) internal pure override returns (string memory) {
    return string(abi.encodePacked('sAMMV2-', _symbol0, '/', _symbol1));
  }

  function _f(uint256 _x0, uint256 _y) private pure returns (uint256) {
    uint256 _a = Math.mulDiv(_x0, _y, 1e18);
    uint256 _b = Math.mulDiv(_x0, _x0, 1e18) + Math.mulDiv(_y, _y, 1e18);
    return Math.mulDiv(_a, _b, 1e18);
  }

  function _d(uint256 _x0, uint256 _y) private pure returns (uint256) {
    uint256 _ySquared = Math.mulDiv(_y, _y, 1e18);
    uint256 _x0Squared = Math.mulDiv(_x0, _x0, 1e18);
    return Math.mulDiv(3 * _x0, _ySquared, 1e18) + Math.mulDiv(_x0Squared, _x0, 1e18); // 3*x0*y^2 + x0^3
  }

  /// @dev Use Newton-Raphson to approximate the solution to `x^3*y + y^3*x >= k`.
  function _getY(uint256 _x0, uint256 _targetK, uint256 _y) private pure returns (uint256) {
    for (uint256 _i = 0; _i < 255; _i++) {
      uint256 _currentK = _f(_x0, _y);
      if (_currentK < _targetK) {
        // dy == 0 means _d(_x0, _y) is too large compare to (_targetK - _currentK) and the rounding error
        // screwed us. In this case, we need to increase y by 1
        uint256 _dy = Math.mulDiv(_targetK - _currentK, 1e18, _d(_x0, _y));
        if (_dy == 0) {
          if (_f(_x0, _y + 1) > _targetK) {
            // If _f(_x0, _y + 1) > _targetK, then we are close to the correct answer.
            // There's no closer answer than y + 1
            return _y + 1;
          }
          _dy = 1;
        }
        _y = _y + _dy;
      } else {
        uint256 _dy = Math.mulDiv(_currentK - _targetK, 1e18, _d(_x0, _y));
        if (_dy == 0) {
          if (_currentK == _targetK || _f(_x0, _y - 1) < _targetK) {
            // Likewise, if _currentK == _targetK, we found the correct answer.
            // If _f(_x0, _y - 1) < _targetK, then we are close to the correct answer.
            // There's no closer answer than "y"
            // It's worth mentioning that we need to find y where f(x0, y) >= _targetK
            // As a result, we can't return y - 1 even it's closer to the correct answer
            return _y;
          }
          _dy = 1;
        }
        _y = _y - _dy;
      }
    }
    revert CannotCalculateY();
  }
}
