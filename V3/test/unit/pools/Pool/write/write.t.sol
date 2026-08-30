// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

contract UnitPoolOracleWrite is UnitPool {
  function test_WhenTimeElapsedSinceLastObservationIsLtOrEqToPeriodSize(
    uint32 _timestamp,
    uint32 _elapsed,
    uint32 _periodSize,
    uint256 _r0CumulativeLast,
    uint256 _r1CumulativeLast,
    uint256 _r0CumulativeNew,
    uint256 _r1CumulativeNew
  ) external {
    _elapsed = uint32(bound(_elapsed, 0, _periodSize));
    _setObservationCardinality(1);
    _setObservationCardinalityNext(1);
    _writeObservation({_index: 0, _timestamp: _timestamp, _r0c: _r0CumulativeLast, _r1c: _r1CumulativeLast});

    uint32 _blockTimestamp;
    unchecked {
      _blockTimestamp = _timestamp + _elapsed;
    }

    vm.warp(_blockTimestamp);
    MockPool(address(_pool)).externalWrite(_r0CumulativeNew, _r1CumulativeNew, _periodSize);

    // it should not push a new observation
    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(0);
    assertEq(_ts, _timestamp);
    assertEq(_r0c, _r0CumulativeLast);
    assertEq(_r1c, _r1CumulativeLast);

    (uint16 _index, uint16 _cardinality,) = _pool.observationBuffer();
    // it should not increase cardinality
    assertEq(_cardinality, 1);
    // it should not increase index
    assertEq(_index, 0);
  }

  modifier whenTimeElapsedSinceLastObservationIsGtPeriodSize() {
    _;
  }

  modifier whenCardinalityNextIsLtOrEqToCardinality() {
    _;
  }

  function test_WhenIndexIsLtTheLastAvailableSlot(
    uint16 _currentCardinality,
    uint16 _currentIndex,
    uint16 _currentCardinalityNext,
    uint32 _timestamp,
    uint32 _elapsed,
    uint32 _periodSize,
    uint256 _r0CumulativeLast,
    uint256 _r1CumulativeLast,
    uint256 _r0CumulativeNew,
    uint256 _r1CumulativeNew
  ) external whenTimeElapsedSinceLastObservationIsGtPeriodSize whenCardinalityNextIsLtOrEqToCardinality {
    _currentCardinality = uint16(bound(_currentCardinality, 2, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _currentIndex = uint16(bound(_currentIndex, 0, _currentCardinality - 2));
    _currentCardinalityNext = uint16(bound(_currentCardinalityNext, 1, _currentCardinality));
    _periodSize = uint32(bound(_periodSize, 0, type(uint32).max - 1));
    _elapsed = uint32(bound(_elapsed, uint256(_periodSize) + 1, type(uint32).max));

    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinalityNext
    });
    _writeObservation({_index: _currentIndex, _timestamp: _timestamp, _r0c: _r0CumulativeLast, _r1c: _r1CumulativeLast});

    uint32 _blockTimestamp;
    unchecked {
      _blockTimestamp = _timestamp + _elapsed;
    }

    vm.warp(_blockTimestamp);
    MockPool(address(_pool)).externalWrite(_r0CumulativeNew, _r1CumulativeNew, _periodSize);
    (uint16 _indexUpdated, uint16 _cardinalityUpdated,) = _pool.observationBuffer();

    // it should not increase cardinality
    assertEq(_cardinalityUpdated, _currentCardinality);
    // it should increase index by one modulo cardinality
    assertEq(_indexUpdated, (_currentIndex + 1) % _currentCardinality);
    // it should write the new observation at the advanced slot
    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(_indexUpdated);
    assertEq(_ts, _blockTimestamp);
    assertEq(_r0c, _r0CumulativeNew);
    assertEq(_r1c, _r1CumulativeNew);
  }

  function test_WhenIndexEqTheLastAvailableSlot(
    uint16 _currentCardinality,
    uint32 _timestamp,
    uint32 _elapsed,
    uint32 _periodSize,
    uint256 _oldestR0Cumulative,
    uint256 _oldestR1Cumulative,
    uint256 _r0CumulativeLast,
    uint256 _r1CumulativeLast,
    uint256 _r0CumulativeNew,
    uint256 _r1CumulativeNew
  ) external whenTimeElapsedSinceLastObservationIsGtPeriodSize whenCardinalityNextIsLtOrEqToCardinality {
    _currentCardinality = uint16(bound(_currentCardinality, 2, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    uint16 _currentIndex = _currentCardinality - 1;
    _periodSize = uint32(bound(_periodSize, 0, type(uint32).max - 1));
    _elapsed = uint32(bound(_elapsed, uint256(_periodSize) + 1, type(uint32).max));

    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinality
    });
    // The oldest reachable observation sits at slot zero and is the one the wrap overwrites.
    _writeObservation({_index: 0, _timestamp: _timestamp, _r0c: _oldestR0Cumulative, _r1c: _oldestR1Cumulative});
    _writeObservation({_index: _currentIndex, _timestamp: _timestamp, _r0c: _r0CumulativeLast, _r1c: _r1CumulativeLast});

    uint32 _blockTimestamp;
    unchecked {
      _blockTimestamp = _timestamp + _elapsed;
    }

    vm.warp(_blockTimestamp);
    MockPool(address(_pool)).externalWrite(_r0CumulativeNew, _r1CumulativeNew, _periodSize);
    (uint16 _indexUpdated, uint16 _cardinalityUpdated,) = _pool.observationBuffer();

    // it should not increase cardinality
    assertEq(_cardinalityUpdated, _currentCardinality);
    // it should wrap the write index to zero
    assertEq(_indexUpdated, 0);
    // it should overwrite the oldest observation
    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(0);
    assertEq(_ts, _blockTimestamp);
    assertEq(_r0c, _r0CumulativeNew);
    assertEq(_r1c, _r1CumulativeNew);
  }

  function test_WhenCardinalityNextIsGtCardinalityAndIndexEqTheLastAvailableSlot(
    uint16 _currentCardinality,
    uint16 _currentCardinalityNext,
    uint32 _timestamp,
    uint32 _elapsed,
    uint32 _periodSize,
    uint256 _r0CumulativeLast,
    uint256 _r1CumulativeLast,
    uint256 _r0CumulativeNew,
    uint256 _r1CumulativeNew
  ) external whenTimeElapsedSinceLastObservationIsGtPeriodSize {
    _currentCardinality = uint16(bound(_currentCardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _currentCardinalityNext =
      uint16(bound(_currentCardinalityNext, _currentCardinality + 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    uint16 _currentIndex = _currentCardinality - 1;
    _periodSize = uint32(bound(_periodSize, 0, type(uint32).max - 1));
    _elapsed = uint32(bound(_elapsed, uint256(_periodSize) + 1, type(uint32).max));

    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinalityNext
    });
    _writeObservation({_index: _currentIndex, _timestamp: _timestamp, _r0c: _r0CumulativeLast, _r1c: _r1CumulativeLast});

    uint32 _blockTimestamp;
    unchecked {
      _blockTimestamp = _timestamp + _elapsed;
    }

    vm.warp(_blockTimestamp);
    MockPool(address(_pool)).externalWrite(_r0CumulativeNew, _r1CumulativeNew, _periodSize);
    (uint16 _indexUpdated, uint16 _cardinalityUpdated,) = _pool.observationBuffer();

    // it should increase cardinality by one
    assertEq(_cardinalityUpdated, _currentCardinality + 1);
    // it should increase index by one modulo cardinality
    assertEq(_indexUpdated, (_currentIndex + 1) % (_currentCardinality + 1));
    // it should write the new observation at the newly grown slot
    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(_indexUpdated);
    assertEq(_ts, _blockTimestamp);
    assertEq(_r0c, _r0CumulativeNew);
    assertEq(_r1c, _r1CumulativeNew);
  }

  function test_WhenTheBlockTimestampHasWrappedPastTheNewestStoredObservationTimestamp(
    uint16 _currentCardinality,
    uint16 _currentIndex,
    uint32 _storedTimestamp,
    uint32 _elapsed,
    uint32 _periodSize,
    uint256 _r0CumulativeLast,
    uint256 _r1CumulativeLast,
    uint256 _r0CumulativeNew,
    uint256 _r1CumulativeNew
  ) external whenTimeElapsedSinceLastObservationIsGtPeriodSize {
    _currentCardinality = uint16(bound(_currentCardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _currentIndex = uint16(bound(_currentIndex, 0, _currentCardinality - 1));
    _periodSize = uint32(bound(_periodSize, 0, type(uint32).max - 1));
    _elapsed = uint32(bound(_elapsed, uint256(_periodSize) + 1, type(uint32).max));
    // Stored timestamp high enough that adding the elapsed seconds overflows uint32, so the new block
    // timestamp wraps to a value below the stored one.
    _storedTimestamp =
      uint32(bound(_storedTimestamp, uint256(type(uint32).max) - uint256(_elapsed) + 1, type(uint32).max));

    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinality
    });
    _writeObservation({
      _index: _currentIndex, _timestamp: _storedTimestamp, _r0c: _r0CumulativeLast, _r1c: _r1CumulativeLast
    });

    uint32 _blockTimestamp;
    unchecked {
      _blockTimestamp = _storedTimestamp + _elapsed;
    }
    assertTrue(_blockTimestamp < _storedTimestamp);

    vm.warp(_blockTimestamp);
    MockPool(address(_pool)).externalWrite(_r0CumulativeNew, _r1CumulativeNew, _periodSize);
    (uint16 _indexUpdated,,) = _pool.observationBuffer();

    // it should increase index by one modulo cardinality
    assertEq(_indexUpdated, (_currentIndex + 1) % _currentCardinality);
    // it should write the new observation at the wrapped block timestamp
    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(_indexUpdated);
    assertEq(_ts, _blockTimestamp);
    assertEq(_r0c, _r0CumulativeNew);
    assertEq(_r1c, _r1CumulativeNew);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
