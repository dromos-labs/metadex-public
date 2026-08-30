// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_reset` logic for permanent stakes.
 * @dev Invoked through the public `checkpoint` entry point with a zero allocated
 *      weight, clearing a prior permanent stake.
 *
 *      Dispatch behavior is tested separately in the `checkpoint` suite.
 */
contract UnitConcreteVotingRewardsManagerResetPermanent is UnitVotingRewardsManager {
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e18;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e18;
  uint256 internal constant _FEE_ACC_0 = 3e18;
  uint256 internal constant _FEE_ACC_1 = 4e18;
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e18;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e18;
  uint256 internal constant _FEE_ACC_0_TIME = 30e18;
  uint256 internal constant _FEE_ACC_1_TIME = 40e18;

  // @dev Expected per-week supply accumulator snapshots for the prior-week reset case, indexed by elapsed week.
  //      Stored to keep the multi-index loop within the stack limit.
  uint256[4] internal _expectedSharePerVote;
  uint256[4] internal _expectedWeightedSharePerVote;

  /// @dev Variables from the multi-week test, kept in storage to avoid stack-too-deep
  uint16 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _resetTs;
  uint128 internal _weight;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint256 internal _sharePerVote;
  uint256 internal _weightedSharePerVote;
  uint256 internal _finalSharePerVote;
  uint256 internal _finalWeightedSharePerVote;

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
    // @dev No prior checkpoint: lastTs == block.timestamp so the only sub-interval has dt = 0; accumulators stay zero
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(1);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
  }

  modifier whenThereIsAPriorCheckpoint() {
    _;
  }

  function test_WhenThePreviousUserPointWasRecordedInTheCurrentTimestamp() external whenThereIsAPriorCheckpoint {
    _weight = uint128(1000 * TOKEN_1);

    // @dev Seed the accumulators so the first checkpoint caches them at `_globalIndex`
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is observably distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Same-timestamp overwrite: the only sub-interval has dt = 0, so the supply accumulators stay zero
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 0);
    assertEq(_weightedSharePerVote, 0);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
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
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weightA = uint128(2000 * TOKEN_1);
    uint128 _weightB = uint128(1000 * TOKEN_1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Seed the accumulators so the next checkpoint records them at the new index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Grow the accumulators so the overwrite path is distinct from a re-snapshot
    _seedFeeAccumulator(_FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);

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
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Snapshot written by token B's checkpoint and left unchanged by the same-timestamp reset overwrite.
    //      _weightA = 2000e18 constant supply from lastTs = 1 to block.timestamp = 1 + WEEK (1 + 604800).
    //      Sub-interval 1: [1, 604800), dt = 604799, supply = 2000e18; sub-interval 2: [604800, 604801), dt = 1.
    //      sharePerVote = 604799*1e42/2000e18 + 1*1e42/2000e18 = 302400000000000000000000000.
    //      weightedSharePerVote = (604800-2)*604799*1e42/2000e18 + (604801-2)*1*1e42/2000e18.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, 302_400_000_000_000_000_000_000_000);
    assertEq(_weightedSharePerVote, 182_890_915_200_500_000_000_000_000_000_000);
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

  function test_WhenThePreviousGlobalPointWasRecordedInTheCurrentWeek()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Later in the same week as _initialTs so no boundary is crossed and a new global point is recorded
    _resetTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs) - 1 days);
    _weight = uint128(1000 * TOKEN_1);

    vm.warp(_initialTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

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
    // @dev Single sub-interval, no week boundary crossed. lastTs = _initialTs = epochNext(1)+1day = 691200,
    //      block.timestamp = _resetTs = epochNext(691200)-1day = 1123200. dt = 1123200-691200 = 432000,
    //      supply = _weight = 1000e18, ORIGIN = 1.
    //      sharePerVote = 432000*1e42/1000e18 = 432000000000000000000000000.
    //      weightedSharePerVote = (1123200-2)*432000*1e42/1000e18 = 485221536000000000000000000000000.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, 432_000_000_000_000_000_000_000_000);
    assertEq(_weightedSharePerVote, 485_221_536_000_000_000_000_000_000_000_000);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function test_WhenThePreviousGlobalPointWasRecordedInAPriorWeek()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weeksElapsed = 3;
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Land mid-week so exactly _weeksElapsed boundaries fall before _resetTs
    _resetTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs + _weeksElapsed * 1 weeks) + 1 days);
    _weight = uint128(1000 * TOKEN_1);

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
    // @dev Running supply accumulators with constant supply = _weight = 1000e18, ORIGIN = 1, lastTs starts at
    //      _initialTs = epochNext(1)+1day = 691200, walking week boundaries to _resetTs = 2505600.
    //      idx2: sub-interval [691200, 1209600), dt = 518400; sharePerVote = 518400*1e42/1000e18,
    //            weighted += (1209600-2)*518400*1e42/1000e18.
    //      idx3: sub-interval [1209600, 1814400), dt = 604800; sharePerVote += 604800*1e42/1000e18,
    //            weighted += (1814400-2)*604800*1e42/1000e18.
    //      idx4: sub-interval [1814400, 2419200), dt = 604800; sharePerVote += 604800*1e42/1000e18,
    //            weighted += (2419200-2)*604800*1e42/1000e18.
    //      idx5 (final): sub-interval [2419200, 2505600), dt = 86400; sharePerVote += 86400*1e42/1000e18,
    //            weighted += (2505600-2)*86400*1e42/1000e18.
    _expectedSharePerVote[1] = 518_400_000_000_000_000_000_000_000;
    _expectedWeightedSharePerVote[1] = 627_055_603_200_000_000_000_000_000_000_000;
    _expectedSharePerVote[2] = 1_123_200_000_000_000_000_000_000_000;
    _expectedWeightedSharePerVote[2] = 1_724_403_513_600_000_000_000_000_000_000_000;
    _expectedSharePerVote[3] = 1_728_000_000_000_000_000_000_000_000;
    _expectedWeightedSharePerVote[3] = 3_187_534_464_000_000_000_000_000_000_000_000;
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
      (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_sharePerVote, _expectedSharePerVote[_i]);
      assertEq(_weightedSharePerVote, _expectedWeightedSharePerVote[_i]);
    }
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(_newIndex, _FEE_ACC_0, _FEE_ACC_1, _FEE_ACC_0_TIME, _FEE_ACC_1_TIME);
    // it should snapshot the supply accumulators at each new global checkpoint index
    (_finalSharePerVote, _finalWeightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_finalSharePerVote, 1_814_400_000_000_000_000_000_000_000);
    assertEq(_finalWeightedSharePerVote, 3_404_018_131_200_000_000_000_000_000_000_000);
    // @dev stakeExpiry stays zero for permanent locks
    assertEq(votingRewardsManager.stakeExpiry(_TOKEN_ID_A), 0);
    // @dev balanceOfNFTAt / totalSupply reflect the reset state
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);
  }

  function testGas_reset_permanent()
    external
    whenThereIsAPriorCheckpoint
    whenThePreviousUserPointWasRecordedInAPriorTimestamp
    whenThePreviousGlobalPointWasRecordedInAPriorTimestamp
  {
    _weight = 1000e18;

    vm.warp(1 weeks);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Seed the accumulators so they're snapshotted at the new global index
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    vm.warp(block.timestamp + 1 hours);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});
    vm.snapshotGasLastCall('VotingRewardsManager_reset_permanent');
  }
}
