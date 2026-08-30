// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {BasePoolTape} from 'V3/pools/tape/BasePoolTape.sol';

/// @title PoolTape
/// @notice Records and exposes per-swap cumulative metrics for V2 pools.
contract PoolTape is BasePoolTape, IPoolTape {
  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPoolTape
  mapping(address _pool => Accumulator _accumulator) public accumulators;

  /// @inheritdoc IBasePoolTape
  mapping(address _pool => ObservationBuffer _buffer) public observationBuffers;

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the V2 Pool tape.
  /// @param _initialOwner The initial owner.
  /// @param _defaultCadenceInterval The chain-wide default cadence in seconds.
  constructor(
    address _initialOwner,
    uint32 _defaultCadenceInterval
  ) BasePoolTape(_initialOwner, _defaultCadenceInterval) {}

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPoolTape
  function record(address _pool, PoolTapeData calldata _data) external {
    (address _caller, uint32 _cadence) = _poolConfig(_pool);
    if (_caller != msg.sender) revert Unauthorized();

    Accumulator memory _poolAccumulator = accumulators[_pool];
    uint48 _blockTimestamp = uint48(block.timestamp);

    if (_poolAccumulator.lastSwapTimestamp == 0) {
      // discards the pre populated values in the first swap
      _poolAccumulator.cumulativeFee0 = _data.fee0;
      _poolAccumulator.cumulativeFee1 = _data.fee1;
      _poolAccumulator.cumulativeVolume0 = _data.volume0;
      _poolAccumulator.cumulativeVolume1 = _data.volume1;
      _poolAccumulator.cumulativeMevVolume0 = _data.mevVolume0;
      _poolAccumulator.cumulativeMevVolume1 = _data.mevVolume1;
      _poolAccumulator.cumulativeMevFee0 = _data.mevFee0;
      _poolAccumulator.cumulativeMevFee1 = _data.mevFee1;
      _poolAccumulator.swapCount = 1;
    } else {
      unchecked {
        _poolAccumulator.cumulativeFee0 += _data.fee0;
        _poolAccumulator.cumulativeFee1 += _data.fee1;
        _poolAccumulator.cumulativeVolume0 += _data.volume0;
        _poolAccumulator.cumulativeVolume1 += _data.volume1;
        _poolAccumulator.cumulativeMevVolume0 += _data.mevVolume0;
        _poolAccumulator.cumulativeMevVolume1 += _data.mevVolume1;
        _poolAccumulator.cumulativeMevFee0 += _data.mevFee0;
        _poolAccumulator.cumulativeMevFee1 += _data.mevFee1;
        _poolAccumulator.swapCount += 1;
      }
    }
    // {_writeObservation} reads the accumulator before lastSwapTimestamp is set, so a zero there marks the first
    // swap in a wrap-safe way (unlike swapCount, which is unchecked and cycles). Set it and flush afterward.
    _writeObservation(_pool, _poolAccumulator, _blockTimestamp, _cadence);

    // timestamp needs to be set after {_writeObservation} to be able to set the first swap timestamp
    // after calling {increaseObservationCardinalityNext}
    _poolAccumulator.lastSwapTimestamp = _blockTimestamp;
    accumulators[_pool] = _poolAccumulator;
  }

  /// @inheritdoc IBasePoolTape
  function increaseObservationCardinalityNext(address _pool, uint16 _observationCardinalityNext) external {
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];

    _initializePoolBuffer(_pool, poolBuffer);

    uint16 _current = poolBuffer.cardinalityNext;
    if (_observationCardinalityNext <= _current) return;

    for (uint16 _i = _current; _i < _observationCardinalityNext; ++_i) {
      Observation storage observation = poolBuffer.observations[_i];
      observation.cumulativeFee0 = 1; // slot 1
      observation.cumulativeVolume0 = 1; // slot 2
      observation.cumulativeMevVolume0 = 1; // slot 3
      observation.cumulativeMevFee0 = 1; // slot 4
      observation.blockTimestamp = 1; // slot 5
    }
    poolBuffer.cardinalityNext = _observationCardinalityNext;
    emit ObservationCardinalityIncreased(_pool, _current, _observationCardinalityNext);
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IPoolTape
  function getObservation(address _pool, uint16 _index) external view returns (Observation memory _observation) {
    _observation = observationBuffers[_pool].observations[_index];
  }

  /// @inheritdoc IPoolTape
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations) {
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];
    Accumulator memory _poolAccumulator = accumulators[_pool];
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _observations[_i] = _observeSingle(poolBuffer, _poolAccumulator, _secondsAgo[_i]);
    }
  }

  /*////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc BasePoolTape
  /// @dev Does not pre-populate `lastSwapTimestamp` so {record} can detect the first swap.
  function _initializePool(address _pool) internal override {
    Accumulator storage accumulator = accumulators[_pool];
    if (accumulator.swapCount != 0 || accumulator.lastSwapTimestamp != 0) return;
    accumulator.swapCount = 1;
    accumulator.cumulativeFee0 = 1;
    accumulator.cumulativeVolume0 = 1;
    accumulator.cumulativeMevVolume0 = 1;
    accumulator.cumulativeMevFee0 = 1;
    _initializePoolBuffer(_pool, observationBuffers[_pool]);
  }

  /// @notice Seeds slot zero and sets cardinality to one for a fresh pool's observation buffer.
  /// @dev Returns without writing when the buffer already holds a cardinality, so callers can seed blindly.
  /// @param _pool The pool whose observation buffer is being initialized.
  /// @param poolBuffer The pool's buffer storage reference.
  function _initializePoolBuffer(address _pool, ObservationBuffer storage poolBuffer) internal {
    if (poolBuffer.cardinality != 0) return;
    uint48 _blockTimestamp = uint48(block.timestamp);
    poolBuffer.observations[0].blockTimestamp = _blockTimestamp;
    poolBuffer.cardinality = 1;
    poolBuffer.cardinalityNext = 1;
    emit PoolObservationBufferInitialized(_pool, _blockTimestamp);
  }

  /// @notice Seeds the buffer on first use, then commits the accumulator snapshot once the
  ///         cadence boundary has been crossed.
  /// @param _pool The pool committing.
  /// @param _poolAccumulator The accumulator snapshot to commit.
  /// @param _blockTimestamp The block timestamp.
  /// @param _cadence The pool's cadence in seconds.
  function _writeObservation(
    address _pool,
    Accumulator memory _poolAccumulator,
    uint48 _blockTimestamp,
    uint32 _cadence
  ) internal {
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];

    if (_poolAccumulator.lastSwapTimestamp == 0) {
      // Replaces the seed value with the correct timestamp from the first swap
      poolBuffer.observations[0].blockTimestamp = _blockTimestamp;
      return;
    }

    uint16 _cardinality = poolBuffer.cardinality;
    uint16 _index = poolBuffer.index;
    uint16 _cardinalityNext = poolBuffer.cardinalityNext;

    uint256 _elapsed;
    unchecked {
      _elapsed = _blockTimestamp - poolBuffer.observations[_index].blockTimestamp;
    }
    if (_elapsed <= _cadence) return;

    uint16 _newCardinality = _cardinality;
    /// @dev Grows by one slot per write since there is no `initialized` flag on `Observation`.
    ///      This ensures that every read only hits initialized slots.
    if (_cardinalityNext > _cardinality && _index == _cardinality - 1) {
      _newCardinality = _cardinality + 1;
    }
    uint16 _newIndex = (_index + 1) % _newCardinality;

    poolBuffer.observations[_newIndex] = _accumulatorToObservation(_poolAccumulator, _blockTimestamp);
    poolBuffer.index = _newIndex;
    if (_newCardinality != _cardinality) poolBuffer.cardinality = _newCardinality;
    emit ObservationRecorded(_pool, _newIndex, _blockTimestamp);
  }

  /*////////////////////////////////////////////////////////////
                    OBSERVE INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Resolves a single `_secondsAgo` offset into an observation by interpolating between
  ///         surrounding observations.
  /// @param poolBuffer The observation buffer.
  /// @param _poolAccumulator The pool's current accumulator.
  /// @param _secondsAgo Offset into the past from the current timestamp. `0` requests the current accumulator.
  /// @return _observation Observation at `block.timestamp - _secondsAgo`.
  function _observeSingle(
    ObservationBuffer storage poolBuffer,
    Accumulator memory _poolAccumulator,
    uint48 _secondsAgo
  ) internal view returns (Observation memory _observation) {
    uint48 _lastSwapTimestamp = _poolAccumulator.lastSwapTimestamp;

    // A pool with no recorded swap, including an unregistered pool, has no data, so return a zeroed observation.
    if (_lastSwapTimestamp == 0) return _observation;

    uint48 _blockTimestamp = uint48(block.timestamp);

    // A zero offset returns the current accumulator with the current block timestamp.
    if (_secondsAgo == 0) return _accumulatorToObservation(_poolAccumulator, _blockTimestamp);

    uint48 _target = _secondsAgo >= _blockTimestamp ? 0 : _blockTimestamp - _secondsAgo;

    // A target at or after the last swap returns the current accumulator with the requested target.
    // An observation cannot be newer than the current accumulator.
    if (_target >= _lastSwapTimestamp) return _accumulatorToObservation(_poolAccumulator, _target);

    (Observation memory _beforeOrAt, Observation memory _atOrAfter) =
      _getSurroundingObservations(poolBuffer, _poolAccumulator, _target);

    if (_target >= _atOrAfter.blockTimestamp) return _atOrAfter;
    if (_target <= _beforeOrAt.blockTimestamp) return _beforeOrAt;
    return _interpolate(_beforeOrAt, _atOrAfter, _target);
  }

  /// @notice Returns the observations bracketing `_target`.
  /// @param poolBuffer The observation buffer.
  /// @param _poolAccumulator The pool's current accumulator.
  /// @param _target Timestamp to locate inside or relative to the populated range.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _getSurroundingObservations(
    ObservationBuffer storage poolBuffer,
    Accumulator memory _poolAccumulator,
    uint48 _target
  ) internal view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    Observation[65_535] storage observations = poolBuffer.observations;
    uint16 _index = poolBuffer.index;

    // A target at or after the newest committed observation is bracketed by it and the current accumulator.
    Observation memory _newestCommittedObservation = observations[_index];
    if (_target >= _newestCommittedObservation.blockTimestamp) {
      return
        (_newestCommittedObservation, _accumulatorToObservation(_poolAccumulator, _poolAccumulator.lastSwapTimestamp));
    }

    uint16 _cardinality = poolBuffer.cardinality;
    uint16 _oldestIndex = (_index + 1) % _cardinality;

    // A target at or before the oldest observation returns the oldest observation directly.
    Observation memory _oldestCommittedObservation = observations[_oldestIndex];
    if (_target <= _oldestCommittedObservation.blockTimestamp) {
      return (_oldestCommittedObservation, _oldestCommittedObservation);
    }

    // A target between the oldest and newest committed observations is bracketed by
    // two observations found by binary search.
    return _binarySearch(observations, _index, _cardinality, _target);
  }

  /// @notice Binary searches the active buffer for the observations bracketing `_target`.
  /// @param observations The pool's observation buffer.
  /// @param _index Index of the newest committed observation.
  /// @param _cardinality Number of populated slots in the buffer.
  /// @param _target Timestamp to bracket.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _binarySearch(
    Observation[65_535] storage observations,
    uint16 _index,
    uint16 _cardinality,
    uint48 _target
  ) internal view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    uint256 _left = (uint256(_index) + 1) % _cardinality; // oldest reachable slot
    uint256 _right = _left + _cardinality - 1; // newest written slot
    while (true) {
      uint256 _mid = (_left + _right) / 2;
      uint16 _beforeIndex = uint16(_mid % _cardinality);
      uint16 _afterIndex = uint16((_mid + 1) % _cardinality);
      uint48 _beforeTimestamp = observations[_beforeIndex].blockTimestamp;
      uint48 _afterTimestamp = observations[_afterIndex].blockTimestamp;
      if (_beforeTimestamp <= _target && _target <= _afterTimestamp) {
        _beforeOrAt = observations[_beforeIndex];
        _atOrAfter = observations[_afterIndex];
        break;
      }
      if (_beforeTimestamp <= _target) _left = _mid + 1;
      else _right = _mid - 1;
    }
  }

  /// @notice Interpolates the cumulative fields at `_target` between two observation points: `_beforeOrAt` and
  ///         `_atOrAfter`.
  /// @dev When `_target` equals `_atOrAfter.blockTimestamp` the result equals the `_atOrAfter` fields.
  /// @dev When `_target` equals `_beforeOrAt.blockTimestamp` the result equals the `_beforeOrAt` fields.
  /// @dev `_target` should fall between `_beforeOrAt.blockTimestamp` and `_atOrAfter.blockTimestamp` (inclusive).
  /// @param _beforeOrAt Observation at or before `_target` chronologically.
  /// @param _atOrAfter Observation at or after `_target` chronologically.
  /// @param _target Timestamp at which to evaluate the interpolation.
  /// @return _observation The interpolated observation at timestamp `_target`.
  function _interpolate(
    Observation memory _beforeOrAt,
    Observation memory _atOrAfter,
    uint48 _target
  ) internal pure returns (Observation memory _observation) {
    uint256 _beforeToAfterTimeDelta = _atOrAfter.blockTimestamp - _beforeOrAt.blockTimestamp;
    uint256 _beforeToTargetTimeDelta = _target - _beforeOrAt.blockTimestamp;

    _observation.cumulativeFee0 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeFee0, _atOrAfter.cumulativeFee0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeFee1 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeFee1, _atOrAfter.cumulativeFee1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeVolume0 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeVolume0, _atOrAfter.cumulativeVolume0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeVolume1 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeVolume1, _atOrAfter.cumulativeVolume1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevVolume0 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeMevVolume0,
      _atOrAfter.cumulativeMevVolume0,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevVolume1 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeMevVolume1,
      _atOrAfter.cumulativeMevVolume1,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevFee0 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeMevFee0, _atOrAfter.cumulativeMevFee0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevFee1 = _interpolateUint128Cumulative(
      _beforeOrAt.cumulativeMevFee1, _atOrAfter.cumulativeMevFee1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );

    uint256 _swapCountDelta;
    unchecked {
      _swapCountDelta = _atOrAfter.swapCount - _beforeOrAt.swapCount;
    }
    _observation.swapCount =
      uint48(_beforeOrAt.swapCount + (_swapCountDelta * _beforeToTargetTimeDelta) / _beforeToAfterTimeDelta);

    _observation.blockTimestamp = _target;
  }

  /// @notice Linearly interpolates a single uint128 cumulative field.
  /// @dev The before/after subtraction is `unchecked` so the math holds across a uint128 cumulative wrap.
  /// @param _beforeValue The field value at the before observation.
  /// @param _afterValue The field value at the after observation.
  /// @param _beforeToTargetTimeDelta Seconds from the before observation to the target.
  /// @param _beforeToAfterTimeDelta Seconds from the before observation to the after observation.
  /// @return _value The interpolated field value.
  function _interpolateUint128Cumulative(
    uint128 _beforeValue,
    uint128 _afterValue,
    uint256 _beforeToTargetTimeDelta,
    uint256 _beforeToAfterTimeDelta
  ) internal pure returns (uint128 _value) {
    uint256 _valueDelta;
    unchecked {
      _valueDelta = _afterValue - _beforeValue;
    }
    _value = uint128(_beforeValue + (_valueDelta * _beforeToTargetTimeDelta) / _beforeToAfterTimeDelta);
  }

  /// @notice Builds an Observation from the current accumulator with `_blockTimestamp`.
  /// @param _poolAccumulator The current accumulator to convert.
  /// @param _blockTimestamp The timestamp to stamp on the returned observation.
  /// @return _observation The current cumulatives as an Observation with `_blockTimestamp`.
  function _accumulatorToObservation(
    Accumulator memory _poolAccumulator,
    uint48 _blockTimestamp
  ) internal pure returns (Observation memory _observation) {
    _observation = Observation({
      cumulativeFee0: _poolAccumulator.cumulativeFee0,
      cumulativeFee1: _poolAccumulator.cumulativeFee1,
      cumulativeVolume0: _poolAccumulator.cumulativeVolume0,
      cumulativeVolume1: _poolAccumulator.cumulativeVolume1,
      cumulativeMevVolume0: _poolAccumulator.cumulativeMevVolume0,
      cumulativeMevVolume1: _poolAccumulator.cumulativeMevVolume1,
      cumulativeMevFee0: _poolAccumulator.cumulativeMevFee0,
      cumulativeMevFee1: _poolAccumulator.cumulativeMevFee1,
      blockTimestamp: _blockTimestamp,
      swapCount: _poolAccumulator.swapCount
    });
  }
}
