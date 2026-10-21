// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title IDefaultGaugeCreationModule
 * @notice Public creation module for standard pool targets. Restricts the
 *         caller-chosen gauge factory to an admin-managed allowlist, validates
 *         pool provenance through the FactoryRegistry, requires one listed
 *         base asset, and gates each gauge's one-time activation on both pool
 *         tokens being listed in its TokenRegistry when activation is requested
 */
interface IDefaultGaugeCreationModule is IGaugeCreationModule {
  /**
   * @notice Emitted when a token is added to the listed base asset set.
   * @param _token The added token.
   */
  event ListedBaseAssetAdded(address indexed _token);

  /**
   * @notice Emitted when a token is removed from the listed base asset set.
   * @param _token The removed token.
   */
  event ListedBaseAssetRemoved(address indexed _token);

  /**
   * @notice Emitted when a gauge factory is added to the allowed set.
   * @param _gaugeFactory The allowed gauge factory.
   */
  event GaugeFactoryAllowed(address indexed _gaugeFactory);

  /**
   * @notice Emitted when a gauge factory is removed from the allowed set.
   * @param _gaugeFactory The disallowed gauge factory.
   */
  event GaugeFactoryDisallowed(address indexed _gaugeFactory);

  /**
   * @notice Thrown when the target is unrecorded in the FactoryRegistry or its
   *         recorded factory does not report it as a pool.
   */
  error NotAPool();

  /**
   * @notice Thrown when neither pool token is in the listed base asset set.
   */
  error NoListedBaseAsset();

  /**
   * @notice Thrown by `createGauge` when the chosen gauge factory is not in
   *         the allowed set, and by `removeAllowedGaugeFactory` when the
   *         factory to remove is not in the set.
   */
  error GaugeFactoryNotAllowed();

  /**
   * @notice Thrown when the gauge factory to allow is already in the set.
   */
  error GaugeFactoryAlreadyAllowed();

  /**
   * @notice Thrown when the caller lacks MODULE_ADMIN_ROLE on the LeafVoter.
   */
  error NotAuthorized();

  /**
   * @notice Thrown by `activate` when the FactoryRegistry records no target for the gauge.
   */
  error GaugeNotRegistered();

  /**
   * @notice Thrown by `activate` when a pool token is not listed in the TokenRegistry.
   * @param _token The first unlisted token.
   */
  error TokenNotListed(address _token);

  /**
   * @notice Validate a pool target and create its gauge through the
   *         caller-chosen gauge factory with the factory defaults.
   * @dev The gauge factory must be in the allowed set, the target must be
   *      recorded as a pool, and at least one of its tokens must be a listed
   *      base asset. The request carries empty factory data and activates
   *      immediately only when both pool tokens are listed in the
   *      TokenRegistry.
   * @param _target The pool to create a gauge over.
   * @param _gaugeFactory The approved gauge factory to deploy through.
   * @return _gauge The deployed gauge.
   */
  function createGauge(address _target, address _gaugeFactory) external returns (address _gauge);

  /**
   * @notice Add a token to the listed base asset set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. Reverts on the
   *      zero address. No-op without an event when the token is already
   *      listed.
   * @param _token The token to add.
   */
  function addListedBaseAsset(address _token) external;

  /**
   * @notice Remove a token from the listed base asset set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. No-op without
   *      an event when the token is not listed.
   * @param _token The token to remove.
   */
  function removeListedBaseAsset(address _token) external;

  /**
   * @notice Add a gauge factory to the allowed set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. Reverts on the
   *      zero address and a factory already in the set.
   * @param _gaugeFactory The gauge factory to allow.
   */
  function addAllowedGaugeFactory(address _gaugeFactory) external;

  /**
   * @notice Remove a gauge factory from the allowed set.
   * @dev Caller must hold MODULE_ADMIN_ROLE on the LeafVoter. Reverts when
   *      the factory is not in the set.
   * @param _gaugeFactory The gauge factory to disallow.
   */
  function removeAllowedGaugeFactory(address _gaugeFactory) external;

  /**
   * @notice True when the token is in the listed base asset set.
   * @param _token The token to check.
   * @return _isListed Whether the token is a listed base asset.
   */
  function isListedBaseAsset(address _token) external view returns (bool _isListed);

  /**
   * @notice The listed base assets.
   * @return _tokens The listed base asset set as an array.
   */
  function listedBaseAssets() external view returns (address[] memory _tokens);

  /**
   * @notice True when the gauge factory is in the allowed set.
   * @param _gaugeFactory The gauge factory to check.
   * @return _isAllowed Whether the gauge factory is allowed.
   */
  function isAllowedGaugeFactory(address _gaugeFactory) external view returns (bool _isAllowed);

  /**
   * @notice The allowed gauge factories.
   * @return _gaugeFactories The allowed gauge factory set as an array.
   */
  function allowedGaugeFactories() external view returns (address[] memory _gaugeFactories);

  /**
   * @notice FactoryRegistry resolving target provenance and gauge targets and
   *         supplying the TokenRegistry pointer read live for creation-time
   *         and delayed activation.
   * @return _factoryRegistry The FactoryRegistry.
   */
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry _factoryRegistry);

  /**
   * @notice LeafVoter resolving MODULE_ADMIN_ROLE for administration.
   * @return _leafVoter The LeafVoter, read from the GaugeManager at deployment.
   */
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);
}
