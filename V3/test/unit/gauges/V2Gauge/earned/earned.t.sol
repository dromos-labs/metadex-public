// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAX_PIPS, PRECISION} from 'V3/libraries/ProtocolConstants.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {MockLeafVoter} from 'V3-test/mocks/MockLeafVoter.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeEarned is UnitV2Gauge {
  MockLeafVoter internal _mockLeafVoter;

  function setUp() public override {
    _receiptToken = new TestERC20('Receipt Token', 'RCT', 18);
    _mockLeafVoter = new MockLeafVoter(_receiptToken);
    _voter = address(_mockLeafVoter);

    super.setUp();

    vm.warp(1 weeks);
  }

  function test_WhenTheGaugeHasNoStakedSupply(address _account, uint256 _rewardPerToken) external {
    // Virgin gauge: totalSupply stays zero and the projection is deliberately NOT mocked, so any call
    // into the voter would hit the un-expected mock path — proving the zero-supply guard skips the
    // voter query entirely and no division by zero occurs.
    _assumeFuzzable(_account);
    _rewardPerToken = bound(_rewardPerToken, 0, type(uint128).max);
    _seedRewardPerTokenStored(_rewardPerToken);

    // it should not query the voter projection
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.projectedCumulativeRewardShare.selector), 0);

    // it should return zero
    assertEq(_gauge.earned(_account), 0);
  }

  function test_WhenTheAccountHasNoAccruedEmissions(
    address _account,
    uint256 _rewardPerToken,
    uint256 _balance,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_account);
    _rewardPerToken = bound(_rewardPerToken, 0, type(uint128).max);
    _balance = bound(_balance, 1, type(uint128).max);
    _totalSupply = bound(_totalSupply, _balance, type(uint128).max);

    _seedBalance(_account, _balance);
    _seedTotalSupply(_totalSupply);
    _seedRewardPerTokenStored(_rewardPerToken);
    _seedUserRewardPerTokenPaid(_account, _rewardPerToken);

    _mockProjectedCumulativeRewardShare(0);

    // it should return zero
    assertEq(_gauge.earned(_account), 0);
  }

  function test_WhenTheAccountHasOnlyDeferredLPEmissions(address _account) external {
    _assumeFuzzable(_account);
    uint256 _deferredAmount = 100 * TOKEN_1;
    uint256 _deferredReferralAmount = 10 * TOKEN_1;
    _seedDeferredEmissions(_account, _deferredAmount);
    _seedDeferredReferralEmissions(_account, _deferredReferralAmount);

    uint256 _earned = _gauge.earned(_account);
    // it should return the deferred LP emissions
    assertEq(_earned, _deferredAmount);
    // it should exclude referral emissions credited to the account
    assertEq(_earned, _gauge.deferredEmissions(_account));
  }

  function test_WhenTheAccountHasAccruedAndDeferredLPEmissions() external {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _storedRewards = 100 * TOKEN_1;
    uint256 _rewardPerTokenStored = 5_000_000_000_000_000;
    uint256 _deferredAmount = 20 * TOKEN_1;
    uint256 _deferredReferralAmount = 5 * TOKEN_1;
    uint256 _penaltyRate = MAX_PIPS / 2;
    uint256 _referralShare = MAX_PIPS / 10;

    _seedBalance(users.alice, _balance);
    _seedTotalSupply(_balance);
    _seedRewards(users.alice, _storedRewards);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, 0);
    _seedDepositBlock(users.alice, block.number);
    _seedDeferredEmissions(users.alice, _deferredAmount);
    _seedDeferredReferralEmissions(users.alice, _deferredReferralAmount);

    _mockProjectedCumulativeRewardShare(0);
    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(10, _penaltyRate);

    uint256 _expectedLiveEmissions = 47_250_000_000_000_000_000;
    uint256 _earned = _gauge.earned(users.alice);
    // it should apply penalty and referral deductions only to live emissions
    assertEq(_earned - _deferredAmount, _expectedLiveEmissions);
    // it should include deferred LP emissions
    assertEq(_earned, _expectedLiveEmissions + _deferredAmount);
    // it should exclude referral emissions credited to the account
    assertEq(_earned - _expectedLiveEmissions, _gauge.deferredEmissions(users.alice));
  }

  modifier whenTheAccountHasAccruedEmissions() {
    _;
  }

  modifier whenThereIsNoPenaltyAndNoReferral() {
    _;
  }

  function test_WhenTheRewardPerTokenIsKnown()
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    _mockProjectedCumulativeRewardShare(0);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens
    uint128 _expectedRewardAmount = uint128(105 * TOKEN_1);

    // it should return full emissions
    assertEq(_gauge.earned(users.alice), _expectedRewardAmount);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);
    _expectSettleGauge(0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should align claimed emissions with earned
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);
  }

  function test_WhenTheRewardPerTokenVaries(
    uint256 _balance,
    uint256 _totalSupply,
    uint256 _prevRewards,
    uint256 _prevUserRewardPerTokenPaid,
    uint256 _prevRewardPerTokenDelta
  ) external whenTheAccountHasAccruedEmissions whenThereIsNoPenaltyAndNoReferral {
    _balance = bound(_balance, TOKEN_1, 1_000_000 * TOKEN_1);
    _totalSupply = bound(_totalSupply, _balance, 1_000_000 * TOKEN_1);
    _prevRewards = bound(_prevRewards, 1, 100_000 * TOKEN_1);
    _prevUserRewardPerTokenPaid = bound(_prevUserRewardPerTokenPaid, 0, 1_000_000 * PRECISION);
    _prevRewardPerTokenDelta = bound(_prevRewardPerTokenDelta, 1, 1_000_000 * PRECISION);

    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;

    // @dev Alice stakes her balance and total supply is fuzzed separately
    _stakeFor(users.alice, _balance);
    _seedTotalSupply(_totalSupply);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    _mockProjectedCumulativeRewardShare(0);

    uint128 _expectedRewardAmount = uint128(_prevRewards + (_balance * _prevRewardPerTokenDelta) / PRECISION);

    // it should return full emissions
    assertEq(_gauge.earned(users.alice), _expectedRewardAmount);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);
    _expectSettleGauge(0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should align claimed emissions with earned
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);
  }

  modifier whenThereIsAPenaltyRate() {
    _;
  }

  function test_WhenCalledWithinMinStakeBlocks(uint256 _elapsedBlocks)
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    uint256 _minStakeBlocks = 10;
    // @dev Simulate a penalty rate of 50%
    uint256 _penaltyRate = MAX_PIPS / 2;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _elapsedBlocks = bound(_elapsedBlocks, 0, _minStakeBlocks - 1);
    vm.roll(_gauge.depositBlock(users.alice) + _elapsedBlocks);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(_minStakeBlocks, _penaltyRate);

    _mockProjectedCumulativeRewardShare(0);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens
    uint128 _rewardAmount = uint128(105 * TOKEN_1);
    // @dev Penalty emissions: 50% of 105 tokens = 52.5 tokens
    uint128 _expectedEarned = _rewardAmount / 2;

    // it should return emissions after penalty
    assertEq(_gauge.earned(users.alice), _expectedEarned);
  }

  function test_WhenCalledAfterMinStakeBlocks(uint256 _elapsedBlocks)
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    uint256 _minStakeBlocks = 10;
    // @dev Simulate a penalty rate of 50%
    uint256 _penaltyRate = MAX_PIPS / 2;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _elapsedBlocks = bound(_elapsedBlocks, _minStakeBlocks, _minStakeBlocks + 1000);
    vm.roll(_gauge.depositBlock(users.alice) + _elapsedBlocks);

    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(_minStakeBlocks, _penaltyRate);

    _mockProjectedCumulativeRewardShare(0);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens
    uint128 _expectedEarned = uint128(105 * TOKEN_1);

    // it should return full emissions
    assertEq(_gauge.earned(users.alice), _expectedEarned);
  }

  function test_WhenThereIsAReferralShare() external whenTheAccountHasAccruedEmissions {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Simulate a referral share of 5%
    uint256 _referralShare = 50_000;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(0, 0);

    _mockProjectedCumulativeRewardShare(0);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens
    uint128 _rewardAmount = uint128(105 * TOKEN_1);
    // @dev Referral emissions: 5% of 105 tokens = 5.25 tokens
    uint128 _expectedEarned = _rewardAmount - uint128(525 * TOKEN_1 / 100);

    // it should return emissions after referral
    assertEq(_gauge.earned(users.alice), _expectedEarned);
  }

  modifier whenThereIsAPenaltyRateAndAReferralShare() {
    _;
  }

  function test_WhenTheGaugeHasNoNewRewardPerTokenToEstimate()
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    _mockProjectedCumulativeRewardShare(0);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens
    uint128 _rewardAmount = uint128(105 * TOKEN_1);
    // @dev Penalty emissions: 50% of 105 tokens = 52.5 tokens
    uint128 _penaltyAmount = _rewardAmount / 2;
    // it should apply the penalty before the referral
    // @dev Referral emissions: 10% of the 52.5 tokens left after penalty = 5.25 tokens
    uint128 _referralAmount = (_rewardAmount - _penaltyAmount) / 10;
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;

    // it should return emissions after penalty and referral
    assertEq(_gauge.earned(users.alice), _expectedEarned);

    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);
    _expectSettleGauge(0);
    _expectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedEarned;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should align claimed emissions with earned
    assertEq(_receiptToken.balanceOf(users.bob), _expectedEarned);
    assertEq(_gauge.deferredReferralEmissions(users.referral), _referralAmount);
    // it should return zero earned emissions after claim
    _mockProjectedCumulativeRewardShare(0);
    assertEq(_gauge.earned(users.alice), 0);
  }

  function test_WhenTheGaugeHasNewRewardPerTokenToEstimate()
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    // @dev Projected cumulative delta of 6 tokens = 60 seconds * 0.1 tokens/second
    _mockProjectedCumulativeRewardShare(6 ether);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    // it should include the cached rate estimate
    uint128 _rewardAmount = uint128(111 * TOKEN_1);
    // @dev Penalty emissions: 50% of 111 tokens = 55.5 tokens
    uint128 _penaltyAmount = _rewardAmount / 2;
    // it should apply the penalty before the referral
    // @dev Referral emissions: 10% of the 55.5 tokens left after penalty = 5.55 tokens
    uint128 _referralAmount = (_rewardAmount - _penaltyAmount) / 10;
    uint128 _expectedEarned = _rewardAmount - _penaltyAmount - _referralAmount;

    // it should return emissions after penalty and referral
    assertEq(_gauge.earned(users.alice), _expectedEarned);

    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);
    _expectSettleGauge(6 ether);
    _expectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedEarned;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should align claimed emissions with earned
    assertEq(_receiptToken.balanceOf(users.bob), _expectedEarned);
    assertEq(_gauge.deferredReferralEmissions(users.referral), _referralAmount);
    // it should return zero earned emissions after claim
    _mockProjectedCumulativeRewardShare(6 ether);
    assertEq(_gauge.earned(users.alice), 0);
  }

  function test_WhenTheProjectedCumulativeVaries(uint256 _projectedCumulative)
    external
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Simulate a referral share of 10% and a penalty rate of 50%
    uint256 _referralShare = MAX_PIPS / 10;
    uint256 _penaltyRate = MAX_PIPS / 2;

    // @dev Alice holds the full staked supply, so `_stakeFor` leaves the cursor at zero.
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);

    uint256 _totalSupply = _gauge.totalSupply();
    // @dev The projection must be at least the cursor (zero here); bound below the mint cast ceiling.
    _projectedCumulative = bound(_projectedCumulative, _gauge.lastCumulativeRewardShare(), 1_000_000 * TOKEN_1);

    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(10, _penaltyRate);
    _mockProjectedCumulativeRewardShare(_projectedCumulative);

    // @dev Independently fold the projected delta and apply penalty then referral, matching a same-block claim.
    uint256 _projectedIncrease = (_projectedCumulative * PRECISION) / _totalSupply;
    uint256 _rewardPerToken = _prevRewardPerTokenStored + _projectedIncrease;
    uint256 _rewardAmount = _prevRewards + (_balance * (_rewardPerToken - _prevUserRewardPerTokenPaid)) / PRECISION;
    uint128 _penaltyAmount = uint128((_rewardAmount * _penaltyRate) / MAX_PIPS);
    // it should fold the projected delta into the estimate
    uint128 _referralAmount = uint128(((_rewardAmount - _penaltyAmount) * _referralShare) / MAX_PIPS);
    uint128 _expectedEarned = uint128(_rewardAmount - _penaltyAmount - _referralAmount);

    assertEq(_gauge.earned(users.alice), _expectedEarned);

    // @dev A same-block claim settles to the projected cumulative and pays the same net amount.
    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(10, _penaltyRate);
    _expectSettleGauge(_projectedCumulative);
    _expectForfeitEmissions(_penaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedEarned;
    _expectMintEmissions(_recipients, _amounts);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should align claimed emissions with earned
    assertEq(_receiptToken.balanceOf(users.bob), _expectedEarned);
    assertEq(_gauge.deferredReferralEmissions(users.referral), _referralAmount);
  }
}
