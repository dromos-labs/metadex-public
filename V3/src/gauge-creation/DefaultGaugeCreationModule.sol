// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IDefaultGaugeCreationModule} from 'V3/interfaces/gauge-creation/IDefaultGaugeCreationModule.sol';
import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title DefaultGaugeCreationModule
 * @notice Public creation module for standard pool targets. Restricts the
 *         caller-chosen gauge factory to an admin-managed allowlist, validates
 *         pool provenance through the FactoryRegistry, requires one listed
 *         base asset, and gates each gauge's one-time activation on both pool
 *         tokens being listed in its TokenRegistry when activation is requested
 * @dev Gauges are created with empty factory data, so every gauge takes the
 *      factory defaults. The TokenRegistry pointer is read live from the
 *      FactoryRegistry for both creation-time and delayed activation.
 *      Administration resolves MODULE_ADMIN_ROLE through the LeafVoter's
 *      AccessControl state, so the module carries none of its own.
 */
contract DefaultGaugeCreationModule is ReentrancyGuardTransient, IDefaultGaugeCreationModule {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeCreationModule
  IGaugeManager public immutable GAUGE_MANAGER;

  /// @inheritdoc IDefaultGaugeCreationModule
  IFactoryRegistry public immutable FACTORY_REGISTRY;

  /// @inheritdoc IDefaultGaugeCreationModule
  ILeafVoter public immutable LEAF_VOTER;

  /*//////////////////////////////////////////////////////////////
                             STATE VARIABLES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Listed base assets. A pool qualifies for creation only when at
   *         least one of its tokens is in the set. Exposed as an array by
   *         `listedBaseAssets`.
   */
  EnumerableSet.AddressSet internal _listedBaseAssets;

  /**
   * @notice Gauge factories this module may create through. The caller-chosen
   *         factory must be in the set. Exposed as an array by
   *         `allowedGaugeFactories`.
   */
  EnumerableSet.AddressSet internal _allowedGaugeFactories;

  /*//////////////////////////////////////////////////////////////
                               MODIFIERS
  //////////////////////////////////////////////////////////////*/

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
   * @notice Wire the LeafVoter reference.
   * @dev The FactoryRegistry and GaugeManager are read from the LeafVoter so
   *      all three always agree on them. Reverts when the address is zero or
   *      the LeafVoter reports a zero FactoryRegistry or GaugeManager.
   * @param _leafVoter LeafVoter on this chain.
   */
  constructor(address _leafVoter) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    IFactoryRegistry _factoryRegistry = ILeafVoter(_leafVoter).FACTORY_REGISTRY();
    address _gaugeManager = ILeafVoter(_leafVoter).GAUGE_MANAGER();
    if (address(_factoryRegistry) == address(0) || _gaugeManager == address(0)) revert ZeroAddress();

    GAUGE_MANAGER = IGaugeManager(_gaugeManager);
    FACTORY_REGISTRY = _factoryRegistry;
    LEAF_VOTER = ILeafVoter(_leafVoter);
  }

  /*//////////////////////////////////////////////////////////////
                            GAUGE LIFECYCLE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDefaultGaugeCreationModule
  function createGauge(address _target, address _gaugeFactory) external nonReentrant returns (address _gauge) {
    if (!_allowedGaugeFactories.contains(_gaugeFactory)) revert GaugeFactoryNotAllowed();

    address _targetFactory = FACTORY_REGISTRY.targetToFactory(_target);
    if (_targetFactory == address(0) || !IPoolFactory(_targetFactory).isPool(_target)) revert NotAPool();

    address _token0 = IPool(_target).token0();
    address _token1 = IPool(_target).token1();
    if (!_listedBaseAssets.contains(_token0) && !_listedBaseAssets.contains(_token1)) revert NoListedBaseAsset();

    ITokenRegistry _tokenRegistry = ITokenRegistry(FACTORY_REGISTRY.tokenRegistry());
    bool _activate = _tokenRegistry.isListed(_token0) && _tokenRegistry.isListed(_token1);

    _gauge = GAUGE_MANAGER.createGauge(
      IGaugeManager.GaugeCreationRequest({
        creator: msg.sender, gaugeFactory: _gaugeFactory, target: _target, factoryData: '', activate: _activate
      })
    );
  }

  /// @inheritdoc IGaugeCreationModule
  function activate(address _gauge) external {
    address _target = FACTORY_REGISTRY.gaugeToTarget(_gauge);
    if (_target == address(0)) revert GaugeNotRegistered();

    address _token0 = IPool(_target).token0();
    address _token1 = IPool(_target).token1();
    ITokenRegistry _tokenRegistry = ITokenRegistry(FACTORY_REGISTRY.tokenRegistry());
    if (!_tokenRegistry.isListed(_token0)) revert TokenNotListed(_token0);
    if (!_tokenRegistry.isListed(_token1)) revert TokenNotListed(_token1);

    GAUGE_MANAGER.activateGauge(_gauge);
  }

  /*//////////////////////////////////////////////////////////////
                             ADMINISTRATION
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDefaultGaugeCreationModule
  function addListedBaseAsset(address _token) external onlyModuleAdmin {
    if (_token == address(0)) revert ZeroAddress();
    if (!_listedBaseAssets.add(_token)) return;

    emit ListedBaseAssetAdded(_token);
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function removeListedBaseAsset(address _token) external onlyModuleAdmin {
    if (!_listedBaseAssets.remove(_token)) return;

    emit ListedBaseAssetRemoved(_token);
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function addAllowedGaugeFactory(address _gaugeFactory) external onlyModuleAdmin {
    if (_gaugeFactory == address(0)) revert ZeroAddress();
    if (!_allowedGaugeFactories.add(_gaugeFactory)) revert GaugeFactoryAlreadyAllowed();

    emit GaugeFactoryAllowed(_gaugeFactory);
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function removeAllowedGaugeFactory(address _gaugeFactory) external onlyModuleAdmin {
    if (!_allowedGaugeFactories.remove(_gaugeFactory)) revert GaugeFactoryNotAllowed();

    emit GaugeFactoryDisallowed(_gaugeFactory);
  }

  /*//////////////////////////////////////////////////////////////
                                SET VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDefaultGaugeCreationModule
  function isListedBaseAsset(address _token) external view returns (bool _isListed) {
    _isListed = _listedBaseAssets.contains(_token);
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function listedBaseAssets() external view returns (address[] memory _tokens) {
    _tokens = _listedBaseAssets.values();
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function isAllowedGaugeFactory(address _gaugeFactory) external view returns (bool _isAllowed) {
    _isAllowed = _allowedGaugeFactories.contains(_gaugeFactory);
  }

  /// @inheritdoc IDefaultGaugeCreationModule
  function allowedGaugeFactories() external view returns (address[] memory _gaugeFactories) {
    _gaugeFactories = _allowedGaugeFactories.values();
  }
}
