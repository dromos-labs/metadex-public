// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeRecord is UnitClPoolTapeBase {
  function test_WhenCallerIsNotInAllowedCallerMap(address _invalidCaller) external {
    vm.assume(_invalidCaller != _caller);
    // it reverts with Unauthorized
    vm.expectRevert(IBasePoolTape.Unauthorized.selector);
    vm.prank(_invalidCaller);
    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: 0}));
  }

  modifier whenCallerIsInAllowedCallerMap() {
    vm.startPrank(_caller);
    _;
    vm.stopPrank();
  }

  function test_WhenCallerIsInAllowedCallerMap(
    int24 _tick,
    uint40 _existingLastSwapTimestamp
  ) external whenCallerIsInAllowedCallerMap {
    _existingLastSwapTimestamp = uint40(bound(_existingLastSwapTimestamp, 1, type(uint40).max));

    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: _existingLastSwapTimestamp,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: 0,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: 0,
        _cumulative: 0
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: _tick}));

    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    // it sets lastTick to the swap tick
    assertEq(_accumulator.lastTick, _tick);
    // it sets lastSwapTimestamp to the current timestamp
    assertEq(_accumulator.lastSwapTimestamp, block.timestamp);
  }

  function test_WhenRecordingTheFirstSwap(uint128 _value, int24 _tick) external whenCallerIsInAllowedCallerMap {
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: 0});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: 0, _secondsAgo: 0
    });

    bool _committed = _tape.record(_pool, _clPoolTapeData({_value: _value, _tick: _tick}));

    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    uint256 _expected = _value % (uint256(1) << 120);
    // it assigns every cumulative discarding the pre populated values
    assertEq(_accumulator.cumulativeFee0, _expected);
    assertEq(_accumulator.cumulativeFee1, _expected);
    assertEq(_accumulator.cumulativeVolume0, _expected);
    assertEq(_accumulator.cumulativeVolume1, _expected);
    assertEq(_accumulator.cumulativeMevVolume0, _expected);
    assertEq(_accumulator.cumulativeMevVolume1, _expected);
    assertEq(_accumulator.cumulativeMevFee0, _expected);
    assertEq(_accumulator.cumulativeMevFee1, _expected);
    // it sets swapCount to one
    assertEq(_accumulator.swapCount, 1);
    // it sets intervalSwapCount to one
    assertEq(_accumulator.intervalSwapCount, 1);
    // it does not commit an observation
    assertFalse(_committed);
  }

  modifier whenRecordingASubsequentSwap() {
    _;
  }

  function test_WhenRecordingASubsequentSwap(
    uint120 _existingCumulative,
    uint120 _delta,
    uint32 _existingSwapCount,
    uint16 _existingIntervalSwapCount
  ) external whenCallerIsInAllowedCallerMap whenRecordingASubsequentSwap {
    _existingCumulative = uint120(bound(_existingCumulative, 0, type(uint120).max - 1));
    _delta = uint120(bound(_delta, 0, type(uint120).max - _existingCumulative));
    _existingSwapCount = uint32(bound(_existingSwapCount, 0, type(uint32).max - 1));
    _existingIntervalSwapCount = uint16(bound(_existingIntervalSwapCount, 0, type(uint16).max - 1));

    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: _existingSwapCount,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: _existingIntervalSwapCount,
        _cumulative: _existingCumulative
      })
    );

    vm.record();
    _tape.record(_pool, _clPoolTapeData({_value: uint128(_delta), _tick: 0}));
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    uint120 _expectedCumulative = _existingCumulative + _delta;
    // it adds every cumulative delta to the accumulator
    assertEq(_accumulator.cumulativeFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeFee1, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee1, _expectedCumulative);
    // it increments swapCount by one
    assertEq(_accumulator.swapCount, _existingSwapCount + 1);
    // it increments intervalSwapCount by one
    assertEq(_accumulator.intervalSwapCount, _existingIntervalSwapCount + 1);
    // it writes each accumulator slot exactly once
    assertEq(_writes.length, 5);
  }

  function test_WhenACumulativeAdditionOverflows(uint120 _delta)
    external
    whenCallerIsInAllowedCallerMap
    whenRecordingASubsequentSwap
  {
    _delta = uint120(bound(_delta, 1, type(uint120).max));

    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: 0,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: 0,
        _cumulative: type(uint120).max
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: uint128(_delta), _tick: 0}));

    uint120 _expectedCumulative = uint120(uint256(type(uint120).max) + _delta);
    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    // it wraps the cumulative
    assertEq(_accumulator.cumulativeFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeFee1, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee1, _expectedCumulative);
  }

  function test_WhenTheIntervalSwapCountIsAtItsMaximum(int24 _tick)
    external
    whenCallerIsInAllowedCallerMap
    whenRecordingASubsequentSwap
  {
    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: 0,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: type(uint16).max,
        _cumulative: 0
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: _tick}));

    // it keeps the intervalSwapCount max value
    assertEq(_tape.accumulators(_pool).intervalSwapCount, type(uint16).max);
  }

  function test_WhenTheSwapCountIsAtItsMaximum(int24 _tick)
    external
    whenCallerIsInAllowedCallerMap
    whenRecordingASubsequentSwap
  {
    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: type(uint32).max,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: 0,
        _cumulative: 0
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: _tick}));

    // it wraps the swapCount to zero
    assertEq(_tape.accumulators(_pool).swapCount, 0);
  }

  function test_WhenTheIntervalSwapCountIsEqToZero(
    int24 _tick,
    int24 _existingMaxTick,
    int24 _existingMinTick
  ) external whenCallerIsInAllowedCallerMap {
    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: 0,
        _intervalMaxTick: _existingMaxTick,
        _intervalMinTick: _existingMinTick,
        _intervalSwapCount: 0,
        _cumulative: 0
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: _tick}));

    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    // it sets intervalMaxTick to the swap tick
    assertEq(_accumulator.intervalMaxTick, _tick);
    // it sets intervalMinTick to the swap tick
    assertEq(_accumulator.intervalMinTick, _tick);
  }

  function test_WhenTheIntervalSwapCountIsGtZero(
    uint16 _existingIntervalSwapCount,
    int24 _tick,
    int24 _existingMaxTick,
    int24 _existingMinTick
  ) external whenCallerIsInAllowedCallerMap {
    _existingIntervalSwapCount = uint16(bound(_existingIntervalSwapCount, 1, type(uint16).max));

    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: uint40(block.timestamp),
        _swapCount: 0,
        _intervalMaxTick: _existingMaxTick,
        _intervalMinTick: _existingMinTick,
        _intervalSwapCount: _existingIntervalSwapCount,
        _cumulative: 0
      })
    );

    _tape.record(_pool, _clPoolTapeData({_value: 0, _tick: _tick}));

    int24 _expectedMaxTick = _tick > _existingMaxTick ? _tick : _existingMaxTick;
    int24 _expectedMinTick = _tick < _existingMinTick ? _tick : _existingMinTick;
    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    // it updates the interval tick extremes
    assertEq(_accumulator.intervalMaxTick, _expectedMaxTick);
    assertEq(_accumulator.intervalMinTick, _expectedMinTick);
  }

  function test_WhenTheElapsedTimeIsLteThePoolCadence(
    uint32 _cadence,
    uint32 _shortfall
  ) external whenCallerIsInAllowedCallerMap {
    _cadence = uint32(bound(_cadence, 1, type(uint32).max - 1));
    _shortfall = uint32(bound(_shortfall, 0, _cadence));
    _setPoolConfig({_configCaller: _caller, _cadence: _cadence});
    vm.warp(uint256(_cadence - _shortfall) + 1);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: 1,
        _swapCount: 0,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: 0,
        _cumulative: 0
      })
    );

    // it does not commit an observation
    assertFalse(_tape.record(_pool, _clPoolTapeData({_value: 0, _tick: 0})));
  }

  function test_WhenTheElapsedTimeIsGtThePoolCadence(
    uint32 _cadence,
    uint32 _elapsed
  ) external whenCallerIsInAllowedCallerMap {
    _cadence = uint32(bound(_cadence, 1, type(uint32).max - 1));
    _elapsed = uint32(bound(_elapsed, _cadence + 1, type(uint32).max));
    _setPoolConfig({_configCaller: _caller, _cadence: _cadence});
    vm.warp(uint256(_elapsed) + 1);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(
      _subsequentSwapAccumulator({
        _lastSwapTimestamp: 1,
        _lastObservationTimestamp: 1,
        _swapCount: 0,
        _intervalMaxTick: 0,
        _intervalMinTick: 0,
        _intervalSwapCount: 0,
        _cumulative: 0
      })
    );
    _mockPoolStakedCumulative({_poolAddress: _pool, _cumulative: 0});
    _mockPoolSecondsPerLiquidityCumulativeX128({
      _poolAddress: _pool, _secondsPerLiquidityCumulativeX128: 0, _secondsAgo: 0
    });

    // it returns the committed flag
    assertTrue(_tape.record(_pool, _clPoolTapeData({_value: 0, _tick: 0})));
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _clPoolTapeData(
    uint128 _value,
    int24 _tick
  ) internal pure returns (ICLPoolTape.CLPoolTapeData memory _data) {
    _data = ICLPoolTape.CLPoolTapeData({
      fee0: _value,
      fee1: _value,
      volume0: _value,
      volume1: _value,
      mevVolume0: _value,
      mevVolume1: _value,
      mevFee0: _value,
      mevFee1: _value,
      tick: _tick
    });
  }

  /// @dev Builds an accumulator for a pool that already recorded a swap.
  function _subsequentSwapAccumulator(
    uint40 _lastSwapTimestamp,
    uint40 _lastObservationTimestamp,
    uint32 _swapCount,
    int24 _intervalMaxTick,
    int24 _intervalMinTick,
    uint16 _intervalSwapCount,
    uint120 _cumulative
  ) internal pure returns (ICLPoolTape.Accumulator memory _accumulator) {
    _accumulator = ICLPoolTape.Accumulator({
      lastSwapTimestamp: _lastSwapTimestamp,
      lastObservationTimestamp: _lastObservationTimestamp,
      swapCount: _swapCount,
      lastTick: 0,
      intervalMaxTick: _intervalMaxTick,
      intervalMinTick: _intervalMinTick,
      intervalOpenTick: 0,
      volatilityCorrob: 0,
      cumulativeVolume0: _cumulative,
      cumulativeVolume1: _cumulative,
      intervalSwapCount: _intervalSwapCount,
      cumulativeFee0: _cumulative,
      cumulativeFee1: _cumulative,
      volatilityRingHead: 0,
      volatilityRingCount: 0,
      cumulativeMevVolume0: _cumulative,
      cumulativeMevVolume1: _cumulative,
      nOver: 0,
      cumulativeMevFee0: _cumulative,
      cumulativeMevFee1: _cumulative
    });
  }
}
