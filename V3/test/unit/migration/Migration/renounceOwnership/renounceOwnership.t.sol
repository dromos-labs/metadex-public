// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

contract UnitMigrationRenounceOwnership is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.renounceOwnership();
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheContractIsUnpaused() external whenTheCallerIsTheOwner {
    // it should revert with ExpectedPause
    vm.expectRevert(Pausable.ExpectedPause.selector);
    vm.prank(_owner);
    _migration.renounceOwnership();
  }

  function test_GivenTheContractIsPaused() external whenTheCallerIsTheOwner {
    vm.prank(_owner);
    _migration.pause();

    vm.prank(_owner);
    // it should emit OwnershipTransferred
    _expectEmit(address(_migration));
    emit Ownable.OwnershipTransferred(_owner, address(0));
    _migration.renounceOwnership();

    // it should renounce ownership
    assertEq(_migration.owner(), address(0));
  }

  function testGas_renounceOwnership() external {
    vm.prank(_owner);
    _migration.pause();

    vm.prank(_owner);
    _migration.renounceOwnership();
    vm.snapshotGasLastCall('Migration_renounceOwnership');
  }
}
