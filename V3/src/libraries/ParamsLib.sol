// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

library ParamsLib {
  uint8 internal constant _PARAMS_REFERRAL = 0x01;

  /// @dev One tag byte followed by abi.encode(address, uint256).
  uint256 internal constant _REFERRAL_PARAMS_LENGTH = 65;

  /// @notice Thrown when a referral payload does not have the exact encoded length.
  error MalformedReferral();

  function isReferral(bytes calldata _params) internal pure returns (bool _isReferral) {
    _isReferral = _params.length > 0 && uint8(_params[0]) == _PARAMS_REFERRAL;
  }

  function decodeReferral(bytes calldata _params) internal pure returns (address _referral, uint256 _share) {
    if (_params.length != _REFERRAL_PARAMS_LENGTH) revert MalformedReferral();
    (_referral, _share) = abi.decode(_params[1:], (address, uint256));
  }
}
