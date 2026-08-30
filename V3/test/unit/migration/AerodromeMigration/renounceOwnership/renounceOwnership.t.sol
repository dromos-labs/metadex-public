// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationRenounceOwnership is UnitAerodromeMigration {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();

    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenTheCallerIsNotTheOwner(address _caller) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.renounceOwnership();
  }

  function test_WhenTheMigrationIsNotPaused() external {
    // it should revert with ExpectedPause
    vm.expectRevert(Pausable.ExpectedPause.selector);
    vm.prank(_owner);
    _migration.renounceOwnership();
  }

  modifier whenTheMigrationIsPaused() {
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);
    _;
  }

  function test_WhenTheRemainingTOKENBalanceIsNotZero(uint256 _remaining) external whenTheMigrationIsPaused {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _remaining);

    // it should revert with RemainingBalance
    vm.expectRevert(IAerodromeMigration.RemainingBalance.selector);
    vm.prank(_owner);
    _migration.renounceOwnership();
  }

  function test_WhenTheRemainingTOKENBalanceIsZero() external whenTheMigrationIsPaused {
    _mockAndExpectTokenBalance(_v3Token, address(_migration), 0);

    // it should emit OwnershipTransferred
    _expectEmit(address(_migration));
    emit Ownable.OwnershipTransferred(_owner, address(0));

    vm.prank(_owner);
    _migration.renounceOwnership();

    // it should renounce ownership
    assertEq(_migration.owner(), address(0));
  }

  function testGas_renounceOwnership() external {
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), 0);

    vm.prank(_owner);
    _migration.renounceOwnership();
    vm.snapshotGasLastCall('AerodromeMigration_renounceOwnership');
  }
}
