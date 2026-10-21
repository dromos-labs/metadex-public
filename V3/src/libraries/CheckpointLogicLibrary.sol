// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

/// @title CheckpointLogicLibrary
/// @notice Global-point checkpoint math for VotingEscrow, extracted to an external library so the core contract
///         keeps only a DELEGATECALL and stays under the EIP-170 runtime size limit.
library CheckpointLogicLibrary {
  using SafeCastLibrary for uint256;
  using SafeCastLibrary for int128;

  /// @notice Value-type inputs for `checkpoint`, bundled into one memory struct to keep the call within the
  ///         legacy-codegen stack limit (the four storage mappings already consume most of it).
  /// @param epoch Global epoch value held in storage at call time.
  /// @param permanentStakeBalance Current permanent stake balance, synced into the advanced global point.
  /// @param tokenId tokenId being checkpointed (0 performs a global-only checkpoint).
  /// @param oldStaked Previous StakedBalance for the tokenId.
  /// @param newStaked Target StakedBalance for the tokenId.
  struct CheckpointInput {
    uint256 epoch;
    uint128 permanentStakeBalance;
    uint256 tokenId;
    IVotingEscrow.StakedBalance oldStaked;
    IVotingEscrow.StakedBalance newStaked;
  }

  /// @notice Maximum staking time as int128, the slope denominator.
  int128 internal constant _I_MAXTIME = int128(uint128(MAXTIME));

  /// @notice Record a global checkpoint and, when `_input.tokenId != 0`, the per-token user point for an old -> new
  ///         stake transition.
  /// @dev Mirrors the former `VotingEscrow._checkpoint`. Linked as an external library: storage mappings are shared
  ///      through the delegatecall, value-type state arrives via `_input`, and the epoch to persist is returned so
  ///      the caller writes `epoch` itself. `_I_MAXTIME` derives from MAXTIME.
  /// @param _pointHistory Global point history by epoch.
  /// @param _slopeChanges Scheduled slope changes keyed by unlock week.
  /// @param _userPointEpoch Latest user point epoch by tokenId.
  /// @param _userPointHistory User point history by tokenId.
  /// @param _input Bundled value-type inputs (see CheckpointInput).
  /// @return _newEpoch The epoch value the caller must persist to storage after the checkpoint.
  function checkpoint(
    mapping(uint256 => IVotingEscrow.GlobalPoint) storage _pointHistory,
    mapping(uint48 => int128) storage _slopeChanges,
    mapping(uint256 => uint256) storage _userPointEpoch,
    mapping(uint256 => IVotingEscrow.UserPoint[1_000_000_000]) storage _userPointHistory,
    CheckpointInput memory _input
  ) external returns (uint256 _newEpoch) {
    IVotingEscrow.UserPoint memory _uOld = IVotingEscrow.UserPoint({bias: 0, slope: 0, ts: 0, permanent: 0});
    IVotingEscrow.UserPoint memory _uNew = IVotingEscrow.UserPoint({bias: 0, slope: 0, ts: 0, permanent: 0});
    int128 _oldDslope = 0;
    int128 _newDslope = 0;
    // Working epoch; equals the storage `epoch` at entry and is advanced through the loop below.
    _newEpoch = _input.epoch;

    // Build the old/new user points and read the scheduled slope changes at the two ends.
    if (_input.tokenId != 0) {
      _uNew.permanent = _input.newStaked.isPermanent ? _input.newStaked.amount : 0;
      // Amount-to-int128 cast is safe because credit sites enforce `_staked[id].amount <= type(int128).max`.
      if (_input.oldStaked.end > block.timestamp && _input.oldStaked.amount > 0) {
        _uOld.slope = uint256(_input.oldStaked.amount).toInt128() / _I_MAXTIME;
        _uOld.bias = _uOld.slope * (uint256(_input.oldStaked.end) - block.timestamp).toInt128();
      }
      if (_input.newStaked.end > block.timestamp && _input.newStaked.amount > 0) {
        _uNew.slope = uint256(_input.newStaked.amount).toInt128() / _I_MAXTIME;
        _uNew.bias = _uNew.slope * (uint256(_input.newStaked.end) - block.timestamp).toInt128();
      }

      _oldDslope = _slopeChanges[_input.oldStaked.end];
      if (_input.newStaked.end != 0) {
        if (_input.newStaked.end == _input.oldStaked.end) {
          _newDslope = _oldDslope;
        } else {
          _newDslope = _slopeChanges[_input.newStaked.end];
        }
      }
    }

    IVotingEscrow.GlobalPoint memory _lastPoint =
      IVotingEscrow.GlobalPoint({bias: 0, slope: 0, ts: block.timestamp.toUint48(), permanentStakeBalance: 0});
    if (_input.epoch > 0) {
      _lastPoint = _pointHistory[_input.epoch];
    }
    uint256 _lastCheckpoint = _lastPoint.ts;

    // Walk week boundaries up to now, recording a global point per crossed week (capped at 255 iterations).
    {
      uint256 _ti = (_lastCheckpoint / WEEK) * WEEK;
      for (uint256 i = 0; i < 255; ++i) {
        _ti += WEEK;
        int128 _dSlope = 0;
        if (_ti > block.timestamp) {
          _ti = block.timestamp;
        } else {
          _dSlope = _slopeChanges[_ti.toUint48()];
        }
        _lastPoint.bias -= _lastPoint.slope * (_ti - _lastCheckpoint).toInt128();
        _lastPoint.slope += _dSlope;
        if (_lastPoint.bias < 0) _lastPoint.bias = 0;
        if (_lastPoint.slope < 0) _lastPoint.slope = 0;
        _lastCheckpoint = _ti;
        _lastPoint.ts = _ti.toUint48();
        _newEpoch += 1;
        if (_ti == block.timestamp) {
          break;
        } else {
          _pointHistory[_newEpoch] = _lastPoint;
        }
      }
    }

    // Fold this token's slope/bias delta into the advanced global point.
    if (_input.tokenId != 0) {
      _lastPoint.slope += (_uNew.slope - _uOld.slope);
      _lastPoint.bias += (_uNew.bias - _uOld.bias);
      if (_lastPoint.slope < 0) _lastPoint.slope = 0;
      if (_lastPoint.bias < 0) _lastPoint.bias = 0;
    }
    // Synced unconditionally so accumulator credits and standalone checkpoint() stay in step with storage.
    _lastPoint.permanentStakeBalance = _input.permanentStakeBalance;

    // Persist the global point: overwrite the latest if it shares this timestamp, otherwise append a new epoch.
    // When overwriting, the storage epoch must stay put, so the original value is returned to the caller.
    if (_newEpoch != 1 && _pointHistory[_newEpoch - 1].ts == block.timestamp) {
      _pointHistory[_newEpoch - 1] = _lastPoint;
      _newEpoch = _input.epoch;
    } else {
      _pointHistory[_newEpoch] = _lastPoint;
    }

    // Reschedule the slope changes at the old/new ends and append the new user point.
    if (_input.tokenId != 0) {
      if (_input.oldStaked.end > block.timestamp) {
        // Cancel the prior contribution of _uOld.slope to slopeChanges[_oldStaked.end].
        _oldDslope += _uOld.slope;
        // top-up, not extension: end key is shared
        if (_input.newStaked.end == _input.oldStaked.end) _oldDslope -= _uNew.slope;
        _slopeChanges[_input.oldStaked.end] = _oldDslope;
      }

      if (_input.newStaked.end > block.timestamp) {
        // When the end shifts, record the new slope change at the new end; otherwise it's already in _oldDslope.
        if (_input.newStaked.end > _input.oldStaked.end) {
          _newDslope -= _uNew.slope;
          _slopeChanges[_input.newStaked.end] = _newDslope;
        }
      }

      _uNew.ts = block.timestamp.toUint48();
      uint256 _userEpoch = _userPointEpoch[_input.tokenId];
      if (_userEpoch != 0 && _userPointHistory[_input.tokenId][_userEpoch].ts == block.timestamp) {
        _userPointHistory[_input.tokenId][_userEpoch] = _uNew;
      } else {
        _userPointEpoch[_input.tokenId] = ++_userEpoch;
        _userPointHistory[_input.tokenId][_userEpoch] = _uNew;
      }
    }
  }
}
