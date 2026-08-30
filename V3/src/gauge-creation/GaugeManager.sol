// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title GaugeManager
 * @notice Target-agnostic gauge lifecycle proxy. Registered creation modules
 *         forward normalized creation requests and delayed activations through
 *         it. It validates factory approval and target provenance against the
 *         FactoryRegistry, deploys through the requested gauge factory, records
 *         gauge-to-module ownership, reports relationships to the
 *         FactoryRegistry and drives the LeafVoter lifecycle hooks.
 * @dev Module administration resolves MODULE_ADMIN_ROLE through the
 *      LeafVoter's AccessControl state, so the manager carries none of its
 *      own.
 */
contract GaugeManager is ReentrancyGuardTransient, IGaugeManager {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeManager
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @inheritdoc IGaugeManager
  ILeafVoter public immutable LEAF_VOTER;

  /*//////////////////////////////////////////////////////////////
                             MODULE REGISTRY
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Registered module callers. Membership authorizes `createGauge`
   *         and `activateGauge`. Exposed as an array by `modules`.
   */
  EnumerableSet.AddressSet internal _modules;

  /// @inheritdoc IGaugeManager
  mapping(address _gauge => address _module) public moduleForGauge;

  /*//////////////////////////////////////////////////////////////
                               MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restrict the caller to registered modules.
   * @dev Reverts with ModuleNotRegistered when the caller is not in the set.
   */
  modifier onlyRegisteredModule() {
    if (!_modules.contains(msg.sender)) revert ModuleNotRegistered();
    _;
  }

  /**
   * @notice Restrict the caller to holders of MODULE_ADMIN_ROLE on the
   *         LeafVoter.
   * @dev Reverts with NotAuthorized when the role check fails.
   */
  modifier onlyModuleAdmin() {
    if (!LEAF_VOTER.hasRole(Roles.MODULE_ADMIN_ROLE, msg.sender)) revert NotAuthorized();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Wire the FactoryRegistry and LeafVoter references.
   * @dev The FactoryRegistry takes this manager's address at construction too,
   *      so the deployment script precomputes the missing address to break the
   *      circularity. Reverts when either address is zero.
   * @param _factoryRegistry FactoryRegistry on this chain.
   * @param _leafVoter LeafVoter on this chain.
   */
  constructor(address _factoryRegistry, address _leafVoter) {
    if (_factoryRegistry == address(0) || _leafVoter == address(0)) revert ZeroAddress();
    FACTORY_REGISTRY = IFactoryRegistry(_factoryRegistry);
    LEAF_VOTER = ILeafVoter(_leafVoter);
  }

  /*//////////////////////////////////////////////////////////////
                            GAUGE LIFECYCLE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeManager
  function createGauge(GaugeCreationRequest calldata _request)
    external
    nonReentrant
    onlyRegisteredModule
    returns (address _gauge)
  {
    if (!FACTORY_REGISTRY.isGaugeFactoryApproved(_request.gaugeFactory)) {
      revert GaugeFactoryNotApproved();
    }
    address _targetFactory = FACTORY_REGISTRY.targetToFactory(_request.target);
    if (_targetFactory == address(0)) revert TargetNotRecorded();
    if (FACTORY_REGISTRY.gaugeFactoryToTargetFactory(_request.gaugeFactory) != _targetFactory) {
      revert TargetFactoryMismatch();
    }

    if (FACTORY_REGISTRY.targetToGauge(_request.target) != address(0)) revert TargetAlreadyLinked();

    address _rewards;
    (_gauge, _rewards) = IGaugeFactory(_request.gaugeFactory).createGauge(_request.target, _request.factoryData);

    moduleForGauge[_gauge] = msg.sender;

    FACTORY_REGISTRY.registerGauge(_gauge, _request.gaugeFactory, _rewards, _request.target);
    LEAF_VOTER.registerGauge(_gauge, _request.activate);

    emit GaugeCreated({
      _target: _request.target,
      _gauge: _gauge,
      _module: msg.sender,
      _gaugeFactory: _request.gaugeFactory,
      _votingRewardsManager: _rewards,
      _creator: _request.creator,
      _activated: _request.activate
    });
  }

  /// @inheritdoc IGaugeManager
  function activateGauge(address _gauge) external nonReentrant {
    // Governance can activate any gauge, covering gauges whose module is
    // broken or deregistered.
    if (!LEAF_VOTER.hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) {
      if (!_modules.contains(msg.sender)) revert ModuleNotRegistered();
      if (moduleForGauge[_gauge] != msg.sender) revert WrongModule();
    }
    LEAF_VOTER.activateGauge(_gauge);
  }

  /*//////////////////////////////////////////////////////////////
                          MODULE ADMINISTRATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeManager
  function registerModule(address _module) external onlyModuleAdmin {
    if (_module == address(0)) revert ZeroAddress();
    if (!_modules.add(_module)) revert ModuleAlreadyRegistered();

    emit ModuleRegistered(_module);
  }

  /// @inheritdoc IGaugeManager
  function deregisterModule(address _module) external onlyModuleAdmin {
    if (!_modules.remove(_module)) revert ModuleNotRegistered();

    emit ModuleDeregistered(_module);
  }

  /*//////////////////////////////////////////////////////////////
                                SET VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeManager
  function isModule(address _module) external view returns (bool _isModule) {
    _isModule = _modules.contains(_module);
  }

  /// @inheritdoc IGaugeManager
  function modules() external view returns (address[] memory _moduleList) {
    _moduleList = _modules.values();
  }
}
