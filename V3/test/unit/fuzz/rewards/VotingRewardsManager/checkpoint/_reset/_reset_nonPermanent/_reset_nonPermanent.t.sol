// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_reset` logic for non-permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a zero allocated
 *      weight, clearing a prior non-permanent stake.
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitFuzzVotingRewardsManagerResetNonPermanent is UnitFuzzVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  /// @dev Variables from the multi-week fuzz test, kept in storage to avoid stack-too-deep
  uint16 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _resetTs;
  uint48 internal _stakeEnd;
  uint120 internal _weight;
  uint256 internal _priorIndex;
  int128 internal _slope;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint48 internal _intermediateTs;
  int128 internal _intermediateBias;
  uint256 internal _stepPriorShare;
  uint256 internal _stepPriorWeighted;
  uint256 internal _stepShare;
  uint256 internal _stepWeighted;
  uint256 internal _finalPriorShare;
  uint256 internal _finalPriorWeighted;
  uint256 internal _finalShare;
  uint256 internal _finalWeighted;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function testFuzz_WhenThereIsNoPriorCheckpoint(uint48 _ts) external {
    _ts = uint48(bound(_ts, 1, type(uint48).max));
    vm.warp(_ts);

    // @dev Seed the accumulators so they're snapshotted at the new global index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should not modify the permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should not modify the slope changes
    assertEq(votingRewardsManager.slopeChanges(0), 0);
    // it should not modify the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(1)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(1, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);
    // @dev genesis-zero: no elapsed interval over a non-zero supply, so the supply accumulator is exact (0, 0)
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  modifier whenThePreviousStakeHasNotYetExpired() {
    _;
  }

  function testFuzz_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp(
    uint48 _ts,
    uint48 _stakeEndFuzz,
    uint120 _weightFuzz
  ) external whenThereIsAPriorCheckpoint whenThePreviousStakeHasNotYetExpired {
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndFuzz, MAX_TIME + 1 weeks, type(uint48).max)));
    _ts = uint48(bound(_ts, _stakeEnd - MAX_TIME, _stakeEnd - 1));
    vm.warp(_ts);

    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Checkpoint scheduled `-_slope` as the slope change at the stake end
    (, _slope) = _contribution(_weight, _stakeEnd, uint48(block.timestamp));
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply snapshot before the same-ts overwrite to assert it is not rewritten
    (uint256 _shareBefore, uint256 _weightedBefore) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should overwrite the user point
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's zero weight
    // it should checkpoint the veNFT's zero slope
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should increase the slope changes at the previous stake end by the previous slope
    // @dev cancels the scheduled change back to zero
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), 0);
    // it should delete the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value (overwrite must not re-snapshot)
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: the supply snapshot at the overwritten index stays at its pre-overwrite value
    (uint256 _shareAfter, uint256 _weightedAfter) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_shareAfter, _shareBefore);
    assertEq(_weightedAfter, _weightedBefore);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint48 _stakeEndA,
    uint48 _stakeEndB,
    uint120 _weightA,
    uint120 _weightB
  )
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _resetTs = uint48(bound(_resetTsFuzz, _initialTs + 1, MAX_CHECKPOINT_ITERATIONS * 1 weeks));

    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndA, _resetTs + 1 weeks, _resetTs + MAX_TIME)));
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndB, _resetTs + 1 weeks, _resetTs + MAX_TIME)));
    vm.assume(_stakeEndA != _stakeEndB);

    _weightA = uint120(bound(_weightA, MAX_TIME, type(uint120).max));
    _weightB = uint120(bound(_weightB, MAX_TIME, type(uint120).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEndA, _data: ''});
    (, int128 _slopeA) = _contribution(_weightA, _stakeEndA, _initialTs);

    vm.warp(_resetTs);

    // @dev TOKEN_A's checkpoint scheduled `-_slopeA` at its stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slopeA);

    // @dev Seed the accumulators so the next checkpoint records them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    (int128 _biasB, int128 _slopeB) = _contribution(_weightB, _stakeEndB, _resetTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply snapshot before the same-ts overwrite to assert it is not rewritten
    (uint256 _shareBefore, uint256 _weightedBefore) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's zero weight
    // it should checkpoint the veNFT's zero slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should increase the slope changes at the previous stake end by the previous slope
    // @dev TOKEN_A's scheduled change uncancelled; TOKEN_B's stays
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), 0);
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);
    // it should delete the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_B), _stakeEndB);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: _biasB,
      _expectedSlope: _slopeB,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value (overwrite must not re-snapshot)
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: the supply snapshot at the overwritten index stays at its pre-overwrite value
    (uint256 _shareAfter, uint256 _weightedAfter) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_shareAfter, _shareBefore);
    assertEq(_weightedAfter, _weightedBefore);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, block.timestamp), uint256(uint128(_biasB)));
    assertEq(votingRewardsManager.totalSupply(), uint256(uint128(_biasB)));
  }

  modifier whenThePreviousGlobalPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint48 _stakeEndFuzz,
    uint120 _weightFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_resetTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _resetTs = uint48(bound(_resetTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));

    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndFuzz, _resetTs + 1 weeks, _resetTs + MAX_TIME)));
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    (, _slope) = _contribution(_weight, _stakeEnd, _initialTs);

    // @dev Checkpoint scheduled `-_slope` at the stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);

    // @dev Seed the accumulators so they're snapshotted at the new global index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_resetTs);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's zero weight
    // it should checkpoint the veNFT's zero slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should increase the slope changes at the previous stake end by the previous slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), 0);
    // it should delete the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = _priorIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(
      _newIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev advanced-vs-prior: the new index covers a live sub-interval (dt > 0, non-zero decaying supply since the
    //      stake outlives the reset), so sharePerVote strictly advances; weightedSharePerVote never regresses
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (uint256 _newShare, uint256 _newWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_newShare, _priorShare);
    assertGe(_newWeighted, _priorWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInAPriorWeek(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint48 _stakeEndFuzz,
    uint120 _weightFuzz,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 2, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev Constrain _resetTs so exactly _weeksElapsed week boundaries fall between _initialTs and _resetTs
    _resetTs = uint48(
      bound(
        _resetTsFuzz,
        ProtocolTimeLibrary.epochStart(_initialTs + uint256(_weeksElapsed) * 1 weeks) + 1,
        ProtocolTimeLibrary.epochNext(_initialTs + uint256(_weeksElapsed) * 1 weeks) - 1
      )
    );

    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndFuzz, _resetTs + 1 weeks, _resetTs + MAX_TIME)));
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    (, _slope) = _contribution(_weight, _stakeEnd, _initialTs);

    // @dev Checkpoint scheduled `-_slope` at the stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);

    // @dev Grow the accumulators so the reset records the new values at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_resetTs);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's zero weight
    // it should checkpoint the veNFT's zero slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should increase the slope changes at the previous stake end by the previous slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), 0);
    // it should delete the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);

    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias,) = _contribution(_weight, _stakeEnd, _intermediateTs);
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _slope,
        _expectedPermanentLockBalance: 0,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // @dev advanced-vs-prior: each elapsed week covers a full live sub-interval (dt = WEEK, non-zero decaying
      //      supply since the stake outlives the reset), so sharePerVote strictly advances; weighted never regresses
      (_stepPriorShare, _stepPriorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i - 1);
      (_stepShare, _stepWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_stepShare, _stepPriorShare);
      assertGe(_stepWeighted, _stepPriorWeighted);
    }
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev advanced-vs-prior: the final index covers the partial sub-interval up to the reset (dt > 0 since the reset
    //      sits strictly inside its week, non-zero supply as the stake still outlives it), so sharePerVote strictly
    //      advances over the last full-week index; weighted never regresses
    (_finalPriorShare, _finalPriorWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex - 1);
    (_finalShare, _finalWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_finalShare, _finalPriorShare);
    assertGe(_finalWeighted, _finalPriorWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function testFuzz_WhenThePreviousStakeHasAlreadyExpired(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint120 _weightFuzz
  ) external whenThereIsAPriorCheckpoint {
    // @dev `_stakeEnd` sits between `_initialTs` and `_resetTs` so the lock has weight at
    //      `_initialTs` and is expired by `_resetTs`
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - 2) * 1 weeks));
    _stakeEnd = uint48(ProtocolTimeLibrary.epochNext(_initialTs));
    _resetTs = uint48(bound(_resetTsFuzz, _stakeEnd + 1, _stakeEnd + 1 weeks - 1));
    _weight = uint120(bound(_weightFuzz, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the intermediate global point caches them at the boundary index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint that will be expired by `_resetTs`
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    (, _slope) = _contribution(_weight, _stakeEnd, _initialTs);

    // @dev Sanity-check: checkpoint scheduled `-_slope` at the stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);

    // @dev Grow the accumulators so the new global point's snapshot is observably distinct from the intermediate
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_resetTs);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's zero weight
    // it should checkpoint the veNFT's zero slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should not modify the slope changes at the previous stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);
    // it should delete the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    // @dev Reset's loop writes an intermediate point at the boundary, so `globalCheckpointIndex` advances by 2
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 2);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev advanced-vs-prior: the final index's trailing sub-interval runs past the stake expiry, so supply can be
    //      zero throughout it and the accumulator may not move; assert only non-regression to avoid flaking
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (uint256 _newShare, uint256 _newWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGe(_newShare, _priorShare);
    assertGe(_newWeighted, _priorWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }
}
