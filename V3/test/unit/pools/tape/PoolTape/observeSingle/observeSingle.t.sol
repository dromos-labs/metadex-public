// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract UnitPoolTapeObserveSingle is UnitPoolTapeBase {
  function test_WhenThePoolHasNoRecordedSwap(uint48 _now, uint48 _secondsAgo) external {
    _now = uint48(bound(_now, 1, type(uint48).max));
    vm.warp(_now);

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns a zeroed observation
    assertEq(_result.cumulativeFee0, 0);
    assertEq(_result.cumulativeFee1, 0);
    assertEq(_result.cumulativeVolume0, 0);
    assertEq(_result.cumulativeVolume1, 0);
    assertEq(_result.cumulativeMevVolume0, 0);
    assertEq(_result.cumulativeMevVolume1, 0);
    assertEq(_result.cumulativeMevFee0, 0);
    assertEq(_result.cumulativeMevFee1, 0);
    assertEq(_result.swapCount, 0);
    assertEq(_result.blockTimestamp, 0);
  }

  function test_WhenSecondsAgoIsEqToZero(IPoolTape.Accumulator memory _accumulator, uint48 _now) external {
    _now = uint48(bound(_now, 1, type(uint48).max));
    _accumulator.lastSwapTimestamp = uint48(bound(_accumulator.lastSwapTimestamp, 1, _now));
    _setAccumulator(_accumulator);

    vm.warp(_now);

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, 0);

    // it returns the current accumulator as an observation
    assertEq(_result.cumulativeFee0, _accumulator.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _accumulator.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _accumulator.cumulativeMevFee1);
    assertEq(_result.swapCount, _accumulator.swapCount);
    assertEq(_result.blockTimestamp, _now);
  }

  modifier whenSecondsAgoIsGtZero() {
    _;
  }

  function test_WhenSecondsAgoIsGteTheCurrentBlockTime(
    IPoolTape.Observation memory _oldest,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero {
    _oldest.blockTimestamp = uint48(bound(_oldest.blockTimestamp, 1, type(uint48).max));
    // we just need the accumulator to have a non zero lastSwapTimestamp
    _accumulator.lastSwapTimestamp = _oldest.blockTimestamp;
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_accumulator);

    _now = uint48(bound(_now, 1, type(uint48).max));
    vm.warp(_now);
    _secondsAgo = uint48(bound(_secondsAgo, _now, type(uint48).max));

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it sets the target to zero and returns the oldest observation
    assertEq(_result.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_result.swapCount, _oldest.swapCount);
    assertEq(_result.blockTimestamp, _oldest.blockTimestamp);
  }

  modifier whenSecondsAgoIsLtTheCurrentBlockTime() {
    _;
  }

  function test_WhenTheTargetIsGteTheLastSwapTimestamp(
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _lastSwapTimestamp,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime {
    _now = uint48(bound(_now, 2, type(uint48).max));
    _lastSwapTimestamp = uint48(bound(_lastSwapTimestamp, 1, _now - 1));
    _accumulator.lastSwapTimestamp = _lastSwapTimestamp;
    _setAccumulator(_accumulator);

    vm.warp(_now);

    _secondsAgo = uint48(bound(_secondsAgo, 1, _now - _lastSwapTimestamp));
    uint48 _target = _now - _secondsAgo;

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the current accumulator as an observation with the target timestamp
    assertEq(_result.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _accumulator.cumulativeMevFee1);
    assertEq(_result.swapCount, _accumulator.swapCount);
    assertEq(_result.blockTimestamp, _target);
  }

  modifier whenTheTargetIsLtTheLastSwapTimestamp() {
    _;
  }

  function test_WhenTheTargetIsGteTheUpperBound(
    IPoolTape.Observation memory _upperBound,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint48(bound(_now, 5, type(uint48).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 3));
    uint48 _target = _now - _secondsAgo;
    // Four committed observations, with the target landing exactly on the upper bound
    _setObservationTimestamp(0, _target - 2);
    _setObservationTimestamp(1, _target - 1);
    _upperBound.blockTimestamp = _target;
    _setObservation(2, _upperBound);
    _setObservationTimestamp(3, _target + 1);
    _accumulator.lastSwapTimestamp = _target + 2;
    _setObservationInformationSlot({_index: 3, _cardinality: 4, _cardinalityNext: 4});
    _setAccumulator(_accumulator);

    vm.warp(_now);

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the upper bound observation
    assertEq(_result.cumulativeVolume0, _upperBound.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _upperBound.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _upperBound.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _upperBound.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _upperBound.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _upperBound.cumulativeMevFee1);
    assertEq(_result.swapCount, _upperBound.swapCount);
    assertEq(_result.blockTimestamp, _upperBound.blockTimestamp);
  }

  function test_WhenTheTargetIsLteTheLowerBound(
    IPoolTape.Observation memory _oldest,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint48(bound(_now, 3, type(uint48).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 1));
    uint48 _target = _now - _secondsAgo;
    _oldest.blockTimestamp = _target + 1; // oldest sits just after the target
    _accumulator.lastSwapTimestamp = _target + 2;
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_accumulator);

    vm.warp(_now);

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the lower bound observation
    assertEq(_result.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_result.swapCount, _oldest.swapCount);
    assertEq(_result.blockTimestamp, _oldest.blockTimestamp);
  }

  function test_WhenTheTargetIsStrictlyBetweenTheBounds(
    IPoolTape.Observation memory _before,
    IPoolTape.Observation memory _after,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint48(bound(_now, 4, type(uint48).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 2));
    uint48 _target = _now - _secondsAgo;
    _before.blockTimestamp = _target - 1; // one observation just below the target
    _after.blockTimestamp = _target + 1; // one observation just above the target
    _after.cumulativeFee0 = uint128(bound(_after.cumulativeFee0, _before.cumulativeFee0, type(uint128).max));
    _after.cumulativeFee1 = uint128(bound(_after.cumulativeFee1, _before.cumulativeFee1, type(uint128).max));
    _after.cumulativeVolume0 = uint128(bound(_after.cumulativeVolume0, _before.cumulativeVolume0, type(uint128).max));
    _after.cumulativeVolume1 = uint128(bound(_after.cumulativeVolume1, _before.cumulativeVolume1, type(uint128).max));
    _after.cumulativeMevVolume0 =
      uint128(bound(_after.cumulativeMevVolume0, _before.cumulativeMevVolume0, type(uint128).max));
    _after.cumulativeMevVolume1 =
      uint128(bound(_after.cumulativeMevVolume1, _before.cumulativeMevVolume1, type(uint128).max));
    _after.cumulativeMevFee0 = uint128(bound(_after.cumulativeMevFee0, _before.cumulativeMevFee0, type(uint128).max));
    _after.cumulativeMevFee1 = uint128(bound(_after.cumulativeMevFee1, _before.cumulativeMevFee1, type(uint128).max));
    _after.swapCount = uint48(bound(_after.swapCount, _before.swapCount, type(uint48).max));
    _accumulator.lastSwapTimestamp = _target + 2;
    _setObservation(0, _before);
    _setObservation(1, _after);
    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _setAccumulator(_accumulator);

    vm.warp(_now);

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);
    IPoolTape.Observation memory _expected = MockPoolTape(address(_tape)).externalInterpolate(_before, _after, _target);

    // it returns the interpolation between the bounds
    assertEq(_result.cumulativeFee0, _expected.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _expected.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _expected.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _expected.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _expected.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _expected.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _expected.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _expected.cumulativeMevFee1);
    assertEq(_result.swapCount, _expected.swapCount);
    assertEq(_result.blockTimestamp, _target);
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (PoolTape) {
    return new MockPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
