// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IV2EmergencyCouncil} from 'V3/interfaces/migration/v2/IV2EmergencyCouncil.sol';

import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationReviveRootGauges is UnitVelodromeMigration {
  function setUp() public override {
    super.setUp();
    _deployMigration();
  }

  function test_WhenTheCallerIsNotTheOwner(address _caller, address _gauge) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);
    address[] memory _gauges = new address[](1);
    _gauges[0] = _gauge;

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.reviveRootGauges(_gauges);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_WhenTheGaugesArrayIsEmpty() external whenTheCallerIsTheOwner {
    address[] memory _gauges = new address[](0);

    // it should not call the V2 emergency council
    vm.expectCall(_v2EmergencyCouncil, abi.encodeWithSelector(IV2EmergencyCouncil.reviveRootGauge.selector), 0);
    vm.prank(_owner);
    _migration.reviveRootGauges(_gauges);
  }

  function test_WhenGaugesAreProvided(address _gaugeOne, address _gaugeTwo) external whenTheCallerIsTheOwner {
    vm.assume(_gaugeOne != _gaugeTwo);
    address[] memory _gauges = new address[](2);
    _gauges[0] = _gaugeOne;
    _gauges[1] = _gaugeTwo;

    // it should revive every root gauge through the V2 emergency council
    _mockAndExpect(_v2EmergencyCouncil, abi.encodeCall(IV2EmergencyCouncil.reviveRootGauge, (_gaugeOne)), '');
    _mockAndExpect(_v2EmergencyCouncil, abi.encodeCall(IV2EmergencyCouncil.reviveRootGauge, (_gaugeTwo)), '');
    vm.prank(_owner);
    _migration.reviveRootGauges(_gauges);
  }

  function test_GivenTheContractIsPaused(address _gauge) external whenTheCallerIsTheOwner {
    _setPaused(true);
    address[] memory _gauges = new address[](1);
    _gauges[0] = _gauge;

    // it should revive every root gauge through the V2 emergency council
    _mockAndExpect(_v2EmergencyCouncil, abi.encodeCall(IV2EmergencyCouncil.reviveRootGauge, (_gauge)), '');
    vm.prank(_owner);
    _migration.reviveRootGauges(_gauges);
  }

  function testGas_reviveRootGauges() external {
    address[] memory _gauges = new address[](2);
    _gauges[0] = makeAddr('GaugeOne');
    _gauges[1] = makeAddr('GaugeTwo');
    _mockAndExpect(_v2EmergencyCouncil, abi.encodeCall(IV2EmergencyCouncil.reviveRootGauge, (_gauges[0])), '');
    _mockAndExpect(_v2EmergencyCouncil, abi.encodeCall(IV2EmergencyCouncil.reviveRootGauge, (_gauges[1])), '');

    vm.prank(_owner);
    _migration.reviveRootGauges(_gauges);
    vm.snapshotGasLastCall('VelodromeMigration_reviveRootGauges');
  }
}
