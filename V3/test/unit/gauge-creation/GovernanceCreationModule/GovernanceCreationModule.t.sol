// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {IGaugeCreationModule} from 'V3/interfaces/gauge-creation/IGaugeCreationModule.sol';
import {IGaugeManager} from 'V3/interfaces/gauge-creation/IGaugeManager.sol';
import {IGovernanceCreationModule} from 'V3/interfaces/gauge-creation/IGovernanceCreationModule.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {GovernanceCreationModule} from 'V3/gauge-creation/GovernanceCreationModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitGovernanceCreationModule is TestHelpers {
  address internal _gaugeManager = makeAddr('_gaugeManager');
  address internal _leafVoter = makeAddr('_leafVoter');
  address internal _governor = makeAddr('_governor');

  GovernanceCreationModule internal _module;

  function setUp() public virtual {
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));
    _module = new GovernanceCreationModule(_leafVoter);
  }

  function _mockGovernanceRole(address _account, bool _hasRole) internal {
    _mockAndExpect(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _account)), abi.encode(_hasRole)
    );
  }

  function test_ConstructorWhenTheLeafVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    new GovernanceCreationModule(address(0));
  }

  function test_ConstructorWhenTheLeafVoterReportsAZeroGaugeManager(address _newLeafVoter) external {
    _assumeFuzzable(_newLeafVoter);
    vm.mockCall(_newLeafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(address(0)));

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeCreationModule.ZeroAddress.selector);
    new GovernanceCreationModule(_newLeafVoter);
  }

  function test_ConstructorWhenTheLeafVoterReportsANonzeroGaugeManager(
    address _newLeafVoter,
    address _newGaugeManager
  ) external {
    _assumeFuzzable(_newLeafVoter);
    vm.assume(_newGaugeManager != address(0));
    vm.mockCall(_newLeafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_newGaugeManager));

    GovernanceCreationModule module = new GovernanceCreationModule(_newLeafVoter);

    // it should set the leaf voter
    assertEq(address(module.LEAF_VOTER()), _newLeafVoter);

    // it should set the gauge manager reported by the leaf voter
    assertEq(address(module.GAUGE_MANAGER()), _newGaugeManager);
  }

  function test_CreateGaugeWhenTheCallerIsNotAGovernor(
    address _caller,
    address _target,
    address _gaugeFactory,
    bytes calldata _factoryData,
    bool _activate
  ) external {
    _assumeFuzzable(_caller);
    _mockGovernanceRole(_caller, false);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGovernanceCreationModule.NotAuthorized.selector);
    _module.createGauge(_target, _gaugeFactory, _factoryData, _activate);
  }

  function test_CreateGaugeWhenTheCallerIsAGovernor(
    address _target,
    address _gaugeFactory,
    bytes calldata _factoryData,
    bool _activate,
    address _gauge
  ) external {
    _mockGovernanceRole(_governor, true);

    // it should forward the request to the gauge manager verbatim
    // it should report the governor as the creator
    // it should forward the chosen activation flag
    IGaugeManager.GaugeCreationRequest memory expectedRequest = IGaugeManager.GaugeCreationRequest({
      creator: _governor, gaugeFactory: _gaugeFactory, target: _target, factoryData: _factoryData, activate: _activate
    });
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.createGauge, (expectedRequest)), abi.encode(_gauge));

    vm.prank(_governor);
    address createdGauge = _module.createGauge(_target, _gaugeFactory, _factoryData, _activate);

    // it should return the created gauge
    assertEq(createdGauge, _gauge);
  }

  function test_ActivateWhenTheCallerIsNotAGovernor(address _caller, address _gauge) external {
    _assumeFuzzable(_caller);
    _mockGovernanceRole(_caller, false);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGovernanceCreationModule.NotAuthorized.selector);
    _module.activate(_gauge);
  }

  function test_ActivateWhenTheCallerIsAGovernor(address _gauge) external {
    _mockGovernanceRole(_governor, true);

    // it should activate the gauge through the gauge manager
    _mockAndExpect(_gaugeManager, abi.encodeCall(IGaugeManager.activateGauge, (_gauge)), '');

    vm.prank(_governor);
    _module.activate(_gauge);
  }
}
