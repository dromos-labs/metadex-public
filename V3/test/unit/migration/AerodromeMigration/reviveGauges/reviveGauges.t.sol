// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationReviveGauges is UnitAerodromeMigration {
  function setUp() public override {
    super.setUp();
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenTheCallerIsNotTheOwner(address _caller, address _gauge) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);
    address[] memory _gauges = new address[](1);
    _gauges[0] = _gauge;

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.reviveGauges(_gauges);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_WhenTheGaugesArrayIsEmpty() external whenTheCallerIsTheOwner {
    address[] memory _gauges = new address[](0);

    // it should not call the V2 voter
    vm.expectCall(_v2Voter, abi.encodeWithSelector(IV2Voter.reviveGauge.selector), 0);
    vm.prank(_owner);
    _migration.reviveGauges(_gauges);
  }

  function test_WhenGaugesAreProvided(address _gaugeOne, address _gaugeTwo) external whenTheCallerIsTheOwner {
    vm.assume(_gaugeOne != _gaugeTwo);
    address[] memory _gauges = new address[](2);
    _gauges[0] = _gaugeOne;
    _gauges[1] = _gaugeTwo;

    // it should revive every gauge through the V2 voter
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reviveGauge, (_gaugeOne)), '');
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reviveGauge, (_gaugeTwo)), '');
    vm.prank(_owner);
    _migration.reviveGauges(_gauges);
  }

  function test_GivenTheContractIsPaused(address _gauge) external whenTheCallerIsTheOwner {
    _setPaused(true);
    address[] memory _gauges = new address[](1);
    _gauges[0] = _gauge;

    // it should revive every gauge through the V2 voter
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reviveGauge, (_gauge)), '');
    vm.prank(_owner);
    _migration.reviveGauges(_gauges);
  }

  function testGas_reviveGauges() external {
    address[] memory _gauges = new address[](2);
    _gauges[0] = makeAddr('GaugeOne');
    _gauges[1] = makeAddr('GaugeTwo');
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reviveGauge, (_gauges[0])), '');
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reviveGauge, (_gauges[1])), '');

    vm.prank(_owner);
    _migration.reviveGauges(_gauges);
    vm.snapshotGasLastCall('AerodromeMigration_reviveGauges');
  }
}
