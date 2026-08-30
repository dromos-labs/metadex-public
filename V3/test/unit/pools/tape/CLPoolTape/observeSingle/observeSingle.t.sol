// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';
import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

contract UnitClPoolTapeObserveSingle is UnitClPoolTapeBase {
  function test_WhenThePoolHasNoRecordedSwap(uint40 _now, uint48 _secondsAgo) external {
    _now = uint40(bound(_now, 1, type(uint40).max));
    vm.warp(_now);

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns a zeroed observation
    assertEq(_result.cumulativeFee0, 0);
    assertEq(_result.cumulativeVolume0, 0);
    assertEq(_result.cumulativeMevVolume0, 0);
    assertEq(_result.cumulativeMevFee0, 0);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, 0);
    assertEq(_result.secondsPerLiquidityCumulativeX128, 0);
    assertEq(_result.swapCount, 0);
    assertEq(_result.closeTick, 0);
    assertEq(_result.volatilityCorrob, 0);
    assertEq(_result.blockTimestamp, 0);
  }

  function test_WhenSecondsAgoIsEqToZero(
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint160 _secondsPerLiquidityCumulativeX128,
    uint160 _stakedCumulativeX128
  ) external {
    _now = uint40(bound(_now, 2, type(uint40).max));
    _accumulator.lastSwapTimestamp = _now;
    _setAccumulator(_accumulator);

    _mockPoolStakedCumulative(_pool, _stakedCumulativeX128);
    _mockPoolSecondsPerLiquidityCumulativeX128(_pool, _secondsPerLiquidityCumulativeX128, 0);

    vm.warp(_now);

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, 0);

    // it returns the current accumulator as an observation with the current timestamp
    assertEq(_result.cumulativeFee0, _accumulator.cumulativeFee0);
    assertEq(_result.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_result.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_result.swapCount, _accumulator.swapCount);
    assertEq(_result.closeTick, _accumulator.lastTick);
    assertEq(_result.volatilityCorrob, _accumulator.volatilityCorrob);
    assertEq(_result.blockTimestamp, _now);

    // it reads the live staked cumulative from the pool
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _stakedCumulativeX128);
    // it reads the active liquidity from the pool oracle
    assertEq(_result.secondsPerLiquidityCumulativeX128, _secondsPerLiquidityCumulativeX128);
  }

  modifier whenSecondsAgoIsGtZero() {
    _;
  }

  function test_WhenSecondsAgoIsGteTheCurrentBlockTime(
    ICLPoolTape.Observation memory _oldest,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero {
    _oldest.blockTimestamp = uint40(bound(_oldest.blockTimestamp, 1, type(uint40).max));
    // we need the accumulator to have a non zero lastSwapTimestamp
    _accumulator.lastSwapTimestamp = _oldest.blockTimestamp;
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_accumulator);

    _now = uint40(bound(_now, 1, type(uint40).max));
    vm.warp(_now);
    _secondsAgo = uint48(bound(_secondsAgo, _now, type(uint48).max));

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it sets the target to zero and returns the oldest observation
    assertEq(_result.cumulativeFee0, _oldest.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _oldest.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _oldest.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_result.secondsPerLiquidityCumulativeX128, _oldest.secondsPerLiquidityCumulativeX128);
    assertEq(_result.swapCount, _oldest.swapCount);
    assertEq(_result.closeTick, _oldest.closeTick);
    assertEq(_result.volatilityCorrob, _oldest.volatilityCorrob);
    assertEq(_result.blockTimestamp, _oldest.blockTimestamp);
  }

  modifier whenSecondsAgoIsLtTheCurrentBlockTime() {
    _;
  }

  modifier whenTheTargetIsGteTheLastSwapTimestamp() {
    _;
  }

  function test_WhenTheTargetIsGteTheLastSwapTimestamp(
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _lastUpdated,
    uint48 _secondsAgo,
    uint160 _secondsPerLiquidityCumulativeX128,
    uint160 _settledStakedX128,
    uint160 _liveStakedX128
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsGteTheLastSwapTimestamp {
    _now = uint40(bound(_now, 3, type(uint40).max));
    _accumulator.lastSwapTimestamp = uint40(bound(_accumulator.lastSwapTimestamp, 1, _now - 2));
    _setAccumulator(_accumulator);

    vm.warp(_now);

    _secondsAgo = uint48(bound(_secondsAgo, 1, _now - _accumulator.lastSwapTimestamp - 1));
    uint40 _target = _now - uint40(_secondsAgo);
    _lastUpdated = uint48(bound(_lastUpdated, 1, _target));

    _mockPoolSecondsPerLiquidityCumulativeX128(_pool, _secondsPerLiquidityCumulativeX128, uint32(_secondsAgo));
    _mockPoolSettlement(_pool, _lastUpdated, _settledStakedX128);
    _mockPoolStakedCumulative(_pool, _liveStakedX128);

    // unchecked so the delta is valid if the cumulative wrapped
    uint256 _stakedDelta;
    unchecked {
      _stakedDelta = _liveStakedX128 - _settledStakedX128;
    }
    uint160 _expectedStaked =
      uint160(_settledStakedX128 + (_stakedDelta * (_target - _lastUpdated)) / (_now - _lastUpdated));

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the current accumulator as an observation with the target timestamp
    assertEq(_result.cumulativeFee0, _accumulator.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _accumulator.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _accumulator.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _accumulator.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _accumulator.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _accumulator.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _accumulator.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _accumulator.cumulativeMevFee1);
    assertEq(_result.swapCount, _accumulator.swapCount);
    assertEq(_result.closeTick, _accumulator.lastTick);
    assertEq(_result.volatilityCorrob, _accumulator.volatilityCorrob);
    assertEq(_result.blockTimestamp, _target);

    // it returns the staked cumulative interpolated between the snapshot and the pool projection
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _expectedStaked);
    // it reads the active liquidity from the pool oracle
    assertEq(_result.secondsPerLiquidityCumulativeX128, _secondsPerLiquidityCumulativeX128);
  }

  function test_WhenGivenAConcreteSnapshotAndProjection()
    external
    whenSecondsAgoIsGtZero
    whenSecondsAgoIsLtTheCurrentBlockTime
    whenTheTargetIsGteTheLastSwapTimestamp
  {
    ICLPoolTape.Accumulator memory _accumulator;
    _accumulator.lastSwapTimestamp = 1000;
    _setAccumulator(_accumulator);

    _mockPoolSettlement(_pool, 1000, 100);
    _mockPoolStakedCumulative(_pool, 107);
    _mockPoolSecondsPerLiquidityCumulativeX128(_pool, 0, 7);

    vm.warp(1010);

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, 7);

    // it returns the rounded down interpolation
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, 102);
  }

  modifier whenTheTargetIsLtTheLastSwapTimestamp() {
    _;
  }

  function test_WhenTheTargetIsGteTheUpperBound(
    ICLPoolTape.Observation memory _upperBound,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint40(bound(_now, 5, type(uint40).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 3));
    uint40 _target = uint40(_now - _secondsAgo);
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

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the upper bound observation
    assertEq(_result.cumulativeFee0, _upperBound.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _upperBound.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _upperBound.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _upperBound.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _upperBound.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _upperBound.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _upperBound.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _upperBound.cumulativeMevFee1);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _upperBound.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_result.secondsPerLiquidityCumulativeX128, _upperBound.secondsPerLiquidityCumulativeX128);
    assertEq(_result.swapCount, _upperBound.swapCount);
    assertEq(_result.closeTick, _upperBound.closeTick);
    assertEq(_result.volatilityCorrob, _upperBound.volatilityCorrob);
    assertEq(_result.blockTimestamp, _upperBound.blockTimestamp);
  }

  function test_WhenTheTargetIsLteTheLowerBound(
    ICLPoolTape.Observation memory _oldest,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint40(bound(_now, 3, type(uint40).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 1));
    uint40 _target = uint40(_now - _secondsAgo);
    _oldest.blockTimestamp = _target + 1; // oldest sits just after the target
    _accumulator.lastSwapTimestamp = _target + 2;
    _setObservation(0, _oldest);
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_accumulator);

    vm.warp(_now);

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);

    // it returns the lower bound observation
    assertEq(_result.cumulativeFee0, _oldest.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _oldest.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _oldest.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _oldest.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _oldest.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _oldest.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _oldest.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _oldest.cumulativeMevFee1);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _oldest.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_result.secondsPerLiquidityCumulativeX128, _oldest.secondsPerLiquidityCumulativeX128);
    assertEq(_result.swapCount, _oldest.swapCount);
    assertEq(_result.closeTick, _oldest.closeTick);
    assertEq(_result.volatilityCorrob, _oldest.volatilityCorrob);
    assertEq(_result.blockTimestamp, _oldest.blockTimestamp);
  }

  function test_WhenTheTargetIsStrictlyBetweenTheBounds(
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgo
  ) external whenSecondsAgoIsGtZero whenSecondsAgoIsLtTheCurrentBlockTime whenTheTargetIsLtTheLastSwapTimestamp {
    _now = uint40(bound(_now, 4, type(uint40).max));
    _secondsAgo = uint48(bound(_secondsAgo, 2, _now - 2));
    uint40 _target = uint40(_now - _secondsAgo);
    _before.blockTimestamp = _target - 1; // one observation just below the target
    _after.blockTimestamp = _target + 1; // one observation just above the target
    _after.cumulativeFee0 = uint120(bound(_after.cumulativeFee0, _before.cumulativeFee0, type(uint120).max));
    _after.cumulativeVolume0 = uint120(bound(_after.cumulativeVolume0, _before.cumulativeVolume0, type(uint120).max));
    _after.secondsPerStakedLiquidityCumulativeX128 = uint160(
      bound(
        _after.secondsPerStakedLiquidityCumulativeX128,
        _before.secondsPerStakedLiquidityCumulativeX128,
        type(uint160).max
      )
    );
    _after.secondsPerLiquidityCumulativeX128 = uint160(
      bound(_after.secondsPerLiquidityCumulativeX128, _before.secondsPerLiquidityCumulativeX128, type(uint160).max)
    );
    _after.swapCount = uint32(bound(_after.swapCount, _before.swapCount, type(uint32).max));
    _accumulator.lastSwapTimestamp = _target + 2;
    _setObservation(0, _before);
    _setObservation(1, _after);
    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _setAccumulator(_accumulator);

    vm.warp(_now);

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgo);
    ICLPoolTape.Observation memory _expected =
      MockCLPoolTape(address(_tape)).externalInterpolate(_before, _after, _target);

    // it returns the interpolation between the bounds
    assertEq(_result.cumulativeFee0, _expected.cumulativeFee0);
    assertEq(_result.cumulativeFee1, _expected.cumulativeFee1);
    assertEq(_result.cumulativeVolume0, _expected.cumulativeVolume0);
    assertEq(_result.cumulativeVolume1, _expected.cumulativeVolume1);
    assertEq(_result.cumulativeMevVolume0, _expected.cumulativeMevVolume0);
    assertEq(_result.cumulativeMevVolume1, _expected.cumulativeMevVolume1);
    assertEq(_result.cumulativeMevFee0, _expected.cumulativeMevFee0);
    assertEq(_result.cumulativeMevFee1, _expected.cumulativeMevFee1);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, _expected.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_result.secondsPerLiquidityCumulativeX128, _expected.secondsPerLiquidityCumulativeX128);
    assertEq(_result.swapCount, _expected.swapCount);
    assertEq(_result.closeTick, _expected.closeTick);
    assertEq(_result.volatilityCorrob, _expected.volatilityCorrob);
    assertEq(_result.blockTimestamp, _target);
  }

  /*////////////////////////////////////////////////////////////
                        HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
