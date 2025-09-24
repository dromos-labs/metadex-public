// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

/// @title PoolOracle
/// @notice Circular-buffer TWAP mechanics for Aerodrome V2 pools.
library PoolOracle {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Captured TWAP observation circular buffer.
  /// @param timestamp Observation timestamp (truncated to uint32).
  /// @param reserve0Cumulative Reserve 0 cumulative.
  /// @param reserve1Cumulative Reserve 1 cumulative.
  struct Observation {
    uint32 timestamp;
    uint256 reserve0Cumulative;
    uint256 reserve1Cumulative;
  }

  /// @notice Circular buffer of TWAP observations and its metadata.
  /// @param observations Fixed-size buffer of reserve cumulative snapshots.
  /// @param index Index of the most recently written observation.
  /// @param cardinality Number of populated slots in the buffer.
  /// @param cardinalityNext Number of observation slots that can be populated.
  struct ObservationBuffer {
    Observation[65_535] observations;
    uint16 index;
    uint16 cardinality;
    uint16 cardinalityNext;
  }

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a requested timestamp predates the oldest stored observation.
  error ObservationOld();

  /*////////////////////////////////////////////////////////////
                              FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Seeds slot zero of the buffer and sets the starting cardinality.
  /// @param self The observation buffer.
  function initialize(ObservationBuffer storage self) internal {
    self.observations[0].timestamp = uint32(block.timestamp);
    self.cardinality = 1;
    self.cardinalityNext = 1;
  }

  /// @notice Writes a new observation when more than `_periodSize` has elapsed since the newest one.
  /// @dev `self.cardinality` increases by one when `self.index` reaches the last available slot and `self.cardinalityNext`
  ///      is > `self.cardinality`.
  /// @param self The observation buffer.
  /// @param _reserve0CumulativeLast Running reserve0 cumulative to store.
  /// @param _reserve1CumulativeLast Running reserve1 cumulative to store.
  /// @param _periodSize Minimum seconds between observations.
  function write(
    ObservationBuffer storage self,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast,
    uint256 _periodSize
  ) internal {
    uint32 _blockTimestamp = uint32(block.timestamp);
    uint16 _index = self.index;
    uint256 _timeElapsed;
    unchecked {
      _timeElapsed = _blockTimestamp - self.observations[_index].timestamp;
    }
    if (_timeElapsed <= _periodSize) return;
    uint16 _cardinality = self.cardinality;
    uint16 _newCardinality = _cardinality;
    /// @dev Grow by one slot per write since there is no `initialized` flag on `Observation`.
    ///      This ensures that every read only hits initialized slots.
    if (self.cardinalityNext > _cardinality && _index == _cardinality - 1) {
      _newCardinality = _cardinality + 1;
    }
    uint16 _newIndex = (_index + 1) % _newCardinality;
    self.observations[_newIndex] = Observation({
      timestamp: _blockTimestamp,
      reserve0Cumulative: _reserve0CumulativeLast,
      reserve1Cumulative: _reserve1CumulativeLast
    });
    self.index = _newIndex;
    if (_newCardinality != _cardinality) self.cardinality = _newCardinality;
  }

  /// @notice Pre-initialises the new buffer slots and updates `cardinalityNext` so observation writes hit warm storage.
  /// @param self The observation buffer.
  /// @param _next Requested target cardinality.
  /// @return _grown The resulting target cardinality, unchanged when `_next` is not greater than the current.
  function grow(ObservationBuffer storage self, uint16 _next) internal returns (uint16) {
    uint16 _current = self.cardinalityNext;
    if (_next <= _current) return _current;
    for (uint16 _i = _current; _i < _next; _i++) {
      self.observations[_i].timestamp = 1;
      self.observations[_i].reserve0Cumulative = 1;
      self.observations[_i].reserve1Cumulative = 1;
    }
    self.cardinalityNext = _next;
    return _next;
  }

  /// @notice Returns the observations bracketing `_target`.
  /// @dev When `_target` falls after the newest stored observation, `_atOrAfter` is interpolated from the
  ///      current cumulatives. When `_target` equals the newest stored observation, that observation is
  ///      returned as both bounds.
  /// @param self The observation buffer.
  /// @param _time The current timestamp.
  /// @param _target Timestamp to locate inside or relative to the populated range.
  /// @param _reserve0CumulativeNow Current reserve0 cumulative extrapolated to `_time`.
  /// @param _reserve1CumulativeNow Current reserve1 cumulative extrapolated to `_time`.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _getSurroundingObservations(
    ObservationBuffer storage self,
    uint32 _time,
    uint32 _target,
    uint256 _reserve0CumulativeNow,
    uint256 _reserve1CumulativeNow
  ) internal view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    uint16 _index = self.index;
    _beforeOrAt = self.observations[_index]; // newest written
    if (_lte(_time, _beforeOrAt.timestamp, _target)) {
      // target sits exactly on the newest observation, which brackets itself with no interpolation
      if (_beforeOrAt.timestamp == _target) return (_beforeOrAt, _beforeOrAt);
      (uint256 _r0Interpolated, uint256 _r1Interpolated) =
        _interpolate(_beforeOrAt, _time, _reserve0CumulativeNow, _reserve1CumulativeNow, _target);
      _atOrAfter =
        Observation({timestamp: _target, reserve0Cumulative: _r0Interpolated, reserve1Cumulative: _r1Interpolated});
      return (_beforeOrAt, _atOrAfter);
    }
    _beforeOrAt = self.observations[(_index + 1) % self.cardinality]; // oldest reachable
    if (!_lte(_time, _beforeOrAt.timestamp, _target)) revert ObservationOld();
    return _binarySearch(self, _time, _target);
  }

  /// @notice Resolves a single `_secondsAgo` offset into a pair of reserve cumulatives by interpolating between
  ///         surrounding observations.
  /// @dev A `_secondsAgo` that lands after the newest stored observation is estimated from the current
  ///      cumulatives, so a later trade can change what it reads. It stops changing once an observation
  ///      is stored at or after that point.
  /// @param self The observation buffer.
  /// @param _time The current timestamp.
  /// @param _secondsAgo Offset from `_time` into the past. `0` requests the cumulatives at `_time`.
  /// @param _reserve0CumulativeNow Current reserve0 cumulative extrapolated to `_time`.
  /// @param _reserve1CumulativeNow Current reserve1 cumulative extrapolated to `_time`.
  /// @return _reserve0Cumulative Cumulative reserve0 at `_time - _secondsAgo`.
  /// @return _reserve1Cumulative Cumulative reserve1 at `_time - _secondsAgo`.
  function observeSingle(
    ObservationBuffer storage self,
    uint32 _time,
    uint32 _secondsAgo,
    uint256 _reserve0CumulativeNow,
    uint256 _reserve1CumulativeNow
  ) internal view returns (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative) {
    if (_secondsAgo == 0) {
      return (_reserve0CumulativeNow, _reserve1CumulativeNow);
    }
    uint32 _target;
    unchecked {
      _target = _time - _secondsAgo;
    }
    (Observation memory _beforeOrAt, Observation memory _atOrAfter) =
      _getSurroundingObservations(self, _time, _target, _reserve0CumulativeNow, _reserve1CumulativeNow);
    if (_atOrAfter.timestamp == _target) {
      return (_atOrAfter.reserve0Cumulative, _atOrAfter.reserve1Cumulative);
    }
    (_reserve0Cumulative, _reserve1Cumulative) = _interpolate(
      _beforeOrAt, _atOrAfter.timestamp, _atOrAfter.reserve0Cumulative, _atOrAfter.reserve1Cumulative, _target
    );
  }

  /// @notice Resolves an array of `_secondsAgos` offsets into reserve cumulatives.
  /// @param self The observation buffer.
  /// @param _secondsAgos Offsets into the past from the current timestamp, `0` requesting the current cumulatives.
  /// @param _reserve0CumulativeNow Current reserve0 cumulative extrapolated to the current timestamp.
  /// @param _reserve1CumulativeNow Current reserve1 cumulative extrapolated to the current timestamp.
  /// @return _reserve0Cumulatives Cumulative reserve0 at each requested offset.
  /// @return _reserve1Cumulatives Cumulative reserve1 at each requested offset.
  function observe(
    ObservationBuffer storage self,
    uint32[] calldata _secondsAgos,
    uint256 _reserve0CumulativeNow,
    uint256 _reserve1CumulativeNow
  ) internal view returns (uint256[] memory _reserve0Cumulatives, uint256[] memory _reserve1Cumulatives) {
    uint32 _time = uint32(block.timestamp);
    uint256 _length = _secondsAgos.length;
    _reserve0Cumulatives = new uint256[](_length);
    _reserve1Cumulatives = new uint256[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      (_reserve0Cumulatives[_i], _reserve1Cumulatives[_i]) =
        observeSingle(self, _time, _secondsAgos[_i], _reserve0CumulativeNow, _reserve1CumulativeNow);
    }
  }

  /// @notice Compares two uint32 timestamps chronologically, tolerating the uint32 rollover.
  /// @param _time The current timestamp.
  /// @param _a Timestamp to test.
  /// @param _b Timestamp to compare against.
  /// @return  Whether `_a` is chronologically less than or equal to `_b`.
  function _lte(uint32 _time, uint32 _a, uint32 _b) internal pure returns (bool) {
    if (_a <= _time && _b <= _time) return _a <= _b;

    uint256 _aAdjusted = _a > _time ? _a : _a + 2 ** 32;
    uint256 _bAdjusted = _b > _time ? _b : _b + 2 ** 32;

    return _aAdjusted <= _bAdjusted;
  }

  /// @notice Interpolates the reserve cumulatives at `_target` between two observation points: `_beforeOrAt.timestamp` and `_afterTimestamp`.
  /// @dev When `_target` equals `_afterTimestamp` the result equals the after cumulatives.
  /// @dev When `_target` equals `_beforeOrAt.timestamp` the result equals the `_beforeOrAt` cumulatives.
  /// @dev `_target` should fall between `_beforeOrAt.timestamp` and `_afterTimestamp` (inclusive).
  /// @dev Timestamp subtractions are `unchecked` so the math holds across uint32 timestamp rollover.
  /// @param _beforeOrAt Observation at or before `_target` chronologically.
  /// @param _afterTimestamp Timestamp at the end of the interpolation window.
  /// @param _afterReserve0Cumulative End-of-window reserve0 cumulative.
  /// @param _afterReserve1Cumulative End-of-window reserve1 cumulative.
  /// @param _target Timestamp at which to evaluate the interpolation.
  /// @return _reserve0Cumulative Interpolated reserve0 cumulative at `_target`.
  /// @return _reserve1Cumulative Interpolated reserve1 cumulative at `_target`.
  function _interpolate(
    Observation memory _beforeOrAt,
    uint32 _afterTimestamp,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative,
    uint32 _target
  ) internal pure returns (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative) {
    uint256 _beforeToAfterTimeDelta;
    uint256 _beforeToTargetTimeDelta;
    unchecked {
      _beforeToAfterTimeDelta = uint256(_afterTimestamp - _beforeOrAt.timestamp);
      _beforeToTargetTimeDelta = uint256(_target - _beforeOrAt.timestamp);
    }
    uint256 _reserve0Delta = _afterReserve0Cumulative - _beforeOrAt.reserve0Cumulative;
    uint256 _reserve1Delta = _afterReserve1Cumulative - _beforeOrAt.reserve1Cumulative;
    _reserve0Cumulative =
      _beforeOrAt.reserve0Cumulative + Math.mulDiv(_reserve0Delta, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta);
    _reserve1Cumulative =
      _beforeOrAt.reserve1Cumulative + Math.mulDiv(_reserve1Delta, _beforeToTargetTimeDelta, _beforeToAfterTimeDelta);
  }

  /// @notice Binary searches the active buffer for the observations bracketing `_target`.
  /// @param self The observation buffer.
  /// @param _time The current timestamp.
  /// @param _target Timestamp to bracket.
  /// @return _beforeOrAt Observation at or before `_target`.
  /// @return _atOrAfter Observation at or after `_target`.
  function _binarySearch(
    ObservationBuffer storage self,
    uint32 _time,
    uint32 _target
  ) private view returns (Observation memory _beforeOrAt, Observation memory _atOrAfter) {
    uint16 _cardinality = self.cardinality;
    Observation[65_535] storage observations = self.observations;
    unchecked {
      uint256 _l = (uint256(self.index) + 1) % _cardinality; // oldest reachable slot
      uint256 _r = _l + _cardinality - 1; // newest written slot
      while (true) {
        uint256 _i = (_l + _r) / 2;
        _beforeOrAt = observations[_i % _cardinality];
        _atOrAfter = observations[(_i + 1) % _cardinality];
        bool _targetAtOrAfterBefore = _lte(_time, _beforeOrAt.timestamp, _target);
        bool _targetAtOrBeforeAfter = _lte(_time, _target, _atOrAfter.timestamp);
        if (_targetAtOrAfterBefore && _targetAtOrBeforeAfter) break;
        if (_targetAtOrAfterBefore) _l = _i + 1;
        else _r = _i - 1;
      }
    }
  }
}
