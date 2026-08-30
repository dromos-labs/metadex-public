// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

import {MockWETH} from 'V3-test/mocks/MockWETH.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitVotingRewardsManager is TestHelpers {
  using stdStorage for StdStorage;

  /// @dev Maximum week-boundary iterations per checkpoint call
  uint256 public constant MAX_CHECKPOINT_ITERATIONS = 520;

  uint256 internal constant _TOKEN_ID_A = 1;
  uint256 internal constant _TOKEN_ID_B = 2;

  address internal immutable _VOTER = makeAddr('voter');
  address internal immutable _GAUGE = makeAddr('gauge');
  address internal immutable _GAUGE_FACTORY = makeAddr('gaugeFactory');
  address internal immutable _FACTORY_REGISTRY = makeAddr('factoryRegistry');
  address internal immutable _TOKEN_REGISTRY = makeAddr('tokenRegistry');
  address internal immutable _TOKEN0 = makeAddr('token0');
  address internal immutable _TOKEN1 = makeAddr('token1');
  address[] internal _initialRewards;

  VotingRewardsManager public votingRewardsManager;
  MockWETH internal _weth;
  uint256 internal _deploymentTimestamp;

  function setUp() public virtual {
    _initialRewards = new address[](2);
    _initialRewards[0] = _TOKEN0;
    _initialRewards[1] = _TOKEN1;
    _deploymentTimestamp = block.timestamp;

    _weth = new MockWETH();
    votingRewardsManager = new VotingRewardsManager(_VOTER, _GAUGE, _GAUGE_FACTORY, address(_weth), _initialRewards);

    vm.mockCall(_VOTER, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_FACTORY_REGISTRY));
    vm.mockCall(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_TOKEN_REGISTRY));
    // Default the gauge's pending fees to zero so entry-point calls don't revert; fee tests override as needed
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(uint256(0), uint256(0)));
  }

  function test_WhenTheVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IIncentiveStreaming.ZeroAddress.selector);
    new VotingRewardsManager(address(0), _GAUGE, _GAUGE_FACTORY, address(_weth), _initialRewards);
  }

  function test_WhenPassingValidParameters() external view {
    // it exposes the max checkpoint iterations constant
    assertEq(votingRewardsManager.MAX_CHECKPOINT_ITERATIONS(), MAX_CHECKPOINT_ITERATIONS);
    // it sets the accumulator origin to the deployment timestamp
    assertEq(votingRewardsManager.ACCUMULATOR_ORIGIN(), _deploymentTimestamp);
    // it sets the voter address
    assertEq(votingRewardsManager.voter(), _VOTER);
    // it sets the gauge address
    assertEq(votingRewardsManager.gauge(), _GAUGE);
    // it sets the gaugeFactory address
    assertEq(votingRewardsManager.gaugeFactory(), _GAUGE_FACTORY);
    // it sets the token registry address
    assertEq(votingRewardsManager.tokenRegistry(), _TOKEN_REGISTRY);
    // it sets the wrapped native address
    assertEq(votingRewardsManager.wrappedNative(), address(_weth));
    // it sets token0 to the first initial reward
    assertEq(votingRewardsManager.token0(), _TOKEN0);
    // it sets token1 to the second initial reward
    assertEq(votingRewardsManager.token1(), _TOKEN1);
    // it registers the initial reward tokens in the rewards set
    assertEq(votingRewardsManager.rewardsListLength(), 2);
    assertEq(votingRewardsManager.rewards(0), _TOKEN0);
    assertEq(votingRewardsManager.rewards(1), _TOKEN1);
    assertTrue(votingRewardsManager.isReward(_TOKEN0));
    assertTrue(votingRewardsManager.isReward(_TOKEN1));
    // it sets the incentive count to zero
    assertEq(votingRewardsManager.incentiveCount(), 0);
    // it returns a zero-initialized incentive claim state for an unset veNFT and program
    IVotingRewardsManager.ClaimState memory _claimState =
      votingRewardsManager.incentiveClaimState({_tokenId: _TOKEN_ID_A, _programId: 1});
    assertEq(_claimState.lastGlobalCp, 0);
    assertEq(_claimState.lastUserCp, 0);
  }

  /**
   * @notice Asserts all fields of a UserPoint
   * @param _expectedBias The expected bias
   * @param _expectedSlope The expected slope
   * @param _expectedPermanent The expected permanent balance
   * @param _expectedTs The expected timestamp of the checkpoint
   * @param _userPoint The UserPoint struct to validate
   */
  function _assertUserPoint(
    int128 _expectedBias,
    int128 _expectedSlope,
    uint256 _expectedPermanent,
    uint256 _expectedTs,
    IVotingCheckpoints.UserPoint memory _userPoint
  ) internal pure {
    assertEq(_userPoint.bias, _expectedBias);
    assertEq(_userPoint.slope, _expectedSlope);
    assertEq(_userPoint.permanent, _expectedPermanent);
    assertEq(_userPoint.ts, _expectedTs);
  }

  /**
   * @notice Asserts all fields of a GlobalPoint
   * @param _expectedBias The expected global bias
   * @param _expectedSlope The expected global slope
   * @param _expectedPermanentLockBalance The expected global permanent balance
   * @param _expectedTs The expected timestamp of the checkpoint
   * @param _globalPoint The GlobalPoint struct to validate
   */
  function _assertGlobalPoint(
    int128 _expectedBias,
    int128 _expectedSlope,
    uint256 _expectedPermanentLockBalance,
    uint256 _expectedTs,
    IVotingCheckpoints.GlobalPoint memory _globalPoint
  ) internal pure {
    assertEq(_globalPoint.bias, _expectedBias);
    assertEq(_globalPoint.slope, _expectedSlope);
    assertEq(_globalPoint.permanentStakeBalance, _expectedPermanentLockBalance);
    assertEq(_globalPoint.ts, _expectedTs);
  }

  /**
   * @notice Asserts the fee accumulator snapshot at a global checkpoint index
   * @param _checkpointIndex The global checkpoint index to read
   * @param _expected0 The expected token0 accumulator value
   * @param _expected1 The expected token1 accumulator value
   * @param _expected0xTime The expected time-weighted token0 accumulator value
   * @param _expected1xTime The expected time-weighted token1 accumulator value
   */
  function _assertFeeSnapshot(
    uint256 _checkpointIndex,
    uint256 _expected0,
    uint256 _expected1,
    uint256 _expected0xTime,
    uint256 _expected1xTime
  ) internal view {
    (uint256 _acc0, uint256 _acc1, uint256 _acc0xTime, uint256 _acc1xTime) =
      votingRewardsManager.feeRewardPerVotingPowerAt(_checkpointIndex);
    assertEq(_acc0, _expected0);
    assertEq(_acc1, _expected1);
    assertEq(_acc0xTime, _expected0xTime);
    assertEq(_acc1xTime, _expected1xTime);
  }

  /**
   * @notice Asserts the current fee accumulator values
   * @param _expected0 The expected token0 accumulator value
   * @param _expected1 The expected token1 accumulator value
   * @param _expected0xTime The expected time-weighted token0 accumulator value
   * @param _expected1xTime The expected time-weighted token1 accumulator value
   */
  function _assertFeeAccumulator(
    uint256 _expected0,
    uint256 _expected1,
    uint256 _expected0xTime,
    uint256 _expected1xTime
  ) internal view {
    (uint256 _acc0, uint256 _acc1, uint256 _acc0xTime, uint256 _acc1xTime) =
      votingRewardsManager.feeRewardPerVotingPower();
    assertEq(_acc0, _expected0);
    assertEq(_acc1, _expected1);
    assertEq(_acc0xTime, _expected0xTime);
    assertEq(_acc1xTime, _expected1xTime);
  }

  /**
   * @notice Simulate fee accrual by overwriting the fee accumulator
   * @param _acc0 Accumulator value to write for token0
   * @param _acc1 Accumulator value to write for token1
   * @param _acc0xTime Time-weighted accumulator value to write for token0
   * @param _acc1xTime Time-weighted accumulator value to write for token1
   */
  function _seedFeeAccumulator(uint256 _acc0, uint256 _acc1, uint256 _acc0xTime, uint256 _acc1xTime) internal {
    stdstore.target(address(votingRewardsManager)).sig('feeRewardPerVotingPower()').depth(0).checked_write(_acc0);
    stdstore.target(address(votingRewardsManager)).sig('feeRewardPerVotingPower()').depth(1).checked_write(_acc1);
    stdstore.target(address(votingRewardsManager)).sig('feeRewardPerVotingPower()').depth(2).checked_write(_acc0xTime);
    stdstore.target(address(votingRewardsManager)).sig('feeRewardPerVotingPower()').depth(3).checked_write(_acc1xTime);
  }

  /**
   * @notice Mock and expect a call to `IGauge.pendingFees()` returning the given amounts
   * @param _amount0 Pending token0 fees
   * @param _amount1 Pending token1 fees
   */
  function _mockGaugePendingFees(uint256 _amount0, uint256 _amount1) internal {
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_amount0, _amount1));
  }
}
