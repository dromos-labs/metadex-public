// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_reset` logic for permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a zero allocated
 *      weight, clearing a prior permanent stake.
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitFuzzVotingRewardsManagerResetPermanent is UnitFuzzVotingRewardsManager {
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
  uint128 internal _weight;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint256 internal _priorShare;
  uint256 internal _priorWeighted;
  uint256 internal _share;
  uint256 internal _weighted;
  uint256 internal _lastWeekShare;
  uint256 internal _lastWeekWeighted;
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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev genesis-zero: no prior checkpoint, so the only sub-interval has dt = 0 and accumulators stay zero
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function testFuzz_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp(uint128 _weightFuzz)
    external
    whenThereIsAPriorCheckpoint
  {
    _weight = uint128(bound(_weightFuzz, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: snapshot the supply accumulators before the same-timestamp overwrite
    (uint256 _sharePerVoteBefore, uint256 _weightedSharePerVoteBefore) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should overwrite the user point
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's zero permanent amount
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should decrease the permanent lock balance by the previous weight
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: same-timestamp overwrite must not re-snapshot the supply accumulators
    (uint256 _sharePerVoteAfter, uint256 _weightedSharePerVoteAfter) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVoteAfter, _sharePerVoteBefore);
    assertEq(_weightedSharePerVoteAfter, _weightedSharePerVoteBefore);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp(
    uint48 _ts,
    uint128 _weightA,
    uint128 _weightB
  ) external whenThereIsAPriorCheckpoint whenThePreviousUserPointWasRecordedInAPriorTimestamp {
    _ts = uint48(bound(_ts, block.timestamp + 1, block.timestamp + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    uint256 _maxPermanentBalance = type(uint128).max;
    _weightA = uint128(bound(_weightA, 1, _maxPermanentBalance - 1));
    _weightB = uint128(bound(_weightB, 1, _maxPermanentBalance - _weightA));

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Seed the accumulators so the next checkpoint records them at the new index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: snapshot the supply accumulators before the same-timestamp overwrite
    (uint256 _sharePerVoteBefore, uint256 _weightedSharePerVoteBefore) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's zero permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should decrease the permanent lock balance by the previous weight
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightB);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightB,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value (overwrite must not re-snapshot)
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: same-timestamp overwrite must not re-snapshot the supply accumulators
    (uint256 _sharePerVoteAfter, uint256 _weightedSharePerVoteAfter) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVoteAfter, _sharePerVoteBefore);
    assertEq(_weightedSharePerVoteAfter, _weightedSharePerVoteBefore);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, block.timestamp), _weightB);
    assertEq(votingRewardsManager.totalSupply(), _weightB);
  }

  modifier whenThePreviousGlobalPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint128 _weightFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_resetTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _resetTs = uint48(bound(_resetTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    _weight = uint128(bound(_weightFuzz, 1, type(uint128).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev advanced-vs-prior: capture the prior-index supply accumulators before the elapsed-interval reset
    (uint256 _priorSharePerVote, uint256 _priorWeightedSharePerVote) =
      votingRewardsManager.supplyAccumulatorAt(_priorIndex);

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
    // it should checkpoint the veNFT's zero permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should decrease the permanent lock balance by the previous weight
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: one live sub-interval (dt = _resetTs - _initialTs >= 1, supply = _weight >= 1),
    //      so sharePerVote advances strictly; weighted advances non-strictly
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_sharePerVote, _priorSharePerVote);
    assertGe(_weightedSharePerVote, _priorWeightedSharePerVote);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInAPriorWeek(
    uint48 _initialTsFuzz,
    uint48 _resetTsFuzz,
    uint128 _weightFuzz,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAPriorCheckpoint
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
    _weight = uint128(bound(_weightFuzz, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

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
    // it should checkpoint the veNFT's zero permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should decrease the permanent lock balance by the previous weight
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: 0,
        _expectedSlope: 0,
        _expectedPermanentLockBalance: _weight,
        _expectedTs: ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // it should snapshot the supply accumulators at each new global checkpoint index
      // @dev advanced-vs-prior: each elapsed week is a live sub-interval (dt = 1 week, supply = _weight >= 1),
      //      so the running sharePerVote advances strictly and weighted advances non-strictly index over index
      (_priorShare, _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i - 1);
      (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_share, _priorShare);
      assertGe(_weighted, _priorWeighted);
    }
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: final partial sub-interval (dt = _resetTs - last boundary >= 1, supply = _weight >= 1),
    //      so the running sharePerVote advances strictly past the last elapsed-week index; weighted non-strictly
    (_lastWeekShare, _lastWeekWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _weeksElapsed);
    (_finalShare, _finalWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_finalShare, _lastWeekShare);
    assertGe(_finalWeighted, _lastWeekWeighted);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }
}
