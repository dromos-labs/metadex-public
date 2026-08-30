// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Vm} from 'forge-std/Test.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IDefaultGaugeCreationModule} from 'V3/interfaces/gauge-creation/IDefaultGaugeCreationModule.sol';
import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {DefaultGaugeCreationModule} from 'V3/gauge-creation/DefaultGaugeCreationModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitDefaultGaugeCreationModule is TestHelpers {
  address internal _gaugeManager = makeAddr('_gaugeManager');
  address internal _factoryRegistry = makeAddr('_factoryRegistry');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _tokenRegistry = makeAddr('_tokenRegistry');
  address internal _moduleAdmin = makeAddr('_moduleAdmin');
  address internal _gauge = makeAddr('_gauge');
  address internal _target = makeAddr('_target');
  address internal _token0 = makeAddr('_token0');
  address internal _token1 = makeAddr('_token1');

  DefaultGaugeCreationModule internal _module;

  function setUp() public virtual {
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_tokenRegistry));
    _module = new DefaultGaugeCreationModule(_leafVoter);
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _moduleAdmin)), abi.encode(true)
    );
  }

  function test_ConstructorWhenTheLeafVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    new DefaultGaugeCreationModule(address(0));
  }

  function test_ConstructorWhenTheLeafVoterReportsAZeroFactoryRegistry(
    address _fuzzedLeafVoter,
    address _fuzzedGaugeManager
  ) external {
    _assumeFuzzable(_fuzzedLeafVoter);
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_fuzzedGaugeManager));
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(address(0)));

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    new DefaultGaugeCreationModule(_fuzzedLeafVoter);
  }

  function test_ConstructorWhenTheLeafVoterReportsAZeroGaugeManager(
    address _fuzzedLeafVoter,
    address _fuzzedFactoryRegistry
  ) external {
    _assumeFuzzable(_fuzzedLeafVoter);
    vm.assume(_fuzzedFactoryRegistry != address(0));
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(address(0)));
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_fuzzedFactoryRegistry));

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    new DefaultGaugeCreationModule(_fuzzedLeafVoter);
  }

  function test_ConstructorWhenTheLeafVoterReportsNonzeroLinks(
    address _fuzzedLeafVoter,
    address _fuzzedFactoryRegistry,
    address _fuzzedGaugeManager
  ) external {
    _assumeFuzzable(_fuzzedLeafVoter);
    vm.assume(_fuzzedFactoryRegistry != address(0));
    vm.assume(_fuzzedGaugeManager != address(0));
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_fuzzedGaugeManager));
    vm.mockCall(_fuzzedLeafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_fuzzedFactoryRegistry));

    DefaultGaugeCreationModule _deployedModule = new DefaultGaugeCreationModule(_fuzzedLeafVoter);

    // it should set the leaf voter
    assertEq(address(_deployedModule.LEAF_VOTER()), _fuzzedLeafVoter);

    // it should set the factory registry reported by the leaf voter
    assertEq(address(_deployedModule.FACTORY_REGISTRY()), _fuzzedFactoryRegistry);

    // it should set the gauge manager reported by the leaf voter
    assertEq(address(_deployedModule.GAUGE_MANAGER()), _fuzzedGaugeManager);
  }

  function test_ActivateWhenTheFactoryRegistryRecordsNoTargetForTheGauge() external {
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.gaugeToTarget, (_gauge)), abi.encode(address(0)));

    // it should revert with GaugeNotRegistered
    vm.expectRevert(IDefaultGaugeCreationModule.GaugeNotRegistered.selector);
    _module.activate(_gauge);
  }

  modifier whenTheGaugeHasARecordedTarget() {
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.gaugeToTarget, (_gauge)), abi.encode(_target));
    vm.mockCall(_target, abi.encodeCall(IPool.token0, ()), abi.encode(_token0));
    vm.mockCall(_target, abi.encodeCall(IPool.token1, ()), abi.encode(_token1));
    _;
  }

  function test_ActivateWhenTheFirstPoolTokenIsNotListed() external whenTheGaugeHasARecordedTarget {
    vm.mockCall(_tokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token0)), abi.encode(false));

    // it should revert with TokenNotListed carrying the first token
    vm.expectRevert(abi.encodeWithSelector(IDefaultGaugeCreationModule.TokenNotListed.selector, _token0));
    _module.activate(_gauge);
  }

  function test_ActivateWhenTheSecondPoolTokenIsNotListed() external whenTheGaugeHasARecordedTarget {
    vm.mockCall(_tokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token0)), abi.encode(true));
    vm.mockCall(_tokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token1)), abi.encode(false));

    // it should revert with TokenNotListed carrying the second token
    vm.expectRevert(abi.encodeWithSelector(IDefaultGaugeCreationModule.TokenNotListed.selector, _token1));
    _module.activate(_gauge);
  }

  function test_ActivateWhenBothPoolTokensAreListed(
    address _caller,
    address _newTokenRegistry
  ) external whenTheGaugeHasARecordedTarget {
    _assumeFuzzable(_caller);
    _newTokenRegistry = _boundNotEq(_newTokenRegistry, _tokenRegistry);
    _assumeFuzzable(_newTokenRegistry);

    // it should read the live token registry pointer from the factory registry
    vm.mockCall(_factoryRegistry, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_newTokenRegistry));
    _mockAndExpect(_newTokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token0)), abi.encode(true));
    _mockAndExpect(_newTokenRegistry, abi.encodeCall(ITokenRegistry.isListed, (_token1)), abi.encode(true));

    // it should activate the gauge through the gauge manager
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.activateGauge, (_gauge)), '');

    // it should allow any caller
    vm.prank(_caller);
    _module.activate(_gauge);
  }

  function test_AddListedBaseAssetWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _token
  ) external {
    _assumeFuzzable(_caller);
    _mockNotModuleAdmin(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IDefaultGaugeCreationModule.NotAuthorized.selector);
    _module.addListedBaseAsset(_token);
  }

  modifier whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter() {
    vm.startPrank(_moduleAdmin);
    _;
    vm.stopPrank();
  }

  function test_AddListedBaseAssetWhenTheTokenIsTheZeroAddress()
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    _module.addListedBaseAsset(address(0));
  }

  function test_AddListedBaseAssetWhenTheTokenIsNotInTheSet(address _token)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _assumeFuzzable(_token);

    // it should emit ListedBaseAssetAdded
    vm.expectEmit(address(_module));
    emit IDefaultGaugeCreationModule.ListedBaseAssetAdded(_token);
    _module.addListedBaseAsset(_token);

    // it should add the token to the set
    assertTrue(_module.isListedBaseAsset(_token));
    address[] memory _tokens = _module.listedBaseAssets();
    assertEq(_tokens.length, 1);
    assertEq(_tokens[0], _token);
  }

  function test_AddListedBaseAssetWhenTheTokenIsAlreadyInTheSet(address _token)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _assumeFuzzable(_token);
    _module.addListedBaseAsset(_token);

    // it should succeed
    vm.recordLogs();
    _module.addListedBaseAsset(_token);

    // it should keep the token in the set
    assertTrue(_module.isListedBaseAsset(_token));
    address[] memory _tokens = _module.listedBaseAssets();
    assertEq(_tokens.length, 1);
    assertEq(_tokens[0], _token);

    // it should not emit ListedBaseAssetAdded
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertNotEq(_logs[_i].topics[0], IDefaultGaugeCreationModule.ListedBaseAssetAdded.selector);
    }
  }

  function test_RemoveListedBaseAssetWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _token
  ) external {
    _assumeFuzzable(_caller);
    _mockNotModuleAdmin(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IDefaultGaugeCreationModule.NotAuthorized.selector);
    _module.removeListedBaseAsset(_token);
  }

  function test_RemoveListedBaseAssetWhenTheTokenIsInTheSet(address _token)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _assumeFuzzable(_token);
    _module.addListedBaseAsset(_token);

    // it should emit ListedBaseAssetRemoved
    vm.expectEmit(address(_module));
    emit IDefaultGaugeCreationModule.ListedBaseAssetRemoved(_token);
    _module.removeListedBaseAsset(_token);

    // it should remove the token from the set
    assertFalse(_module.isListedBaseAsset(_token));
    assertEq(_module.listedBaseAssets().length, 0);
  }

  function test_RemoveListedBaseAssetWhenTheTokenIsNotInTheSet(address _token)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _assumeFuzzable(_token);

    // it should succeed
    vm.recordLogs();
    _module.removeListedBaseAsset(_token);

    // it should leave the set unchanged
    assertFalse(_module.isListedBaseAsset(_token));
    assertEq(_module.listedBaseAssets().length, 0);

    // it should not emit ListedBaseAssetRemoved
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertNotEq(_logs[_i].topics[0], IDefaultGaugeCreationModule.ListedBaseAssetRemoved.selector);
    }
  }

  function test_AddAllowedGaugeFactoryWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _gaugeFactory
  ) external {
    _assumeFuzzable(_caller);
    _mockNotModuleAdmin(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IDefaultGaugeCreationModule.NotAuthorized.selector);
    _module.addAllowedGaugeFactory(_gaugeFactory);
  }

  function test_AddAllowedGaugeFactoryWhenTheGaugeFactoryIsTheZeroAddress()
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    _module.addAllowedGaugeFactory(address(0));
  }

  function test_AddAllowedGaugeFactoryWhenTheGaugeFactoryIsAlreadyAllowed(address _gaugeFactory)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _gaugeFactory = _excludingAddressZero(_gaugeFactory);
    _module.addAllowedGaugeFactory(_gaugeFactory);

    // it should revert with GaugeFactoryAlreadyAllowed
    vm.expectRevert(IDefaultGaugeCreationModule.GaugeFactoryAlreadyAllowed.selector);
    _module.addAllowedGaugeFactory(_gaugeFactory);
  }

  function test_AddAllowedGaugeFactoryWhenTheGaugeFactoryIsNotYetAllowed(address _gaugeFactory)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _gaugeFactory = _excludingAddressZero(_gaugeFactory);

    // it should emit GaugeFactoryAllowed
    vm.expectEmit(address(_module));
    emit IDefaultGaugeCreationModule.GaugeFactoryAllowed(_gaugeFactory);
    _module.addAllowedGaugeFactory(_gaugeFactory);

    // it should add the gauge factory to the set
    assertTrue(_module.isAllowedGaugeFactory(_gaugeFactory));

    // it should expose the gauge factory through the set views
    address[] memory _gaugeFactories = _module.allowedGaugeFactories();
    assertEq(_gaugeFactories.length, 1);
    assertEq(_gaugeFactories[0], _gaugeFactory);
  }

  function test_RemoveAllowedGaugeFactoryWhenTheCallerDoesNotHoldTheModuleAdminRoleOnTheLeafVoter(
    address _caller,
    address _gaugeFactory
  ) external {
    _assumeFuzzable(_caller);
    _mockNotModuleAdmin(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IDefaultGaugeCreationModule.NotAuthorized.selector);
    _module.removeAllowedGaugeFactory(_gaugeFactory);
  }

  function test_RemoveAllowedGaugeFactoryWhenTheGaugeFactoryIsNotInTheSet(address _gaugeFactory)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    // it should revert with GaugeFactoryNotAllowed
    vm.expectRevert(IDefaultGaugeCreationModule.GaugeFactoryNotAllowed.selector);
    _module.removeAllowedGaugeFactory(_gaugeFactory);
  }

  function test_RemoveAllowedGaugeFactoryWhenTheGaugeFactoryIsInTheSet(address _gaugeFactory)
    external
    whenTheCallerHoldsTheModuleAdminRoleOnTheLeafVoter
  {
    _gaugeFactory = _excludingAddressZero(_gaugeFactory);
    _module.addAllowedGaugeFactory(_gaugeFactory);

    // it should emit GaugeFactoryDisallowed
    vm.expectEmit(address(_module));
    emit IDefaultGaugeCreationModule.GaugeFactoryDisallowed(_gaugeFactory);
    _module.removeAllowedGaugeFactory(_gaugeFactory);

    // it should remove the gauge factory from the set
    assertFalse(_module.isAllowedGaugeFactory(_gaugeFactory));

    // it should hide the gauge factory from the set views
    assertEq(_module.allowedGaugeFactories().length, 0);
  }

  /// @dev Mocks the leaf voter to deny the module admin role for the caller.
  function _mockNotModuleAdmin(address _caller) internal {
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.MODULE_ADMIN_ROLE, _caller)), abi.encode(false)
    );
  }
}
