// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

contract UnitClPoolTapeGetSurroundingObservations is UnitClPoolTapeBase {
  // Caps the buffer so the binary search runs at most ~10 iterations with an acceptable running time.
  uint16 internal constant _BINARY_SEARCH_MAX_CARDINALITY = 2 ** 10;

  function test_WhenTheTargetIsGteTheNewestCommittedObservation(
    ICLPoolTape.Observation memory _committed,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _target,
    uint40 _now,
    uint48 _lastUpdated,
    uint160 _stakedCumulative,
    uint160 _activeCumulative
  ) external {
    _committed.blockTimestamp = uint40(bound(_committed.blockTimestamp, 1, type(uint40).max - 2));
    _setObservation(0, _committed);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _accumulator.lastSwapTimestamp =
      uint40(bound(_accumulator.lastSwapTimestamp, uint256(_committed.blockTimestamp) + 1, type(uint40).max - 1));
    _setAccumulator(_accumulator);

    _target = uint40(bound(_target, _committed.blockTimestamp, type(uint40).max));
    _now = uint40(bound(_now, uint256(_accumulator.lastSwapTimestamp) + 1, type(uint40).max));
    _lastUpdated = uint48(bound(_lastUpdated, 0, _accumulator.lastSwapTimestamp));
    vm.warp(_now);

    _mockPoolSettlement({_poolAddress: _pool, _lastUpdated: _lastUpdated, _stored: _stakedCumulative});
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _stakedCumulative});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool,
      _secondsPerLiquidityCumulativeX128: _activeCumulative,
      _secondsAgo: uint32(_now - _accumulator.lastSwapTimestamp)
    });

    (ICLPoolTape.Observation memory _beforeOrAt, ICLPoolTape.Observation memory _atOrAfter) =
      MockCLPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the newest committed observation and the accumulator as an observation
    assertEq(_beforeOrAt.blockTimestamp, _committed.blockTimestamp);
    assertEq(_beforeOrAt.cumulativeFee0, _committed.cumulativeFee0);
    assertEq(_beforeOrAt.cumulativeFee1, _committed.cumulativeFee1);
    assertEq(_beforeOrAt.cumulativeVolume0, _committed.cumulativeVolume0);
    assertEq(_beforeOrAt.cumulativeVolume1, _committed.cumulativeVolume1);
    assertEq(_beforeOrAt.cumulativeMevVolume0, _committed.cumulativeMevVolume0);
    assertEq(_beforeOrAt.cumulativeMevVolume1, _committed.cumulativeMevVolume1);
    assertEq(_beforeOrAt.cumulativeMevFee0, _committed.cumulativeMevFee0);
    assertEq(_beforeOrAt.cumulativeMevFee1, _committed.cumulativeMevFee1);
    assertEq(_beforeOrAt.secondsPerStakedLiquidityCumulativeX128, _committed.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_beforeOrAt.secondsPerLiquidityCumulativeX128, _committed.secondsPerLiquidityCumulativeX128);
    assertEq(_beforeOrAt.swapCount, _committed.swapCount);
    assertEq(_beforeOrAt.closeTick, _committed.closeTick);
    assertEq(_beforeOrAt.volatilityCorrob, _committed.volatilityCorrob);
    assertEq(_atOrAfter.blockTimestamp, _accumulator.lastSwapTimestamp);
    assertEq(_atOrAfter.cumulativeFee0, _accumulator.cumulativeFee0);
    assertEq(_atOrAfter.cumulativeFee1, _accumulator.cumulativeFee1);
    assertEq(_atOrAfter.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_atOrAfter.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_atOrAfter.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_atOrAfter.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_atOrAfter.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_atOrAfter.cumulativeMevFee1, _accumulator.cumulativeMevFee1);
    assertEq(_atOrAfter.secondsPerStakedLiquidityCumulativeX128, _stakedCumulative);
    assertEq(_atOrAfter.swapCount, _accumulator.swapCount);
    assertEq(_atOrAfter.secondsPerLiquidityCumulativeX128, _activeCumulative);
    // closeTick carries the accumulator's lastTick value
    assertEq(_atOrAfter.closeTick, _accumulator.lastTick);
    assertEq(_atOrAfter.volatilityCorrob, _accumulator.volatilityCorrob);
  }

  modifier whenTheTargetIsLtTheNewestCommittedObservation() {
    _;
  }

  function test_WhenTheTargetIsLteTheOldestObservation(
    ICLPoolTape.Observation memory _oldest,
    uint40 _target
  ) external whenTheTargetIsLtTheNewestCommittedObservation {
    _oldest.blockTimestamp = uint40(bound(_oldest.blockTimestamp, 1, type(uint40).max - 1));
    _setObservationTimestamp(1, _oldest.blockTimestamp + 1); // newest sits just after the oldest
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});

    _target = uint40(bound(_target, 1, _oldest.blockTimestamp)); // target at or before the oldest

    (ICLPoolTape.Observation memory _beforeOrAt, ICLPoolTape.Observation memory _atOrAfter) =
      MockCLPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the oldest observation as both bounds
    assertEq(_beforeOrAt.blockTimestamp, _oldest.blockTimestamp);
    assertEq(_beforeOrAt.cumulativeFee0, _oldest.cumulativeFee0);
    assertEq(_beforeOrAt.cumulativeFee1, _oldest.cumulativeFee1);
    assertEq(_beforeOrAt.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_beforeOrAt.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_beforeOrAt.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_beforeOrAt.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_beforeOrAt.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_beforeOrAt.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_beforeOrAt.secondsPerStakedLiquidityCumulativeX128, _oldest.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_beforeOrAt.secondsPerLiquidityCumulativeX128, _oldest.secondsPerLiquidityCumulativeX128);
    assertEq(_beforeOrAt.swapCount, _oldest.swapCount);
    assertEq(_beforeOrAt.closeTick, _oldest.closeTick);
    assertEq(_beforeOrAt.volatilityCorrob, _oldest.volatilityCorrob);
    assertEq(_atOrAfter.blockTimestamp, _oldest.blockTimestamp);
    assertEq(_atOrAfter.cumulativeFee0, _oldest.cumulativeFee0);
    assertEq(_atOrAfter.cumulativeFee1, _oldest.cumulativeFee1);
    assertEq(_atOrAfter.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_atOrAfter.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_atOrAfter.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_atOrAfter.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_atOrAfter.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_atOrAfter.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_atOrAfter.secondsPerStakedLiquidityCumulativeX128, _oldest.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_atOrAfter.secondsPerLiquidityCumulativeX128, _oldest.secondsPerLiquidityCumulativeX128);
    assertEq(_atOrAfter.swapCount, _oldest.swapCount);
    assertEq(_atOrAfter.closeTick, _oldest.closeTick);
    assertEq(_atOrAfter.volatilityCorrob, _oldest.volatilityCorrob);
  }

  modifier whenTheTargetIsWithinTheCommittedRange() {
    _;
  }

  function test_WhenTheTargetMatchesACommittedObservation(
    ICLPoolTape.Observation memory _match,
    uint16 _cardinality,
    uint40 _firstTimestamp,
    uint16 _targetIndex
  ) external whenTheTargetIsLtTheNewestCommittedObservation whenTheTargetIsWithinTheCommittedRange {
    // Fuzzes consecutive committed observations. The target matches an interior observation, which the binary
    // search may return as either bound depending on where it lands.
    _cardinality = uint16(bound(_cardinality, 3, _BINARY_SEARCH_MAX_CARDINALITY)); // at least one observation in the gap
    uint16 _newestIndex = _cardinality - 1;
    _firstTimestamp = uint40(bound(_firstTimestamp, 1, type(uint40).max - _BINARY_SEARCH_MAX_CARDINALITY));
    for (uint16 _i; _i < _cardinality; ++_i) {
      _setObservationTimestamp(_i, _firstTimestamp + _i);
    }
    _setObservationInformationSlot({_index: _newestIndex, _cardinality: _cardinality, _cardinalityNext: _cardinality});

    // excludes the oldest and newest slots
    _targetIndex = uint16(bound(_targetIndex, 1, _newestIndex - 1));
    uint40 _target = _firstTimestamp + _targetIndex;
    _match.blockTimestamp = _target;
    _setObservation(_targetIndex, _match);

    (ICLPoolTape.Observation memory _beforeOrAt, ICLPoolTape.Observation memory _atOrAfter) =
      MockCLPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the matching observation as one of the bounds
    bool _matchedBefore = _beforeOrAt.blockTimestamp == _target;
    assertTrue(_matchedBefore || _atOrAfter.blockTimestamp == _target);
    ICLPoolTape.Observation memory _matched = _matchedBefore ? _beforeOrAt : _atOrAfter;
    assertEq(_matched.cumulativeFee0, _match.cumulativeFee0);
    assertEq(_matched.cumulativeFee1, _match.cumulativeFee1);
    assertEq(_matched.cumulativeVolume0, _match.cumulativeVolume0);
    assertEq(_matched.cumulativeVolume1, _match.cumulativeVolume1);
    assertEq(_matched.cumulativeMevVolume0, _match.cumulativeMevVolume0);
    assertEq(_matched.cumulativeMevVolume1, _match.cumulativeMevVolume1);
    assertEq(_matched.cumulativeMevFee0, _match.cumulativeMevFee0);
    assertEq(_matched.cumulativeMevFee1, _match.cumulativeMevFee1);
    assertEq(_matched.secondsPerStakedLiquidityCumulativeX128, _match.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_matched.secondsPerLiquidityCumulativeX128, _match.secondsPerLiquidityCumulativeX128);
    assertEq(_matched.swapCount, _match.swapCount);
    assertEq(_matched.closeTick, _match.closeTick);
    assertEq(_matched.volatilityCorrob, _match.volatilityCorrob);
    assertEq(_atOrAfter.blockTimestamp - _beforeOrAt.blockTimestamp, 1); // adjacent neighbors
  }

  function test_WhenTheTargetIsStrictlyBetweenTwoCommittedObservations(
    uint16 _cardinality,
    uint40 _firstTimestamp,
    uint16 _gapIndex
  ) external whenTheTargetIsLtTheNewestCommittedObservation whenTheTargetIsWithinTheCommittedRange {
    // Fuzzes consecutive committed observations. The target sits strictly between two observations, which the binary
    // search will return as the surrounding observations.
    _cardinality = uint16(bound(_cardinality, 2, _BINARY_SEARCH_MAX_CARDINALITY)); // at least one gap
    uint16 _newestIndex = _cardinality - 1;
    _firstTimestamp = uint40(bound(_firstTimestamp, 1, type(uint40).max - 2 * _BINARY_SEARCH_MAX_CARDINALITY));
    for (uint16 _i; _i < _cardinality; ++_i) {
      _setObservationTimestamp(_i, _firstTimestamp + 2 * _i);
    }
    _setObservationInformationSlot({_index: _newestIndex, _cardinality: _cardinality, _cardinalityNext: _cardinality});

    _gapIndex = uint16(bound(_gapIndex, 0, _newestIndex - 1));
    uint40 _expectedBefore = _firstTimestamp + 2 * _gapIndex;
    uint40 _target = _expectedBefore + 1; // strictly inside the gap

    (ICLPoolTape.Observation memory _beforeOrAt, ICLPoolTape.Observation memory _atOrAfter) =
      MockCLPoolTape(address(_tape)).externalGetSurroundingObservations(_pool, _target);

    // it returns the two surrounding observations
    assertEq(_beforeOrAt.blockTimestamp, _expectedBefore);
    assertEq(_atOrAfter.blockTimestamp, _expectedBefore + 2);
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
