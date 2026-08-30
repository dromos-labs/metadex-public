// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IDefaultGaugeCreationModule} from 'V3/interfaces/gauge-creation/IDefaultGaugeCreationModule.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {DefaultGaugeCreationModule} from 'V3/gauge-creation/DefaultGaugeCreationModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Unit tests for DefaultGaugeCreationModule createGauge
contract UnitDefaultGaugeCreationModuleCreateGauge is TestHelpers {
  address internal _gaugeManager = makeAddr('_gaugeManager');
  address internal _factoryRegistry = makeAddr('_factoryRegistry');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _tokenRegistry = makeAddr('_tokenRegistry');
  address internal _moduleAdmin = makeAddr('_moduleAdmin');
  address internal _target = makeAddr('_target');
  address internal _poolFactory = makeAddr('_poolFactory');
  address internal _gaugeFactory = makeAddr('_gaugeFactory');
  address internal _token0 = makeAddr('_token0');
  address internal _token1 = makeAddr('_token1');
  address internal _gauge = makeAddr('_gauge');

  DefaultGaugeCreationModule internal _module;

  function setUp() public virtual {
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_tokenRegistry));
    _module = new DefaultGaugeCreationModule(_leafVoter);
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _moduleAdmin)), abi.encode(true)
    );
    vm.prank(_moduleAdmin);
    _module.addAllowedGaugeFactory(_gaugeFactory);
  }

  /// @notice Reverts when the gauge factory is not on the allowlist
  function test_WhenTheGaugeFactoryIsNotAllowed(address _caller, address _otherFactory) external {
    _assumeFuzzable(_caller);
    _otherFactory = _boundNotEq(_otherFactory, _gaugeFactory);

    // it should revert with GaugeFactoryNotAllowed
    vm.expectRevert(IDefaultGaugeCreationModule.GaugeFactoryNotAllowed.selector);
    vm.prank(_caller);
    _module.createGauge(_target, _otherFactory);
  }

  /// @notice Reverts when the factory registry has no factory recorded for the target
  function test_WhenTheTargetHasNoRecordedFactory(address _caller) external {
    _assumeFuzzable(_caller);
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(address(0)));

    // it should revert with NotAPool
    vm.expectRevert(IDefaultGaugeCreationModule.NotAPool.selector);
    vm.prank(_caller);
    _module.createGauge(_target, _gaugeFactory);
  }

  /// @notice Reverts when the recorded factory denies the target is a pool
  function test_WhenTheRecordedFactoryDoesNotReportTheTargetAsAPool(address _caller) external {
    _assumeFuzzable(_caller);
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(_poolFactory));
    vm.mockCall(_poolFactory, abi.encodeCall(IPoolFactory.isPool, (_target)), abi.encode(false));

    // it should revert with NotAPool
    vm.expectRevert(IDefaultGaugeCreationModule.NotAPool.selector);
    vm.prank(_caller);
    _module.createGauge(_target, _gaugeFactory);
  }

  /// @dev Registers the target as a pool of the pool factory and mocks its tokens
  modifier whenTheTargetIsARecordedPool() {
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.targetToFactory, (_target)), abi.encode(_poolFactory));
    vm.mockCall(_poolFactory, abi.encodeCall(IPoolFactory.isPool, (_target)), abi.encode(true));
    vm.mockCall(_target, abi.encodeCall(IPool.token0, ()), abi.encode(_token0));
    vm.mockCall(_target, abi.encodeCall(IPool.token1, ()), abi.encode(_token1));
    _;
  }

  /// @notice Reverts when neither pool token is a listed base asset
  function test_WhenNeitherPoolTokenIsAListedBaseAsset(address _caller) external whenTheTargetIsARecordedPool {
    _assumeFuzzable(_caller);

    // it should revert with NoListedBaseAsset
    vm.expectRevert(IDefaultGaugeCreationModule.NoListedBaseAsset.selector);
    vm.prank(_caller);
    _module.createGauge(_target, _gaugeFactory);
  }

  /// @dev Lists token0 as a base asset on the module
  modifier whenAtLeastOnePoolTokenIsAListedBaseAsset() {
    vm.prank(_moduleAdmin);
    _module.addListedBaseAsset(_token0);
    _;
  }

  /// @notice Creates an activated gauge crediting the caller when both pool tokens are registry listed
  function test_WhenBothPoolTokensAreListedInTheTokenRegistry(address _caller)
    external
    whenTheTargetIsARecordedPool
    whenAtLeastOnePoolTokenIsAListedBaseAsset
  {
    _assumeFuzzable(_caller);
    _mockListings(true, true);
    IGaugeManager.GaugeCreationRequest memory _request = _expectedRequest({_creator: _caller, _activate: true});

    // it should request an activated registration crediting the caller with empty factory data
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.createGauge, (_request)), abi.encode(_gauge));

    vm.prank(_caller);
    address _createdGauge = _module.createGauge(_target, _gaugeFactory);

    // it should return the created gauge
    assertEq(_createdGauge, _gauge);
  }

  /// @notice Creates an inactive gauge when the second pool token lacks a registry listing
  function test_WhenTheSecondPoolTokenIsNotListedInTheTokenRegistry(address _caller)
    external
    whenTheTargetIsARecordedPool
    whenAtLeastOnePoolTokenIsAListedBaseAsset
  {
    _assumeFuzzable(_caller);
    _mockListings(true, false);

    // it should request an inactive registration
    IGaugeManager.GaugeCreationRequest memory _request = _expectedRequest(_caller, false);
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.createGauge, (_request)), abi.encode(_gauge));

    vm.prank(_caller);
    address _createdGauge = _module.createGauge(_target, _gaugeFactory);

    // it should still create the gauge
    assertEq(_createdGauge, _gauge);
  }

  /// @notice Creates an inactive gauge when the first pool token lacks a registry listing
  function test_WhenTheFirstPoolTokenIsNotListedInTheTokenRegistry(address _caller)
    external
    whenTheTargetIsARecordedPool
    whenAtLeastOnePoolTokenIsAListedBaseAsset
  {
    _assumeFuzzable(_caller);
    _mockListings(false, true);

    // it should request an inactive registration
    IGaugeManager.GaugeCreationRequest memory _request = _expectedRequest(_caller, false);
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.createGauge, (_request)), abi.encode(_gauge));

    vm.prank(_caller);
    address _createdGauge = _module.createGauge(_target, _gaugeFactory);

    // it should still create the gauge
    assertEq(_createdGauge, _gauge);
  }

  /// @notice Creates the gauge when only the second pool token is a listed base asset
  function test_WhenOnlyTheSecondPoolTokenIsAListedBaseAsset(address _caller) external whenTheTargetIsARecordedPool {
    _assumeFuzzable(_caller);
    vm.prank(_moduleAdmin);
    _module.addListedBaseAsset(_token1);
    _mockListings(true, true);

    // it should create the gauge
    IGaugeManager.GaugeCreationRequest memory _request = _expectedRequest(_caller, true);
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.createGauge, (_request)), abi.encode(_gauge));

    vm.prank(_caller);
    address _createdGauge = _module.createGauge(_target, _gaugeFactory);

    // it should return the created gauge
    assertEq(_createdGauge, _gauge);
  }

  /// @dev Mocks the token registry listing answer for both pool tokens
  function _mockListings(bool _token0Listed, bool _token1Listed) internal {
    vm.mockCall(_tokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token0)), abi.encode(_token0Listed));
    vm.mockCall(_tokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token1)), abi.encode(_token1Listed));
  }

  /// @dev Builds the gauge creation request the module is expected to send
  function _expectedRequest(
    address _creator,
    bool _activate
  ) internal view returns (IGaugeManager.GaugeCreationRequest memory _request) {
    _request = IGaugeManager.GaugeCreationRequest({
      creator: _creator, gaugeFactory: _gaugeFactory, target: _target, factoryData: '', activate: _activate
    });
  }
}
