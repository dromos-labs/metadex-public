// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeFetchStakedCumulativeAt is UnitClPoolTapeBase {
  function test_WhenTheTargetTimestampIsGteTheCurrentBlockTimestamp(
    uint40 _now,
    uint40 _timestamp,
    uint160 _cumulative
  ) external {
    _now = uint40(bound(_now, 1, type(uint40).max));
    vm.warp(_now);
    _timestamp = uint40(bound(_timestamp, _now, type(uint40).max));

    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _cumulative});

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, _timestamp);

    // it returns the live secondsPerStakedLiquidityCumulativeX128 from the pool
    assertEq(_result, _cumulative);
  }

  modifier whenTheTargetTimestampIsLtTheCurrentBlockTimestamp() {
    _;
  }

  function test_WhenTheTargetTimestampIsLteTheNewestCommittedObservation(
    uint16 _index,
    uint40 _now,
    uint40 _anchorTimestamp,
    uint40 _timestamp,
    uint160 _anchorCumulative
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _now = uint40(bound(_now, 2, type(uint40).max));
    vm.warp(_now);
    _anchorTimestamp = uint40(bound(_anchorTimestamp, 1, _now - 1));
    _timestamp = uint40(bound(_timestamp, 0, _anchorTimestamp));

    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = _anchorTimestamp;
    _observation.secondsPerStakedLiquidityCumulativeX128 = _anchorCumulative;
    _setObservation(_index, _observation);
    _setObservationInformationSlot({_index: _index, _cardinality: 1, _cardinalityNext: 1});

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, _timestamp);

    // it returns the observation secondsPerStakedLiquidityCumulativeX128 value
    assertEq(_result, _anchorCumulative);
  }

  modifier whenTheTargetTimestampIsLtThePoolLastUpdatedValue() {
    _;
  }

  function test_WhenTheTargetTimestampIsLtThePoolLastUpdatedValue(
    uint16 _index,
    uint40 _now,
    uint40 _anchorTimestamp,
    uint40 _timestamp,
    uint48 _lastUpdated,
    uint160 _anchorCumulative,
    uint160 _stored
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp whenTheTargetTimestampIsLtThePoolLastUpdatedValue {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _now = uint40(bound(_now, 2, type(uint40).max));
    vm.warp(_now);
    _anchorTimestamp = uint40(bound(_anchorTimestamp, 0, _now - 2));
    _timestamp = uint40(bound(_timestamp, uint256(_anchorTimestamp) + 1, _now - 1));
    _lastUpdated = uint48(bound(_lastUpdated, uint256(_timestamp) + 1, _now));

    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = _anchorTimestamp;
    _observation.secondsPerStakedLiquidityCumulativeX128 = _anchorCumulative;
    _setObservation(_index, _observation);
    _setObservationInformationSlot({_index: _index, _cardinality: 1, _cardinalityNext: 1});

    _mockPoolSettlement({_poolAddress: _pool, _lastUpdated: _lastUpdated, _stored: _stored});

    uint256 _expected;
    unchecked {
      uint160 _delta = _stored - _anchorCumulative;
      _expected = uint256(_anchorCumulative) + (uint256(_delta) * (_timestamp - _anchorTimestamp))
        / (_lastUpdated - _anchorTimestamp);
    }

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, _timestamp);

    // it interpolates between the observation value the settled value in the pool
    assertEq(_result, uint160(_expected));
  }

  function test_WhenTheCumulativeWrappedBetweenTheSnapshotAndTheSettlement()
    external
    whenTheTargetTimestampIsLtTheCurrentBlockTimestamp
    whenTheTargetTimestampIsLtThePoolLastUpdatedValue
  {
    uint160 _anchorCumulative = type(uint160).max - 4;
    uint160 _stored = 10;

    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = 1000;
    _observation.secondsPerStakedLiquidityCumulativeX128 = _anchorCumulative;
    _setObservation(0, _observation);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});

    vm.warp(1200);
    _mockPoolSettlement({_poolAddress: _pool, _lastUpdated: 1100, _stored: _stored});

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, 1050);

    // it interpolates across the wrap
    assertEq(_result, 2);
  }

  modifier whenTheTargetTimestampIsGteThePoolLastUpdatedValue() {
    _;
  }

  function test_WhenTheTargetTimestampIsGteThePoolLastUpdatedValue(
    uint16 _index,
    uint40 _now,
    uint40 _anchorTimestamp,
    uint40 _timestamp,
    uint48 _lastUpdated,
    uint160 _stored,
    uint160 _live
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp whenTheTargetTimestampIsGteThePoolLastUpdatedValue {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _now = uint40(bound(_now, 2, type(uint40).max));
    vm.warp(_now);
    _lastUpdated = uint48(bound(_lastUpdated, 1, _now - 1));
    _timestamp = uint40(bound(_timestamp, _lastUpdated, _now - 1));
    _anchorTimestamp = uint40(bound(_anchorTimestamp, 0, _timestamp - 1));

    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = _anchorTimestamp;
    _setObservation(_index, _observation);
    _setObservationInformationSlot({_index: _index, _cardinality: 1, _cardinalityNext: 1});

    _mockPoolSettlement({_poolAddress: _pool, _lastUpdated: _lastUpdated, _stored: _stored});
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _live});

    uint256 _expected;
    unchecked {
      uint160 _delta = _live - _stored;
      _expected = uint256(_stored) + (uint256(_delta) * (_timestamp - _lastUpdated)) / (_now - _lastUpdated);
    }

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, _timestamp);

    // it interpolates between the settled value and the live secondsPerStakedLiquidityCumulativeX128 value
    assertEq(_result, uint160(_expected));
  }

  function test_WhenTheStakedLiquidityNeverChanged()
    external
    whenTheTargetTimestampIsLtTheCurrentBlockTimestamp
    whenTheTargetTimestampIsGteThePoolLastUpdatedValue
  {
    uint256 _stakedLiquidity = 1e18;
    uint160 _stored = 1_000_000;
    uint160 _live = uint160(_stored + ((2500 - 900) << 128) / _stakedLiquidity);
    uint160 _projected = uint160(_stored + ((2200 - 900) << 128) / _stakedLiquidity);

    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = 2000;
    _setObservation(0, _observation);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});

    vm.warp(2500);
    _mockPoolSettlement({_poolAddress: _pool, _lastUpdated: 900, _stored: _stored});
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: _live});

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchStakedCumulativeAt(_pool, 2200);

    // it lands on the projected value
    assertEq(_result, _projected);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
