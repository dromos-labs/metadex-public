// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeDeposit is UnitV2Gauge {
  function setUp() public override {
    super.setUp();

    vm.warp(1 weeks);
  }

  function test_WhenTheAmountIsZero(address _caller) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAmount
    vm.expectRevert(IV2Gauge.ZeroAmount.selector);
    _gauge.deposit(0);
  }

  modifier whenTheAmountIsNotZero() {
    _;
  }

  modifier whenUnusedEmissionsAreZero() {
    _;
  }

  function test_WhenTheRewardParametersAreKnown() external whenTheAmountIsNotZero whenUnusedEmissionsAreZero {
    uint256 _amount = 100 * TOKEN_1;
    uint256 _previousBalance = 250 * TOKEN_1;
    uint256 _previousTotalSupply = 1000 * TOKEN_1;

    _seedBalance(users.alice, _previousBalance);
    _seedTotalSupply(_previousTotalSupply);

    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // it should pull staking tokens from the caller
    _expectDepositTransfer(users.alice, _amount);
    // it should request a voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    // @dev Reward per token: 6 tokens cumulative delta * PRECISION / 1,000 tokens = 0.006e18.
    uint256 _expectedRewardPerTokenStored = 6_000_000_000_000_000;
    // @dev Caller rewards: 250 tokens * 0.006e18 / PRECISION = 1.5 tokens.
    uint256 _expectedRewards = 1.5 ether;

    vm.prank(users.alice);
    // it should emit the Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(users.alice, users.alice, _amount);
    _gauge.deposit(_amount);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the caller's rewards before the deposit
    assertEq(_gauge.rewards(users.alice), _expectedRewards);
    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _expectedRewardPerTokenStored);
    // it should credit the caller balance
    assertEq(_gauge.balanceOf(users.alice), _previousBalance + _amount);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _previousTotalSupply + _amount);
    // it should update the caller's deposit block
    assertEq(_gauge.depositBlock(users.alice), block.number);
  }

  function test_WhenTheRewardParametersVary(
    uint256 _amount,
    uint256 _previousBalance,
    uint256 _previousTotalSupply,
    uint128 _rewardRate,
    uint48 _elapsed
  ) external whenTheAmountIsNotZero whenUnusedEmissionsAreZero {
    _amount = bound(_amount, 1, type(uint128).max);
    _previousTotalSupply = bound(_previousTotalSupply, 1, type(uint128).max);
    _previousBalance = bound(_previousBalance, 0, _previousTotalSupply);
    _rewardRate = uint128(bound(_rewardRate, 0, 100 ether));
    _elapsed = uint48(bound(_elapsed, 0, 30 days));

    _seedBalance(users.alice, _previousBalance);
    _seedTotalSupply(_previousTotalSupply);

    // @dev Cumulative delta equivalent to the realized emissions over the elapsed window.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;

    // it should pull staking tokens from the caller
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (users.alice, address(_gauge), _amount)), abi.encode(true)
    );
    // it should request a voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    uint256 _expectedRewardPerTokenStored = (_cumulativeRewardShare * PRECISION) / _previousTotalSupply;
    uint256 _expectedRewards = (_previousBalance * _expectedRewardPerTokenStored) / PRECISION;

    vm.prank(users.alice);
    // it should emit the Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(users.alice, users.alice, _amount);
    _gauge.deposit(_amount);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the caller's rewards before the deposit
    assertEq(_gauge.rewards(users.alice), _expectedRewards);
    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _expectedRewardPerTokenStored);
    // it should credit the caller balance
    assertEq(_gauge.balanceOf(users.alice), _previousBalance + _amount);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _previousTotalSupply + _amount);
    // it should update the caller's deposit block
    assertEq(_gauge.depositBlock(users.alice), block.number);
  }

  function test_WhenUnusedEmissionsAreGreaterThanZero(
    address _caller,
    uint256 _amount,
    uint256 _previousRewards,
    uint128 _rewardRate,
    uint48 _elapsed
  ) external whenTheAmountIsNotZero {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _seedRewards(_caller, _previousRewards);
    _rewardRate = uint128(bound(_rewardRate, 1, 100 ether));
    _elapsed = uint48(bound(_elapsed, 1 seconds, 30 days));

    // @dev No stakers over the pulled span, so the cumulative delta cannot be distributed and is forfeited.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;
    uint128 _expectedUnusedEmissions = uint128(_cumulativeRewardShare);
    uint256 _rewardPerTokenStored = _gauge.rewardPerTokenStored();

    // it should pull staking tokens from the caller
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    // it should request a voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    // it should forfeit unused emissions
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.forfeitEmissions, (_expectedUnusedEmissions)), '');

    vm.prank(_caller);
    // it should emit the Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(_caller, _caller, _amount);
    _gauge.deposit(_amount);

    // it should leave reward per token unchanged
    assertEq(_gauge.rewardPerTokenStored(), _rewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should leave the caller's rewards unchanged
    assertEq(_gauge.rewards(_caller), _previousRewards);
    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), _rewardPerTokenStored);
    // it should credit the caller balance
    assertEq(_gauge.balanceOf(_caller), _amount);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _amount);
    // it should update the caller's deposit block
    assertEq(_gauge.depositBlock(_caller), block.number);
  }

  function testGas_deposit() external whenTheAmountIsNotZero whenUnusedEmissionsAreZero {
    uint256 _amount = 100 * TOKEN_1;
    uint256 _previousBalance = 250 * TOKEN_1;
    uint256 _previousTotalSupply = 1000 * TOKEN_1;

    _seedBalance(users.alice, _previousBalance);
    _seedTotalSupply(_previousTotalSupply);

    _expectDepositTransfer(users.alice, _amount);
    _expectSettleGauge(6 ether);

    vm.prank(users.alice);
    _gauge.deposit(_amount);
    vm.snapshotGasLastCall('V2Gauge_deposit');
  }

  function testGas_deposit_forfeit() external whenTheAmountIsNotZero {
    uint256 _amount = 100 * TOKEN_1;
    uint256 _previousRewards = 2 ether;

    _seedRewards(users.alice, _previousRewards);

    // @dev No stakers over the pulled span, so the whole cumulative delta is forfeited.
    uint256 _cumulativeRewardShare = 6 ether;
    uint128 _expectedUnusedEmissions = uint128(_cumulativeRewardShare);

    _expectDepositTransfer(users.alice, _amount);
    _expectSettleGauge(_cumulativeRewardShare);
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.forfeitEmissions, (_expectedUnusedEmissions)), '');

    vm.prank(users.alice);
    _gauge.deposit(_amount);
    vm.snapshotGasLastCall('V2Gauge_deposit_forfeit');
  }

  function test_WhenTheFirstDepositLandsOnAnEmptyGaugeAndAStakerFollows(
    uint256 _amount,
    uint128 _emptySpan,
    uint128 _stakedSpan
  ) external whenTheAmountIsNotZero {
    _amount = bound(_amount, 1, type(uint128).max);
    // @dev The empty-span accrual is forfeited whole, so it must fit the uint128 forfeit cast.
    _emptySpan = uint128(bound(_emptySpan, 1, type(uint128).max));
    // @dev The staked-span increment folds into rewards; keep it small enough to avoid the mint cast overflow.
    _stakedSpan = uint128(bound(_stakedSpan, 1, 1_000_000 * TOKEN_1));

    // @dev Phase 1: the gauge is empty, so the first pull's accrual cannot be distributed and is forfeited.
    uint256 _firstCumulative = _emptySpan;

    // it should forfeit the emissions accrued while the gauge was empty
    _expectDepositTransfer(users.alice, _amount);
    _expectSettleGauge(_firstCumulative);
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.forfeitEmissions, (uint128(_firstCumulative))), '');

    vm.prank(users.alice);
    _gauge.deposit(_amount);

    // it should advance the cursor past the forfeited span
    assertEq(_gauge.lastCumulativeRewardShare(), _firstCumulative);
    // it should leave reward per token stored at zero after the empty span
    assertEq(_gauge.rewardPerTokenStored(), 0);
    assertEq(_gauge.rewards(users.alice), 0);

    uint256 _totalSupply = _gauge.totalSupply();
    assertEq(_totalSupply, _amount);

    // @dev Phase 2: the gauge now has a staker; re-pull a larger cumulative so only the new span folds in.
    uint256 _secondCumulative = _firstCumulative + _stakedSpan;
    uint256 _expectedIncrease = (uint256(_stakedSpan) * PRECISION) / _totalSupply;

    _expectDepositTransfer(users.alice, _amount);
    _expectSettleGauge(_secondCumulative);
    // it should not back pay the forfeited span to the first staker
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    vm.prank(users.alice);
    _gauge.deposit(_amount);

    // it should fold only the post deposit delta once the gauge has a staker
    assertEq(_gauge.rewardPerTokenStored(), _expectedIncrease);
    assertEq(_gauge.lastCumulativeRewardShare(), _secondCumulative);
    // @dev The first staker's rewards reflect only the staked-span delta, never the forfeited empty span.
    uint256 _expectedRewards = (_amount * _expectedIncrease) / PRECISION;
    assertEq(_gauge.rewards(users.alice), _expectedRewards);
  }

  function test_WhenTheVoterReentersTheGaugeDuringSettlement(uint256 _amount) external whenTheAmountIsNotZero {
    _amount = bound(_amount, 1, type(uint128).max);

    // @dev Point a fresh gauge at a malicious voter whose settlement re-enters `deposit`.
    ReentrantDepositVoter _reentrantVoter = new ReentrantDepositVoter(_amount);
    _voter = address(_reentrantVoter);
    _gauge = _newGauge(_IS_POOL);
    _reentrantVoter.setGauge(address(_gauge));

    // @dev The outer deposit reverts inside `_updateRewards` before it ever pulls staking tokens.
    vm.mockCall(_stakingToken, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));

    vm.prank(users.alice);
    // it should revert with ReentrancyGuardReentrantCall
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _gauge.deposit(_amount);
  }

  /// @dev Expects the caller's staking tokens to be transferred into the gauge.
  function _expectDepositTransfer(address _caller, uint256 _amount) internal {
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
  }
}

/// @dev Malicious voter whose `settleGauge` re-enters the gauge's `deposit`, exercising the reentrancy guard.
contract ReentrantDepositVoter {
  IGauge internal _gauge;
  uint256 internal immutable _AMOUNT;

  constructor(uint256 _amount) {
    _AMOUNT = _amount;
  }

  function setGauge(address _gauge_) external {
    _gauge = IGauge(_gauge_);
  }

  function settleGauge(address) external returns (uint256) {
    // @dev The outer `deposit` holds the transient reentrancy lock, so this inner call must revert.
    _gauge.deposit(_AMOUNT);
    return 0;
  }
}
