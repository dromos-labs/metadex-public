// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_checkpoint` logic for non-permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a non-zero
 *      allocated weight and a non-permanent stake (`stakeEnd != 0`).
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitFuzzVotingRewardsManagerCheckpointNonPermanent is UnitFuzzVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  /// @dev Cached fuzz inputs to avoid stack too deep
  int128 internal _slopeA;
  int128 internal _slopeB;
  int128 internal _biasB;
  int128 internal _expectedBias;
  int128 internal _expectedSlope;

  /// @dev Running supply accumulator carried across the elapsed-week loop to avoid stack too deep
  uint256 internal _prevShare;
  uint256 internal _prevWeighted;

  /// @dev Variables from the multi-week fuzz test, kept in storage to avoid stack-too-deep
  uint16 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _checkpointTs;
  uint48 internal _stakeEndA;
  uint120 internal _weightABefore;
  uint120 internal _weightAAfter;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  int128 internal _slopeBefore;
  uint256 internal _i;
  uint48 internal _intermediateTs;
  int128 internal _intermediateBias;
  uint256 internal _intermediateShare;
  uint256 internal _intermediateWeighted;
  uint256 internal _sharePerVote;
  uint256 internal _weightedSharePerVote;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function testFuzz_WhenThereIsNoPriorCheckpoint(uint48 _ts, uint48 _stakeEnd, uint120 _weight) external {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    vm.warp(_ts);

    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEnd, _ts + 1 weeks, _ts + MAX_TIME)));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    (_expectedBias, _expectedSlope) = _contribution(_weight, _stakeEnd, uint48(block.timestamp));

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should decrease the slope changes at the stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_expectedSlope);
    // it should set the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(1)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(1, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev genesis-zero: no prior point, the loop seeds lastTs = block.timestamp so every dt = 0
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_expectedBias)));
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function testFuzz_WhenTheStakeWasPermanent(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEnd,
    uint128 _weightBefore,
    uint120 _weightAfter
  ) external whenThereIsAPriorCheckpoint {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_checkpointTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    _stakeEnd =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEnd, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));

    _weightBefore = uint128(bound(_weightBefore, 1, type(uint128).max));
    _weightAfter = uint120(bound(_weightAfter, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a permanent stake checkpoint
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the reset's snapshot at the new index is observably distinct
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    (_expectedBias, _expectedSlope) = _contribution(_weightAfter, _stakeEnd, _checkpointTs);

    // it should reset the previous checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);
    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: _stakeEnd, _data: ''});

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should decrease the slope changes at the stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_expectedSlope);
    // it should set the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // @dev Reset clears the prior permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the new index spans [_initialTs, _checkpointTs] (dt > 0) over a non-zero
    //      permanent supply, so sharePerVote strictly advances past the prior index's (0, 0) snapshot
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_sharePerVote, _priorShare);
    assertGe(_weightedSharePerVote, _priorWeighted);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_expectedBias)));
  }

  modifier whenTheStakeWasAlreadyNonPermanent() {
    _;
  }

  modifier whenTheStakeEndIsUnchanged() {
    _;
  }

  function testFuzz_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp(
    uint48 _ts,
    uint48 _stakeEnd,
    uint120 _weightBefore,
    uint120 _weightAfter
  ) external whenThereIsAPriorCheckpoint whenTheStakeWasAlreadyNonPermanent whenTheStakeEndIsUnchanged {
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEnd, MAX_TIME + 1 weeks, type(uint48).max)));
    _ts = uint48(bound(_ts, _stakeEnd - MAX_TIME, _stakeEnd - 1));
    vm.warp(_ts);

    _weightBefore = uint120(bound(_weightBefore, MAX_TIME, type(uint120).max));
    _weightAfter = uint120(bound(_weightAfter, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEnd, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply accumulator snapshot before the same-timestamp overwrite
    (uint256 _sharePerVoteBefore, uint256 _weightedSharePerVoteBefore) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: _stakeEnd, _data: ''});

    (_expectedBias, _expectedSlope) = _contribution(_weightAfter, _stakeEnd, uint48(block.timestamp));

    // it should overwrite the user point
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_expectedSlope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: same-timestamp overwrite must not re-snapshot the supply accumulator
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, _sharePerVoteBefore);
    assertEq(_weightedSharePerVote, _weightedSharePerVoteBefore);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_expectedBias)));
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEndAFuzz,
    uint48 _stakeEndB,
    uint120 _weightABeforeFuzz,
    uint120 _weightAAfterFuzz,
    uint120 _weightB
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, MAX_CHECKPOINT_ITERATIONS * 1 weeks));

    _stakeEndA =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndAFuzz, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));
    _stakeEndB =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndB, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));
    vm.assume(_stakeEndA != _stakeEndB);

    _weightABefore = uint120(bound(_weightABeforeFuzz, MAX_TIME, type(uint120).max));
    _weightAAfter = uint120(bound(_weightAAfterFuzz, MAX_TIME, type(uint120).max));
    _weightB = uint120(bound(_weightB, MAX_TIME, type(uint120).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: _stakeEndA, _data: ''
    });

    vm.warp(_checkpointTs);

    // @dev Seed the accumulators so the next checkpoint caches them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    (_biasB, _slopeB) = _contribution(_weightB, _stakeEndB, _checkpointTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators to simulate fee accrual
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev overwrite-unchanged: capture the supply accumulator snapshot before the same-timestamp overwrite
    (uint256 _sharePerVoteBefore, uint256 _weightedSharePerVoteBefore) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    (_expectedBias, _slopeA) = _contribution(_weightAAfter, _stakeEndA, _checkpointTs);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAAfter);

    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightAAfter, _stakeEnd: _stakeEndA, _data: ''
    });

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _slopeA,
      _expectedPermanent: 0,
      _expectedTs: _checkpointTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slopeA);
    // @dev TOKEN_B's slopeChanges entry stays at its own delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);
    // @dev stakeExpiry reflects each token's stake end
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndA);
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_B), _stakeEndB);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: _biasB + _expectedBias,
      _expectedSlope: _slopeB + _slopeA,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // @dev overwrite-unchanged: same-timestamp overwrite must not re-snapshot the supply accumulator
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, _sharePerVoteBefore);
    assertEq(_weightedSharePerVote, _weightedSharePerVoteBefore);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _checkpointTs), uint256(uint128(_biasB)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_biasB)) + uint256(uint128(_expectedBias)));
  }

  modifier whenThePreviousGlobalPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEndAFuzz,
    uint120 _weightABeforeFuzz,
    uint120 _weightAAfterFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room left for `_checkpointTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));

    _stakeEndA =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndAFuzz, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));
    _weightABefore = uint120(bound(_weightABeforeFuzz, MAX_TIME, type(uint120).max));
    _weightAAfter = uint120(bound(_weightAAfterFuzz, MAX_TIME, type(uint120).max));

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: _stakeEndA, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Seed the accumulators so the second checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    (_expectedBias, _expectedSlope) = _contribution(_weightAAfter, _stakeEndA, _checkpointTs);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAAfter);

    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightAAfter, _stakeEnd: _stakeEndA, _data: ''
    });

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: _checkpointTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_expectedSlope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndA);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the new index spans [_initialTs, _checkpointTs] (dt > 0) over a still-live,
    //      non-zero supply (stakeEndA >= _checkpointTs + 1 week), so sharePerVote strictly advances
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_sharePerVote, _priorShare);
    assertGe(_weightedSharePerVote, _priorWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_expectedBias)));
  }

  function testFuzz_WhenThePreviousGlobalPointWasRecordedInAPriorWeek(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEndAFuzz,
    uint120 _weightABeforeFuzz,
    uint120 _weightAAfterFuzz,
    uint16 _weeksElapsedFuzz
  )
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
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

    _stakeEndA =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndAFuzz, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));

    _weightABefore = uint120(bound(_weightABeforeFuzz, MAX_TIME, type(uint120).max));
    _weightAAfter = uint120(bound(_weightAAfterFuzz, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: _stakeEndA, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the second checkpoint records the new values at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    (_expectedBias, _expectedSlope) = _contribution(_weightAAfter, _stakeEndA, _checkpointTs);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAAfter);

    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightAAfter, _stakeEnd: _stakeEndA, _data: ''
    });

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: _checkpointTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_expectedSlope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndA);
    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);

    (, _slopeBefore) = _contribution(_weightABefore, _stakeEndA, _initialTs);
    // @dev advanced-vs-prior: seed the running comparison from `_priorIndex` (the genesis snapshot, (0, 0))
    (_prevShare, _prevWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      (_intermediateBias,) = _contribution(_weightABefore, _stakeEndA, _intermediateTs);
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: _intermediateBias,
        _expectedSlope: _slopeBefore,
        _expectedPermanentLockBalance: 0,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // it should snapshot the supply accumulators at each new global checkpoint index
      // @dev advanced-vs-prior: each whole-week sub-interval is dt > 0 over a still-live, non-zero supply
      (_intermediateShare, _intermediateWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertGt(_intermediateShare, _prevShare);
      assertGe(_intermediateWeighted, _prevWeighted);
      _prevShare = _intermediateShare;
      _prevWeighted = _intermediateWeighted;
    }
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the final partial sub-interval [last boundary, _checkpointTs] still has live supply
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_sharePerVote, _prevShare);
    assertGe(_weightedSharePerVote, _prevWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_expectedBias)));
  }

  modifier whenTheStakeEndHasChanged() {
    _;
  }

  function testFuzz_WhenThePreviousStakeHasNotYetExpired(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEndBefore,
    uint48 _stakeEndAfter,
    uint120 _weightBefore,
    uint120 _weightAfter
  ) external whenThereIsAPriorCheckpoint whenTheStakeWasAlreadyNonPermanent whenTheStakeEndHasChanged {
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_initialTs` sits at the last second of its week (no room for `_checkpointTs`)
    if (_initialTs + 1 >= ProtocolTimeLibrary.epochNext(_initialTs)) {
      _initialTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs));
    }
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _initialTs + 1, ProtocolTimeLibrary.epochNext(_initialTs) - 1));
    // @dev Non-permanent stakes can only be extended, so `_stakeEndAfter` is strictly greater than `_stakeEndBefore`
    _stakeEndBefore = uint48(
      ProtocolTimeLibrary.epochStart(
        bound(_stakeEndBefore, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME - 1 weeks)
      )
    );
    _stakeEndAfter = uint48(
      ProtocolTimeLibrary.epochStart(bound(_stakeEndAfter, _stakeEndBefore + 1 weeks, _checkpointTs + MAX_TIME))
    );

    _weightBefore = uint120(bound(_weightBefore, MAX_TIME, type(uint120).max));
    _weightAfter = uint120(bound(_weightAfter, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEndBefore, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the reset's snapshot at the new index is observably distinct
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    (_expectedBias, _expectedSlope) = _contribution(_weightAfter, _stakeEndAfter, _checkpointTs);

    // it should reset the previous checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);
    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: _stakeEndAfter, _data: ''
    });

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // @dev Reset cancels the previously scheduled slope change at the prior stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEndBefore), 0);
    // it should decrease the slope changes at the new stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEndAfter), -_expectedSlope);
    // it should overwrite the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndAfter);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior: the new index spans [_initialTs, _checkpointTs] (dt > 0) over the prior stake,
    //      still live (stakeEndBefore >= _checkpointTs + 1 week), so sharePerVote strictly advances
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGt(_sharePerVote, _priorShare);
    assertGe(_weightedSharePerVote, _priorWeighted);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_expectedBias)));
  }

  function testFuzz_WhenThePreviousStakeHasAlreadyExpired(
    uint48 _initialTsFuzz,
    uint48 _checkpointTsFuzz,
    uint48 _stakeEndAfter,
    uint120 _weightBefore,
    uint120 _weightAfter
  ) external whenThereIsAPriorCheckpoint whenTheStakeWasAlreadyNonPermanent whenTheStakeEndHasChanged {
    // @dev `_stakeEndBefore` sits between `_initialTs` and `_checkpointTs` so the lock has weight at
    //      `_initialTs` and is expired by `_checkpointTs`
    _initialTs = uint48(bound(_initialTsFuzz, 1 weeks, (MAX_CHECKPOINT_ITERATIONS - 2) * 1 weeks));
    uint48 _stakeEndBefore = uint48(ProtocolTimeLibrary.epochNext(_initialTs));
    _checkpointTs = uint48(bound(_checkpointTsFuzz, _stakeEndBefore + 1, _stakeEndBefore + 1 weeks - 1));
    _stakeEndAfter =
      uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEndAfter, _checkpointTs + 1 weeks, _checkpointTs + MAX_TIME)));

    _weightBefore = uint120(bound(_weightBefore, MAX_TIME, type(uint120).max));
    _weightAfter = uint120(bound(_weightAfter, MAX_TIME, type(uint120).max));

    // @dev Seed the accumulators so the intermediate global point caches them at the boundary index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint that will be expired by `_checkpointTs`
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEndBefore, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    (, _slopeA) = _contribution(_weightBefore, _stakeEndBefore, _initialTs);

    // @dev Grow the accumulators so the new global point's snapshot is observably distinct from the intermediate
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    (_expectedBias, _expectedSlope) = _contribution(_weightAfter, _stakeEndAfter, _checkpointTs);

    // it should reset the previous checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);
    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: _stakeEndAfter, _data: ''
    });

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 2);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // @dev Reset leaves the slope changes at the prior expired stake end untouched (already applied at the boundary)
    assertEq(votingRewardsManager.slopeChanges(_stakeEndBefore), -_slopeA);
    // it should decrease the slope changes at the new stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEndAfter), -_expectedSlope);
    // it should overwrite the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndAfter);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    // @dev Reset's loop writes an intermediate point at the boundary, so `globalCheckpointIndex` advances by 2
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 2);
    _assertGlobalPoint({
      _expectedBias: _expectedBias,
      _expectedSlope: _expectedSlope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev advanced-vs-prior (non-strict): the final span [_stakeEndBefore, _checkpointTs] sees the prior
    //      stake already expired (supply 0 throughout), so the last sub-interval adds nothing; keep >=
    (uint256 _priorShare, uint256 _priorWeighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex);
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertGe(_sharePerVote, _priorShare);
    assertGe(_weightedSharePerVote, _priorWeighted);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_expectedBias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_expectedBias)));
  }
}
