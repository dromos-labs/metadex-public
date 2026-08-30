// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title Roles
 * @notice Central registry of AccessControl role identifiers used by Voter and LeafVoter.
 */
library Roles {
  /// @notice Root governance authority.
  bytes32 public constant GOVERNANCE_ROLE = keccak256('GOVERNANCE_ROLE');

  /// @notice Admin of the operational config roles.
  bytes32 public constant CONFIG_ADMIN_ROLE = keccak256('CONFIG_ADMIN_ROLE');

  /// @notice Configures Voter-wide parameters.
  bytes32 public constant VOTER_CONFIG_ROLE = keccak256('VOTER_CONFIG_ROLE');

  /// @notice Registers and configures per-chain parameters.
  bytes32 public constant CHAIN_CONFIG_ROLE = keccak256('CHAIN_CONFIG_ROLE');

  /// @notice Flips per-chain status.
  bytes32 public constant CHAIN_STATUS_ROLE = keccak256('CHAIN_STATUS_ROLE');

  /// @notice Authorizes remote-adapter configuration on bridge adapters.
  bytes32 public constant ADAPTER_CONFIG_ROLE = keccak256('ADAPTER_CONFIG_ROLE');

  /// @notice Replaces the Splitter's recipient list, directing future team-share emissions.
  bytes32 public constant SPLITTER_CONFIG_ROLE = keccak256('SPLITTER_CONFIG_ROLE');

  /// @notice Whitelists tokenIds on the LeafVoter.
  bytes32 public constant TOKEN_WHITELIST_ROLE = keccak256('TOKEN_WHITELIST_ROLE');

  /// @notice Emergency actor authorized to zero a gauge's emission cap on the leaf.
  bytes32 public constant EMERGENCY_COUNCIL_ROLE = keccak256('EMERGENCY_COUNCIL_ROLE');

  /// @notice Registers and unregisters factories on the FactoryRegistry.
  bytes32 public constant FACTORY_REGISTRY_ADMIN_ROLE = keccak256('FACTORY_REGISTRY_ADMIN_ROLE');

  /// @notice Administers the GaugeManager's creation module set.
  bytes32 public constant MODULE_ADMIN_ROLE = keccak256('MODULE_ADMIN_ROLE');

  /// @notice Creates Relays on the RelayFactory.
  bytes32 public constant RELAY_DEPLOYER_ROLE = keccak256('RELAY_DEPLOYER_ROLE');

  /// @notice Configures leaf messaging gas costs, including the deallocation return-message fee.
  bytes32 public constant GAS_CONFIGURER_ROLE = keccak256('GAS_CONFIGURER_ROLE');

  /// @notice Withdraws native currency from a contract (e.g. collected deallocation return fees on the
  ///         root Voter, or a leaf orchestrator's pre-funded return-message balance).
  bytes32 public constant NATIVE_WITHDRAWER_ROLE = keccak256('NATIVE_WITHDRAWER_ROLE');

  /// @notice Seizes token metadata NFTs on the TokenNFT.
  bytes32 public constant SEIZER_ROLE = keccak256('SEIZER_ROLE');
}
