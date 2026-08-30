// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract UnitPoolTapeGetSurroundingObservations is UnitPoolTapeBase {
  // Caps the buffer so the binary search runs at most ~10 iterations with an acceptable running time.
  uint16 internal constant _BINARY_SEARCH_MAX_CARDINALITY = 2 ** 10;

  function test_WhenTheTargetIsGteTheNewestCommittedObservation(
    IPoolTape.Observation memory _committed,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _target
  ) external {
    _committed.blockTimestamp = uint48(bound(_committed.blockTimestamp, 1, type(uint48).max));
    _setObservation(0, _committed);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_accumulator);

    _target = uint48(bound(_target, _committed.blockTimestamp, type(uint48).max));

    (IPoolTape.Observation memory _beforeOrAt, IPoolTape.Observation memory _atOrAfter) =
      MockPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the newest committed observation and the accumulator as an observation
    assertEq(_beforeOrAt.blockTimestamp, _committed.blockTimestamp);
    assertEq(_beforeOrAt.cumulativeVolume0, _committed.cumulativeVolume0);
    assertEq(_beforeOrAt.cumulativeVolume1, _committed.cumulativeVolume1);
    assertEq(_beforeOrAt.cumulativeMevVolume0, _committed.cumulativeMevVolume0);
    assertEq(_beforeOrAt.cumulativeMevVolume1, _committed.cumulativeMevVolume1);
    assertEq(_beforeOrAt.cumulativeMevFee0, _committed.cumulativeMevFee0);
    assertEq(_beforeOrAt.cumulativeMevFee1, _committed.cumulativeMevFee1);
    assertEq(_beforeOrAt.swapCount, _committed.swapCount);
    assertEq(_atOrAfter.blockTimestamp, _accumulator.lastSwapTimestamp);
    assertEq(_atOrAfter.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_atOrAfter.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_atOrAfter.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_atOrAfter.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_atOrAfter.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_atOrAfter.cumulativeMevFee1, _accumulator.cumulativeMevFee1);
    assertEq(_atOrAfter.swapCount, _accumulator.swapCount);
  }

  modifier whenTheTargetIsLtTheNewestCommittedObservation() {
    _;
  }

  function test_WhenTheTargetIsLteTheOldestObservation(
    IPoolTape.Observation memory _oldest,
    uint48 _target
  ) external whenTheTargetIsLtTheNewestCommittedObservation {
    _oldest.blockTimestamp = uint48(bound(_oldest.blockTimestamp, 1, type(uint48).max - 1));
    _setObservationTimestamp(1, _oldest.blockTimestamp + 1); // newest sits just after the oldest
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});

    _target = uint48(bound(_target, 1, _oldest.blockTimestamp)); // target at or before the oldest

    (IPoolTape.Observation memory _beforeOrAt, IPoolTape.Observation memory _atOrAfter) =
      MockPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the oldest observation as both bounds
    assertEq(_beforeOrAt.blockTimestamp, _oldest.blockTimestamp);
    assertEq(_beforeOrAt.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_beforeOrAt.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_beforeOrAt.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_beforeOrAt.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_beforeOrAt.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_beforeOrAt.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_beforeOrAt.swapCount, _oldest.swapCount);
    assertEq(_atOrAfter.blockTimestamp, _oldest.blockTimestamp);
    assertEq(_atOrAfter.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_atOrAfter.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_atOrAfter.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_atOrAfter.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_atOrAfter.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_atOrAfter.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_atOrAfter.swapCount, _oldest.swapCount);
  }

  modifier whenTheTargetIsWithinTheCommittedRange() {
    _;
  }

  function test_WhenTheTargetMatchesACommittedObservation(
    IPoolTape.Observation memory _match,
    uint16 _cardinality,
    uint48 _firstTimestamp,
    uint16 _targetIndex
  ) external whenTheTargetIsLtTheNewestCommittedObservation whenTheTargetIsWithinTheCommittedRange {
    // Fuzzes consecutive committed observations. The target matches an interior observation, which the binary
    // search may return as either bound depending on where it lands.
    _cardinality = uint16(bound(_cardinality, 3, _BINARY_SEARCH_MAX_CARDINALITY)); // at least one observation in the gap
    uint16 _newestIndex = _cardinality - 1;
    _firstTimestamp = uint48(bound(_firstTimestamp, 1, type(uint48).max - _BINARY_SEARCH_MAX_CARDINALITY));
    for (uint16 _i; _i < _cardinality; ++_i) {
      _setObservationTimestamp(_i, _firstTimestamp + _i);
    }
    _setObservationInformationSlot({_index: _newestIndex, _cardinality: _cardinality, _cardinalityNext: _cardinality});

    // excludes the oldest and newest slots
    _targetIndex = uint16(bound(_targetIndex, 1, _newestIndex - 1));
    uint48 _target = _firstTimestamp + _targetIndex;
    _match.blockTimestamp = _target;
    _setObservation(_targetIndex, _match);

    (IPoolTape.Observation memory _beforeOrAt, IPoolTape.Observation memory _atOrAfter) =
      MockPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the matching observation as one of the bounds
    bool _matchedBefore = _beforeOrAt.blockTimestamp == _target;
    assertTrue(_matchedBefore || _atOrAfter.blockTimestamp == _target);
    IPoolTape.Observation memory _matched = _matchedBefore ? _beforeOrAt : _atOrAfter;
    assertEq(_matched.cumulativeVolume0, _match.cumulativeVolume0);
    assertEq(_matched.cumulativeVolume1, _match.cumulativeVolume1);
    assertEq(_matched.cumulativeMevVolume0, _match.cumulativeMevVolume0);
    assertEq(_matched.cumulativeMevVolume1, _match.cumulativeMevVolume1);
    assertEq(_matched.cumulativeMevFee0, _match.cumulativeMevFee0);
    assertEq(_matched.cumulativeMevFee1, _match.cumulativeMevFee1);
    assertEq(_matched.swapCount, _match.swapCount);
    assertEq(_atOrAfter.blockTimestamp - _beforeOrAt.blockTimestamp, 1); // adjacent neighbors
  }

  function test_WhenTheTargetIsStrictlyBetweenTwoCommittedObservations(
    uint16 _cardinality,
    uint48 _firstTimestamp,
    uint16 _gapIndex
  ) external whenTheTargetIsLtTheNewestCommittedObservation whenTheTargetIsWithinTheCommittedRange {
    // Fuzzes consecutive committed observations. The target sits strictly between two observations, which the binary
    // search will return as the surrounding observations.
    _cardinality = uint16(bound(_cardinality, 2, _BINARY_SEARCH_MAX_CARDINALITY)); // at least one gap
    uint16 _newestIndex = _cardinality - 1;
    _firstTimestamp = uint48(bound(_firstTimestamp, 1, type(uint48).max - 2 * _BINARY_SEARCH_MAX_CARDINALITY));
    for (uint16 _i; _i < _cardinality; ++_i) {
      _setObservationTimestamp(_i, _firstTimestamp + 2 * _i);
    }
    _setObservationInformationSlot({_index: _newestIndex, _cardinality: _cardinality, _cardinalityNext: _cardinality});

    _gapIndex = uint16(bound(_gapIndex, 0, _newestIndex - 1));
    uint48 _expectedBefore = _firstTimestamp + 2 * _gapIndex;
    uint48 _target = _expectedBefore + 1; // strictly inside the gap

    (IPoolTape.Observation memory _beforeOrAt, IPoolTape.Observation memory _atOrAfter) =
      MockPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the two surrounding observations
    assertEq(_beforeOrAt.blockTimestamp, _expectedBefore);
    assertEq(_atOrAfter.blockTimestamp, _expectedBefore + 2);
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (PoolTape) {
    return new MockPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
