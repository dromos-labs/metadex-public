// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title IGovernanceCreationModule
 * @notice Governance-gated bypass module for custom and non-pool gauges.
 *         Governance supplies opaque factory data and the activation flag
 *         without TokenRegistry listing checks. The target must still be
 *         recorded on the FactoryRegistry by a registered target factory. May
 *         be deployed and left unregistered until needed.
 */
interface IGovernanceCreationModule is IGaugeCreationModule {
  /**
   * @notice Thrown when the caller lacks GOVERNANCE_ROLE on the LeafVoter.
   */
  error NotAuthorized();

  /**
   * @notice Create a gauge over the target with governance-supplied factory
   *         data and activation flag.
   * @dev Caller must hold GOVERNANCE_ROLE on the LeafVoter. Forwards the
   *      normalized request to the GaugeManager, which enforces factory
   *      approval, target provenance, and the write once target link.
   * @param _target The target to create a gauge over.
   * @param _gaugeFactory The approved gauge factory to deploy through.
   * @param _factoryData Opaque payload forwarded to the gauge factory.
   * @param _activate Whether the gauge registers already activated.
   * @return _gauge The deployed gauge.
   */
  function createGauge(
    address _target,
    address _gaugeFactory,
    bytes calldata _factoryData,
    bool _activate
  ) external returns (address _gauge);

  /**
   * @notice LeafVoter whose AccessControl state resolves GOVERNANCE_ROLE.
   * @return _leafVoter The LeafVoter.
   */
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);
}
