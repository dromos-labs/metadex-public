// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the bounded `advanceGlobalPoints(uint256)` overload
 */
contract UnitConcreteVotingRewardsManagerAdvanceGlobalPointsWithMaxIterations is UnitVotingRewardsManager {
  /// @dev Permanent voting weight used to keep supply constant across the tested intervals
  uint128 internal constant _WEIGHT = uint128(1000 * TOKEN_1);

  uint48 internal _initialTs;
  uint48 internal _advanceTs;
  uint48 internal _partialTs;
  uint128 internal _weight;
  uint256 internal _maxIterations;
  uint256 internal _remainingIntervals;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _targetIndex;
  uint256 internal _pending0;
  uint256 internal _pending1;

  modifier whenMaxIterationsIsInvalid() {
    _;
  }

  function test_WhenMaxIterationsIsZero(address _caller) external whenMaxIterationsIsInvalid {
    _assumeFuzzable(_caller);

    // it should revert with InvalidCheckpointIterations
    vm.expectRevert(IVotingRewardsManager.InvalidCheckpointIterations.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(0);
  }

  function test_WhenMaxIterationsExceedsTheMaximum(
    address _caller,
    uint256 _maxIterationsFuzz
  ) external whenMaxIterationsIsInvalid {
    _assumeFuzzable(_caller);
    _maxIterationsFuzz = bound(_maxIterationsFuzz, MAX_CHECKPOINT_ITERATIONS + 1, type(uint256).max);

    // it should revert with InvalidCheckpointIterations
    vm.expectRevert(IVotingRewardsManager.InvalidCheckpointIterations.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(_maxIterationsFuzz);
  }

  modifier whenMaxIterationsIsValid(uint256 _maxIterationsFuzz) {
    _maxIterations = bound(_maxIterationsFuzz, 1, MAX_CHECKPOINT_ITERATIONS);
    _;
  }

  function test_WhenThereIsNoPriorGlobalCheckpoint(
    address _caller,
    uint256 _maxIterationsFuzz
  ) external whenMaxIterationsIsValid(_maxIterationsFuzz) {
    _assumeFuzzable(_caller);

    // it should revert with NoGlobalCheckpoint
    vm.expectRevert(IVotingRewardsManager.NoGlobalCheckpoint.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(_maxIterations);
  }

  modifier whenThereIsAtLeastOnePriorGlobalCheckpoint(uint48 _initialTsFuzz, uint128 _weightFuzz) {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, type(uint48).max - 4 * MAX_CHECKPOINT_ITERATIONS * 1 weeks));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_advanceTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _weight = uint128(bound(_weightFuzz, 1, type(uint120).max));

    // @dev Record a global checkpoint at `_initialTs`
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    _;
  }

  function test_WhenTheLatestGlobalPointWasRecordedInTheCurrentEpoch(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _advanceTsFuzz,
    uint256 _maxIterationsFuzz
  )
    external
    whenMaxIterationsIsValid(_maxIterationsFuzz)
    whenThereIsAtLeastOnePriorGlobalCheckpoint(_initialTsFuzz, _WEIGHT)
  {
    _assumeFuzzable(_caller);
    _advanceTs = uint48(bound(_advanceTsFuzz, _initialTs, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    vm.warp(_advanceTs);

    // it should revert with TooSoon
    vm.expectRevert(IVotingRewardsManager.TooSoon.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(_maxIterations);
  }

  modifier whenTheLatestGlobalPointWasRecordedInAPriorEpoch() {
    _;
  }

  function test_WhenHistoryReachesTheCheckpointIterationLimit(
    address _caller,
    uint256 _maxIterationsFuzz,
    uint48 _initialTsFuzz,
    uint120 _weightFuzz,
    uint256 _pending0Fuzz
  )
    external
    whenMaxIterationsIsValid(_maxIterationsFuzz)
    whenThereIsAtLeastOnePriorGlobalCheckpoint(_initialTsFuzz, _weightFuzz)
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _assumeFuzzable(_caller);
    // @dev Ensure both pending fee amounts meet the credit threshold for the permanent supply
    _pending0 = bound(_pending0Fuzz, 2 * (uint256(_weight) / FEE_ACCUMULATOR_PRECISION + 1), type(uint128).max);
    _pending1 = _pending0 / 2;

    // @dev Require exactly `_maxIterations` weekly checkpoints to reach the current timestamp
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _maxIterations * 1 weeks);
    vm.warp(_advanceTs);
    _mockGaugePendingFees(_pending0, _pending1);

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 =
        _ceilDiv((_pending0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 =
        _ceilDiv((_pending1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);

      // it should notify the pending fees
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
    }

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(_caller, _priorIndex + _maxIterations);

    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(_maxIterations);

    // it should reach the current timestamp in one advance
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _maxIterations);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _advanceTs);

    uint256 _feeAcc0 = _pending0 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _feeAcc1 = _pending1 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();

    // it should snapshot the credited fee accumulator at the current timestamp
    _assertFeeSnapshot(
      _newIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_advanceTs - _origin), _feeAcc1 * (_advanceTs - _origin)
    );
  }

  function test_WhenHistoryExceedsTheCheckpointIterationLimit(
    address _caller,
    address _secondCaller,
    uint256 _maxIterationsFuzz,
    uint48 _initialTsFuzz,
    uint16 _remainingIntervalsFuzz
  )
    external
    whenMaxIterationsIsValid(_maxIterationsFuzz)
    whenThereIsAtLeastOnePriorGlobalCheckpoint(_initialTsFuzz, _WEIGHT)
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_secondCaller);
    vm.assume(_secondCaller != _caller);
    // @dev Require between two and four bounded calls to reach the current timestamp
    _remainingIntervals = bound(_remainingIntervalsFuzz, 1, 3 * _maxIterations);
    _targetIndex = _priorIndex + _maxIterations + _remainingIntervals;
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + (_maxIterations + _remainingIntervals) * 1 weeks);
    vm.warp(_advanceTs);

    /// @dev Revert any pending-fee query to prove partial recovery does not read the gauge
    vm.clearMockedCalls();
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(_caller, _priorIndex + _maxIterations);

    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints(_maxIterations);

    _newIndex = _priorIndex + _maxIterations;
    _partialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _maxIterations * 1 weeks);

    // it should advance the selected number of intervals
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _partialTs);

    // it should not query the gauge for pending fees

    // it should not notify pending fees
    assertEq(votingRewardsManager.lastFeeUpdate(), _initialTs);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should preserve fee accounting at the partial frontier
    _assertFeeAccumulator(0, 0, 0, 0);
    _assertFeeSnapshot(_newIndex, 0, 0, 0, 0);

    // @dev Advance any additional full partial batches without allowing a pending-fee query
    while (_targetIndex - _newIndex > _maxIterations) {
      vm.clearMockedCalls();
      vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

      uint256 _nextIndex = _newIndex + _maxIterations;
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.GlobalPointsAdvanced(_secondCaller, _nextIndex);

      vm.prank(_secondCaller);
      votingRewardsManager.advanceGlobalPoints(_maxIterations);

      _newIndex = votingRewardsManager.globalCheckpointIndex();
      assertEq(_newIndex, _nextIndex);
      _assertFeeAccumulator(0, 0, 0, 0);
      assertEq(votingRewardsManager.lastFeeUpdate(), _initialTs);
      assertEq(votingRewardsManager.lastPendingFees0(), 0);
      assertEq(votingRewardsManager.lastPendingFees1(), 0);
      _assertFeeSnapshot(_newIndex, 0, 0, 0, 0);
    }

    vm.clearMockedCalls();
    _mockGaugePendingFees(0, 0);

    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(_secondCaller, _targetIndex);

    vm.prank(_secondCaller);
    votingRewardsManager.advanceGlobalPoints(_maxIterations);

    // it should resume from the partial frontier on later calls
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _targetIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_priorIndex + _maxIterations).ts, _partialTs);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _advanceTs);
  }
}
