// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {PoolOracle} from 'V3/libraries/PoolOracle.sol';
import {Pool} from 'V3/pools/Pool.sol';

contract MockPool is Pool {
  bytes32 public constant POOL_TYPE = 'MOCK';

  function externalUpdate(uint256 _balance0, uint256 _balance1, uint256 _reserve0, uint256 _reserve1) external {
    _update(_balance0, _balance1, _reserve0, _reserve1);
  }

  function externalWrite(
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast,
    uint256 _periodSize
  ) external {
    PoolOracle.write(observationBuffer, _reserve0CumulativeLast, _reserve1CumulativeLast, _periodSize);
  }

  function externalGrow(uint16 _next) external returns (uint16 _grown) {
    return PoolOracle.grow(observationBuffer, _next);
  }

  function externalInitialize() external {
    PoolOracle.initialize(observationBuffer);
  }

  function externalGetSurroundingObservations(
    uint32 _time,
    uint32 _target
  ) external view returns (PoolOracle.Observation memory _beforeOrAt, PoolOracle.Observation memory _atOrAfter) {
    (uint256 _r0Now, uint256 _r1Now,) = currentCumulativePrices();
    return PoolOracle._getSurroundingObservations(observationBuffer, _time, _target, _r0Now, _r1Now);
  }

  function externalInterpolate(
    PoolOracle.Observation memory _beforeOrAt,
    uint32 _afterTimestamp,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative,
    uint32 _target
  ) external pure returns (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative) {
    return PoolOracle._interpolate(
      _beforeOrAt, _afterTimestamp, _afterReserve0Cumulative, _afterReserve1Cumulative, _target
    );
  }

  function externalObserveSingle(
    uint32 _time,
    uint32 _secondsAgo
  ) external view returns (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative) {
    (uint256 _r0Now, uint256 _r1Now,) = currentCumulativePrices();
    return PoolOracle.observeSingle(observationBuffer, _time, _secondsAgo, _r0Now, _r1Now);
  }

  function externalLte(uint32 _time, uint32 _a, uint32 _b) external pure returns (bool) {
    return PoolOracle._lte(_time, _a, _b);
  }

  function _k(uint256, uint256) internal view virtual override returns (uint256) {
    return 0;
  }

  function _getAmountOut(uint256, address, uint256, uint256) internal view virtual override returns (uint256) {
    return 0;
  }

  function _getAmountIn(uint256, address, uint256, uint256) internal view virtual override returns (uint256) {
    return 0;
  }

  function _poolName(string memory, string memory) internal pure virtual override returns (string memory) {
    return '';
  }

  function _poolSymbol(string memory, string memory) internal pure virtual override returns (string memory) {
    return '';
  }
}
