// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitConcreteVotingRewardsManagerFlushFees is UnitVotingRewardsManager {
  function test_WhenTheCallerIsNotTheGaugeFactory() external {
    // it should revert with NotGaugeFactory
    vm.expectRevert(IVotingRewardsManager.NotGaugeFactory.selector);
    vm.prank(users.charlie);
    votingRewardsManager.flushFees();
  }

  modifier whenTheCallerIsTheGaugeFactory() {
    _;
  }

  function test_WhenTheGaugeFeeCollectionReverts() external whenTheCallerIsTheGaugeFactory {
    // @dev Simulate gauge fee collection revert
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), '');

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

  function test_WhenTheCollectedFeesAreSmallerThanOrEqualToTheLastPendingFees()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Simulate gauge fees and buffer them via an initial checkpoint, advancing the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Collect exactly the last pending fees in the same timestamp, so no new accrual exists
    _mockGaugeCollectFees(_pending0, _pending1);

    // it should emit the FeesCollected event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _pending0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _pending1);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should skip the fee accumulator update
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should skip the fee buffering
    assertEq(votingRewardsManager.bufferedFees0(), _pending0);
    assertEq(votingRewardsManager.bufferedFees1(), _pending1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  function test_WhenTheCollectedFeesAreGreaterThanTheLastPendingFees()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Simulate gauge fees and buffer them via an initial checkpoint, advancing the last pending fees
    vm.warp(_ts);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Collect more than the last pending fees in the same timestamp, simulating a new accrual
    uint256 _newFees0 = 2 * TOKEN_1;
    uint256 _newFees1 = 3 * TOKEN_1;
    uint256 _collected0 = _pending0 + _newFees0;
    uint256 _collected1 = _pending1 + _newFees1;
    _mockGaugeCollectFees(_collected0, _collected1);

    // it should emit the FeesCollected event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);

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

  function test_WhenTheBufferIsEmpty()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Establish voting supply so the following checkpoint credits the fees, leaving an empty buffer
    vm.warp(_ts - 2);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Credit the gauge fees so the last pending fees advance with no buffered residual
    vm.warp(_ts - 1);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    (uint256 _acc0, uint256 _acc1, uint256 _acc0xTime, uint256 _acc1xTime) =
      votingRewardsManager.feeRewardPerVotingPower();
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev The gauge collects no fees in the new timestamp
    vm.warp(_ts);
    _mockGaugeCollectFees(0, 0);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

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

  function test_WhenTheGaugeIsNotActive()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
    whenTheBufferIsNotEmpty
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Simulate gauge fees and buffer them via an initial checkpoint with no voting supply
    vm.warp(_ts - 1);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects no fees in the new timestamp
    vm.warp(_ts);
    _mockGaugeCollectFees(0, 0);

    // @dev Suspend the gauge so the buffer is preserved instead of flushed
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(uint128(0)));

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

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

  function test_WhenTheGaugeIsActive()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedNoFees
    whenTheBufferIsNotEmpty
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _buffered0 = 5 * TOKEN_1;
    uint256 _buffered1 = 7 * TOKEN_1;

    // @dev Establish voting supply with no pending fees, so the checkpoint only sets the supply
    vm.warp(_ts - 1);
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
    vm.warp(_ts);
    _mockGaugeCollectFees(0, 0);
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

    // it should emit the NotifyFeesAmount event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _buffered0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _buffered1);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should set lastFeeUpdate to the current timestamp
    assertEq(votingRewardsManager.lastFeeUpdate(), _ts);

    // it should credit the buffered fees to the fee accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    uint256 _feeAcc0 = _buffered0 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _feeAcc1 = _buffered1 * FEE_ACCUMULATOR_PRECISION / _weight;
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_ts - _origin), _feeAcc1 * (_ts - _origin));

    // it should retain only the rounding remainder
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _ts);
  }

  modifier whenTheGaugeCollectedFees() {
    _;
  }

  function test_WhenTheCollectedFeesDoNotMeetTheCreditThreshold()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    // @dev Use supply above the fee accumulator precision so the test can collect fees without increasing the accumulator
    uint128 _weight = uint128(1_000_000_000 * TOKEN_1);
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minCollected = _weight / FEE_ACCUMULATOR_PRECISION;
    // @dev Both collected fees fall below the credit threshold, with `_collected1` at the boundary
    uint256 _collected0 = _minCollected / 2;
    uint256 _collected1 = _minCollected - 1;

    // @dev Establish voting supply ahead of time so the credit threshold is enforced against it
    vm.warp(_ts - 1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects fees below the credit threshold in the new timestamp
    vm.warp(_ts);
    _mockGaugeCollectFees(_collected0, _collected1);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should emit the FeesCollected event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);

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

  function test_WhenTheAccumulatorIncreaseRepresentsAtLeastTheSmallestTokenUnit()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
    whenTheCollectedFeesMeetTheCreditThreshold
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    // @dev Increase the voting supply to test the credit threshold for a high-supply gauge
    uint128 _weight = uint128(500_000_000 * TOKEN_1);
    // @dev Compute the minimum fees that meet the credit threshold `fees * FEE_ACCUMULATOR_PRECISION >= totalSupply`
    uint256 _minCollected = _weight / FEE_ACCUMULATOR_PRECISION;
    uint256 _collected0 = _minCollected;
    uint256 _collected1 = 7 * TOKEN_1;

    // @dev Establish voting supply ahead of time so the credit threshold is enforced against it
    vm.warp(_ts - 1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects fees above the credit threshold in the new timestamp
    vm.warp(_ts);
    _mockGaugeCollectFees(_collected0, _collected1);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should emit the FeesCollected event for each qualifying token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // it should credit the collected fees to the fee accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    uint256 _feeAcc0 = _collected0 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _feeAcc1 = _collected1 * FEE_ACCUMULATOR_PRECISION / _weight;
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_ts - _origin), _feeAcc1 * (_ts - _origin));
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _ts);

    // it should snapshot the fee accumulator at the new global checkpoint index
    _assertFeeSnapshot(_newIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_ts - _origin), _feeAcc1 * (_ts - _origin));

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  function test_WhenTheAccumulatorIncreaseRepresentsLessThanTheSmallestTokenUnit()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
    whenTheCollectedFeesMeetTheCreditThreshold
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint256 _collectedFees = 1;
    uint256 _expectedIncrement = 1;

    // @dev Establish supply at three quarters of `FEE_ACCUMULATOR_PRECISION` so one fee unit increases the accumulator by one
    uint128 _weight = uint128(3 * 1_000_000 * TOKEN_1 / 4);
    vm.warp(_ts - 1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);
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
      _expectedIncrement, _expectedIncrement, _expectedIncrement * (_ts - _origin), _expectedIncrement * (_ts - _origin)
    );

    // it should leave no fees buffered
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);

    // it should create a new global reward point
    uint256 _newIndex = _globalIndex + 1;
    assertEq(votingRewardsManager.globalCheckpointIndex(), _newIndex);
    assertEq(votingRewardsManager.globalRewardPointHistory(_newIndex).ts, _ts);

    // it should snapshot the fee accumulator at the new global checkpoint index
    _assertFeeSnapshot(
      _newIndex,
      _expectedIncrement,
      _expectedIncrement,
      _expectedIncrement * (_ts - _origin),
      _expectedIncrement * (_ts - _origin)
    );

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
  }

  function testGas_flushFees()
    external
    whenTheCallerIsTheGaugeFactory
    whenTheGaugeFeeCollectionSucceeds
    whenTheFeeAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheGaugeCollectedFees
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _collected0 = 5 * TOKEN_1;
    uint256 _collected1 = 7 * TOKEN_1;

    // @dev Establish voting supply ahead of time so the credit threshold is enforced against it
    vm.warp(_ts - 1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge collects fees above the credit threshold in the new timestamp
    vm.warp(_ts);
    _mockGaugeCollectFees(_collected0, _collected1);

    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();
    vm.snapshotGasLastCall('VotingRewardsManager_flushFees');
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
