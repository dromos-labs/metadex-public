// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {GaugeManager} from 'V3/gauge-creation/GaugeManager.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitGaugeManagerCreateGauge is TestHelpers {
  address internal _factoryRegistry = makeAddr('_factoryRegistry');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _moduleAdmin = makeAddr('_moduleAdmin');
  address internal _module = makeAddr('_module');
  address internal _gaugeFactory = makeAddr('_gaugeFactory');
  address internal _targetFactory = makeAddr('_targetFactory');
  address internal _target = makeAddr('_target');
  address internal _gauge = makeAddr('_gauge');
  address internal _votingRewardsManager = makeAddr('_votingRewardsManager');
  address internal _creator = makeAddr('_creator');

  GaugeManager internal _gaugeManager;

  function setUp() public {
    _gaugeManager = new GaugeManager(_factoryRegistry, _leafVoter);
  }

  function test_WhenTheCallerIsNotARegisteredModule(address _caller) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ModuleNotRegistered
    vm.expectRevert(IGaugeManager.ModuleNotRegistered.selector);
    _gaugeManager.createGauge(_defaultRequest());
  }

  modifier whenTheCallerIsARegisteredModule() {
    _registerModule(_module);
    vm.startPrank(_module);
    _;
    vm.stopPrank();
  }

  function test_WhenTheGaugeFactoryIsNotApproved() external whenTheCallerIsARegisteredModule {
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_gaugeFactory)), abi.encode(false)
    );

    // it should revert with GaugeFactoryNotApproved
    vm.expectRevert(IGaugeManager.GaugeFactoryNotApproved.selector);
    _gaugeManager.createGauge(_defaultRequest());
  }

  modifier whenTheGaugeFactoryIsApproved() {
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_gaugeFactory)), abi.encode(true)
    );
    _;
  }

  function test_WhenTheTargetHasNoRecordedFactory()
    external
    whenTheCallerIsARegisteredModule
    whenTheGaugeFactoryIsApproved
  {
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(address(0)));

    // it should revert with TargetNotRecorded
    vm.expectRevert(IGaugeManager.TargetNotRecorded.selector);
    _gaugeManager.createGauge(_defaultRequest());
  }

  function test_WhenTheGaugeFactoryLinksToADifferentTargetFactory(address _linkedTargetFactory)
    external
    whenTheCallerIsARegisteredModule
    whenTheGaugeFactoryIsApproved
  {
    _linkedTargetFactory = _boundNotEq(_linkedTargetFactory, _targetFactory);
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(_targetFactory)
    );
    vm.mockCall(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.gaugeFactoryToTargetFactory, (_gaugeFactory)),
      abi.encode(_linkedTargetFactory)
    );

    // it should revert with TargetFactoryMismatch
    vm.expectRevert(IGaugeManager.TargetFactoryMismatch.selector);
    _gaugeManager.createGauge(_defaultRequest());
  }

  function test_WhenTheTargetIsAlreadyLinkedToAGauge(address _linkedGauge)
    external
    whenTheCallerIsARegisteredModule
    whenTheGaugeFactoryIsApproved
  {
    _assumeFuzzable(_linkedGauge);
    vm.assume(_linkedGauge != address(0));

    _mockTargetLinks();
    _mockTargetToGauge(_linkedGauge);

    // it should revert with TargetAlreadyLinked
    vm.expectRevert(IGaugeManager.TargetAlreadyLinked.selector);
    _gaugeManager.createGauge(_defaultRequest());
  }

  function test_WhenTheTargetHasNoLinkedGauge(
    address _requestCreator,
    bool _activate,
    bytes memory _factoryData
  ) external whenTheCallerIsARegisteredModule whenTheGaugeFactoryIsApproved {
    _requestCreator = _boundNotEq(_requestCreator, _module);

    _mockTargetLinks();
    _mockTargetToGauge(address(0));

    IGaugeManager.GaugeCreationRequest memory _request = _defaultRequest();
    _request.creator = _requestCreator;
    _request.activate = _activate;
    _request.factoryData = _factoryData;

    // it should deploy through the requested gauge factory
    _mockAndExpect(
      _gaugeFactory,
      abi.encodeCall(IGaugeFactory.createGauge, (_target, _factoryData)),
      abi.encode(_gauge, _votingRewardsManager)
    );

    // it should report the gauge to the factory registry
    _mockAndExpect(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.registerGauge, (_gauge, _gaugeFactory, _votingRewardsManager, _target)),
      ''
    );

    // it should register the gauge on the leaf voter with the activation flag
    _mockAndExpect(_leafVoter, abi.encodeCall(ILeafVoter.registerGauge, (_gauge, _activate)), '');

    // it should emit GaugeCreated with the module and creator fields
    vm.expectEmit(address(_gaugeManager));
    emit IGaugeManager.GaugeCreated({
      _target: _target,
      _gauge: _gauge,
      _module: _module,
      _gaugeFactory: _gaugeFactory,
      _votingRewardsManager: _votingRewardsManager,
      _creator: _requestCreator,
      _activated: _activate
    });

    address _createdGauge = _gaugeManager.createGauge(_request);

    // it should return the deployed gauge
    assertEq(_createdGauge, _gauge);

    // it should record the caller as the gauge module
    assertEq(_gaugeManager.moduleForGauge(_gauge), _module);
  }

  function test_RevertWhen_TheLeafVoterRegistrationReverts()
    external
    whenTheCallerIsARegisteredModule
    whenTheGaugeFactoryIsApproved
  {
    _mockTargetLinks();
    _mockTargetToGauge(address(0));

    IGaugeManager.GaugeCreationRequest memory _request = _defaultRequest();
    vm.mockCall(
      _gaugeFactory,
      abi.encodeCall(IGaugeFactory.createGauge, (_target, _request.factoryData)),
      abi.encode(_gauge, _votingRewardsManager)
    );
    vm.mockCall(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.registerGauge, (_gauge, _gaugeFactory, _votingRewardsManager, _target)),
      ''
    );

    bytes memory _revertData = 'leaf voter reverted';
    vm.mockCallRevert(_leafVoter, abi.encodeCall(ILeafVoter.registerGauge, (_gauge, _request.activate)), _revertData);

    // it should revert
    vm.expectRevert(_revertData);
    _gaugeManager.createGauge(_request);
  }

  function test_WhenTheGaugeFactoryReentersCreateGauge()
    external
    whenTheCallerIsARegisteredModule
    whenTheGaugeFactoryIsApproved
  {
    address _reentrantFactory = address(new ReentrantGaugeFactory(_gaugeManager));

    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.isGaugeFactoryApproved, (_reentrantFactory)), abi.encode(true)
    );
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(_targetFactory)
    );
    vm.mockCall(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.gaugeFactoryToTargetFactory, (_reentrantFactory)),
      abi.encode(_targetFactory)
    );
    _mockTargetToGauge(address(0));

    IGaugeManager.GaugeCreationRequest memory _request = _defaultRequest();
    _request.gaugeFactory = _reentrantFactory;

    // it should revert with ReentrancyGuardReentrantCall
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _gaugeManager.createGauge(_request);
  }

  /// @dev Grants the module admin role on the mocked leaf voter and registers the module.
  function _registerModule(address _newModule) internal {
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _moduleAdmin)), abi.encode(true)
    );
    vm.prank(_moduleAdmin);
    _gaugeManager.registerModule(_newModule);
  }

  /// @dev Mocks the target and gauge factory links so both resolve to the same target factory.
  function _mockTargetLinks() internal {
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(_targetFactory)
    );
    vm.mockCall(
      _factoryRegistry,
      abi.encodeCall(IFactoryRegistry.gaugeFactoryToTargetFactory, (_gaugeFactory)),
      abi.encode(_targetFactory)
    );
  }

  /// @dev Mocks the gauge linked to the target on the factory registry.
  function _mockTargetToGauge(address _linkedGauge) internal {
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToGauge, (_target)), abi.encode(_linkedGauge));
  }

  function _defaultRequest() internal view returns (IGaugeManager.GaugeCreationRequest memory _request) {
    _request = IGaugeManager.GaugeCreationRequest({
      creator: _creator, gaugeFactory: _gaugeFactory, target: _target, factoryData: '', activate: false
    });
  }
}

/// @dev Gauge factory stub that reenters GaugeManager.createGauge from its creation hook.
contract ReentrantGaugeFactory {
  GaugeManager internal immutable _GAUGE_MANAGER;

  constructor(GaugeManager _gaugeManager) {
    _GAUGE_MANAGER = _gaugeManager;
  }

  function createGauge(address _target, bytes calldata) external returns (address _gauge, address _rewards) {
    IGaugeManager.GaugeCreationRequest memory _request = IGaugeManager.GaugeCreationRequest({
      creator: address(this), gaugeFactory: address(this), target: _target, factoryData: '', activate: false
    });
    _GAUGE_MANAGER.createGauge(_request);
    return (address(0), address(0));
  }
}
