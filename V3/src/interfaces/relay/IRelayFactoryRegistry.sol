// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IRelayFactoryRegistry
 * @notice Approval set of the relay factories the protocol trusts. A consumer handed a relay address
 *         resolves the relay's factory, checks it here, then asks that factory whether it created
 *         the relay. The set is governed by GOVERNANCE_ROLE on the root Voter, a seat above the
 *         relay deployer. It gates what a consumer accepts, not relay creation. The factory checks only
 *         RELAY_DEPLOYER_ROLE, and a relay keeps taking direct deposits whether or not its factory is in
 *         the set.
 */
interface IRelayFactoryRegistry {
  /**
   * @notice Emitted when a relay factory enters the approval set.
   * @param _relayFactory The relay factory registered.
   */
  event RelayFactoryRegistered(address indexed _relayFactory);

  /**
   * @notice Emitted when a relay factory leaves the approval set.
   * @param _relayFactory The relay factory unregistered.
   */
  event RelayFactoryUnregistered(address indexed _relayFactory);

  /// @notice Thrown when the caller lacks GOVERNANCE_ROLE on the Voter.
  error NotAuthorized();

  /// @notice Thrown when a zero address is supplied where an address is required.
  error ZeroAddress();

  /// @notice Thrown when registering a relay factory already in the approval set.
  error AlreadyRegistered();

  /// @notice Thrown when unregistering a relay factory not in the approval set.
  error NotRegistered();

  /**
   * @notice Add a relay factory to the approval set. Multiple relay factories can be approved at
   *         once so relays of an older factory keep working while a new one rolls out.
   * @dev Caller must hold GOVERNANCE_ROLE on the Voter. Reverts on the zero address and a relay
   *      factory already in the set.
   * @param _relayFactory The relay factory to register.
   */
  function registerRelayFactory(address _relayFactory) external;

  /**
   * @notice Remove a relay factory from the approval set. Every relay that factory created stops
   *         passing the consumers' checks at once. Direct calls on those relays are untouched.
   * @dev Caller must hold GOVERNANCE_ROLE on the Voter. Reverts when the relay factory is not
   *      in the set.
   * @param _relayFactory The relay factory to unregister.
   */
  function unregisterRelayFactory(address _relayFactory) external;

  /**
   * @notice True when the relay factory is in the approval set.
   * @dev Membership alone does not authenticate a relay. A spoofed relay can report any factory, so
   *      a consumer must also ask the approved factory whether it created the relay.
   * @param _relayFactory The relay factory to check.
   * @return _approved Whether the relay factory is registered.
   */
  function isRelayFactoryApproved(address _relayFactory) external view returns (bool _approved);

  /**
   * @notice The registered relay factories.
   * @return _factories The relay factory approval set as an array.
   */
  function relayFactories() external view returns (address[] memory _factories);

  /**
   * @notice The number of registered relay factories.
   * @return _length The size of the approval set.
   */
  function relayFactoriesLength() external view returns (uint256 _length);

  /**
   * @notice The relay factory at an index of the approval set.
   * @param _index The index to read.
   * @return _relayFactory The member at the index, zero for an out of range index.
   */
  function relayFactoriesAt(uint256 _index) external view returns (address _relayFactory);

  /**
   * @notice The Voter whose GOVERNANCE_ROLE governs the approval set.
   * @return _voter The Voter address.
   */
  function VOTER() external view returns (address _voter);
}
