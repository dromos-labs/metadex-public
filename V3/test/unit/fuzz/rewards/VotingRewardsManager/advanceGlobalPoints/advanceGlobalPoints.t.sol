// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitFuzzVotingRewardsManagerAdvanceGlobalPoints is UnitFuzzVotingRewardsManager {
  /// @dev Gauge fees pending at the initial checkpoint
  uint256 internal constant _INITIAL_PENDING_0 = 500 * TOKEN_1;
  uint256 internal constant _INITIAL_PENDING_1 = 1000 * TOKEN_1;
  /// @dev Gauge fees pending while stale checkpoint history is recovered
  uint256 internal constant _PENDING_0 = 5 * TOKEN_1;
  uint256 internal constant _PENDING_1 = 7 * TOKEN_1;
  /// @dev Accumulator values after the initial credit: _INITIAL_PENDING * FEE_ACCUMULATOR_PRECISION / _weightPerm
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e24;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e24;
  /// @dev Time-weighted accumulators seeded for the advance with no pending fees
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e24;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e24;

  /// @dev Cached fuzz inputs to avoid stack too deep
  int128 internal _slopeB;
  int128 internal _initialBiasB;
  int128 internal _intermediateBias;
  int128 internal _intermediateSlope;
  int128 internal _finalBias;
  int128 internal _finalSlope;
  uint16 internal _weeksElapsed;
  uint16 internal _remainingWeeks;
  uint48 internal _initialTs;
  uint48 internal _advanceTs;
  uint48 internal _stakeEndB;
  uint120 internal _weight;
  uint120 internal _weightPerm;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint48 internal _intermediateTs;

  /// @dev Cached accumulator variables to avoid stack too deep
  uint256 internal _feeAcc0;
  uint256 internal _feeAcc1;
  uint256 internal _buffered0;
  uint256 internal _buffered1;
  uint256 internal _supply;
  uint256 internal _prevShare;
  uint256 internal _prevWeighted;
  uint256 internal _share;
  uint256 internal _weighted;

  function testFuzz_WhenThereIsNoPriorGlobalCheckpoint(address _caller) external {
    // it should revert with NoGlobalCheckpoint
    _assumeFuzzable(_caller);
    vm.expectRevert(IVotingRewardsManager.NoGlobalCheckpoint.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();
  }

  modifier whenThereIsAtLeastOnePriorGlobalCheckpoint() {
    _;
  }

  function testFuzz_WhenTheLatestGlobalPointWasRecordedInTheCurrentEpoch(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _advanceTsFuzz
  ) external whenThereIsAtLeastOnePriorGlobalCheckpoint {
    _assumeFuzzable(_caller);
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_advanceTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _advanceTs = uint48(bound(_advanceTsFuzz, _initialTs, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    uint128 _fixedWeight = 1000e18;

    // @dev Record a global checkpoint at `_initialTs`
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _fixedWeight, _stakeEnd: 0, _data: ''});

    vm.warp(_advanceTs);

    // it should revert with TooSoon
    vm.expectRevert(IVotingRewardsManager.TooSoon.selector);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();
  }

  modifier whenTheLatestGlobalPointWasRecordedInAPriorEpoch() {
    _;
  }

  function testFuzz_WhenHistoryReachesTheCheckpointIterationLimit(
    address _caller,
    uint48 _initialTsFuzz,
    uint120 _weightFuzz,
    uint256 _pending0
  ) external whenThereIsAtLeastOnePriorGlobalCheckpoint whenTheLatestGlobalPointWasRecordedInAPriorEpoch {
    _assumeFuzzable(_caller);
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, type(uint48).max - MAX_CHECKPOINT_ITERATIONS * 1 weeks));
    _weightPerm = uint120(bound(_weightFuzz, 1, type(uint120).max));

    // @dev Lower bound ensures both pending fee amounts meet the credit threshold for the permanent supply
    _pending0 = bound(_pending0, 2 * (uint256(_weightPerm) / FEE_ACCUMULATOR_PRECISION + 1), type(uint128).max);
    uint256 _pending1 = _pending0 / 2;

    // @dev Record a permanent stake at the initial checkpoint
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Advance exactly the maximum number of checkpoint intervals
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks);
    vm.warp(_advanceTs);
    _mockGaugePendingFees(_pending0, _pending1);

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 =
        _ceilDiv((_pending0 * FEE_ACCUMULATOR_PRECISION / _weightPerm) * _weightPerm, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 =
        _ceilDiv((_pending1 * FEE_ACCUMULATOR_PRECISION / _weightPerm) * _weightPerm, FEE_ACCUMULATOR_PRECISION);

      // it should notify the pending fees
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
    }

    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    // it should reach the current timestamp in one advance
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + MAX_CHECKPOINT_ITERATIONS);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _advanceTs);

    _feeAcc0 = _pending0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    _feeAcc1 = _pending1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;

    // it should snapshot the credited fee accumulator at the current timestamp
    _assertFeeAccumulator(
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    _assertFeeSnapshot(
      _newIndex,
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    assertEq(votingRewardsManager.lastFeeUpdate(), _advanceTs);
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
  }

  function testFuzz_WhenHistoryExceedsTheCheckpointIterationLimit(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _stakeEndBFuzz,
    uint120 _weightFuzz,
    uint16 _remainingWeeksFuzz
  ) external whenThereIsAtLeastOnePriorGlobalCheckpoint whenTheLatestGlobalPointWasRecordedInAPriorEpoch {
    _assumeFuzzable(_caller);
    // @dev Simulate enough stale global checkpoint history to require between two and four advanceGlobalPoints calls
    _remainingWeeks = uint16(bound(_remainingWeeksFuzz, 1, 3 * MAX_CHECKPOINT_ITERATIONS));
    _weeksElapsed = uint16(MAX_CHECKPOINT_ITERATIONS + _remainingWeeks);
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, type(uint48).max - 4 * MAX_CHECKPOINT_ITERATIONS * 1 weeks));
    // @dev Bound `_stakeEndB` so TOKEN_ID_B's lock is week-aligned
    _stakeEndB =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndBFuzz, _initialTs + 1 weeks, _initialTs + MAX_TIME)));
    // @dev TOKEN_ID_A locks half the fuzzed weight permanently; TOKEN_ID_B locks the full weight until `_stakeEndB`
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));
    _weightPerm = _weight / 2;

    // @dev Record a permanent stake for TOKEN_ID_A and a non-permanent stake for TOKEN_ID_B at `_initialTs`
    vm.warp(_initialTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    (_initialBiasB, _slopeB) = _contribution(_weight, _stakeEndB, _initialTs);
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + uint256(_weeksElapsed) * 1 weeks);

    // @dev Make history require between two and four calls by exceeding one full checkpoint iteration pass
    vm.warp(_advanceTs);

    // @dev Revert any pending-fee query to prove partial recovery does not read the gauge
    vm.clearMockedCalls();
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

    // @dev Advance the first maximum-sized checkpoint history segment
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    // it should advance only the maximum number of intervals on the first call
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks);
    assertEq(_newIndex, _priorIndex + MAX_CHECKPOINT_ITERATIONS);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _intermediateTs);

    // it should preserve fee accounting during partial recovery
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastFeeUpdate(), _initialTs);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
    _assertFeeSnapshot(_newIndex, 0, 0, 0, 0);

    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);

    uint256 _callCount = 1;
    uint256 _targetIndex = _priorIndex + _weeksElapsed;
    // @dev Repeatedly advance full checkpoint segments while another recovery call will still be required
    while (_targetIndex - _newIndex > MAX_CHECKPOINT_ITERATIONS) {
      uint256 _partialStartIndex = _newIndex;

      // @dev Revert any pending-fee query until checkpoint history can reach the current timestamp
      vm.clearMockedCalls();
      vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

      // @dev Advance the next checkpoint history segment toward the current timestamp
      vm.prank(_caller);
      votingRewardsManager.advanceGlobalPoints();

      _newIndex = votingRewardsManager.globalCheckpointIndex();
      assertEq(_newIndex, _partialStartIndex + MAX_CHECKPOINT_ITERATIONS);

      // it should preserve fee accounting during partial recovery
      _assertFeeAccumulator(0, 0, 0, 0);
      assertEq(votingRewardsManager.lastFeeUpdate(), _initialTs);
      assertEq(votingRewardsManager.lastPendingFees0(), 0);
      assertEq(votingRewardsManager.lastPendingFees1(), 0);
      assertEq(votingRewardsManager.bufferedFees0(), 0);
      assertEq(votingRewardsManager.bufferedFees1(), 0);
      _assertFeeSnapshot(_newIndex, 0, 0, 0, 0);

      // it should continue the supply accumulators across calls
      (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
      assertGt(_share, _prevShare);
      assertGt(_weighted, _prevWeighted);
      (_prevShare, _prevWeighted) = (_share, _weighted);
      ++_callCount;
    }

    uint256 _finalStartIndex = _newIndex;
    uint256 _remainingIntervals = _targetIndex - _finalStartIndex;

    // @dev Make pending fees available once checkpoint history can reach the current timestamp
    vm.clearMockedCalls();
    _mockGaugePendingFees(_PENDING_0, _PENDING_1);

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 =
        _ceilDiv((_PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm) * _weightPerm, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 =
        _ceilDiv((_PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm) * _weightPerm, FEE_ACCUMULATOR_PRECISION);

      // it should notify pending fees only when history reaches the current timestamp
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
    }

    // @dev Advance the final checkpoint history segment to the current timestamp
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _finalStartIndex + _remainingIntervals);

    // it should continue the supply accumulators across calls
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_share, _prevShare);
    assertGt(_weighted, _prevWeighted);
    ++_callCount;

    // it should resume from each checkpoint and reach the current timestamp within four calls
    assertEq(_callCount, (uint256(_weeksElapsed) + MAX_CHECKPOINT_ITERATIONS - 1) / MAX_CHECKPOINT_ITERATIONS);
    assertEq(_newIndex, _targetIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _advanceTs);

    _feeAcc0 = _PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    _feeAcc1 = _PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;

    // it should credit the pending fees exactly once
    _assertFeeAccumulator(
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    assertEq(votingRewardsManager.lastFeeUpdate(), _advanceTs);
    assertEq(votingRewardsManager.lastPendingFees0(), _PENDING_0);
    assertEq(votingRewardsManager.lastPendingFees1(), _PENDING_1);
    assertEq(
      votingRewardsManager.bufferedFees0(), _PENDING_0 - _ceilDiv(_feeAcc0 * _weightPerm, FEE_ACCUMULATOR_PRECISION)
    );
    assertEq(
      votingRewardsManager.bufferedFees1(), _PENDING_1 - _ceilDiv(_feeAcc1 * _weightPerm, FEE_ACCUMULATOR_PRECISION)
    );

    // it should snapshot the credited fee accumulator at the current timestamp
    _assertFeeSnapshot(
      _newIndex,
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should apply scheduled slope changes at each epoch boundary
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias, _intermediateSlope) = _contribution(_weight, _stakeEndB, _intermediateTs);
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _intermediateSlope,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
    }

    // it should not modify any user reward state
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightPerm,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_B), 1);
    _assertUserPoint({
      _expectedBias: _initialBiasB,
      _expectedSlope: _slopeB,
      _expectedPermanent: 0,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_B, 1)
    });

    // it should not modify the permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightPerm);
  }

  modifier whenTheAdvanceLandsWithinAnEpoch() {
    _;
  }

  function testFuzz_WhenTheGaugeHasPendingFees(
    uint48 _initialTsFuzz,
    uint48 _advanceTsFuzz,
    uint48 _stakeEndBFuzz,
    uint120 _weightFuzz,
    uint256 _pending0,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
    whenTheAdvanceLandsWithinAnEpoch
  {
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 1, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev Constrain _advanceTs so exactly _weeksElapsed week boundaries fall between _initialTs and _advanceTs
    _advanceTs = uint48(
      bound(
        _advanceTsFuzz,
        ProtocolTimeLibrary.epochStart(_initialTs + uint256(_weeksElapsed) * 1 weeks) + 1,
        ProtocolTimeLibrary.epochNext(_initialTs + uint256(_weeksElapsed) * 1 weeks) - 1
      )
    );
    // @dev Bound `_stakeEndB` so TOKEN_ID_B's lock is week-aligned
    _stakeEndB =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndBFuzz, _initialTs + 1 weeks, _advanceTs + MAX_TIME)));
    // @dev TOKEN_ID_A locks `_weight / 2` permanently; TOKEN_ID_B locks `_weight` non-permanently
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));
    _weightPerm = _weight / 2;

    // @dev totalSupply at credit time is the permanent balance plus TOKEN_ID_B's decayed bias
    {
      (int128 _decayedBias,) = _contribution(_weight, _stakeEndB, _advanceTs);
      _supply = uint256(_weightPerm) + uint256(uint128(_decayedBias));
    }
    // @dev Lower bound guarantees the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply` is met for both tokens
    _pending0 = bound(_pending0, 2 * (_supply / FEE_ACCUMULATOR_PRECISION + 1), type(uint128).max);
    uint256 _pending1 = _pending0 / 2;

    // @dev Record a permanent stake for TOKEN_ID_A one second early so the next checkpoint credits fees
    vm.warp(_initialTs - 1);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});

    vm.warp(_initialTs);

    // @dev Simulate gauge fees to advance the accumulator
    _mockGaugePendingFees(_INITIAL_PENDING_0, _INITIAL_PENDING_1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev TOKEN_ID_A's checkpoint one second before `_initialTs` seeds a non-zero supply interval, so the
    //      accumulator at `_priorIndex` is already positive
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    assertGt(_prevShare, 0);
    assertGt(_prevWeighted, 0);

    // @dev Accumulators increase by pendingFees * FEE_ACCUMULATOR_PRECISION / supply, with supply being `_weightPerm` at credit time
    _feeAcc0 = _INITIAL_PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    _feeAcc1 = _INITIAL_PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    // @dev Compute the rounding remainder retained after the initial accumulator increase
    _buffered0 = _INITIAL_PENDING_0 - _ceilDiv(_feeAcc0 * _weightPerm, FEE_ACCUMULATOR_PRECISION);
    _buffered1 = _INITIAL_PENDING_1 - _ceilDiv(_feeAcc1 * _weightPerm, FEE_ACCUMULATOR_PRECISION);

    vm.warp(_advanceTs);
    // @dev Increase the gauge fees by `_pending0/1` so the advance credits them
    _mockGaugePendingFees(_INITIAL_PENDING_0 + _pending0, _INITIAL_PENDING_1 + _pending1);

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 =
        _ceilDiv(((_pending0 + _buffered0) * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 =
        _ceilDiv(((_pending1 + _buffered1) * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);

      // it should emit the NotifyFeesAmount event
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
    }

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(users.alice, _priorIndex + _weeksElapsed + 1);

    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should credit the pending fees to the accumulator
    // @dev Accumulators increase by (pendingFees + bufferedFees) * FEE_ACCUMULATOR_PRECISION / supply
    _assertFeeAccumulator(
      _feeAcc0 + (_pending0 + _buffered0) * FEE_ACCUMULATOR_PRECISION / _supply,
      _feeAcc1 + (_pending1 + _buffered1) * FEE_ACCUMULATOR_PRECISION / _supply,
      _feeAcc0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + (_pending0 + _buffered0)
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + (_pending1 + _buffered1)
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should advance globalCheckpointIndex by the number of new global points
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    for (_i = 1; _i < _weeksElapsed + 1; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias, _intermediateSlope) = _contribution(_weight, _stakeEndB, _intermediateTs);
      // it should record a new global point for each elapsed week and the current timestamp
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _intermediateSlope,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the pre-credit accumulator at each intermediate checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i,
        _feeAcc0,
        _feeAcc1,
        _feeAcc0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
        _feeAcc1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
      );
      // it should snapshot the supply accumulators at the new global checkpoint index
      // @dev advanced-vs-prior: each elapsed week is a live interval (dt = 1 week, permanent supply > 0), so the
      //      supply accumulator strictly advances on `sharePerVote`; `weightedSharePerVote` is non-decreasing
      (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i - 1);
      (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_share, _prevShare);
      assertGe(_weighted, _prevWeighted);
    }
    (_finalBias, _finalSlope) = _contribution(_weight, _stakeEndB, _advanceTs);
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _finalSlope,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });

    // it should snapshot the credited accumulator at the latest global checkpoint index
    _assertFeeSnapshot(
      _newIndex,
      _feeAcc0 + (_pending0 + _buffered0) * FEE_ACCUMULATOR_PRECISION / _supply,
      _feeAcc1 + (_pending1 + _buffered1) * FEE_ACCUMULATOR_PRECISION / _supply,
      _feeAcc0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + (_pending0 + _buffered0)
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + (_pending1 + _buffered1)
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the final write covers the elapsed interval into `_advanceTs` (dt > 0, permanent
    //      supply > 0), so `sharePerVote` strictly advances; `weightedSharePerVote` is non-decreasing
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex - 1);
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_share, _prevShare);
    assertGe(_weighted, _prevWeighted);
    // it should not modify any user reward state
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightPerm,
      _expectedTs: _initialTs - 1,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_B), 1);
    (_initialBiasB, _slopeB) = _contribution(_weight, _stakeEndB, _initialTs);
    _assertUserPoint({
      _expectedBias: _initialBiasB,
      _expectedSlope: _slopeB,
      _expectedPermanent: 0,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_B, 1)
    });
    // it should not modify the permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightPerm);
    // @dev slopeChanges at TOKEN_ID_B's stake end stay at the value set during its checkpoint
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_B), _stakeEndB);
    // @dev balanceOfNFTAt / supplyAt reflect the mixed state at `_advanceTs`
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _advanceTs), _weightPerm);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _advanceTs), uint256(uint128(_finalBias)));
    assertEq(votingRewardsManager.supplyAt(_advanceTs), uint256(_weightPerm) + uint256(uint128(_finalBias)));
  }

  function testFuzz_WhenTheGaugeHasNoPendingFees(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _advanceTsFuzz,
    uint48 _stakeEndBFuzz,
    uint120 _weightFuzz,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
    whenTheAdvanceLandsWithinAnEpoch
  {
    _assumeFuzzable(_caller);
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 1, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev Constrain _advanceTs so exactly _weeksElapsed week boundaries fall between _initialTs and _advanceTs
    _advanceTs = uint48(
      bound(
        _advanceTsFuzz,
        ProtocolTimeLibrary.epochStart(_initialTs + uint256(_weeksElapsed) * 1 weeks) + 1,
        ProtocolTimeLibrary.epochNext(_initialTs + uint256(_weeksElapsed) * 1 weeks) - 1
      )
    );
    // @dev Bound `_stakeEndB` so TOKEN_ID_B's lock is week-aligned
    _stakeEndB =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndBFuzz, _initialTs + 1 weeks, _advanceTs + MAX_TIME)));
    // @dev TOKEN_ID_A locks `_weight / 2` permanently; TOKEN_ID_B locks `_weight` non-permanently
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));
    _weightPerm = _weight / 2;

    // @dev Initialize the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a permanent stake for TOKEN_ID_A and a non-permanent stake for TOKEN_ID_B at `_initialTs`
    vm.warp(_initialTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    (_initialBiasB, _slopeB) = _contribution(_weight, _stakeEndB, _initialTs);

    vm.warp(_advanceTs);

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(_caller, _priorIndex + _weeksElapsed + 1);

    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    // it should not credit any fees to the accumulator
    _assertFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // it should advance globalCheckpointIndex by the number of new global points
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    for (_i = 1; _i < _weeksElapsed + 1; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias, _intermediateSlope) = _contribution(_weight, _stakeEndB, _intermediateTs);
      // it should record a new global point for each elapsed week and the current timestamp
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _intermediateSlope,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the unchanged accumulator at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
    }
    (_finalBias, _finalSlope) = _contribution(_weight, _stakeEndB, _advanceTs);
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _finalSlope,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(
      _newIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the final write covers the elapsed interval into `_advanceTs` (dt > 0, permanent
    //      supply > 0), so `sharePerVote` strictly advances over the prior index; `weightedSharePerVote` rises
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex - 1);
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_share, _prevShare);
    assertGe(_weighted, _prevWeighted);
    // it should not modify any user reward state
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightPerm,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_B), 1);
    _assertUserPoint({
      _expectedBias: _initialBiasB,
      _expectedSlope: _slopeB,
      _expectedPermanent: 0,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_B, 1)
    });
    // it should not modify the permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightPerm);
    // @dev slopeChanges at TOKEN_ID_B's stake end stay at the value set during its checkpoint
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_B), _stakeEndB);
    // @dev balanceOfNFTAt / supplyAt reflect the mixed state at `_advanceTs`
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _advanceTs), _weightPerm);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _advanceTs), uint256(uint128(_finalBias)));
    assertEq(votingRewardsManager.supplyAt(_advanceTs), uint256(_weightPerm) + uint256(uint128(_finalBias)));
  }

  function testFuzz_WhenTheAdvanceLandsOnAnEpochBoundary(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _stakeEndBFuzz,
    uint120 _weightFuzz,
    uint16 _weeksElapsedFuzz
  ) external whenThereIsAtLeastOnePriorGlobalCheckpoint whenTheLatestGlobalPointWasRecordedInAPriorEpoch {
    _assumeFuzzable(_caller);
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 1, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev `_advanceTs` lands exactly on the epoch boundary `_weeksElapsed` weeks after `epochStart(_initialTs)`
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + uint256(_weeksElapsed) * 1 weeks);
    // @dev Bound `_stakeEndB` so TOKEN_ID_B's lock is week-aligned
    _stakeEndB =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndBFuzz, _initialTs + 1 weeks, _advanceTs + MAX_TIME)));
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));
    _weightPerm = _weight / 2;

    // @dev Record a permanent stake for TOKEN_ID_A one second early so the next checkpoint credits fees
    vm.warp(_initialTs - 1);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});

    vm.warp(_initialTs);

    // @dev Simulate gauge fees to advance the accumulator
    _mockGaugePendingFees(_INITIAL_PENDING_0, _INITIAL_PENDING_1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev TOKEN_ID_A's checkpoint one second before `_initialTs` seeds a non-zero supply interval, so the
    //      accumulator at `_priorIndex` is already positive
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    assertGt(_prevShare, 0);
    assertGt(_prevWeighted, 0);

    (_initialBiasB, _slopeB) = _contribution(_weight, _stakeEndB, _initialTs);
    // @dev Accumulators increase by pendingFees * FEE_ACCUMULATOR_PRECISION / supply, with supply being `_weightPerm` at credit time
    _feeAcc0 = _INITIAL_PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    _feeAcc1 = _INITIAL_PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;

    vm.warp(_advanceTs);

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(_caller, _priorIndex + _weeksElapsed);

    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed);
    // @dev Intermediate writes cover weeks 1.._weeksElapsed - 1; the final write is the boundary itself
    for (_i = 1; _i < _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias, _intermediateSlope) = _contribution(_weight, _stakeEndB, _intermediateTs);
      // it should record a new global point for each elapsed week
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _intermediateSlope,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i,
        _feeAcc0,
        _feeAcc1,
        _feeAcc0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
        _feeAcc1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
      );
      // it should snapshot the supply accumulators at the new global checkpoint index
      // @dev advanced-vs-prior: each elapsed week is a live interval (dt = 1 week, permanent supply > 0), so the
      //      supply accumulator strictly advances on `sharePerVote`; `weightedSharePerVote` is non-decreasing
      (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i - 1);
      (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_share, _prevShare);
      assertGe(_weighted, _prevWeighted);
    }
    (_finalBias, _finalSlope) = _contribution(_weight, _stakeEndB, _advanceTs);
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _finalSlope,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(
      _newIndex,
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the boundary write covers the elapsed interval into `_advanceTs` (dt = 1 week,
    //      permanent supply > 0), so `sharePerVote` strictly advances; `weightedSharePerVote` is non-decreasing
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex - 1);
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_share, _prevShare);
    assertGe(_weighted, _prevWeighted);
    // it should not modify any user reward state
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightPerm,
      _expectedTs: _initialTs - 1,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_B), 1);
    _assertUserPoint({
      _expectedBias: _initialBiasB,
      _expectedSlope: _slopeB,
      _expectedPermanent: 0,
      _expectedTs: _initialTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_B, 1)
    });
    // it should not modify the permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightPerm);
    // @dev slopeChanges at TOKEN_ID_B's stake end stay at the value set during its checkpoint
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_B), _stakeEndB);
    // @dev balanceOfNFTAt / supplyAt reflect the mixed state at `_advanceTs`
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _advanceTs), _weightPerm);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _advanceTs), uint256(uint128(_finalBias)));
    assertEq(votingRewardsManager.supplyAt(_advanceTs), uint256(_weightPerm) + uint256(uint128(_finalBias)));
  }

  function testFuzz_WhenTheElapsedIntervalsHaveZeroSupply(
    address _caller,
    uint48 _initialTsFuzz,
    uint48 _advanceTsFuzz,
    uint120 _weightFuzz,
    uint16 _weeksElapsedFuzz
  ) external whenThereIsAtLeastOnePriorGlobalCheckpoint whenTheLatestGlobalPointWasRecordedInAPriorEpoch {
    _assumeFuzzable(_caller);
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 1, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for the reset)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    // @dev Reset one second after the stake, so reward voting supply is positive only across `[_initialTs, _resetTs)`
    uint48 _resetTs = _initialTs + 1;
    // @dev Constrain `_advanceTs` so exactly `_weeksElapsed` week boundaries fall between `_resetTs` and `_advanceTs`
    _advanceTs = uint48(
      bound(
        _advanceTsFuzz,
        ProtocolTimeLibrary.epochStart(_resetTs + uint256(_weeksElapsed) * 1 weeks) + 1,
        ProtocolTimeLibrary.epochNext(_resetTs + uint256(_weeksElapsed) * 1 weeks) - 1
      )
    );
    // @dev Permanent stakes carry no slope, so any non-zero weight yields a positive pre-reset supply
    _weight = uint120(bound(_weightFuzz, 1, type(uint120).max));

    // @dev Record a permanent stake then immediately clear it, so the supply is zero from `_resetTs` onward
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_resetTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    vm.warp(_advanceTs);
    vm.prank(_caller);
    votingRewardsManager.advanceGlobalPoints();

    // it should accumulate zero supply seconds across the elapsed intervals
    assertEq(
      votingRewardsManager.globalRewardPointHistory(votingRewardsManager.globalCheckpointIndex()).zeroSupplySeconds,
      _advanceTs - _resetTs
    );
    assertEq(votingRewardsManager.globalRewardPointHistory(_priorIndex).zeroSupplySeconds, 0);
  }
}
