// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_checkpoint` logic for permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a non-zero
 *      allocated weight and a permanent stake (`stakeEnd == 0`).
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitFuzzVotingRewardsManagerCheckpointPermanent is UnitFuzzVotingRewardsManager {
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
  uint48 internal _checkpointTs;
  uint128 internal _weightBefore;
  uint128 internal _weightAfter;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint256 internal _prevWeekShare;
  uint256 internal _prevWeekWeighted;
  uint256 internal _weekShare;
  uint256 internal _weekWeighted;
  uint256 internal _lastWeekShare;
  uint256 internal _lastWeekWeighted;
  uint256 internal _finalShare;
  uint256 internal _finalWeighted;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function testFuzz_WhenThereIsNoPriorCheckpoint(uint48 _ts, uint128 _weight) external {
    _ts = uint48(bound(_ts, 1, type(uint48).max));
    vm.warp(_ts);

    _weight = uint128(bound(_weight, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weight,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should increase the permanent lock balance by the weight
    assertEq(votingRewardsManager.permanentStakeBalance(), _weight);
    // it should record a new global point
    // it should increment the global checkpoint count
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weight,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(1)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(1, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev genesis-zero: first checkpoint has no prior interval, so the supply accumulator snapshots at (0, 0)
    (uint256 _share, uint256 _weighted) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_share, 0);
    assertEq(_weighted, 0);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weight);
    assertEq(votingRewardsManager.totalSupply(), _weight);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function testFuzz_WhenTheStakeWasNon_permanent(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEnd,
    uint120 _weightBeforeFuzz,
    uint128 _weightAfterFuzz
  ) external whenThereIsAPriorCheckpoint {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_checkpointTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    _stakeEnd =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEnd, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));

    _weightBefore = uint120(bound(_weightBeforeFuzz, MAX_TIME, type(uint120).max));
    _weightAfter = uint128(bound(_weightAfterFuzz, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the reset's snapshot at the new index is observably distinct
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // it should reset the previous checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);
    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightAfter,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should increase the permanent lock balance by the weight
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightAfter);
    // @dev Reset cancels the previously scheduled slope change at the prior stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), 0);
    // @dev Reset deletes the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightAfter,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev advanced-vs-prior: a live sub-interval elapsed (dt > 0 over a non-zero non-permanent supply within the
    //      week), so the supply accumulator strictly advances in share and is non-decreasing in the weighted term
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (uint256 _newShare, uint256 _newWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_newShare, _priorShare);
    assertGe(_newWeighted, _priorWeighted);
    // @dev balanceOfNFTAt / totalSupply reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  modifier whenTheStakeWasAlreadyPermanent() {
    _;
  }

  function testFuzz_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp(
    uint48 _ts,
    uint128 _weightBeforeFuzz,
    uint128 _weightAfterFuzz
  ) external whenThereIsAPriorCheckpoint whenTheStakeWasAlreadyPermanent {
    _ts = uint48(bound(_ts, 1, type(uint48).max));
    vm.warp(_ts);

    _weightBefore = uint128(bound(_weightBeforeFuzz, 1, type(uint128).max));
    _weightAfter = uint128(bound(_weightAfterFuzz, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply accumulator before the same-timestamp overwrite to assert it later
    (uint256 _shareBefore, uint256 _weightedBefore) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: 0, _data: ''});

    // it should overwrite the user point
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's permanent amount
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightAfter,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should update the permanent lock balance by the weight delta
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightAfter);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightAfter,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: the same-timestamp overwrite must not re-snapshot the supply accumulator
    (uint256 _shareAfter, uint256 _weightedAfter) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_shareAfter, _shareBefore);
    assertEq(_weightedAfter, _weightedBefore);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp(
    uint48 _ts,
    uint128 _weightABefore,
    uint128 _weightAAfter,
    uint128 _weightB
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _ts = uint48(bound(_ts, block.timestamp + 1, block.timestamp + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    uint256 _maxPermanentBalance = type(uint128).max;
    _weightABefore = uint128(bound(_weightABefore, 1, _maxPermanentBalance - 1));
    _weightAAfter = uint128(bound(_weightAAfter, 1, _maxPermanentBalance - 1));
    uint256 _maxWeightA = _weightABefore > _weightAAfter ? _weightABefore : _weightAAfter;
    _weightB = uint128(bound(_weightB, 1, _maxPermanentBalance - _maxWeightA));

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Seed the accumulators so the next checkpoint caches them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators to simulate fee accrual
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply accumulator before the same-timestamp overwrite to assert it later
    (uint256 _shareBefore, uint256 _weightedBefore) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAAfter, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightAAfter,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should update the permanent lock balance by the weight delta
    assertEq(votingRewardsManager.permanentStakeBalance(), uint256(_weightB) + uint256(_weightAAfter));
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: uint256(_weightB) + uint256(_weightAAfter),
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value (overwrite must not re-snapshot)
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: the same-timestamp overwrite must not re-snapshot the supply accumulator
    (uint256 _shareAfter, uint256 _weightedAfter) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_shareAfter, _shareBefore);
    assertEq(_weightedAfter, _weightedBefore);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAAfter);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, block.timestamp), _weightB);
    assertEq(votingRewardsManager.totalSupply(), uint256(_weightAAfter) + uint256(_weightB));
  }

  modifier whenThePreviousGlobalPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint128 _weightBeforeFuzz,
    uint128 _weightAfterFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room left for `_checkpointTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));

    _weightBefore = uint128(bound(_weightBeforeFuzz, 1, type(uint128).max));
    _weightAfter = uint128(bound(_weightAfterFuzz, 1, type(uint128).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Seed the accumulators so the second checkpoint records them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightAfter,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should update the permanent lock balance by the weight delta
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightAfter);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightAfter,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev advanced-vs-prior: a live sub-interval elapsed (dt > 0 over the non-zero permanent supply within the week),
    //      so the supply accumulator strictly advances in share and is non-decreasing in the weighted term
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (uint256 _newShare, uint256 _newWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_newShare, _priorShare);
    assertGe(_newWeighted, _priorWeighted);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInAPriorWeek(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint128 _weightBeforeFuzz,
    uint128 _weightAfterFuzz,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = uint16(bound(_weeksElapsedFuzz, 2, MAX_CHECKPOINT_ITERATIONS - 2));
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - _weeksElapsed) * 1 weeks - 1));
    // @dev Constrain _checkpointTs so exactly _weeksElapsed week boundaries fall between _initialTs and _checkpointTs
    _checkpointTs = uint48(
      bound(
        _checkpointTsFuzz,
        ProtocolTimeLibrary.epochStart(_initialTs + uint256(_weeksElapsed) * 1 weeks) + 1,
        ProtocolTimeLibrary.epochNext(_initialTs + uint256(_weeksElapsed) * 1 weeks) - 1
      )
    );
    _weightBefore = uint128(bound(_weightBeforeFuzz, 1, type(uint128).max));
    _weightAfter = uint128(bound(_weightAfterFuzz, 1, type(uint128).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the second checkpoint records the new values at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: 0, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's permanent amount
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightAfter,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should update the permanent lock balance by the weight delta
    assertEq(votingRewardsManager.permanentStakeBalance(), _weightAfter);
    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: 0,
        _expectedSlope: 0,
        _expectedPermanentLockBalance: _weightBefore,
        _expectedTs: ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // @dev advanced-vs-prior: each intermediate index fills a full elapsed week over the non-zero permanent supply,
      //      so the supply accumulator strictly advances in share and is non-decreasing in the weighted term
      (_prevWeekShare, _prevWeekWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i - 1);
      (_weekShare, _weekWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_weekShare, _prevWeekShare);
      assertGe(_weekWeighted, _prevWeekWeighted);
    }
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightAfter,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev advanced-vs-prior: the final index covers a live partial interval (dt >= 1) over the non-zero permanent
    //      supply, so the supply accumulator strictly advances in share and is non-decreasing in the weighted term
    (_lastWeekShare, _lastWeekWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex - 1);
    (_finalShare, _finalWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_finalShare, _lastWeekShare);
    assertGe(_finalWeighted, _lastWeekWeighted);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }
}
