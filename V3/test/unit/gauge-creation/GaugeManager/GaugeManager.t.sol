// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {GaugeManager} from 'V3/gauge-creation/GaugeManager.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitGaugeManager is TestHelpers {
  /// @dev Storage slot of moduleForGauge, after the two module set slots.
  uint256 internal constant _MODULE_FOR_GAUGE_SLOT = 2;

  address internal _factoryRegistry = makeAddr('_factoryRegistry');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _moduleAdmin = makeAddr('_moduleAdmin');
  address internal _governor = makeAddr('_governor');
  address internal _module = makeAddr('_module');

  GaugeManager internal _gaugeManager;

  function setUp() public {
    _gaugeManager = new GaugeManager(_factoryRegistry, _leafVoter);
  }

  function test_ConstructorWhenTheFactoryRegistryIsTheZeroAddress(address _newLeafVoter) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeManager.ZeroAddress.selector);
    new GaugeManager(address(0), _newLeafVoter);
  }

  function test_ConstructorWhenTheLeafVoterIsTheZeroAddress(address _newFactoryRegistry) external {
    _newFactoryRegistry = _excludingAddressZero(_newFactoryRegistry);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeManager.ZeroAddress.selector);
    new GaugeManager(_newFactoryRegistry, address(0));
  }

  function test_ConstructorWhenNoAddressIsZero(address _newFactoryRegistry, address _newLeafVoter) external {
    _assumeFuzzable(_newFactoryRegistry);
    _assumeFuzzable(_newLeafVoter);

    GaugeManager _newGaugeManager = new GaugeManager(_newFactoryRegistry, _newLeafVoter);

    // it should set the factory registry
    assertEq(address(_newGaugeManager.FACTORY_REGISTRY()), _newFactoryRegistry);

    // it should set the leaf voter
    assertEq(address(_newGaugeManager.LEAF_VOTER()), _newLeafVoter);
  }

  function test_ActivateGaugeWhenTheCallerHoldsTheGovernanceRoleOnTheLeafVoter(
    address _gauge,
    address _otherModule
  ) external {
    _assumeFuzzable(_gauge);
    _otherModule = _boundNotEq(_otherModule, _governor);
    _seedModuleForGauge(_gauge, _otherModule);
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _governor)), abi.encode(true)
    );

    // it should activate the gauge on the leaf voter regardless of the recorded module
    _mockAndExpect(_leafVoter, abi.encodeCall(ILeafVoter.activateGauge, (_gauge)), '');
    vm.prank(_governor);
    _gaugeManager.activateGauge(_gauge);
  }

  modifier whenTheCallerDoesNotHoldTheGovernanceRoleOnTheLeafVoter() {
    _;
  }

  function test_ActivateGaugeWhenTheCallerIsNotARegisteredModule(
    address _caller,
    address _gauge
  ) external whenTheCallerDoesNotHoldTheGovernanceRoleOnTheLeafVoter {
    _assumeFuzzable(_caller);
    _mockNotGovernor(_caller);

    vm.prank(_caller);
    // it should revert with ModuleNotRegistered
    vm.expectRevert(IGaugeManager.ModuleNotRegistered.selector);
    _gaugeManager.activateGauge(_gauge);
  }

  modifier whenTheCallerIsARegisteredModule() {
    _registerModule(_module);
    _mockNotGovernor(_module);
    vm.startPrank(_module);
    _;
    vm.stopPrank();
  }

  function test_ActivateGaugeWhenTheCallerIsNotTheRecordedModuleForTheGauge(
    address _gauge,
    address _otherModule
  ) external whenTheCallerDoesNotHoldTheGovernanceRoleOnTheLeafVoter whenTheCallerIsARegisteredModule {
    _otherModule = _boundNotEq(_otherModule, _module);
    _seedModuleForGauge(_gauge, _otherModule);

    // it should revert with WrongModule
    vm.expectRevert(IGaugeManager.WrongModule.selector);
    _gaugeManager.activateGauge(_gauge);
  }

  function test_ActivateGaugeWhenTheCallerIsTheRecordedModuleForTheGauge(address _gauge)
    external
    whenTheCallerDoesNotHoldTheGovernanceRoleOnTheLeafVoter
    whenTheCallerIsARegisteredModule
  {
    _assumeFuzzable(_gauge);
    _seedModuleForGauge(_gauge, _module);

    // it should activate the gauge on the leaf voter
    _mockAndExpect(_leafVoter, abi.encodeCall(ILeafVoter.activateGauge, (_gauge)), '');
    _gaugeManager.activateGauge(_gauge);
  }

  function test_RegisterModuleWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _newModule
  ) external {
    _assumeFuzzable(_caller);
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _caller)), abi.encode(false)
    );

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeManager.NotAuthorized.selector);
    _gaugeManager.registerModule(_newModule);
  }

  modifier whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter() {
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _moduleAdmin)), abi.encode(true)
    );
    vm.startPrank(_moduleAdmin);
    _;
    vm.stopPrank();
  }

  function test_RegisterModuleWhenTheModuleIsTheZeroAddress()
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeManager.ZeroAddress.selector);
    _gaugeManager.registerModule(address(0));
  }

  function test_RegisterModuleWhenTheModuleIsAlreadyRegistered(address _newModule)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _newModule = _excludingAddressZero(_newModule);
    _gaugeManager.registerModule(_newModule);

    // it should revert with ModuleAlreadyRegistered
    vm.expectRevert(IGaugeManager.ModuleAlreadyRegistered.selector);
    _gaugeManager.registerModule(_newModule);
  }

  function test_RegisterModuleWhenTheModuleIsNotRegistered(address _newModule)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _newModule = _excludingAddressZero(_newModule);

    // it should emit ModuleRegistered
    vm.expectEmit(address(_gaugeManager));
    emit IGaugeManager.ModuleRegistered(_newModule);
    _gaugeManager.registerModule(_newModule);

    // it should add the module to the set
    assertTrue(_gaugeManager.isModule(_newModule));

    // it should expose the module through the set views
    address[] memory _moduleList = _gaugeManager.modules();
    assertEq(_moduleList.length, 1);
    assertEq(_moduleList[0], _newModule);
  }

  function test_DeregisterModuleWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _newModule
  ) external {
    _assumeFuzzable(_caller);
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _caller)), abi.encode(false)
    );

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeManager.NotAuthorized.selector);
    _gaugeManager.deregisterModule(_newModule);
  }

  function test_DeregisterModuleWhenTheModuleIsNotRegistered(address _newModule)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    // it should revert with ModuleNotRegistered
    vm.expectRevert(IGaugeManager.ModuleNotRegistered.selector);
    _gaugeManager.deregisterModule(_newModule);
  }

  function test_DeregisterModuleWhenTheModuleIsRegistered(address _newModule)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _newModule = _excludingAddressZero(_newModule);
    _gaugeManager.registerModule(_newModule);

    // it should emit ModuleDeregistered
    vm.expectEmit(address(_gaugeManager));
    emit IGaugeManager.ModuleDeregistered(_newModule);
    _gaugeManager.deregisterModule(_newModule);

    // it should remove the module from the set
    assertFalse(_gaugeManager.isModule(_newModule));

    // it should hide the module from the set views
    assertEq(_gaugeManager.modules().length, 0);
  }

  /// @dev Grants the module admin role on the mocked leaf voter and registers the module.
  function _registerModule(address _newModule) internal {
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _moduleAdmin)), abi.encode(true)
    );
    vm.prank(_moduleAdmin);
    _gaugeManager.registerModule(_newModule);
  }

  /// @dev Mocks the leaf voter to deny the governance role for the caller.
  function _mockNotGovernor(address _caller) internal {
    vm.mockCall(_leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _caller)), abi.encode(false));
  }

  /// @dev Writes moduleForGauge directly so no createGauge path runs.
  function _seedModuleForGauge(address _gauge, address _owningModule) internal {
    vm.store(
      address(_gaugeManager),
      keccak256(abi.encode(_gauge, _MODULE_FOR_GAUGE_SLOT)),
      bytes32(uint256(uint160(_owningModule)))
    );
    assertEq(_gaugeManager.moduleForGauge(_gauge), _owningModule);
  }
}
