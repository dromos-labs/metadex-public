// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/// @title SafeCast Library
/// @author velodrome.finance
/// @notice Safely convert unsigned and signed integers without overflow / underflow
library SafeCastLibrary {
  /// @notice Thrown when a value exceeds the destination type's maximum.
  error SafeCastOverflow();
  /// @notice Thrown when a negative value is cast to an unsigned type.
  error SafeCastUnderflow();

  /// @notice Safely convert uint256 to int128.
  /// @param _value Value to convert.
  /// @return _result Converted int128 value.
  function toInt128(uint256 _value) internal pure returns (int128 _result) {
    if (_value > uint128(type(int128).max)) revert SafeCastOverflow();
    return int128(uint128(_value));
  }

  /// @notice Safely convert int128 to uint256.
  /// @param _value Value to convert.
  /// @return _result Converted uint256 value.
  function toUint256(int128 _value) internal pure returns (uint256 _result) {
    if (_value < 0) revert SafeCastUnderflow();
    return uint256(int256(_value));
  }

  /// @notice Safely convert uint256 to uint48.
  /// @param _value Value to convert.
  /// @return _result Converted uint48 value.
  function toUint48(uint256 _value) internal pure returns (uint48 _result) {
    if (_value > type(uint48).max) revert SafeCastOverflow();
    return uint48(_value);
  }

  /// @notice Safely convert uint256 to uint64.
  /// @param _value Value to convert.
  /// @return _result Converted uint64 value.
  function toUint64(uint256 _value) internal pure returns (uint64 _result) {
    if (_value > type(uint64).max) revert SafeCastOverflow();
    return uint64(_value);
  }

  /// @notice Safely convert uint256 to uint72.
  /// @param _value Value to convert.
  /// @return _result Converted uint72 value.
  function toUint72(uint256 _value) internal pure returns (uint72 _result) {
    if (_value > type(uint72).max) revert SafeCastOverflow();
    return uint72(_value);
  }

  /// @notice Safely convert uint256 to uint128.
  /// @param _value Value to convert.
  /// @return _result Converted uint128 value.
  function toUint128(uint256 _value) internal pure returns (uint128 _result) {
    if (_value > type(uint128).max) revert SafeCastOverflow();
    return uint128(_value);
  }
}
