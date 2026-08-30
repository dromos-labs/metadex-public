// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_checkpoint` logic for permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a non-zero
 *      allocated weight and a permanent stake (`stakeEnd == 0`).
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitConcreteVotingRewardsManagerCheckpointPermanent is UnitVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  /// @dev Variables from the multi-week test, kept in storage to avoid stack-too-deep
  uint256 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _checkpointTs;
  uint128 internal _weightBefore;
  uint128 internal _weightAfter;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256[3] internal _expectedShare;
  uint256[3] internal _expectedWeighted;
  uint256 internal _i;
  uint256 internal _share;
  uint256 internal _weighted;
  uint256 internal _finalShare;
  uint256 internal _finalWeighted;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function test_WhenThereIsNoPriorCheckpoint() external {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev No interval precedes the first checkpoint (genesis supply is zero), so both accumulators are zero
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weight);
    assertEq(votingRewardsManager.totalSupply(), _weight);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function test_WhenTheStakeWasNon_permanent() external whenThereIsAPriorCheckpoint {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Same week as _initialTs so no boundary is crossed and a single global point is recorded
    _checkpointTs = uint48(_initialTs + 1 days);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    _weightBefore = uint128(1000 * TOKEN_1);
    _weightAfter = uint128(2000 * TOKEN_1);

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev One sub-interval [_initialTs, _checkpointTs) (same week) of dt = 86400s. The prior stake was a
    //      decaying lock with permanentStakeBalance == 0, so supply is sampled at refTs = _checkpointTs - 1:
    //        slope         = 1000 * TOKEN_1 / MAX_TIME = 1e21 / 126144000 = 7927447995941
    //        supplyRef     = slope * (_stakeEnd - refTs) = 7927447995941 * (32054400 - 777599)
    //                      = 247945213406895464741
    //      With accumulator origin at the deploy timestamp (1) and scale 1e42:
    //        sharePerVote         = 86400 * 1e42 / 247945213406895464741
    //        weightedSharePerVote = (refTs - 1) * 86400 * 1e42 / 247945213406895464741
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_share, 348_464_077_256_500_803_422_134_942);
    assertEq(_weighted, 270_964_969_546_500_511_739_445_287_316_694);
    // @dev balanceOfNFTAt / totalSupply reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  modifier whenTheStakeWasAlreadyPermanent() {
    _;
  }

  function test_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    _weightBefore = uint128(1000 * TOKEN_1);
    _weightAfter = uint128(2000 * TOKEN_1);

    vm.warp(_ts);

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // @dev Supply accumulator at the overwritten index is final (genesis interval, zero) and not re-snapshotted
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    uint48 _ts = uint48(_initialTs + 1 days);
    uint128 _weightABefore = uint128(1000 * TOKEN_1);
    uint128 _weightAAfter = uint128(2000 * TOKEN_1);
    uint128 _weightB = uint128(3000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Seed the accumulators so the next checkpoint caches them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators to simulate fee accrual
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // @dev Supply accumulator at the overwritten index prices the one-day interval [_initialTs, _ts) at the
    //      permanent supply _weightABefore (1000 * TOKEN_1); the overwrite must not re-snapshot it. With the
    //      accumulator origin at the deploy timestamp (1) and scale 1e42:
    //        sharePerVote         = 86400 * 1e42 / (1000 * TOKEN_1)              = 86400 * 1e21
    //        weightedSharePerVote = (_ts - 2) * 86400 * 1e42 / (1000 * TOKEN_1) = 691199 * 86400 * 1e21
    (uint256 _sharePerVote, uint256 _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 86_400 * 1e21);
    assertEq(_weightedSharePerVote, 691_199 * 86_400 * 1e21);
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

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Same week as _initialTs so no boundary is crossed and a single global point is recorded
    _checkpointTs = uint48(_initialTs + 1 days);
    _weightBefore = uint128(1000 * TOKEN_1);
    _weightAfter = uint128(2000 * TOKEN_1);

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev One sub-interval [_initialTs, _checkpointTs) (same week) of dt = 86400s at the constant permanent
    //      supply _weightBefore (1000 * TOKEN_1 = 1e21). With accumulator origin at the deploy timestamp (1)
    //      and scale 1e42 (1e42 / 1e21 = 1e21 per second):
    //        sharePerVote         = 86400 * 1e21                    = 86400 * 1e21
    //        weightedSharePerVote = (_checkpointTs - 2) * 86400 * 1e21 = 777598 * 86400 * 1e21
    (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_share, 86_400 * 1e21);
    assertEq(_weighted, 777_598 * 86_400 * 1e21);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  function test_WhenThePreviousGlobalPointWasRecordedInAPriorWeek()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = 3;
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Land mid-week so exactly _weeksElapsed boundaries fall before _checkpointTs
    _checkpointTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs + _weeksElapsed * 1 weeks) + 1 days);
    _weightBefore = uint128(1000 * TOKEN_1);
    _weightAfter = uint128(2000 * TOKEN_1);

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
    // @dev Walking week boundaries from _initialTs (604801) toward _checkpointTs (2505600) at the constant
    //      permanent supply 1000 * TOKEN_1 (1e21), each second contributes 1e21 to sharePerVote and each
    //      sub-interval contributes (intervalEnd - 2) * dt * 1e21 to weightedSharePerVote. Origin is the deploy
    //      timestamp (1), scale 1e42. The four sub-intervals are:
    //        j0: [604801,  1209600] dt = 604799 -> index _priorIndex + 1
    //        j1: [1209600, 1814400] dt = 604800 -> index _priorIndex + 2
    //        j2: [1814400, 2419200] dt = 604800 -> index _priorIndex + 3
    //        j3: [2419200, 2505600] dt = 86400  -> final index _newIndex (== block.timestamp)
    _expectedShare = [uint256(604_799 * 1e21), 1_209_599 * 1e21, 1_814_399 * 1e21];
    _expectedWeighted = [
      uint256(1_209_598 * 604_799 * 1e21),
      1_209_598 * 604_799 * 1e21 + 1_814_398 * 604_800 * 1e21,
      1_209_598 * 604_799 * 1e21 + 1_814_398 * 604_800 * 1e21 + 2_419_198 * 604_800 * 1e21
    ];
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
      // it should snapshot the supply accumulators at each new global checkpoint index
      (_share, _weighted) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_share, _expectedShare[_i - 1]);
      assertEq(_weighted, _expectedWeighted[_i - 1]);
    }
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightAfter,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // @dev Final index adds j3: cumulative share = 1900799 * 1e21; weighted adds (2505600 - 2) * 86400 * 1e21
    (_finalShare, _finalWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_finalShare, 1_900_799 * 1e21);
    assertEq(
      _finalWeighted,
      1_209_598 * 604_799 * 1e21 + 1_814_398 * 604_800 * 1e21 + 2_419_198 * 604_800 * 1e21 + 2_505_598 * 86_400 * 1e21
    );
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightAfter);
    assertEq(votingRewardsManager.totalSupply(), _weightAfter);
  }

  function testGas_checkpoint_permanent()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyPermanent
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    uint128 _weight = 1000e18;

    vm.warp(1 weeks);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight / 4, _stakeEnd: 0, _data: ''});

    // @dev Seed the accumulators so the second checkpoint records them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(block.timestamp + 1 hours);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.snapshotGasLastCall('VotingRewardsManager_checkpoint_permanent');
  }
}
