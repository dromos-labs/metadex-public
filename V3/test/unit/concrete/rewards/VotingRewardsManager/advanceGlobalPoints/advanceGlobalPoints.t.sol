// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitConcreteVotingRewardsManagerAdvanceGlobalPoints is UnitVotingRewardsManager {
  /// @dev Precision used by the supply accumulators
  uint256 internal constant _ACCUMULATOR_PRECISION = 1e42;
  /// @dev Gauge fees pending at the initial checkpoint
  uint256 internal constant _INITIAL_PENDING_0 = 500 * TOKEN_1;
  uint256 internal constant _INITIAL_PENDING_1 = 1000 * TOKEN_1;
  /// @dev Accumulator values after the initial credit: _INITIAL_PENDING * FEE_ACCUMULATOR_PRECISION / _weightPerm
  uint256 internal constant _INITIAL_FEE_ACC_0 = 1e24;
  uint256 internal constant _INITIAL_FEE_ACC_1 = 2e24;
  /// @dev Time-weighted accumulators seeded for the advance with no pending fees
  uint256 internal constant _INITIAL_FEE_ACC_0_TIME = 10e24;
  uint256 internal constant _INITIAL_FEE_ACC_1_TIME = 20e24;
  /// @dev New gauge fees accrued by the time of the advance
  uint256 internal constant _PENDING_0 = 5 * TOKEN_1;
  uint256 internal constant _PENDING_1 = 7 * TOKEN_1;

  uint128 internal _weight = uint128(1000 * TOKEN_1);
  uint128 internal _weightPerm = _weight / 2;

  /// @dev Scratch storage for supply accumulator reads, kept off the stack to avoid stack-too-deep
  uint256 internal _sharePerVote;
  uint256 internal _weightedSharePerVote;

  /// @dev Expected per-boundary supply accumulators, kept in storage to avoid stack-too-deep
  uint256[] internal _expectedSharePerVote;
  uint256[] internal _expectedWeightedSharePerVote;

  /// @dev Variables from multi-week tests, kept in storage to avoid stack-too-deep
  uint16 internal _weeksElapsed;
  uint48 internal _initialTs;
  uint48 internal _advanceTs;
  uint48 internal _stakeEndB;
  uint256 internal _priorIndex;
  uint256 internal _newIndex;
  uint256 internal _i;
  uint48 internal _intermediateTs;
  int128 internal _slopeB;
  int128 internal _initialBiasB;
  int128 internal _finalBias;

  function test_WhenThereIsNoPriorGlobalCheckpoint() external {
    // it should revert with NoGlobalCheckpoint
    vm.expectRevert(IVotingRewardsManager.NoGlobalCheckpoint.selector);
    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();
  }

  modifier whenThereIsAtLeastOnePriorGlobalCheckpoint() {
    _;
  }

  function test_WhenTheLatestGlobalPointWasRecordedInTheCurrentEpoch()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Later in the same epoch as _initialTs so the latest global point is still in the current epoch
    _advanceTs = uint48(ProtocolTimeLibrary.epochNext(_initialTs) - 1 days);

    // @dev Record a global checkpoint at `_initialTs`
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_advanceTs);

    // it should revert with TooSoon
    vm.expectRevert(IVotingRewardsManager.TooSoon.selector);
    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();
  }

  modifier whenTheLatestGlobalPointWasRecordedInAPriorEpoch() {
    _;
  }

  function test_WhenHistoryReachesTheCheckpointIterationLimit()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);

    // @dev Record a permanent stake at the initial checkpoint
    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev Advance exactly the maximum number of checkpoint intervals
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks);
    vm.warp(_advanceTs);
    _mockGaugePendingFees(_PENDING_0, _PENDING_1);

    // it should notify the pending fees
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _PENDING_0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _PENDING_1);

    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should reach the current timestamp in one advance
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + MAX_CHECKPOINT_ITERATIONS);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _advanceTs);

    uint256 _feeAcc0 = _PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    uint256 _feeAcc1 = _PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();

    // it should snapshot the credited fee accumulator at the current timestamp
    _assertFeeSnapshot(
      _newIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_advanceTs - _origin), _feeAcc1 * (_advanceTs - _origin)
    );
  }

  function test_WhenHistoryExceedsTheCheckpointIterationLimit()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev TOKEN_ID_B's week-aligned stake end, 55 weeks after the initial checkpoint's epoch
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_initialTs + 55 weeks));
    // @dev slopeB = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeB = 7_927_447_995_941;
    // @dev initialBiasB = slopeB * (stakeEndB - initialTs), 55 weeks minus 1 day of decay
    _initialBiasB = 263_013_698_630_132_121_600;

    vm.warp(_initialTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + (MAX_CHECKPOINT_ITERATIONS + 1) * 1 weeks);
    /// @dev Make history exceed the single-advance limit by one week
    vm.warp(_advanceTs);

    /// @dev Revert any pending-fee query to prove partial recovery does not read the gauge
    vm.clearMockedCalls();
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

    /// @dev Advance stale history by the maximum number of intervals
    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should advance only the maximum number of intervals on the first call
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = ProtocolTimeLibrary.epochStart(_initialTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks;
    assertEq(_globalIndex, _priorIndex + MAX_CHECKPOINT_ITERATIONS);
    assertEq(votingRewardsManager.globalRewardPointHistory(_globalIndex).ts, _latestCheckpointTs);
    assertEq(votingRewardsManager.globalRewardPointHistory(_globalIndex - 1).ts, _latestCheckpointTs - 1 weeks);

    // it should not query the gauge for pending fees during partial recovery

    // it should preserve fee accounting during partial recovery
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastFeeUpdate(), _initialTs);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should snapshot the unchanged fee accumulator at the partial frontier
    _assertFeeSnapshot(_globalIndex, 0, 0, 0, 0);

    // it should apply scheduled slope changes at each epoch boundary
    // @dev The expiry is the 55th boundary after the initial checkpoint; the prior point is one week earlier
    //      with bias = slopeB * 1 week = 7_927_447_995_941 * 604_800 = 4_794_520_547_945_116_800
    _assertGlobalPoint({
      _expectedBias: 4_794_520_547_945_116_800,
      _expectedSlope: _slopeB,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _stakeEndB - 1 weeks,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + 54)
    });
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _stakeEndB,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + 55)
    });

    (uint256 _firstSharePerVote, uint256 _firstWeightedSharePerVote) =
      votingRewardsManager.supplyAccumulatorAt(_globalIndex);

    /// @dev Make the pending fees available once history can reach the current timestamp
    vm.clearMockedCalls();
    _mockGaugePendingFees(_PENDING_0, _PENDING_1);

    // it should notify pending fees only when history reaches the current timestamp
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _PENDING_0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _PENDING_1);

    /// @dev Advance the remaining week so history reaches the current timestamp
    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should resume from that checkpoint and reach the current timestamp on the second call
    _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_globalIndex, _priorIndex + MAX_CHECKPOINT_ITERATIONS + 1);
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });

    uint256 _feeAcc0 = _PENDING_0 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    uint256 _feeAcc1 = _PENDING_1 * FEE_ACCUMULATOR_PRECISION / _weightPerm;
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();

    // it should credit the pending fees exactly once
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_advanceTs - _origin), _feeAcc1 * (_advanceTs - _origin));
    assertEq(votingRewardsManager.lastFeeUpdate(), _advanceTs);
    assertEq(votingRewardsManager.lastPendingFees0(), _PENDING_0);
    assertEq(votingRewardsManager.lastPendingFees1(), _PENDING_1);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should snapshot the credited fee accumulator at the current timestamp
    _assertFeeSnapshot(
      _globalIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_advanceTs - _origin), _feeAcc1 * (_advanceTs - _origin)
    );

    // it should continue the supply accumulators across both calls
    // @dev The second call prices one permanent-only week and extends the first call's accumulator values
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_globalIndex);
    assertEq(_sharePerVote, _firstSharePerVote + (1 weeks * _ACCUMULATOR_PRECISION) / _weightPerm);
    assertEq(
      _weightedSharePerVote,
      _firstWeightedSharePerVote
        + ((_advanceTs - 1 - votingRewardsManager.ACCUMULATOR_ORIGIN()) * 1 weeks * _ACCUMULATOR_PRECISION)
        / _weightPerm
    );

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

  function test_WhenTheGaugeHasPendingFees()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
    whenTheAdvanceLandsWithinAnEpoch
  {
    _weeksElapsed = 3;
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Land mid-week so exactly _weeksElapsed boundaries fall before _advanceTs
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs + _weeksElapsed * 1 weeks) + 1 days);
    // @dev TOKEN_ID_B's week-aligned stake end, beyond _advanceTs so it never expires in-window
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_initialTs + 55 weeks));

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

    // @dev slopeB = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeB = 7_927_447_995_941;

    vm.warp(_advanceTs);
    // @dev Increase the gauge fees by `_PENDING_0/1` so the advance credits them
    _mockGaugePendingFees(_INITIAL_PENDING_0 + _PENDING_0, _INITIAL_PENDING_1 + _PENDING_1);

    // @dev finalBias = slopeB * (stakeEndB - _advanceTs), 52 weeks minus 1 day of decay
    _finalBias = 248_630_136_986_296_771_200;
    // @dev totalSupply at credit time is the permanent balance plus TOKEN_ID_B's decayed bias
    uint256 _supply = uint256(_weightPerm) + uint256(uint128(_finalBias));

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 =
        _ceilDiv((_PENDING_0 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 =
        _ceilDiv((_PENDING_1 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);

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
    // @dev Accumulators increase by pendingFees * FEE_ACCUMULATOR_PRECISION / supply
    _assertFeeAccumulator(
      _INITIAL_FEE_ACC_0 + _PENDING_0 * FEE_ACCUMULATOR_PRECISION / _supply,
      _INITIAL_FEE_ACC_1 + _PENDING_1 * FEE_ACCUMULATOR_PRECISION / _supply,
      _INITIAL_FEE_ACC_0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + _PENDING_0
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _INITIAL_FEE_ACC_1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + _PENDING_1
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should advance globalCheckpointIndex by the number of new global points
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    // @dev Each crossed boundary's intermediate point holds TOKEN_ID_B decayed to that boundary:
    //      bias = slopeB * (stakeEndB - boundary), i.e. 54, 53 and 52 whole weeks of decay
    int128[3] memory _intermediateBias =
      [int128(258_904_109_589_036_307_200), int128(254_109_589_041_091_190_400), int128(249_315_068_493_146_073_600)];
    // @dev Supply accumulators per crossed boundary: the same intervals as the no-pending scenario plus a
    //      constant seed from TOKEN_ID_A's checkpoint one second before `_initialTs` (1s at supply `_weightPerm`):
    //      sharePerVote += 2e21, weightedSharePerVote += 691198 * 2e21.
    _expectedSharePerVote.push(683_092_245_572_082_738_527_676_594);
    _expectedSharePerVote.push(1_485_097_686_732_423_446_587_714_142);
    _expectedSharePerVote.push(2_292_234_789_710_614_320_703_891_018);
    _expectedWeightedSharePerVote.push(826_265_977_259_500_136_357_600_553_189_759);
    _expectedWeightedSharePerVote.push(2_281_423_045_689_939_996_380_316_561_721_846);
    _expectedWeightedSharePerVote.push(4_234_047_510_940_573_402_660_423_429_776_809);
    for (_i = 1; _i < _weeksElapsed + 1; ++_i) {
      // it should record a new global point for each elapsed week and the current timestamp
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias[_i - 1],
        _expectedSlope: _slopeB,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the pre-credit accumulator at each intermediate checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i,
        _INITIAL_FEE_ACC_0,
        _INITIAL_FEE_ACC_1,
        _INITIAL_FEE_ACC_0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
        _INITIAL_FEE_ACC_1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
      );
      // it should snapshot the supply accumulators at the new global checkpoint index
      (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_sharePerVote, _expectedSharePerVote[_i - 1]);
      assertEq(_weightedSharePerVote, _expectedWeightedSharePerVote[_i - 1]);
    }
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _slopeB,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });

    // it should snapshot the credited accumulator at the latest global checkpoint index
    _assertFeeSnapshot(
      _newIndex,
      _INITIAL_FEE_ACC_0 + _PENDING_0 * FEE_ACCUMULATOR_PRECISION / _supply,
      _INITIAL_FEE_ACC_1 + _PENDING_1 * FEE_ACCUMULATOR_PRECISION / _supply,
      _INITIAL_FEE_ACC_0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + _PENDING_0
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _INITIAL_FEE_ACC_1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()) + _PENDING_1
        * FEE_ACCUMULATOR_PRECISION / _supply * (_advanceTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, 2_407_645_584_462_881_189_380_143_740);
    assertEq(_weightedSharePerVote, 4_523_220_567_450_263_764_281_904_899_684_287);
    // it should not modify any user reward state
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weightPerm,
      _expectedTs: _initialTs - 1,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, 1)
    });
    // @dev initialBiasB = slopeB * (stakeEndB - _initialTs), 55 weeks minus 1 day of decay
    _initialBiasB = 263_013_698_630_132_121_600;
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

  function test_WhenTheGaugeHasNoPendingFees()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
    whenTheAdvanceLandsWithinAnEpoch
  {
    _weeksElapsed = 3;
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev Land mid-week so exactly _weeksElapsed boundaries fall before _advanceTs
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs + _weeksElapsed * 1 weeks) + 1 days);
    // @dev TOKEN_ID_B's week-aligned stake end, beyond _advanceTs so it never expires in-window
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_initialTs + 55 weeks));

    // @dev Initialize the accumulators so the first checkpoint caches them at `_priorIndex` for intermediate fills
    _seedFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // @dev Record a permanent stake for TOKEN_ID_A and a non-permanent stake for TOKEN_ID_B at `_initialTs`
    vm.warp(_initialTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();
    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev slopeB = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeB = 7_927_447_995_941;
    // @dev initialBiasB = slopeB * (stakeEndB - _initialTs), 55 weeks minus 1 day of decay
    _initialBiasB = 263_013_698_630_132_121_600;

    vm.warp(_advanceTs);

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(users.alice, _priorIndex + _weeksElapsed + 1);

    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should not credit any fees to the accumulator
    _assertFeeAccumulator(_INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME);

    // it should advance globalCheckpointIndex by the number of new global points
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed + 1);
    // @dev finalBias = slopeB * (stakeEndB - _advanceTs), 52 weeks minus 1 day of decay
    _finalBias = 248_630_136_986_296_771_200;
    // @dev Each crossed boundary's intermediate point holds TOKEN_ID_B decayed to that boundary:
    //      bias = slopeB * (stakeEndB - boundary), i.e. 54, 53 and 52 whole weeks of decay
    int128[3] memory _intermediateBias =
      [int128(258_904_109_589_036_307_200), int128(254_109_589_041_091_190_400), int128(249_315_068_493_146_073_600)];
    // @dev Independently-derived supply accumulators per crossed boundary. Each sub-interval term is
    //      `dt_j * 1e42 / supply_j` (supply_j = bias at `intervalEnd - 1` + permanentStakeBalance) and they
    //      accumulate from the (0, 0) prior-index seed (the initialTs checkpoint walked no live interval).
    //      +1: dt=518400, supply=758_904_117_516_484_303_141, refTs=1_209_599
    //      +2: dt=604800, supply=754_109_596_968_539_186_341, refTs=1_814_399
    //      +3: dt=604800, supply=749_315_076_420_594_069_541, refTs=2_419_199
    _expectedSharePerVote.push(683_090_245_572_082_738_527_676_594);
    _expectedSharePerVote.push(1_485_095_686_732_423_446_587_714_142);
    _expectedSharePerVote.push(2_292_232_789_710_614_320_703_891_018);
    _expectedWeightedSharePerVote.push(826_264_594_863_500_136_357_600_553_189_759);
    _expectedWeightedSharePerVote.push(2_281_421_663_293_939_996_380_316_561_721_846);
    _expectedWeightedSharePerVote.push(4_234_046_128_544_573_402_660_423_429_776_809);
    for (_i = 1; _i < _weeksElapsed + 1; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      // it should record a new global point for each elapsed week and the current timestamp
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias[_i - 1],
        _expectedSlope: _slopeB,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the unchanged accumulator at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
      );
      // it should snapshot the supply accumulators at the new global checkpoint index
      (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_sharePerVote, _expectedSharePerVote[_i - 1]);
      assertEq(_weightedSharePerVote, _expectedWeightedSharePerVote[_i - 1]);
    }
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _slopeB,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(
      _newIndex, _INITIAL_FEE_ACC_0, _INITIAL_FEE_ACC_1, _INITIAL_FEE_ACC_0_TIME, _INITIAL_FEE_ACC_1_TIME
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Final write adds the trailing sub-interval dt=86400, supply=748_630_144_913_744_767_141
    //      at refTs=2_505_599 on top of the +3 accumulators above.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, 2_407_643_584_462_881_189_380_143_740);
    assertEq(_weightedSharePerVote, 4_523_219_185_054_263_764_281_904_899_684_287);
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

  function test_WhenTheAdvanceLandsOnAnEpochBoundary()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _weeksElapsed = 3;
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    // @dev `_advanceTs` lands exactly on the epoch boundary `_weeksElapsed` weeks after `epochStart(_initialTs)`
    _advanceTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + uint256(_weeksElapsed) * 1 weeks);
    // @dev TOKEN_ID_B's week-aligned stake end, beyond _advanceTs so it never expires in-window
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_initialTs + 55 weeks));

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

    // @dev slopeB = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeB = 7_927_447_995_941;
    // @dev initialBiasB = slopeB * (stakeEndB - _initialTs), 55 weeks minus 1 day of decay
    _initialBiasB = 263_013_698_630_132_121_600;

    vm.warp(_advanceTs);

    // it should emit the GlobalPointsAdvanced event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.GlobalPointsAdvanced(users.alice, _priorIndex + _weeksElapsed);

    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should advance globalCheckpointIndex by the number of elapsed weeks
    _newIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_newIndex, _priorIndex + _weeksElapsed);
    // @dev finalBias = slopeB * (stakeEndB - _advanceTs), 52 whole weeks of decay (advance lands on the boundary)
    _finalBias = 249_315_068_493_146_073_600;
    // @dev Intermediate writes cover weeks 1.._weeksElapsed - 1; the final write is the boundary itself.
    //      Each intermediate point holds TOKEN_ID_B decayed to that boundary:
    //      bias = slopeB * (stakeEndB - boundary), i.e. 54 and 53 whole weeks of decay
    int128[2] memory _intermediateBias = [int128(258_904_109_589_036_307_200), int128(254_109_589_041_091_190_400)];
    // @dev Independently-derived supply accumulators per crossed boundary. Each sub-interval term is
    //      `dt_j * 1e42 / supply_j` (supply_j = bias at `intervalEnd - 1` + permanentStakeBalance) accumulated
    //      from the prior-index seed of TOKEN_ID_A's checkpoint one second before _initialTs.
    //      seed: dt=1, supply=500_000_000_000_000_000_000, refTs=691_199
    //      +1: dt=518400, supply=758_904_117_516_484_303_141, refTs=1_209_599
    //      +2: dt=604800, supply=754_109_596_968_539_186_341, refTs=1_814_399
    _expectedSharePerVote.push(683_092_245_572_082_738_527_676_594);
    _expectedSharePerVote.push(1_485_097_686_732_423_446_587_714_142);
    _expectedWeightedSharePerVote.push(826_265_977_259_500_136_357_600_553_189_759);
    _expectedWeightedSharePerVote.push(2_281_423_045_689_939_996_380_316_561_721_846);
    for (_i = 1; _i < _weeksElapsed; ++_i) {
      _intermediateTs = uint48(ProtocolTimeLibrary.epochStart(_initialTs) + _i * 1 weeks);
      // it should record a new global point for each elapsed week
      // it should apply scheduled slope changes at each epoch boundary
      _assertGlobalPoint({
        _expectedBias: _intermediateBias[_i - 1],
        _expectedSlope: _slopeB,
        _expectedPermanentLockBalance: _weightPerm,
        _expectedTs: _intermediateTs,
        _globalPoint: votingRewardsManager.globalRewardPointHistory(_priorIndex + _i)
      });
      // it should snapshot the fee accumulators at each new global checkpoint index
      _assertFeeSnapshot(
        _priorIndex + _i,
        _INITIAL_FEE_ACC_0,
        _INITIAL_FEE_ACC_1,
        _INITIAL_FEE_ACC_0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
        _INITIAL_FEE_ACC_1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
      );
      // it should snapshot the supply accumulators at the new global checkpoint index
      (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_priorIndex + _i);
      assertEq(_sharePerVote, _expectedSharePerVote[_i - 1]);
      assertEq(_weightedSharePerVote, _expectedWeightedSharePerVote[_i - 1]);
    }
    _assertGlobalPoint({
      _expectedBias: _finalBias,
      _expectedSlope: _slopeB,
      _expectedPermanentLockBalance: _weightPerm,
      _expectedTs: _advanceTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_newIndex)
    });
    _assertFeeSnapshot(
      _newIndex,
      _INITIAL_FEE_ACC_0,
      _INITIAL_FEE_ACC_1,
      _INITIAL_FEE_ACC_0 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _INITIAL_FEE_ACC_1 * (_initialTs - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
    // it should snapshot the supply accumulators at the new global checkpoint index
    // @dev Final write is the week-3 boundary itself: trailing sub-interval dt=604800,
    //      supply=749_315_076_420_594_069_541 at refTs=2_419_199 on top of +2.
    (_sharePerVote, _weightedSharePerVote) = votingRewardsManager.supplyAccumulatorAt(_newIndex);
    assertEq(_sharePerVote, 2_292_234_789_710_614_320_703_891_018);
    assertEq(_weightedSharePerVote, 4_234_047_510_940_573_402_660_423_429_776_809);
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

  function test_WhenTheElapsedIntervalsHaveZeroSupply()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _initialTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    uint48 _resetTs = _initialTs + 1 days;
    _advanceTs = uint48(ProtocolTimeLibrary.epochNext(_resetTs) + 1 days);

    vm.warp(_initialTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_resetTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    _priorIndex = votingRewardsManager.globalCheckpointIndex();

    vm.warp(_advanceTs);
    vm.prank(users.alice);
    votingRewardsManager.advanceGlobalPoints();

    // it should accumulate zero supply seconds across the elapsed intervals
    assertEq(
      votingRewardsManager.globalRewardPointHistory(votingRewardsManager.globalCheckpointIndex()).zeroSupplySeconds,
      _advanceTs - _resetTs
    );
    assertEq(votingRewardsManager.globalRewardPointHistory(_priorIndex).zeroSupplySeconds, 0);
  }

  function testGas_advanceGlobalPoints()
    external
    whenThereIsAtLeastOnePriorGlobalCheckpoint
    whenTheLatestGlobalPointWasRecordedInAPriorEpoch
  {
    _stakeEndB = 208 weeks;

    // @dev Record a permanent stake for TOKEN_ID_A one second early so the next checkpoint credits fees
    vm.warp(1 weeks - 1);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightPerm, _stakeEnd: 0, _data: ''});

    vm.warp(1 weeks);

    // @dev Simulate gauge fees to advance the accumulator
    _mockGaugePendingFees(_INITIAL_PENDING_0, _INITIAL_PENDING_1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: _stakeEndB, _data: ''});
    vm.stopPrank();

    vm.warp(2 weeks + 1 hours);

    // @dev Increase the gauge fees by `_PENDING_0/1` so the advance credits them
    _mockGaugePendingFees(_INITIAL_PENDING_0 + _PENDING_0, _INITIAL_PENDING_1 + _PENDING_1);

    votingRewardsManager.advanceGlobalPoints();
    vm.snapshotGasLastCall('VotingRewardsManager_advanceGlobalPoints');
  }
}
