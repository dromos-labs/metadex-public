// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAX_PIPS, PRECISION} from 'V3/libraries/ProtocolConstants.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {MockLeafVoter} from 'V3-test/mocks/MockLeafVoter.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeClaimEmissions is UnitV2Gauge {
  MockLeafVoter internal _mockLeafVoter;
  address internal _operator;
  address internal _recipient;
  address internal _referral;

  function setUp() public override {
    _receiptToken = new TestERC20('Receipt Token', 'RCT', 18);
    _mockLeafVoter = new MockLeafVoter(_receiptToken);
    _voter = address(_mockLeafVoter);

    super.setUp();

    vm.warp(1 weeks);
  }

  function test_WhenTheRecipientIsTheZeroAddress(address _caller, address _account) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_account);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.claimEmissions(_account, address(0));
  }

  modifier whenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenTheCallerIsNotTheAccountOrAnApprovedOperator(
    address _caller,
    address _account,
    address _recipient_
  ) external whenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_account);
    _assumeFuzzable(_recipient_);
    _caller = _boundNotEq(_caller, _account);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGauge.NotAuthorized.selector);
    _gauge.claimEmissions(_account, _recipient_);
  }

  modifier whenTheCallerIsAuthorized() {
    _;
  }

  modifier whenTheCallerIsTheAccount() {
    _;
  }

  modifier whenTheAccountHasDeferredEmissionsAndNoAccruedEmissions() {
    _;
  }

  function test_WhenTheAccountHasDeferredEmissionsAndNoAccruedEmissions(
    address _caller,
    uint128 _deferredAmount
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasDeferredEmissionsAndNoAccruedEmissions
  {
    _assumeFuzzable(_caller);
    _deferredAmount = uint128(bound(_deferredAmount, 1, type(uint128).max));
    _seedDeferredEmissions(_caller, _deferredAmount);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, MAX_PIPS / 10);
    _expectEffectivePenaltyConfig(0, 0);
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _deferredAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the DeferredEmissionsClaimed event
    _expectEmit(address(_gauge));
    emit IV2Gauge.DeferredEmissionsClaimed(_caller, users.bob, _deferredAmount);

    vm.prank(_caller);
    _gauge.claimEmissions(_caller, users.bob);

    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), 0);
    // it should clear the account deferred emissions
    assertEq(_gauge.deferredEmissions(_caller), 0);
    // it should mint the deferred account emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _deferredAmount);
  }

  modifier whenTheAccountHasNoAccruedEmissions() {
    _;
  }

  function test_WhenUnusedEmissionsAreZero()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasNoAccruedEmissions
  {
    uint256 _totalSupply = 1000 * TOKEN_1;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    _seedTotalSupply(_totalSupply);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // @dev Reward per token: 6 tokens cumulative delta * PRECISION / 1,000 tokens = 0.006e18.
    uint256 _expectedRewardPerTokenStored = 6_000_000_000_000_000;

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _expectedRewardPerTokenStored);
    // it should not mint emissions
    assertEq(_receiptToken.totalSupply(), 0);
  }

  function test_WhenUnusedEmissionsAreGreaterThanZero(
    uint128 _rewardRate,
    uint48 _elapsed
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasNoAccruedEmissions
  {
    _elapsed = uint48(bound(_elapsed, 1, 1 days));
    _rewardRate = uint128(bound(_rewardRate, 1, type(uint128).max / _elapsed));

    // @dev Cumulative delta equivalent to the realized emissions over the elapsed window.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;

    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    uint128 _expectedUnusedEmissions = uint128(_cumulativeRewardShare);

    // it should forfeit unused emissions
    _expectForfeitEmissions(_expectedUnusedEmissions);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should leave reward per token stored unchanged
    assertEq(_gauge.rewardPerTokenStored(), 0);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), 0);
    // it should not mint emissions
    assertEq(_receiptToken.totalSupply(), 0);
  }

  modifier whenTheAccountHasAccruedEmissions() {
    _;
  }

  modifier whenThereIsNoPenaltyAndNoReferral() {
    _;
  }

  function test_WhenTheRewardParametersAreKnown()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18.
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens.
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens.
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens.
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRewardAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should mint full emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);

    uint256 _rewardPerTokenStored = _gauge.rewardPerTokenStored();
    uint256 _userRewardPerTokenPaid = _gauge.userRewardPerTokenPaid(users.alice);
    uint256 _rewards = _gauge.rewards(users.alice);

    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // @dev Balance should remain unchanged after another claim
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);
    // @dev Reward accounting should remain unchanged after another claim
    assertEq(_gauge.rewardPerTokenStored(), _rewardPerTokenStored);
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _userRewardPerTokenPaid);
    assertEq(_gauge.rewards(users.alice), _rewards);
  }

  function test_WhenTheRewardParametersVary(
    uint256 _balance,
    uint256 _totalSupply,
    uint256 _prevRewards,
    uint256 _prevUserRewardPerTokenPaid,
    uint256 _prevRewardPerTokenDelta,
    uint128 _rewardRate,
    uint48 _elapsed
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsNoPenaltyAndNoReferral
  {
    _balance = bound(_balance, TOKEN_1, 1_000_000 * TOKEN_1);
    _totalSupply = bound(_totalSupply, _balance, 1_000_000 * TOKEN_1);
    _prevRewards = bound(_prevRewards, 1, 100_000 * TOKEN_1);
    _prevUserRewardPerTokenPaid = bound(_prevUserRewardPerTokenPaid, 0, 1_000_000 * PRECISION);
    _prevRewardPerTokenDelta = bound(_prevRewardPerTokenDelta, 1, 1_000_000 * PRECISION);
    _rewardRate = uint128(bound(_rewardRate, 1_000_000, 100 ether));
    _elapsed = uint48(bound(_elapsed, 1, 1 days));

    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to the realized emissions over the elapsed window.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;

    // @dev Alice stakes her balance. Total supply is fuzzed separately.
    _stakeFor(users.alice, _balance);
    _seedTotalSupply(_totalSupply);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    uint256 _expectedRewardPerTokenIncrease = (_cumulativeRewardShare * PRECISION) / _totalSupply;
    uint128 _expectedRewardAmount =
      uint128(_prevRewards + (_balance * (_prevRewardPerTokenDelta + _expectedRewardPerTokenIncrease)) / PRECISION);

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRewardAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should mint full emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);
  }

  modifier whenThereIsAPenaltyRate() {
    _;
  }

  modifier whenCalledWithinMinStakeBlocks() {
    _;
  }

  function test_WhenThereAreNoRemainingEmissionsAfterPenalty()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(10, MAX_PIPS);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18.
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens.
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens.
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens.
    uint128 _expectedPenaltyAmount = uint128(111 * TOKEN_1);

    // it should forfeit all emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);
    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    assertEq(_receiptToken.balanceOf(users.bob), 0);
  }

  modifier whenThereAreRemainingEmissionsAfterPenalty() {
    _;
  }

  function test_WhenUnusedEmissionsAreZero_()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
    whenThereAreRemainingEmissionsAfterPenalty
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18.
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens.
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens.
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens.
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);
    // @dev Penalty emissions: 50% of 111 tokens = 55.5 tokens.
    uint128 _expectedPenaltyAmount = _expectedRewardAmount / 2;
    uint128 _expectedRemainingAmount = _expectedRewardAmount - _expectedPenaltyAmount;

    // it should forfeit the penalty emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRemainingAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRemainingAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should mint the remaining emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRemainingAmount);
  }

  function test_WhenUnusedEmissionsAreGreaterThanZero_()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
    whenCalledWithinMinStakeBlocks
    whenThereAreRemainingEmissionsAfterPenalty
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev This case should not be reachable through public flows, but is covered defensively
    _stakeFor(users.alice, _balance);
    _seedTotalSupply(0);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens.
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens.
    uint128 _expectedRewardAmount = uint128(105 * TOKEN_1);
    // @dev Unused emissions: 60 seconds * 0.1 tokens/second = 6 tokens.
    uint128 _expectedUnusedEmissions = 6 ether;
    // @dev Penalty emissions: 50% of 105 tokens = 52.5 tokens.
    uint128 _expectedPenaltyAmount = _expectedRewardAmount / 2;
    uint128 _expectedRemainingAmount = _expectedRewardAmount - _expectedPenaltyAmount;
    uint128 _expectedForfeitedAmount = _expectedUnusedEmissions + _expectedPenaltyAmount;

    // it should forfeit unused and penalty emissions
    _expectForfeitEmissions(_expectedForfeitedAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRemainingAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRemainingAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should leave reward per token stored unchanged
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should mint the remaining emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRemainingAmount);
  }

  function test_WhenCalledAfterMinStakeBlocks(
    uint256 _minStakeBlocks,
    uint256 _elapsedBlocks
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRate
  {
    _minStakeBlocks = bound(_minStakeBlocks, 0, 1000);
    _elapsedBlocks = bound(_elapsedBlocks, _minStakeBlocks, 1000);

    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // @dev Move strictly past Alice's minimum stake window
    vm.roll(block.number + _elapsedBlocks);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(_minStakeBlocks, MAX_PIPS);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRewardAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should mint full emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRewardAmount);
  }

  modifier whenThereIsAReferralShare() {
    _;
  }

  function test_WhenThereAreNoRemainingEmissionsAfterReferral()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;
    // @dev Simulate a referral share of 100%
    uint256 _referralShare = MAX_PIPS;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(users.alice, users.referral, _expectedRewardAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should store all emissions for the referral
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedRewardAmount);
  }

  function test_WhenThereAreRemainingEmissionsAfterReferral()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);
    // @dev Referral emissions: 10% of 111 tokens = 11.1 tokens
    uint128 _expectedReferralAmount = _expectedRewardAmount / 10;
    uint128 _expectedRecipientAmount = _expectedRewardAmount - _expectedReferralAmount;

    // it should not forfeit emissions
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRecipientAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(users.alice, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRecipientAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should store the referral emissions
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedReferralAmount);
    // it should mint the remaining emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRecipientAmount);
  }

  modifier whenThereIsAPenaltyRateAndAReferralShare() {
    _;
  }

  function test_WhenThePenaltyRateAndReferralShareAreKnown()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);
    // @dev Penalty emissions: 50% of 111 tokens = 55.5 tokens
    uint128 _expectedPenaltyAmount = _expectedRewardAmount / 2;
    // it should apply the penalty before the referral
    // @dev Referral emissions: 10% of the 55.5 tokens left after penalty = 5.55 tokens
    uint128 _expectedReferralAmount = (_expectedRewardAmount - _expectedPenaltyAmount) / 10;
    uint128 _expectedRecipientAmount = _expectedRewardAmount - _expectedPenaltyAmount - _expectedReferralAmount;

    // it should forfeit the penalty emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRecipientAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);
    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(users.alice, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRecipientAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should store the referral emissions
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedReferralAmount);
    // it should mint the remaining emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRecipientAmount);
  }

  function test_WhenThePenaltyRateAndReferralShareVary(
    uint256 _balance,
    uint256 _totalSupply,
    uint256 _prevRewardPerTokenDelta,
    uint256 _penaltyRate,
    uint256 _referralShare
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _maxPips = MAX_PIPS;
    _balance = bound(_balance, TOKEN_1, 1_000_000 * TOKEN_1);
    _totalSupply = bound(_totalSupply, _balance, 1_000_000 * TOKEN_1);
    _prevRewardPerTokenDelta = bound(_prevRewardPerTokenDelta, 1, 1_000_000 * PRECISION);
    _penaltyRate = bound(_penaltyRate, 1, _maxPips - 1);
    _referralShare = bound(_referralShare, 1, _maxPips - 1);

    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    // @dev Alice stakes her balance. Total supply is fuzzed separately
    _seedTotalSupply(_totalSupply);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(users.referral, _referralShare);
    _expectEffectivePenaltyConfig(10, _penaltyRate);

    uint256 _expectedRewardPerTokenIncrease = (_cumulativeRewardShare * PRECISION) / _totalSupply;
    // @dev Reward amount includes stored rewards, prior reward-per-token accrual, and newly accrued rewards
    uint128 _expectedRewardAmount =
      uint128(_prevRewards + (_balance * (_prevRewardPerTokenDelta + _expectedRewardPerTokenIncrease)) / PRECISION);
    uint128 _expectedPenaltyAmount = uint128(uint256(_expectedRewardAmount) * _penaltyRate / _maxPips);
    // it should apply the penalty before the referral
    uint128 _expectedReferralAmount =
      uint128((uint256(_expectedRewardAmount) - _expectedPenaltyAmount) * _referralShare / _maxPips);
    uint128 _expectedRecipientAmount = _expectedRewardAmount - _expectedPenaltyAmount - _expectedReferralAmount;

    // it should forfeit the penalty emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = users.bob;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRecipientAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);
    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(users.alice, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.bob, _expectedRecipientAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should store the referral emissions
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedReferralAmount);
    // it should mint the remaining emissions to the recipient
    assertEq(_receiptToken.balanceOf(users.bob), _expectedRecipientAmount);
  }

  function test_WhenTheCallerIsTheAccountAndTheGaugeSettlesAcrossMultiplePulls(
    uint256 _firstCumulative,
    uint256 _increment
  ) external whenTheRecipientIsNotTheZeroAddress whenTheCallerIsAuthorized {
    // @dev Alice holds the full staked supply so the fold denominator is fixed and nonzero.
    uint256 _balance = 1000 * TOKEN_1;
    // @dev Bound both settlements well below uint128 so the minted emissions never overflow the cast.
    _firstCumulative = bound(_firstCumulative, 1, 1_000_000 * TOKEN_1);
    _increment = bound(_increment, 1, 1_000_000 * TOKEN_1);
    uint256 _secondCumulative = _firstCumulative + _increment;

    _stakeFor(users.alice, _balance);
    uint256 _totalSupply = _gauge.totalSupply();

    // @dev First settlement folds the full first cumulative across the single staker.
    uint256 _expectedFirstIncrease = (_firstCumulative * PRECISION) / _totalSupply;

    // it should fold only the first cumulative delta on the first settlement
    _expectSettleGauge(_firstCumulative);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    assertEq(_gauge.rewardPerTokenStored(), _expectedFirstIncrease);
    // it should advance the cursor to the first cumulative on the first settlement
    assertEq(_gauge.lastCumulativeRewardShare(), _firstCumulative);

    uint256 _rewardPerTokenAfterFirst = _gauge.rewardPerTokenStored();

    // @dev Second settlement re-pulls a larger cumulative; only the new increment folds in.
    uint256 _expectedSecondIncrease = (_increment * PRECISION) / _totalSupply;

    // it should fold only the new cumulative increment on the second settlement
    _expectSettleGauge(_secondCumulative);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);

    assertEq(_gauge.rewardPerTokenStored(), _rewardPerTokenAfterFirst + _expectedSecondIncrease);
    assertEq(_gauge.lastCumulativeRewardShare(), _secondCumulative);
  }

  function test_WhenTheCallerIsAnApprovedOperator(
    address _operator_,
    address _recipient_,
    address _referral_
  ) external whenTheRecipientIsNotTheZeroAddress whenTheCallerIsAuthorized {
    _assumeFuzzable(_operator_);
    _assumeFuzzable(_recipient_);
    _assumeFuzzable(_referral_);
    _operator = _boundNotEq(_operator_, users.alice);
    _recipient = _recipient_;
    _referral = _boundNotEq(_referral_, _recipient);

    // it should keep claim approval active
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;
    uint128 _deferredRewardAmount = uint128(16 * TOKEN_1);
    uint128 _deferredReferralAmount = uint128(4 * TOKEN_1);

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedApprovedForClaim(users.alice, _operator, true);
    _seedRewards(users.alice, _prevRewards);
    _seedDeferredEmissions(users.alice, _deferredRewardAmount);
    _seedDeferredReferralEmissions(_referral, _deferredReferralAmount);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(_referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    // @dev Reward per token increase: 60 seconds * 0.1 tokens/second * PRECISION / 1,000 tokens = 0.006e18
    uint256 _expectedRewardPerTokenIncrease = 6_000_000_000_000_000;
    // @dev Previous accrual: 1,000 staked tokens * 0.005e18 reward-per-token / PRECISION = 5 tokens
    //      New accrual:      1,000 staked tokens * 0.006e18 reward-per-token / PRECISION = 6 tokens
    //      Full emissions:   100 stored tokens + 5 previous reward-per-token tokens + 6 newly accrued tokens
    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);
    // @dev Penalty emissions: 50% of 111 tokens = 55.5 tokens
    uint128 _expectedPenaltyAmount = _expectedRewardAmount / 2;
    // it should apply the penalty before the referral
    // @dev Referral emissions: 10% of the 55.5 tokens left after penalty = 5.55 tokens
    uint128 _expectedReferralAmount = (_expectedRewardAmount - _expectedPenaltyAmount) / 10;
    uint128 _expectedRecipientAmount = _expectedRewardAmount - _expectedPenaltyAmount - _expectedReferralAmount;
    // it should forfeit the penalty emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _recipient;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRecipientAmount + _deferredRewardAmount;
    _expectMintEmissions(_recipients, _amounts);

    // it should emit the EarlyWithdrawPenalty event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EarlyWithdrawPenalty(users.alice, _expectedPenaltyAmount);
    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(users.alice, _referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, _recipient, _expectedRecipientAmount);
    // it should emit the DeferredEmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.DeferredEmissionsClaimed(users.alice, _recipient, _deferredRewardAmount);
    vm.prank(_operator);
    _gauge.claimEmissions(users.alice, _recipient);

    // it should keep claim approval active
    assertTrue(_gauge.approvedForClaim(users.alice, _operator));
    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _prevRewardPerTokenStored + _expectedRewardPerTokenIncrease);
    // it should clear the account rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should clear the account deferred emissions
    assertEq(_gauge.deferredEmissions(users.alice), 0);
    // it should accumulate the referral emissions
    assertEq(_gauge.deferredReferralEmissions(_referral), _expectedReferralAmount + _deferredReferralAmount);
    // it should mint live and deferred LP emissions to the recipient
    assertEq(_receiptToken.balanceOf(_recipient), _expectedRecipientAmount + _deferredRewardAmount);
  }

  function testGas_claimEmissions()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCallerIsAuthorized
    whenTheCallerIsTheAccount
    whenTheAccountHasAccruedEmissions
    whenThereIsAPenaltyRateAndAReferralShare
  {
    uint256 _balance = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _prevUserRewardPerTokenPaid = 15_000_000_000_000_000;
    uint256 _prevRewardPerTokenDelta = 5_000_000_000_000_000;
    uint256 _prevRewardPerTokenStored = _prevUserRewardPerTokenPaid + _prevRewardPerTokenDelta;
    // @dev Cumulative delta equivalent to 60 seconds * 0.1 tokens/second = 6 tokens of realized emissions.
    uint256 _cumulativeRewardShare = 6 ether;
    // @dev Simulate a referral share of 10%
    uint256 _referralShare = MAX_PIPS / 10;

    // @dev Alice holds the full staked supply
    _stakeFor(users.alice, _balance);
    _seedRewards(users.alice, _prevRewards);
    _seedRewardPerTokenStored(_prevRewardPerTokenStored);
    _seedUserRewardPerTokenPaid(users.alice, _prevUserRewardPerTokenPaid);
    // it should request a leaf voter settlement
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(users.referral, _referralShare);
    // @dev Simulate a penalty rate of 50%
    _expectEffectivePenaltyConfig(10, MAX_PIPS / 2);

    uint128 _expectedRewardAmount = uint128(111 * TOKEN_1);
    // @dev Penalty emissions: 50% of 111 tokens = 55.5 tokens
    uint128 _expectedPenaltyAmount = _expectedRewardAmount / 2;

    // it should forfeit the penalty emissions
    _expectForfeitEmissions(_expectedPenaltyAmount);

    vm.prank(users.alice);
    _gauge.claimEmissions(users.alice, users.bob);
    vm.snapshotGasLastCall('V2Gauge_claimEmissions');
  }
}
