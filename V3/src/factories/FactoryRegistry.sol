// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title FactoryRegistry
 * @notice Per-chain approval gate for factories and relationship graph of the
 *         protocol. Records on every creation event how gauges, targets,
 *         factories and rewards contracts relate and exposes that graph through
 *         getters the rest of the protocol resolves against. Holds the
 *         TokenRegistry pointer the protocol resolves listing checks through
 *         and the meta router allowlist gauges resolve deposit permissions
 *         through.
 * @dev The target factory admin exists only for the lite launch, where the
 *      registry deploys before the LeafVoter. Until the admin wires the voter
 *      in, the admin is the only authority and can register target factories
 *      so pools can be recorded from day one. A deployment that passes the
 *      LeafVoter at construction never has an admin and wiring the voter in
 *      through setLeafVoter clears it. Once set, permissioned
 *      registration functions resolve their roles through the LeafVoter's
 *      AccessControl state, so the registry carries no AccessControl of its
 *      own. A gauge factory registers and links against the target factory it
 *      serves, writing their permanent one to one link on first use and
 *      reapproving the same pair after unregistration. The target factory may
 *      already be approved through the target factory admin, so a lite launch
 *      factory links to its gauge factory later.
 *      Gauge recording is callable only by the GaugeManager, resolved through
 *      the LeafVoter, and writes a gauge's record and target link exactly
 *      once, with the factory required to be linked and the target required
 *      to originate from the factory's linked target factory.
 *      Every view resolves unknown keys to zero values and never reverts.
 */
contract FactoryRegistry is IFactoryRegistry {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  address public leafVoter;

  /// @inheritdoc IFactoryRegistry
  address public targetFactoryAdmin;

  /// @inheritdoc IFactoryRegistry
  address public tokenRegistry;

  /*//////////////////////////////////////////////////////////////
                              APPROVAL SETS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Approved gauge factories. Membership gates gauge records against
   *         the factory. Exposed as an array by gaugeFactories.
   */
  EnumerableSet.AddressSet internal _gaugeFactories;

  /**
   * @notice Approved target factories. Membership gates target recording.
   *         Exposed as an array by targetFactories.
   */
  EnumerableSet.AddressSet internal _targetFactories;

  /**
   * @notice Approved meta routers. Gauges resolve membership to allow a meta
   *         router to deposit on behalf of a user. Exposed as an array by
   *         metaRouters.
   */
  EnumerableSet.AddressSet internal _metaRouters;

  /*//////////////////////////////////////////////////////////////
                           RELATIONSHIP GRAPH
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  mapping(address _gaugeFactory => address _targetFactory) public gaugeFactoryToTargetFactory;

  /// @inheritdoc IFactoryRegistry
  mapping(address _targetFactory => address _gaugeFactory) public targetFactoryToGaugeFactory;

  /// @inheritdoc IFactoryRegistry
  mapping(address _gauge => address _factory) public gaugeToFactory;

  /// @inheritdoc IFactoryRegistry
  mapping(address _target => address _factory) public targetToFactory;

  /**
   * @notice Targets recorded by each target factory. Exposed as an array by
   *         factoryToTargets.
   */
  mapping(address _factory => EnumerableSet.AddressSet _targets) internal _factoryToTargets;

  /**
   * @notice Gauges recorded by each gauge factory. Exposed as an array by
   *         factoryToGauges.
   */
  mapping(address _factory => EnumerableSet.AddressSet _gauges) internal _factoryToGauges;

  /// @inheritdoc IFactoryRegistry
  mapping(address _gauge => address _target) public gaugeToTarget;

  /// @inheritdoc IFactoryRegistry
  mapping(address _target => address _gauge) public targetToGauge;

  /// @inheritdoc IFactoryRegistry
  mapping(address _gauge => address _rewards) public gaugeToRewards;

  /// @inheritdoc IFactoryRegistry
  mapping(address _rewards => address _gauge) public rewardsToGauge;

  /*//////////////////////////////////////////////////////////////
                               MODIFIERS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Restrict the caller to holders of FACTORY_REGISTRY_ADMIN_ROLE on
   *         the LeafVoter.
   * @dev Reverts with NotAuthorized when the role check fails or the
   *      LeafVoter is not set yet.
   */
  modifier onlyFactoryRegistryAdmin() {
    address _leafVoter = leafVoter;
    if (_leafVoter == address(0) || !IAccessControl(_leafVoter).hasRole(Roles.FACTORY_REGISTRY_ADMIN_ROLE, msg.sender))
    {
      revert NotAuthorized();
    }
    _;
  }

  /**
   * @notice Restrict the caller to the GaugeManager, resolved through the
   *         LeafVoter.
   * @dev Reverts with NotAuthorized for any other caller and while the
   *      LeafVoter is not set yet.
   */
  modifier onlyGaugeManager() {
    address _leafVoter = leafVoter;
    if (_leafVoter == address(0) || msg.sender != ILeafVoter(_leafVoter).GAUGE_MANAGER()) revert NotAuthorized();
    _;
  }

  /**
   * @notice Restrict the caller to the target factory admin.
   * @dev Reverts with NotAuthorized for any other caller.
   */
  modifier onlyTargetFactoryAdmin() {
    if (msg.sender != targetFactoryAdmin) revert NotAuthorized();
    _;
  }

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Wire either the LeafVoter or the initial target factory admin.
   * @dev A regular deployment passes the LeafVoter directly and never has an
   *      admin. The lite launch deploys the registry before the LeafVoter, so
   *      it passes zero, the admin registers target factories in the interim
   *      and wires the voter later through setLeafVoter. Reverts when both or
   *      neither are provided.
   * @param _targetFactoryAdmin Initial target factory admin, zero when the
   *        LeafVoter is provided.
   * @param _leafVoter LeafVoter on this chain, zero when wired later.
   */
  constructor(address _targetFactoryAdmin, address _leafVoter) {
    if (_leafVoter == address(0)) {
      if (_targetFactoryAdmin == address(0)) revert ZeroAddress();
      targetFactoryAdmin = _targetFactoryAdmin;
      emit TargetFactoryAdminSet(_targetFactoryAdmin);
    } else {
      if (_targetFactoryAdmin != address(0)) revert TargetFactoryAdminNotAllowed();
      leafVoter = _leafVoter;
      emit LeafVoterSet(_leafVoter);
    }
  }

  /*//////////////////////////////////////////////////////////////
                               BOOTSTRAP
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function setLeafVoter(address _leafVoter) external onlyTargetFactoryAdmin {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (leafVoter != address(0)) revert LeafVoterAlreadySet();
    leafVoter = _leafVoter;
    delete targetFactoryAdmin;

    emit LeafVoterSet(_leafVoter);
    emit TargetFactoryAdminSet(address(0));
  }

  /// @inheritdoc IFactoryRegistry
  function setTargetFactoryAdmin(address _targetFactoryAdmin) external onlyTargetFactoryAdmin {
    if (_targetFactoryAdmin == address(0)) revert ZeroAddress();
    targetFactoryAdmin = _targetFactoryAdmin;

    emit TargetFactoryAdminSet(_targetFactoryAdmin);
  }

  /*//////////////////////////////////////////////////////////////
                          FACTORY REGISTRATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function registerFactories(address _gaugeFactory, address _targetFactory) external onlyFactoryRegistryAdmin {
    if (_gaugeFactory == address(0) || _targetFactory == address(0)) revert ZeroAddress();
    address _linkedTargetFactory = gaugeFactoryToTargetFactory[_gaugeFactory];
    if (_linkedTargetFactory == address(0)) {
      if (targetFactoryToGaugeFactory[_targetFactory] != address(0)) revert TargetFactoryAlreadyLinked();
    } else if (_linkedTargetFactory != _targetFactory) {
      revert GaugeFactoryAlreadyLinked();
    }
    if (!_gaugeFactories.add(_gaugeFactory)) revert AlreadyRegistered();
    // the target factory may already be approved through the target factory
    // admin via {registerTargetFactory}, so adding it again is not an error
    // and only skips the registration event
    bool _targetFactoryAdded = _targetFactories.add(_targetFactory);

    if (_linkedTargetFactory == address(0)) {
      gaugeFactoryToTargetFactory[_gaugeFactory] = _targetFactory;
      targetFactoryToGaugeFactory[_targetFactory] = _gaugeFactory;
      emit FactoriesLinked({_gaugeFactory: _gaugeFactory, _targetFactory: _targetFactory});
    }

    emit GaugeFactoryRegistered(_gaugeFactory);
    if (_targetFactoryAdded) emit TargetFactoryRegistered(_targetFactory);
  }

  /// @inheritdoc IFactoryRegistry
  function registerTargetFactory(address _targetFactory) external onlyTargetFactoryAdmin {
    if (_targetFactory == address(0)) revert ZeroAddress();
    if (!_targetFactories.add(_targetFactory)) revert AlreadyRegistered();

    emit TargetFactoryRegistered(_targetFactory);
  }

  /// @inheritdoc IFactoryRegistry
  function unregisterFactories(address _gaugeFactory) external onlyFactoryRegistryAdmin {
    if (!_gaugeFactories.remove(_gaugeFactory)) revert NotRegistered();
    address _targetFactory = gaugeFactoryToTargetFactory[_gaugeFactory];
    if (!_targetFactories.remove(_targetFactory)) revert NotRegistered();

    emit GaugeFactoryUnregistered(_gaugeFactory);
    emit TargetFactoryUnregistered(_targetFactory);
  }

  /*//////////////////////////////////////////////////////////////
                        META ROUTER REGISTRATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function registerMetaRouter(address _metaRouter) external onlyFactoryRegistryAdmin {
    if (_metaRouter == address(0)) revert ZeroAddress();
    if (!_metaRouters.add(_metaRouter)) revert AlreadyRegistered();

    emit MetaRouterRegistered(_metaRouter);
  }

  /// @inheritdoc IFactoryRegistry
  function unregisterMetaRouter(address _metaRouter) external onlyFactoryRegistryAdmin {
    if (!_metaRouters.remove(_metaRouter)) revert NotRegistered();

    emit MetaRouterUnregistered(_metaRouter);
  }

  /*//////////////////////////////////////////////////////////////
                             TOKEN REGISTRY
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function setTokenRegistry(address _tokenRegistry) external onlyFactoryRegistryAdmin {
    if (_tokenRegistry == address(0)) revert ZeroAddress();
    tokenRegistry = _tokenRegistry;

    emit TokenRegistrySet(_tokenRegistry);
  }

  /*//////////////////////////////////////////////////////////////
                            TARGET RECORDING
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function registerTarget(address _target) external {
    if (!_targetFactories.contains(msg.sender)) revert TargetFactoryNotRegistered();
    if (_target == address(0)) revert ZeroAddress();
    if (targetToFactory[_target] != address(0)) revert TargetAlreadyRecorded();
    if (!_factoryToTargets[msg.sender].add(_target)) revert AlreadyEnumerated();
    targetToFactory[_target] = msg.sender;

    emit TargetCreated({_target: _target, _targetFactory: msg.sender});
  }

  /*//////////////////////////////////////////////////////////////
                            GAUGE RECORDING
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function registerGauge(
    address _gauge,
    address _gaugeFactory,
    address _rewards,
    address _target
  ) external onlyGaugeManager {
    if (_gauge == address(0) || _rewards == address(0)) revert ZeroAddress();
    if (!_gaugeFactories.contains(_gaugeFactory)) revert GaugeFactoryNotRegistered();
    address _linkedTargetFactory = gaugeFactoryToTargetFactory[_gaugeFactory];
    if (_linkedTargetFactory == address(0)) revert NotLinked();
    if (gaugeToFactory[_gauge] != address(0)) revert GaugeAlreadyRecorded();
    if (rewardsToGauge[_rewards] != address(0)) revert RewardsAlreadyRecorded();
    address _targetFactory = targetToFactory[_target];
    if (_targetFactory == address(0)) revert TargetNotRecorded();
    if (targetToGauge[_target] != address(0)) revert TargetAlreadyLinked();
    if (_targetFactory != _linkedTargetFactory) revert TargetFactoryMismatch();
    if (!_factoryToGauges[_gaugeFactory].add(_gauge)) revert AlreadyEnumerated();

    gaugeToFactory[_gauge] = _gaugeFactory;
    gaugeToRewards[_gauge] = _rewards;
    rewardsToGauge[_rewards] = _gauge;
    gaugeToTarget[_gauge] = _target;
    targetToGauge[_target] = _gauge;

    emit GaugeRegistered({_gauge: _gauge, _gaugeFactory: _gaugeFactory, _target: _target, _rewards: _rewards});
  }

  /*//////////////////////////////////////////////////////////////
                             APPROVAL CHECKS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function isGaugeFactoryApproved(address _gaugeFactory) external view returns (bool _approved) {
    _approved = _gaugeFactories.contains(_gaugeFactory);
  }

  /// @inheritdoc IFactoryRegistry
  function isTargetFactoryApproved(address _targetFactory) external view returns (bool _approved) {
    _approved = _targetFactories.contains(_targetFactory);
  }

  /// @inheritdoc IFactoryRegistry
  function isMetaRouterApproved(address _metaRouter) external view returns (bool _approved) {
    _approved = _metaRouters.contains(_metaRouter);
  }

  /*//////////////////////////////////////////////////////////////
                                SET VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function gaugeFactories() external view returns (address[] memory _factories) {
    _factories = _gaugeFactories.values();
  }

  /// @inheritdoc IFactoryRegistry
  function gaugeFactoriesLength() external view returns (uint256 _length) {
    _length = _gaugeFactories.length();
  }

  /// @inheritdoc IFactoryRegistry
  function gaugeFactoriesAt(uint256 _index) external view returns (address _factory) {
    _factory = _index < _gaugeFactories.length() ? _gaugeFactories.at(_index) : address(0);
  }

  /// @inheritdoc IFactoryRegistry
  function targetFactories() external view returns (address[] memory _factories) {
    _factories = _targetFactories.values();
  }

  /// @inheritdoc IFactoryRegistry
  function targetFactoriesLength() external view returns (uint256 _length) {
    _length = _targetFactories.length();
  }

  /// @inheritdoc IFactoryRegistry
  function targetFactoriesAt(uint256 _index) external view returns (address _factory) {
    _factory = _index < _targetFactories.length() ? _targetFactories.at(_index) : address(0);
  }

  /// @inheritdoc IFactoryRegistry
  function metaRouters() external view returns (address[] memory _routers) {
    _routers = _metaRouters.values();
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToTargets(address _factory) external view returns (address[] memory _targets) {
    _targets = _factoryToTargets[_factory].values();
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToTargetsLength(address _factory) external view returns (uint256 _length) {
    _length = _factoryToTargets[_factory].length();
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToTargetsAt(address _factory, uint256 _index) external view returns (address _target) {
    EnumerableSet.AddressSet storage _targets = _factoryToTargets[_factory];
    _target = _index < _targets.length() ? _targets.at(_index) : address(0);
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToGauges(address _factory) external view returns (address[] memory _gauges) {
    _gauges = _factoryToGauges[_factory].values();
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToGaugesLength(address _factory) external view returns (uint256 _length) {
    _length = _factoryToGauges[_factory].length();
  }

  /// @inheritdoc IFactoryRegistry
  function factoryToGaugesAt(address _factory, uint256 _index) external view returns (address _gauge) {
    EnumerableSet.AddressSet storage _gauges = _factoryToGauges[_factory];
    _gauge = _index < _gauges.length() ? _gauges.at(_index) : address(0);
  }

  /*//////////////////////////////////////////////////////////////
                           FORWARDING GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IFactoryRegistry
  function emissionCap(address _gauge) external view returns (uint128 _cap) {
    address _factory = gaugeToFactory[_gauge];
    if (_factory == address(0)) return 0;
    try IGaugeFactory(_factory).emissionCap(_gauge) returns (uint128 _factoryCap) {
      _cap = _factoryCap;
    } catch {
      _cap = 0;
    }
  }
}
