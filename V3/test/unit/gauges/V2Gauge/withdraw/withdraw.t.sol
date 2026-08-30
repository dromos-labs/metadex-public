// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {stdError} from 'forge-std/StdError.sol';
import {StdStorage, stdStorage} from 'forge-std/StdStorage.sol';
import {Vm} from 'forge-std/Vm.sol';

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {MockLeafVoter} from 'V3-test/mocks/MockLeafVoter.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeWithdraw is UnitV2Gauge {
  using stdStorage for StdStorage;

  MockLeafVoter internal _mockLeafVoter;

  function setUp() public override {
    _receiptToken = new TestERC20('Receipt Token', 'RCT', 18);
    _mockLeafVoter = new MockLeafVoter(_receiptToken);
    _voter = address(_mockLeafVoter);

    super.setUp();

    vm.warp(1 weeks);
  }

  function test_WhenTheAmountIsZero(address _caller) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAmount
    vm.expectRevert(IV2Gauge.ZeroAmount.selector);
    _gauge.withdraw(0);
  }

  modifier whenTheAmountIsNotZero() {
    _;
  }

  function test_RevertWhen_TheAmountExceedsTheCallerBalance(
    address _caller,
    uint256 _balance,
    uint256 _amount
  ) external whenTheAmountIsNotZero {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 0, type(uint128).max);
    _amount = bound(_amount, _balance + 1, type(uint256).max);
    _seedBalance(_caller, _balance);
    _seedTotalSupply(_balance);

    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_caller);
    // it should revert
    vm.expectRevert(stdError.arithmeticError);
    _gauge.withdraw(_amount);

    assertEq(_receiptToken.balanceOf(_caller), 0);
  }

  modifier whenTheAmountIsWithinTheCallerBalance() {
    _;
  }

  /// @dev Seeds a positive deferred balance with no live accrued emissions for the caller.
  modifier whenTheCallerHasDeferredEmissionsAndNoAccruedEmissions(
    address _caller,
    uint256 _amount,
    uint128 _deferredAmount
  ) {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _deferredAmount = uint128(bound(_deferredAmount, 1, type(uint128).max));
    _seedBalance(_caller, _amount);
    _seedTotalSupply(_amount);
    _seedDepositBlock(_caller, 1);
    _seedDeferredEmissions(_caller, _deferredAmount);
    _;
  }

  /// @notice Verifies a failed deferred-only emission mint preserves the claim while allowing withdrawal.
  function test_WhenDeferredEmissionMintingReverts(
    address _caller,
    uint256 _amount,
    uint128 _deferredAmount
  )
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasDeferredEmissionsAndNoAccruedEmissions(_caller, _amount, _deferredAmount)
  {
    _amount = _gauge.balanceOf(_caller);
    _deferredAmount = uint128(_gauge.deferredEmissions(_caller));

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, 0);
    _expectEffectivePenaltyConfig(0, 0);
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _deferredAmount;
    // it should attempt to mint the deferred emissions
    _expectMintEmissionsRevert(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);

    vm.recordLogs();
    vm.prank(_caller);
    _gauge.withdraw(_amount);

    // it should preserve the caller deferred emissions
    assertEq(_gauge.deferredEmissions(_caller), _deferredAmount);
    // it should decrease the caller balance
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);

    // it should not emit the EmissionsDeferred event
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter == address(_gauge)) {
        assertNotEq(_logs[_i].topics[0], IV2Gauge.EmissionsDeferred.selector);
      }
    }
  }

  /// @notice Verifies a successful deferred-only emission mint claims the deferred balance during withdrawal.
  function test_WhenDeferredEmissionMintingSucceeds(
    address _caller,
    uint256 _amount,
    uint128 _deferredAmount
  )
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasDeferredEmissionsAndNoAccruedEmissions(_caller, _amount, _deferredAmount)
  {
    _amount = _gauge.balanceOf(_caller);
    _deferredAmount = uint128(_gauge.deferredEmissions(_caller));

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, 0);
    _expectEffectivePenaltyConfig(0, 0);
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _deferredAmount;
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    // it should emit the DeferredEmissionsClaimed event
    _expectEmit(address(_gauge));
    emit IV2Gauge.DeferredEmissionsClaimed(_caller, _caller, _deferredAmount);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);

    vm.prank(_caller);
    _gauge.withdraw(_amount);

    // it should clear the caller deferred emissions
    assertEq(_gauge.deferredEmissions(_caller), 0);
    // it should mint the deferred emissions to the caller
    assertEq(_receiptToken.balanceOf(_caller), _deferredAmount);
    // it should decrease the caller balance
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);
  }

  function test_WhenTheCallerHasNoAccruedEmissions(
    address _caller,
    uint256 _amount,
    uint256 _rewardPerTokenStored,
    uint256 _depositBlock
  ) external whenTheAmountIsNotZero whenTheAmountIsWithinTheCallerBalance {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _rewardPerTokenStored = bound(_rewardPerTokenStored, 0, type(uint128).max);
    _depositBlock = bound(_depositBlock, 1, type(uint48).max);
    _seedBalance(_caller, _amount);
    _seedTotalSupply(_amount);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedUserRewardPerTokenPaid(_caller, _rewardPerTokenStored);
    _seedDepositBlock(_caller, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);
    // it should not mint emissions
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])'), 0);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    vm.prank(_caller);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);
    _gauge.withdraw(_amount);

    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), _rewardPerTokenStored);
    // it should keep the caller rewards cleared
    assertEq(_gauge.rewards(_caller), 0);
    // it should decrease the caller balance to zero
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);
    // it should clear the caller deposit block
    assertEq(_gauge.depositBlock(_caller), 0);
    assertEq(_receiptToken.balanceOf(_caller), 0);
  }

  modifier whenTheCallerHasAccruedEmissions() {
    _;
  }

  function test_WhenEmissionMintingReverts(address _caller)
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasAccruedEmissions
  {
    _assumeFuzzable(_caller);
    vm.assume(_caller != users.referral);

    uint256 _balance = 1000 * TOKEN_1;
    uint256 _amount = _balance / 2;
    uint128 _rewardAmount = uint128(100 * TOKEN_1);
    uint128 _deferredAmount = uint128(20 * TOKEN_1);
    uint128 _deferredReferralAmount = uint128(2 * TOKEN_1);
    uint256 _depositBlock = 1;
    _seedBalance(_caller, _balance);
    _seedTotalSupply(_balance);
    _seedRewards(_caller, _rewardAmount);
    _seedDeferredEmissions(_caller, _deferredAmount);
    _seedDeferredReferralEmissions(users.referral, _deferredReferralAmount);
    _seedUserRewardPerTokenPaid(_caller, 0);
    _seedRewardPerTokenStored(0);
    _seedDepositBlock(_caller, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(users.referral, MAX_PIPS / 10);
    _expectEffectivePenaltyConfig(0, 0);

    uint128 _expectedReferralAmount = _rewardAmount / 10;
    uint128 _expectedRewardAmount = _rewardAmount - _expectedReferralAmount;
    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount + _deferredAmount;
    // it should attempt to mint live and deferred LP emissions
    _expectMintEmissionsRevert(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    // it should emit the ReferralEmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.ReferralEmissionsDeferred(_caller, users.referral, _expectedReferralAmount);
    // it should emit the EmissionsDeferred event
    _expectEmit(address(_gauge));
    emit IV2Gauge.EmissionsDeferred(_caller, _expectedRewardAmount);
    vm.prank(_caller);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);
    _gauge.withdraw(_amount);

    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), 0);
    // it should clear the caller rewards
    assertEq(_gauge.rewards(_caller), 0);
    // it should store the live LP emissions with the existing deferred LP balance
    assertEq(_gauge.deferredEmissions(_caller), _expectedRewardAmount + _deferredAmount);
    // it should store the referral emissions with the existing referral balance
    assertEq(_gauge.deferredReferralEmissions(users.referral), _expectedReferralAmount + _deferredReferralAmount);
    // it should decrease the caller balance
    assertEq(_gauge.balanceOf(_caller), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
    // it should keep the caller deposit block
    assertEq(_gauge.depositBlock(_caller), _depositBlock);
  }

  function test_WhenTheAmountIsLessThanTheCallerBalance(
    address _caller,
    uint256 _balance,
    uint256 _amount,
    uint128 _rewardAmount,
    uint256 _rewardPerTokenStored,
    uint256 _depositBlock
  ) external whenTheAmountIsNotZero whenTheAmountIsWithinTheCallerBalance whenTheCallerHasAccruedEmissions {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 2, type(uint128).max);
    _amount = bound(_amount, 1, _balance - 1);
    _rewardAmount = uint128(bound(_rewardAmount, 1, uint256(type(uint128).max) / 2));
    uint256 _minRewardPerTokenStored = PRECISION / _balance + 1;
    uint256 _maxRewardPerTokenStored = ((uint256(type(uint128).max) - _rewardAmount) * PRECISION) / _balance;
    _rewardPerTokenStored = bound(_rewardPerTokenStored, _minRewardPerTokenStored, _maxRewardPerTokenStored);
    _depositBlock = bound(_depositBlock, 1, type(uint48).max);
    _seedBalance(_caller, _balance);
    _seedTotalSupply(_balance);
    _seedRewards(_caller, _rewardAmount);
    _seedUserRewardPerTokenPaid(_caller, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedDepositBlock(_caller, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    uint128 _expectedRewardAmount = uint128(uint256(_rewardAmount) + (_balance * _rewardPerTokenStored) / PRECISION);
    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(_caller, _caller, _expectedRewardAmount);
    vm.prank(_caller);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);
    _gauge.withdraw(_amount);

    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), _rewardPerTokenStored);
    // it should clear the caller rewards
    assertEq(_gauge.rewards(_caller), 0);
    // it should decrease the caller balance
    assertEq(_gauge.balanceOf(_caller), _balance - _amount);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), _balance - _amount);
    // it should keep the caller deposit block
    assertEq(_gauge.depositBlock(_caller), _depositBlock);
    // it should mint emissions to the caller
    assertEq(_receiptToken.balanceOf(_caller), _expectedRewardAmount);
  }

  modifier whenTheAmountEqualsTheCallerBalance() {
    _;
  }

  function test_WhenTheRewardParametersAreKnown()
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasAccruedEmissions
    whenTheAmountEqualsTheCallerBalance
  {
    uint256 _amount = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _rewardPerTokenStored = 5_000_000_000_000_000;
    uint256 _depositBlock = 1;
    _seedBalance(users.alice, _amount);
    _seedTotalSupply(_amount);
    _seedRewards(users.alice, _prevRewards);
    _seedUserRewardPerTokenPaid(users.alice, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedDepositBlock(users.alice, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev Reward-per-token accrual: 1,000 staked tokens * 0.005e18 / PRECISION = 5 tokens
    // @dev Full emissions: 100 stored tokens + 5 reward-per-token tokens
    uint128 _expectedRewardAmount = uint128(105 * TOKEN_1);
    address[] memory _recipients = new address[](1);
    _recipients[0] = users.alice;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    // it should mint emissions to the caller
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (users.alice, _amount)), abi.encode(true));

    // it should emit the EmissionsClaimed event
    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(users.alice, users.alice, _expectedRewardAmount);
    vm.prank(users.alice);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(users.alice, users.alice, _amount);
    _gauge.withdraw(_amount);

    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(users.alice), _rewardPerTokenStored);
    // it should clear the caller rewards
    assertEq(_gauge.rewards(users.alice), 0);
    // it should decrease the caller balance to zero
    assertEq(_gauge.balanceOf(users.alice), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);
    // it should clear the caller deposit block
    assertEq(_gauge.depositBlock(users.alice), 0);
    // it should mint emissions to the caller
    assertEq(_receiptToken.balanceOf(users.alice), _expectedRewardAmount);
  }

  function test_WhenTheRewardParametersVary(
    address _caller,
    uint256 _amount,
    uint128 _rewardAmount,
    uint256 _rewardPerTokenStored,
    uint256 _depositBlock
  )
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasAccruedEmissions
    whenTheAmountEqualsTheCallerBalance
  {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _rewardAmount = uint128(bound(_rewardAmount, 1, uint256(type(uint128).max) / 2));
    uint256 _minRewardPerTokenStored = PRECISION / _amount + 1;
    uint256 _maxRewardPerTokenStored = ((uint256(type(uint128).max) - _rewardAmount) * PRECISION) / _amount;
    _rewardPerTokenStored = bound(_rewardPerTokenStored, _minRewardPerTokenStored, _maxRewardPerTokenStored);
    _depositBlock = bound(_depositBlock, 1, type(uint48).max);
    _seedBalance(_caller, _amount);
    _seedTotalSupply(_amount);
    _seedRewards(_caller, _rewardAmount);
    _seedUserRewardPerTokenPaid(_caller, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedDepositBlock(_caller, _depositBlock);

    // it should request a leaf voter settlement
    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    uint128 _expectedRewardAmount = uint128(uint256(_rewardAmount) + (_amount * _rewardPerTokenStored) / PRECISION);
    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    vm.expectEmit(true, true, true, true, address(_gauge));
    emit IV2Gauge.EmissionsClaimed(_caller, _caller, _expectedRewardAmount);
    vm.prank(_caller);
    // it should emit the Withdraw event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Withdraw(_caller, _caller, _amount);
    _gauge.withdraw(_amount);

    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), _rewardPerTokenStored);
    // it should clear the caller rewards
    assertEq(_gauge.rewards(_caller), 0);
    // it should decrease the caller balance to zero
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should decrease total supply
    assertEq(_gauge.totalSupply(), 0);
    // it should clear the caller deposit block
    assertEq(_gauge.depositBlock(_caller), 0);
    // it should mint emissions to the caller
    assertEq(_receiptToken.balanceOf(_caller), _expectedRewardAmount);
  }

  function test_WhenTheSettlementPullsANonzeroDelta(
    address _caller,
    uint256 _amount,
    uint256 _cumulativeRewardShare
  )
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasAccruedEmissions
    whenTheAmountEqualsTheCallerBalance
  {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, TOKEN_1, 1_000_000 * TOKEN_1);
    // @dev Keep the cumulative at least the stake so the folded delta always mints a nonzero reward.
    _cumulativeRewardShare = bound(_cumulativeRewardShare, _amount, 1_000_000 * TOKEN_1);

    _seedBalance(_caller, _amount);
    _seedTotalSupply(_amount);
    _seedRewardPerTokenStored(0);
    _seedUserRewardPerTokenPaid(_caller, 0);
    _seedDepositBlock(_caller, 1);

    // it should advance the cumulative reward share cursor
    _expectSettleGauge(_cumulativeRewardShare);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    // @dev Single staker holds the full supply, so the pulled delta folds entirely across `_amount`.
    uint256 _expectedRewardPerTokenStored = (_cumulativeRewardShare * PRECISION) / _amount;
    uint128 _expectedRewardAmount = uint128((_amount * _expectedRewardPerTokenStored) / PRECISION);

    address[] memory _recipients = new address[](1);
    _recipients[0] = _caller;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _expectedRewardAmount;
    // it should mint the folded emissions to the caller
    _expectMintEmissions(_recipients, _amounts);
    // it should transfer staking tokens to the caller
    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (_caller, _amount)), abi.encode(true));

    vm.prank(_caller);
    _gauge.withdraw(_amount);

    // it should fold the pulled delta into reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    assertEq(_receiptToken.balanceOf(_caller), _expectedRewardAmount);
  }

  function testGas_withdraw()
    external
    whenTheAmountIsNotZero
    whenTheAmountIsWithinTheCallerBalance
    whenTheCallerHasAccruedEmissions
    whenTheAmountEqualsTheCallerBalance
  {
    uint256 _amount = 1000 * TOKEN_1;
    uint256 _prevRewards = 100 * TOKEN_1;
    uint256 _rewardPerTokenStored = 5_000_000_000_000_000;
    uint256 _depositBlock = 1;
    _seedBalance(users.alice, _amount);
    _seedTotalSupply(_amount);
    _seedRewards(users.alice, _prevRewards);
    _seedUserRewardPerTokenPaid(users.alice, 0);
    _seedRewardPerTokenStored(_rewardPerTokenStored);
    _seedDepositBlock(users.alice, _depositBlock);

    _expectSettleGauge(0);
    _expectReferralConfig(address(0), 0);
    _expectEffectivePenaltyConfig(0, 0);

    _mockAndExpect(_stakingToken, abi.encodeCall(IERC20.transfer, (users.alice, _amount)), abi.encode(true));

    vm.prank(users.alice);
    _gauge.withdraw(_amount);
    vm.snapshotGasLastCall('V2Gauge_withdraw');
  }
}
