// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/StdStorage.sol';

import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {V2Gauge} from 'V3/gauges/V2Gauge.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitV2Gauge is TestHelpers {
  using stdStorage for StdStorage;

  address internal _stakingToken = _mockContract('_stakingToken');
  address internal _votingRewardsManager = _mockContract('_votingRewardsManager');
  address internal _gaugeFactory = _mockContract('_gaugeFactory');
  address internal _factoryRegistry = _mockContract('_factoryRegistry');
  address internal _voter = _mockContract('_voter');
  TestERC20 internal _receiptToken;

  bool internal constant _IS_POOL = true;

  V2Gauge internal _gauge;

  function setUp() public virtual {
    _gauge = _newGauge(_IS_POOL);
  }

  function test_WhenDeployedWithValidParameters(bool _isPool) external {
    V2Gauge gauge = _newGauge(_isPool);

    // it should set the staking token
    assertEq(gauge.stakingToken(), _stakingToken);
    // it should set the fees voting reward
    assertEq(gauge.votingRewardsManager(), _votingRewardsManager);
    // it should set the voter
    assertEq(gauge.voter(), _voter);
    // it should set the is pool flag
    assertEq(gauge.isPool(), _isPool);
    // it should set the gauge factory
    assertEq(gauge.gaugeFactory(), _gaugeFactory);
  }

  function _newGauge(bool _isPool) internal returns (V2Gauge gauge) {
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    V2Gauge implementation = new V2Gauge(_voter, _gaugeFactory);
    gauge = V2Gauge(Clones.clone(address(implementation)));
    gauge.initialize(_stakingToken, _votingRewardsManager, _isPool);
  }

  function _seedBalance(address _account, uint256 _balance) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.balanceOf.selector).with_key(_account).checked_write(_balance);
  }

  function _seedTotalSupply(uint256 _supply) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.totalSupply.selector).checked_write(_supply);
  }

  /// @dev Seeds the global reward-per-token accumulator.
  function _seedRewardPerTokenStored(uint256 _rewardPerTokenStored) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.rewardPerTokenStored.selector).checked_write(_rewardPerTokenStored);
  }

  /// @dev Seeds accrued rewards for an account.
  function _seedRewards(address _account, uint256 _rewards) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.rewards.selector).with_key(_account).checked_write(_rewards);
  }

  /// @dev Seeds deferred emissions for an account.
  function _seedDeferredEmissions(address _account, uint256 _deferredEmissions) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.deferredEmissions.selector).with_key(_account)
      .checked_write(_deferredEmissions);
  }

  /// @dev Seeds deferred referral emissions for a referral.
  function _seedDeferredReferralEmissions(address _referral, uint256 _deferredReferralEmissions) internal {
    stdstore.target(address(_gauge)).sig(IGauge.deferredReferralEmissions.selector).with_key(_referral)
      .checked_write(_deferredReferralEmissions);
  }

  /// @dev Seeds the reward-per-token checkpoint for an account.
  function _seedUserRewardPerTokenPaid(address _account, uint256 _rewardPerTokenPaid) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.userRewardPerTokenPaid.selector).with_key(_account)
      .checked_write(_rewardPerTokenPaid);
  }

  /// @dev Seeds the block at which an account deposited.
  function _seedDepositBlock(address _account, uint256 _depositBlock) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.depositBlock.selector).with_key(_account).checked_write(_depositBlock);
  }

  function _seedAllowance(address _owner, address _operator, uint256 _amount) internal {
    stdstore.target(address(_gauge)).sig(IV2Gauge.allowance.selector).with_key(_owner).with_key(_operator)
      .checked_write(_amount);
  }

  function _seedApprovedForClaim(address _account, address _operator, bool _approved) internal {
    stdstore.target(address(_gauge)).sig(IGauge.approvedForClaim.selector).with_key(_account).with_key(_operator)
      .checked_write(_approved);
  }

  /// @dev Stakes tokens for an account through the gauge deposit path.
  /// @dev Deposit pulls the voter's cumulative reward share; mock it to the gauge's current cursor so the
  ///      setup stake realizes no emissions and leaves reward accounting untouched.
  function _stakeFor(address _account, uint256 _amount) internal {
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IERC20.transferFrom, (_account, address(_gauge), _amount)), abi.encode(true)
    );
    vm.mockCall(
      _voter, abi.encodeCall(ILeafVoter.settleGauge, (address(_gauge))), abi.encode(_gauge.lastCumulativeRewardShare())
    );

    vm.prank(_account);
    _gauge.deposit(_amount);
  }

  /// @dev Mocks and expects the gauge settlement pull to return the requested cumulative reward share.
  function _expectSettleGauge(uint256 _cumulativeRewardShare) internal {
    _mockAndExpect(
      _voter, abi.encodeCall(ILeafVoter.settleGauge, (address(_gauge))), abi.encode(_cumulativeRewardShare)
    );
  }

  /// @dev Mocks the read-only projected cumulative reward share used by `earned`.
  function _mockProjectedCumulativeRewardShare(uint256 _cumulativeRewardShare) internal {
    vm.mockCall(
      _voter,
      abi.encodeCall(ILeafVoter.projectedCumulativeRewardShare, (address(_gauge))),
      abi.encode(_cumulativeRewardShare)
    );
  }

  /// @dev Mocks and expects emission forfeiture through the voter.
  function _expectForfeitEmissions(uint128 _amount) internal {
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.forfeitEmissions, (_amount)), '');
  }

  /// @dev Expects emission minting through the voter and receipt token mints.
  function _expectMintEmissions(address[] memory _recipients, uint128[] memory _amounts) internal {
    vm.expectCall(_voter, abi.encodeWithSignature('mintEmissions(address[],uint128[])', _recipients, _amounts));

    for (uint256 _i; _i < _recipients.length; _i++) {
      vm.expectCall(address(_receiptToken), abi.encodeCall(TestERC20.mint, (_recipients[_i], uint256(_amounts[_i]))));
    }
  }

  /// @dev Expects emission minting through the voter to revert.
  function _expectMintEmissionsRevert(address[] memory _recipients, uint128[] memory _amounts) internal {
    bytes memory _callData = abi.encodeCall(ILeafVoter.mintEmissions, (_recipients, _amounts));
    vm.mockCallRevert(_voter, _callData, bytes(''));
    vm.expectCall(_voter, _callData);
  }

  /// @dev Expects the gauge's referral config lookup to return the requested values.
  function _expectReferralConfig(address _referral_, uint256 _share) internal {
    _mockAndExpect(
      _gaugeFactory, abi.encodeCall(IGaugeFactory.referralConfig, (address(_gauge))), abi.encode(_referral_, _share)
    );
  }

  /// @dev Expects the effective penalty config lookup to return no active penalty.
  function _expectEffectivePenaltyConfig(uint256 _minStakeBlocks, uint256 _penaltyRate) internal {
    _mockAndExpect(
      _gaugeFactory,
      abi.encodeCall(IGaugeFactory.effectivePenaltyConfig, (address(_gauge))),
      abi.encode(IGaugeFactory.PenaltyConfig({minStakeBlocks: _minStakeBlocks, penaltyRate: _penaltyRate}))
    );
  }

  function _mockMetaRouterApproved(address _metaRouter, bool _approved) internal {
    _mockAndExpect(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isMetaRouterApproved, (_metaRouter)), abi.encode(_approved)
    );
  }

  function _expectEmissionCap(uint128 _cap) internal {
    _mockAndExpect(_gaugeFactory, abi.encodeCall(IGaugeFactory.emissionCap, (address(_gauge))), abi.encode(_cap));
  }
}
