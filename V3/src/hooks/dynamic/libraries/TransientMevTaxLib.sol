// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {LibTransient} from '@solady/utils/LibTransient.sol';

import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';

/// @title TransientMevTaxLib
/// @notice Library for managing MEV tax data in transient storage.
library TransientMevTaxLib {
  using LibTransient for LibTransient.TBytes32;

  /// @dev The number of bits for shifting to pack (uint24, bool) values.
  uint256 private constant _DYNAMIC_FEE_SHIFT = 8;

  /// @notice Packs fee and toxic flag and writes them to transient storage for a given `_pool`.
  /// @param _transientMevData The transient storage mapping (pool address -> packed data).
  /// @param _pool The pool address to map MEV data.
  /// @param _dynamicFee The capped and discounted dynamic fee component paid in beforeSwap.
  /// @param _toxic The toxic classification to store.
  function write(
    mapping(address => LibTransient.TBytes32) storage _transientMevData,
    address _pool,
    uint24 _dynamicFee,
    bool _toxic
  ) internal {
    bytes32 _packedMevData = bytes32((uint256(_dynamicFee) << _DYNAMIC_FEE_SHIFT) | (_toxic ? 1 : 0));
    _transientMevData[_pool].set(_packedMevData);
  }

  /// @notice Reads and unpacks the MEV data from transient storage for a given `_pool`.
  /// @param _transientMevData The transient storage mapping (pool address -> packed data).
  /// @param _pool The pool address to which MEV data is mapped.
  /// @return _dynamicFee The capped and discounted dynamic fee component paid in beforeSwap.
  /// @return _toxic The unpacked toxic classification.
  function read(
    mapping(address => LibTransient.TBytes32) storage _transientMevData,
    address _pool
  ) internal view returns (uint24 _dynamicFee, bool _toxic) {
    bytes32 _packedMevData = _transientMevData[_pool].get();

    _dynamicFee = uint24(uint256(_packedMevData >> _DYNAMIC_FEE_SHIFT));
    _toxic = (uint256(_packedMevData) & 1) != 0;
  }

  /// @notice Retrieves the current MEV tax parameters from MEV module.
  /// @param _mevTaxModule The MEV tax module contract.
  /// @return The MEV fee (in pips) from the module.
  /// @return Whether the swap is classified as toxic according to the module.
  function mevTax(IMevTaxModule _mevTaxModule) internal view returns (uint24, bool) {
    if (address(_mevTaxModule) != address(0)) {
      try _mevTaxModule.getMevTax() returns (uint24 _mevFee, bool _toxic) {
        return (_mevFee, _toxic);
      } catch {}
    }
    return (0, false);
  }
}
