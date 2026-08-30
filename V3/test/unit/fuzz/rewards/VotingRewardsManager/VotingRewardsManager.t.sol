// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitFuzzVotingRewardsManager is TestHelpers {
  using stdStorage for StdStorage;

  /// @dev Maximum week-boundary iterations per checkpoint call
  uint256 public constant MAX_CHECKPOINT_ITERATIONS = 520;

  uint256 internal constant _TOKEN_ID_A = 1;
  uint256 internal constant _TOKEN_ID_B = 2;

  address internal immutable _VOTER = makeAddr('voter');
  address internal immutable _GAUGE = makeAddr('gauge');
  address internal immutable _GAUGE_FACTORY = makeAddr('gaugeFactory');
  address internal immutable _TOKEN0 = makeAddr('token0');
  address internal immutable _TOKEN1 = makeAddr('token1');
  address[] internal _initialRewards;

  VotingRewardsManager public votingRewardsManager;

  function setUp() public virtual {
    _initialRewards = new address[](2);
    _initialRewards[0] = _TOKEN0;
    _initialRewards[1] = _TOKEN1;
    votingRewardsManager = new VotingRewardsManager(_VOTER, _GAUGE, _GAUGE_FACTORY, address(0), _initialRewards);
    // Default the gauge's pending fees to zero so entry-point calls don't revert; fee tests override as needed
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(uint256(0), uint256(0)));
  }

  /**
   * @notice Computes the (bias, slope) contribution of a non-permanent stake at a given timestamp
   * @param _allocated Allocation amount for the stake
   * @param _stakeEnd Stake expiry timestamp
   * @param _tAct Anchor timestamp at which the contribution is evaluated
   * @return _bias Bias contribution at `_tAct`
   * @return _slope Slope contribution
   */
  function _contribution(
    uint128 _allocated,
    uint48 _stakeEnd,
    uint48 _tAct
  ) internal pure returns (int128 _bias, int128 _slope) {
    if (_stakeEnd <= _tAct) return (0, 0);
    _slope = int128(uint128(_allocated / MAX_TIME));
    _bias = _slope * int128(uint128(_stakeEnd - _tAct));
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
