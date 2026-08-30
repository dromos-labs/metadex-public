// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/StdStorage.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {MockLeafVoter} from 'V3-test/mocks/MockLeafVoter.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeWithdrawFrom is UnitV2Gauge {
  using stdStorage for StdStorage;

  MockLeafVoter internal _mockLeafVoter;

  function setUp() public override {
    _receiptToken = new TestERC20('Receipt Token', 'RCT', 18);
    _mockLeafVoter = new MockLeafVoter(_receiptToken);
    _voter = address(_mockLeafVoter);

    super.setUp();

    vm.warp(1 weeks);
  }

  function test_WhenTheAccountIsTheZeroAddress(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.withdrawFrom(_amount, address(0));
  }

  function test_WhenTheAmountIsZero(address _caller, address _account) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_account);

    vm.prank(_caller);
    // it should revert with ZeroAmount
    vm.expectRevert(IV2Gauge.ZeroAmount.selector);
    _gauge.withdrawFrom(0, _account);
  }

  function test_WhenTheCallerIsTheAccountWithoutSelfApproval(
    address _account,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_account);
    _balance = bound(_balance, 1, type(uint128).max);
    _amount = bound(_amount, 1, _balance);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);

    vm.prank(_account);
    // it should revert with InsufficientAllowance
    vm.expectRevert(IV2Gauge.InsufficientAllowance.selector);
    _gauge.withdrawFrom(_amount, _account);
  }

  modifier whenTheCallerIsAnOperator() {
    _;
  }

  function test_WhenTheAllowanceIsInsufficient(
    address _operator,
    address _account,
    uint256 _allowance,
    uint256 _amount
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _amount = bound(_amount, 1, type(uint128).max);
    _allowance = bound(_allowance, 0, _amount - 1);
    _seedAllowance(_account, _operator, _allowance);

    vm.prank(_operator);
    // it should revert with InsufficientAllowance
    vm.expectRevert(IV2Gauge.InsufficientAllowance.selector);
    _gauge.withdrawFrom(_amount, _account);
  }

  modifier whenTheAllowanceIsBoundedAndSufficient() {
    _;
  }

  function test_WhenTheAmountIsLessThanTheAccountBalance(
    address _operator,
    address _account,
    uint256 _allowance,
    uint256 _balance,
    uint256 _amount,
    uint256 _rewardPerTokenStored,
    uint256 _depositBlock
  ) external whenTheCallerIsAnOperator whenTheAllowanceIsBoundedAndSufficient {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _balance = bound(_balance, 2, type(uint128).max);
    _amount = bound(_amount, 1, _balance - 1);
    _allowance = bound(_allowance, _amount, type(uint256).max - 1);
    _rewardPerTokenStored = bound(_rewardPerTokenStored, 0, type(uint128).max);
    _depositBlock = bound(_depositBlock, 1, type(uint48).max);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);
    _seedAllowance(_account, _operator, _allowance);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedUserRewardPerTokenPaid(_account, _rewardPerTokenStored);
    _seedDepositBlock(_account, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);
    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    vm.prank(_operator);
    // it should emit a Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_operator, _account, _amount);
    _gauge.withdrawFrom(_amount, _account);

    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_account), _rewardPerTokenStored);
    // it should keep the account rewards cleared
    assertEq(_gauge.rewards(_account), 0);
    // it should decrement the allowance
    assertEq(_gauge.allowance(_account, _operator), _allowance - _amount);
    // it should decrease the account balance
    assertEq(_gauge.balanceOf(_account), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
    // it should keep the account deposit block
    assertEq(_gauge.depositBlock(_account), _depositBlock);
  }

  function test_WhenTheAmountEqualsTheAccountBalance(
    address _operator,
    address _account,
    uint256 _allowance,
    uint256 _amount,
    uint256 _rewardPerTokenStored,
    uint256 _depositBlock
  ) external whenTheCallerIsAnOperator whenTheAllowanceIsBoundedAndSufficient {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _amount = bound(_amount, 1, type(uint128).max);
    _allowance = bound(_allowance, _amount, type(uint256).max - 1);
    _rewardPerTokenStored = bound(_rewardPerTokenStored, 0, type(uint128).max);
    _depositBlock = bound(_depositBlock, 1, type(uint48).max);
    _seedBalance(_account, _amount);
    _seedTotalSupply(_amount);
    _seedAllowance(_account, _operator, _allowance);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedUserRewardPerTokenPaid(_account, _rewardPerTokenStored);
    _seedDepositBlock(_account, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);
    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    vm.prank(_operator);
    // it should emit a Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_operator, _account, _amount);
    _gauge.withdrawFrom(_amount, _account);

    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_account), _rewardPerTokenStored);
    // it should keep the account rewards cleared
    assertEq(_gauge.rewards(_account), 0);
    // it should decrement the allowance
    assertEq(_gauge.allowance(_account, _operator), _allowance - _amount);
    // it should decrease the account balance to zero
    assertEq(_gauge.balanceOf(_account), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);
    // it should clear the account deposit block
    assertEq(_gauge.depositBlock(_account), 0);
  }

  function test_WhenTheOperatorHasBlanketApproval(
    address _operator,
    address _account,
    uint256 _balance,
    uint256 _firstAmount,
    uint256 _secondAmount
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _balance = bound(_balance, 2, type(uint128).max);
    _firstAmount = bound(_firstAmount, 1, _balance - 1);
    _secondAmount = bound(_secondAmount, 1, _balance - _firstAmount);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);
    _seedAllowance(_account, _operator, type(uint256).max);

    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _firstAmount)), abi.encode(true));
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_operator);
    _gauge.withdrawFrom(_firstAmount, _account);

    // it should not decrement the allowance
    assertEq(_gauge.allowance(_account, _operator), type(uint256).max);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _firstAmount);

    // it should allow repeated withdrawals
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _secondAmount)), abi.encode(true));
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_operator);
    _gauge.withdrawFrom(_secondAmount, _account);

    assertEq(_gauge.allowance(_account, _operator), type(uint256).max);
    assertEq(_gauge.balanceOf(_account), _balance - _firstAmount - _secondAmount);
    assertEq(_gauge.totalSupply(), _balance - _firstAmount - _secondAmount);
  }

  function test_WhenTheOperatorHasMaxAllowanceThroughApprove(
    address _operator,
    address _account,
    uint256 _balance,
    uint256 _firstAmount,
    uint256 _secondAmount
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _balance = bound(_balance, 2, type(uint128).max);
    _firstAmount = bound(_firstAmount, 1, _balance - 1);
    _secondAmount = bound(_secondAmount, 1, _balance - _firstAmount);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);

    vm.prank(_account);
    _gauge.approve(_operator, type(uint256).max);

    // it should report blanket approval
    assertTrue(_gauge.isApprovedForAll(_account, _operator));

    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _firstAmount)), abi.encode(true));
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_operator);
    _gauge.withdrawFrom(_firstAmount, _account);

    // it should not decrement the allowance
    assertEq(_gauge.allowance(_account, _operator), type(uint256).max);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _firstAmount);

    // it should allow repeated withdrawals
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _secondAmount)), abi.encode(true));
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_operator);
    _gauge.withdrawFrom(_secondAmount, _account);

    assertEq(_gauge.allowance(_account, _operator), type(uint256).max);
    assertEq(_gauge.balanceOf(_account), _balance - _firstAmount - _secondAmount);
    assertEq(_gauge.totalSupply(), _balance - _firstAmount - _secondAmount);
  }

  function test_WhenTheOperatorHasNoClaimApproval(
    address _operator,
    address _account,
    uint256 _balance,
    uint256 _amount,
    uint128 _rewardAmount,
    uint256 _rewardPerTokenStored
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    vm.assume(_operator != users.referral);
    vm.assume(_account != users.referral);
    _balance = bound(_balance, TOKEN_1, 1_000_000 * TOKEN_1);
    _amount = bound(_amount, 1, _balance);
    _rewardAmount = uint128(bound(_rewardAmount, 10, 100_000 * TOKEN_1));
    _rewardPerTokenStored = bound(_rewardPerTokenStored, 1, 1_000_000 * PRECISION);
    uint128 _deferredAmount = uint128(20 * TOKEN_1);
    uint128 _deferredReferralAmount = uint128(5 * TOKEN_1);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);
    _seedAllowance(_account, _operator, _amount);
    _seedRewards(_account, _rewardAmount);
    _seedDeferredEmissions(_account, _deferredAmount);
    _seedDeferredReferralEmissions(users.referral, _deferredReferralAmount);
    _seedUserRewardPerTokenPaid(_account, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, MAX_PIPS / 10);
    _expectEffectivePenaltyConfig(0, 0);
    uint128 _grossRewardAmount = uint128(uint256(_rewardAmount) + (_balance * _rewardPerTokenStored) / PRECISION);
    uint128 _expectedReferralAmount = _grossRewardAmount / 10;
    uint128 _expectedRewardAmount = _grossRewardAmount - _expectedReferralAmount;
    {
      address[] memory _recipients = new address[](1);
      _recipients[0] = _account;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _expectedRewardAmount + _deferredAmount;
      _expectMintEmissions(_recipients, _amounts);
    }
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(_account, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(_account, _account, _expectedRewardAmount);
    // it should emit the DeferredEmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.DeferredEmissionsClaimed(_account, _account, _deferredAmount);
    vm.prank(_operator);
    // it should withdraw without requiring claim approval
    // it should emit a Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_operator, _account, _amount);
    _gauge.withdrawFrom(_amount, _account);

    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_account), _rewardPerTokenStored);
    // it should clear the account rewards
    assertEq(_gauge.rewards(_account), 0);
    // it should clear the account deferred emissions
    assertEq(_gauge.deferredEmissions(_account), 0);
    // it should accumulate the referral emissions
    assertEq(_gauge.deferredReferralEmissions(users.referral), _deferredReferralAmount + _expectedReferralAmount);
    // it should decrease the account balance
    assertEq(_gauge.balanceOf(_account), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
    // it should mint live and deferred LP emissions to the account
    assertEq(_receiptToken.balanceOf(_account), _expectedRewardAmount + _deferredAmount);
  }

  function test_WhenTheOperatorHasClaimApproval(
    address _operator,
    address _account,
    uint256 _balance,
    uint256 _amount,
    uint128 _rewardAmount,
    uint256 _rewardPerTokenStored
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    vm.assume(_operator != users.referral);
    vm.assume(_account != users.referral);
    _balance = bound(_balance, TOKEN_1, 1_000_000 * TOKEN_1);
    _amount = bound(_amount, 1, _balance);
    _rewardAmount = uint128(bound(_rewardAmount, 10, 100_000 * TOKEN_1));
    _rewardPerTokenStored = bound(_rewardPerTokenStored, 1, 1_000_000 * PRECISION);
    uint128 _deferredAmount = uint128(20 * TOKEN_1);
    uint128 _deferredReferralAmount = uint128(5 * TOKEN_1);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);
    _seedAllowance(_account, _operator, _amount);
    _seedApprovedForClaim(_account, _operator, true);
    _seedRewards(_account, _rewardAmount);
    _seedDeferredEmissions(_account, _deferredAmount);
    _seedDeferredReferralEmissions(users.referral, _deferredReferralAmount);
    _seedUserRewardPerTokenPaid(_account, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, MAX_PIPS / 10);
    _expectEffectivePenaltyConfig(0, 0);
    uint128 _grossRewardAmount = uint128(uint256(_rewardAmount) + (_balance * _rewardPerTokenStored) / PRECISION);
    uint128 _expectedReferralAmount = _grossRewardAmount / 10;
    uint128 _expectedRewardAmount = _grossRewardAmount - _expectedReferralAmount;
    {
      address[] memory _recipients = new address[](1);
      _recipients[0] = _operator;
      uint128[] memory _amounts = new uint128[](1);
      _amounts[0] = _expectedRewardAmount + _deferredAmount;
      _expectMintEmissions(_recipients, _amounts);
    }
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(_account, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(_account, _operator, _expectedRewardAmount);
    // it should emit the DeferredEmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.DeferredEmissionsClaimed(_account, _operator, _deferredAmount);
    vm.prank(_operator);
    // it should emit a Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_operator, _account, _amount);
    _gauge.withdrawFrom(_amount, _account);

    // it should update the account's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_account), _rewardPerTokenStored);
    // it should clear the account rewards
    assertEq(_gauge.rewards(_account), 0);
    // it should clear the account deferred emissions
    assertEq(_gauge.deferredEmissions(_account), 0);
    // it should accumulate the referral emissions
    assertEq(_gauge.deferredReferralEmissions(users.referral), _deferredReferralAmount + _expectedReferralAmount);
    // it should keep claim approval active after withdrawal
    assertTrue(_gauge.approvedForClaim(_account, _operator));
    // it should decrease the account balance
    assertEq(_gauge.balanceOf(_account), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
    // it should mint live and deferred LP emissions to the caller
    assertEq(_receiptToken.balanceOf(_operator), _expectedRewardAmount + _deferredAmount);
  }

  function test_WhenTheOperatorHasClaimApprovalAndEmissionMintingReverts(
    address _operator,
    address _account
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    vm.assume(_operator != users.referral);
    vm.assume(_account != users.referral);

    uint256 _balance = 1000 * TOKEN_1;
    uint256 _amount = _balance / 2;
    uint128 _rewardAmount = uint128(100 * TOKEN_1);
    uint128 _deferredAmount = uint128(20 * TOKEN_1);
    uint128 _deferredReferralAmount = uint128(2 * TOKEN_1);
    _seedBalance(_account, _balance);
    _seedTotalSupply(_balance);
    _seedAllowance(_account, _operator, _amount);
    _seedApprovedForClaim(_account, _operator, true);
    _seedRewards(_account, _rewardAmount);
    _seedDeferredEmissions(_account, _deferredAmount);
    _seedDeferredReferralEmissions(users.referral, _deferredReferralAmount);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, MAX_PIPS / 10);
    _expectEffectivePenaltyConfig(0, 0);

    uint128 _expectedReferralAmount = _rewardAmount / 10;
    uint128 _expectedRewardAmount = _rewardAmount - _expectedReferralAmount;
    address[] memory _recipients = new address[](1);
    _recipients[0] = _operator;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount + _deferredAmount;
    // it should attempt to mint live and deferred LP emissions to the caller
    _expectMintEmissionsRevert(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(_account, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.EmissionsDeferred(_account, _expectedRewardAmount);
    vm.prank(_operator);
    // it should emit a Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_operator, _account, _amount);
    _gauge.withdrawFrom(_amount, _account);

    // it should store the live LP emissions with the existing account deferred balance
    assertEq(_gauge.deferredEmissions(_account), _expectedRewardAmount + _deferredAmount);
    // it should store the referral emissions with the existing referral balance
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedReferralAmount + _deferredReferralAmount);
    // it should keep claim approval active after withdrawal
    assertTrue(_gauge.approvedForClaim(_account, _operator));
    // it should decrease the account balance
    assertEq(_gauge.balanceOf(_account), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
  }

  function test_WhenTheSettlementPullsANonzeroDelta(
    address _operator,
    address _account,
    uint256 _amount,
    uint256 _cumulativeRewardShare
  ) external whenTheCallerIsAnOperator {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_account);
    _operator = _boundNotEq(_operator, _account);
    _amount = bound(_amount, TOKEN_1, 1_000_000 * TOKEN_1);
    // @dev Keep the cumulative at least the stake so the folded delta always mints a nonzero reward.
    _cumulativeRewardShare = bound(_cumulativeRewardShare, _amount, 1_000_000 * TOKEN_1);

    _seedBalance(_account, _amount);
    _seedTotalSupply(_amount);
    _seedAllowance(_account, _operator, _amount);
    _seedRewardPerTokenStored(0);
    _seedUserRewardPerTokenPaid(_account, 0);

    // it should advance the cumulative reward share cursor
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev The account holds the full supply, so the pulled delta folds entirely across `_amount`.
    uint256 _expectedRewardPerTokenStored = (_cumulativeRewardShare * PRECISION) / _amount;
    uint128 _expectedRewardAmount = uint128((_amount * _expectedRewardPerTokenStored) / PRECISION);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _account;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    // it should mint the folded emissions to the account
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));

    vm.prank(_operator);
    _gauge.withdrawFrom(_amount, _account);

    // it should fold the pulled delta into reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    assertEq(_receiptToken.balanceOf(_account), _expectedRewardAmount);
  }

  function testGas_withdrawFrom() external {
    address _operator = users.bob;
    address _account = users.alice;
    uint256 _amount = TOKEN_1;
    _seedBalance(_account, _amount);
    _seedTotalSupply(_amount);
    _seedAllowance(_account, _operator, _amount);

    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_operator, _amount)), abi.encode(true));
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_operator);
    _gauge.withdrawFrom(_amount, _account);
    vm.snapshotGasLastCall('V2Gauge_withdrawFrom');
  }
}
