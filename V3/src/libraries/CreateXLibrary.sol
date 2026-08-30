// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICreateX} from 'V3/interfaces/external/ICreateX.sol';

/// @notice Helpers for deterministic CreateX deployments.
library CreateXLibrary {
  /// @notice Canonical CreateX contract.
  ICreateX public constant CREATEX = ICreateX(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

  /// @notice Calculates a cross-chain salt from entropy and a deployer.
  function calculateSalt(bytes11 _entropy, address _deployer) internal pure returns (bytes32 _salt) {
    _salt = bytes32(abi.encodePacked(bytes20(_deployer), bytes1(0x00), _entropy));
  }

  /// @notice Computes the CREATE3 address for entropy and a deployer.
  function computeCreate3Address(bytes11 _entropy, address _deployer) internal pure returns (address _address) {
    bytes32 _salt = calculateSalt({_entropy: _entropy, _deployer: _deployer});
    bytes32 _guardedSalt = keccak256(abi.encodePacked(uint256(uint160(_deployer)), _salt));
    _address = CREATEX.computeCreate3Address(_guardedSalt, address(CREATEX));
  }
}
