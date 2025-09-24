// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/// @title VolatilityRingLibrary
/// @notice Library to write and read values from a ring buffer of packed `{uint24 range, uint24 dist, uint16 m}`
///         volatility values.
/// @dev A `{range, dist, m}` value occupies exactly 64 bits and 4 of those values fit per 256 bit word.
///      The fixed buffer length of 60 values spans 15 256 bit words.
library VolatilityRingLibrary {
  /// @notice Max amount of values held by the ring.
  uint8 internal constant _WINDOW = 60;

  /// @notice Writes a packed value at the head position and advances the ring.
  /// @dev Clears the previous value in the head position before writing.
  /// @param _ring The ring.
  /// @param _head The next write position.
  /// @param _count The current number of filled positions.
  /// @param _range The tick range to pack.
  /// @param _dist The tick distance to pack.
  /// @param _m The swap count to pack.
  /// @return _newHead The head advanced modulo the window.
  /// @return _newCount The updated count. This value stops incrementing when it reaches _WINDOW.
  function push(
    uint256[15] storage _ring,
    uint8 _head,
    uint8 _count,
    uint24 _range,
    uint24 _dist,
    uint16 _m
  ) internal returns (uint8 _newHead, uint8 _newCount) {
    uint64 _packed = pack(_range, _dist, _m);
    // slot in which the new packed value is going to be written
    // each ring has 15 slots of 256 bits
    uint256 _slot = _head / 4;
    // offset inside the slot
    // each slot can hold 4 different values of 64 bits
    uint256 _shift = (uint256(_head) % 4) * 64;
    uint256 _word = _ring[_slot];
    // clears any older value in the current position before writing
    _word &= ~(uint256(type(uint64).max) << _shift);
    _word |= uint256(_packed) << _shift;
    _ring[_slot] = _word;

    _newHead = (_head + 1) % _WINDOW;
    _newCount = _count < _WINDOW ? _count + 1 : _count;
  }

  /// @notice Packs a tick range, a tick distance and a swap count into a 64 bit ring value.
  /// @param _range The tick range to pack.
  /// @param _dist The tick distance to pack.
  /// @param _m The swap count to pack.
  /// @return _packed The packed `{range, dist, m}` value.
  function pack(uint24 _range, uint24 _dist, uint16 _m) internal pure returns (uint64 _packed) {
    _packed = (uint64(_range) << 40) | (uint64(_dist) << 16) | _m;
  }

  /// @notice Unpacks a 64 bit ring value into its tick range, tick distance and swap count.
  /// @param _packed The packed value.
  /// @return _range The tick range.
  /// @return _dist The tick distance.
  /// @return _m The swap count.
  function unpack(uint64 _packed) internal pure returns (uint24 _range, uint24 _dist, uint16 _m) {
    _range = uint24(_packed >> 40);
    _dist = uint24(_packed >> 16);
    _m = uint16(_packed);
  }

  /// @notice Unpacks the ring into three separate arrays of values ordered oldest to newest.
  /// @dev The three returned arrays have length `_count`.
  /// @param _ring The ring with the packed values.
  /// @param _head The next write position.
  /// @param _count The current number of filled positions.
  /// @return _tickRanges The tick ranges ordered oldest to newest.
  /// @return _dists The tick distances ordered oldest to newest.
  /// @return _swapCounts The swap counts ordered oldest to newest.
  function values(
    uint256[15] memory _ring,
    uint8 _head,
    uint8 _count
  ) internal pure returns (uint256[] memory _tickRanges, uint256[] memory _dists, uint256[] memory _swapCounts) {
    _tickRanges = new uint256[](_count);
    _dists = new uint256[](_count);
    _swapCounts = new uint256[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      uint256 _position = (uint256(_head) + _WINDOW - _count + _i) % _WINDOW;
      (uint24 _range, uint24 _dist, uint16 _m) = unpack(uint64(_ring[_position / 4] >> ((_position % 4) * 64)));
      (_tickRanges[_i], _dists[_i], _swapCounts[_i]) = (_range, _dist, _m);
    }
  }
}
