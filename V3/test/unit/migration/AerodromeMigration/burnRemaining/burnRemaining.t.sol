// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationBurnRemaining is UnitAerodromeMigration {
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
    _migration.burnRemaining();
  }

  function test_WhenTheMigrationIsNotPaused() external {
    // it should revert with ExpectedPause
    vm.expectRevert(Pausable.ExpectedPause.selector);
    vm.prank(_owner);
    _migration.burnRemaining();
  }

  modifier whenTheMigrationIsPaused() {
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);
    _;
  }

  function test_WhenTheMigrationIsPaused(uint256 _remaining) external whenTheMigrationIsPaused {
    _remaining = bound(_remaining, 1, type(uint256).max);

    // it should burn the full remaining balance
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _remaining);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    // it should emit RemainingBurned with the remaining balance
    _expectEmit(address(_migration));
    emit IAerodromeMigration.RemainingBurned(_remaining);

    vm.prank(_owner);
    _migration.burnRemaining();
  }

  function test_WhenBurnRemainingIsCalledRepeatedly(uint256 _remaining) external whenTheMigrationIsPaused {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_migration), [_remaining, 0]);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    // it should call burn with zero on the repeated call
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (uint256(0))), abi.encode());

    _expectEmit(address(_migration));
    emit IAerodromeMigration.RemainingBurned(_remaining);

    vm.prank(_owner);
    _migration.burnRemaining();

    // it should emit RemainingBurned with zero on the repeated call
    _expectEmit(address(_migration));
    emit IAerodromeMigration.RemainingBurned(0);

    vm.prank(_owner);
    _migration.burnRemaining();
  }

  function testGas_burnRemaining() external {
    uint256 _remaining = 100 ether;
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _remaining);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    vm.prank(_owner);
    _migration.burnRemaining();
    vm.snapshotGasLastCall('AerodromeMigration_burnRemaining');
  }
}
