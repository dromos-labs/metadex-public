// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_reset` logic for non-permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a zero allocated
 *      weight, clearing a prior non-permanent stake.
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitConcreteVotingRewardsManagerResetNonPermanent is UnitVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  // @dev Hoisted out of the multi-week reset test to avoid stack-too-deep
  uint256[4] internal _shareTerm;
  uint256[4] internal _weightedShareTerm;
  uint256 internal _runningShare;
  uint256 internal _runningWeightedShare;

  /// @dev Variables from the multi-week test, kept in storage to avoid stack-too-deep
  uint16 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _resetTs;
  uint48 internal _stakeEnd;
  uint128 internal _weight;
  uint256 internal _priorIndex;
  int128 internal _slope;
  uint256 internal _newIndex;
  int128[3] internal _intermediateBias;
  uint256 internal _i;
  uint48 internal _intermediateTs;
  uint256 internal _intermediateShare;
  uint256 internal _intermediateWeightedShare;
  uint256 internal _sharePerVote;
  uint256 internal _weightedSharePerVote;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function test_WhenThereIsNoPriorCheckpoint() external {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
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
    // @dev No prior point: the loop seeds lastTs = block.timestamp, so every sub-interval has dt = 0
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  modifier whenThePreviousStakeHasNotYetExpired() {
    _;
  }

  function test_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    _weight = uint128(1000 * TOKEN_1);
    vm.warp(_ts);

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;
    // @dev Checkpoint scheduled `-_slope` as the slope change at the stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEnd), -_slope);

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // @dev Supply accumulator at the overwritten index also stays put. The first checkpoint took the
    //      globalIndex == 0 path (lastTs == block.timestamp, every dt == 0), so it snapshotted (0, 0);
    //      the same-timestamp overwrite does not re-snapshot.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  modifier whenThePreviousUserPointWasRecordedInAPriorTimestamp() {
    _;
  }

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentTimestamp()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(block.timestamp + 1 weeks);
    // @dev On the next epoch boundary so TOKEN_B's decay spans whole weeks
    _resetTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs));
    uint48 _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_resetTs + 52 weeks));
    uint48 _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_resetTs + 39 weeks));
    uint128 _weightA = uint128(2000 * TOKEN_1);
    uint128 _weightB = uint128(1000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEndA, _data: ''});
    // @dev slopeA = 2_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slopeA = 15_854_895_991_882;

    vm.warp(_resetTs);

    // @dev TOKEN_A's checkpoint scheduled `-_slopeA` at its stake end
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slopeA);

    // @dev Seed the accumulators so the next checkpoint records them at the current index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev slopeB = 1_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slopeB = 7_927_447_995_941;
    // @dev biasB = slopeB * (stakeEndB - _resetTs), 39 whole weeks of decay
    int128 _biasB = 186_986_301_369_859_555_200;
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // @dev Supply accumulator at the overwritten index keeps TOKEN_B's checkpoint snapshot. That checkpoint ran
    //      one sub-interval [_initialTs, _resetTs) over TOKEN_A's lock: lastTs = _initialTs = 604801,
    //      block.timestamp = _resetTs = 1209600, dt = 604799, refTs = 1209599, slopeA = 15854895991882,
    //      stakeEndA = 32659200, supplyRef = slopeA*(stakeEndA - refTs) = 498630152841188139082.
    //      sharePerVote = 604799 * 1e42 / 498630152841188139082;
    //      weightedSharePerVote = (refTs - 1) * 604799 * 1e42 / 498630152841188139082. The reset overwrites without re-snapshotting.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, (uint256(604_799) * 1e42) / uint256(498_630_152_841_188_139_082));
    assertEq(
      _weightedSharePerVote, (uint256(1_209_599 - 1) * uint256(604_799) * 1e42) / uint256(498_630_152_841_188_139_082)
    );
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

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Later in the same week as _initialTs so no boundary is crossed and a new global point is recorded
    _resetTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs) - 1 days);
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_resetTs + 52 weeks));
    _weight = uint128(1000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev One sub-interval [_initialTs, _resetTs) inside a single week: lastTs = _initialTs = 691200,
    //      block.timestamp = _resetTs = 1123200, dt = 432000, refTs = 1123199, slope = 7927447995941,
    //      stakeEnd = 32054400, supplyRef = slope*(stakeEnd - refTs) = 245205487379498255141.
    //      sharePerVote = 432000 * 1e42 / 245205487379498255141;
    //      weightedSharePerVote = (refTs - 1) * 432000 * 1e42 / 245205487379498255141.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, (uint256(432_000) * 1e42) / uint256(245_205_487_379_498_255_141));
    assertEq(
      _weightedSharePerVote, (uint256(1_123_199 - 1) * uint256(432_000) * 1e42) / uint256(245_205_487_379_498_255_141)
    );
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function test_WhenThePreviousGlobalPointWasRecordedInAPriorWeek()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = 3;
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Land mid-week so exactly _weeksElapsed boundaries fall before _resetTs
    _resetTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs + _weeksElapsed * 1 weeks) + 1 days);
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_resetTs + 52 weeks));
    _weight = uint128(1000 * TOKEN_1);

    // @dev Seed the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;

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

    // @dev Each elapsed week's intermediate point holds the stake decayed to that boundary:
    //      bias = slope * (stakeEnd - boundary), i.e. 54, 53 and 52 whole weeks of decay
    _intermediateBias =
      [int128(258_904_109_589_036_307_200), int128(254_109_589_041_091_190_400), int128(249_315_068_493_146_073_600)];
    // @dev Per-sub-interval supply accumulator terms (each divided separately, then summed).
    //      slope = 7927447995941, stakeEnd = 33868800, supplyRef = slope*(stakeEnd - refTs). ORIGIN = 1.
    //      sub1 [691200,1209600) dt=518400 refTs=1209599 supplyRef=258904117516484303141
    //      sub2 [1209600,1814400) dt=604800 refTs=1814399 supplyRef=254109596968539186341
    //      sub3 [1814400,2419200) dt=604800 refTs=2419199 supplyRef=249315076420594069541
    //      sub4 [2419200,2505600) dt= 86400 refTs=2505599 supplyRef=248630144913744767141
    //      Intermediate index _priorIndex+_i caches the running sum through sub-interval _i.
    _shareTerm = [
      (uint256(518_400) * 1e42) / uint256(258_904_117_516_484_303_141),
      (uint256(604_800) * 1e42) / uint256(254_109_596_968_539_186_341),
      (uint256(604_800) * 1e42) / uint256(249_315_076_420_594_069_541),
      (uint256(86_400) * 1e42) / uint256(248_630_144_913_744_767_141)
    ];
    _weightedShareTerm = [
      (uint256(1_209_599 - 1) * uint256(518_400) * 1e42) / uint256(258_904_117_516_484_303_141),
      (uint256(1_814_399 - 1) * uint256(604_800) * 1e42) / uint256(254_109_596_968_539_186_341),
      (uint256(2_419_199 - 1) * uint256(604_800) * 1e42) / uint256(249_315_076_420_594_069_541),
      (uint256(2_505_599 - 1) * uint256(86_400) * 1e42) / uint256(248_630_144_913_744_767_141)
    ];
    for (_i = 1; _i <= _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      // it should record a new global point for each elapsed week
      _assertGlobalPoint({
        _expectedBias: _intermediateBias[_i - 1],
        _expectedSlope: _slope,
        _expectedPermanentLockBalance: 0,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // it should snapshot the supply accumulators at each new global checkpoint index
      _runningShare += _shareTerm[_i - 1];
      _runningWeightedShare += _weightedShareTerm[_i - 1];
      (_intermediateShare, _intermediateWeightedShare) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_intermediateShare, _runningShare);
      assertEq(_intermediateWeightedShare, _runningWeightedShare);
    }
    // @dev Add the final partial sub-interval to reach the snapshot at `_newIndex`
    _runningShare += _shareTerm[3];
    _runningWeightedShare += _weightedShareTerm[3];
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Final snapshot = running sum through all four sub-intervals (the last partial one added above)
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, _runningShare);
    assertEq(_weightedSharePerVote, _runningWeightedShare);
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function test_WhenThePreviousStakeHasAlreadyExpired() external whenThereIsAPriorCheckpoint {
    // @dev `_stakeEnd` sits between `_initialTs` and `_resetTs` so the lock has weight at
    //      `_initialTs` and is expired by `_resetTs`
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    _stakeEnd = uint48(ProtocolTimeLibrary.epochNext(_initialTs));
    _resetTs = uint48(_stakeEnd + 1 days);
    _weight = uint128(1000 * TOKEN_1);

    // @dev Seed the accumulators so the intermediate global point caches them at the boundary index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a non-permanent stake checkpoint that will be expired by `_resetTs`
    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slope = 7_927_447_995_941;

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Only the first sub-interval [_initialTs, _stakeEnd) contributes: lastTs = _initialTs = 691200,
    //      stakeEnd boundary = 1209600, dt = 518400, refTs = 1209599, slope = 7927447995941,
    //      supplyRef = slope*(_stakeEnd - refTs) = 7927447995941.
    //      The next sub-interval [_stakeEnd, _resetTs] sees supply == 0 (lock fully decayed) so it is skipped.
    //      sharePerVote = 518400 * 1e42 / 7927447995941;
    //      weightedSharePerVote = (refTs - 1) * 518400 * 1e42 / 7927447995941.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, (uint256(518_400) * 1e42) / uint256(7_927_447_995_941));
    assertEq(_weightedSharePerVote, (uint256(1_209_599 - 1) * uint256(518_400) * 1e42) / uint256(7_927_447_995_941));
    // @dev permanentStakeBalance stays zero for non-permanent locks
    assertEq(votingRewardsManager.permanentStakeBalance(), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function testGas_reset_nonPermanent()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousStakeHasNotYetExpired
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weight = 1000e18;
    _stakeEnd = 208 weeks;

    vm.warp(1 weeks);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // @dev Seed the accumulators so they're snapshotted at the new global index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(block.timestamp + 1 hours);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});
    vm.snapshotGasLastCall('VotingRewardsManager_reset_nonPermanent');
  }
}
