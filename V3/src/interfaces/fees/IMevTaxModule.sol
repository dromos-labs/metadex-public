// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IMevTaxModule
/// @notice Computes the MEV tax rate and toxicity classification for a swap.
interface IMevTaxModule {
  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the priority fee multiplier is set.
  /// @param _priorityFeeMultiplier The new priority fee multiplier.
  event MultiplierSet(uint64 _priorityFeeMultiplier);

  /// @notice Emitted when the retail threshold floor is set.
  /// @param _minThreshold The new retail threshold floor, in wei.
  event MinThresholdSet(uint96 _minThreshold);

  /// @notice Emitted when the base fee factor is set.
  /// @param _baseFeeFactor The new base fee factor.
  event BaseFeeFactorSet(uint96 _baseFeeFactor);

  /*////////////////////////////////////////////////////////////
                        WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Sets the chain wide priority fee multiplier.
  /// @param _priorityFeeMultiplier The new priority fee multiplier.
  function setMultiplier(uint64 _priorityFeeMultiplier) external;

  /// @notice Sets the floor of the adaptive retail threshold.
  /// @param _minThreshold The new retail threshold floor, in wei.
  function setMinThreshold(uint96 _minThreshold) external;

  /// @notice Sets the congestion factor of the adaptive retail threshold.
  /// @dev A zero value disables the congestion term.
  /// @param _baseFeeFactor The new base fee factor.
  function setBaseFeeFactor(uint96 _baseFeeFactor) external;

  /*////////////////////////////////////////////////////////////
                            CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @notice The maximum MEV tax the module can return, in pips.
  /// @return _mevTaxCap The MEV tax cap.
  function MEV_TAX_CAP() external view returns (uint24 _mevTaxCap);

  /// @notice The fixed point divisor of the priority fee multiplier.
  /// @return _precision The divisor.
  function PRECISION() external view returns (uint256 _precision);

  /*////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the MEV tax rate and toxicity classification for a swap.
  /// @return _mevTax The MEV tax in pips.
  /// @return _toxic True when the swap is classified as toxic flow.
  function getMevTax() external view returns (uint24 _mevTax, bool _toxic);

  /// @notice The chain wide multiplier applied to the excess priority fee.
  /// @return _priorityFeeMultiplier The priority fee multiplier.
  function priorityFeeMultiplier() external view returns (uint64 _priorityFeeMultiplier);

  /// @notice The floor of the adaptive retail threshold, in wei.
  /// @return _minThreshold The retail threshold floor.
  function minThreshold() external view returns (uint96 _minThreshold);

  /// @notice The congestion factor scaling the block base fee into the adaptive retail threshold.
  /// @return _baseFeeFactor The base fee factor.
  function baseFeeFactor() external view returns (uint96 _baseFeeFactor);
}
