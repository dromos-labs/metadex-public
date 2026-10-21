// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FEE_ACCUMULATOR_PRECISION} from 'V3/libraries/ProtocolConstants.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';

import {VotingCheckpoints} from 'V3/rewards/VotingCheckpoints.sol';

/**
 * @title Fee Distribution
 * @notice Tracks pool fees accrued per unit of voting power and snapshots them at each global reward checkpoint
 */
abstract contract FeeDistribution is VotingCheckpoints, IFeeDistribution {
  /// @inheritdoc IFeeDistribution
  address public immutable gauge;
  /// @inheritdoc IFeeDistribution
  address public immutable gaugeFactory;
  /// @inheritdoc IFeeDistribution
  address public immutable token0;
  /// @inheritdoc IFeeDistribution
  address public immutable token1;

  /// @inheritdoc IFeeDistribution
  uint256 public lastPendingFees0;
  /// @inheritdoc IFeeDistribution
  uint256 public lastPendingFees1;
  /// @inheritdoc IFeeDistribution
  uint256 public bufferedFees0;
  /// @inheritdoc IFeeDistribution
  uint256 public bufferedFees1;
  /// @inheritdoc IFeeDistribution
  uint256 public lastFeeUpdate;

  /// @inheritdoc IFeeDistribution
  FeeSnapshot public feeRewardPerVotingPower;
  /// @inheritdoc IFeeDistribution
  mapping(uint256 _checkpointIndex => FeeSnapshot _snapshot) public feeRewardPerVotingPowerAt;

  /**
   * @notice Constructor function to initialize the contract
   * @param _gauge The gauge linked to this rewards contract
   * @param _gaugeFactory The gauge factory authorized to flush fees
   * @param _token0 The first fee token for the pool
   * @param _token1 The second fee token for the pool
   */
  constructor(address _gauge, address _gaugeFactory, address _token0, address _token1) {
    gauge = _gauge;
    gaugeFactory = _gaugeFactory;
    token0 = _token0;
    token1 = _token1;
  }

  /**
   * @notice Credits the gauge's accrued fees to the per-token fee accumulator
   * @dev Assumes `gauge.pendingFees()` returns 0 once the gauge is suspended
   *      Assumes only this contract collects gauge fees, so `lastPendingFees0/1` never exceed the claimable amounts
   *      Assumes at most one call per timestamp
   *      Updates lastFeeUpdate on entry, even if no fees are released
   * @param _pending0 The gauge's pending token0 fees
   * @param _pending1 The gauge's pending token1 fees
   * @return The amount of token0 credited for distribution, rounded up to the smallest token unit
   * @return The amount of token1 credited for distribution, rounded up to the smallest token unit
   */
  function _notifyFeesAmount(uint256 _pending0, uint256 _pending1) internal returns (uint256, uint256) {
    lastFeeUpdate = block.timestamp;

    /// @dev Skip when there are no pending fees, unless an active gauge has buffered residual left to flush
    uint256 _buffered0 = bufferedFees0;
    uint256 _buffered1 = bufferedFees1;
    if (_pending0 == 0 && _pending1 == 0) {
      if (_buffered0 == 0 && _buffered1 == 0) return (0, 0);
      if (IGaugeFactory(gaugeFactory).emissionCap(gauge) == 0) return (0, 0);
    }

    /// @dev New accrual + any buffered residual
    uint256 _fees0 = _pending0 - lastPendingFees0 + _buffered0;
    uint256 _fees1 = _pending1 - lastPendingFees1 + _buffered1;

    /// @dev Early return if no fees to credit
    if (_fees0 == 0 && _fees1 == 0) return (0, 0);

    /// @dev Credit to accumulator if threshold is met, otherwise buffer
    uint256 _totalSupply = totalSupply();
    if (_totalSupply > 0 && _fees0 * FEE_ACCUMULATOR_PRECISION >= _totalSupply) {
      /// @dev Advance the accumulator and its time-weighted counterpart from the same increment
      uint256 _scaled0 = _fees0 * FEE_ACCUMULATOR_PRECISION;
      uint256 _increment0 = _scaled0 / _totalSupply;
      feeRewardPerVotingPower.feeReward0 += _increment0;
      feeRewardPerVotingPower.feeReward0xTime += _increment0 * (block.timestamp - ACCUMULATOR_ORIGIN);

      lastPendingFees0 = _pending0;

      /// @dev Buffer the undistributed fee remainder
      // slither-disable-next-line weak-prng
      uint256 _remainder0 = (_scaled0 % _totalSupply) / FEE_ACCUMULATOR_PRECISION;
      bufferedFees0 = _remainder0;
      _fees0 -= _remainder0;
      emit NotifyFeesAmount(gauge, token0, _fees0);
    } else {
      /// @dev lastPendingFees0 still advances since bufferedFees0 absorbs the new accrual
      lastPendingFees0 = _pending0;
      bufferedFees0 = _fees0;
      _fees0 = 0;
    }

    /// @dev Credit to accumulator if threshold is met, otherwise buffer
    if (_totalSupply > 0 && _fees1 * FEE_ACCUMULATOR_PRECISION >= _totalSupply) {
      /// @dev Advance the accumulator and its time-weighted counterpart from the same increment
      uint256 _scaled1 = _fees1 * FEE_ACCUMULATOR_PRECISION;
      uint256 _increment1 = _scaled1 / _totalSupply;
      feeRewardPerVotingPower.feeReward1 += _increment1;
      feeRewardPerVotingPower.feeReward1xTime += _increment1 * (block.timestamp - ACCUMULATOR_ORIGIN);

      lastPendingFees1 = _pending1;

      /// @dev Buffer the undistributed fee remainder
      // slither-disable-next-line weak-prng
      uint256 _remainder1 = (_scaled1 % _totalSupply) / FEE_ACCUMULATOR_PRECISION;
      bufferedFees1 = _remainder1;
      _fees1 -= _remainder1;
      emit NotifyFeesAmount(gauge, token1, _fees1);
    } else {
      /// @dev lastPendingFees1 still advances since bufferedFees1 absorbs the new accrual
      lastPendingFees1 = _pending1;
      bufferedFees1 = _fees1;
      _fees1 = 0;
    }

    return (_fees0, _fees1);
  }

  /**
   * @notice Snapshot fee accumulator values at the given global checkpoint index
   * @dev Called when recording a global checkpoint.
   * @param _checkpointIndex The target global checkpoint index
   * @param _snapshot The fee accumulator snapshot to record
   */
  function _snapshotFeeAccumulator(uint256 _checkpointIndex, FeeSnapshot memory _snapshot) internal {
    feeRewardPerVotingPowerAt[_checkpointIndex] = _snapshot;
  }
}
