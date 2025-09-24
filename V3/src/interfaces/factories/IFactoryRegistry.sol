// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IFactoryRegistry
 * @notice Per-chain approval gate for factories and relationship graph of the
 *         protocol. Tracks which gauge factories and target factories may
 *         participate on the chain, records how gauges, targets, factories
 *         and rewards contracts relate and holds the meta router allowlist.
 */
interface IFactoryRegistry {
  /**
   * @notice Emitted when a gauge factory is registered into the approval set.
   * @param _gaugeFactory The registered gauge factory.
   */
  event GaugeFactoryRegistered(address indexed _gaugeFactory);

  /**
   * @notice Emitted when a gauge factory and a target factory are linked.
   * @param _gaugeFactory The linked gauge factory.
   * @param _targetFactory The target factory the gauge factory serves.
   */
  event FactoriesLinked(address indexed _gaugeFactory, address indexed _targetFactory);

  /**
   * @notice Emitted when a gauge factory is removed from the approval set.
   * @param _gaugeFactory The unregistered gauge factory.
   */
  event GaugeFactoryUnregistered(address indexed _gaugeFactory);

  /**
   * @notice Emitted when a target factory is registered into the approval set.
   * @param _targetFactory The registered target factory.
   */
  event TargetFactoryRegistered(address indexed _targetFactory);

  /**
   * @notice Emitted when a target factory is removed from the approval set.
   * @param _targetFactory The unregistered target factory.
   */
  event TargetFactoryUnregistered(address indexed _targetFactory);

  /**
   * @notice Emitted when a target factory records a freshly deployed target.
   * @param _target The recorded target.
   * @param _targetFactory The target factory that deployed the target.
   */
  event TargetCreated(address indexed _target, address indexed _targetFactory);

  /**
   * @notice Emitted when the GaugeManager records a freshly created gauge.
   * @param _gauge The recorded gauge.
   * @param _gaugeFactory The gauge factory that deployed the gauge.
   * @param _target The target the gauge points at.
   * @param _rewards The gauge's rewards contract.
   */
  event GaugeRegistered(
    address indexed _gauge, address indexed _gaugeFactory, address indexed _target, address _rewards
  );

  /**
   * @notice Emitted when the TokenRegistry pointer is updated.
   * @param _tokenRegistry The new TokenRegistry.
   */
  event TokenRegistrySet(address indexed _tokenRegistry);

  /**
   * @notice Emitted when the LeafVoter is wired in.
   * @param _leafVoter The LeafVoter address.
   */
  event LeafVoterSet(address indexed _leafVoter);

  /**
   * @notice Emitted when the target factory admin is set.
   * @param _targetFactoryAdmin The new target factory admin.
   */
  event TargetFactoryAdminSet(address indexed _targetFactoryAdmin);

  /**
   * @notice Emitted when a meta router is registered into the approval set.
   * @param _metaRouter The registered meta router.
   */
  event MetaRouterRegistered(address indexed _metaRouter);

  /**
   * @notice Emitted when a meta router is removed from the approval set.
   * @param _metaRouter The unregistered meta router.
   */
  event MetaRouterUnregistered(address indexed _metaRouter);

  /**
   * @notice Thrown when the caller lacks the required authorization.
   */
  error NotAuthorized();

  /**
   * @notice Thrown when a zero address is invalid.
   */
  error ZeroAddress();

  /**
   * @notice Thrown when registering an entry already in its approval set.
   */
  error AlreadyRegistered();

  /**
   * @notice Thrown when unregistering an entry not in its approval set.
   */
  error NotRegistered();

  /**
   * @notice Thrown when a target factory required by the operation is not in the approval set.
   */
  error TargetFactoryNotRegistered();

  /**
   * @notice Thrown when a gauge factory required by the operation is not in the approval set.
   */
  error GaugeFactoryNotRegistered();

  /**
   * @notice Thrown when registering a target already recorded in the registry.
   */
  error TargetAlreadyRecorded();

  /**
   * @notice Thrown when registering a gauge already recorded in the registry.
   */
  error GaugeAlreadyRecorded();

  /**
   * @notice Thrown when registering a gauge with a rewards contract already recorded for another gauge.
   */
  error RewardsAlreadyRecorded();

  /**
   * @notice Thrown when adding an entry already present in a factory enumeration.
   */
  error AlreadyEnumerated();

  /**
   * @notice Thrown when linking a gauge to a target not recorded in the registry.
   */
  error TargetNotRecorded();

  /**
   * @notice Thrown when linking a gauge to a target already linked to a gauge.
   */
  error TargetAlreadyLinked();

  /**
   * @notice Thrown when linking a gauge to a target not deployed by its factory's linked target factory.
   */
  error TargetFactoryMismatch();

  /**
   * @notice Thrown when registering a gauge factory against a target factory other than its linked one.
   */
  error GaugeFactoryAlreadyLinked();

  /**
   * @notice Thrown when registering a gauge factory against a target factory already linked to another gauge factory.
   */
  error TargetFactoryAlreadyLinked();

  /**
   * @notice Thrown when the operation requires a gauge factory with a linked target factory and none is recorded.
   */
  error NotLinked();

  /**
   * @notice Thrown when setting the LeafVoter after it has already been set.
   */
  error LeafVoterAlreadySet();

  /**
   * @notice Thrown when deploying with a target factory admin while the LeafVoter is provided.
   */
  error TargetFactoryAdminNotAllowed();

  /**
   * @notice Register a gauge factory and the target factory it serves as a
   *         pair, writing their permanent one to one link on first
   *         registration. The only writer of the link. Registering a
   *         previously unregistered pair reapproves it against the recorded
   *         link. The target factory may already be approved through the
   *         target factory admin, in which case this call links it to its
   *         gauge factory.
   * @dev Caller must hold FACTORY_REGISTRY_ADMIN_ROLE on the LeafVoter.
   *      Reverts on zero addresses, when either factory is linked to a
   *      different counterpart and when the gauge factory is already in its
   *      approval set.
   * @param _gaugeFactory The gauge factory to register.
   * @param _targetFactory The target factory the gauge factory serves.
   */
  function registerFactories(address _gaugeFactory, address _targetFactory) external;

  /**
   * @notice Register a target factory into the approval set without a gauge
   *         factory pair. Lets the lite launch approve pool factories before
   *         the LeafVoter and the gauge stack exist, with the gauge factory
   *         linked later through registerFactories.
   * @dev Caller must be the target factory admin. Reverts on the zero address
   *      and a target factory already in the set.
   * @param _targetFactory The target factory to register.
   */
  function registerTargetFactory(address _targetFactory) external;

  /**
   * @notice Wire the LeafVoter the registry resolves roles and the
   *         GaugeManager through. The lite launch deploys the registry before
   *         the LeafVoter, so the voter is set once by the target factory
   *         admin here instead of at construction. Wiring the voter clears
   *         the target factory admin, disabling the bootstrap role.
   * @dev Caller must be the target factory admin. Reverts on the zero address
   *      and when the LeafVoter is already set.
   * @param _leafVoter The LeafVoter on this chain.
   */
  function setLeafVoter(address _leafVoter) external;

  /**
   * @notice Update the target factory admin.
   * @dev Caller must be the target factory admin. Reverts on the zero address.
   * @param _targetFactoryAdmin The new target factory admin.
   */
  function setTargetFactoryAdmin(address _targetFactoryAdmin) external;

  /**
   * @notice Remove a gauge factory and its linked target factory from their
   *         approval sets as a pair. The link and every record the factories
   *         established keep resolving.
   * @dev Caller must hold FACTORY_REGISTRY_ADMIN_ROLE on the LeafVoter.
   *      Resolves the target factory through the recorded link. Reverts when
   *      either factory is not in its approval set.
   * @param _gaugeFactory The gauge factory of the pair to unregister.
   */
  function unregisterFactories(address _gaugeFactory) external;

  /**
   * @notice Update the TokenRegistry pointer. The registry is a peripheral
   *         contract that can be replaced, so the pointer is settable.
   * @dev Caller must hold FACTORY_REGISTRY_ADMIN_ROLE on the LeafVoter.
   *      Reverts on the zero address.
   * @param _tokenRegistry The new TokenRegistry.
   */
  function setTokenRegistry(address _tokenRegistry) external;

  /**
   * @notice Add a meta router to the approval set. Multiple meta routers can
   *         be approved at once so older versions keep working while new ones
   *         roll out.
   * @dev Caller must hold FACTORY_REGISTRY_ADMIN_ROLE on the LeafVoter.
   *      Reverts on the zero address and a meta router already in the set.
   * @param _metaRouter The meta router to register.
   */
  function registerMetaRouter(address _metaRouter) external;

  /**
   * @notice Remove a meta router from the approval set.
   * @dev Caller must hold FACTORY_REGISTRY_ADMIN_ROLE on the LeafVoter.
   *      Reverts when the meta router is not in the set.
   * @param _metaRouter The meta router to unregister.
   */
  function unregisterMetaRouter(address _metaRouter) external;

  /**
   * @notice Record a freshly deployed target. Called by the target factory
   *         inside its own creation function.
   * @dev msg.sender must be a registered target factory, so a factory outside
   *      the approval set cannot deploy at all. Reverts on the zero address, a
   *      target already recorded and a target already in the factory
   *      enumeration.
   * @param _target The deployed target.
   */
  function registerTarget(address _target) external;

  /**
   * @notice Record a freshly created gauge with its factory, rewards contract
   *         and target link. Called by the GaugeManager in the creation
   *         transaction. Writes both sides of the link, which is permanent
   *         with no later write path.
   * @dev msg.sender must be the GaugeManager, resolved through the LeafVoter.
   *      The gauge factory must be
   *      registered and linked and the target recorded by that factory's
   *      linked target factory. Reverts on zero addresses, a gauge already recorded or
   *      enumerated, a rewards contract already recorded and a target already
   *      linked to a gauge, so the record is write once in every direction.
   * @param _gauge The deployed gauge.
   * @param _gaugeFactory The gauge factory that deployed it.
   * @param _rewards The gauge's rewards contract.
   * @param _target The target the gauge points at.
   */
  function registerGauge(address _gauge, address _gaugeFactory, address _rewards, address _target) external;

  /**
   * @notice True when the gauge factory is in the approval set.
   * @param _gaugeFactory The gauge factory to check.
   * @return _approved Whether the gauge factory is registered.
   */
  function isGaugeFactoryApproved(address _gaugeFactory) external view returns (bool _approved);

  /**
   * @notice True when the target factory is in the approval set.
   * @param _targetFactory The target factory to check.
   * @return _approved Whether the target factory is registered.
   */
  function isTargetFactoryApproved(address _targetFactory) external view returns (bool _approved);

  /**
   * @notice True when the meta router is in the approval set. Gauges resolve
   *         this check to allow a meta router to deposit on behalf of a user.
   * @param _metaRouter The meta router to check.
   * @return _approved Whether the meta router is registered.
   */
  function isMetaRouterApproved(address _metaRouter) external view returns (bool _approved);

  /**
   * @notice The registered gauge factories.
   * @return _factories The gauge factory approval set as an array.
   */
  function gaugeFactories() external view returns (address[] memory _factories);

  /**
   * @notice The number of registered gauge factories.
   * @return _length The gauge factory approval set member count.
   */
  function gaugeFactoriesLength() external view returns (uint256 _length);

  /**
   * @notice The registered gauge factory at an index.
   * @param _index The index to read.
   * @return _factory The member at the index, zero for an out of range index.
   */
  function gaugeFactoriesAt(uint256 _index) external view returns (address _factory);

  /**
   * @notice The registered target factories.
   * @return _factories The target factory approval set as an array.
   */
  function targetFactories() external view returns (address[] memory _factories);

  /**
   * @notice The number of registered target factories.
   * @return _length The target factory approval set member count.
   */
  function targetFactoriesLength() external view returns (uint256 _length);

  /**
   * @notice The registered target factory at an index.
   * @param _index The index to read.
   * @return _factory The member at the index, zero for an out of range index.
   */
  function targetFactoriesAt(uint256 _index) external view returns (address _factory);

  /**
   * @notice The registered meta routers.
   * @return _metaRouters The meta router approval set as an array.
   */
  function metaRouters() external view returns (address[] memory _metaRouters);

  /**
   * @notice The targets recorded by a target factory.
   * @param _factory The target factory to enumerate.
   * @return _targets The targets the factory deployed as an array.
   */
  function factoryToTargets(address _factory) external view returns (address[] memory _targets);

  /**
   * @notice The number of targets recorded by a target factory.
   * @param _factory The target factory to enumerate.
   * @return _length The recorded target count.
   */
  function factoryToTargetsLength(address _factory) external view returns (uint256 _length);

  /**
   * @notice The target recorded by a target factory at an index.
   * @param _factory The target factory to enumerate.
   * @param _index The index to read.
   * @return _target The member at the index, zero for an out of range index.
   */
  function factoryToTargetsAt(address _factory, uint256 _index) external view returns (address _target);

  /**
   * @notice The gauges recorded by a gauge factory.
   * @param _factory The gauge factory to enumerate.
   * @return _gauges The gauges the factory deployed as an array.
   */
  function factoryToGauges(address _factory) external view returns (address[] memory _gauges);

  /**
   * @notice The number of gauges recorded by a gauge factory.
   * @param _factory The gauge factory to enumerate.
   * @return _length The recorded gauge count.
   */
  function factoryToGaugesLength(address _factory) external view returns (uint256 _length);

  /**
   * @notice The gauge recorded by a gauge factory at an index.
   * @param _factory The gauge factory to enumerate.
   * @param _index The index to read.
   * @return _gauge The member at the index, zero for an out of range index.
   */
  function factoryToGaugesAt(address _factory, uint256 _index) external view returns (address _gauge);

  /**
   * @notice Emission cap for a gauge, read from the factory that deployed it.
   * @dev Returns zero when the gauge is unknown or the factory call reverts.
   *      Resolves through the recorded gauge to factory link, so unregistering
   *      a factory stops new gauges but leaves existing caps intact.
   * @param _gauge The gauge to resolve.
   * @return _cap The gauge emission cap in tokens per second.
   */
  function emissionCap(address _gauge) external view returns (uint128 _cap);

  /**
   * @notice LeafVoter on this chain. Resolves roles for every permissioned
   *         registration function and the GaugeManager for gauge recording.
   *         Set at construction in a regular deployment. In the lite launch
   *         it is zero until the target factory admin wires it in through
   *         setLeafVoter.
   * @return _leafVoter The LeafVoter address.
   */
  function leafVoter() external view returns (address _leafVoter);

  /**
   * @notice Bootstrap authority of the registry, added for the lite launch
   *         where the registry deploys before the LeafVoter. Registers target
   *         factories before the LeafVoter exists and wires the LeafVoter in
   *         once deployed.
   * @return _targetFactoryAdmin The target factory admin address, zero once
   *         the LeafVoter is set.
   */
  function targetFactoryAdmin() external view returns (address _targetFactoryAdmin);

  /**
   * @notice TokenRegistry supplying token listing checks on this chain.
   * @return _tokenRegistry The current TokenRegistry, zero until set.
   */
  function tokenRegistry() external view returns (address _tokenRegistry);

  /**
   * @notice Gauge factory that deployed each gauge. Written once when the
   *         GaugeManager records the gauge.
   * @param _gauge The gauge to resolve.
   * @return _factory The deploying gauge factory, zero for an unknown gauge.
   */
  function gaugeToFactory(address _gauge) external view returns (address _factory);

  /**
   * @notice Target factory that deployed each target. Written once when the
   *         factory records the target.
   * @param _target The target to resolve.
   * @return _factory The deploying target factory, zero for an unknown target.
   */
  function targetToFactory(address _target) external view returns (address _factory);

  /**
   * @notice The target a gauge points at. Written once when the GaugeManager
   *         records the gauge, with no later write path.
   * @param _gauge The gauge to resolve.
   * @return _target The linked target, zero for a gauge with no target.
   */
  function gaugeToTarget(address _gauge) external view returns (address _target);

  /**
   * @notice The gauge over a target. Written once when the GaugeManager
   *         records the gauge, together with the forward direction, with no
   *         later write path.
   * @param _target The target to resolve.
   * @return _gauge The linked gauge, zero for a target with no gauge.
   */
  function targetToGauge(address _target) external view returns (address _gauge);

  /**
   * @notice The target factory a gauge factory serves. Written once by the
   *         pair registration entrypoint and never modified afterwards,
   *         including across reregistration.
   * @param _gaugeFactory The gauge factory to resolve.
   * @return _targetFactory The linked target factory, zero for an unlinked factory.
   */
  function gaugeFactoryToTargetFactory(address _gaugeFactory) external view returns (address _targetFactory);

  /**
   * @notice The gauge factory serving a target factory. Written once together
   *         with the forward direction and never modified afterwards,
   *         including across reregistration.
   * @param _targetFactory The target factory to resolve.
   * @return _gaugeFactory The linked gauge factory, zero for an unlinked factory.
   */
  function targetFactoryToGaugeFactory(address _targetFactory) external view returns (address _gaugeFactory);

  /**
   * @notice Rewards contract escrowing fees and incentives for each gauge.
   *         Written once when the GaugeManager records the gauge.
   * @param _gauge The gauge to resolve.
   * @return _rewards The rewards contract, zero for an unknown gauge.
   */
  function gaugeToRewards(address _gauge) external view returns (address _rewards);

  /**
   * @notice Gauge behind each rewards contract. Written once when the
   *         GaugeManager records the gauge, together with the forward
   *         direction. Rewards contracts carry no gauge reference, so this is
   *         the only on-chain path from a rewards contract back to its gauge.
   * @param _rewards The rewards contract to resolve.
   * @return _gauge The recorded gauge, zero for an unknown rewards contract.
   */
  function rewardsToGauge(address _rewards) external view returns (address _gauge);
}
