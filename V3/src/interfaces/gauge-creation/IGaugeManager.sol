// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title IGaugeManager
 * @notice Target-agnostic gauge lifecycle proxy. Registered creation modules
 *         forward normalized creation requests and delayed activations through
 *         it. It validates factory approval and target provenance against the
 *         FactoryRegistry, deploys through the requested gauge factory, records
 *         gauge-to-module ownership, reports relationships to the
 *         FactoryRegistry and drives the LeafVoter lifecycle hooks.
 */
interface IGaugeManager {
  /**
   * @notice Normalized creation request a module submits to `createGauge`.
   * @param creator Informational originating caller the module reports.
   * @param gaugeFactory Approved gauge factory chosen for the deployment.
   * @param target Target the gauge points at. Must be recorded in the FactoryRegistry.
   * @param factoryData Opaque payload forwarded to the gauge factory.
   * @param activate Initial activation result from the module's activation policy.
   */
  struct GaugeCreationRequest {
    address creator;
    address gaugeFactory;
    address target;
    bytes factoryData;
    bool activate;
  }

  /**
   * @notice Emitted after a gauge is deployed and registered on the LeafVoter.
   * @param _target The target the gauge points at.
   * @param _gauge The deployed gauge.
   * @param _module The registered module that submitted the request, `msg.sender`.
   * @param _gaugeFactory The gauge factory that deployed the gauge.
   * @param _votingRewardsManager The rewards manager deployed alongside the gauge.
   * @param _creator The informational creator the module supplied.
   * @param _activated Whether the gauge registered already activated.
   */
  event GaugeCreated(
    address indexed _target,
    address indexed _gauge,
    address indexed _module,
    address _gaugeFactory,
    address _votingRewardsManager,
    address _creator,
    bool _activated
  );

  /**
   * @notice Emitted when a module is added to the caller set.
   * @param _module The registered module.
   */
  event ModuleRegistered(address indexed _module);

  /**
   * @notice Emitted when a module is removed from the caller set.
   * @param _module The deregistered module.
   */
  event ModuleDeregistered(address indexed _module);

  /**
   * @notice Thrown when the caller is not a registered module, and by
   *         `deregisterModule` for a module not in the set.
   */
  error ModuleNotRegistered();

  /**
   * @notice Thrown when registering a module already in the set.
   */
  error ModuleAlreadyRegistered();

  /**
   * @notice Thrown when the request's gauge factory is not in the FactoryRegistry approval set.
   */
  error GaugeFactoryNotApproved();

  /**
   * @notice Thrown when the FactoryRegistry records no factory for the request's target.
   */
  error TargetNotRecorded();

  /**
   * @notice Thrown when the gauge factory's linked target factory is not the target's recorded factory.
   */
  error TargetFactoryMismatch();

  /**
   * @notice Thrown when the target is already linked to a gauge. The link is
   *         write once, so no deactivation state reopens a target for creation.
   */
  error TargetAlreadyLinked();

  /**
   * @notice Thrown when a module activates a gauge it does not own.
   */
  error WrongModule();

  /**
   * @notice Thrown when the caller lacks the required role on the LeafVoter.
   */
  error NotAuthorized();

  /**
   * @notice Thrown when a zero address is invalid.
   */
  error ZeroAddress();

  /**
   * @notice Create a gauge over the request's target through its approved
   *         gauge factory, record ownership and relationships, and register
   *         the gauge on the LeafVoter.
   * @dev Caller must be a registered module and is the authoritative module
   *      for the request. The gauge factory must be approved and linked to the
   *      target's recorded factory, and the target must not already be linked
   *      to a gauge. Emits `GaugeCreated` after LeafVoter registration
   *      succeeds.
   * @param _request The normalized creation request.
   * @return _gauge The deployed gauge.
   */
  function createGauge(GaugeCreationRequest calldata _request) external returns (address _gauge);

  /**
   * @notice Activate a gauge on the LeafVoter on behalf of the module that created it.
   * @dev Caller must be a registered module and the recorded module for the
   *      gauge, or hold GOVERNANCE_ROLE on the LeafVoter. The governance path
   *      covers gauges whose module is broken or deregistered.
   * @param _gauge The gauge to activate.
   */
  function activateGauge(address _gauge) external;

  /**
   * @notice Add a module to the caller set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. Reverts on the
   *      zero address and a module already in the set.
   * @param _module The module to register.
   */
  function registerModule(address _module) external;

  /**
   * @notice Remove a module from the caller set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. Reverts when the
   *      module is not in the set.
   * @param _module The module to deregister.
   */
  function deregisterModule(address _module) external;

  /**
   * @notice True when the module is in the caller set.
   * @param _module The module to check.
   * @return _isModule Whether the module is registered.
   */
  function isModule(address _module) external view returns (bool _isModule);

  /**
   * @notice The registered modules.
   * @return _modules The module caller set as an array.
   */
  function modules() external view returns (address[] memory _modules);

  /**
   * @notice Module that created each gauge. Written once at creation and
   *         authorized for the gauge's delayed activation.
   * @param _gauge The gauge to resolve.
   * @return _module The owning module, zero for an unknown gauge.
   */
  function moduleForGauge(address _gauge) external view returns (address _module);

  /**
   * @notice FactoryRegistry validating factories and recording relationships.
   * @return _factoryRegistry The FactoryRegistry.
   */
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry _factoryRegistry);

  /**
   * @notice LeafVoter receiving the gauge lifecycle writes and resolving MODULE_ADMIN_ROLE.
   * @return _leafVoter The LeafVoter.
   */
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);
}
