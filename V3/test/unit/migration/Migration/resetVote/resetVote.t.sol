// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

contract UnitMigrationResetVote is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.resetVote();
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheContractIsUnpaused() external whenTheCallerIsTheOwner {
    // it should reset the migration token id through the V2 voter
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reset, (_MIGRATION_TOKEN_ID)), '');
    vm.prank(_owner);
    _migration.resetVote();
  }

  function test_GivenTheContractIsPaused() external whenTheCallerIsTheOwner {
    _setPaused(true);

    // it should reset the migration token id through the V2 voter
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reset, (_MIGRATION_TOKEN_ID)), '');
    vm.prank(_owner);
    _migration.resetVote();
  }

  function testGas_resetVote() external {
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.reset, (_MIGRATION_TOKEN_ID)), '');

    vm.prank(_owner);
    _migration.resetVote();
    vm.snapshotGasLastCall('Migration_resetVote');
  }
}
