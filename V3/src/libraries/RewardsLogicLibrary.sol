// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ExcessivelySafeCall} from '@nomad-xyz/src/ExcessivelySafeCall.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {FEE_ACCUMULATOR_PRECISION, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title Rewards Logic Library
 * @notice Handles gauge fee collection, fee and incentive reward calculations, incentive creation, and sweep
 *         calculations for VotingRewardsManager
 */
library RewardsLogicLibrary {
  using SafeERC20 for IERC20;
  using EnumerableSet for EnumerableSet.UintSet;
  using EnumerableSet for EnumerableSet.AddressSet;
  using SafeCastLibrary for int128;
  using SafeCastLibrary for uint256;
  using ExcessivelySafeCall for address;

  /**
   * @notice Inputs for a fee claim computation
   * @param tokenId The ID of the veNFT to compute rewards for
   * @param from The global checkpoint index to resume from
   * @param startUserCp The user checkpoint index to start from
   * @param userCheckpointIndex The latest user checkpoint index for the veNFT
   * @param globalCheckpointIndex The latest global checkpoint index
   * @param maxCheckpoints The maximum number of user checkpoints to process
   * @param accumulatorOrigin Origin timestamp of the time-weighted fee accumulator
   */
  struct FeeClaimParams {
    uint256 tokenId;
    uint256 from;
    uint256 startUserCp;
    uint256 userCheckpointIndex;
    uint256 globalCheckpointIndex;
    uint256 maxCheckpoints;
    uint256 accumulatorOrigin;
  }

  /**
   * @notice Claim progress while iterating user checkpoints
   * @param currUserCp The user checkpoint index currently being processed
   * @param currGlobalCp The global checkpoint index currently being processed
   * @param numerator0 The accrued token0 reward numerator
   * @param numerator1 The accrued token1 reward numerator
   */
  struct FeeClaimCursor {
    uint256 currUserCp;
    uint256 currGlobalCp;
    uint256 numerator0;
    uint256 numerator1;
  }

  /**
   * @notice Inputs for a single incentive reward computation, bundled to keep the compute function
   *         within the stack-slot limit
   * @param tokenId The veNFT token ID
   * @param from First global checkpoint index to process
   * @param startUserCp The user checkpoint index to start from
   * @param userCheckpointIndex The latest user checkpoint index for the veNFT
   * @param globalCheckpointIndex The latest global checkpoint index used for supply lookups
   * @param maxCheckpoints The maximum number of user checkpoints that may be examined in this call
   * @param rate Program stream rate, scaled by `PRECISION`
   * @param startTs Program start timestamp
   * @param endTs Program end timestamp
   * @param accumulatorOrigin Origin timestamp of the time-weighted supply accumulator
   */
  struct IncentiveClaimParams {
    uint256 tokenId;
    uint256 from;
    uint256 startUserCp;
    uint256 userCheckpointIndex;
    uint256 globalCheckpointIndex;
    uint256 maxCheckpoints;
    uint256 rate;
    uint256 startTs;
    uint256 endTs;
    uint256 accumulatorOrigin;
  }

  /**
   * @notice Mutable state of the incentive reward computation loop, held in memory so the locals
   *         stay within the stack-slot limit
   * @param currUserCp The user checkpoint index currently being processed
   * @param currGlobalCp The global checkpoint index currently being processed
   * @param numerator Running `PRECISION`-scaled reward numerator
   */
  struct IncentiveClaimCursor {
    uint256 currUserCp;
    uint256 currGlobalCp;
    uint256 numerator;
  }

  /// @dev Fixed-point scale for the supply accumulators.
  uint256 internal constant _ACCUMULATOR_PRECISION = 1e42;
  /// @dev Maximum number of week boundaries processed by a supply lookup.
  uint256 internal constant _MAX_CHECKPOINT_ITERATIONS = 520;
  /// @dev Maximum gas forwarded when collecting fees from a gauge during deactivation.
  uint256 internal constant _COLLECT_FEES_GAS_LIMIT = 1_000_000;

  /**
   * @notice Creates a new incentive program that streams tokens at a constant rate
   * @dev The deposited amount is rounded down to match the calculated rate.
   * @param _incentives Incentive program records keyed by program ID
   * @param _incentivesByToken Program ID sets grouped by incentive token
   * @param _incentivesByCreator Program ID sets grouped by creator
   * @param _rewards Set of registered incentive tokens
   * @param _remainingAmount Remaining program balances keyed by program ID
   * @param _programId The unique identifier of the program
   * @param _token The reward token address
   * @param _amount The amount of tokens intended for the program
   * @param _start The timestamp when streaming begins
   * @param _duration The duration of the program in seconds
   */
  function createIncentiveProgram(
    mapping(uint256 _programId => IIncentiveStreaming.IncentiveProgram _program) storage _incentives,
    mapping(address _token => EnumerableSet.UintSet _programIds) storage _incentivesByToken,
    mapping(address _creator => EnumerableSet.UintSet _programIds) storage _incentivesByCreator,
    EnumerableSet.AddressSet storage _rewards,
    mapping(uint256 _programId => uint256 _amount) storage _remainingAmount,
    uint256 _programId,
    address _token,
    uint256 _amount,
    uint48 _start,
    uint48 _duration
  ) external {
    uint256 _rate = (_amount * PRECISION) / _duration;
    uint256 _programAmount = (_rate * _duration) / PRECISION;

    _incentives[_programId] = IIncentiveStreaming.IncentiveProgram({
      token: _token, amount: _programAmount, rate: _rate, start: _start, end: _start + _duration, creator: msg.sender
    });
    _remainingAmount[_programId] = _programAmount;

    // slither-disable-next-line unused-return
    _incentivesByToken[_token].add(_programId);
    // slither-disable-next-line unused-return
    _incentivesByCreator[msg.sender].add(_programId);
    // slither-disable-next-line unused-return
    _rewards.add(_token);

    IERC20(_token).safeTransferFrom({from: msg.sender, to: address(this), value: _programAmount});
    emit IIncentiveStreaming.IncentiveCreated({
      _programId: _programId,
      _token: _token,
      _creator: msg.sender,
      _amount: _programAmount,
      _start: _start,
      _duration: _duration
    });
  }

  /**
   * @notice Collects fees from a gauge with bounded gas and return data
   * @param _gauge Address of the gauge to collect fees from
   * @return _collected0 Amount of token0 fees collected
   * @return _collected1 Amount of token1 fees collected
   */
  function collectGaugeFees(address _gauge) external returns (uint256 _collected0, uint256 _collected1) {
    (bool _success, bytes memory _data) = _gauge.excessivelySafeCall({
      _gas: _COLLECT_FEES_GAS_LIMIT,
      _value: 0,
      _maxCopy: 64, // 2 x uint256 - (uint256 _collected0, uint256 _collected1)
      _calldata: abi.encodeCall(IGauge.collectFees, ())
    });
    if (!_success) revert IVotingRewardsManager.FeeCollectionFailed(_gauge);

    (_collected0, _collected1) = abi.decode(_data, (uint256, uint256));
  }

  /**
   * @notice Computes tokens streamed during zero-voter intervals for an incentive program
   * @dev Measures the program window directly so partial checkpoint intervals are clipped to program bounds
   * @param _incentives Incentive program records keyed by program ID
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _sweptAmount Cumulative swept amounts keyed by program ID
   * @param _programId The program to compute
   * @param _globalIndex Latest global reward checkpoint index
   * @return The cumulative amount that may be swept
   * @return The additional amount that may be swept
   */
  function computeSweep(
    mapping(uint256 _programId => IIncentiveStreaming.IncentiveProgram _program) storage _incentives,
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    mapping(uint256 _programId => uint256 _amount) storage _sweptAmount,
    uint256 _programId,
    uint256 _globalIndex
  ) external view returns (uint256, uint256) {
    IIncentiveStreaming.IncentiveProgram memory _program = _incentives[_programId];

    uint256 _zeroSeconds =
      _zeroSupplySecondsInRange(_globalRewardPointHistory, _slopeChanges, _globalIndex, _program.start, _program.end);
    uint256 _cumulativeSweepable = (_program.rate * _zeroSeconds) / PRECISION;
    uint256 _alreadySwept = _sweptAmount[_programId];

    if (_cumulativeSweepable <= _alreadySwept) return (_cumulativeSweepable, 0);

    return (_cumulativeSweepable, _cumulativeSweepable - _alreadySwept);
  }

  /**
   * @notice Computes the accrued fees for a veNFT over a range of global checkpoints
   * @dev Permanent stakes settle in a single accumulator delta
   *      Decaying stakes combine deltas of the fee accumulator and its time-weighted counterpart to account for decay
   *      Assumes the fee time-weighted accumulator is rebased to `_params.accumulatorOrigin`
   *      Assumes `_params.startUserCp` is non-zero because user checkpoints begin at index 1
   *      This function mirrors `computeIncentiveRewards`, so shared logic changes must be reflected in both functions
   * @param _userRewardPointHistory Checkpoints for each veNFT by user checkpoint index
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _feeRewardPerVotingPowerAt Fee accumulator snapshots by global checkpoint index
   * @param _params The parameters to process the fee claim
   * @return The token0 fee reward
   * @return The token1 fee reward
   * @return The user checkpoint index reached
   * @return The global checkpoint index reached
   */
  function computeFeeRewards(
    mapping(
      uint256 _tokenId => IVotingCheckpoints.UserPoint[1_000_000_000] _userPoints
    ) storage _userRewardPointHistory,
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _checkpointIndex => IFeeDistribution.FeeSnapshot _snapshot) storage _feeRewardPerVotingPowerAt,
    FeeClaimParams memory _params
  ) external view returns (uint256, uint256, uint256, uint256) {
    FeeClaimCursor memory _cursor =
      FeeClaimCursor({currUserCp: _params.startUserCp, currGlobalCp: _params.from, numerator0: 0, numerator1: 0});

    while (_cursor.currUserCp <= _params.userCheckpointIndex) {
      /// @dev Stop before settling another user checkpoint once the budget is spent
      if (_params.maxCheckpoints == 0) break;

      IVotingCheckpoints.UserPoint memory _userPoint = _userRewardPointHistory[_params.tokenId][_cursor.currUserCp];

      /// @dev Skip the search after the first claim, once the start checkpoint is cached
      uint256 _gcpStart = _cursor.currGlobalCp > 0
        ? _cursor.currGlobalCp
        : _globalCpIndexAtOrAfter(
          _globalRewardPointHistory, _cursor.currGlobalCp, _params.globalCheckpointIndex, _userPoint.ts
        );

      /// @dev Stop when the user checkpoint has no closed global interval to price
      if (_gcpStart >= _params.globalCheckpointIndex) break;

      /// @dev Find the global CP for the next user boundary or use the latest global CP when none exists
      _cursor.currGlobalCp = (_cursor.currUserCp >= _params.userCheckpointIndex)
        ? _params.globalCheckpointIndex
        : _globalCpIndexAtOrAfter(
          _globalRewardPointHistory,
          _gcpStart,
          _params.globalCheckpointIndex,
          _userRewardPointHistory[_params.tokenId][_cursor.currUserCp + 1].ts
        );

      uint256 _activeEnd = _cursor.currGlobalCp;
      if (_userPoint.permanent == 0 && _userPoint.bias > 0) {
        /// @dev Derive stakeEnd per point, as it may change across the checkpoint history
        uint256 _stakeEnd = _userPoint.ts + _userPoint.bias.toUint256() / _userPoint.slope.toUint256();

        /// @dev Search for the expiry checkpoint only when it falls strictly before the interval's end
        ///      Stake expiries are epoch-aligned, ensuring each will have a matching global checkpoint
        uint256 _activeEndTs = _globalRewardPointHistory[_activeEnd].ts;
        if (_activeEndTs > _stakeEnd) {
          _activeEnd = _globalCpIndexAtOrAfter(_globalRewardPointHistory, _gcpStart, _cursor.currGlobalCp, _stakeEnd);
          _activeEndTs = _globalRewardPointHistory[_activeEnd].ts;
        }

        /// @dev Exclude the checkpoint at or after stake expiry, when the stake has no voting power
        ///      Required for fees to skip the zero contribution at expiry
        if (_activeEnd > 0 && _activeEndTs >= _stakeEnd) _activeEnd--;
      }

      /// @dev Price only non-empty checkpoint intervals with active weights
      if ((_userPoint.permanent > 0 || _userPoint.bias > 0) && _gcpStart < _activeEnd) {
        (uint256 _numerator0, uint256 _numerator1) =
          _priceFeeSpan(_feeRewardPerVotingPowerAt, _userPoint, _gcpStart, _activeEnd, _params.accumulatorOrigin);
        _cursor.numerator0 += _numerator0;
        _cursor.numerator1 += _numerator1;
      }

      _params.maxCheckpoints--;

      /// @dev If claiming the latest user checkpoint, keep it as the resume point for future claims
      if (_cursor.currUserCp >= _params.userCheckpointIndex) break;

      /// @dev Advance the user pointer to the next interval
      _cursor.currUserCp++;
    }

    return (
      _cursor.numerator0 / FEE_ACCUMULATOR_PRECISION,
      _cursor.numerator1 / FEE_ACCUMULATOR_PRECISION,
      _cursor.currUserCp,
      _cursor.currGlobalCp
    );
  }

  /**
   * @notice Computes a veNFT's incentive reward for a program over a range of global checkpoints
   * @dev Samples voting power and supply at the same right-aligned reference timestamp per interval so payouts
   *      conserve across claim paths and with sweep. Prices only closed global checkpoint intervals;
   *      the open interval is claimed once a checkpoint closes it. Inputs are bundled into a struct and
   *      the loop's mutable state lives in a memory cursor to stay within the stack-slot limit; reads no
   *      state beyond storage and writes none.
   *      Assumes `_params.startUserCp` is non-zero because user checkpoints begin at index 1
   *      This function mirrors `computeFeeRewards`, so shared logic changes must be reflected in both functions
   * @param _userRewardPointHistory Checkpoints for each veNFT by user checkpoint index
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _supplyAccumulatorAt Supply accumulator snapshots by global checkpoint index
   * @param _params The bundled computation inputs
   * @return The incentive reward accrued over the range
   * @return The last user checkpoint index examined, persisted as the resume row
   * @return The frontier: the global checkpoint index actually reached, never past where work was done
   */
  function computeIncentiveRewards(
    mapping(
      uint256 _tokenId => IVotingCheckpoints.UserPoint[1_000_000_000] _userPoints
    ) storage _userRewardPointHistory,
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    mapping(
      uint256 _checkpointIndex => IIncentiveStreaming.SupplyAccumulator _accumulator
    ) storage _supplyAccumulatorAt,
    IncentiveClaimParams memory _params
  ) external view returns (uint256, uint256, uint256) {
    IncentiveClaimCursor memory _cursor = IncentiveClaimCursor({
      currUserCp: _params.startUserCp, currGlobalCp: _params.from, numerator: 0
    });

    while (_cursor.currUserCp <= _params.userCheckpointIndex) {
      /// @dev Stop before settling another user checkpoint once the budget is spent
      if (_params.maxCheckpoints == 0) break;

      IVotingCheckpoints.UserPoint memory _userPoint = _userRewardPointHistory[_params.tokenId][_cursor.currUserCp];

      /// @dev Skip the search after the first claim, once the start checkpoint is cached
      uint256 _gcpStart = _cursor.currGlobalCp > 0
        ? _cursor.currGlobalCp
        : _globalCpIndexAtOrAfter(
          _globalRewardPointHistory, _cursor.currGlobalCp, _params.globalCheckpointIndex, _userPoint.ts
        );

      /// @dev Stop when the user checkpoint has no closed global interval to price
      if (_gcpStart >= _params.globalCheckpointIndex) break;

      /// @dev Find the global CP for the next user boundary or use the latest global CP when none exists
      _cursor.currGlobalCp = (_cursor.currUserCp >= _params.userCheckpointIndex)
        ? _params.globalCheckpointIndex
        : _globalCpIndexAtOrAfter(
          _globalRewardPointHistory,
          _gcpStart,
          _params.globalCheckpointIndex,
          _userRewardPointHistory[_params.tokenId][_cursor.currUserCp + 1].ts
        );

      uint256 _activeEnd = _cursor.currGlobalCp;
      if (_userPoint.permanent == 0 && _userPoint.bias > 0) {
        /// @dev Derive stakeEnd per point, as it may change across the checkpoint history
        uint256 _stakeEnd = _userPoint.ts + _userPoint.bias.toUint256() / _userPoint.slope.toUint256();

        /// @dev Search for the expiry checkpoint only when it falls strictly before the interval's end
        ///      Stake expiries are epoch-aligned, ensuring each will have a matching global checkpoint
        if (_globalRewardPointHistory[_activeEnd].ts > _stakeEnd) {
          _activeEnd = _globalCpIndexAtOrAfter(_globalRewardPointHistory, _gcpStart, _cursor.currGlobalCp, _stakeEnd);
        }
      }

      /// @dev Price only non-empty checkpoint intervals with active weights
      if ((_userPoint.permanent > 0 || _userPoint.bias > 0) && _gcpStart < _activeEnd) {
        _cursor.numerator += _priceIncentiveSpan(
          _globalRewardPointHistory, _slopeChanges, _supplyAccumulatorAt, _params, _userPoint, _gcpStart, _activeEnd
        );
      }

      _params.maxCheckpoints--;

      /// @dev If claiming the latest user checkpoint, keep it as the resume point for future claims
      if (_cursor.currUserCp >= _params.userCheckpointIndex) break;

      /// @dev Advance the user pointer to the next interval
      _cursor.currUserCp++;
    }

    return (_cursor.numerator / PRECISION, _cursor.currUserCp, _cursor.currGlobalCp);
  }

  /**
   * @notice Reverts if the caller is not authorized to claim rewards for a veNFT
   * @dev Authorizes the voter or the veNFT's registered operator
   * @param _voter Address of the voter contract
   * @param _tokenId ID of the veNFT whose claim authorization is checked
   */
  function checkAuthorized(address _voter, uint256 _tokenId) external view {
    if (msg.sender == _voter) return;
    if (msg.sender != ILeafVoter(_voter).operator(_tokenId)) revert IVotingRewardsManager.NotAuthorized();
  }

  /**
   * @notice Returns the latest global reward point index at or before a timestamp
   * @dev Uses binary search over recorded global reward checkpoints. Returns zero when no checkpoint exists
   *      at or before `_timestamp`.
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _epoch Latest global reward checkpoint index to search
   * @param _timestamp Timestamp to query
   * @return Index of the latest global reward point at or before `_timestamp`
   */
  function _globalCpIndexAtOrBefore(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    uint256 _epoch,
    uint256 _timestamp
  ) internal view returns (uint256) {
    if (_epoch == 0) return 0;
    if (_globalRewardPointHistory[_epoch].ts <= _timestamp) return _epoch;
    if (_globalRewardPointHistory[1].ts > _timestamp) return 0;

    uint256 _lower = 0;
    uint256 _upper = _epoch;
    while (_upper > _lower) {
      uint256 _center = _upper - (_upper - _lower) / 2;
      IVotingCheckpoints.GlobalPoint storage _globalPoint = _globalRewardPointHistory[_center];
      if (_globalPoint.ts == _timestamp) {
        return _center;
      } else if (_globalPoint.ts < _timestamp) {
        _lower = _center;
      } else {
        _upper = _center - 1;
      }
    }
    return _lower;
  }

  /**
   * @notice Returns aggregate reward voting power at a timestamp
   * @dev Starts from the latest checkpoint at or before `_timestamp`, applies scheduled slope changes up to
   *      the queried timestamp, and includes permanent voting power from that checkpoint.
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _epoch Latest global reward checkpoint index to search
   * @param _timestamp Timestamp to query
   * @return Aggregate reward voting power at `_timestamp`
   */
  function _supplyAt(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    uint256 _epoch,
    uint256 _timestamp
  ) internal view returns (uint256) {
    uint256 _pointIndex = _globalCpIndexAtOrBefore(_globalRewardPointHistory, _epoch, _timestamp);
    if (_pointIndex == 0) return 0;

    IVotingCheckpoints.GlobalPoint memory _point = _globalRewardPointHistory[_pointIndex];
    int128 _bias = _point.bias;
    int128 _slope = _point.slope;
    uint256 _ts = _point.ts;
    uint256 _t_i = (_ts / WEEK) * WEEK;
    for (uint256 _i = 0; _i < _MAX_CHECKPOINT_ITERATIONS; ++_i) {
      _t_i += WEEK;
      int128 _dSlope = 0;
      if (_t_i > _timestamp) {
        _t_i = _timestamp;
      } else {
        _dSlope = _slopeChanges[_t_i];
      }
      _bias -= _slope * (_t_i - _ts).toInt128();
      if (_t_i == _timestamp) break;
      _slope += _dSlope;
      _ts = _t_i;
    }

    if (_bias < 0) _bias = 0;
    return _bias.toUint256() + _point.permanentStakeBalance;
  }

  /**
   * @notice Evaluates a veNFT's decayed voting power at a target timestamp
   * @dev Assumes the target timestamp is greater than or equal to the reference timestamp
   *      Assumes there are no slope changes to be applied between the two timestamps
   * @param _bias Stored user point bias
   * @param _slope Stored user point slope
   * @param _ts Stored user point timestamp
   * @param _targetTs Target timestamp to decay to
   * @return Linearly decayed bias, floored at zero
   */
  function _computeDecayedBias(
    int128 _bias,
    int128 _slope,
    uint256 _ts,
    uint256 _targetTs
  ) internal pure returns (int128) {
    int128 _decay = _slope * int128(int256(_targetTs - _ts));
    return _bias > _decay ? _bias - _decay : int128(0);
  }

  /**
   * @notice Prices fee rewards over a global checkpoint range
   * @dev Assumes the checkpoint range is non-empty.
   * @param _feeRewardPerVotingPowerAt Fee accumulator snapshots by global checkpoint index
   * @param _userPoint The stake's active checkpoint over the range
   * @param _gStart Global checkpoint index marking the range start
   * @param _gEnd Global checkpoint index marking the range end
   * @param _accumulatorOrigin Origin timestamp of the time-weighted fee accumulator
   * @return The token0 fee reward numerator
   * @return The token1 fee reward numerator
   */
  function _priceFeeSpan(
    mapping(uint256 _checkpointIndex => IFeeDistribution.FeeSnapshot _snapshot) storage _feeRewardPerVotingPowerAt,
    IVotingCheckpoints.UserPoint memory _userPoint,
    uint256 _gStart,
    uint256 _gEnd,
    uint256 _accumulatorOrigin
  ) private view returns (uint256, uint256) {
    IFeeDistribution.FeeSnapshot storage _accEnd = _feeRewardPerVotingPowerAt[_gEnd];
    IFeeDistribution.FeeSnapshot storage _accStart = _feeRewardPerVotingPowerAt[_gStart];

    if (_userPoint.permanent > 0) {
      /// @dev Permanent stakes settle in a single delta since weights stay constant
      return (
        _userPoint.permanent * (_accEnd.feeReward0 - _accStart.feeReward0),
        _userPoint.permanent * (_accEnd.feeReward1 - _accStart.feeReward1)
      );
    } else if (_userPoint.bias > 0) {
      /// @dev Non-permanent stakes settle in two accumulator deltas to account for decaying weights
      uint256 _slope = _userPoint.slope.toUint256();
      uint256 _coeff = _userPoint.bias.toUint256() + _slope * (_userPoint.ts - _accumulatorOrigin);

      return (
        _decayingStakeNumerator(
          _coeff, _slope, _accEnd.feeReward0 - _accStart.feeReward0, _accEnd.feeReward0xTime - _accStart.feeReward0xTime
        ),
        _decayingStakeNumerator(
          _coeff, _slope, _accEnd.feeReward1 - _accStart.feeReward1, _accEnd.feeReward1xTime - _accStart.feeReward1xTime
        )
      );
    }

    return (0, 0);
  }

  /**
   * @notice Prices a veNFT's reward over the global checkpoint range `[_gStart, _gEnd)` for a program
   * @dev Prices the full interior intervals from one supply accumulator delta and prices the partial
   *      intervals at the program boundaries directly so their time is clipped to the program window. The
   *      returned numerator is scaled by `PRECISION`.
   *      Assumes the checkpoint range is non-empty.
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _supplyAccumulatorAt Supply accumulator snapshots by global checkpoint index
   * @param _params The bundled computation inputs
   * @param _userPoint The veNFT's active checkpoint over the range
   * @param _gStart Global checkpoint index marking the range start (inclusive)
   * @param _gEnd Global checkpoint index marking the range end (exclusive)
   * @return The reward numerator contribution for the range
   */
  function _priceIncentiveSpan(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    mapping(
      uint256 _checkpointIndex => IIncentiveStreaming.SupplyAccumulator _accumulator
    ) storage _supplyAccumulatorAt,
    IncentiveClaimParams memory _params,
    IVotingCheckpoints.UserPoint memory _userPoint,
    uint256 _gStart,
    uint256 _gEnd
  ) private view returns (uint256) {
    uint256 _startIndex = _gStart;
    /// @dev Search for the first checkpoint at or after program start when it is strictly after the interval's start
    if (_params.startTs > _globalRewardPointHistory[_gStart].ts) {
      _startIndex = _globalCpIndexAtOrAfter(_globalRewardPointHistory, _gStart, _gEnd, _params.startTs);
    }

    bool _endStraddles = false;
    uint256 _endIndex = _gEnd;
    /// @dev Search for the first checkpoint at or after program end when it is strictly before the interval's end
    if (_params.endTs < _globalRewardPointHistory[_gEnd].ts) {
      _endIndex = _globalCpIndexAtOrAfter(_globalRewardPointHistory, _gStart, _gEnd, _params.endTs);
      /// @dev Check if the program ends mid-interval, requiring its final span to be priced as a trailing partial
      _endStraddles = _globalRewardPointHistory[_endIndex].ts > _params.endTs;
    }
    uint256 _interiorEnd = _endStraddles ? _endIndex - 1 : _endIndex;

    /// @dev Programs span at least one week and intervals are at most one week, so program start and end never
    ///      fall in the same interval; the index guards keep the leading and trailing partials distinct.
    uint256 _numerator = 0;
    /// @dev Leading partial: the interval straddling program start, time-clipped to the window.
    if (_startIndex > _gStart && _startIndex <= _interiorEnd) {
      _numerator += _priceIncentivePartialSpan(
        _globalRewardPointHistory, _slopeChanges, _params, _userPoint, _startIndex - 1
      );
    }
    /// @dev Full interior intervals priced in bulk from one accumulator delta.
    if (_interiorEnd > _startIndex) {
      _numerator += _priceIncentiveInteriorSpan(_supplyAccumulatorAt, _params, _userPoint, _startIndex, _interiorEnd);
    }
    /// @dev Trailing partial: the interval straddling program end.
    if (_endStraddles && _endIndex > _startIndex) {
      _numerator += _priceIncentivePartialSpan(
        _globalRewardPointHistory, _slopeChanges, _params, _userPoint, _endIndex - 1
      );
    }
    return _numerator;
  }

  /**
   * @notice Prices a run of full interior intervals `[_gStart, _gEnd)` from the supply accumulator deltas
   * @dev Accumulator deltas encode each full interval's right-aligned supply reference. Permanent voter:
   *      `rate * permanent * dSharePerVote`. Decaying voter:
   *      `rate * (coeff * dSharePerVote - slope * dWeightedSharePerVote)` with
   *      `coeff = bias + slope * (userTs - origin)`. Scaled by `PRECISION`
   * @param _supplyAccumulatorAt Supply accumulator snapshots by global checkpoint index
   * @param _params The bundled computation inputs
   * @param _userPoint The veNFT's active checkpoint over the range
   * @param _gStart Global checkpoint index marking the interior range start
   * @param _gEnd Global checkpoint index marking the interior range end
   * @return The reward numerator contribution for the interior intervals
   */
  function _priceIncentiveInteriorSpan(
    mapping(
      uint256 _checkpointIndex => IIncentiveStreaming.SupplyAccumulator _accumulator
    ) storage _supplyAccumulatorAt,
    IncentiveClaimParams memory _params,
    IVotingCheckpoints.UserPoint memory _userPoint,
    uint256 _gStart,
    uint256 _gEnd
  ) private view returns (uint256) {
    IIncentiveStreaming.SupplyAccumulator storage _accEnd = _supplyAccumulatorAt[_gEnd];
    IIncentiveStreaming.SupplyAccumulator storage _accStart = _supplyAccumulatorAt[_gStart];

    uint256 _numerator = 0;
    if (_userPoint.permanent > 0) {
      /// @dev Use permanent * deltaSharePerVote separated from rate to avoid rate * permanent pre-multiplication (overflow); accumulator units are the bounded factor.
      _numerator = _userPoint.permanent * (_accEnd.sharePerVote - _accStart.sharePerVote);
    } else if (_userPoint.bias > 0) {
      /// @dev Non-permanent stakes settle in two accumulator deltas to account for decaying weights
      uint256 _slope = _userPoint.slope.toUint256();

      _numerator = _decayingStakeNumerator(
        _userPoint.bias.toUint256() + _slope * (_userPoint.ts - _params.accumulatorOrigin),
        _slope,
        _accEnd.sharePerVote - _accStart.sharePerVote,
        _accEnd.weightedSharePerVote - _accStart.weightedSharePerVote
      );
    }

    /// @dev Scale the accumulator numerator by the program rate
    return Math.mulDiv(_params.rate, _numerator, _ACCUMULATOR_PRECISION);
  }

  /**
   * @notice Computes one closed global checkpoint interval's reward numerator for a veNFT
   * @dev Split out so the per-interval locals get their own stack frame. Samples voting power and supply
   *      at `paidEnd - 1`, with reward duration clipped to the paid program overlap. The returned numerator is
   *      scaled by `PRECISION`.
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _params The bundled computation inputs
   * @param _userPoint The veNFT's active checkpoint over the interval
   * @param _g Global checkpoint index marking the interval start
   * @return The reward numerator contribution for the interval
   */
  function _priceIncentivePartialSpan(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    IncentiveClaimParams memory _params,
    IVotingCheckpoints.UserPoint memory _userPoint,
    uint256 _g
  ) private view returns (uint256) {
    uint256 _globalTs = _globalRewardPointHistory[_g].ts;
    uint256 _paidStart = Math.max(_globalTs, _params.startTs);
    uint256 _paidEnd = Math.min(_globalRewardPointHistory[_g + 1].ts, _params.endTs);
    if (_paidEnd <= _paidStart) return 0;

    /// @dev Right-aligned reference rule: the end boundary belongs to the next interval, so sample the
    ///      final included second of the clipped paid interval.
    uint256 _refTs = _paidEnd - 1;

    uint256 _supply = _supplyAt(_globalRewardPointHistory, _slopeChanges, _params.globalCheckpointIndex, _refTs);
    if (_supply == 0) return 0;

    uint256 _votingPower = _userPoint.permanent > 0
      ? _userPoint.permanent
      : _computeDecayedBias(_userPoint.bias, _userPoint.slope, _userPoint.ts, _refTs).toUint256();
    /// @dev Keep the large program rate inside mulDiv; votingPower * dt is the bounded share-time term.
    return Math.mulDiv(_params.rate, _votingPower * (_paidEnd - _paidStart), _supply);
  }

  /**
   * @notice Returns zero-supply seconds in the half-open range `[_start, _end)`
   * @dev Prices leading and trailing partial intervals with the claim path's right-aligned reference and uses
   *      stored prefix deltas only for full checkpoint-aligned intervals. Assumes global history begins at or
   *      before `_start` and `_end > _start`.
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _slopeChanges Scheduled aggregate slope changes by timestamp
   * @param _globalIndex Latest global reward checkpoint index
   * @param _start Inclusive lower bound of the range
   * @param _end Exclusive upper bound of the range
   * @return Zero-supply seconds inside the range
   */
  function _zeroSupplySecondsInRange(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    mapping(uint256 _timestamp => int128 _slopeChange) storage _slopeChanges,
    uint256 _globalIndex,
    uint256 _start,
    uint256 _end
  ) private view returns (uint256) {
    uint256 _zeroSeconds = 0;
    uint256 _startIndex = _globalCpIndexAtOrBefore(_globalRewardPointHistory, _globalIndex, _start);
    /// @dev Tracks the checkpoint that starts the full prefix-delta range. It is `_startIndex` unless the
    ///      leading partial interval is split off, in which case the full range starts at the next checkpoint.
    uint256 _alignedStartIndex = _startIndex;

    if (_globalRewardPointHistory[_startIndex].ts < _start) {
      uint256 _partialEnd = Math.min(_end, _globalRewardPointHistory[_startIndex + 1].ts);
      /// @dev Leading partials are priced from their clipped end, not the full checkpoint interval end.
      if (_supplyAt(_globalRewardPointHistory, _slopeChanges, _globalIndex, _partialEnd - 1) == 0) {
        _zeroSeconds += _partialEnd - _start;
      }
      _start = _partialEnd;
      /// @dev If the remaining range was fully consumed by the leading partial, there are no aligned or
      ///      trailing intervals to price.
      if (_end <= _start) return _zeroSeconds;
      /// @dev `_start` is now the next checkpoint timestamp, so the aligned prefix delta can start from the
      ///      next checkpoint without another binary search.
      _alignedStartIndex = _startIndex + 1;
    }

    /// @dev `_alignedEnd` is the last checkpoint timestamp at or before `_end`. If `_end` lands inside an
    ///      interval, the prefix delta stops at that checkpoint and the final partial is handled below.
    uint256 _endIndex = _globalCpIndexAtOrBefore(_globalRewardPointHistory, _globalIndex, _end);
    uint256 _alignedEnd = _globalRewardPointHistory[_endIndex].ts;
    bool _hasTrailingPartial = _alignedEnd < _end;

    if (_alignedEnd > _start) {
      /// @dev Stored zero-supply prefixes are only valid for complete checkpoint-aligned intervals.
      uint256 _endZeroSeconds = _globalRewardPointHistory[_endIndex].zeroSupplySeconds;
      uint256 _startZeroSeconds = _globalRewardPointHistory[_alignedStartIndex].zeroSupplySeconds;
      _zeroSeconds += _endZeroSeconds - _startZeroSeconds;
    }

    /// @dev Trailing partials are priced from `end - 1`, matching `_priceIncentivePartialSpan`.
    if (_hasTrailingPartial && _supplyAt(_globalRewardPointHistory, _slopeChanges, _globalIndex, _end - 1) == 0) {
      _zeroSeconds += _end - _alignedEnd;
    }

    return _zeroSeconds;
  }

  /**
   * @notice Finds the first global checkpoint at or after a timestamp within a bounded range
   * @dev Binary searches `_globalRewardPointHistory` over the inclusive range `[_lo, _hi]`
   *      Returns `_lo` when `_ts` precedes the range and `_hi` when `_ts` follows the range
   * @param _globalRewardPointHistory Aggregate voting-power checkpoints by global checkpoint index
   * @param _lo The lower bound of the search range
   * @param _hi The upper bound of the search range
   * @param _ts The timestamp to locate
   * @return The first global checkpoint index whose timestamp is at or after `_ts`, clamped to the search range
   */
  function _globalCpIndexAtOrAfter(
    mapping(uint256 _index => IVotingCheckpoints.GlobalPoint _globalPoint) storage _globalRewardPointHistory,
    uint256 _lo,
    uint256 _hi,
    uint256 _ts
  ) private view returns (uint256) {
    uint256 _mid;
    uint256 _midTs;
    while (_lo < _hi) {
      _mid = _lo + (_hi - _lo) / 2;
      _midTs = _globalRewardPointHistory[_mid].ts;
      /// @dev Timestamps are strictly increasing, so an exact match is the lower bound
      if (_midTs == _ts) {
        return _mid;
      } else if (_midTs < _ts) {
        _lo = _mid + 1;
      } else {
        _hi = _mid;
      }
    }
    return _lo;
  }

  /**
   * @notice Computes a decaying stake's reward numerator from accumulator deltas
   * @dev For voting power `bias - slope * (t - userTs)`, the sum of power times per-vote increments over a
   *      checkpoint range telescopes into `coeff * deltaAcc - slope * deltaAccXTime`, with
   *      `coeff = bias + slope * (userTs - accumulatorOrigin)`.
   *      Assumes the time-weighted accumulator and `coeff` use the same accumulator origin.
   *      Assumes the checkpoint range is clipped at stake expiry.
   * @param _coeff The constant coefficient of the stake's decay function
   * @param _slope The stake's decay rate
   * @param _deltaAcc Delta of the per-vote accumulator over the range
   * @param _deltaAccXTime Delta of the time-weighted per-vote accumulator over the range
   * @return The reward numerator in the accumulator's scale
   */
  function _decayingStakeNumerator(
    uint256 _coeff,
    uint256 _slope,
    uint256 _deltaAcc,
    uint256 _deltaAccXTime
  ) private pure returns (uint256) {
    uint256 _positiveUnits = _coeff * _deltaAcc;
    uint256 _negativeUnits = _slope * _deltaAccXTime;

    /// @dev Clamp accumulator-rounding differences to zero
    return _positiveUnits <= _negativeUnits ? 0 : _positiveUnits - _negativeUnits;
  }
}
