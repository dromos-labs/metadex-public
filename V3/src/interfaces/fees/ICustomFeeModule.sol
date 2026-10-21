// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import 'V3/interfaces/fees/IFeeModule.sol';

interface ICustomFeeModule is IFeeModule {
  event SetCustomFee(address indexed pool, uint256 indexed fee);

  error NotFeeManager();
  error InvalidPool();
  error FeeTooHigh();
  /// @notice Thrown when no custom fee has been set for the queried pool. The caller
  ///         should fall back to its own default fee.
  error NoCustomFee();

  /// @notice Maximum possible fee for custom fee
  /// @return 3%
  function MAX_FEE() external view returns (uint256);

  /// @dev Used to indicate there is custom 0% fee - as a 0 value in the
  /// @dev customFee mapping indicates that no custom fee rate has been set
  function ZERO_FEE_INDICATOR() external view returns (uint256);

  /// @notice Returns the custom fee for a given pool if set, otherwise returns default fees
  /// @dev Can use default fee by setting the fee to 0, can set zero fee by setting default fee to ZERO_FEE_INDICATOR
  /// @param pool The pool to get the custom fee for
  /// @return The custom fee for the given pool
  function customFee(address pool) external view returns (uint24);

  /// @notice Sets a custom fee for a given pool
  /// @dev Can use default fee by setting the fee to 0, can set zero fee by setting default fee to ZERO_FEE_INDICATOR
  /// @dev Must be called by the current fee manager
  /// @param _pool The pool to set the custom fee for
  /// @param _fee The fee to set for the given pool
  function setCustomFee(address _pool, uint24 _fee) external;
}
