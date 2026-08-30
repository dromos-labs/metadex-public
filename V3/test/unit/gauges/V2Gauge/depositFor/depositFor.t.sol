// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeDepositFor is UnitV2Gauge {
  function test_WhenTheOwnerIsZeroAddress(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.depositFor(_amount, address(0));
  }

  modifier whenThePenaltyIsActive() {
    _expectEffectivePenaltyConfig(1, 1);
    _;
  }

  function test_WhenTheCallerIsNotAnApprovedMetaRouter(
    address _caller,
    address _owner,
    uint256 _amount
  ) external whenThePenaltyIsActive {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);

    _mockMetaRouterApproved(_caller, false);

    vm.prank(_caller);
    // it should revert with PenaltyActive
    vm.expectRevert(IV2Gauge.PenaltyActive.selector);
    _gauge.depositFor(_amount, _owner);
  }

  function test_WhenTheCallerIsAnApprovedMetaRouter(
    address _caller,
    address _owner,
    uint256 _amount
  ) external whenThePenaltyIsActive {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);
    _amount = bound(_amount, 1, type(uint128).max);

    _mockMetaRouterApproved(_caller, true);
    // it should pull staking tokens from the caller (expectCall below)
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    _expectSettleGauge(0);

    vm.prank(_caller);
    // it should emit a Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(_caller, _owner, _amount);
    _gauge.depositFor(_amount, _owner);

    // it should credit the owner balance
    assertEq(_gauge.balanceOf(_owner), _amount);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _amount);
    // it should update the owner's deposit block
    assertEq(_gauge.depositBlock(_owner), block.number);
  }

  function test_WhenTheAmountIsZero(address _caller, address _owner) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);

    _expectEffectivePenaltyConfig(0, 0);

    vm.prank(_caller);
    // it should revert with ZeroAmount
    vm.expectRevert(IV2Gauge.ZeroAmount.selector);
    _gauge.depositFor(0, _owner);
  }

  function test_WhenThePenaltyIsInactive(
    address _caller,
    address _owner,
    uint256 _amount,
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);
    _owner = _boundNotEq(_owner, _caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _minStakeBlocks = bound(_minStakeBlocks, 0, type(uint256).max);
    _penaltyRate = _minStakeBlocks == 0 ? bound(_penaltyRate, 1, type(uint256).max) : 0;
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    _expectEffectivePenaltyConfig(_minStakeBlocks, _penaltyRate);
    _expectSettleGauge(0);

    vm.prank(_caller);
    // it should emit a Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(_caller, _owner, _amount);
    _gauge.depositFor(_amount, _owner);

    // it should pull staking tokens from the caller (expectCall above)
    // it should credit the owner balance
    assertEq(_gauge.balanceOf(_owner), _amount);
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _amount);
    // it should update the owner's deposit block
    assertEq(_gauge.depositBlock(_owner), block.number);
  }

  function test_WhenDepositingForTheCaller(
    address _caller,
    uint256 _amount,
    uint256 _previousBalance,
    uint256 _previousTotalSupply,
    uint128 _rewardRate,
    uint48 _elapsed
  ) external {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _previousTotalSupply = bound(_previousTotalSupply, 1, type(uint128).max);
    _previousBalance = bound(_previousBalance, 0, _previousTotalSupply);
    _rewardRate = uint128(bound(_rewardRate, 0, 100 ether));
    _elapsed = uint48(bound(_elapsed, 0, 30 days));

    _seedBalance(_caller, _previousBalance);
    _seedTotalSupply(_previousTotalSupply);

    // @dev Cumulative delta equivalent to the realized emissions over the elapsed window.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;

    // it should pull staking tokens from the caller (expectCall above)
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    _expectEffectivePenaltyConfig(0, 0);
    _expectSettleGauge(_cumulativeRewardShare);
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    uint256 _expectedRewardPerTokenStored = (_cumulativeRewardShare * PRECISION) / _previousTotalSupply;
    uint256 _expectedRewards = (_previousBalance * _expectedRewardPerTokenStored) / PRECISION;

    vm.prank(_caller);
    // it should emit a Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(_caller, _caller, _amount);
    _gauge.depositFor(_amount, _caller);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the caller's rewards before the deposit
    assertEq(_gauge.rewards(_caller), _expectedRewards);
    // it should update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), _expectedRewardPerTokenStored);
    // it should credit the caller balance
    assertEq(_gauge.balanceOf(_caller), _previousBalance + _amount);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _previousTotalSupply + _amount);
    // it should update the caller's deposit block
    assertEq(_gauge.depositBlock(_caller), block.number);
  }

  function test_WhenDepositingForAnotherOwner(
    address _caller,
    address _owner,
    uint256 _amount,
    uint256 _previousOwnerBalance,
    uint256 _previousTotalSupply,
    uint128 _rewardRate,
    uint48 _elapsed,
    uint256 _depositBlock
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);
    _owner = _boundNotEq(_owner, _caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _previousTotalSupply = bound(_previousTotalSupply, 1, type(uint128).max);
    _previousOwnerBalance = bound(_previousOwnerBalance, 0, _previousTotalSupply);
    _rewardRate = uint128(bound(_rewardRate, 0, 100 ether));
    _elapsed = uint48(bound(_elapsed, 0, 30 days));

    _seedBalance(_owner, _previousOwnerBalance);
    _seedTotalSupply(_previousTotalSupply);
    _seedRewards(_caller, 2 ether);
    _seedUserRewardPerTokenPaid(_caller, 3 ether);

    // @dev Cumulative delta equivalent to the realized emissions over the elapsed window.
    uint256 _cumulativeRewardShare = uint256(_rewardRate) * _elapsed;

    _depositBlock = bound(_depositBlock, block.number + 1, type(uint128).max);
    vm.roll(_depositBlock);

    // it should pull staking tokens from the caller (expectCall above)
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    _expectEffectivePenaltyConfig(0, 0);
    _expectSettleGauge(_cumulativeRewardShare);
    vm.expectCall(_voter, abi.encodeWithSelector(ILeafVoter.forfeitEmissions.selector), 0);

    uint256 _expectedRewardPerTokenStored = (_cumulativeRewardShare * PRECISION) / _previousTotalSupply;
    uint256 _expectedOwnerRewards = (_previousOwnerBalance * _expectedRewardPerTokenStored) / PRECISION;

    vm.prank(_caller);
    // it should emit a Deposit event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Deposit(_caller, _owner, _amount);
    _gauge.depositFor(_amount, _owner);

    // it should advance reward per token stored
    assertEq(_gauge.rewardPerTokenStored(), _expectedRewardPerTokenStored);
    // it should advance the cumulative reward share cursor
    assertEq(_gauge.lastCumulativeRewardShare(), _cumulativeRewardShare);
    // it should update the owner's rewards before the deposit
    assertEq(_gauge.rewards(_owner), _expectedOwnerRewards);
    // it should update the owner's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_owner), _expectedRewardPerTokenStored);
    // it should not update the caller's rewards
    assertEq(_gauge.rewards(_caller), 2 ether);
    // it should not update the caller's rewardPerTokenPaid
    assertEq(_gauge.userRewardPerTokenPaid(_caller), 3 ether);
    // it should credit the owner balance
    assertEq(_gauge.balanceOf(_owner), _previousOwnerBalance + _amount);
    assertEq(_gauge.balanceOf(_caller), 0);
    // it should increase total supply
    assertEq(_gauge.totalSupply(), _previousTotalSupply + _amount);
    // it should update the owner's deposit block
    assertEq(_gauge.depositBlock(_owner), _depositBlock);
  }

  function testGas_depositFor() external {
    address _caller = users.alice;
    address _owner = users.bob;
    uint256 _amount = TOKEN_1;
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_caller, address(_gauge), _amount)), abi.encode(true)
    );
    _expectEffectivePenaltyConfig(1, 1);
    _mockMetaRouterApproved(_caller, true);
    _expectSettleGauge(0);

    vm.prank(_caller);
    _gauge.depositFor(_amount, _owner);
    vm.snapshotGasLastCall('V2Gauge_depositFor');
  }
}
