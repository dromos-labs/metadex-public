// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VolatilityRingLibrary} from 'V3/libraries/VolatilityRingLibrary.sol';

/// @notice Mock handler to test the VolatilityRingLibrary
contract VolatilityRingHandler {
  using VolatilityRingLibrary for uint256[15];

  /// @notice The ring used to test the different functions.
  uint256[15] internal _ring;

  /// @notice Executes `VolatilityRingLibrary.pack`.
  /// @param _range The tick range to pack.
  /// @param _dist The tick distance to pack.
  /// @param _m The swap count to pack.
  /// @return _packed The packed value.
  function pack(uint24 _range, uint24 _dist, uint16 _m) external pure returns (uint64 _packed) {
    _packed = VolatilityRingLibrary.pack(_range, _dist, _m);
  }

  /// @notice Executes `VolatilityRingLibrary.unpack`.
  /// @param _packed The packed value.
  /// @return _range The unpacked tick range.
  /// @return _dist The unpacked tick distance.
  /// @return _m The unpacked swap count.
  function unpack(uint64 _packed) external pure returns (uint24 _range, uint24 _dist, uint16 _m) {
    (_range, _dist, _m) = VolatilityRingLibrary.unpack(_packed);
  }

  /// @notice Executes `VolatilityRingLibrary.push` over the ring.
  /// @param _head The next write position.
  /// @param _count The number of filled positions.
  /// @param _range The tick range to pack.
  /// @param _dist The tick distance to pack.
  /// @param _m The swap count to pack.
  /// @return _newHead The updated head.
  /// @return _newCount The updated count.
  function push(
    uint8 _head,
    uint8 _count,
    uint24 _range,
    uint24 _dist,
    uint16 _m
  ) external returns (uint8 _newHead, uint8 _newCount) {
    (_newHead, _newCount) = _ring.push(_head, _count, _range, _dist, _m);
  }

  /// @notice Executes `VolatilityRingLibrary.values` over the ring.
  /// @param _head The next write position.
  /// @param _count The number of filled positions.
  /// @return _tickRanges The tick ranges ordered oldest to newest, sized to the count.
  /// @return _dists The tick distances ordered oldest to newest, sized to the count.
  /// @return _swapCounts The swap counts ordered oldest to newest, sized to the count.
  function values(
    uint8 _head,
    uint8 _count
  ) external view returns (uint256[] memory _tickRanges, uint256[] memory _dists, uint256[] memory _swapCounts) {
    (_tickRanges, _dists, _swapCounts) = _ring.values(_head, _count);
  }

  /// @notice Returns a ring value.
  /// @param _index The value index.
  /// @return _value The 256 bit value.
  function ringValue(uint256 _index) external view returns (uint256 _value) {
    _value = _ring[_index];
  }
}
