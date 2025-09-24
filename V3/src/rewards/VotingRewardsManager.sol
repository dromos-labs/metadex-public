// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {RewardsLogicLibrary} from 'V3/libraries/RewardsLogicLibrary.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {FeeDistribution} from 'V3/rewards/FeeDistribution.sol';
import {IncentiveStreaming} from 'V3/rewards/IncentiveStreaming.sol';
import {VotingCheckpoints} from 'V3/rewards/VotingCheckpoints.sol';

contract VotingRewardsManager is FeeDistribution, IncentiveStreaming, IVotingRewardsManager {
  using SafeCastLibrary for uint256;
  using SafeCastLibrary for int128;
  using SafeERC20 for IERC20;

  /// @inheritdoc IVotingRewardsManager
  address public immutable wrappedNative;

  /// @dev Fee claim progress keyed by staked position ID.
  mapping(uint256 _tokenId => ClaimState _claimState) internal _feeClaimState;
  /// @dev Incentive claim progress keyed by staked position and program ID.
  mapping(uint256 _tokenId => mapping(uint256 _programId => ClaimState _claimState)) internal _incentiveClaimState;

  /**
   * @notice Constructor function to initialize the contract
   * @param _voter Address of the voter contract
   * @param _gauge The gauge linked to this rewards contract
   * @param _gaugeFactory The gauge factory authorized to flush fees
   * @param _wrappedNative Address of the wrapped native token, or the zero address to disable auto unwrapping
   * @param _initialRewards Array of initial reward token addresses
   */
  constructor(
    address _voter,
    address _gauge,
    address _gaugeFactory,
    address _wrappedNative,
    address[] memory _initialRewards
  )
    FeeDistribution(_gauge, _gaugeFactory, _initialRewards[0], _initialRewards[1])
    IncentiveStreaming(_voter, _initialRewards)
  {
    wrappedNative = _wrappedNative;
  }

  /// @notice Accepts native token transfers only from the wrapped native token contract.
  receive() external payable {
    if (msg.sender != wrappedNative) revert NotWrappedNative();
  }

  /// @inheritdoc IVotingRewardsManager
  function checkpoint(
    uint256 _tokenId,
    uint128 _allocated,
    uint48 _stakeEnd,
    bytes calldata _data
  ) external nonReentrant {
    if (msg.sender != voter) revert NotVoter();

    /// @dev Process pending fees only once per timestamp
    if (lastFeeUpdate != block.timestamp) {
      (uint256 _pending0, uint256 _pending1) = IGauge(gauge).pendingFees();
      _notifyFeesAmount(_pending0, _pending1);
    }

    /// @dev Reset the allocation if no weights are allocated, or if a non-permanent stake carries no weight.
    if (_allocated == 0 || (_stakeEnd != 0 && (_stakeEnd <= block.timestamp || _allocated < MAXTIME))) {
      _reset(_tokenId);
    } else {
      _checkpoint(_tokenId, _allocated, _stakeEnd, _data);
    }
  }

  /// @inheritdoc IVotingRewardsManager
  function advanceGlobalPoints() external {
    advanceGlobalPoints(MAX_CHECKPOINT_ITERATIONS);
  }

  /// @inheritdoc IVotingRewardsManager
  function claimFees(uint256 _tokenId, address _recipient, uint256 _maxCheckpoints) external nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();
    if (_maxCheckpoints == 0) revert ZeroCheckpoints();
    _checkAuthorized(_tokenId);
    _claimFees(_tokenId, _recipient, _maxCheckpoints);
  }

  /// @inheritdoc IVotingRewardsManager
  function claimIncentives(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _maxCheckpoints
  ) external nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();
    if (_maxCheckpoints == 0) revert ZeroCheckpoints();
    _checkAuthorized(_tokenId);
    _claimIncentives(_tokenId, _recipient, _programId, _maxCheckpoints);
  }

  /// @inheritdoc IVotingRewardsManager
  function flushFees() external nonReentrant {
    if (msg.sender != gaugeFactory) revert NotGaugeFactory();

    /// @dev Collect gauge fees so lastPendingFees0/1 and gauge.pendingFees() reset to zero before suspension.
    (uint256 _collected0, uint256 _collected1) = RewardsLogicLibrary.collectGaugeFees(gauge);
    _settleCollectedFees(_collected0, _collected1);
  }

  /// @inheritdoc IIncentiveStreaming
  function sweep(uint256 _programId) external nonReentrant {
    if (_programId == 0 || _programId > incentiveCount) revert ProgramNotFound();

    IncentiveProgram memory _program = _incentives[_programId];

    if (msg.sender != _program.creator) revert NotCreator();
    if (block.timestamp < _program.end) revert ProgramNotEnded();

    /// @dev Close the open interval when the latest checkpoint is behind the program end, so the
    ///      window is covered by closed intervals before measuring supply (mirrors the claim path).
    uint256 _globalIndex = globalCheckpointIndex;
    uint256 _latestCheckpointTs = _globalRewardPointHistory[_globalIndex].ts;
    if (_latestCheckpointTs < _program.end) {
      _checkStaleCheckpointHistory(_latestCheckpointTs, _program.end, MAX_CHECKPOINT_ITERATIONS);
      _notifyFeesAndAdvanceHistory(_latestCheckpointTs, MAX_CHECKPOINT_ITERATIONS);
      _globalIndex = globalCheckpointIndex;
    }

    (uint256 _cumulativeSweepable, uint256 _sweepable) = RewardsLogicLibrary.computeSweep({
      _incentives: _incentives,
      _globalRewardPointHistory: _globalRewardPointHistory,
      _slopeChanges: slopeChanges,
      _sweptAmount: sweptAmount,
      _programId: _programId,
      _globalIndex: _globalIndex
    });

    if (_sweepable == 0) return;

    /// @dev Store cumulative payout progress so repeated calls transfer only the delta.
    _debitIncentive(_programId, _sweepable);
    sweptAmount[_programId] = _cumulativeSweepable;
    IERC20(_program.token).safeTransfer({to: _program.creator, value: _sweepable});
    emit IncentiveSwept(_programId, _program.creator, _sweepable);
  }

  /// @inheritdoc IVotingRewardsManager
  function earnedFees(uint256 _tokenId, uint256 _maxCheckpoints) external view returns (uint256, uint256) {
    ClaimState memory _state = _feeClaimState[_tokenId];
    /// @dev Iterate the user checkpoints since the last claim, or from the first index
    uint256 _startUserCp = _state.lastUserCp == 0 ? 1 : _state.lastUserCp;
    bool _reachedEnd = _maxCheckpoints >= userRewardCheckpointIndex[_tokenId] + 1 - _startUserCp;

    (uint256 _reward0, uint256 _reward1,,) = _computeFeeRewards(
      RewardsLogicLibrary.FeeClaimParams({
        tokenId: _tokenId,
        from: _state.lastGlobalCp,
        startUserCp: _startUserCp,
        userCheckpointIndex: userRewardCheckpointIndex[_tokenId],
        globalCheckpointIndex: globalCheckpointIndex,
        maxCheckpoints: _maxCheckpoints,
        accumulatorOrigin: ACCUMULATOR_ORIGIN
      })
    );

    /// @dev Estimate the pending fees if claiming past the last user checkpoint
    if (_reachedEnd) {
      uint256 _weight = _balanceOfNFTAt(_tokenId, block.timestamp);
      if (_weight > 0) {
        (uint256 _pending0, uint256 _pending1) = IGauge(gauge).pendingFees();
        /// @dev Include buffered fees that an active gauge would flush, mirroring _notifyFeesAmount
        uint256 _buffered0 = bufferedFees0;
        uint256 _buffered1 = bufferedFees1;
        if (
          _pending0 > 0 || _pending1 > 0
            || ((_buffered0 > 0 || _buffered1 > 0) && IGaugeFactory(gaugeFactory).emissionCap(gauge) > 0)
        ) {
          uint256 _supply = totalSupply();
          if (_supply > 0) {
            _reward0 += _weight * (_pending0 - lastPendingFees0 + _buffered0) / _supply;
            _reward1 += _weight * (_pending1 - lastPendingFees1 + _buffered1) / _supply;
          }
        }
      }
    }

    return (_reward0, _reward1);
  }

  /// @inheritdoc IVotingRewardsManager
  function earnedIncentives(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _maxCheckpoints
  ) external view returns (uint256) {
    ClaimState memory _state = _incentiveClaimState[_tokenId][_programId];
    /// @dev Iterate the user checkpoints since the last claim, or from the first index
    uint256 _startUserCp = _state.lastUserCp == 0 ? 1 : _state.lastUserCp;
    uint256 _userCheckpointIndex = userRewardCheckpointIndex[_tokenId];
    bool _reachedEnd =
      _startUserCp <= _userCheckpointIndex && _maxCheckpoints >= _userCheckpointIndex - _startUserCp + 1;

    uint256 _globalIndex = globalCheckpointIndex;
    IncentiveProgram storage _program = _incentives[_programId];
    (uint256 _reward,,) = _computeIncentiveRewards(
      RewardsLogicLibrary.IncentiveClaimParams({
        tokenId: _tokenId,
        from: _state.lastGlobalCp,
        startUserCp: _startUserCp,
        userCheckpointIndex: _userCheckpointIndex,
        globalCheckpointIndex: _globalIndex,
        maxCheckpoints: _maxCheckpoints,
        rate: _program.rate,
        startTs: _program.start,
        endTs: _program.end,
        accumulatorOrigin: ACCUMULATOR_ORIGIN
      })
    );

    /// @dev Estimate the pending incentives if claiming past the last user checkpoint
    if (_reachedEnd) {
      uint256 _effectiveStart = Math.max(_globalRewardPointHistory[_globalIndex].ts, _program.start);
      uint256 _effectiveEnd = Math.min(block.timestamp, _program.end);

      if (_effectiveStart < _effectiveEnd) {
        uint256 _referenceTimestamp = _effectiveEnd - 1;
        uint256 _weight = _balanceOfNFTAt(_tokenId, _referenceTimestamp);

        if (_weight > 0) {
          uint256 _supply = _supplyAt(_globalIndex, _referenceTimestamp);

          if (_supply > 0) {
            /// @dev Include unsettled incentives using the weight share at the end of the interval
            uint256 _unsettledNumerator =
              Math.mulDiv(_program.rate, _weight * (_effectiveEnd - _effectiveStart), _supply);
            _reward += _unsettledNumerator / PRECISION;
          }
        }
      }
    }

    return _reward;
  }

  /// @inheritdoc IVotingRewardsManager
  function feeClaimState(uint256 _tokenId) external view returns (ClaimState memory) {
    return _feeClaimState[_tokenId];
  }

  /// @inheritdoc IVotingRewardsManager
  function incentiveClaimState(uint256 _tokenId, uint256 _programId) external view returns (ClaimState memory) {
    return _incentiveClaimState[_tokenId][_programId];
  }

  /// @inheritdoc IVotingRewardsManager
  function advanceGlobalPoints(uint256 _maxIterations) public nonReentrant {
    if (_maxIterations == 0 || _maxIterations > MAX_CHECKPOINT_ITERATIONS) {
      revert InvalidCheckpointIterations();
    }

    uint256 _globalCheckpointIndex = globalCheckpointIndex;
    if (_globalCheckpointIndex == 0) revert NoGlobalCheckpoint();

    uint256 _lastTs = _globalRewardPointHistory[_globalCheckpointIndex].ts;
    if (block.timestamp < ProtocolTimeLibrary.epochNext(_lastTs)) revert TooSoon();

    _notifyFeesAndAdvanceHistory(_lastTs, _maxIterations);

    emit GlobalPointsAdvanced(msg.sender, globalCheckpointIndex);
  }

  /// @inheritdoc IncentiveStreaming
  function _initializeGlobalRewardHistory() internal override {
    uint256 _globalIndex = globalCheckpointIndex;
    if (_globalIndex == 0) {
      _createGlobalRewardPoints(MAX_CHECKPOINT_ITERATIONS);
    } else {
      _checkStaleCheckpointHistory(
        _globalRewardPointHistory[_globalIndex].ts, block.timestamp, MAX_CHECKPOINT_ITERATIONS
      );
    }
  }

  /// @inheritdoc VotingCheckpoints
  function _createGlobalRewardPoints(
    UserPoint memory _userRewardPoint,
    UserPoint memory _prevUserRewardPoint,
    uint256 _prevStakeEnd,
    uint256 _stakeEnd,
    uint256 _maxIterations
  ) internal override {
    uint256 _globalIndex = globalCheckpointIndex;

    GlobalPoint memory _lastPoint;
    FeeSnapshot memory _prevAcc = FeeSnapshot({feeReward0: 0, feeReward1: 0, feeReward0xTime: 0, feeReward1xTime: 0});
    /// @dev Load the prior global point and fee accumulators, or start fresh if none exist.
    if (_globalIndex > 0) {
      _lastPoint = _globalRewardPointHistory[_globalIndex];
      _prevAcc = feeRewardPerVotingPowerAt[_globalIndex];
    } else {
      _lastPoint = GlobalPoint({
        bias: 0, slope: 0, ts: block.timestamp.toUint48(), permanentStakeBalance: 0, zeroSupplySeconds: 0
      });
    }
    uint256 _lastTimestamp = _lastPoint.ts;

    /// @dev Seed the running supply accumulators from the prior index to extend them across new intervals.
    uint256 _sharePerVote = supplyAccumulatorAt[_globalIndex].sharePerVote;
    uint256 _weightedSharePerVote = supplyAccumulatorAt[_globalIndex].weightedSharePerVote;

    // Go over weeks to fill history and calculate what the current point is.
    uint256 _t_i = ProtocolTimeLibrary.epochStart(_lastTimestamp);
    for (uint256 _i = 0; _i < _maxIterations; ++_i) {
      // MAX_CHECKPOINT_ITERATIONS covers roughly 10 years of weekly history.
      // Longer gaps should be recovered across multiple advanceGlobalPoints calls before recording a user checkpoint.
      _t_i += WEEK; // Initial value of t_i is always larger than the ts of the last point.
      int128 _dSlope = 0;
      if (_t_i > block.timestamp) {
        _t_i = block.timestamp;
      } else {
        _dSlope = slopeChanges[_t_i];
      }

      uint256 _dt = _t_i - _lastTimestamp;
      if (_dt != 0) {
        /// @dev Price the closed sub-interval from its right-aligned reference timestamp. Boundary slope
        ///      changes at `_t_i` apply to the next interval, so the current interval samples `_t_i - 1`.
        uint256 _refTs = _t_i - 1;
        uint256 _supply = _lastPoint.permanentStakeBalance
          + _computeDecayedBias(_lastPoint.bias, _lastPoint.slope, _lastTimestamp, _refTs).toUint256();
        if (_supply != 0) {
          _sharePerVote += (_dt * RewardsLogicLibrary._ACCUMULATOR_PRECISION) / _supply;
          _weightedSharePerVote += _weightedSharePerVoteDelta(_refTs, _dt, _supply);
        } else {
          _lastPoint.zeroSupplySeconds += _dt.toUint48();
        }
      }

      _lastPoint.bias -= _lastPoint.slope * _dt.toInt128();
      _lastPoint.slope += _dSlope;

      if (_lastPoint.bias < 0) {
        // This can happen.
        _lastPoint.bias = 0;
      }
      if (_lastPoint.slope < 0) {
        // This cannot happen - just in case.
        _lastPoint.slope = 0;
      }

      _lastTimestamp = _t_i;
      _lastPoint.ts = _t_i.toUint48();
      ++_globalIndex;

      if (_t_i == block.timestamp) break;
      /// @dev Record the intermediate global point and fee/supply accumulator snapshots.
      _globalRewardPointHistory[_globalIndex] = _lastPoint;
      _snapshotFeeAccumulator(_globalIndex, _prevAcc);
      _snapshotIncentiveAccumulator(_globalIndex, _sharePerVote, _weightedSharePerVote);
    }

    // @dev Cancel previous voting weight contribution if the stake has not expired.
    if (_prevStakeEnd > block.timestamp) {
      _lastPoint.bias -= _computeDecayedBias(
        _prevUserRewardPoint.bias, _prevUserRewardPoint.slope, _prevUserRewardPoint.ts, block.timestamp
      );
      _lastPoint.slope -= _prevUserRewardPoint.slope;
    }

    // @dev Add new voting weight contribution if the stake has not expired.
    if (_stakeEnd > block.timestamp) {
      _lastPoint.bias += _userRewardPoint.bias;
      _lastPoint.slope += _userRewardPoint.slope;
    }

    if (_lastPoint.bias < 0) {
      _lastPoint.bias = 0;
    }
    if (_lastPoint.slope < 0) {
      _lastPoint.slope = 0;
    }
    _lastPoint.permanentStakeBalance = permanentStakeBalance;

    // If timestamp of last global point is the same, overwrite the last global point.
    // Else record the new global point into history.
    // Exclude index 0 (note: _globalIndex is always >= 1, see above).
    // Two possible outcomes:
    // Missing global checkpoints in prior weeks. In this case, _globalIndex = globalCheckpointIndex + x, where x > 1.
    // No missing global checkpoints, but timestamp != block.timestamp. Create new checkpoint.
    // No missing global checkpoints, but timestamp == block.timestamp. Overwrite last checkpoint.
    if (_globalIndex != 1 && _globalRewardPointHistory[_globalIndex - 1].ts == block.timestamp) {
      // _globalIndex = globalCheckpointIndex + 1, so we do not increment globalCheckpointIndex.
      _globalRewardPointHistory[_globalIndex - 1] = _lastPoint;
    } else {
      // More than one global point may have been written, so we update globalCheckpointIndex.
      _globalRewardPointHistory[_globalIndex] = _lastPoint;
      _snapshotIncentiveAccumulator(_globalIndex, _sharePerVote, _weightedSharePerVote);
      /// @dev Snapshot the credited accumulator via a direct storage copy
      feeRewardPerVotingPowerAt[_globalIndex] = feeRewardPerVotingPower;
      globalCheckpointIndex = _globalIndex;
    }
  }

  /**
   * @notice Advances the global reward checkpoint history by a bounded number of intervals
   * @param _maxIterations Maximum number of week boundaries to process
   */
  function _createGlobalRewardPoints(uint256 _maxIterations) private {
    UserPoint memory _zeroPoint = UserPoint({bias: 0, slope: 0, ts: 0, permanent: 0});
    _createGlobalRewardPoints(_zeroPoint, _zeroPoint, 0, 0, _maxIterations);
  }

  /**
   * @notice Notifies pending fees when the current timestamp is reachable, before advancing history
   * @dev Assumes fees are flushed before suspension and pending fees are zero for suspended gauges
   * @param _latestCheckpointTs Timestamp of the latest global reward checkpoint
   * @param _maxIterations Maximum number of week boundaries to process
   */
  function _notifyFeesAndAdvanceHistory(uint256 _latestCheckpointTs, uint256 _maxIterations) private {
    /// @dev Process pending fees only once per timestamp when history can reach the current timestamp
    if (
      lastFeeUpdate != block.timestamp
        && !_isCheckpointHistoryStale(_latestCheckpointTs, block.timestamp, _maxIterations)
    ) {
      (uint256 _pending0, uint256 _pending1) = IGauge(gauge).pendingFees();
      _notifyFeesAmount(_pending0, _pending1);
    }
    _createGlobalRewardPoints(_maxIterations);
  }

  /**
   * @notice Computes and claims the fee rewards for a veNFT
   * @dev Collects the gauge's fees when the contract has a pending balance, or on an unbounded claim with active allocations
   * @param _tokenId The ID of the veNFT to claim for
   * @param _recipient The address to receive the claimed fees
   * @param _maxCheckpoints The maximum number of user checkpoints to process
   */
  function _claimFees(uint256 _tokenId, address _recipient, uint256 _maxCheckpoints) private {
    ClaimState memory _state = _feeClaimState[_tokenId];
    uint256 _to = globalCheckpointIndex;
    /// @dev Iterate the user checkpoints since the last claim, or from the first index
    uint256 _startUserCp = _state.lastUserCp == 0 ? 1 : _state.lastUserCp;
    uint256 _userCheckpointIndex = userRewardCheckpointIndex[_tokenId];
    bool _reachedEnd = _maxCheckpoints >= _userCheckpointIndex + 1 - _startUserCp;

    /// @dev Collect gauge fees if any are pending, or on an unbounded claim with active allocations
    if (lastPendingFees0 > 0 || lastPendingFees1 > 0 || (_reachedEnd && _balanceOfNFTAt(_tokenId, block.timestamp) > 0))
    {
      /// @dev Collect the gauge's fees to fund the pending balance and back any further accumulator advance
      // slither-disable-next-line reentrancy-no-eth
      (uint256 _collected0, uint256 _collected1) = IGauge(gauge).collectFees();

      bool _checkpointCreated = _settleCollectedFees(_collected0, _collected1);

      /// @dev Extend the range to the new checkpoint to account for newly collected fees
      if (_reachedEnd && _checkpointCreated) _to = globalCheckpointIndex;
    }

    (uint256 _reward0, uint256 _reward1, uint256 _lastUserCp, uint256 _lastGlobalCp) = _computeFeeRewards(
      RewardsLogicLibrary.FeeClaimParams({
        tokenId: _tokenId,
        from: _state.lastGlobalCp,
        startUserCp: _startUserCp,
        userCheckpointIndex: _userCheckpointIndex,
        globalCheckpointIndex: _to,
        maxCheckpoints: _maxCheckpoints,
        accumulatorOrigin: ACCUMULATOR_ORIGIN
      })
    );

    _feeClaimState[_tokenId] = ClaimState({lastGlobalCp: _lastGlobalCp.toUint64(), lastUserCp: _lastUserCp.toUint64()});

    if (_reward0 > 0) {
      _transferReward(_recipient, token0, _reward0);
      emit ClaimFees({_tokenId: _tokenId, _recipient: _recipient, _token: token0, _amount: _reward0});
    }
    if (_reward1 > 0) {
      _transferReward(_recipient, token1, _reward1);
      emit ClaimFees({_tokenId: _tokenId, _recipient: _recipient, _token: token1, _amount: _reward1});
    }
  }

  /**
   * @notice Settles fees collected from the gauge
   * @param _collected0 Amount of token0 fees collected
   * @param _collected1 Amount of token1 fees collected
   * @return _checkpointCreated Whether settling the fees created a global reward checkpoint
   */
  function _settleCollectedFees(uint256 _collected0, uint256 _collected1) private returns (bool _checkpointCreated) {
    /// @dev Skip the accumulator update if already advanced in the current timestamp
    if (lastFeeUpdate == block.timestamp) {
      /// @dev If fees accrued since the last update, buffer the delta
      uint256 _lastPending0 = lastPendingFees0;
      if (_collected0 > _lastPending0) bufferedFees0 += _collected0 - _lastPending0;

      uint256 _lastPending1 = lastPendingFees1;
      if (_collected1 > _lastPending1) bufferedFees1 += _collected1 - _lastPending1;
    } else {
      /// @dev Advance the accumulator with the collected amount
      (uint256 _amount0, uint256 _amount1) = _notifyFeesAmount(_collected0, _collected1);
      if (_amount0 > 0 || _amount1 > 0) {
        _createGlobalRewardPoints(MAX_CHECKPOINT_ITERATIONS);
        _checkpointCreated = true;
      }
    }

    /// @dev Clear the pending fees if any were collected
    if (_collected0 > 0) {
      delete lastPendingFees0;
      emit FeesCollected(gauge, token0, _collected0);
    }
    if (_collected1 > 0) {
      delete lastPendingFees1;
      emit FeesCollected(gauge, token1, _collected1);
    }
  }

  /**
   * @notice Computes and transfers a veNFT's accrued incentive rewards for a single program
   * @dev Closes the open interval first when this claim reaches the veNFT's latest user checkpoint and the
   *      trailing period is still open, so it is priced as a closed interval. Advances the program's claim
   *      pointers; emits ClaimIncentives only when a non-zero reward is transferred
   * @param _tokenId The veNFT token ID
   * @param _recipient Address receiving the incentive rewards
   * @param _programId The incentive program to claim from
   * @param _maxCheckpoints Maximum number of user checkpoints to examine
   */
  function _claimIncentives(uint256 _tokenId, address _recipient, uint256 _programId, uint256 _maxCheckpoints) private {
    if (_programId == 0 || _programId > incentiveCount) revert InvalidProgramId();

    IncentiveProgram memory _program = _incentives[_programId];
    ClaimState memory _state = _incentiveClaimState[_tokenId][_programId];

    /// @dev Close the open interval only when this claim reaches the veNFT's latest user checkpoint - the only
    ///      span priced to the open tip. A bounded claim that stops short never prices the tail, so it leaves the
    ///      interval open for a later claim to close. Skip too once the latest checkpoint is at or past the
    ///      program end: the closed history already covers the window (the claim clips to end), so closing would
    ///      only write a checkpoint past the program for no extra reward.
    uint256 _startUserCp = _state.lastUserCp == 0 ? 1 : _state.lastUserCp;
    uint256 _userCpCount = userRewardCheckpointIndex[_tokenId];
    uint256 _globalIndex = globalCheckpointIndex;
    if (_startUserCp <= _userCpCount && _maxCheckpoints >= _userCpCount - _startUserCp + 1) {
      uint256 _latestCheckpointTs = _globalRewardPointHistory[_globalIndex].ts;
      uint256 _requiredTs = Math.min(block.timestamp, _program.end);
      if (_latestCheckpointTs < _requiredTs) {
        _checkStaleCheckpointHistory(_latestCheckpointTs, _requiredTs, MAX_CHECKPOINT_ITERATIONS);
        _notifyFeesAndAdvanceHistory(_latestCheckpointTs, MAX_CHECKPOINT_ITERATIONS);
      }
    }

    (uint256 _reward, uint256 _lastUserCpIdx, uint256 _frontier) = _computeIncentiveRewards(
      RewardsLogicLibrary.IncentiveClaimParams({
        tokenId: _tokenId,
        from: _state.lastGlobalCp,
        startUserCp: _startUserCp,
        userCheckpointIndex: _userCpCount,
        globalCheckpointIndex: globalCheckpointIndex,
        maxCheckpoints: _maxCheckpoints,
        rate: _program.rate,
        startTs: _program.start,
        endTs: _program.end,
        accumulatorOrigin: ACCUMULATOR_ORIGIN
      })
    );

    /// @dev Persist the frontier actually reached; the pointer never advances past the intervals priced this call.
    _incentiveClaimState[_tokenId][_programId] =
      ClaimState({lastGlobalCp: _frontier.toUint64(), lastUserCp: _lastUserCpIdx.toUint64()});

    if (_reward > 0) {
      _debitIncentive(_programId, _reward);
      _transferReward(_recipient, _program.token, _reward);
      emit ClaimIncentives(_tokenId, _recipient, _programId, _reward);
    }
  }

  /**
   * @notice Transfers reward tokens to recipient
   * @dev Wrapped native tokens are unwrapped before being sent to the recipient
   * @param _recipient The address to receive the rewards
   * @param _token The reward token address
   * @param _amount The amount to transfer
   */
  function _transferReward(address _recipient, address _token, uint256 _amount) private {
    if (_token == wrappedNative) {
      // Automatically unwrap reward token if it is `wrappedNative`.
      IWETH(wrappedNative).withdraw(_amount);
      SafeTransferLib.safeTransferETH(_recipient, _amount);
    } else {
      // Otherwise, execute standard ERC20 transfer.
      IERC20(_token).safeTransfer(_recipient, _amount);
    }
  }

  /**
   * @notice Computes the accrued fees for a veNFT over a range of global checkpoints
   * @dev Permanent stakes settle in a single accumulator delta
   *      Decaying stakes combine deltas of the fee accumulator and its time-weighted counterpart to account for decay
   *      Assumes the fee time-weighted accumulator is rebased to `ACCUMULATOR_ORIGIN`
   *      Assumes `_params.startUserCp` is non-zero because user checkpoints begin at index 1
   *      This function mirrors `_computeIncentiveRewards`, so shared logic changes must be reflected in both functions
   * @param _params The parameters to process the fee claim
   * @return The token0 fee reward
   * @return The token1 fee reward
   * @return The user checkpoint index reached
   * @return The global checkpoint index reached
   */
  function _computeFeeRewards(
    RewardsLogicLibrary.FeeClaimParams memory _params
  ) private view returns (uint256, uint256, uint256, uint256) {
    // slither-disable-next-line unused-return
    return RewardsLogicLibrary.computeFeeRewards({
      _userRewardPointHistory: _userRewardPointHistory,
      _globalRewardPointHistory: _globalRewardPointHistory,
      _feeRewardPerVotingPowerAt: feeRewardPerVotingPowerAt,
      _params: _params
    });
  }

  /**
   * @notice Computes a veNFT's incentive reward for a program over a range of global checkpoints
   * @dev Samples voting power and supply at the same right-aligned reference timestamp per interval so payouts
   *      conserve across claim paths and with sweep. Prices only closed global checkpoint intervals;
   *      the open interval is claimed once a checkpoint closes it. Inputs are bundled into a struct and
   *      the loop's mutable state lives in a memory cursor to stay within the stack-slot limit; reads no
   *      state beyond storage and writes none.
   *      Assumes `_params.startUserCp` is non-zero because user checkpoints begin at index 1
   *      This function mirrors `_computeFeeRewards`, so shared logic changes must be reflected in both functions
   * @param _params The bundled computation inputs
   * @return The incentive reward accrued over the range
   * @return The last user checkpoint index examined, persisted as the resume row
   * @return The frontier: the global checkpoint index actually reached, never past where work was done
   */
  function _computeIncentiveRewards(
    RewardsLogicLibrary.IncentiveClaimParams memory _params
  ) private view returns (uint256, uint256, uint256) {
    // slither-disable-next-line unused-return
    return RewardsLogicLibrary.computeIncentiveRewards({
      _userRewardPointHistory: _userRewardPointHistory,
      _globalRewardPointHistory: _globalRewardPointHistory,
      _slopeChanges: slopeChanges,
      _supplyAccumulatorAt: supplyAccumulatorAt,
      _params: _params
    });
  }

  /**
   * @notice Computes one time-weighted supply accumulator increment
   * @param _refTs Timestamp of the current accumulator step
   * @param _dt Step duration in seconds
   * @param _supply Effective voting supply over the step
   * @return Time-weighted accumulator increment for the step
   */
  function _weightedSharePerVoteDelta(uint256 _refTs, uint256 _dt, uint256 _supply) private view returns (uint256) {
    return ((_refTs - ACCUMULATOR_ORIGIN) * _dt * RewardsLogicLibrary._ACCUMULATOR_PRECISION) / _supply;
  }

  /**
   * @notice Reverts if the caller is not authorized to claim for a veNFT
   * @dev Authorizes the LeafVoter or the veNFT's registered operator
   * @param _tokenId The ID of the veNFT to check authorization for
   */
  function _checkAuthorized(uint256 _tokenId) private view {
    RewardsLogicLibrary.checkAuthorized(voter, _tokenId);
  }

  /**
   * @notice Returns whether global checkpoint history cannot reach the required timestamp within an iteration limit
   * @param _latestCheckpointTs Timestamp of the latest global reward checkpoint
   * @param _requiredTs Timestamp the history must reach
   * @param _maxIterations Maximum number of week boundaries to process
   * @return Whether the required timestamp exceeds the checkpoint iteration limit
   */
  function _isCheckpointHistoryStale(
    uint256 _latestCheckpointTs,
    uint256 _requiredTs,
    uint256 _maxIterations
  ) private pure returns (bool) {
    return _requiredTs > ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + _maxIterations * WEEK;
  }

  /**
   * @notice Checks whether global checkpoint history can reach the required timestamp within an iteration limit
   * @param _latestCheckpointTs Timestamp of the latest global reward checkpoint
   * @param _requiredTs Timestamp the history must reach
   * @param _maxIterations Maximum number of week boundaries to process
   */
  function _checkStaleCheckpointHistory(
    uint256 _latestCheckpointTs,
    uint256 _requiredTs,
    uint256 _maxIterations
  ) private pure {
    /// @dev Reject timestamps when advancing checkpoint history would exceed the iteration limit
    if (_isCheckpointHistoryStale(_latestCheckpointTs, _requiredTs, _maxIterations)) {
      revert StaleCheckpointHistory();
    }
  }
}
