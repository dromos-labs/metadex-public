// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract MockPoolTape is PoolTape {
  constructor(address _initialOwner, uint32 _defaultCadenceInterval) PoolTape(_initialOwner, _defaultCadenceInterval) {}

  function externalInitializePool(address _pool) external {
    _initializePool(_pool);
  }

  function externalWriteObservation(
    address _pool,
    IPoolTape.Accumulator memory _poolAccumulator,
    uint48 _blockTimestamp,
    uint32 _cadence
  ) external {
    _writeObservation(_pool, _poolAccumulator, _blockTimestamp, _cadence);
  }

  function externalObserveSingle(
    address _pool,
    uint48 _secondsAgo
  ) external view returns (IPoolTape.Observation memory) {
    return _observeSingle(observationBuffers[_pool], accumulators[_pool], _secondsAgo);
  }

  function externalGetSurroundingObservations(
    address _pool,
    uint48 _target
  ) external view returns (IPoolTape.Observation memory _beforeOrAt, IPoolTape.Observation memory _atOrAfter) {
    return _getSurroundingObservations(observationBuffers[_pool], accumulators[_pool], _target);
  }

  function externalInterpolate(
    IPoolTape.Observation memory _beforeOrAt,
    IPoolTape.Observation memory _atOrAfter,
    uint48 _target
  ) external pure returns (IPoolTape.Observation memory) {
    return _interpolate(_beforeOrAt, _atOrAfter, _target);
  }
}
