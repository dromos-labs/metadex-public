// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

contract UnitMigrationPause is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.pause();
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheContractIsUnpaused() external whenTheCallerIsTheOwner {
    vm.prank(_owner);
    // it should emit Paused
    _expectEmit(address(_migration));
    emit Pausable.Paused(_owner);
    _migration.pause();

    // it should pause the contract
    assertTrue(_migration.paused());
  }

  function test_GivenTheContractIsPaused() external whenTheCallerIsTheOwner {
    _setPaused(true);

    // it should revert with EnforcedPause
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_owner);
    _migration.pause();
  }

  function testGas_pause() external {
    vm.prank(_owner);
    _migration.pause();
    vm.snapshotGasLastCall('Migration_pause');
  }
}
