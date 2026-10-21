// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICreateX
/// @notice Minimal redeclaration of the canonical CreateX factory, limited to the two CREATE3 members
///         this repository integrates against.
/// @dev This is not the complete CreateX interface. Refer to the upstream CreateX project for the full
///      surface, its semantics and its guarded-salt rules.
interface ICreateX {
  /// @notice Deploys a contract via CREATE3 at an address determined by the salt.
  /// @param salt The salt used for the deployment.
  /// @param initCode The creation bytecode of the contract to deploy.
  /// @return newContract The address of the deployed contract.
  function deployCreate3(bytes32 salt, bytes memory initCode) external payable returns (address newContract);

  /// @notice Computes the CREATE3 address for a salt and a deployer.
  /// @param salt The salt used for the deployment.
  /// @param deployer The address performing the deployment.
  /// @return computedAddress The deterministic address of the contract.
  function computeCreate3Address(bytes32 salt, address deployer) external pure returns (address computedAddress);
}
