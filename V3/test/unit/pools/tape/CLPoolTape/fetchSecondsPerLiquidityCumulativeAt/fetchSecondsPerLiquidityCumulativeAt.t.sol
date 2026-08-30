// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeFetchSecondsPerLiquidityCumulativeAt is UnitClPoolTapeBase {
  bytes internal constant _OLD_REVERT = abi.encodeWithSignature('Error(string)', 'OLD');
  bytes internal constant _PANIC_REVERT = abi.encodeWithSignature('Panic(uint256)', 0x11);

  function test_WhenTheTargetTimestampIsGteTheCurrentBlockTimestamp(
    uint40 _now,
    uint40 _timestamp,
    uint160 _cumulative
  ) external {
    _now = uint40(bound(_now, 1, type(uint40).max));
    vm.warp(_now);
    _timestamp = uint40(bound(_timestamp, _now, type(uint40).max));

    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _cumulative, _secondsAgo: 0
    });

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);

    // it returns the live secondsPerLiquidityCumulativeX128 from the pool
    assertEq(_result, _cumulative);
  }

  modifier whenTheTargetTimestampIsLtTheCurrentBlockTimestamp() {
    _;
  }

  function test_WhenThePoolOracleStillHasTheTargetTimestamp(
    uint40 _now,
    uint32 _secondsAgo,
    uint160 _cumulative
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp {
    _secondsAgo = uint32(bound(_secondsAgo, 1, type(uint32).max));
    _now = uint40(bound(_now, uint256(_secondsAgo) + 1, type(uint40).max));
    vm.warp(_now);
    uint40 _timestamp = uint40(_now - _secondsAgo);

    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _cumulative, _secondsAgo: _secondsAgo
    });

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);

    // it returns the pool oracle value at the target
    assertEq(_result, _cumulative);
  }

  modifier whenThePoolOracleRevertsWithAString() {
    _;
  }

  modifier whenTheErrorIsOLD() {
    _;
  }

  function test_WhenTheErrorIsOLD(
    uint16 _index,
    uint40 _now,
    uint40 _anchorTimestamp,
    uint32 _secondsAgo,
    uint160 _anchorCumulative,
    uint160 _live
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp whenThePoolOracleRevertsWithAString whenTheErrorIsOLD {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _secondsAgo = uint32(bound(_secondsAgo, 1, type(uint32).max));
    _now = uint40(bound(_now, uint256(_secondsAgo) + 1, type(uint40).max));
    vm.warp(_now);
    uint40 _timestamp = uint40(_now - _secondsAgo);
    _anchorTimestamp = uint40(bound(_anchorTimestamp, 0, _timestamp - 1));

    _commitObservation({_index: _index, _blockTimestamp: _anchorTimestamp, _cumulative: _anchorCumulative});

    _mockPoolObserveRevert({_poolAddress: _pool, _secondsAgo: _secondsAgo, _revertData: _OLD_REVERT});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _live, _secondsAgo: 0
    });

    uint256 _expected;
    unchecked {
      uint160 _delta = _live - _anchorCumulative;
      _expected =
        uint256(_anchorCumulative) + (uint256(_delta) * (_timestamp - _anchorTimestamp)) / (_now - _anchorTimestamp);
    }

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);

    // it interpolates between the newest committed observation and the live value
    assertEq(_result, uint160(_expected));
  }

  function test_WhenTheCumulativeWrappedBetweenTheCommitAndTheLiveValue()
    external
    whenTheTargetTimestampIsLtTheCurrentBlockTimestamp
    whenThePoolOracleRevertsWithAString
    whenTheErrorIsOLD
  {
    uint160 _anchorCumulative = type(uint160).max - 4;
    uint160 _live = 10;

    _commitObservation({_index: 0, _blockTimestamp: 1000, _cumulative: _anchorCumulative});

    vm.warp(1200);
    _mockPoolObserveRevert({_poolAddress: _pool, _secondsAgo: 100, _revertData: _OLD_REVERT});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: _live, _secondsAgo: 0
    });

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, 1100);

    // it interpolates across the wrap
    assertEq(_result, 2);
  }

  function test_WhenTheTargetTimestampIsLteTheNewestCommittedObservation(
    uint16 _index,
    uint40 _now,
    uint40 _anchorTimestamp,
    uint32 _secondsAgo,
    uint160 _anchorCumulative
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp whenThePoolOracleRevertsWithAString whenTheErrorIsOLD {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _secondsAgo = uint32(bound(_secondsAgo, 1, type(uint32).max));
    _now = uint40(bound(_now, uint256(_secondsAgo) + 1, type(uint40).max));
    vm.warp(_now);
    uint40 _timestamp = uint40(_now - _secondsAgo);
    _anchorTimestamp = uint40(bound(_anchorTimestamp, _timestamp, _now - 1));

    _commitObservation({_index: _index, _blockTimestamp: _anchorTimestamp, _cumulative: _anchorCumulative});

    _mockPoolObserveRevert({_poolAddress: _pool, _secondsAgo: _secondsAgo, _revertData: _OLD_REVERT});

    uint160 _result = MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);

    // it returns the observation secondsPerLiquidityCumulativeX128 value
    assertEq(_result, _anchorCumulative);
  }

  function test_WhenTheErrorIsNotOLD(
    uint40 _now,
    uint32 _secondsAgo,
    string memory _reason
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp whenThePoolOracleRevertsWithAString {
    vm.assume(keccak256(bytes(_reason)) != keccak256('OLD'));
    _secondsAgo = uint32(bound(_secondsAgo, 1, type(uint32).max));
    _now = uint40(bound(_now, uint256(_secondsAgo) + 1, type(uint40).max));
    vm.warp(_now);
    uint40 _timestamp = uint40(_now - _secondsAgo);

    bytes memory _revertData = abi.encodeWithSignature('Error(string)', _reason);
    _mockPoolObserveRevert({_poolAddress: _pool, _secondsAgo: _secondsAgo, _revertData: _revertData});

    // it reverts
    vm.expectRevert(_revertData);
    MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);
  }

  function test_WhenThePoolOracleRevertsWithSomethingElse(
    uint40 _now,
    uint32 _secondsAgo
  ) external whenTheTargetTimestampIsLtTheCurrentBlockTimestamp {
    _secondsAgo = uint32(bound(_secondsAgo, 1, type(uint32).max));
    _now = uint40(bound(_now, uint256(_secondsAgo) + 1, type(uint40).max));
    vm.warp(_now);
    uint40 _timestamp = uint40(_now - _secondsAgo);

    _mockPoolObserveRevert({_poolAddress: _pool, _secondsAgo: _secondsAgo, _revertData: _PANIC_REVERT});

    // it reverts
    vm.expectRevert(_PANIC_REVERT);
    MockCLPoolTape(address(_tape)).externalFetchSecondsPerLiquidityCumulativeAt(_pool, _timestamp);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _commitObservation(uint16 _index, uint40 _blockTimestamp, uint160 _cumulative) internal {
    ICLPoolTape.Observation memory _observation;
    _observation.blockTimestamp = _blockTimestamp;
    _observation.secondsPerLiquidityCumulativeX128 = _cumulative;
    _setObservation(_index, _observation);
    _setObservationInformationSlot({_index: _index, _cardinality: 1, _cardinalityNext: 1});
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
