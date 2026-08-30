// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_notifyFeesAmount` buffering and threshold mechanics.
 * @dev Invoked through the public `checkpoint` entry point.
 *
 *      Entry point wiring is tested separately in the `checkpoint` suite.
 */
contract UnitFuzzVotingRewardsManagerNotifyFeesAmount is UnitFuzzVotingRewardsManager {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function testFuzz_WhenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0
  ) external {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Lower bound guarantees the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply` is met for both tokens
    _pending0 = bound(_pending0, uint256(_weight) / FEE_ACCUMULATOR_PRECISION + 1, type(uint128).max);
    uint256 _pending1 = _pending0 * 2;

    // @dev Set lastFeeUpdate to the current timestamp via an initial checkpoint
    vm.warp(_ts);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate gauge fees so a non-skipped notify would credit them
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_pending0, _pending1));
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
  }

  modifier whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp() {
    _;
  }

  modifier whenTheGaugeHasNoPendingFees() {
    _;
  }

  function testFuzz_WhenTheBufferIsEmpty(
    uint48 _ts,
    uint120 _weight
  ) external whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp whenTheGaugeHasNoPendingFees {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));

    // @dev The gauge reports no pending fees and no fees are buffered
    vm.warp(_ts);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  modifier whenTheBufferIsNotEmpty() {
    _;
  }

  function testFuzz_WhenTheGaugeIsNotActive(
    uint48 _ts,
    uint120 _weight,
    uint256 _buffered0
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasNoPendingFees
    whenTheBufferIsNotEmpty
  {
    _ts = uint48(bound(_ts, 2 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    uint48 _checkpointTs = _ts - 1 weeks;
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Lower bound guarantees the buffer would be creditable were the gauge active
    _buffered0 = bound(_buffered0, uint256(_weight) / FEE_ACCUMULATOR_PRECISION + 1, type(uint128).max);
    uint256 _buffered1 = _buffered0 * 2;

    // @dev Establish voting supply while the gauge is still active
    vm.warp(_checkpointTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Initialize the buffered fees as if a residual was left by an earlier fee flush
    _seedBufferedFees(_buffered0, _buffered1);

    // @dev Suspend the gauge so the buffer is preserved instead of flushed
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(uint128(0)));

    // @dev Advance global points after deactivation without checkpointing the gauge
    votingRewardsManager.advanceGlobalPoints();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should preserve the buffered fees
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  function testFuzz_WhenTheGaugeIsActive(
    uint48 _ts,
    uint120 _weight,
    uint256 _buffered0
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasNoPendingFees
    whenTheBufferIsNotEmpty
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Lower bound guarantees the buffer clears the credit threshold for both tokens
    _buffered0 = bound(_buffered0, uint256(_weight) / FEE_ACCUMULATOR_PRECISION + 1, type(uint128).max);
    uint256 _buffered1 = _buffered0 * 2;

    // @dev Establish voting supply so the buffered fees clear the credit threshold
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Initialize the buffered fees as if a residual was left by an earlier fee flush
    _seedBufferedFees(_buffered0, _buffered1);

    // @dev Keep the gauge active so the buffer is flushed instead of preserved
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

    // @dev Compute the rounded-up fee amount represented by each accumulator increment
    uint256 _notified0 =
      _ceilDiv((_buffered0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
    uint256 _notified1 =
      _ceilDiv((_buffered1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);

    // it should emit the NotifyFeesAmount event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the buffered fees to the accumulator
    _assertFeeAccumulator(
      _buffered0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _buffered1 * FEE_ACCUMULATOR_PRECISION / _weight,
      _buffered0 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _buffered1 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0 - _notified0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1 - _notified1);
  }

  modifier whenTheGaugeHasPendingFees() {
    _;
  }

  function testFuzz_WhenTheGaugeHasNoNewlyAccruedFees(
    uint48 _ts,
    uint48 _advanceTs,
    uint120 _weight,
    uint256 _pending0
  ) external whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp whenTheGaugeHasPendingFees {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _advanceTs = uint48(bound(_advanceTs, _ts + 1, _ts + MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Lower bound guarantees the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply` is met for both tokens
    _pending0 = bound(_pending0, uint256(_weight) / FEE_ACCUMULATOR_PRECISION + 1, type(uint128).max);
    uint256 _pending1 = _pending0 * 2;

    // @dev Establish voting supply ahead of time so the next checkpoint credits the gauge fees
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate gauge fees so the checkpoint credits them and advances the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    uint256 _buffered0 = votingRewardsManager.bufferedFees0();
    uint256 _buffered1 = votingRewardsManager.bufferedFees1();
    (uint256 _feeAcc0, uint256 _feeAcc1, uint256 _feeAcc0xTime, uint256 _feeAcc1xTime) =
      votingRewardsManager.feeRewardPerVotingPower();

    // @dev The gauge fees are unchanged, so the checkpoint has no new accrual to notify
    vm.warp(_advanceTs);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _advanceTs);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0xTime, _feeAcc1xTime);
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);
  }

  modifier whenTheGaugeHasNewlyAccruedFees() {
    _;
  }

  function testFuzz_WhenTheTotalSupplyIsZero(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev No supply exists yet, so any nonzero fees are buffered regardless of the credit threshold
    _pending0 = bound(_pending0, 0, type(uint128).max);
    // @dev At least one of the fees must be nonzero so the notify is not skipped
    _pending1 = bound(_pending1, _pending0 == 0 ? 1 : 0, type(uint128).max);

    // @dev Simulate gauge fees ahead of the first checkpoint, when no voting supply exists yet
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);

    // it should buffer the accrued fees
    assertEq(votingRewardsManager.bufferedFees0(), _pending0);
    assertEq(votingRewardsManager.bufferedFees1(), _pending1);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);
  }

  modifier whenTheTotalSupplyIsGreaterThanZero() {
    _;
  }

  function testFuzz_WhenNoTokenMeetsTheCreditThreshold(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    // @dev Supply must exceed one million voting power for a nonzero fee amount to remain below the credit threshold
    _weight = uint120(bound(_weight, 1_000_000 * TOKEN_1 + 1, type(uint120).max));
    // @dev Compute the minimum fees that meet the credit threshold
    uint256 _minPending = (uint256(_weight) + FEE_ACCUMULATOR_PRECISION - 1) / FEE_ACCUMULATOR_PRECISION;
    // @dev Both fees fall below the credit threshold
    _pending0 = bound(_pending0, 0, _minPending - 1);
    // @dev At least one of the fees must be nonzero so the notify is not skipped
    _pending1 = bound(_pending1, _pending0 == 0 ? 1 : 0, _minPending - 1);

    // @dev Establish voting supply ahead of time so the credit threshold is enforced against it
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate gauge fees below the credit threshold
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);

    // it should buffer the accrued fees
    assertEq(votingRewardsManager.bufferedFees0(), _pending0);
    assertEq(votingRewardsManager.bufferedFees1(), _pending1);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);
  }

  modifier whenAtLeastOneTokenMeetsTheCreditThreshold() {
    _;
  }

  function testFuzz_WhenThereAreBufferedFees(
    uint48 _ts,
    uint120 _weight,
    uint256 _pending0,
    uint256 _pending1,
    uint256 _newPending0,
    uint256 _newPending1
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
  {
    _ts = uint48(bound(_ts, block.timestamp + 1, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minPending = (uint256(_weight) + FEE_ACCUMULATOR_PRECISION - 1) / FEE_ACCUMULATOR_PRECISION;
    // @dev Initial fees capped at `_minPending` so the increased readings stay above them
    _pending0 = bound(_pending0, 0, _minPending);
    // @dev At least one of the fees must be nonzero so the first checkpoint buffers them
    _pending1 = bound(_pending1, _pending0 == 0 ? 1 : 0, _minPending);
    // @dev Ensure at least one token qualifies for the fee distribution
    _newPending0 = bound(_newPending0, _pending0, type(uint128).max);
    _newPending1 = bound(_newPending1, _newPending0 < _minPending ? _minPending : _pending1, type(uint128).max);
    assertTrue(_newPending0 >= _minPending || _newPending1 >= _minPending);

    // @dev Simulate gauge fees ahead of the first checkpoint so they buffer while no voting supply exists
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Increase the gauge fees so the accruals plus the buffered residuals can meet the credit threshold
    vm.warp(_ts);
    _mockGaugePendingFees(_newPending0, _newPending1);

    {
      // @dev Compute the rounded-up fee amount represented by each accumulator increment
      uint256 _notified0 = _newPending0 >= _minPending
        ? _ceilDiv((_newPending0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION)
        : 0;
      uint256 _notified1 = _newPending1 >= _minPending
        ? _ceilDiv((_newPending1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION)
        : 0;

      // it should emit the NotifyFeesAmount event for each qualifying token
      // @dev The buffered residual offsets the last pending fees, so the accrued fees equal the new pending amount
      if (_newPending0 >= _minPending) {
        _expectEmit(address(votingRewardsManager));
        emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
      }
      if (_newPending1 >= _minPending) {
        _expectEmit(address(votingRewardsManager));
        emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);
      }
    }

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // @dev Fees advance the accumulator when the token qualifies, with any rounding remainder buffered
    uint256 _feeAcc0 = _newPending0 >= _minPending ? _newPending0 * FEE_ACCUMULATOR_PRECISION / _weight : 0;
    uint256 _feeAcc1 = _newPending1 >= _minPending ? _newPending1 * FEE_ACCUMULATOR_PRECISION / _weight : 0;
    // @dev Subtract the rounded-up notified amount to retain the rounding remainder
    uint256 _buffered0 = _newPending0 >= _minPending
      ? _newPending0 - _ceilDiv(_feeAcc0 * _weight, FEE_ACCUMULATOR_PRECISION)
      : _newPending0;
    uint256 _buffered1 = _newPending1 >= _minPending
      ? _newPending1 - _ceilDiv(_feeAcc1 * _weight, FEE_ACCUMULATOR_PRECISION)
      : _newPending1;

    // it should credit the accrued fees including the buffered residual
    _assertFeeAccumulator(
      _feeAcc0,
      _feeAcc1,
      _feeAcc0 * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _feeAcc1 * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _newPending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _newPending1);
  }

  modifier whenThereAreNoBufferedFees() {
    _;
  }

  function testFuzz_WhenTheAccruedFeesLeaveNoRoundingRemainder(
    uint48 _ts,
    uint120 _weight,
    uint8 _multiplier0,
    uint8 _multiplier1
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
    whenThereAreNoBufferedFees
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    _weight = uint120(bound(_weight, MAX_TIME, type(uint120).max));
    _multiplier0 = uint8(bound(_multiplier0, 1, type(uint8).max));
    _multiplier1 = uint8(bound(_multiplier1, 1, type(uint8).max));
    // @dev Make each pending amount a whole multiple of the supply so no fees remain after rounding
    uint256 _pending0 = uint256(_weight) * _multiplier0;
    uint256 _pending1 = uint256(_weight) * _multiplier1;

    // @dev Establish voting supply ahead of time so the next checkpoint credits the gauge fees
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate gauge fees so the checkpoint credits them
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);

    // it should emit the NotifyFeesAmount event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _pending0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _pending1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the accrued fees to the accumulator
    _assertFeeAccumulator(
      _pending0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _pending1 * FEE_ACCUMULATOR_PRECISION / _weight,
      _pending0 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _pending1 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should leave no fees buffered
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
  }

  function testFuzz_WhenTheAccruedFeesLeaveARoundingRemainder(
    uint48 _ts,
    uint8 _increment0,
    uint8 _increment1,
    uint256 _bufferedFees0,
    uint256 _bufferedFees1
  )
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
    whenThereAreNoBufferedFees
  {
    _ts = uint48(bound(_ts, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks - 1));
    uint128 _weight = uint128(100_000_000 * TOKEN_1);
    _increment0 = uint8(bound(_increment0, 1, type(uint8).max));
    _increment1 = uint8(bound(_increment1, 1, type(uint8).max));
    uint256 _feesPerIncrement = uint256(_weight) / FEE_ACCUMULATOR_PRECISION;
    _bufferedFees0 = bound(_bufferedFees0, 1, _feesPerIncrement - 1);
    _bufferedFees1 = bound(_bufferedFees1, 1, _feesPerIncrement - 1);
    uint256 _notifiedFees0 = uint256(_increment0) * _feesPerIncrement;
    uint256 _notifiedFees1 = uint256(_increment1) * _feesPerIncrement;
    uint256 _pendingFees0 = _notifiedFees0 + _bufferedFees0;
    uint256 _pendingFees1 = _notifiedFees1 + _bufferedFees1;

    // @dev Establish 100 million voting power before the fees accrue
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate pending fees that leave a remainder below the next accumulator increment
    vm.warp(_ts);
    _mockGaugePendingFees(_pendingFees0, _pendingFees1);

    // it should emit the NotifyFeesAmount event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notifiedFees0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notifiedFees1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the rounded down accumulator increment
    _assertFeeAccumulator(
      _increment0,
      _increment1,
      uint256(_increment0) * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      uint256(_increment1) * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _bufferedFees0);
    assertEq(votingRewardsManager.bufferedFees1(), _bufferedFees1);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _pendingFees0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pendingFees1);
  }

  /**
   * @notice Simulate a residual left by an earlier fee flush by overwriting the buffered fees
   * @param _amount0 Buffered token0 fees
   * @param _amount1 Buffered token1 fees
   */
  function _seedBufferedFees(uint256 _amount0, uint256 _amount1) internal {
    stdstore.target(address(votingRewardsManager)).sig('bufferedFees0()').checked_write(_amount0);
    stdstore.target(address(votingRewardsManager)).sig('bufferedFees1()').checked_write(_amount1);
  }
}
