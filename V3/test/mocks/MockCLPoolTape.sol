// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

contract MockCLPoolTape is CLPoolTape {
  constructor(
    address _initialOwner,
    uint32 _defaultCadenceInterval
  ) CLPoolTape(_initialOwner, _defaultCadenceInterval) {}

  function externalWriteObservation(
    address _pool,
    Accumulator memory _poolAccumulator,
    uint40 _blockTimestamp,
    uint32 _cadence,
    bool _firstSwap
  ) external returns (bool _committed) {
    _committed = _writeObservation(_pool, _poolAccumulator, _blockTimestamp, _cadence, _firstSwap);
    _accumulators[_pool] = _poolAccumulator;
  }

  function externalInitializePool(address _pool) external {
    _initializePool(_pool);
  }

  function externalObserveSingle(
    address _pool,
    uint48 _secondsAgo
  ) external view returns (ICLPoolTape.Observation memory) {
    return _observeSingle(observationBuffers[_pool], _accumulators[_pool], _pool, _secondsAgo, _fullObservationSlots());
  }

  function externalGetSurroundingObservations(
    address _pool,
    uint40 _target
  ) external view returns (ICLPoolTape.Observation memory _beforeOrAt, ICLPoolTape.Observation memory _atOrAfter) {
    return _getSurroundingObservations(
      observationBuffers[_pool], _accumulators[_pool], _pool, _target, _fullObservationSlots()
    );
  }

  function externalInterpolate(
    ICLPoolTape.Observation memory _beforeOrAt,
    ICLPoolTape.Observation memory _atOrAfter,
    uint40 _target
  ) external pure returns (ICLPoolTape.Observation memory) {
    return _interpolate(_beforeOrAt, _atOrAfter, _target);
  }

  function externalFetchStakedCumulativeAt(address _pool, uint40 _timestamp) external view returns (uint160) {
    return _fetchStakedCumulativeAt(_pool, _timestamp, observationBuffers[_pool]);
  }

  function externalFetchSecondsPerLiquidityCumulativeAt(
    address _pool,
    uint40 _timestamp
  ) external view returns (uint160) {
    return _fetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp, observationBuffers[_pool]);
  }

  function _fullObservationSlots() internal pure returns (ICLPoolTape.ObservationSlots memory _slots) {
    _slots = ICLPoolTape.ObservationSlots({slot2: true, slot3: true, slot4: true, slot5: true, slot6: true});
  }
}
