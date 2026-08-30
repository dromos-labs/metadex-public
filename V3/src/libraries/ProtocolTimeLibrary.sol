// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

library ProtocolTimeLibrary {
  uint256 internal constant _WEEK = 7 days;

  /// @dev Returns start of epoch based on current timestamp
  function epochStart(uint256 timestamp) internal pure returns (uint256) {
    unchecked {
      return timestamp - (timestamp % _WEEK);
    }
  }

  /// @dev Returns start of next epoch / end of current epoch
  function epochNext(uint256 timestamp) internal pure returns (uint256) {
    unchecked {
      return timestamp - (timestamp % _WEEK) + _WEEK;
    }
  }
}
