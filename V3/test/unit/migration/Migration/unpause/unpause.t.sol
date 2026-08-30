// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

contract UnitMigrationUnpause is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.unpause();
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheContractIsUnpaused() external whenTheCallerIsTheOwner {
    // it should revert with ExpectedPause
    vm.expectRevert(Pausable.ExpectedPause.selector);
    vm.prank(_owner);
    _migration.unpause();
  }

  function test_GivenTheContractIsPaused() external whenTheCallerIsTheOwner {
    _setPaused(true);

    vm.prank(_owner);
    // it should emit Unpaused
    _expectEmit(address(_migration));
    emit Pausable.Unpaused(_owner);
    _migration.unpause();

    // it should unpause the contract
    assertFalse(_migration.paused());
  }

  function testGas_unpause() external {
    _setPaused(true);

    vm.prank(_owner);
    _migration.unpause();
    vm.snapshotGasLastCall('Migration_unpause');
  }
}
