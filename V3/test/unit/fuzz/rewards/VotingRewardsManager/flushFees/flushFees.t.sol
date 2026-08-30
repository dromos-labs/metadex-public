// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitFuzzVotingRewardsManagerFlushFees is UnitFuzzVotingRewardsManager {
  uint48 internal _flushTs;

  function testFuzz_WhenTheCallerIsNotTheGaugeFactory(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _GAUGE_FACTORY);

    // it should revert with NotGaugeFactory
    vm.expectRevert(IVotingRewardsManager.NotGaugeFactory.selector);
    vm.prank(_caller);
    votingRewardsManager.flushFees();
  }

  modifier whenTheCallerIsTheGaugeFactory() {
    _;
  }

  function testFuzz_WhenTheGaugeFeeCollectionReverts(bytes calldata _revertData)
    external
    whenTheCallerIsTheGaugeFactory
  {
    // @dev Simulate gauge fee collection revert
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), _revertData);

    // it should revert with FeeCollectionFailed
    vm.expectRevert(abi.encodeWithSelector(IVotingRewardsManager.FeeCollectionFailed.selector, _GAUGE));

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();
  }

  modifier whenTheGaugeFeeCollectionSucceeds() {
    _;
  }

  modifier whenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp() {
    _;
  }

  function testFuzz_WhenTheCollectedFeesAreSmallerThanOrEqualToTheLastPendingFees(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1,
    uint256 _collected0,
    uint256 _collected1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    _pending0 = bound(_pending0, 0, type(uint128).max);
    _pending1 = bound(_pending1, 0, type(uint128).max);
    // @dev Both collected fees are capped at the last pending fees, so no new accrual exists
    // @dev Only possible when the collected fees equal the pending fees or zero, but tested defensively
    _collected0 = bound(_collected0, 0, _pending0);
    _collected1 = bound(_collected1, 0, _pending1);

    // @dev Simulate gauge fees and buffer them via an initial checkpoint, advancing the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Collect at most the last pending fees in the same timestamp
    _mockGaugeCollectFees(_collected0, _collected1);

    // it should emit the FeesCollected event for each qualifying token
    if (_collected0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    }
    if (_collected1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);
    }

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should skip the fee buffering
    assertEq(votingRewardsManager.bufferedFees0(), _pending0);
    assertEq(votingRewardsManager.bufferedFees1(), _pending1);

    // @dev The last pending fees are only cleared for tokens with collected fees
    uint256 _lastPending0 = _collected0 > 0 ? 0 : _pending0;
    uint256 _lastPending1 = _collected1 > 0 ? 0 : _pending1;

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), _lastPending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _lastPending1);
  }

  function testFuzz_WhenTheCollectedFeesAreGreaterThanTheLastPendingFees(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1,
    uint256 _collected0,
    uint256 _collected1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Initial fees capped below the maximum so greater collected readings exist
    _pending0 = bound(_pending0, 0, type(uint128).max - 1);
    _pending1 = bound(_pending1, 0, type(uint128).max - 1);
    // @dev At least one token must collect more than the last pending fees, simulating a new accrual
    _collected0 = bound(_collected0, _pending0, type(uint128).max);
    _collected1 = bound(_collected1, _collected0 == _pending0 ? _pending1 + 1 : _pending1, type(uint128).max);

    // @dev Simulate gauge fees and buffer them via an initial checkpoint, advancing the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    _mockGaugeCollectFees(_collected0, _collected1);

    // it should emit the FeesCollected event for each qualifying token
    if (_collected0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    }
    if (_collected1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);
    }

    uint256 _newFees0 = _collected0 - _pending0;
    uint256 _newFees1 = _collected1 - _pending1;
    uint256 _oldBuffer0 = votingRewardsManager.bufferedFees0();
    uint256 _oldBuffer1 = votingRewardsManager.bufferedFees1();

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should buffer the newly accrued fees
    assertEq(votingRewardsManager.bufferedFees0(), _oldBuffer0 + _newFees0);
    assertEq(votingRewardsManager.bufferedFees1(), _oldBuffer1 + _newFees1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  modifier whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp() {
    _;
  }

  modifier whenTheGaugeCollectedNoFees() {
    _;
  }

  function testFuzz_WhenTheBufferIsEmpty(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight,
    uint8 _multiplier0,
    uint8 _multiplier1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Flush strictly after the credit checkpoint at `_ts + 1`
    _flushTs = uint48(bound(_flushTs_, _ts + 2, _ts + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    _multiplier0 = uint8(bound(_multiplier0, 1, type(uint8).max));
    _multiplier1 = uint8(bound(_multiplier1, 1, type(uint8).max));
    // @dev Make each pending amount a whole multiple of the supply so no fees remain after rounding
    uint256 _pending0 = uint256(_weight) * _multiplier0;
    uint256 _pending1 = uint256(_weight) * _multiplier1;

    // @dev Establish voting supply with no pending fees, so the checkpoint only sets the supply
    vm.warp(_ts);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Credit the gauge fees so the last pending fees advance with no buffered residual
    vm.warp(_ts + 1);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    (uint256 _acc0, uint256 _acc1, uint256 _acc0xTime, uint256 _acc1xTime) =
      votingRewardsManager.feeRewardPerVotingPower();
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev The gauge collects no fees in the new timestamp
    vm.warp(_flushTs);
    _mockGaugeCollectFees(0, 0);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _flushTs);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(_acc0, _acc1, _acc0xTime, _acc1xTime);

    // it should skip the global reward checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);

    // it should preserve the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
  }

  modifier whenTheBufferIsNotEmpty() {
    _;
  }

  function testFuzz_WhenTheGaugeIsNotActive(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
    whenTheBufferIsNotEmpty
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _flushTs = uint48(bound(_flushTs_, _ts + 1, _ts + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    _pending0 = bound(_pending0, 0, type(uint128).max);
    // @dev At least one fee must be nonzero so the buffer is not empty
    _pending1 = bound(_pending1, _pending0 == 0 ? 1 : 0, type(uint128).max);

    // @dev Simulate gauge fees and buffer them via an initial checkpoint with no voting supply
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects no fees in the new timestamp
    vm.warp(_flushTs);
    _mockGaugeCollectFees(0, 0);

    // @dev Suspend the gauge so the buffer is preserved instead of flushed
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(uint128(0)));

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _flushTs);

    // it should preserve the buffered fees
    assertEq(votingRewardsManager.bufferedFees0(), _pending0);
    assertEq(votingRewardsManager.bufferedFees1(), _pending1);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should skip the global reward checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);

    // it should preserve the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
  }

  function testFuzz_WhenTheGaugeIsActive(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight,
    uint256 _buffered0,
    uint256 _buffered1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
    whenTheBufferIsNotEmpty
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_ts` sits at the last second of its week (no room for `_flushTs`)
    if (_ts + 1 >= ProtocolTimeLibrary.epochNext(_ts)) {
      _ts = uint48(ProtocolTimeLibrary.epochStart(_ts));
    }
    // @dev Flush within the same epoch so the flush creates exactly one new global point
    _flushTs = uint48(bound(_flushTs_, _ts + 1, ProtocolTimeLibrary.epochNext(_ts) - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minCollected = (uint256(_weight) + FEE_ACCUMULATOR_PRECISION - 1) / FEE_ACCUMULATOR_PRECISION;
    // @dev Both buffered fees clear the threshold so each qualifies for crediting
    _buffered0 = bound(_buffered0, _minCollected, type(uint128).max);
    _buffered1 = bound(_buffered1, _minCollected, type(uint128).max);

    // @dev Establish voting supply with no pending fees, so the checkpoint only sets the supply
    vm.warp(_ts);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Collect in the same block so the fees buffer as a same-block delta with no last pending balance
    _mockGaugeCollectFees(_buffered0, _buffered1);
    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // @dev The same-block collection buffered the fees with no last pending balance
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev The gauge collects no fees but stays active, so the buffer is flushed
    vm.warp(_flushTs);
    _mockGaugeCollectFees(0, 0);
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

    uint256 _feeAcc0 = _buffered0 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _feeAcc1 = _buffered1 * FEE_ACCUMULATOR_PRECISION / _weight;

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 = _ceilDiv(_feeAcc0 * _weight, FEE_ACCUMULATOR_PRECISION);
      uint256 _notified1 = _ceilDiv(_feeAcc1 * _weight, FEE_ACCUMULATOR_PRECISION);

      // it should emit the NotifyFeesAmount event for each qualifying token
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      _expectEmit(address(votingRewardsManager));
      emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
    }

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _flushTs);

    // it should credit the buffered fees to the fee accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_flushTs - _origin), _feeAcc1 * (_flushTs - _origin));

    // it should retain only the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0 - _ceilDiv(_feeAcc0 * _weight, FEE_ACCUMULATOR_PRECISION));
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1 - _ceilDiv(_feeAcc1 * _weight, FEE_ACCUMULATOR_PRECISION));

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _flushTs);
  }

  modifier whenTheGaugeCollectedFees() {
    _;
  }

  function testFuzz_WhenTheCollectedFeesDoNotMeetTheCreditThreshold(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1,
    uint256 _collected0,
    uint256 _collected1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _flushTs = uint48(bound(_flushTs_, _ts + 1, _ts + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Lower bound guarantees nonzero fees below the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply` exist
    _weight = uint120(bound(_weight, FEE_ACCUMULATOR_PRECISION + 1, type(uint120).max));
    // @dev Compute the minimum fees that meet the credit threshold
    uint256 _minCollected = (uint256(_weight) + FEE_ACCUMULATOR_PRECISION - 1) / FEE_ACCUMULATOR_PRECISION;
    // @dev Both collected fees fall below the credit threshold
    _collected0 = bound(_collected0, 0, _minCollected - 1);
    // @dev At least one of the fees must be nonzero so the notify is not skipped
    _collected1 = bound(_collected1, _collected0 == 0 ? 1 : 0, _minCollected - 1);
    // @dev Prior gauge readings never exceed the collected amounts
    _pending0 = bound(_pending0, 0, _collected0);
    _pending1 = bound(_pending1, 0, _collected1);

    // @dev Buffer the gauge fees via an initial checkpoint that also establishes the voting supply
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects fees below the credit threshold in the new timestamp
    vm.warp(_flushTs);
    _mockGaugeCollectFees(_collected0, _collected1);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should emit the FeesCollected event for each qualifying token
    if (_collected0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    }
    if (_collected1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);
    }

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should buffer the collected fees
    assertEq(votingRewardsManager.bufferedFees0(), _collected0);
    assertEq(votingRewardsManager.bufferedFees1(), _collected1);
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should skip the global reward checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  modifier whenTheCollectedFeesMeetTheCreditThreshold() {
    _;
  }

  function testFuzz_WhenTheAccumulatorIncreaseRepresentsAtLeastTheSmallestTokenUnit(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1,
    uint256 _collected0,
    uint256 _collected1
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
    whenTheCollectedFeesMeetTheCreditThreshold
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_ts` sits at the last second of its week (no room for `_flushTs`)
    if (_ts + 1 >= ProtocolTimeLibrary.epochNext(_ts)) {
      _ts = uint48(ProtocolTimeLibrary.epochStart(_ts));
    }
    // @dev Flush within the same epoch so the flush creates exactly one new global point
    _flushTs = uint48(bound(_flushTs_, _ts + 1, ProtocolTimeLibrary.epochNext(_ts) - 1));
    // @dev Lower bound guarantees an accumulator increase represents at least the smallest fee unit
    _weight = uint120(bound(_weight, FEE_ACCUMULATOR_PRECISION, type(uint120).max));
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minCollected = (uint256(_weight) + FEE_ACCUMULATOR_PRECISION - 1) / FEE_ACCUMULATOR_PRECISION;
    // @dev Ensure at least one token qualifies for the fee distribution
    _collected0 = bound(_collected0, 0, type(uint128).max);
    _collected1 = bound(_collected1, _collected0 < _minCollected ? _minCollected : 0, type(uint128).max);
    assertTrue(_collected0 >= _minCollected || _collected1 >= _minCollected);
    // @dev Prior gauge readings never exceed the collected amounts
    _pending0 = bound(_pending0, 0, _collected0);
    _pending1 = bound(_pending1, 0, _collected1);

    // @dev Buffer the gauge fees via an initial checkpoint that also establishes the voting supply
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects fees that can meet the credit threshold in the new timestamp
    vm.warp(_flushTs);
    _mockGaugeCollectFees(_collected0, _collected1);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should emit the FeesCollected event for each qualifying token
    if (_collected0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    }
    if (_collected1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);
    }

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // @dev Fees are credited to the accumulator when the token qualifies, and buffered otherwise
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    uint256 _feeAcc0 = _collected0 >= _minCollected ? _collected0 * FEE_ACCUMULATOR_PRECISION / _weight : 0;
    uint256 _feeAcc1 = _collected1 >= _minCollected ? _collected1 * FEE_ACCUMULATOR_PRECISION / _weight : 0;
    // @dev Compute the rounding remainder retained after each qualifying accumulator increase
    uint256 _buffered0 = _collected0 >= _minCollected
      ? _collected0 - _ceilDiv(_feeAcc0 * _weight, FEE_ACCUMULATOR_PRECISION)
      : _collected0;
    uint256 _buffered1 = _collected1 >= _minCollected
      ? _collected1 - _ceilDiv(_feeAcc1 * _weight, FEE_ACCUMULATOR_PRECISION)
      : _collected1;

    // it should credit the collected fees to the fee accumulator
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_flushTs - _origin), _feeAcc1 * (_flushTs - _origin));
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _flushTs);

    // it should snapshot the fee accumulator at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_flushTs - _origin), _feeAcc1 * (_flushTs - _origin));

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  function testFuzz_WhenTheAccumulatorIncreaseRepresentsLessThanTheSmallestTokenUnit(
    uint48 _ts,
    uint48 _flushTs_,
    uint120 _weight
  )
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
    whenTheCollectedFeesMeetTheCreditThreshold
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Snap to epoch start when `_ts` sits at the last second of its week (no room for `_flushTs`)
    if (_ts + 1 >= ProtocolTimeLibrary.epochNext(_ts)) {
      _ts = uint48(ProtocolTimeLibrary.epochStart(_ts));
    }
    // @dev Flush within the same epoch so the flush creates exactly one new global point
    _flushTs = uint48(bound(_flushTs_, _ts + 1, ProtocolTimeLibrary.epochNext(_ts) - 1));
    // @dev Fuzz `_weight` between half and all of `FEE_ACCUMULATOR_PRECISION` so one fee unit increases the accumulator
    //      by exactly one while `_weight * increment / FEE_ACCUMULATOR_PRECISION` rounds down to zero
    _weight = uint120(bound(_weight, FEE_ACCUMULATOR_PRECISION / 2 + 1, FEE_ACCUMULATOR_PRECISION - 1));
    uint256 _collectedFees = 1;
    uint256 _expectedIncrement = 1;

    // @dev Establish the voting supply before collecting one unit of each fee token
    vm.warp(_ts);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_flushTs);
    _mockGaugeCollectFees(_collectedFees, _collectedFees);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should emit the NotifyFeesAmount event with an amount of one
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _collectedFees);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _collectedFees);

    // it should emit the FeesCollected event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collectedFees);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collectedFees);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should increase each fee accumulator by one
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(
      _expectedIncrement,
      _expectedIncrement,
      _expectedIncrement * (_flushTs - _origin),
      _expectedIncrement * (_flushTs - _origin)
    );

    // it should leave no fees buffered
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _flushTs);

    // it should snapshot the fee accumulator at the new global checkpoint index
    _assertFeeSnapshot(
      _newIndex,
      _expectedIncrement,
      _expectedIncrement,
      _expectedIncrement * (_flushTs - _origin),
      _expectedIncrement * (_flushTs - _origin)
    );

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  /**
   * @notice Mock and expect a call to `IGauge.collectFees()` returning the given amounts
   * @param _amount0 Collected token0 fees
   * @param _amount1 Collected token1 fees
   */
  function _mockGaugeCollectFees(uint256 _amount0, uint256 _amount1) internal {
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_amount0, _amount1));
  }
}
