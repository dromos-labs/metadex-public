// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {StdStorage, Vm, stdStorage} from 'forge-std/Test.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {FactoryRegistry} from 'V3/factories/FactoryRegistry.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitFactoryRegistry is TestHelpers {
  using stdStorage for StdStorage;

  // Storage slots from `forge inspect FactoryRegistry storage-layout`. Each
  // EnumerableSet.AddressSet spans two slots, the values array then the
  // positions mapping.
  uint256 internal constant _GAUGE_FACTORIES_SLOT = 3;
  uint256 internal constant _TARGET_FACTORIES_SLOT = 5;
  uint256 internal constant _META_ROUTERS_SLOT = 7;
  uint256 internal constant _FACTORY_TO_TARGETS_SLOT = 13;
  uint256 internal constant _FACTORY_TO_GAUGES_SLOT = 14;

  address internal _targetFactoryAdmin = makeAddr('_targetFactoryAdmin');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _gaugeManager = makeAddr('_gaugeManager');
  address internal _gaugeFactory = makeAddr('_gaugeFactory');
  address internal _targetFactory = makeAddr('_targetFactory');
  address internal _gauge = makeAddr('_gauge');
  address internal _target = makeAddr('_target');
  address internal _rewards = makeAddr('_rewards');
  address internal _tokenRegistry = makeAddr('_tokenRegistry');
  address internal _metaRouter = makeAddr('_metaRouter');

  FactoryRegistry internal _factoryRegistry;

  function setUp() public virtual {
    _factoryRegistry = new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});
    // seed the leaf voter through storage so a bug in the constructor or
    // setLeafVoter cannot mask the tests of the functions gated on it
    stdstore.target(address(_factoryRegistry)).sig('leafVoter()').checked_write(_leafVoter);
  }

  /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  modifier whenTheLeafVoterIsTheZeroAddress() {
    _;
  }

  function test_ConstructorWhenTheTargetFactoryAdminIsTheZeroAddress() external whenTheLeafVoterIsTheZeroAddress {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    new FactoryRegistry({_targetFactoryAdmin: address(0), _leafVoter: address(0)});
  }

  function test_ConstructorWhenTheTargetFactoryAdminIsNonZero(address _newTargetFactoryAdmin)
    external
    whenTheLeafVoterIsTheZeroAddress
  {
    _assumeFuzzable(_newTargetFactoryAdmin);

    // it should emit TargetFactoryAdminSet
    vm.expectEmit();
    emit IFactoryRegistry.TargetFactoryAdminSet(_newTargetFactoryAdmin);

    FactoryRegistry _newRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _newTargetFactoryAdmin, _leafVoter: address(0)});

    // it should set the target factory admin
    assertEq(_newRegistry.targetFactoryAdmin(), _newTargetFactoryAdmin);

    // it should leave the leaf voter unset
    assertEq(_newRegistry.leafVoter(), address(0));
  }

  modifier whenTheLeafVoterIsNonZero() {
    _;
  }

  function test_ConstructorWhenATargetFactoryAdminIsProvided(
    address _newTargetFactoryAdmin,
    address _newLeafVoter
  ) external whenTheLeafVoterIsNonZero {
    _assumeFuzzable(_newTargetFactoryAdmin);
    _assumeFuzzable(_newLeafVoter);

    // it should revert with TargetFactoryAdminNotAllowed
    vm.expectRevert(IFactoryRegistry.TargetFactoryAdminNotAllowed.selector);
    new FactoryRegistry({_targetFactoryAdmin: _newTargetFactoryAdmin, _leafVoter: _newLeafVoter});
  }

  function test_ConstructorWhenNoTargetFactoryAdminIsProvided(address _newLeafVoter)
    external
    whenTheLeafVoterIsNonZero
  {
    _assumeFuzzable(_newLeafVoter);

    // it should emit LeafVoterSet
    vm.expectEmit();
    emit IFactoryRegistry.LeafVoterSet(_newLeafVoter);

    FactoryRegistry _newRegistry = new FactoryRegistry({_targetFactoryAdmin: address(0), _leafVoter: _newLeafVoter});

    // it should set the leaf voter
    assertEq(_newRegistry.leafVoter(), _newLeafVoter);

    // it should leave the target factory admin unset
    assertEq(_newRegistry.targetFactoryAdmin(), address(0));
  }

  /*//////////////////////////////////////////////////////////////
                              BOOTSTRAP
  //////////////////////////////////////////////////////////////*/

  function test_SetLeafVoterWhenTheCallerIsNotTheTargetFactoryAdmin(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _targetFactoryAdmin);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.setLeafVoter(_leafVoter);
  }

  modifier whenTheCallerIsTheTargetFactoryAdmin() {
    vm.startPrank(_targetFactoryAdmin);
    _;
    vm.stopPrank();
  }

  function test_SetLeafVoterWhenTheLeafVoterIsTheZeroAddress() external whenTheCallerIsTheTargetFactoryAdmin {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.setLeafVoter(address(0));
  }

  function test_SetLeafVoterWhenTheLeafVoterIsAlreadySet() external whenTheCallerIsTheTargetFactoryAdmin {
    // it should revert with LeafVoterAlreadySet
    vm.expectRevert(IFactoryRegistry.LeafVoterAlreadySet.selector);
    _factoryRegistry.setLeafVoter(_leafVoter);
  }

  function test_SetLeafVoterWhenTheLeafVoterIsUnset(address _newLeafVoter)
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    _assumeFuzzable(_newLeafVoter);
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should emit LeafVoterSet
    _expectEmit(address(_freshRegistry));
    emit IFactoryRegistry.LeafVoterSet(_newLeafVoter);

    // it should emit TargetFactoryAdminSet with the zero address
    _expectEmit(address(_freshRegistry));
    emit IFactoryRegistry.TargetFactoryAdminSet(address(0));

    _freshRegistry.setLeafVoter(_newLeafVoter);

    // it should write the leaf voter
    assertEq(_freshRegistry.leafVoter(), _newLeafVoter);

    // it should clear the target factory admin
    assertEq(_freshRegistry.targetFactoryAdmin(), address(0));
  }

  function test_SetTargetFactoryAdminWhenTheCallerIsNotTheTargetFactoryAdmin(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _targetFactoryAdmin);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.setTargetFactoryAdmin(_caller);
  }

  function test_SetTargetFactoryAdminWhenTheNewTargetFactoryAdminIsTheZeroAddress()
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.setTargetFactoryAdmin(address(0));
  }

  function test_SetTargetFactoryAdminWhenTheNewTargetFactoryAdminIsNonZero(address _newTargetFactoryAdmin)
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    _assumeFuzzable(_newTargetFactoryAdmin);

    // it should emit TargetFactoryAdminSet
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TargetFactoryAdminSet(_newTargetFactoryAdmin);

    _factoryRegistry.setTargetFactoryAdmin(_newTargetFactoryAdmin);

    // it should write the target factory admin
    assertEq(_factoryRegistry.targetFactoryAdmin(), _newTargetFactoryAdmin);
  }

  /*//////////////////////////////////////////////////////////////
                           APPROVAL CHECKS
  //////////////////////////////////////////////////////////////*/

  function test_IsGaugeFactoryApprovedWhenTheGaugeFactoryApprovalSetIsEmpty() external view {
    // it should return false
    assertFalse(_factoryRegistry.isGaugeFactoryApproved(_gaugeFactory));
  }

  function test_IsGaugeFactoryApprovedWhenTheGaugeFactoryIsNotInThePopulatedApprovalSet(address _otherFactory)
    external
  {
    _assumeFuzzable(_otherFactory);
    vm.assume(_otherFactory != _gaugeFactory);
    _seedGaugeFactory(_gaugeFactory);

    // it should return false
    assertFalse(_factoryRegistry.isGaugeFactoryApproved(_otherFactory));
  }

  function test_IsGaugeFactoryApprovedWhenTheGaugeFactoryIsInTheApprovalSet() external {
    _seedGaugeFactory(_gaugeFactory);

    // it should return true
    assertTrue(_factoryRegistry.isGaugeFactoryApproved(_gaugeFactory));
  }

  function test_IsTargetFactoryApprovedWhenTheTargetFactoryApprovalSetIsEmpty() external view {
    // it should return false
    assertFalse(_factoryRegistry.isTargetFactoryApproved(_targetFactory));
  }

  function test_IsTargetFactoryApprovedWhenTheTargetFactoryIsNotInThePopulatedApprovalSet(address _otherFactory)
    external
  {
    _assumeFuzzable(_otherFactory);
    vm.assume(_otherFactory != _targetFactory);
    _seedTargetFactory(_targetFactory);

    // it should return false
    assertFalse(_factoryRegistry.isTargetFactoryApproved(_otherFactory));
  }

  function test_IsTargetFactoryApprovedWhenTheTargetFactoryIsInTheApprovalSet() external {
    _seedTargetFactory(_targetFactory);

    // it should return true
    assertTrue(_factoryRegistry.isTargetFactoryApproved(_targetFactory));
  }

  function test_IsMetaRouterApprovedWhenTheMetaRouterApprovalSetIsEmpty() external view {
    // it should return false
    assertFalse(_factoryRegistry.isMetaRouterApproved(_metaRouter));
  }

  function test_IsMetaRouterApprovedWhenTheMetaRouterIsNotInThePopulatedApprovalSet(address _otherRouter) external {
    _assumeFuzzable(_otherRouter);
    vm.assume(_otherRouter != _metaRouter);
    _seedMetaRouter(_metaRouter);

    // it should return false
    assertFalse(_factoryRegistry.isMetaRouterApproved(_otherRouter));
  }

  function test_IsMetaRouterApprovedWhenTheMetaRouterIsInTheApprovalSet() external {
    _seedMetaRouter(_metaRouter);

    // it should return true
    assertTrue(_factoryRegistry.isMetaRouterApproved(_metaRouter));
  }

  /*//////////////////////////////////////////////////////////////
                              SET VIEWS
  //////////////////////////////////////////////////////////////*/

  function test_GaugeFactoriesWhenTheGaugeFactoryApprovalSetIsEmpty() external view {
    // it should return an empty array
    assertEq(_factoryRegistry.gaugeFactories().length, 0);
  }

  function test_GaugeFactoriesWhenTheGaugeFactoryApprovalSetIsPopulated() external {
    address _secondGaugeFactory = makeAddr('_secondGaugeFactory');
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactory(_secondGaugeFactory);

    // it should return every registered gauge factory
    address[] memory _factories = _factoryRegistry.gaugeFactories();
    assertEq(_factories.length, 2);
    assertEq(_factories[0], _gaugeFactory);
    assertEq(_factories[1], _secondGaugeFactory);
  }

  function test_GaugeFactoriesLengthWhenTheGaugeFactoryApprovalSetIsEmpty() external view {
    // it should return zero
    assertEq(_factoryRegistry.gaugeFactoriesLength(), 0);
  }

  function test_GaugeFactoriesLengthWhenTheGaugeFactoryApprovalSetIsPopulated() external {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactory(makeAddr('_secondGaugeFactory'));

    // it should return the member count
    assertEq(_factoryRegistry.gaugeFactoriesLength(), 2);
  }

  function test_GaugeFactoriesAtWhenTheIndexIsOutOfRangeOfTheGaugeFactoryApprovalSet(uint256 _index) external {
    _index = bound(_index, 1, type(uint256).max);
    _seedGaugeFactory(_gaugeFactory);

    // it should return the zero address
    assertEq(_factoryRegistry.gaugeFactoriesAt(_index), address(0));
  }

  function test_GaugeFactoriesAtWhenTheIndexIsWithinRangeOfTheGaugeFactoryApprovalSet() external {
    address _secondGaugeFactory = makeAddr('_secondGaugeFactory');
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactory(_secondGaugeFactory);

    // it should return the member at the index
    assertEq(_factoryRegistry.gaugeFactoriesAt(0), _gaugeFactory);
    assertEq(_factoryRegistry.gaugeFactoriesAt(1), _secondGaugeFactory);
  }

  function test_TargetFactoriesWhenTheTargetFactoryApprovalSetIsEmpty() external view {
    // it should return an empty array
    assertEq(_factoryRegistry.targetFactories().length, 0);
  }

  function test_TargetFactoriesWhenTheTargetFactoryApprovalSetIsPopulated() external {
    address _secondTargetFactory = makeAddr('_secondTargetFactory');
    _seedTargetFactory(_targetFactory);
    _seedTargetFactory(_secondTargetFactory);

    // it should return every registered target factory
    address[] memory _factories = _factoryRegistry.targetFactories();
    assertEq(_factories.length, 2);
    assertEq(_factories[0], _targetFactory);
    assertEq(_factories[1], _secondTargetFactory);
  }

  function test_TargetFactoriesLengthWhenTheTargetFactoryApprovalSetIsEmpty() external view {
    // it should return zero
    assertEq(_factoryRegistry.targetFactoriesLength(), 0);
  }

  function test_TargetFactoriesLengthWhenTheTargetFactoryApprovalSetIsPopulated() external {
    _seedTargetFactory(_targetFactory);
    _seedTargetFactory(makeAddr('_secondTargetFactory'));

    // it should return the member count
    assertEq(_factoryRegistry.targetFactoriesLength(), 2);
  }

  function test_TargetFactoriesAtWhenTheIndexIsOutOfRangeOfTheTargetFactoryApprovalSet(uint256 _index) external {
    _index = bound(_index, 1, type(uint256).max);
    _seedTargetFactory(_targetFactory);

    // it should return the zero address
    assertEq(_factoryRegistry.targetFactoriesAt(_index), address(0));
  }

  function test_TargetFactoriesAtWhenTheIndexIsWithinRangeOfTheTargetFactoryApprovalSet() external {
    address _secondTargetFactory = makeAddr('_secondTargetFactory');
    _seedTargetFactory(_targetFactory);
    _seedTargetFactory(_secondTargetFactory);

    // it should return the member at the index
    assertEq(_factoryRegistry.targetFactoriesAt(0), _targetFactory);
    assertEq(_factoryRegistry.targetFactoriesAt(1), _secondTargetFactory);
  }

  function test_MetaRoutersWhenTheMetaRouterApprovalSetIsEmpty() external view {
    // it should return an empty array
    assertEq(_factoryRegistry.metaRouters().length, 0);
  }

  function test_MetaRoutersWhenTheMetaRouterApprovalSetIsPopulated() external {
    address _secondMetaRouter = makeAddr('_secondMetaRouter');
    _seedMetaRouter(_metaRouter);
    _seedMetaRouter(_secondMetaRouter);

    // it should return every registered meta router
    address[] memory _routers = _factoryRegistry.metaRouters();
    assertEq(_routers.length, 2);
    assertEq(_routers[0], _metaRouter);
    assertEq(_routers[1], _secondMetaRouter);
  }

  function test_FactoryToTargetsWhenTheFactoryHasNoRecordedTargets() external view {
    // it should return an empty array
    assertEq(_factoryRegistry.factoryToTargets(_targetFactory).length, 0);
  }

  function test_FactoryToTargetsWhenTheFactoryHasRecordedTargets() external {
    address _secondTarget = makeAddr('_secondTarget');
    _seedFactoryTarget(_targetFactory, _target);
    _seedFactoryTarget(_targetFactory, _secondTarget);

    // it should return every recorded target
    address[] memory _targets = _factoryRegistry.factoryToTargets(_targetFactory);
    assertEq(_targets.length, 2);
    assertEq(_targets[0], _target);
    assertEq(_targets[1], _secondTarget);
  }

  function test_FactoryToTargetsLengthWhenTheFactoryHasNoRecordedTargets() external view {
    // it should return zero
    assertEq(_factoryRegistry.factoryToTargetsLength(_targetFactory), 0);
  }

  function test_FactoryToTargetsLengthWhenTheFactoryHasRecordedTargets() external {
    _seedFactoryTarget(_targetFactory, _target);
    _seedFactoryTarget(_targetFactory, makeAddr('_secondTarget'));

    // it should return the member count
    assertEq(_factoryRegistry.factoryToTargetsLength(_targetFactory), 2);
  }

  function test_FactoryToTargetsAtWhenTheIndexIsOutOfRangeOfTheFactoryTargetEnumeration(uint256 _index) external {
    _index = bound(_index, 1, type(uint256).max);
    _seedFactoryTarget(_targetFactory, _target);

    // it should return the zero address
    assertEq(_factoryRegistry.factoryToTargetsAt(_targetFactory, _index), address(0));
  }

  function test_FactoryToTargetsAtWhenTheIndexIsWithinRangeOfTheFactoryTargetEnumeration() external {
    address _secondTarget = makeAddr('_secondTarget');
    _seedFactoryTarget(_targetFactory, _target);
    _seedFactoryTarget(_targetFactory, _secondTarget);

    // it should return the member at the index
    assertEq(_factoryRegistry.factoryToTargetsAt(_targetFactory, 0), _target);
    assertEq(_factoryRegistry.factoryToTargetsAt(_targetFactory, 1), _secondTarget);
  }

  function test_FactoryToGaugesWhenTheFactoryHasNoRecordedGauges() external view {
    // it should return an empty array
    assertEq(_factoryRegistry.factoryToGauges(_gaugeFactory).length, 0);
  }

  function test_FactoryToGaugesWhenTheFactoryHasRecordedGauges() external {
    address _secondGauge = makeAddr('_secondGauge');
    _seedFactoryGauge(_gaugeFactory, _gauge);
    _seedFactoryGauge(_gaugeFactory, _secondGauge);

    // it should return every recorded gauge
    address[] memory _gauges = _factoryRegistry.factoryToGauges(_gaugeFactory);
    assertEq(_gauges.length, 2);
    assertEq(_gauges[0], _gauge);
    assertEq(_gauges[1], _secondGauge);
  }

  function test_FactoryToGaugesLengthWhenTheFactoryHasNoRecordedGauges() external view {
    // it should return zero
    assertEq(_factoryRegistry.factoryToGaugesLength(_gaugeFactory), 0);
  }

  function test_FactoryToGaugesLengthWhenTheFactoryHasRecordedGauges() external {
    _seedFactoryGauge(_gaugeFactory, _gauge);
    _seedFactoryGauge(_gaugeFactory, makeAddr('_secondGauge'));

    // it should return the member count
    assertEq(_factoryRegistry.factoryToGaugesLength(_gaugeFactory), 2);
  }

  function test_FactoryToGaugesAtWhenTheIndexIsOutOfRangeOfTheFactoryGaugeEnumeration(uint256 _index) external {
    _index = bound(_index, 1, type(uint256).max);
    _seedFactoryGauge(_gaugeFactory, _gauge);

    // it should return the zero address
    assertEq(_factoryRegistry.factoryToGaugesAt(_gaugeFactory, _index), address(0));
  }

  function test_FactoryToGaugesAtWhenTheIndexIsWithinRangeOfTheFactoryGaugeEnumeration() external {
    address _secondGauge = makeAddr('_secondGauge');
    _seedFactoryGauge(_gaugeFactory, _gauge);
    _seedFactoryGauge(_gaugeFactory, _secondGauge);

    // it should return the member at the index
    assertEq(_factoryRegistry.factoryToGaugesAt(_gaugeFactory, 0), _gauge);
    assertEq(_factoryRegistry.factoryToGaugesAt(_gaugeFactory, 1), _secondGauge);
  }

  function test_GaugeToTargetWhenTheGaugeHasNoLinkedTarget() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.gaugeToTarget(_gauge), address(0));
  }

  function test_GaugeToTargetWhenTheGaugeIsLinkedToATarget(address _linkedTarget) external {
    _assumeFuzzable(_linkedTarget);
    _seedGaugeTargetLink(_gauge, _linkedTarget);

    // it should return the linked target
    assertEq(_factoryRegistry.gaugeToTarget(_gauge), _linkedTarget);
  }

  function test_GaugeFactoryToTargetFactoryWhenTheGaugeFactoryHasNoRecordedLink() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), address(0));
  }

  function test_GaugeFactoryToTargetFactoryWhenTheGaugeFactoryIsLinked(address _linkedTargetFactory) external {
    _assumeFuzzable(_linkedTargetFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _linkedTargetFactory);

    // it should return the linked target factory
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), _linkedTargetFactory);
  }

  function test_TargetFactoryToGaugeFactoryWhenTheTargetFactoryHasNoLinkedGaugeFactory() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_targetFactory), address(0));
  }

  function test_TargetFactoryToGaugeFactoryWhenTheTargetFactoryIsLinked(address _linkedGaugeFactory) external {
    _assumeFuzzable(_linkedGaugeFactory);
    _seedGaugeFactoryLink(_linkedGaugeFactory, _targetFactory);

    // it should return the linked gauge factory
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_targetFactory), _linkedGaugeFactory);
  }

  function test_TargetToGaugeWhenTheTargetHasNoLinkedGauge() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.targetToGauge(_target), address(0));
  }

  function test_TargetToGaugeWhenTheTargetIsLinkedToAGauge(address _linkedGauge) external {
    _assumeFuzzable(_linkedGauge);
    _seedGaugeTargetLink(_linkedGauge, _target);

    // it should return the linked gauge
    assertEq(_factoryRegistry.targetToGauge(_target), _linkedGauge);
  }

  /*//////////////////////////////////////////////////////////////
                        RELATIONSHIP GETTERS
  //////////////////////////////////////////////////////////////*/

  function test_GaugeToFactoryWhenTheGaugeIsUnknown() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.gaugeToFactory(_gauge), address(0));
  }

  function test_GaugeToFactoryWhenTheGaugeIsRecorded(address _recordedFactory) external {
    _assumeFuzzable(_recordedFactory);
    _seedGaugeRecord(_gauge, _recordedFactory);

    // it should return the deploying gauge factory
    assertEq(_factoryRegistry.gaugeToFactory(_gauge), _recordedFactory);
  }

  function test_TargetToFactoryWhenTheTargetIsUnknown() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.targetToFactory(_target), address(0));
  }

  function test_TargetToFactoryWhenTheTargetIsRecorded(address _recordedFactory) external {
    _assumeFuzzable(_recordedFactory);
    _seedTargetRecord(_target, _recordedFactory);

    // it should return the deploying target factory
    assertEq(_factoryRegistry.targetToFactory(_target), _recordedFactory);
  }

  function test_GaugeToRewardsWhenTheGaugeIsUnknown() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.gaugeToRewards(_gauge), address(0));
  }

  function test_GaugeToRewardsWhenTheGaugeIsRecorded(address _recordedRewards) external {
    _assumeFuzzable(_recordedRewards);
    _seedRewardsRecord(_gauge, _recordedRewards);

    // it should return the recorded rewards contract
    assertEq(_factoryRegistry.gaugeToRewards(_gauge), _recordedRewards);
  }

  function test_RewardsToGaugeWhenTheRewardsContractIsUnknown() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.rewardsToGauge(_rewards), address(0));
  }

  function test_RewardsToGaugeWhenTheRewardsContractIsRecorded(address _recordedGauge) external {
    _assumeFuzzable(_recordedGauge);
    _seedRewardsToGaugeRecord(_rewards, _recordedGauge);

    // it should return the recorded gauge
    assertEq(_factoryRegistry.rewardsToGauge(_rewards), _recordedGauge);
  }

  function test_TokenRegistryWhenTheTokenRegistryIsUnset() external view {
    // it should return the zero address
    assertEq(_factoryRegistry.tokenRegistry(), address(0));
  }

  function test_TokenRegistryWhenTheTokenRegistryIsSet(address _recordedTokenRegistry) external {
    _assumeFuzzable(_recordedTokenRegistry);
    _seedTokenRegistry(_recordedTokenRegistry);

    // it should return the recorded token registry
    assertEq(_factoryRegistry.tokenRegistry(), _recordedTokenRegistry);
  }

  /*//////////////////////////////////////////////////////////////
                         FORWARDING GETTERS
  //////////////////////////////////////////////////////////////*/

  function test_EmissionCapWhenTheGaugeIsUnknown() external {
    // it should not call the gauge factory
    vm.expectCall(_gaugeFactory, abi.encodeWithSelector(IGaugeFactory.emissionCap.selector), 0);

    // it should return zero
    assertEq(_factoryRegistry.emissionCap(_gauge), 0);
  }

  function test_EmissionCapWhenTheFactoryCapQueryReverts() external {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeRecord(_gauge, _gaugeFactory);
    vm.mockCallRevert(_gaugeFactory, abi.encodeCall(IGaugeFactory.emissionCap, (_gauge)), 'revert');

    // it should return zero
    assertEq(_factoryRegistry.emissionCap(_gauge), 0);
  }

  function test_EmissionCapWhenTheDeployingFactoryIsNoLongerInTheApprovalSet(uint128 _cap) external {
    _seedGaugeRecord(_gauge, _gaugeFactory);

    // it should query the cap on the deploying gauge factory
    _mockAndExpect(_gaugeFactory, abi.encodeCall(IGaugeFactory.emissionCap, (_gauge)), abi.encode(_cap));

    // it should return the factory reported cap
    assertEq(_factoryRegistry.emissionCap(_gauge), _cap);
  }

  function test_EmissionCapWhenTheGaugeIsRecordedUnderARegisteredFactory(uint128 _cap) external {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeRecord(_gauge, _gaugeFactory);

    // it should query the cap on the deploying gauge factory
    _mockAndExpect(_gaugeFactory, abi.encodeCall(IGaugeFactory.emissionCap, (_gauge)), abi.encode(_cap));

    // it should return the factory reported cap
    assertEq(_factoryRegistry.emissionCap(_gauge), _cap);
  }

  /*//////////////////////////////////////////////////////////////
                        FACTORY REGISTRATION
  //////////////////////////////////////////////////////////////*/

  function test_RegisterFactoriesWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.registerFactories(_gaugeFactory, _targetFactory);
  }

  function test_RegisterFactoriesWhenTheCallerLacksTheFactoryRegistryAdminRole(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAdminRole(_caller, false);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.registerFactories(_gaugeFactory, _targetFactory);
  }

  modifier whenTheCallerHoldsTheFactoryRegistryAdminRole() {
    _mockAdminRole(address(this), true);
    _;
  }

  function test_RegisterFactoriesWhenTheGaugeFactoryIsTheZeroAddress()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerFactories(address(0), _targetFactory);
  }

  function test_RegisterFactoriesWhenTheTargetFactoryIsTheZeroAddress()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerFactories(_gaugeFactory, address(0));
  }

  function test_RegisterFactoriesWhenTheGaugeFactoryIsLinkedToADifferentTargetFactory(address _otherTargetFactory)
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _assumeFuzzable(_otherTargetFactory);
    vm.assume(_otherTargetFactory != _targetFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);

    // it should revert with GaugeFactoryAlreadyLinked
    vm.expectRevert(IFactoryRegistry.GaugeFactoryAlreadyLinked.selector);
    _factoryRegistry.registerFactories(_gaugeFactory, _otherTargetFactory);
  }

  function test_RegisterFactoriesWhenTheTargetFactoryIsLinkedToADifferentGaugeFactory(address _otherGaugeFactory)
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _assumeFuzzable(_otherGaugeFactory);
    vm.assume(_otherGaugeFactory != _gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);

    // it should revert with TargetFactoryAlreadyLinked
    vm.expectRevert(IFactoryRegistry.TargetFactoryAlreadyLinked.selector);
    _factoryRegistry.registerFactories(_otherGaugeFactory, _targetFactory);
  }

  function test_RegisterFactoriesWhenTheGaugeFactoryIsAlreadyInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedGaugeFactory(_gaugeFactory);

    // it should revert with AlreadyRegistered
    vm.expectRevert(IFactoryRegistry.AlreadyRegistered.selector);
    _factoryRegistry.registerFactories(_gaugeFactory, _targetFactory);
  }

  function test_RegisterFactoriesWhenTheTargetFactoryIsPreregisteredAndUnlinked()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedTargetFactory(_targetFactory);

    vm.recordLogs();
    _factoryRegistry.registerFactories(_gaugeFactory, _targetFactory);

    // it should write the gauge factory to target factory link
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), _targetFactory);

    // it should write the target factory to gauge factory link
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_targetFactory), _gaugeFactory);

    // it should add the gauge factory to the approval set
    assertTrue(_factoryRegistry.isGaugeFactoryApproved(_gaugeFactory));

    // it should keep the target factory in the approval set
    assertTrue(_factoryRegistry.isTargetFactoryApproved(_targetFactory));

    // it should emit FactoriesLinked
    // it should emit GaugeFactoryRegistered
    // it should not emit TargetFactoryRegistered
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    bool _factoriesLinkedSeen;
    bool _gaugeFactoryRegisteredSeen;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].topics[0] == IFactoryRegistry.FactoriesLinked.selector) _factoriesLinkedSeen = true;
      if (_logs[_i].topics[0] == IFactoryRegistry.GaugeFactoryRegistered.selector) _gaugeFactoryRegisteredSeen = true;
      assertNotEq(_logs[_i].topics[0], IFactoryRegistry.TargetFactoryRegistered.selector);
    }
    assertTrue(_factoriesLinkedSeen);
    assertTrue(_gaugeFactoryRegisteredSeen);
  }

  function test_RegisterFactoriesWhenThePairIsLinkedAndUnregistered()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);

    vm.recordLogs();
    _factoryRegistry.registerFactories(_gaugeFactory, _targetFactory);

    // it should add the gauge factory to the approval set
    assertTrue(_factoryRegistry.isGaugeFactoryApproved(_gaugeFactory));

    // it should add the target factory to the approval set
    assertTrue(_factoryRegistry.isTargetFactoryApproved(_targetFactory));

    // it should keep the recorded link unchanged
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), _targetFactory);
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_targetFactory), _gaugeFactory);

    // it should not emit FactoriesLinked
    // it should emit GaugeFactoryRegistered
    // it should emit TargetFactoryRegistered
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    bool _gaugeFactoryRegisteredSeen;
    bool _targetFactoryRegisteredSeen;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].topics[0] == IFactoryRegistry.GaugeFactoryRegistered.selector) _gaugeFactoryRegisteredSeen = true;
      if (_logs[_i].topics[0] == IFactoryRegistry.TargetFactoryRegistered.selector) {
        _targetFactoryRegisteredSeen = true;
      }
      assertNotEq(_logs[_i].topics[0], IFactoryRegistry.FactoriesLinked.selector);
    }
    assertTrue(_gaugeFactoryRegisteredSeen);
    assertTrue(_targetFactoryRegisteredSeen);
  }

  function test_RegisterFactoriesWhenBothFactoriesAreUnlinkedAndUnregistered(
    address _newGaugeFactory,
    address _newTargetFactory
  ) external whenTheCallerHoldsTheFactoryRegistryAdminRole {
    _assumeFuzzable(_newGaugeFactory);
    _assumeFuzzable(_newTargetFactory);

    // it should emit FactoriesLinked
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.FactoriesLinked(_newGaugeFactory, _newTargetFactory);

    // it should emit GaugeFactoryRegistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.GaugeFactoryRegistered(_newGaugeFactory);

    // it should emit TargetFactoryRegistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TargetFactoryRegistered(_newTargetFactory);

    _factoryRegistry.registerFactories(_newGaugeFactory, _newTargetFactory);

    // it should write the gauge factory to target factory link
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_newGaugeFactory), _newTargetFactory);

    // it should write the target factory to gauge factory link
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_newTargetFactory), _newGaugeFactory);

    // it should add the gauge factory to the approval set
    assertTrue(_factoryRegistry.isGaugeFactoryApproved(_newGaugeFactory));

    // it should add the target factory to the approval set
    assertTrue(_factoryRegistry.isTargetFactoryApproved(_newTargetFactory));
  }

  function test_RegisterTargetFactoryWhenTheCallerIsNotTheTargetFactoryAdmin(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _targetFactoryAdmin);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.registerTargetFactory(_targetFactory);
  }

  function test_RegisterTargetFactoryWhenTheTargetFactoryIsTheZeroAddress()
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerTargetFactory(address(0));
  }

  function test_RegisterTargetFactoryWhenTheTargetFactoryIsAlreadyInTheApprovalSet()
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    _seedTargetFactory(_targetFactory);

    // it should revert with AlreadyRegistered
    vm.expectRevert(IFactoryRegistry.AlreadyRegistered.selector);
    _factoryRegistry.registerTargetFactory(_targetFactory);
  }

  function test_RegisterTargetFactoryWhenTheTargetFactoryIsNotInTheApprovalSet(address _newTargetFactory)
    external
    whenTheCallerIsTheTargetFactoryAdmin
  {
    _assumeFuzzable(_newTargetFactory);

    // it should emit TargetFactoryRegistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TargetFactoryRegistered(_newTargetFactory);

    _factoryRegistry.registerTargetFactory(_newTargetFactory);

    // it should add the target factory to the approval set
    assertTrue(_factoryRegistry.isTargetFactoryApproved(_newTargetFactory));
  }

  function test_UnregisterFactoriesWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.unregisterFactories(_gaugeFactory);
  }

  function test_UnregisterFactoriesWhenTheCallerLacksTheFactoryRegistryAdminRole(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAdminRole(_caller, false);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.unregisterFactories(_gaugeFactory);
  }

  function test_UnregisterFactoriesWhenTheGaugeFactoryIsNotInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with NotRegistered
    vm.expectRevert(IFactoryRegistry.NotRegistered.selector);
    _factoryRegistry.unregisterFactories(_gaugeFactory);
  }

  function test_UnregisterFactoriesWhenTheLinkedTargetFactoryIsNotInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);

    // it should revert with NotRegistered
    vm.expectRevert(IFactoryRegistry.NotRegistered.selector);
    _factoryRegistry.unregisterFactories(_gaugeFactory);
  }

  function test_UnregisterFactoriesWhenThePairIsRegistered() external whenTheCallerHoldsTheFactoryRegistryAdminRole {
    _seedGaugeFactory(_gaugeFactory);
    _seedTargetFactory(_targetFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedGaugeRecord(_gauge, _gaugeFactory);
    _seedRewardsRecord(_gauge, _rewards);
    _seedTargetRecord(_target, _targetFactory);

    // it should emit GaugeFactoryUnregistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.GaugeFactoryUnregistered(_gaugeFactory);

    // it should emit TargetFactoryUnregistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TargetFactoryUnregistered(_targetFactory);

    _factoryRegistry.unregisterFactories(_gaugeFactory);

    // it should remove the gauge factory from the approval set
    assertFalse(_factoryRegistry.isGaugeFactoryApproved(_gaugeFactory));

    // it should remove the linked target factory from the approval set
    assertFalse(_factoryRegistry.isTargetFactoryApproved(_targetFactory));

    // it should keep every record the factories established resolving
    assertEq(_factoryRegistry.gaugeToFactory(_gauge), _gaugeFactory);
    assertEq(_factoryRegistry.gaugeToRewards(_gauge), _rewards);
    assertEq(_factoryRegistry.targetToFactory(_target), _targetFactory);

    // it should keep the factory link resolving
    assertEq(_factoryRegistry.gaugeFactoryToTargetFactory(_gaugeFactory), _targetFactory);
    assertEq(_factoryRegistry.targetFactoryToGaugeFactory(_targetFactory), _gaugeFactory);
  }

  /*//////////////////////////////////////////////////////////////
                      META ROUTER REGISTRATION
  //////////////////////////////////////////////////////////////*/

  function test_RegisterMetaRouterWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.registerMetaRouter(_metaRouter);
  }

  function test_RegisterMetaRouterWhenTheCallerLacksTheFactoryRegistryAdminRole(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAdminRole(_caller, false);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.registerMetaRouter(_metaRouter);
  }

  function test_RegisterMetaRouterWhenTheMetaRouterIsTheZeroAddress()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerMetaRouter(address(0));
  }

  function test_RegisterMetaRouterWhenTheMetaRouterIsAlreadyInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedMetaRouter(_metaRouter);

    // it should revert with AlreadyRegistered
    vm.expectRevert(IFactoryRegistry.AlreadyRegistered.selector);
    _factoryRegistry.registerMetaRouter(_metaRouter);
  }

  function test_RegisterMetaRouterWhenTheMetaRouterIsNotInTheApprovalSet(address _newMetaRouter)
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _assumeFuzzable(_newMetaRouter);

    // it should emit MetaRouterRegistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.MetaRouterRegistered(_newMetaRouter);

    _factoryRegistry.registerMetaRouter(_newMetaRouter);

    // it should add the meta router to the approval set
    assertTrue(_factoryRegistry.isMetaRouterApproved(_newMetaRouter));
  }

  function test_UnregisterMetaRouterWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.unregisterMetaRouter(_metaRouter);
  }

  function test_UnregisterMetaRouterWhenTheCallerLacksTheFactoryRegistryAdminRole(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAdminRole(_caller, false);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.unregisterMetaRouter(_metaRouter);
  }

  function test_UnregisterMetaRouterWhenTheMetaRouterIsNotInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with NotRegistered
    vm.expectRevert(IFactoryRegistry.NotRegistered.selector);
    _factoryRegistry.unregisterMetaRouter(_metaRouter);
  }

  function test_UnregisterMetaRouterWhenTheMetaRouterIsInTheApprovalSet()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _seedMetaRouter(_metaRouter);

    // it should emit MetaRouterUnregistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.MetaRouterUnregistered(_metaRouter);

    _factoryRegistry.unregisterMetaRouter(_metaRouter);

    // it should remove the meta router from the approval set
    assertFalse(_factoryRegistry.isMetaRouterApproved(_metaRouter));
  }

  /*//////////////////////////////////////////////////////////////
                           TOKEN REGISTRY
  //////////////////////////////////////////////////////////////*/

  function test_SetTokenRegistryWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.setTokenRegistry(_tokenRegistry);
  }

  function test_SetTokenRegistryWhenTheCallerLacksTheFactoryRegistryAdminRole(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAdminRole(_caller, false);

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.setTokenRegistry(_tokenRegistry);
  }

  function test_SetTokenRegistryWhenTheTokenRegistryIsTheZeroAddress()
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.setTokenRegistry(address(0));
  }

  function test_SetTokenRegistryWhenTheTokenRegistryIsNonZero(address _newTokenRegistry)
    external
    whenTheCallerHoldsTheFactoryRegistryAdminRole
  {
    _assumeFuzzable(_newTokenRegistry);

    // it should emit TokenRegistrySet
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TokenRegistrySet(_newTokenRegistry);

    _factoryRegistry.setTokenRegistry(_newTokenRegistry);

    // it should write the token registry pointer
    assertEq(_factoryRegistry.tokenRegistry(), _newTokenRegistry);
  }

  /*//////////////////////////////////////////////////////////////
                          TARGET RECORDING
  //////////////////////////////////////////////////////////////*/

  function test_RegisterTargetWhenTheCallerIsNotARegisteredTargetFactory(address _caller) external {
    _assumeFuzzable(_caller);

    // it should revert with TargetFactoryNotRegistered
    vm.expectRevert(IFactoryRegistry.TargetFactoryNotRegistered.selector);
    vm.prank(_caller);
    _factoryRegistry.registerTarget(_target);
  }

  modifier whenTheCallerIsARegisteredTargetFactory() {
    _seedTargetFactory(_targetFactory);
    _;
  }

  function test_RegisterTargetWhenTheTargetIsTheZeroAddress() external whenTheCallerIsARegisteredTargetFactory {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    vm.prank(_targetFactory);
    _factoryRegistry.registerTarget(address(0));
  }

  function test_RegisterTargetWhenTheTargetIsAlreadyRecorded() external whenTheCallerIsARegisteredTargetFactory {
    _seedTargetRecord(_target, _targetFactory);

    // it should revert with TargetAlreadyRecorded
    vm.expectRevert(IFactoryRegistry.TargetAlreadyRecorded.selector);
    vm.prank(_targetFactory);
    _factoryRegistry.registerTarget(_target);
  }

  function test_RegisterTargetWhenTheTargetIsAlreadyInTheFactoryEnumeration()
    external
    whenTheCallerIsARegisteredTargetFactory
  {
    _seedFactoryTarget(_targetFactory, _target);

    // it should revert with AlreadyEnumerated
    vm.expectRevert(IFactoryRegistry.AlreadyEnumerated.selector);
    vm.prank(_targetFactory);
    _factoryRegistry.registerTarget(_target);
  }

  function test_RegisterTargetWhenTheTargetIsUnrecorded(address _newTarget)
    external
    whenTheCallerIsARegisteredTargetFactory
  {
    _assumeFuzzable(_newTarget);

    // it should emit TargetCreated
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.TargetCreated(_newTarget, _targetFactory);
    vm.prank(_targetFactory);
    _factoryRegistry.registerTarget(_newTarget);

    // it should write the target to factory record
    assertEq(_factoryRegistry.targetToFactory(_newTarget), _targetFactory);

    // it should add the target to the factory enumeration
    address[] memory _targets = _factoryRegistry.factoryToTargets(_targetFactory);
    assertEq(_targets.length, 1);
    assertEq(_targets[0], _newTarget);
  }

  /*//////////////////////////////////////////////////////////////
                            GAUGE RECORDING
  //////////////////////////////////////////////////////////////*/

  function test_RegisterGaugeWhenTheLeafVoterIsUnset() external {
    FactoryRegistry _freshRegistry =
      new FactoryRegistry({_targetFactoryAdmin: _targetFactoryAdmin, _leafVoter: address(0)});

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    _freshRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheCallerIsNotTheGaugeManager(address _caller) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _gaugeManager);
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));

    // it should revert with NotAuthorized
    vm.expectRevert(IFactoryRegistry.NotAuthorized.selector);
    vm.prank(_caller);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  modifier whenTheCallerIsTheGaugeManager() {
    _mockAndExpect(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));
    vm.startPrank(_gaugeManager);
    _;
    vm.stopPrank();
  }

  function test_RegisterGaugeWhenTheGaugeIsTheZeroAddress() external whenTheCallerIsTheGaugeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerGauge(address(0), _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheRewardsContractIsTheZeroAddress() external whenTheCallerIsTheGaugeManager {
    // it should revert with ZeroAddress
    vm.expectRevert(IFactoryRegistry.ZeroAddress.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, address(0), _target);
  }

  function test_RegisterGaugeWhenTheGaugeFactoryIsNotRegistered() external whenTheCallerIsTheGaugeManager {
    // it should revert with GaugeFactoryNotRegistered
    vm.expectRevert(IFactoryRegistry.GaugeFactoryNotRegistered.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheGaugeFactoryHasNoLinkedTargetFactory() external whenTheCallerIsTheGaugeManager {
    _seedGaugeFactory(_gaugeFactory);

    // it should revert with NotLinked
    vm.expectRevert(IFactoryRegistry.NotLinked.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheGaugeIsAlreadyRecorded() external whenTheCallerIsTheGaugeManager {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedGaugeRecord(_gauge, _gaugeFactory);

    // it should revert with GaugeAlreadyRecorded
    vm.expectRevert(IFactoryRegistry.GaugeAlreadyRecorded.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheRewardsContractIsAlreadyRecorded() external whenTheCallerIsTheGaugeManager {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedRewardsToGaugeRecord(_rewards, makeAddr('_otherGauge'));

    // it should revert with RewardsAlreadyRecorded
    vm.expectRevert(IFactoryRegistry.RewardsAlreadyRecorded.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheTargetIsNotRecorded() external whenTheCallerIsTheGaugeManager {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);

    // it should revert with TargetNotRecorded
    vm.expectRevert(IFactoryRegistry.TargetNotRecorded.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheTargetAlreadyHoldsAGauge(address _newGauge)
    external
    whenTheCallerIsTheGaugeManager
  {
    _assumeFuzzable(_newGauge);
    vm.assume(_newGauge != _gauge);
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedTargetRecord(_target, _targetFactory);
    _seedGaugeTargetLink(_gauge, _target);

    // it should revert with TargetAlreadyLinked
    vm.expectRevert(IFactoryRegistry.TargetAlreadyLinked.selector);
    _factoryRegistry.registerGauge(_newGauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheTargetIsNotFromTheLinkedTargetFactory() external whenTheCallerIsTheGaugeManager {
    address _otherTargetFactory = makeAddr('_otherTargetFactory');
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _otherTargetFactory);
    _seedTargetRecord(_target, _targetFactory);

    // it should revert with TargetFactoryMismatch
    vm.expectRevert(IFactoryRegistry.TargetFactoryMismatch.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheGaugeIsAlreadyInTheFactoryEnumeration() external whenTheCallerIsTheGaugeManager {
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedTargetRecord(_target, _targetFactory);
    _seedFactoryGauge(_gaugeFactory, _gauge);

    // it should revert with AlreadyEnumerated
    vm.expectRevert(IFactoryRegistry.AlreadyEnumerated.selector);
    _factoryRegistry.registerGauge(_gauge, _gaugeFactory, _rewards, _target);
  }

  function test_RegisterGaugeWhenTheReportIsValid(
    address _newGauge,
    address _newRewards
  ) external whenTheCallerIsTheGaugeManager {
    _assumeFuzzable(_newGauge);
    _assumeFuzzable(_newRewards);
    _seedGaugeFactory(_gaugeFactory);
    _seedGaugeFactoryLink(_gaugeFactory, _targetFactory);
    _seedTargetRecord(_target, _targetFactory);

    // it should emit GaugeRegistered
    _expectEmit(address(_factoryRegistry));
    emit IFactoryRegistry.GaugeRegistered(_newGauge, _gaugeFactory, _target, _newRewards);

    _factoryRegistry.registerGauge(_newGauge, _gaugeFactory, _newRewards, _target);

    // it should write the gauge to factory record
    assertEq(_factoryRegistry.gaugeToFactory(_newGauge), _gaugeFactory);

    // it should add the gauge to the factory enumeration
    address[] memory _gauges = _factoryRegistry.factoryToGauges(_gaugeFactory);
    assertEq(_gauges.length, 1);
    assertEq(_gauges[0], _newGauge);

    // it should write the gauge to rewards record
    assertEq(_factoryRegistry.gaugeToRewards(_newGauge), _newRewards);

    // it should write the rewards to gauge record
    assertEq(_factoryRegistry.rewardsToGauge(_newRewards), _newGauge);

    // it should write the gauge to target link
    assertEq(_factoryRegistry.gaugeToTarget(_newGauge), _target);

    // it should write the target to gauge link
    assertEq(_factoryRegistry.targetToGauge(_target), _newGauge);
  }

  /*//////////////////////////////////////////////////////////////
                              HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @notice Mocks the admin role check on the LeafVoter for a caller
  function _mockAdminRole(address _caller, bool _hasRole) internal {
    vm.mockCall(
      _leafVoter,
      abi.encodeCall(IAccessControl.hasRole, (Roles.FACTORY_REGISTRY_ADMIN_ROLE, _caller)),
      abi.encode(_hasRole)
    );
  }

  /**
   * @notice Appends a member to an EnumerableSet.AddressSet directly in storage.
   * @dev The set spans two slots, the values array at _setSlot and the one
   *      based positions mapping at the slot after it.
   */
  function _seedAddressSet(bytes32 _setSlot, address _member) internal {
    address _registry = address(_factoryRegistry);
    uint256 _length = uint256(vm.load(_registry, _setSlot));

    vm.store(_registry, bytes32(uint256(keccak256(abi.encode(_setSlot))) + _length), bytes32(uint256(uint160(_member))));
    vm.store(_registry, _setSlot, bytes32(_length + 1));
    vm.store(
      _registry, keccak256(abi.encode(bytes32(uint256(uint160(_member))), uint256(_setSlot) + 1)), bytes32(_length + 1)
    );
  }

  /// @notice Seeds a gauge factory into the approval set directly in storage
  function _seedGaugeFactory(address _factory) internal {
    _seedAddressSet(bytes32(_GAUGE_FACTORIES_SLOT), _factory);
  }

  /// @notice Seeds a target factory into the approval set directly in storage
  function _seedTargetFactory(address _factory) internal {
    _seedAddressSet(bytes32(_TARGET_FACTORIES_SLOT), _factory);
  }

  /// @notice Seeds a meta router into the approval set directly in storage
  function _seedMetaRouter(address _router) internal {
    _seedAddressSet(bytes32(_META_ROUTERS_SLOT), _router);
  }

  /// @notice Seeds a target into a factory's enumeration directly in storage
  function _seedFactoryTarget(address _factory, address _recordedTarget) internal {
    _seedAddressSet(keccak256(abi.encode(_factory, _FACTORY_TO_TARGETS_SLOT)), _recordedTarget);
  }

  /// @notice Seeds a gauge into a factory's enumeration directly in storage
  function _seedFactoryGauge(address _factory, address _recordedGauge) internal {
    _seedAddressSet(keccak256(abi.encode(_factory, _FACTORY_TO_GAUGES_SLOT)), _recordedGauge);
  }

  /// @notice Seeds both sides of a gauge target link directly in storage
  function _seedGaugeTargetLink(address _linkedGauge, address _linkedTarget) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.gaugeToTarget.selector).with_key(_linkedGauge)
      .checked_write(_linkedTarget);
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.targetToGauge.selector).with_key(_linkedTarget)
      .checked_write(_linkedGauge);
  }

  /// @notice Seeds both sides of a gauge factory to target factory link directly in storage
  function _seedGaugeFactoryLink(address _linkedGaugeFactory, address _linkedTargetFactory) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.gaugeFactoryToTargetFactory.selector)
      .with_key(_linkedGaugeFactory).checked_write(_linkedTargetFactory);
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.targetFactoryToGaugeFactory.selector)
      .with_key(_linkedTargetFactory).checked_write(_linkedGaugeFactory);
  }

  /// @notice Seeds the gaugeToFactory record directly in storage
  function _seedGaugeRecord(address _recordedGauge, address _factory) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.gaugeToFactory.selector).with_key(_recordedGauge)
      .checked_write(_factory);
  }

  /// @notice Seeds the gaugeToRewards record directly in storage
  function _seedRewardsRecord(address _recordedGauge, address _recordedRewards) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.gaugeToRewards.selector).with_key(_recordedGauge)
      .checked_write(_recordedRewards);
  }

  /// @notice Seeds the rewardsToGauge record directly in storage
  function _seedRewardsToGaugeRecord(address _recordedRewards, address _recordedGauge) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.rewardsToGauge.selector).with_key(_recordedRewards)
      .checked_write(_recordedGauge);
  }

  /// @notice Seeds the token registry pointer directly in storage
  function _seedTokenRegistry(address _recordedTokenRegistry) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.tokenRegistry.selector)
      .checked_write(_recordedTokenRegistry);
  }

  /// @notice Seeds the targetToFactory record directly in storage
  function _seedTargetRecord(address _recordedTarget, address _factory) internal {
    stdstore.target(address(_factoryRegistry)).sig(IFactoryRegistry.targetToFactory.selector).with_key(_recordedTarget)
      .checked_write(_factory);
  }
}
