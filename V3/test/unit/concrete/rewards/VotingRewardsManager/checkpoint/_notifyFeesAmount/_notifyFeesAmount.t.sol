// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the internal `_notifyFeesAmount` buffering and threshold mechanics.
 * @dev Invoked through the public `checkpoint` entry point.
 *
 *      Entry point wiring is tested separately in the `checkpoint` suite.
 */
contract UnitConcreteVotingRewardsManagerNotifyFeesAmount is UnitVotingRewardsManager {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();
    vm.startPrank(_VOTER);
  }

  function test_WhenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp() external {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

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

  function test_WhenTheBufferIsEmpty()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasNoPendingFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);

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

  function test_WhenTheGaugeIsNotActive()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasNoPendingFees
    whenTheBufferIsNotEmpty
  {
    uint48 _checkpointTs = uint48(1 weeks);
    uint48 _ts = uint48(2 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _buffered0 = 5 * TOKEN_1;
    uint256 _buffered1 = 7 * TOKEN_1;

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

  function test_WhenTheGaugeIsActive()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasNoPendingFees
    whenTheBufferIsNotEmpty
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    // @dev Voting supply must exceed the fee accumulator precision for rounding to leave a nonzero buffered remainder
    uint128 _weight = uint128(1_000_000_000 * TOKEN_1);
    uint256 _notified0 = 5 * TOKEN_1;
    uint256 _notified1 = 7 * TOKEN_1;
    uint256 _remainingBufferedFees = 999;
    uint256 _buffered0 = _notified0 + _remainingBufferedFees;
    uint256 _buffered1 = _notified1 + _remainingBufferedFees;

    // @dev Establish voting supply so the buffered fees clear the credit threshold
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);

    // @dev Initialize the buffered fees as if a residual was left by an earlier fee flush
    _seedBufferedFees(_buffered0, _buffered1);

    // @dev Keep the gauge active so the buffer is flushed instead of preserved
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

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
      _notified0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _notified1 * FEE_ACCUMULATOR_PRECISION / _weight,
      _notified0 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _notified1 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _remainingBufferedFees);
    assertEq(votingRewardsManager.bufferedFees1(), _remainingBufferedFees);
  }

  modifier whenTheGaugeHasPendingFees() {
    _;
  }

  function test_WhenTheGaugeHasNoNewlyAccruedFees()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Establish voting supply ahead of time so the next checkpoint credits the gauge fees
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate gauge fees so the checkpoint credits them and advances the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    (uint256 _feeAcc0, uint256 _feeAcc1, uint256 _feeAcc0xTime, uint256 _feeAcc1xTime) =
      votingRewardsManager.feeRewardPerVotingPower();

    // @dev The gauge fees are unchanged, so the checkpoint has no new accrual to notify
    vm.warp(_ts + 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts + 1);

    // it should skip the fee accumulator update
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0xTime, _feeAcc1xTime);
    assertEq(votingRewardsManager.lastPendingFees0(), _pending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _pending1);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
  }

  modifier whenTheGaugeHasNewlyAccruedFees() {
    _;
  }

  function test_WhenTheTotalSupplyIsZero()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

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

  function test_WhenNoTokenMeetsTheCreditThreshold()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    // @dev Voting supply must exceed the fee accumulator precision so nonzero fees can fall below the credit threshold
    uint128 _weight = uint128(1_000_000_000 * TOKEN_1);
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minPending = _weight / FEE_ACCUMULATOR_PRECISION;
    // @dev Both fees fall below the credit threshold, with `_pending1` at the boundary
    uint256 _pending0 = _minPending / 2;
    uint256 _pending1 = _minPending - 1;

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

  function test_WhenThereAreBufferedFees()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    // @dev Voting supply must exceed the fee accumulator precision for rounding to leave a nonzero buffered remainder
    uint128 _weight = uint128(1_000_000_000 * TOKEN_1);
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minPending = _weight / FEE_ACCUMULATOR_PRECISION;
    // @dev Gauge fees pending at the initial checkpoint
    uint256 _pending0 = _minPending / 2;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Simulate gauge fees ahead of the first checkpoint so they buffer while no voting supply exists
    vm.warp(_ts - 1);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    assertGt(votingRewardsManager.bufferedFees0(), 0);
    assertGt(votingRewardsManager.bufferedFees1(), 0);

    // @dev Increase the gauge fees so the accruals plus the buffered residuals meet the credit threshold
    uint256 _notified0 = _minPending;
    uint256 _notified1 = _pending1 + 20 * TOKEN_1;
    uint256 _remainingBufferedFees = 999;
    uint256 _newPending0 = _notified0 + _remainingBufferedFees;
    uint256 _newPending1 = _notified1 + _remainingBufferedFees;
    vm.warp(_ts);
    _mockGaugePendingFees(_newPending0, _newPending1);

    // it should emit the NotifyFeesAmount event for each qualifying token
    // @dev The buffered residual offsets the last pending fees, so the accrued fees equal the new pending amount
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notified0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notified1);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the accrued fees including the buffered residual
    _assertFeeAccumulator(
      _notified0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _notified1 * FEE_ACCUMULATOR_PRECISION / _weight,
      _notified0 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _notified1 * FEE_ACCUMULATOR_PRECISION / _weight * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _remainingBufferedFees);
    assertEq(votingRewardsManager.bufferedFees1(), _remainingBufferedFees);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _newPending0);
    assertEq(votingRewardsManager.lastPendingFees1(), _newPending1);
  }

  modifier whenThereAreNoBufferedFees() {
    _;
  }

  function test_WhenTheAccruedFeesLeaveNoRoundingRemainder()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
    whenThereAreNoBufferedFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

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

  function test_WhenTheAccruedFeesLeaveARoundingRemainder()
    external
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeHasPendingFees
    whenTheGaugeHasNewlyAccruedFees
    whenTheTotalSupplyIsGreaterThanZero
    whenAtLeastOneTokenMeetsTheCreditThreshold
    whenThereAreNoBufferedFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(100_000_000 * TOKEN_1);
    uint256 _notifiedFees = 150 * USDC_1;
    uint256 _bufferedFees = 99;
    uint256 _pendingFees = _notifiedFees + _bufferedFees;

    // @dev Establish 100 million voting power before the fees accrue
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Simulate 150 USDC plus the largest remainder below the next accumulator increment
    vm.warp(_ts);
    _mockGaugePendingFees(_pendingFees, _pendingFees);

    // it should emit the NotifyFeesAmount event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _notifiedFees);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _notifiedFees);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the rounded down accumulator increment
    // @dev The additional 99 remain below the next accumulator increment, so the increment is 1_500_000
    uint256 _expectedIncrement = 1_500_000;
    _assertFeeAccumulator(
      _expectedIncrement,
      _expectedIncrement,
      _expectedIncrement * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _expectedIncrement * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should buffer the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), _bufferedFees);
    assertEq(votingRewardsManager.bufferedFees1(), _bufferedFees);

    // it should advance the last pending fees to the current pending amount
    assertEq(votingRewardsManager.lastPendingFees0(), _pendingFees);
    assertEq(votingRewardsManager.lastPendingFees1(), _pendingFees);
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
