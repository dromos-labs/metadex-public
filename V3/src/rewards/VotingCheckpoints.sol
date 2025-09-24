// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';
import {RewardsLogicLibrary} from 'V3/libraries/RewardsLogicLibrary.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

/**
 * @title Voting Checkpoints
 * @notice Tracks and manages weights allocated by veNFTs to Rewards contracts
 */
abstract contract VotingCheckpoints is IVotingCheckpoints {
  using SafeCastLibrary for int128;
  using SafeCastLibrary for uint256;

  /// @inheritdoc IVotingCheckpoints
  uint256 public constant MAX_CHECKPOINT_ITERATIONS = RewardsLogicLibrary._MAX_CHECKPOINT_ITERATIONS;

  /// @inheritdoc IVotingCheckpoints
  uint256 public immutable ACCUMULATOR_ORIGIN;

  /// @inheritdoc IVotingCheckpoints
  uint128 public permanentStakeBalance;
  /// @inheritdoc IVotingCheckpoints
  uint256 public globalCheckpointIndex;

  /// @inheritdoc IVotingCheckpoints
  mapping(uint256 _tokenId => uint256 _userRewardCheckpointIndex) public userRewardCheckpointIndex;
  /// @inheritdoc IVotingCheckpoints
  mapping(uint256 _timestamp => int128 _slopeChange) public slopeChanges;
  /// @inheritdoc IVotingCheckpoints
  mapping(uint256 _tokenId => uint256 _stakeEnd) public stakeExpiry;

  /// @dev Checkpoints each veNFT's reward voting power by token ID and user checkpoint index.
  mapping(uint256 _tokenId => UserPoint[1_000_000_000] _userPoints) internal _userRewardPointHistory;
  /// @dev Checkpoints aggregate reward voting power and zero-supply prefix state by global checkpoint index.
  mapping(uint256 _index => GlobalPoint _globalPoint) internal _globalRewardPointHistory;

  /**
   * @notice Constructor function to initialize the contract
   */
  constructor() {
    ACCUMULATOR_ORIGIN = block.timestamp;
  }

  /// @inheritdoc IVotingCheckpoints
  function globalRewardPointHistory(uint256 _index) external view returns (GlobalPoint memory) {
    return _globalRewardPointHistory[_index];
  }

  /// @inheritdoc IVotingCheckpoints
  function userRewardPointHistory(uint256 _tokenId, uint256 _index) external view returns (UserPoint memory) {
    return _userRewardPointHistory[_tokenId][_index];
  }

  /// @inheritdoc IVotingCheckpoints
  function getPriorSupplyIndex(uint256 _timestamp) external view returns (uint256) {
    return _globalCpIndexAtOrBefore(globalCheckpointIndex, _timestamp);
  }

  /// @inheritdoc IVotingCheckpoints
  function supplyAt(uint256 _timestamp) external view returns (uint256) {
    return _supplyAt(globalCheckpointIndex, _timestamp);
  }

  /// @inheritdoc IVotingCheckpoints
  function getPriorBalanceIndex(uint256 _tokenId, uint256 _timestamp) external view returns (uint256) {
    return _getPastUserPointIndex(_tokenId, _timestamp);
  }

  /// @inheritdoc IVotingCheckpoints
  function balanceOfNFTAt(uint256 _tokenId, uint256 _timestamp) external view returns (uint256) {
    return _balanceOfNFTAt(_tokenId, _timestamp);
  }

  /// @inheritdoc IVotingCheckpoints
  function totalSupply() public view returns (uint256) {
    return _supplyAt(globalCheckpointIndex, block.timestamp);
  }

  /**
   * @notice Updates the voting weight allocation for a given veNFT
   * @dev Assumes `_allocated` is at least `MAXTIME` for non-permanent stakes
   *      Assumes the veNFT's stake has not expired
   *      Assumes stale checkpoint calls are skipped upstream
   *      Permanent stakes are signaled via a zero `_stakeEnd`
   * @param _tokenId Unique identifier of the veNFT
   * @param _allocated Allocation amount for this gauge's reward contract
   * @param _stakeEnd Expiration timestamp of the veNFT's stake
   * @param _data Extensible calldata forwarded by the caller
   */
  function _checkpoint(uint256 _tokenId, uint128 _allocated, uint48 _stakeEnd, bytes calldata _data) internal {
    UserPoint memory _userRewardPoint = UserPoint({bias: 0, slope: 0, permanent: 0, ts: block.timestamp.toUint48()});

    uint256 _userCheckpointIndex = userRewardCheckpointIndex[_tokenId];
    UserPoint memory _prevUserRewardPoint = _userRewardPointHistory[_tokenId][_userCheckpointIndex];
    uint256 _prevStakeEnd = 0;

    if (_stakeEnd == 0) {
      _userRewardPoint.permanent = _allocated;

      /// @dev Reset the previous allocation if transitioning from a non-permanent stake
      if (_prevUserRewardPoint.slope > 0) {
        _userCheckpointIndex = _reset(_tokenId);
        _prevUserRewardPoint = UserPoint({bias: 0, slope: 0, permanent: 0, ts: block.timestamp.toUint48()});
      }
      permanentStakeBalance = permanentStakeBalance - _prevUserRewardPoint.permanent + _allocated;
    } else {
      _userRewardPoint.slope = int128(_allocated / MAXTIME);
      _userRewardPoint.bias = _userRewardPoint.slope * int128(uint128(_stakeEnd - uint48(block.timestamp)));

      /// @dev Reset the previous allocation if transitioning from a permanent stake or the stake end has changed
      if (_prevUserRewardPoint.permanent > 0) {
        _userCheckpointIndex = _reset(_tokenId);
        _prevUserRewardPoint = UserPoint({bias: 0, slope: 0, permanent: 0, ts: block.timestamp.toUint48()});
      } else {
        _prevStakeEnd = stakeExpiry[_tokenId];
        if (_prevStakeEnd != _stakeEnd && _prevStakeEnd != 0) {
          _userCheckpointIndex = _reset(_tokenId);
          _prevUserRewardPoint = UserPoint({bias: 0, slope: 0, permanent: 0, ts: block.timestamp.toUint48()});
        }
      }

      /// @dev Adjust the slope change scheduled at the stake end and store the new stake expiry
      slopeChanges[_stakeEnd] += _prevUserRewardPoint.slope - _userRewardPoint.slope;
      stakeExpiry[_tokenId] = _stakeEnd;
    }

    /// @dev Record allocation checkpoints
    _saveUserRewardPoint(_userRewardPoint, _prevUserRewardPoint.ts, _tokenId, _userCheckpointIndex);
    _createGlobalRewardPoints(
      _userRewardPoint, _prevUserRewardPoint, _prevStakeEnd, _stakeEnd, MAX_CHECKPOINT_ITERATIONS
    );

    emit Checkpoint(msg.sender, _tokenId, _allocated);
  }

  /**
   * @notice Clears the existing voting weight allocation for a given veNFT
   * @param _tokenId Unique identifier of the veNFT
   * @return Resulting user checkpoint index after reset
   */
  function _reset(uint256 _tokenId) internal returns (uint256) {
    uint256 _userCheckpointIndex = userRewardCheckpointIndex[_tokenId];
    UserPoint memory _prevUserRewardPoint = _userRewardPointHistory[_tokenId][_userCheckpointIndex];
    uint256 _prevStakeEnd = 0;

    if (_prevUserRewardPoint.permanent > 0) {
      permanentStakeBalance -= _prevUserRewardPoint.permanent;
    } else if (_prevUserRewardPoint.slope > 0) {
      _prevStakeEnd = stakeExpiry[_tokenId];
      /// @dev Cancel the previously scheduled slope change if the veNFT has not expired
      ///      Safe to overwrite because slope changes are only applied after stake expiry
      if (_prevStakeEnd > block.timestamp) {
        slopeChanges[_prevStakeEnd] += _prevUserRewardPoint.slope;
      }
      delete stakeExpiry[_tokenId];
    }

    /// @dev Record allocation checkpoints
    UserPoint memory _userRewardPoint = UserPoint({bias: 0, slope: 0, permanent: 0, ts: block.timestamp.toUint48()});
    _userCheckpointIndex =
      _saveUserRewardPoint(_userRewardPoint, _prevUserRewardPoint.ts, _tokenId, _userCheckpointIndex);
    _createGlobalRewardPoints(_userRewardPoint, _prevUserRewardPoint, _prevStakeEnd, 0, MAX_CHECKPOINT_ITERATIONS);

    emit Reset(msg.sender, _tokenId);

    return _userCheckpointIndex;
  }

  /**
   * @notice Records a new user checkpoint, overwriting if the previous shares the same timestamp
   * @param _userRewardPoint New user point to write
   * @param _prevCheckpointTs Timestamp of the previous user point
   * @param _tokenId Unique identifier of the veNFT
   * @param _userCheckpointIndex Current user checkpoint index
   * @return Updated user checkpoint index
   */
  function _saveUserRewardPoint(
    UserPoint memory _userRewardPoint,
    uint256 _prevCheckpointTs,
    uint256 _tokenId,
    uint256 _userCheckpointIndex
  ) internal returns (uint256) {
    /// @dev Overwrite the last user reward point if it shares the current block.timestamp
    ///      Otherwise, append a new user reward point and increment the index
    if (_prevCheckpointTs == block.timestamp && _userCheckpointIndex != 0) {
      _userRewardPointHistory[_tokenId][_userCheckpointIndex] = _userRewardPoint;
    } else {
      userRewardCheckpointIndex[_tokenId] = ++_userCheckpointIndex;
      _userRewardPointHistory[_tokenId][_userCheckpointIndex] = _userRewardPoint;
    }
    return _userCheckpointIndex;
  }

  /**
   * @notice Records a global reward checkpoint
   * @dev Fills any unrecorded global checkpoints since the last checkpoint
   *      If a checkpoint already exists at the current block.timestamp, it is overwritten
   *      Adapted from `VotingEscrow._checkpoint()`
   * @param _userRewardPoint The updated checkpoint for the veNFT
   * @param _prevUserRewardPoint The previous checkpoint for the veNFT
   * @param _prevStakeEnd The veNFT's prior expiry timestamp (zero if first checkpoint or after reset)
   * @param _stakeEnd The veNFT's expiry timestamp
   * @param _maxIterations Maximum number of week boundaries to process
   */
  function _createGlobalRewardPoints(
    UserPoint memory _userRewardPoint,
    UserPoint memory _prevUserRewardPoint,
    uint256 _prevStakeEnd,
    uint256 _stakeEnd,
    uint256 _maxIterations
  ) internal virtual;

  /**
   * @notice Returns the latest global reward point index at or before a timestamp
   * @dev Uses binary search over recorded global reward checkpoints. Returns zero when no checkpoint exists
   *      at or before `_timestamp`.
   * @param _epoch Latest global reward checkpoint index to search
   * @param _timestamp Timestamp to query
   * @return Index of the latest global reward point at or before `_timestamp`
   */
  function _globalCpIndexAtOrBefore(uint256 _epoch, uint256 _timestamp) internal view returns (uint256) {
    return RewardsLogicLibrary._globalCpIndexAtOrBefore(_globalRewardPointHistory, _epoch, _timestamp);
  }

  /**
   * @notice Binary search to get the user point index for a token id at or prior to a given timestamp
   * @dev If a user point does not exist prior to the timestamp, this will return 0.
   * @param _tokenId The token ID to query
   * @param _timestamp Timestamp to query
   * @return User point index
   */
  function _getPastUserPointIndex(uint256 _tokenId, uint256 _timestamp) internal view returns (uint256) {
    uint256 _userEpoch = userRewardCheckpointIndex[_tokenId];
    if (_userEpoch == 0) return 0;
    // First check most recent balance
    if (_userRewardPointHistory[_tokenId][_userEpoch].ts <= _timestamp) return (_userEpoch);
    // Next check implicit zero balance
    if (_userRewardPointHistory[_tokenId][1].ts > _timestamp) return 0;

    uint256 _lower = 0;
    uint256 _upper = _userEpoch;
    while (_upper > _lower) {
      uint256 _center = _upper - (_upper - _lower) / 2; // ceil, avoiding overflow
      UserPoint storage _userPoint = _userRewardPointHistory[_tokenId][_center];
      if (_userPoint.ts == _timestamp) {
        return _center;
      } else if (_userPoint.ts < _timestamp) {
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
   * @param _epoch Latest global reward checkpoint index to search
   * @param _timestamp Timestamp to query
   * @return Aggregate reward voting power at `_timestamp`
   */
  function _supplyAt(uint256 _epoch, uint256 _timestamp) internal view returns (uint256) {
    return RewardsLogicLibrary._supplyAt(_globalRewardPointHistory, slopeChanges, _epoch, _timestamp);
  }

  /**
   * @notice Calculates the voting power allocated by a veNFT at a given timestamp
   * @dev Adheres to the ERC20 `balanceOf` interface for Aragon compatibility
   *      Fetches last user point prior to a certain timestamp, then walks forward to timestamp.
   * @param _tokenId The token ID to query
   * @param _t Timestamp to return voting power at
   * @return The veNFT's voting power at the given timestamp
   */
  function _balanceOfNFTAt(uint256 _tokenId, uint256 _t) internal view returns (uint256) {
    uint256 _epoch = _getPastUserPointIndex(_tokenId, _t);
    // epoch 0 is an empty point
    if (_epoch == 0) return 0;
    UserPoint memory _lastPoint = _userRewardPointHistory[_tokenId][_epoch];
    if (_lastPoint.permanent != 0) {
      return _lastPoint.permanent;
    } else {
      _lastPoint.bias -= _lastPoint.slope * (_t - _lastPoint.ts).toInt128();
      if (_lastPoint.bias < 0) {
        _lastPoint.bias = 0;
      }
      return _lastPoint.bias.toUint256();
    }
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
    return RewardsLogicLibrary._computeDecayedBias(_bias, _slope, _ts, _targetTs);
  }
}
