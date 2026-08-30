// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeWriteObservation is UnitClPoolTapeBase {
  modifier whenItIsTheFirstSwap() {
    _;
  }

  function test_WhenItIsTheFirstSwap(
    int24 _lastTick,
    uint160 _stakedCumulative,
    uint160 _activeCumulative,
    uint40 _blockTimestamp
  ) external whenItIsTheFirstSwap {
    _lastTick = int24(bound(_lastTick, _MIN_TICK, _MAX_TICK));
    _blockTimestamp = uint40(bound(_blockTimestamp, 1, type(uint40).max));

    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setObservationTimestamp({_index: 0, _blockTimestamp: 1});
    vm.warp(_blockTimestamp);
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _stakedCumulative});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _activeCumulative, _secondsAgo: 0
    });

    ICLPoolTape.Accumulator memory _accumulator;
    _accumulator.lastTick = _lastTick;

    bool _committed = MockCLPoolTape(address(_tape))
      .externalWriteObservation(_pool, _accumulator, _blockTimestamp, _DEFAULT_CADENCE, true);

    ICLPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    // it updates slot zero with the swap timestamp
    assertEq(_obs.blockTimestamp, _blockTimestamp);
    // it sets the staked cumulative value from the pool
    assertEq(_obs.secondsPerStakedLiquidityCumulativeX128, _stakedCumulative);
    // it sets the active cumulative value from the pool oracle
    assertEq(_obs.secondsPerLiquidityCumulativeX128, _activeCumulative);
    // it seeds slot zero close tick from the last tick
    assertEq(_obs.closeTick, _lastTick);

    ICLPoolTape.Accumulator memory _storedAccumulator = _tape.accumulators(_pool);
    // it sets lastObservationTimestamp on the accumulator
    assertEq(_storedAccumulator.lastObservationTimestamp, _blockTimestamp);
    // it sets intervalOpenTick from the last tick
    assertEq(_storedAccumulator.intervalOpenTick, _lastTick);
    // it returns committed as false
    assertFalse(_committed);
  }

  modifier whenItIsNotTheFirstSwap() {
    _;
  }

  function test_WhenTheElapsedTimeSinceTheLastObservationIsLteTheCadence(
    uint32 _cadence,
    uint40 _elapsed
  ) external whenItIsNotTheFirstSwap {
    _elapsed = uint40(bound(_elapsed, 0, _cadence));

    ICLPoolTape.Accumulator memory _accumulator;

    bool _committed =
      MockCLPoolTape(address(_tape)).externalWriteObservation(_pool, _accumulator, _elapsed, _cadence, false);

    // it returns committed as false
    assertFalse(_committed);
  }

  modifier whenTheElapsedTimeSinceTheLastObservationIsGtTheCadence() {
    _;
  }

  function test_WhenTheElapsedTimeSinceTheLastObservationIsGtTheCadence(
    ICLPoolTape.Accumulator memory _accumulator,
    uint160 _stakedCumulative,
    uint160 _activeCumulative,
    uint32 _cadence,
    uint40 _elapsed
  ) external whenItIsNotTheFirstSwap whenTheElapsedTimeSinceTheLastObservationIsGtTheCadence {
    _accumulator.intervalMinTick = int24(bound(_accumulator.intervalMinTick, _MIN_TICK, _MAX_TICK));
    _accumulator.intervalMaxTick = int24(bound(_accumulator.intervalMaxTick, _accumulator.intervalMinTick, _MAX_TICK));
    _accumulator.lastTick = int24(bound(_accumulator.lastTick, _MIN_TICK, _MAX_TICK));
    _accumulator.intervalOpenTick = int24(bound(_accumulator.intervalOpenTick, _MIN_TICK, _MAX_TICK));
    _accumulator.lastObservationTimestamp = 0;
    _accumulator.volatilityRingHead = 0;
    _accumulator.volatilityRingCount = 0;
    _elapsed = uint40(bound(_elapsed, uint256(_cadence) + 1, type(uint40).max));

    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    vm.warp(_elapsed);
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _stakedCumulative});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _activeCumulative, _secondsAgo: 0
    });

    vm.record();
    // it emits ObservationRecorded
    vm.expectEmit();
    emit IBasePoolTape.ObservationRecorded(_pool, 0, _elapsed);
    bool _committed =
      MockCLPoolTape(address(_tape)).externalWriteObservation(_pool, _accumulator, _elapsed, _cadence, false);
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    // it returns committed as true
    assertTrue(_committed);

    ICLPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    // it sets every observation field from the accumulator and the pool with a zeroed volatilityCorrob
    assertEq(_obs.secondsPerStakedLiquidityCumulativeX128, _stakedCumulative);
    assertEq(_obs.blockTimestamp, _elapsed);
    assertEq(_obs.swapCount, _accumulator.swapCount);
    assertEq(_obs.closeTick, _accumulator.lastTick);
    assertEq(_obs.secondsPerLiquidityCumulativeX128, _activeCumulative);
    assertEq(_obs.volatilityCorrob, 0);
    assertEq(_obs.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_obs.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_obs.cumulativeFee0, _accumulator.cumulativeFee0);
    assertEq(_obs.cumulativeFee1, _accumulator.cumulativeFee1);
    assertEq(_obs.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_obs.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_obs.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_obs.cumulativeMevFee1, _accumulator.cumulativeMevFee1);

    // it pushes the interval range dist and swap count into the pool ring
    ICLPoolTape.VolatilityRing memory _ring = _tape.getVolatilityRing(_pool);
    assertEq(_ring.tickRanges[0], uint24(_accumulator.intervalMaxTick - _accumulator.intervalMinTick));
    assertEq(
      _ring.dists[0],
      _accumulator.lastTick >= _accumulator.intervalOpenTick
        ? uint24(_accumulator.lastTick - _accumulator.intervalOpenTick)
        : uint24(_accumulator.intervalOpenTick - _accumulator.lastTick)
    );
    assertEq(_ring.swapCounts[0], _accumulator.intervalSwapCount);

    ICLPoolTape.Accumulator memory _storedAccumulator = _tape.accumulators(_pool);
    // it writes the returned head and count into the accumulator
    assertEq(_storedAccumulator.volatilityRingHead, 1);
    assertEq(_storedAccumulator.volatilityRingCount, 1);
    // it resets the interval values
    assertEq(_storedAccumulator.intervalMaxTick, _accumulator.lastTick);
    assertEq(_storedAccumulator.intervalMinTick, _accumulator.lastTick);
    assertEq(_storedAccumulator.intervalOpenTick, _accumulator.lastTick);
    assertEq(_storedAccumulator.intervalSwapCount, 0);
    // it sets lastObservationTimestamp to the swap timestamp
    assertEq(_storedAccumulator.lastObservationTimestamp, _elapsed);
  }

  function test_WhenTheIntervalOpenTickSitsOutsideTheIntervalExtremes()
    external
    whenItIsNotTheFirstSwap
    whenTheElapsedTimeSinceTheLastObservationIsGtTheCadence
  {
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    vm.warp(100);
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: 0});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: 0, _secondsAgo: 0
    });

    ICLPoolTape.Accumulator memory _accumulator = _committingAccumulator({
      _lastTick: 5, _intervalMaxTick: 10, _intervalMinTick: 0, _intervalOpenTick: 1000, _intervalSwapCount: 1
    });

    MockCLPoolTape(address(_tape)).externalWriteObservation(_pool, _accumulator, 100, 60, false);

    // it stores a dist greater than the range
    ICLPoolTape.VolatilityRing memory _ring = _tape.getVolatilityRing(_pool);
    assertEq(_ring.tickRanges[0], 10);
    assertEq(_ring.dists[0], 995);
    assertGt(_ring.dists[0], _ring.tickRanges[0]);
  }

  function test_WhenTheBufferIsNotFull(
    uint16 _cardinality,
    uint16 _cardinalityNext,
    int24 _lastTick,
    uint160 _stakedCumulative,
    uint160 _activeCumulative,
    uint32 _cadence,
    uint40 _elapsed
  ) external whenItIsNotTheFirstSwap whenTheElapsedTimeSinceTheLastObservationIsGtTheCadence {
    _cardinality = uint16(bound(_cardinality, 1, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _cardinalityNext = uint16(bound(_cardinalityNext, _cardinality + 1, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _lastTick = int24(bound(_lastTick, _MIN_TICK, _MAX_TICK));
    _elapsed = uint40(bound(_elapsed, uint256(_cadence) + 1, type(uint40).max));
    uint16 _index = _cardinality - 1;

    _setObservationInformationSlot({_index: _index, _cardinality: _cardinality, _cardinalityNext: _cardinalityNext});
    _setObservationTimestamp({_index: _index, _blockTimestamp: 1});
    vm.warp(_elapsed);
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _stakedCumulative});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _activeCumulative, _secondsAgo: 0
    });

    ICLPoolTape.Accumulator memory _accumulator = _committingAccumulator({
      _lastTick: _lastTick,
      _intervalMaxTick: _lastTick,
      _intervalMinTick: _lastTick,
      _intervalOpenTick: _lastTick,
      _intervalSwapCount: 1
    });

    MockCLPoolTape(address(_tape)).externalWriteObservation(_pool, _accumulator, _elapsed, _cadence, false);

    (uint16 _newIndex, uint16 _newCardinality, uint16 _newCardinalityNext) = _tape.observationBuffers(_pool);
    // it increases cardinality by one
    assertEq(_newCardinality, _cardinality + 1);
    // it increases index by one
    assertEq(_newIndex, _cardinality);
    assertEq(_newCardinalityNext, _cardinalityNext);

    // it writes the new observation at the newly grown slot
    ICLPoolTape.Observation memory _obs = _tape.getObservation(_pool, _newIndex);
    assertEq(_obs.blockTimestamp, _elapsed);
    assertEq(_obs.closeTick, _lastTick);
    assertEq(_obs.secondsPerStakedLiquidityCumulativeX128, _stakedCumulative);
  }

  function test_WhenTheBufferIsFull(
    uint16 _cardinality,
    int24 _lastTick,
    uint160 _stakedCumulative,
    uint160 _activeCumulative,
    uint32 _cadence,
    uint40 _elapsed
  ) external whenItIsNotTheFirstSwap whenTheElapsedTimeSinceTheLastObservationIsGtTheCadence {
    _cardinality = uint16(bound(_cardinality, 2, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _lastTick = int24(bound(_lastTick, _MIN_TICK, _MAX_TICK));
    _elapsed = uint40(bound(_elapsed, uint256(_cadence) + 1, type(uint40).max));
    uint16 _index = _cardinality - 1;

    _setObservationInformationSlot({_index: _index, _cardinality: _cardinality, _cardinalityNext: _cardinality});
    _setObservationTimestamp({_index: 0, _blockTimestamp: 1});
    _setObservationTimestamp({_index: _index, _blockTimestamp: 2});
    vm.warp(_elapsed);
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _stakedCumulative});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _activeCumulative, _secondsAgo: 0
    });

    ICLPoolTape.Accumulator memory _accumulator = _committingAccumulator({
      _lastTick: _lastTick,
      _intervalMaxTick: _lastTick,
      _intervalMinTick: _lastTick,
      _intervalOpenTick: _lastTick,
      _intervalSwapCount: 1
    });

    MockCLPoolTape(address(_tape)).externalWriteObservation(_pool, _accumulator, _elapsed, _cadence, false);

    (uint16 _newIndex, uint16 _newCardinality, uint16 _newCardinalityNext) = _tape.observationBuffers(_pool);
    // it keeps the cardinality unchanged
    assertEq(_newCardinality, _cardinality);
    assertEq(_newCardinalityNext, _cardinality);
    // it wraps the index to zero
    assertEq(_newIndex, 0);

    // it overwrites the oldest slot
    ICLPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    assertEq(_obs.blockTimestamp, _elapsed);
    assertEq(_obs.closeTick, _lastTick);
    assertEq(_obs.secondsPerStakedLiquidityCumulativeX128, _stakedCumulative);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Deploys `MockCLPoolTape` so the internal `_writeObservation` can be exercised directly.
  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }

  function _committingAccumulator(
    int24 _lastTick,
    int24 _intervalMaxTick,
    int24 _intervalMinTick,
    int24 _intervalOpenTick,
    uint16 _intervalSwapCount
  ) internal pure returns (ICLPoolTape.Accumulator memory _accumulator) {
    _accumulator = ICLPoolTape.Accumulator({
      lastSwapTimestamp: 1,
      lastObservationTimestamp: 0,
      swapCount: 1,
      lastTick: _lastTick,
      intervalMaxTick: _intervalMaxTick,
      intervalMinTick: _intervalMinTick,
      intervalOpenTick: _intervalOpenTick,
      volatilityCorrob: 0,
      cumulativeVolume0: 1,
      cumulativeVolume1: 1,
      intervalSwapCount: _intervalSwapCount,
      cumulativeFee0: 1,
      cumulativeFee1: 1,
      volatilityRingHead: 0,
      volatilityRingCount: 0,
      cumulativeMevVolume0: 1,
      cumulativeMevVolume1: 1,
      nOver: 0,
      cumulativeMevFee0: 1,
      cumulativeMevFee1: 1
    });
  }
}
