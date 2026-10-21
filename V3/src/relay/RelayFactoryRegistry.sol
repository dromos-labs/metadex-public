// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IRelayFactoryRegistry} from 'V3/interfaces/relay/IRelayFactoryRegistry.sol';

/**
 * @title RelayFactoryRegistry
 * @notice Approval set of the relay factories the protocol trusts. The Metarouter resolves a
 *         caller-supplied relay's factory, checks it here, then asks that factory whether it created
 *         the relay, so the factory can be replaced or joined by another without redeploying the
 *         router.
 * @dev Governance is borrowed from the root Voter. Registration resolves GOVERNANCE_ROLE through the
 *      Voter's AccessControl state, so the registry carries no AccessControl of its own. Approval gates
 *      what the Metarouter accepts, not relay creation. RelayFactory checks only RELAY_DEPLOYER_ROLE, and
 *      a relay keeps taking direct deposits whether or not its factory is in the set. The set sits above
 *      the relay deployer seat so a compromised deployer cannot make the router accept a factory of its
 *      own.
 */
contract RelayFactoryRegistry is IRelayFactoryRegistry {
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @inheritdoc IRelayFactoryRegistry
  address public immutable VOTER;

  /// @notice Approved relay factories. Exposed as an array by relayFactories.
  EnumerableSet.AddressSet internal _relayFactories;

  /// @notice Restricts the call to holders of GOVERNANCE_ROLE on the Voter.
  /// @dev Reverts with NotAuthorized when the role check fails.
  modifier onlyGovernance() {
    if (!IAccessControl(VOTER).hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) revert NotAuthorized();
    _;
  }

  /// @notice Binds the Voter whose GOVERNANCE_ROLE governs the approval set.
  /// @param _voter Voter address whose GOVERNANCE_ROLE gates registration.
  constructor(address _voter) {
    if (_voter == address(0)) revert ZeroAddress();
    VOTER = _voter;
  }

  /// @inheritdoc IRelayFactoryRegistry
  function registerRelayFactory(address _relayFactory) external onlyGovernance {
    if (_relayFactory == address(0)) revert ZeroAddress();
    if (!_relayFactories.add(_relayFactory)) revert AlreadyRegistered();

    emit RelayFactoryRegistered(_relayFactory);
  }

  /// @inheritdoc IRelayFactoryRegistry
  function unregisterRelayFactory(address _relayFactory) external onlyGovernance {
    if (!_relayFactories.remove(_relayFactory)) revert NotRegistered();

    emit RelayFactoryUnregistered(_relayFactory);
  }

  /// @inheritdoc IRelayFactoryRegistry
  function isRelayFactoryApproved(address _relayFactory) external view returns (bool _approved) {
    _approved = _relayFactories.contains(_relayFactory);
  }

  /// @inheritdoc IRelayFactoryRegistry
  function relayFactories() external view returns (address[] memory _factories) {
    _factories = _relayFactories.values();
  }

  /// @inheritdoc IRelayFactoryRegistry
  function relayFactoriesLength() external view returns (uint256 _length) {
    _length = _relayFactories.length();
  }

  /// @inheritdoc IRelayFactoryRegistry
  function relayFactoriesAt(uint256 _index) external view returns (address _relayFactory) {
    _relayFactory = _index < _relayFactories.length() ? _relayFactories.at(_index) : address(0);
  }
}
