// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_checkpoint` logic for non-permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a non-zero
 *      allocated weight and a non-permanent stake (`stakeEnd != 0`).
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitConcreteVotingRewardsManagerCheckpointNonPermanent is UnitVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  /// @dev Per-sub-interval inputs and running supply-accumulator expectations for the multi-week fill test
  ///      (kept in storage to relieve stack pressure)
  uint256[4] internal _supplyRef = [
    uint256(527_397_276_128_858_839_882),
    uint256(517_808_235_032_968_606_282),
    uint256(508_219_193_937_078_372_682),
    uint256(498_630_152_841_188_139_082)
  ];
  uint256[4] internal _refTs = [uint256(1_209_599), uint256(1_814_399), uint256(2_419_199), uint256(3_023_999)];
  uint256[4] internal _dt = [uint256(604_799), uint256(604_800), uint256(604_800), uint256(604_800)];
  uint256 internal _expectedShare;
  uint256 internal _expectedWeighted;

  /// @dev Variables from the multi-week test, kept in storage to avoid stack-too-deep
  uint256 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _checkpointTs;
  uint48 internal _stakeEndA;
  uint128 internal _weightABefore;
  uint128 internal _weightAAfter;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  int128 internal _slope;
  int128 internal _bias;
  int128 internal _slopeBefore;
  int128[3] internal _intermediateBias;
  uint256 internal _i;
  uint48 internal _intermediateTs;
  uint256 internal _sharePerVote;
  uint256 internal _weightedSharePerVote;
  uint256 internal _finalShare;
  uint256 internal _finalWeighted;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function test_WhenThereIsNoPriorCheckpoint() external {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _weight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // @dev Seed the accumulators so the first checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEnd - _ts)
    _bias = 249_315_060_565_698_077_659;

    // it should record a new user point
    // it should increment the user checkpoint count
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    // it should checkpoint the current block timestamp
    _assertUserPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should decrease the slope changes at the stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);
    // it should set the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(1)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(1, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev No prior point, so the loop starts at `block.timestamp` itself: dt = 0 for the only sub-interval, so
    //      every supply term is skipped and both accumulators stay at zero.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function test_WhenTheStakeWasPermanent() external whenThereIsAPriorCheckpoint {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Checkpoint on the next epoch boundary so decay spans whole weeks and a single global point is recorded
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs + 1 days));
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    uint128 _weightBefore = uint128(1000 * TOKEN_1);
    uint128 _weightAfter = uint128(1000 * TOKEN_1);

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a permanent stake checkpoint
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the reset's snapshot at the new index is observably distinct
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEnd - _checkpointTs) = slope * 52 weeks
    _bias = 249_315_068_493_146_073_600;

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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should decrease the slope changes at the stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);
    // it should set the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // @dev Reset clears the prior permanent lock balance
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Prior point at ts=_initialTs (604801) is permanent: bias=0, permanentStakeBalance=1_000*TOKEN_1=1e21.
    //      One week-bounded sub-interval [604801, 1209600): dt=604799, supply=perm=1e21 (constant, no decay).
    //      sharePerVote         = 604799 * 1e42 / 1e21                    = 604799 * 1e21
    //      weightedSharePerVote = (1209600 - 2) * 604799 * 1e42 / 1e21
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, 604_799 * 1e21);
    assertEq(_weightedSharePerVote, uint256(1_209_598) * 604_799 * 1e21);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));
  }

  modifier whenTheStakeWasAlreadyNonPermanent() {
    _;
  }

  modifier whenTheStakeEndIsUnchanged() {
    _;
  }

  function test_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _weightBefore = uint128(2000 * TOKEN_1);
    uint128 _weightAfter = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEnd, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weightAfter);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightAfter, _stakeEnd: _stakeEnd, _data: ''});

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEnd - _ts)
    _bias = 249_315_060_565_698_077_659;

    // it should overwrite the user point
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    // it should checkpoint the veNFT's weight allocation after applying in-flight decay
    // it should checkpoint the veNFT's slope
    _assertUserPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEnd);
    // it should overwrite the global point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Same-timestamp overwrite: the supply accumulator at this index is not re-written. The first checkpoint
    //      had no prior point, so its loop started at block.timestamp (dt=0) and the accumulator was seeded at zero;
    //      it stays zero after the overwrite.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Checkpoint on the next epoch boundary so decay spans whole weeks
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs + 1 days));
    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    uint48 _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 39 weeks));
    _weightABefore = uint128(3000 * TOKEN_1);
    _weightAAfter = uint128(1000 * TOKEN_1);
    uint128 _weightB = uint128(2000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: _stakeEndA, _data: ''
    });

    vm.warp(_checkpointTs);

    // @dev Seed the accumulators so the next checkpoint caches them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators to simulate fee accrual
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    // @dev slopeA = 1_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slopeA = 7_927_447_995_941;
    // @dev slopeB = 2_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slopeB = 15_854_895_991_882;
    // @dev biasA = slopeA * (stakeEndA - _checkpointTs) = slopeA * 52 weeks
    int128 _biasA = 249_315_068_493_146_073_600;
    // @dev biasB = slopeB * (stakeEndB - _checkpointTs) = slopeB * 39 weeks
    int128 _biasB = 373_972_602_739_719_110_400;

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
      _expectedBias: _biasA,
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
      _expectedBias: _biasA + _biasB,
      _expectedSlope: _slopeA + _slopeB,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    // @dev Accumulator snapshot at the overwritten index stays at the initial value
    _assertFeeSnapshot(
      _globalIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Same-timestamp overwrite leaves the supply accumulator at `_globalIndex` untouched. It was written by the
    //      tokenB checkpoint walking from the prior point at ts=604801. The single sub-interval [604801, 1209600)
    //      has dt=604799 and samples A at refTs=1209599:
    //      supplyRef            = slopeA * (stakeEndA - refTs) = 747_945_229_261_782_208_623.
    //      sharePerVote         = 604799 * 1e42 / supplyRef
    //      weightedSharePerVote = (refTs - 1) * 604799 * 1e42 / supplyRef
    (_expectedShare, _expectedWeighted) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_expectedShare, (uint256(604_799) * 1e42) / 747_945_229_261_782_208_623);
    assertEq(_expectedWeighted, (uint256(1_209_598) * 604_799 * 1e42) / 747_945_229_261_782_208_623);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_biasA)));
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _checkpointTs), uint256(uint128(_biasB)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_biasB)) + uint256(uint128(_biasA)));
  }

  modifier whenThePreviousGlobalPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Later in the same week as _initialTs: a new global point is recorded without crossing a boundary
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs) - 1 days);
    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    _weightABefore = uint128(2000 * TOKEN_1);
    _weightAAfter = uint128(1000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightABefore, _stakeEnd: _stakeEndA, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Seed the accumulators so the second checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEndA - _checkpointTs) = slope * (52 weeks - 6 days)
    _bias = 245_205_479_452_050_259_200;

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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: _checkpointTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndA);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev New point in the same week as the prior point at ts=604801. Single sub-interval
    //      [604801, _checkpointTs(1123200)): dt=518399, refTs=1123199.
    //      supplyRef            = slope * (stakeEndA - refTs) = 490_410_974_758_996_510_282.
    //      sharePerVote         = 518399 * 1e42 / supplyRef
    //      weightedSharePerVote = (refTs - 1) * 518399 * 1e42 / supplyRef
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, (uint256(518_399) * 1e42) / 490_410_974_758_996_510_282);
    assertEq(_weightedSharePerVote, (uint256(1_123_198) * 518_399 * 1e42) / 490_410_974_758_996_510_282);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_bias)));
  }

  function test_WhenThePreviousGlobalPointWasRecordedInAPriorWeek()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = 3;
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Checkpoint on the boundary _weeksElapsed weeks later, so the fill writes one global point per crossed week
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs + _weeksElapsed * 1 weeks));
    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    _weightABefore = uint128(2000 * TOKEN_1);
    _weightAAfter = uint128(1000 * TOKEN_1);

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

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEndA - _checkpointTs) = slope * 52 weeks
    _bias = 249_315_068_493_146_073_600;

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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: _checkpointTs,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // it should adjust the slope changes at the stake end by the slope delta
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slope);
    // @dev stakeExpiry stays at the unchanged stakeEnd
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndA);
    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);

    // @dev slopeBefore = 2_000 * TOKEN_1 / MAX_TIME (floored); intermediate points carry _weightABefore decayed to each boundary
    _slopeBefore = 15_854_895_991_882;
    // @dev intermediate bias at boundary i = slopeBefore * (stakeEndA - B_i) = slopeBefore * 55, 54, 53 weeks
    _intermediateBias =
      [int128(527_397_260_273_962_848_000), int128(517_808_219_178_072_614_400), int128(508_219_178_082_182_380_800)];
    // @dev Independent running supply accumulators. Each week-bounded sub-interval contributes a separately-floored
    //      term (matching the contract's per-term integer division). Supply is taken at intervalEnd - 1:
    //        sub 1: refTs=1209599, dt=604799, supply=527_397_276_128_858_839_882
    //        sub 2: refTs=1814399, dt=604800, supply=517_808_235_032_968_606_282
    //        sub 3: refTs=2419199, dt=604800, supply=508_219_193_937_078_372_682
    //        sub 4: refTs=3023999, dt=604800, supply=498_630_152_841_188_139_082
    //      sharePerVote term         = dt * 1e42 / supply
    //      weightedSharePerVote term = (refTs - 1) * dt * 1e42 / supply   (ORIGIN = 1)
    //      The `_supplyRef`, `_refTs` and `_dt` arrays live in contract storage to relieve stack pressure.
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: _intermediateBias[_i - 1],
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
      _expectedShare += (_dt[_i - 1] * 1e42) / _supplyRef[_i - 1];
      _expectedWeighted += ((_refTs[_i - 1] - 1) * _dt[_i - 1] * 1e42) / _supplyRef[_i - 1];
      (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_sharePerVote, _expectedShare);
      assertEq(_weightedSharePerVote, _expectedWeighted);
    }
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _checkpointTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Final index adds the 4th sub-interval (refTs=3023999, dt=604800, supply=498_630_152_841_188_139_082).
    _expectedShare += (_dt[3] * 1e42) / _supplyRef[3];
    _expectedWeighted += ((_refTs[3] - 1) * _dt[3] * 1e42) / _supplyRef[3];
    (_finalShare, _finalWeighted) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_finalShare, _expectedShare);
    assertEq(_finalWeighted, _expectedWeighted);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), uint256(uint128(_bias)));
  }

  modifier whenTheStakeEndHasChanged() {
    _;
  }

  function test_WhenThePreviousStakeHasNotYetExpired()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndHasChanged
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev Later in the same week as _initialTs: a single new global point, no boundary crossed
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs) - 1 days);
    // @dev Non-permanent stakes can only be extended, so _stakeEndAfter is strictly greater than _stakeEndBefore
    uint48 _stakeEndBefore = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 26 weeks));
    uint48 _stakeEndAfter = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    uint128 _weightBefore = uint128(2000 * TOKEN_1);
    uint128 _weightAfter = uint128(1000 * TOKEN_1);

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

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEndAfter - _checkpointTs) = slope * (52 weeks - 6 days)
    _bias = 245_205_479_452_050_259_200;

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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // @dev Reset cancels the previously scheduled slope change at the prior stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEndBefore), 0);
    // it should decrease the slope changes at the new stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEndAfter), -_slope);
    // it should overwrite the stake expiry for the token ID
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), _stakeEndAfter);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // it should record a new global point
    // it should increment the global checkpoint count
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + 1);
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Prior point at ts=604801 carries _weightBefore (2_000*TOKEN_1, slope=15_854_895_991_882). A single
    //      same-week sub-interval [604801, _checkpointTs(1123200)): dt=518399, refTs=1123199.
    //      supplyRef            = slope*(_stakeEndBefore - refTs) = 241_095_906_265_850_436_682.
    //      sharePerVote         = 518399 * 1e42 / supplyRef
    //      weightedSharePerVote = (refTs - 1) * 518399 * 1e42 / supplyRef
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, (uint256(518_399) * 1e42) / 241_095_906_265_850_436_682);
    assertEq(_weightedSharePerVote, (uint256(1_123_198) * 518_399 * 1e42) / 241_095_906_265_850_436_682);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));
  }

  function test_WhenThePreviousStakeHasAlreadyExpired()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndHasChanged
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev _stakeEndBefore sits between _initialTs and _checkpointTs so the lock has weight at _initialTs and is expired by _checkpointTs
    uint48 _stakeEndBefore = uint48(ProtocolTimeLibrary.epochNext(_initialTs));
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(_stakeEndBefore) - 1 days);
    uint48 _stakeEndAfter = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    uint128 _weightBefore = uint128(2000 * TOKEN_1);
    uint128 _weightAfter = uint128(1000 * TOKEN_1);

    // @dev Seed the accumulators so the intermediate global point caches them at the boundary index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint that will be expired by `_checkpointTs`
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _weightBefore, _stakeEnd: _stakeEndBefore, _data: ''
    });
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the new global point's snapshot is observably distinct from the intermediate
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(_checkpointTs);

    // @dev slopeBefore = 2_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeBefore = 15_854_895_991_882;
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEndAfter - _checkpointTs) = slope * (52 weeks - 6 days)
    _bias = 245_205_479_452_050_259_200;

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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 2)
    });
    // @dev Reset leaves the slope changes at the prior expired stake end untouched (already applied at the boundary)
    assertEq(votingRewardsManager.slopeChanges(_stakeEndBefore), -_slopeBefore);
    // it should decrease the slope changes at the new stake end by the slope
    assertEq(votingRewardsManager.slopeChanges(_stakeEndAfter), -_slope);
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
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    // it should snapshot the fee accumulators at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Prior point at ts=604801 carries _weightBefore (2_000*TOKEN_1, slope=15_854_895_991_882) ending at
    //      _stakeEndBefore=1209600. Two sub-intervals up to _checkpointTs(1728000):
    //        sub 1: [604801, 1209600), dt=604799, refTs=1209599, supply=slope*(1209600 - refTs)
    //        sub 2: [1209600, 1728000] has supply=0 (stake fully expired at the boundary) so it contributes nothing.
    //      The accumulator at the final index therefore equals the single sub-1 term.
    //      sharePerVote         = 604799 * 1e42 / 15_854_895_991_882
    //      weightedSharePerVote = (1209599 - 1) * 604799 * 1e42 / 15_854_895_991_882
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, (uint256(604_799) * 1e42) / 15_854_895_991_882);
    assertEq(_weightedSharePerVote, (uint256(1_209_598) * 604_799 * 1e42) / 15_854_895_991_882);
    // @dev balanceOfNFTAt / supplyAt reflect the new non-permanent state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));
  }

  function testGas_checkpoint_nonPermanent()
    external
    whenThereIsAPriorCheckpoint
    whenTheStakeWasAlreadyNonPermanent
    whenTheStakeEndIsUnchanged
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    uint128 _weight = 1000e18;
    uint48 _stakeEnd = 208 weeks;

    vm.warp(1 weeks);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight / 4, _stakeEnd: _stakeEnd, _data: ''});

    // @dev Seed the accumulators so the second checkpoint snapshots them at the new index
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

    vm.warp(block.timestamp + 1 hours);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    vm.snapshotGasLastCall('VotingRewardsManager_checkpoint_nonPermanent');
  }
}
