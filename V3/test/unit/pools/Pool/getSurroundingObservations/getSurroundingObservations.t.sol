// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {PoolOracle} from 'V3/libraries/PoolOracle.sol';

contract UnitPoolOracleGetSurroundingObservations is UnitPool {
  // Value to test binary search with a maximum for 10 iterations and an acceptable running time.
  uint16 internal constant _BINARY_SEARCH_MAX_CARDINALITY = 2 ** 10;

  modifier whenTheTargetIsGtOrEqToTheNewestStoredObservationTimestamp() {
    _;
  }

  function test_WhenTheTargetEqTheNewestStoredTimestamp(
    uint32 _time,
    uint32 _secondsAgoNewest,
    uint256 _newestStoredR0Cumulative,
    uint256 _newestStoredR1Cumulative,
    uint16 _observationCardinality,
    uint16 _observationIndex
  ) external whenTheTargetIsGtOrEqToTheNewestStoredObservationTimestamp {
    _secondsAgoNewest = uint32(bound(_secondsAgoNewest, 1, type(uint32).max));
    _observationCardinality = uint16(bound(_observationCardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _observationIndex = uint16(bound(_observationIndex, 0, _observationCardinality - 1));

    uint32 _newestStoredTimestamp = _seedNewest(
      _time,
      _secondsAgoNewest,
      _newestStoredR0Cumulative,
      _newestStoredR1Cumulative,
      _observationCardinality,
      _observationIndex
    );

    /// @dev target lands exactly on the newest stored observation, so no interpolation runs.
    (PoolOracle.Observation memory _beforeOrAt, PoolOracle.Observation memory _atOrAfter) =
      MockPool(address(_pool)).externalGetSurroundingObservations(_time, _newestStoredTimestamp);

    // it should set _beforeOrAt to the newest stored observation
    assertEq(_beforeOrAt.timestamp, _newestStoredTimestamp);
    assertEq(_beforeOrAt.reserve0Cumulative, _newestStoredR0Cumulative);
    assertEq(_beforeOrAt.reserve1Cumulative, _newestStoredR1Cumulative);

    // it should set _atOrAfter to the newest stored observation
    assertEq(_atOrAfter.timestamp, _newestStoredTimestamp);
    assertEq(_atOrAfter.reserve0Cumulative, _newestStoredR0Cumulative);
    assertEq(_atOrAfter.reserve1Cumulative, _newestStoredR1Cumulative);
  }

  function test_WhenTheTargetIsGtTheNewestStoredObservationTimestamp(
    uint32 _time,
    uint32 _secondsAgoNewest,
    uint32 _secondsAgoTarget,
    uint256 _newestStoredR0Cumulative,
    uint256 _newestStoredR1Cumulative,
    uint256 _lastR0Cumulative,
    uint256 _lastR1Cumulative,
    uint16 _observationCardinality,
    uint16 _observationIndex
  ) external whenTheTargetIsGtOrEqToTheNewestStoredObservationTimestamp {
    _secondsAgoNewest = uint32(bound(_secondsAgoNewest, 1, type(uint32).max));
    /// @dev strictly less than `_secondsAgoNewest` so the target is after the newest observation and interpolation runs.
    _secondsAgoTarget = uint32(bound(_secondsAgoTarget, 0, _secondsAgoNewest - 1));
    _observationCardinality = uint16(bound(_observationCardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _observationIndex = uint16(bound(_observationIndex, 0, _observationCardinality - 1));
    _lastR0Cumulative = bound(_lastR0Cumulative, _newestStoredR0Cumulative, type(uint256).max);
    _lastR1Cumulative = bound(_lastR1Cumulative, _newestStoredR1Cumulative, type(uint256).max);

    _set(address(_pool), _lastR0Cumulative, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _lastR1Cumulative, _pool.reserve1CumulativeLast.selector);

    uint32 _target;
    unchecked {
      _target = _time - _secondsAgoTarget;
    }

    PoolOracle.Observation memory _atOrAfter;
    uint32 _newestStoredTimestamp;
    {
      _newestStoredTimestamp = _seedNewest(
        _time,
        _secondsAgoNewest,
        _newestStoredR0Cumulative,
        _newestStoredR1Cumulative,
        _observationCardinality,
        _observationIndex
      );
      PoolOracle.Observation memory _beforeOrAt;
      (_beforeOrAt, _atOrAfter) = MockPool(address(_pool)).externalGetSurroundingObservations(_time, _target);

      // it should set _beforeOrAt to the newest stored observation
      assertEq(_beforeOrAt.timestamp, _newestStoredTimestamp);
      assertEq(_beforeOrAt.reserve0Cumulative, _newestStoredR0Cumulative);
      assertEq(_beforeOrAt.reserve1Cumulative, _newestStoredR1Cumulative);
    }

    // it should set _atOrAfter timestamp to the target
    assertEq(_atOrAfter.timestamp, _target);

    // it should set _atOrAfter cumulatives to the interpolation between the newest stored cumulatives and the live
    // cumulatives prorated to the target
    (uint256 _expectedReserve0Cumulative, uint256 _expectedReserve1Cumulative) = _expectedInterpolatedCumulatives(
      _time,
      _newestStoredTimestamp,
      _target,
      _newestStoredR0Cumulative,
      _newestStoredR1Cumulative,
      _lastR0Cumulative,
      _lastR1Cumulative
    );
    assertEq(uint256(_atOrAfter.reserve0Cumulative), _expectedReserve0Cumulative);
    assertEq(uint256(_atOrAfter.reserve1Cumulative), _expectedReserve1Cumulative);
  }

  modifier whenTheTargetIsLtTheNewestStoredObservationTimestamp() {
    _;
  }

  function test_WhenTheTargetIsLtTheOldestReachableObservationTimestamp(
    uint32 _time,
    uint32 _secondsAgoNewest,
    uint32 _secondsAgoOldest,
    uint32 _secondsAgoTarget,
    uint16 _observationCardinality,
    uint16 _observationIndex
  ) external whenTheTargetIsLtTheNewestStoredObservationTimestamp {
    // Chronological distances. Oldest at least as far back as newest; target strictly older than oldest
    // so the contract reverts with ObservationOld.
    _secondsAgoNewest = uint32(bound(_secondsAgoNewest, 0, type(uint32).max - 2));
    _secondsAgoOldest = uint32(bound(_secondsAgoOldest, _secondsAgoNewest, type(uint32).max - 1));
    _secondsAgoTarget = uint32(bound(_secondsAgoTarget, _secondsAgoOldest + 1, type(uint32).max));

    uint32 _newestStoredTimestamp;
    uint32 _oldestTimestamp;
    uint32 _target;
    unchecked {
      _newestStoredTimestamp = _time - _secondsAgoNewest;
      _oldestTimestamp = _time - _secondsAgoOldest;
      _target = _time - _secondsAgoTarget;
    }

    _observationCardinality = uint16(bound(_observationCardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _observationIndex = uint16(bound(_observationIndex, 0, _observationCardinality - 1));
    uint16 _oldestIndex = uint16((uint256(_observationIndex) + 1) % uint256(_observationCardinality));

    _setObservationInformationSlot({
      _index: _observationIndex, _cardinality: _observationCardinality, _cardinalityNext: _observationCardinality
    });
    _writeObservation({_index: _observationIndex, _timestamp: _newestStoredTimestamp, _r0c: 0, _r1c: 0});
    _writeObservation({_index: _oldestIndex, _timestamp: _oldestTimestamp, _r0c: 0, _r1c: 0});

    // it should revert with ObservationOld
    vm.expectRevert(PoolOracle.ObservationOld.selector);
    MockPool(address(_pool)).externalGetSurroundingObservations(_time, _target);
  }

  modifier whenTheTargetIsWithinThePopulatedRange() {
    _;
  }

  function test_WhenTheTargetEqAStoredObservationTimestamp(
    uint32 _time,
    uint16 _observationCardinality,
    uint32 _secondsAgoNewest,
    uint32 _observationSpacing,
    uint16 _targetIndex,
    uint256 _matchR0c,
    uint256 _matchR1c
  ) external whenTheTargetIsLtTheNewestStoredObservationTimestamp whenTheTargetIsWithinThePopulatedRange {
    // Populates `_observationCardinality` observations spaced by `_observationSpacing` chronologically.
    _observationCardinality = uint16(bound(_observationCardinality, 2, _BINARY_SEARCH_MAX_CARDINALITY));
    uint16 _newestIndex = _observationCardinality - 1;
    _observationSpacing = uint32(bound(_observationSpacing, 1, type(uint32).max / _newestIndex));
    _secondsAgoNewest = uint32(bound(_secondsAgoNewest, 0, type(uint32).max - _newestIndex * _observationSpacing));

    uint32 _firstTimestamp;
    unchecked {
      _firstTimestamp = _time - _secondsAgoNewest - _newestIndex * _observationSpacing;
    }

    for (uint16 _i = 0; _i < _observationCardinality; _i++) {
      uint32 _timestamp;
      unchecked {
        _timestamp = _firstTimestamp + uint32(_i) * _observationSpacing;
      }
      _writeObservation({_index: _i, _timestamp: _timestamp, _r0c: 0, _r1c: 0});
    }

    _setObservationInformationSlot({
      _index: _newestIndex, _cardinality: _observationCardinality, _cardinalityNext: _observationCardinality
    });

    // Excludes the newest observation to make sure target is not the newest observation.
    _targetIndex = uint16(bound(_targetIndex, 0, _newestIndex - 1));
    uint32 _target;
    unchecked {
      _target = _firstTimestamp + uint32(_targetIndex) * _observationSpacing;
    }
    _writeObservation({_index: _targetIndex, _timestamp: _target, _r0c: _matchR0c, _r1c: _matchR1c});

    (PoolOracle.Observation memory _beforeOrAt, PoolOracle.Observation memory _atOrAfter) =
      MockPool(address(_pool)).externalGetSurroundingObservations(_time, _target);

    // Binary search may land on either the observation on the left or the right.
    bool _matchesBeforeOrAt = _beforeOrAt.timestamp == _target;
    bool _matchesAtOrAfter = _atOrAfter.timestamp == _target;

    // it should return the matching observation as either _beforeOrAt or _atOrAfter
    assertTrue(_matchesBeforeOrAt || _matchesAtOrAfter);
    uint256 _matchedR0c = _matchesBeforeOrAt ? _beforeOrAt.reserve0Cumulative : _atOrAfter.reserve0Cumulative;
    uint256 _matchedR1c = _matchesBeforeOrAt ? _beforeOrAt.reserve1Cumulative : _atOrAfter.reserve1Cumulative;
    assertEq(_matchedR0c, _matchR0c);
    assertEq(_matchedR1c, _matchR1c);

    // it should pair the matching observation with its adjacent stored neighbor
    uint32 _gap;
    unchecked {
      _gap = _atOrAfter.timestamp - _beforeOrAt.timestamp;
    }
    assertEq(uint256(_gap), uint256(_observationSpacing));
  }

  function test_WhenTheTargetIsStrictlyBetweenTwoStoredObservations(
    uint32 _time,
    uint16 _observationCardinality,
    uint32 _secondsAgoNewest,
    uint32 _observationSpacing,
    uint16 _gapOffset,
    uint32 _offsetInGap
  ) external whenTheTargetIsLtTheNewestStoredObservationTimestamp whenTheTargetIsWithinThePopulatedRange {
    _observationCardinality = uint16(bound(_observationCardinality, 2, _BINARY_SEARCH_MAX_CARDINALITY));
    uint16 _newestIndex = _observationCardinality - 1;
    // _observationSpacing >= 2 so at least one value lies strictly between consecutive timestamps.
    _observationSpacing = uint32(bound(_observationSpacing, 2, type(uint32).max / _newestIndex));
    _secondsAgoNewest = uint32(bound(_secondsAgoNewest, 0, type(uint32).max - _newestIndex * _observationSpacing));

    uint32 _firstTimestamp;
    unchecked {
      _firstTimestamp = _time - _secondsAgoNewest - _newestIndex * _observationSpacing;
    }

    _setObservationInformationSlot({
      _index: _newestIndex, _cardinality: _observationCardinality, _cardinalityNext: _observationCardinality
    });
    for (uint16 _i = 0; _i < _observationCardinality; _i++) {
      uint32 _timestamp;
      unchecked {
        _timestamp = _firstTimestamp + uint32(_i) * _observationSpacing;
      }
      _writeObservation({_index: _i, _timestamp: _timestamp, _r0c: 0, _r1c: 0});
    }
    uint16 _gapIndex = uint16(bound(_gapOffset, 0, _newestIndex - 1));
    _offsetInGap = uint32(bound(_offsetInGap, 1, _observationSpacing - 1)); // timestamp strictly between two observations
    uint32 _target;
    uint32 _expectedBeforeOrAtTimestamp;
    uint32 _expectedAtOrAfterTimestamp;
    unchecked {
      _expectedBeforeOrAtTimestamp = _firstTimestamp + uint32(_gapIndex) * _observationSpacing;
      _target = _expectedBeforeOrAtTimestamp + _offsetInGap;
      _expectedAtOrAfterTimestamp = _firstTimestamp + uint32(_gapIndex + 1) * _observationSpacing;
    }

    (PoolOracle.Observation memory _beforeOrAt, PoolOracle.Observation memory _atOrAfter) =
      MockPool(address(_pool)).externalGetSurroundingObservations(_time, _target);

    // it should set _beforeOrAt to the previous observation
    assertEq(_beforeOrAt.timestamp, _expectedBeforeOrAtTimestamp);

    // it should set _atOrAfter to the next observation
    assertEq(_atOrAfter.timestamp, _expectedAtOrAfterTimestamp);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }

  function _seedNewest(
    uint32 _time,
    uint32 _secondsAgoNewest,
    uint256 _newestStoredR0Cumulative,
    uint256 _newestStoredR1Cumulative,
    uint16 _observationCardinality,
    uint16 _observationIndex
  ) internal returns (uint32 _newestStoredTimestamp) {
    unchecked {
      _newestStoredTimestamp = _time - _secondsAgoNewest;
    }
    _setObservationInformationSlot({
      _index: _observationIndex, _cardinality: _observationCardinality, _cardinalityNext: _observationCardinality
    });
    _writeObservation({
      _index: _observationIndex,
      _timestamp: _newestStoredTimestamp,
      _r0c: _newestStoredR0Cumulative,
      _r1c: _newestStoredR1Cumulative
    });
  }

  function _expectedInterpolatedCumulatives(
    uint32 _time,
    uint32 _newestStoredTimestamp,
    uint32 _target,
    uint256 _newestStoredR0Cumulative,
    uint256 _newestStoredR1Cumulative,
    uint256 _lastR0Cumulative,
    uint256 _lastR1Cumulative
  ) internal view returns (uint256, uint256) {
    PoolOracle.Observation memory _newestObservation = PoolOracle.Observation({
      timestamp: _newestStoredTimestamp,
      reserve0Cumulative: _newestStoredR0Cumulative,
      reserve1Cumulative: _newestStoredR1Cumulative
    });
    return MockPool(address(_pool))
      .externalInterpolate(_newestObservation, _time, _lastR0Cumulative, _lastR1Cumulative, _target);
  }
}
