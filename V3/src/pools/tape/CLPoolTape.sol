// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {VolatilityRingLibrary} from 'V3/libraries/VolatilityRingLibrary.sol';

import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolState} from 'V3/interfaces/pools/ICLPoolState.sol';
import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {BasePoolTape} from 'V3/pools/tape/BasePoolTape.sol';

/// @title CLPoolTape
/// @notice Records and exposes per-swap cumulative metrics, tick state, and volatility inputs for CL pools.
contract CLPoolTape is BasePoolTape, ICLPoolTape {
  using VolatilityRingLibrary for uint256[15];

  /*////////////////////////////////////////////////////////////
                            STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLPoolTape
  address public elasticFeeModule;

  /// @inheritdoc IBasePoolTape
  mapping(address _pool => ObservationBuffer _buffer) public observationBuffers;

  /// @notice The per-pool current accumulator state.
  mapping(address _pool => Accumulator _accumulator) internal _accumulators;

  /// @notice 15 slots ring containing the volatility results written at each observation commit.
  /// @dev Each slot can contain up to 4 triples of packed `{uint24 range, uint24 dist, uint16 m}` values.
  /// @dev The total amount of triples is limited to {VolatilityRingLibrary._WINDOW}.
  mapping(address _pool => uint256[15] _ring) internal _volatilityRings;

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the CL pool tape.
  /// @param _initialOwner The initial owner.
  /// @param _defaultCadenceInterval The chain-wide default cadence in seconds.
  constructor(
    address _initialOwner,
    uint32 _defaultCadenceInterval
  ) BasePoolTape(_initialOwner, _defaultCadenceInterval) {}

  /*////////////////////////////////////////////////////////////
                    EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLPoolTape
  function setElasticFeeModule(address _elasticFeeModule) external onlyOwner {
    elasticFeeModule = _elasticFeeModule;
    emit ElasticFeeModuleSet(_elasticFeeModule);
  }

  /// @inheritdoc ICLPoolTape
  function record(address _pool, CLPoolTapeData calldata _data) external returns (bool _committed) {
    (address _caller, uint32 _cadence) = _poolConfig(_pool);
    if (_caller != msg.sender) revert Unauthorized();

    Accumulator memory _poolAccumulator = _accumulators[_pool];
    uint40 _blockTimestamp = uint40(block.timestamp);
    bool _firstSwap = _poolAccumulator.lastSwapTimestamp == 0;

    if (_poolAccumulator.intervalSwapCount == 0) {
      _poolAccumulator.intervalMaxTick = _data.tick;
      _poolAccumulator.intervalMinTick = _data.tick;
    } else {
      if (_data.tick > _poolAccumulator.intervalMaxTick) _poolAccumulator.intervalMaxTick = _data.tick;
      if (_data.tick < _poolAccumulator.intervalMinTick) _poolAccumulator.intervalMinTick = _data.tick;
    }

    if (_firstSwap) {
      // discards the pre populated values in the first swap
      _poolAccumulator.cumulativeFee0 = uint120(_data.fee0);
      _poolAccumulator.cumulativeFee1 = uint120(_data.fee1);
      _poolAccumulator.cumulativeVolume0 = uint120(_data.volume0);
      _poolAccumulator.cumulativeVolume1 = uint120(_data.volume1);
      _poolAccumulator.cumulativeMevVolume0 = uint120(_data.mevVolume0);
      _poolAccumulator.cumulativeMevVolume1 = uint120(_data.mevVolume1);
      _poolAccumulator.cumulativeMevFee0 = uint120(_data.mevFee0);
      _poolAccumulator.cumulativeMevFee1 = uint120(_data.mevFee1);
      _poolAccumulator.swapCount = 1;
      _poolAccumulator.intervalSwapCount = 1;
    } else {
      unchecked {
        _poolAccumulator.cumulativeFee0 += uint120(_data.fee0);
        _poolAccumulator.cumulativeFee1 += uint120(_data.fee1);
        _poolAccumulator.cumulativeVolume0 += uint120(_data.volume0);
        _poolAccumulator.cumulativeVolume1 += uint120(_data.volume1);
        _poolAccumulator.cumulativeMevVolume0 += uint120(_data.mevVolume0);
        _poolAccumulator.cumulativeMevVolume1 += uint120(_data.mevVolume1);
        _poolAccumulator.cumulativeMevFee0 += uint120(_data.mevFee0);
        _poolAccumulator.cumulativeMevFee1 += uint120(_data.mevFee1);
        _poolAccumulator.swapCount += 1;
        if (_poolAccumulator.intervalSwapCount != type(uint16).max) _poolAccumulator.intervalSwapCount += 1;
      }
    }

    _poolAccumulator.lastTick = _data.tick;
    _poolAccumulator.lastSwapTimestamp = _blockTimestamp;

    _committed = _writeObservation(_pool, _poolAccumulator, _blockTimestamp, _cadence, _firstSwap);

    // this compiles to one SSTORE per packed slot instead of one SSTORE per struct field
    _accumulators[_pool] = _poolAccumulator;
  }

  /// @inheritdoc ICLPoolTape
  function recordVolatility(address _pool, uint48 _volatilityCorrob, uint8 _nOver) external {
    if (msg.sender != elasticFeeModule) revert Unauthorized();

    ObservationBuffer storage poolBuffer = observationBuffers[_pool];
    poolBuffer.observations[poolBuffer.index].volatilityCorrob = _volatilityCorrob;
    Accumulator storage accumulator = _accumulators[_pool];
    accumulator.volatilityCorrob = _volatilityCorrob;
    accumulator.nOver = _nOver;
    emit VolatilityRecorded(_pool, _volatilityCorrob, _nOver);
  }

  /// @inheritdoc IBasePoolTape
  function increaseObservationCardinalityNext(address _pool, uint16 _observationCardinalityNext) external {
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];

    _initializePoolBuffer(_pool, poolBuffer);

    uint16 _current = poolBuffer.cardinalityNext;
    if (_observationCardinalityNext <= _current) return;

    for (uint16 _i = _current; _i < _observationCardinalityNext; ++_i) {
      Observation storage observation = poolBuffer.observations[_i];
      observation.secondsPerStakedLiquidityCumulativeX128 = 1; // slot 1
      observation.secondsPerLiquidityCumulativeX128 = 1; // slot 2
      observation.cumulativeVolume0 = 1; // slot 3
      observation.cumulativeFee0 = 1; // slot 4
      observation.cumulativeMevVolume0 = 1; // slot 5
      observation.cumulativeMevFee0 = 1; // slot 6
    }
    poolBuffer.cardinalityNext = _observationCardinalityNext;
    emit ObservationCardinalityIncreased(_pool, _current, _observationCardinalityNext);
  }

  /*////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ICLPoolTape
  function accumulators(address _pool) external view returns (Accumulator memory _accumulator) {
    _accumulator = _accumulators[_pool];
  }

  /// @inheritdoc ICLPoolTape
  function getObservation(address _pool, uint16 _index) external view returns (Observation memory _observation) {
    _observation = observationBuffers[_pool].observations[_index];
  }

  /// @inheritdoc ICLPoolTape
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations) {
    ObservationSlots memory _slots = ObservationSlots({slot2: true, slot3: true, slot4: true, slot5: true, slot6: true});
    _observations = _observe(_pool, _secondsAgo, _slots);
  }

  /// @inheritdoc ICLPoolTape
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo,
    ObservationSlots calldata _slots
  ) external view returns (Observation[] memory _observations) {
    _observations = _observe(_pool, _secondsAgo, _slots);
  }

  /// @inheritdoc ICLPoolTape
  function getVolatilityRing(address _pool) external view returns (VolatilityRing memory _values) {
    (_values.tickRanges, _values.dists, _values.swapCounts) =
      _volatilityRings[_pool].values(_accumulators[_pool].volatilityRingHead, _accumulators[_pool].volatilityRingCount);
  }

  /*////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc BasePoolTape
  /// @dev Does not pre-populate `lastSwapTimestamp` so {record} can detect the first swap.
  function _initializePool(address _pool) internal override {
    Accumulator storage accumulator = _accumulators[_pool];
    if (accumulator.lastObservationTimestamp != 0 || accumulator.lastSwapTimestamp != 0) return;
    accumulator.lastObservationTimestamp = 1;
    accumulator.cumulativeVolume0 = 1;
    accumulator.cumulativeFee0 = 1;
    accumulator.cumulativeMevVolume0 = 1;
    accumulator.cumulativeMevFee0 = 1;
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];
    // observation zero index is written by the first swap, so warm the two first slots set
    Observation storage firstObservation = poolBuffer.observations[0];
    firstObservation.secondsPerStakedLiquidityCumulativeX128 = 1; // slot 1
    firstObservation.secondsPerLiquidityCumulativeX128 = 1; // slot 2
    _initializePoolBuffer(_pool, poolBuffer);
  }

  /// @notice Sets cardinality to one for a fresh pool's observation buffer.
  /// @dev Returns without writing when the buffer already holds a cardinality, so callers can seed blindly.
  /// @param _pool The pool whose observation buffer is being initialized.
  /// @param poolBuffer The pool's buffer storage reference.
  function _initializePoolBuffer(address _pool, ObservationBuffer storage poolBuffer) internal {
    if (poolBuffer.cardinality != 0) return;
    poolBuffer.cardinality = 1;
    poolBuffer.cardinalityNext = 1;
    emit PoolObservationBufferInitialized(_pool, uint48(block.timestamp));
  }

  /// @notice Seeds the buffer on first use, then commits the accumulator snapshot once the
  ///         cadence boundary has been crossed.
  /// @dev Mutates the accumulator in memory and the {record} function writes it in storage.
  /// @param _pool The pool committing.
  /// @param _poolAccumulator The accumulator snapshot.
  /// @param _blockTimestamp The block timestamp.
  /// @param _cadence The pool's resolved cadence in seconds.
  /// @param _firstSwap True on the pool's first recorded swap.
  /// @return True when a new observation has been committed.
  function _writeObservation(
    address _pool,
    Accumulator memory _poolAccumulator,
    uint40 _blockTimestamp,
    uint32 _cadence,
    bool _firstSwap
  ) internal returns (bool) {
    if (!_firstSwap) {
      uint256 _elapsed;
      unchecked {
        _elapsed = _blockTimestamp - _poolAccumulator.lastObservationTimestamp;
      }
      if (_elapsed <= _cadence) return false;
    }

    ObservationBuffer storage poolBuffer = observationBuffers[_pool];

    if (_firstSwap) {
      // registration seeds the buffer, so slot zero already exists
      Observation storage firstObservation = poolBuffer.observations[0];
      firstObservation.blockTimestamp = _blockTimestamp;
      firstObservation.secondsPerStakedLiquidityCumulativeX128 = _fetchStakedCumulative(_pool);
      firstObservation.secondsPerLiquidityCumulativeX128 = _fetchSecondsPerLiquidityCumulativeX128(_pool, 0);
      firstObservation.closeTick = _poolAccumulator.lastTick;
      _poolAccumulator.lastObservationTimestamp = _blockTimestamp;
      _poolAccumulator.intervalOpenTick = _poolAccumulator.lastTick;
      return false;
    }

    _pushVolatility(_pool, _poolAccumulator);

    uint16 _cardinality = poolBuffer.cardinality;
    uint16 _index = poolBuffer.index;
    uint16 _cardinalityNext = poolBuffer.cardinalityNext;
    uint16 _newCardinality = _cardinality;
    /// @dev Grows by one slot per write since there is no `initialized` flag on `Observation`.
    ///      This ensures that every read only hits initialized slots.
    if (_cardinalityNext > _cardinality && _index == _cardinality - 1) {
      _newCardinality = _cardinality + 1;
    }
    uint16 _newIndex = (_index + 1) % _newCardinality;

    poolBuffer.observations[_newIndex] = Observation({
      secondsPerStakedLiquidityCumulativeX128: _fetchStakedCumulative(_pool),
      blockTimestamp: _blockTimestamp,
      swapCount: _poolAccumulator.swapCount,
      closeTick: _poolAccumulator.lastTick,
      secondsPerLiquidityCumulativeX128: _fetchSecondsPerLiquidityCumulativeX128(_pool, 0),
      volatilityCorrob: 0,
      cumulativeVolume0: _poolAccumulator.cumulativeVolume0,
      cumulativeVolume1: _poolAccumulator.cumulativeVolume1,
      cumulativeFee0: _poolAccumulator.cumulativeFee0,
      cumulativeFee1: _poolAccumulator.cumulativeFee1,
      cumulativeMevVolume0: _poolAccumulator.cumulativeMevVolume0,
      cumulativeMevVolume1: _poolAccumulator.cumulativeMevVolume1,
      cumulativeMevFee0: _poolAccumulator.cumulativeMevFee0,
      cumulativeMevFee1: _poolAccumulator.cumulativeMevFee1
    });
    poolBuffer.index = _newIndex;
    if (_newCardinality != _cardinality) poolBuffer.cardinality = _newCardinality;

    _poolAccumulator.lastObservationTimestamp = _blockTimestamp;
    _poolAccumulator.intervalMaxTick = _poolAccumulator.lastTick;
    _poolAccumulator.intervalMinTick = _poolAccumulator.lastTick;
    _poolAccumulator.intervalOpenTick = _poolAccumulator.lastTick;
    _poolAccumulator.intervalSwapCount = 0;

    emit ObservationRecorded(_pool, _newIndex, _blockTimestamp);

    return true;
  }

  /// @notice Pushes the interval's `{range, dist, m}` triple into the pool's volatility ring.
  /// @dev The dist is the difference between the interval open and close ticks.
  /// @dev Delegates the packing and ring advance to {VolatilityRingLibrary} and then writes the returned head and
  ///      count onto the accumulator in memory, which is then saved in storage.
  /// @param _pool The pool pushing the volatility result.
  /// @param _poolAccumulator The accumulator snapshot.
  function _pushVolatility(address _pool, Accumulator memory _poolAccumulator) internal {
    uint24 _range = uint24(_poolAccumulator.intervalMaxTick - _poolAccumulator.intervalMinTick);
    uint24 _dist = uint24(FixedPointMathLib.dist(_poolAccumulator.lastTick, _poolAccumulator.intervalOpenTick));
    (_poolAccumulator.volatilityRingHead, _poolAccumulator.volatilityRingCount) = _volatilityRings[_pool].push(
      _poolAccumulator.volatilityRingHead,
      _poolAccumulator.volatilityRingCount,
      _range,
      _dist,
      _poolAccumulator.intervalSwapCount
    );
  }

  /// @notice Reads the pool oracle's active seconds-per-liquidity cumulative at `_secondsAgo`.
  /// @param _pool The pool whose oracle to read.
  /// @param _secondsAgo Offset in seconds before the current block timestamp.
  /// @return _cumulative The pool's secondsPerLiquidityCumulativeX128 at that offset.
  function _fetchSecondsPerLiquidityCumulativeX128(
    address _pool,
    uint32 _secondsAgo
  ) internal view returns (uint160 _cumulative) {
    uint32[] memory _secondsAgos = new uint32[](1);
    _secondsAgos[0] = _secondsAgo;
    // slither-disable-next-line unused-return
    (, uint160[] memory _values) = ICLPoolDerivedState(_pool).observe(_secondsAgos);
    _cumulative = _values[0];
  }

  /// @notice Reads the pool oracle's active seconds-per-liquidity cumulative at a timestamp.
  /// @dev With a low pool oracle cardinality, all its observations can be newer than the tape's newest
  ///      one, so a request for an older timestamp fails with `OLD`. That failure is caught and the value
  ///      is interpolated from the tape's newest observation up to the live one instead.
  /// @param _pool The pool to read.
  /// @param _timestamp The timestamp to read at.
  /// @param poolBuffer The pool's observation buffer.
  /// @return The cumulative at `_timestamp`.
  function _fetchSecondsPerLiquidityCumulativeAt(
    address _pool,
    uint40 _timestamp,
    ObservationBuffer storage poolBuffer
  ) internal view returns (uint160) {
    if (_timestamp >= block.timestamp) {
      return _fetchSecondsPerLiquidityCumulativeX128(_pool, 0);
    }

    uint32[] memory _secondsAgos = new uint32[](1);
    _secondsAgos[0] = uint32(block.timestamp - _timestamp);

    // slither-disable-next-line unused-return
    try ICLPoolDerivedState(_pool).observe(_secondsAgos) returns (int56[] memory, uint160[] memory _values) {
      return _values[0];
    } catch Error(string memory _reason) {
      // Only the 'OLD' failure falls back, any other error reverts.
      if (keccak256(bytes(_reason)) != keccak256('OLD')) revert(_reason);

      Observation storage newest = poolBuffer.observations[poolBuffer.index];
      uint40 _anchorTimestamp = newest.blockTimestamp;
      uint160 _anchorCumulative = newest.secondsPerLiquidityCumulativeX128;
      if (_timestamp <= _anchorTimestamp) return _anchorCumulative;

      unchecked {
        return _interpolateUint160Cumulative(
          _anchorCumulative,
          _fetchSecondsPerLiquidityCumulativeX128(_pool, 0),
          _timestamp - _anchorTimestamp,
          uint40(block.timestamp) - _anchorTimestamp
        );
      }
    }
  }

  /// @notice Reads the pool's live cumulative seconds per unit of staked liquidity.
  /// @param _pool The pool to read.
  /// @return _cumulative The cumulative at the current block timestamp.
  function _fetchStakedCumulative(address _pool) internal view returns (uint160 _cumulative) {
    _cumulative = ICLPoolDerivedState(_pool).getSecondsPerStakedLiquidityCumulativeX128();
  }

  /// @notice Reads the pool's cumulative seconds per unit of staked liquidity at a timestamp.
  /// @param _pool The pool to read.
  /// @param _timestamp The timestamp to read at.
  /// @param poolBuffer The pool's observation buffer.
  /// @return The cumulative at `_timestamp`.
  function _fetchStakedCumulativeAt(
    address _pool,
    uint40 _timestamp,
    ObservationBuffer storage poolBuffer
  ) internal view returns (uint160) {
    if (_timestamp >= block.timestamp) return _fetchStakedCumulative(_pool);

    Observation storage newest = poolBuffer.observations[poolBuffer.index];
    uint40 _anchorTimestamp = newest.blockTimestamp;
    uint160 _anchorCumulative = newest.secondsPerStakedLiquidityCumulativeX128;
    if (_timestamp <= _anchorTimestamp) return _anchorCumulative;

    uint48 _lastUpdated = ICLPoolState(_pool).lastUpdated();
    uint160 _latestSecondsPerStakedLiquidityValue = ICLPoolState(_pool).secondsPerStakedLiquidityCumulativeX128();

    unchecked {
      // _anchorTimestamp < _timestamp < _lastUpdated
      if (_timestamp < _lastUpdated) {
        return _interpolateUint160Cumulative(
          _anchorCumulative,
          _latestSecondsPerStakedLiquidityValue,
          _timestamp - _anchorTimestamp,
          _lastUpdated - _anchorTimestamp
        );
      }

      // _lastUpdated <= _timestamp < block.timestamp
      return _interpolateUint160Cumulative(
        _latestSecondsPerStakedLiquidityValue,
        _fetchStakedCumulative(_pool),
        _timestamp - _lastUpdated,
        block.timestamp - _lastUpdated
      );
    }
  }

  /*////////////////////////////////////////////////////////////
                    OBSERVE INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Resolves every `_secondsAgo` offset into an observation, loading only requested slots.
  /// @param _pool The pool to read.
  /// @param _secondsAgo The past timestamps to read.
  /// @param _slots The observation slots to load.
  /// @return _observations One observation per timestamp.
  function _observe(
    address _pool,
    uint48[] calldata _secondsAgo,
    ObservationSlots memory _slots
  ) internal view returns (Observation[] memory _observations) {
    ObservationBuffer storage poolBuffer = observationBuffers[_pool];
    Accumulator memory _poolAccumulator = _loadAccumulator(_pool, _slots);
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _observations[_i] = _observeSingle(poolBuffer, _poolAccumulator, _pool, _secondsAgo[_i], _slots);
    }
  }

  /// @notice Loads the accumulator slots that have been requested only. Unloaded fields stay zero.
  /// @param _pool The pool to read.
  /// @param _slots The observation slots to load.
  /// @return _poolAccumulator The partially loaded accumulator.
  function _loadAccumulator(
    address _pool,
    ObservationSlots memory _slots
  ) internal view returns (Accumulator memory _poolAccumulator) {
    Accumulator storage accumulator = _accumulators[_pool];
    // lastSwapTimestamp is always needed so the whole accumulator slot 1 is loaded
    _poolAccumulator.lastSwapTimestamp = accumulator.lastSwapTimestamp;
    _poolAccumulator.swapCount = accumulator.swapCount;
    _poolAccumulator.lastTick = accumulator.lastTick;
    _poolAccumulator.volatilityCorrob = accumulator.volatilityCorrob;
    if (_slots.slot3) {
      _poolAccumulator.cumulativeVolume0 = accumulator.cumulativeVolume0;
      _poolAccumulator.cumulativeVolume1 = accumulator.cumulativeVolume1;
    }
    if (_slots.slot4) {
      _poolAccumulator.cumulativeFee0 = accumulator.cumulativeFee0;
      _poolAccumulator.cumulativeFee1 = accumulator.cumulativeFee1;
    }
    if (_slots.slot5) {
      _poolAccumulator.cumulativeMevVolume0 = accumulator.cumulativeMevVolume0;
      _poolAccumulator.cumulativeMevVolume1 = accumulator.cumulativeMevVolume1;
    }
    if (_slots.slot6) {
      _poolAccumulator.cumulativeMevFee0 = accumulator.cumulativeMevFee0;
      _poolAccumulator.cumulativeMevFee1 = accumulator.cumulativeMevFee1;
    }
  }

  /// @notice Loads the requested slots of a stored observation into memory.
  /// @dev `blockTimestamp` is always loaded because search and interpolation need it.
  /// @param observation The stored observation.
  /// @param _slots The observation slots to load.
  /// @return _observation The partially loaded observation.
  function _loadObservation(
    Observation storage observation,
    ObservationSlots memory _slots
  ) internal view returns (Observation memory _observation) {
    // blockTimestamp is always needed so the whole slot 1 is loaded
    _observation.secondsPerStakedLiquidityCumulativeX128 = observation.secondsPerStakedLiquidityCumulativeX128;
    _observation.blockTimestamp = observation.blockTimestamp;
    _observation.swapCount = observation.swapCount;
    _observation.closeTick = observation.closeTick;
    if (_slots.slot2) {
      _observation.secondsPerLiquidityCumulativeX128 = observation.secondsPerLiquidityCumulativeX128;
      _observation.volatilityCorrob = observation.volatilityCorrob;
    }
    if (_slots.slot3) {
      _observation.cumulativeVolume0 = observation.cumulativeVolume0;
      _observation.cumulativeVolume1 = observation.cumulativeVolume1;
    }
    if (_slots.slot4) {
      _observation.cumulativeFee0 = observation.cumulativeFee0;
      _observation.cumulativeFee1 = observation.cumulativeFee1;
    }
    if (_slots.slot5) {
      _observation.cumulativeMevVolume0 = observation.cumulativeMevVolume0;
      _observation.cumulativeMevVolume1 = observation.cumulativeMevVolume1;
    }
    if (_slots.slot6) {
      _observation.cumulativeMevFee0 = observation.cumulativeMevFee0;
      _observation.cumulativeMevFee1 = observation.cumulativeMevFee1;
    }
  }

  /// @notice Resolves a single `_secondsAgo` offset into an observation by interpolating between
  ///         surrounding observations.
  /// @param poolBuffer The observation buffer.
  /// @param _poolAccumulator The pool's current accumulator.
  /// @param _pool The pool related to the observation buffer.
  /// @param _secondsAgo Offset into the past from the current timestamp. `0` requests the current accumulator.
  /// @param _slots The observation slots to load.
  /// @return _observation Observation at `block.timestamp - _secondsAgo`.
  function _observeSingle(
    ObservationBuffer storage poolBuffer,
    Accumulator memory _poolAccumulator,
    address _pool,
    uint48 _secondsAgo,
    ObservationSlots memory _slots
  ) internal view returns (Observation memory _observation) {
    uint40 _lastSwapTimestamp = _poolAccumulator.lastSwapTimestamp;

    // A pool with no recorded swap, including an unregistered pool, has no data, so return a zeroed observation.
    if (_lastSwapTimestamp == 0) return _observation;

    uint40 _blockTimestamp = uint40(block.timestamp);

    // A zero offset returns the current accumulator with the current block timestamp.
    if (_secondsAgo == 0) {
      return _accumulatorToObservation(poolBuffer, _pool, _poolAccumulator, _blockTimestamp, _slots);
    }

    uint40 _target = _secondsAgo >= _blockTimestamp ? 0 : uint40(_blockTimestamp - _secondsAgo);

    // A target at or after the last swap returns the current accumulator with the requested target.
    // An observation cannot be newer than the current accumulator.
    if (_target >= _lastSwapTimestamp) {
      return _accumulatorToObservation(poolBuffer, _pool, _poolAccumulator, _target, _slots);
    }

    (Observation memory _beforeOrAt, Observation memory _atOrAfter) =
      _getSurroundingObservations(poolBuffer, _poolAccumulator, _pool, _target, _slots);

    if (_target >= _atOrAfter.blockTimestamp) return _atOrAfter;
    if (_target <= _beforeOrAt.blockTimestamp) return _beforeOrAt;
    return _interpolate(_beforeOrAt, _atOrAfter, _target);
  }

  /// @notice Returns the observations bracketing `_target`.
  /// @param poolBuffer The observation buffer.
  /// @param _poolAccumulator The pool's current accumulator.
  /// @param _pool The pool related to the observation buffer.
  /// @param _target Timestamp to locate inside or relative to the populated range.
  /// @param _slots The observation slots to load.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _getSurroundingObservations(
    ObservationBuffer storage poolBuffer,
    Accumulator memory _poolAccumulator,
    address _pool,
    uint40 _target,
    ObservationSlots memory _slots
  ) internal view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    Observation[65_535] storage observations = poolBuffer.observations;
    uint16 _index = poolBuffer.index;
    uint16 _cardinality = poolBuffer.cardinality;

    // A target at or after the newest committed observation is bracketed by it and the current accumulator.
    if (_target >= observations[_index].blockTimestamp) {
      return (
        _loadObservation(observations[_index], _slots),
        _accumulatorToObservation(poolBuffer, _pool, _poolAccumulator, _poolAccumulator.lastSwapTimestamp, _slots)
      );
    }

    uint16 _oldestIndex = (_index + 1) % _cardinality;

    // A target at or before the oldest observation returns the oldest observation directly.
    if (_target <= observations[_oldestIndex].blockTimestamp) {
      Observation memory _oldestCommittedObservation = _loadObservation(observations[_oldestIndex], _slots);
      return (_oldestCommittedObservation, _oldestCommittedObservation);
    }

    // A target between the oldest and newest committed observations is bracketed by
    // two observations found by binary search.
    return _binarySearch(observations, _index, _cardinality, _target, _slots);
  }

  /// @notice Binary searches the active buffer for the observations bracketing `_target`.
  /// @param observations The pool's observation buffer.
  /// @param _index Index of the newest committed observation.
  /// @param _cardinality Number of populated slots in the buffer.
  /// @param _target Timestamp to bracket.
  /// @param _slots The observation slots to load.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _binarySearch(
    Observation[65_535] storage observations,
    uint16 _index,
    uint16 _cardinality,
    uint40 _target,
    ObservationSlots memory _slots
  ) internal view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    uint256 _left = (uint256(_index) + 1) % _cardinality; // oldest reachable slot
    uint256 _right = _left + _cardinality - 1; // newest written slot
    while (true) {
      uint256 _mid = (_left + _right) / 2;
      uint16 _beforeIndex = uint16(_mid % _cardinality);
      uint16 _afterIndex = uint16((_mid + 1) % _cardinality);
      uint40 _beforeTimestamp = observations[_beforeIndex].blockTimestamp;
      uint40 _afterTimestamp = observations[_afterIndex].blockTimestamp;
      if (_beforeTimestamp <= _target && _target <= _afterTimestamp) {
        _beforeOrAt = _loadObservation(observations[_beforeIndex], _slots);
        _atOrAfter = _loadObservation(observations[_afterIndex], _slots);
        break;
      }
      if (_beforeTimestamp <= _target) _left = _mid + 1;
      else _right = _mid - 1;
    }
  }

  /// @notice Builds an Observation from the current accumulator with `_timestamp`.
  /// @dev Neither liquidity cumulative lives on the accumulator, so both come from the pool.
  /// @param poolBuffer The pool's observation buffer.
  /// @param _pool The pool related to the observation buffer.
  /// @param _poolAccumulator The current accumulator to convert.
  /// @param _timestamp The timestamp to write on the returned observation.
  /// @param _slots The observation slots to load.
  /// @return _observation The current cumulatives as an Observation with `_timestamp` as blockTimestamp.
  function _accumulatorToObservation(
    ObservationBuffer storage poolBuffer,
    address _pool,
    Accumulator memory _poolAccumulator,
    uint40 _timestamp,
    ObservationSlots memory _slots
  ) internal view returns (Observation memory _observation) {
    _observation.blockTimestamp = _timestamp;
    _observation.swapCount = _poolAccumulator.swapCount;
    _observation.closeTick = _poolAccumulator.lastTick;
    _observation.secondsPerStakedLiquidityCumulativeX128 = _fetchStakedCumulativeAt(_pool, _timestamp, poolBuffer);

    if (_slots.slot2) {
      _observation.volatilityCorrob = _poolAccumulator.volatilityCorrob;
      // Active in-range liquidity can change between swaps through LP mint and burn, so read the accurate
      // cumulative at the target directly from the pool oracle.
      _observation.secondsPerLiquidityCumulativeX128 =
        _fetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp, poolBuffer);
    }
    if (_slots.slot3) {
      _observation.cumulativeVolume0 = _poolAccumulator.cumulativeVolume0;
      _observation.cumulativeVolume1 = _poolAccumulator.cumulativeVolume1;
    }
    if (_slots.slot4) {
      _observation.cumulativeFee0 = _poolAccumulator.cumulativeFee0;
      _observation.cumulativeFee1 = _poolAccumulator.cumulativeFee1;
    }
    if (_slots.slot5) {
      _observation.cumulativeMevVolume0 = _poolAccumulator.cumulativeMevVolume0;
      _observation.cumulativeMevVolume1 = _poolAccumulator.cumulativeMevVolume1;
    }
    if (_slots.slot6) {
      _observation.cumulativeMevFee0 = _poolAccumulator.cumulativeMevFee0;
      _observation.cumulativeMevFee1 = _poolAccumulator.cumulativeMevFee1;
    }
  }

  /// @notice Interpolates the cumulative fields at `_target` between two observation points: `_beforeOrAt` and
  ///         `_atOrAfter`.
  /// @dev When `_target` equals `_atOrAfter.blockTimestamp` the result equals the `_atOrAfter` cumulative fields.
  /// @dev When `_target` equals `_beforeOrAt.blockTimestamp` the result equals the `_beforeOrAt` cumulative fields.
  /// @dev `_target` should fall between `_beforeOrAt.blockTimestamp` and `_atOrAfter.blockTimestamp` (inclusive).
  /// @dev The snapshot fields `closeTick` and `volatilityCorrob` are not interpolated, they pass through from
  ///      `_beforeOrAt`. `volatilityCorrob` stays zero unless slot2 is requested.
  /// @dev Fields zeroed by specific slot loading interpolate to zero.
  /// @param _beforeOrAt Observation at or before `_target` chronologically.
  /// @param _atOrAfter Observation at or after `_target` chronologically.
  /// @param _target Timestamp at which to evaluate the interpolation.
  /// @return _observation The interpolated observation at timestamp `_target`.
  function _interpolate(
    Observation memory _beforeOrAt,
    Observation memory _atOrAfter,
    uint40 _target
  ) internal pure returns (Observation memory _observation) {
    uint256 _beforeToAfterTimeDelta = _atOrAfter.blockTimestamp - _beforeOrAt.blockTimestamp;
    uint256 _beforeToTargetTimeDelta = _target - _beforeOrAt.blockTimestamp;

    _observation.blockTimestamp = _target;
    _observation.cumulativeVolume0 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeVolume0, _atOrAfter.cumulativeVolume0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeVolume1 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeVolume1, _atOrAfter.cumulativeVolume1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.secondsPerLiquidityCumulativeX128 = _interpolateUint160Cumulative(
      _beforeOrAt.secondsPerLiquidityCumulativeX128,
      _atOrAfter.secondsPerLiquidityCumulativeX128,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    _observation.volatilityCorrob = _beforeOrAt.volatilityCorrob;
    _observation.secondsPerStakedLiquidityCumulativeX128 = _interpolateUint160Cumulative(
      _beforeOrAt.secondsPerStakedLiquidityCumulativeX128,
      _atOrAfter.secondsPerStakedLiquidityCumulativeX128,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    uint256 _swapCountDelta;
    unchecked {
      _swapCountDelta = _atOrAfter.swapCount - _beforeOrAt.swapCount;
    }
    _observation.swapCount =
      uint32(_beforeOrAt.swapCount + (_swapCountDelta * _beforeToTargetTimeDelta) / _beforeToAfterTimeDelta);
    _observation.closeTick = _beforeOrAt.closeTick;
    _observation.cumulativeFee0 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeFee0, _atOrAfter.cumulativeFee0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeFee1 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeFee1, _atOrAfter.cumulativeFee1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevVolume0 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeMevVolume0,
      _atOrAfter.cumulativeMevVolume0,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevVolume1 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeMevVolume1,
      _atOrAfter.cumulativeMevVolume1,
      _beforeToTargetTimeDelta,
      _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevFee0 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeMevFee0, _atOrAfter.cumulativeMevFee0, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
    _observation.cumulativeMevFee1 = _interpolateUint120Cumulative(
      _beforeOrAt.cumulativeMevFee1, _atOrAfter.cumulativeMevFee1, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta
    );
  }

  /// @notice Linearly interpolates a single uint120 cumulative field.
  /// @dev The before/after subtraction is `unchecked` so the math holds across a uint120 cumulative wrap.
  /// @param _beforeValue The field value at the before observation.
  /// @param _afterValue The field value at the after observation.
  /// @param _beforeToTargetTimeDelta Seconds from the before observation to the target.
  /// @param _beforeToAfterTimeDelta Seconds from the before observation to the after observation.
  /// @return _value The interpolated field value.
  function _interpolateUint120Cumulative(
    uint120 _beforeValue,
    uint120 _afterValue,
    uint256 _beforeToTargetTimeDelta,
    uint256 _beforeToAfterTimeDelta
  ) internal pure returns (uint120 _value) {
    uint256 _valueDelta;
    unchecked {
      _valueDelta = _afterValue - _beforeValue;
    }
    _value = uint120(_beforeValue + (_valueDelta * _beforeToTargetTimeDelta) / _beforeToAfterTimeDelta);
  }

  /// @notice Linearly interpolates a single uint160 cumulative field.
  /// @dev The before/after subtraction is `unchecked` so the math holds across a uint160 cumulative wrap.
  /// @param _beforeValue The field value at the before observation.
  /// @param _afterValue The field value at the after observation.
  /// @param _beforeToTargetTimeDelta Seconds from the before observation to the target.
  /// @param _beforeToAfterTimeDelta Seconds from the before observation to the after observation.
  /// @return _value The interpolated field value.
  function _interpolateUint160Cumulative(
    uint160 _beforeValue,
    uint160 _afterValue,
    uint256 _beforeToTargetTimeDelta,
    uint256 _beforeToAfterTimeDelta
  ) internal pure returns (uint160 _value) {
    uint256 _valueDelta;
    unchecked {
      _valueDelta = _afterValue - _beforeValue;
    }
    _value = uint160(_beforeValue + (_valueDelta * _beforeToTargetTimeDelta) / _beforeToAfterTimeDelta);
  }
}
