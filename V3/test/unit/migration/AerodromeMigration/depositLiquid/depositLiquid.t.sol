// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationDepositLiquid is UnitAerodromeMigration {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();

    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenTheMigrationIsPaused(uint256 _amount, address _recipient, address _caller) external {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);

    // it should revert with EnforcedPause
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_caller);
    _migration.depositLiquid({_amount: _amount, _recipient: _recipient});
  }

  modifier whenTheMigrationIsNotPaused() {
    _;
  }

  function test_WhenNativeTokensAreSent(
    uint256 _amount,
    address _recipient,
    address _caller,
    uint256 _value
  ) external whenTheMigrationIsNotPaused {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _value = bound(_value, 1, type(uint256).max);
    vm.deal(_caller, _value);

    // it should revert with UnexpectedValue
    vm.expectRevert(IAerodromeMigration.UnexpectedValue.selector);
    vm.prank(_caller);
    _migration.depositLiquid{value: _value}({_amount: _amount, _recipient: _recipient});
  }

  modifier whenNativeTokensAreNotSent() {
    _;
  }

  function test_WhenTheMigrationHasNotOpened(
    uint256 _amount,
    address _recipient,
    address _caller,
    uint256 _timestamp
  ) external whenTheMigrationIsNotPaused whenNativeTokensAreNotSent {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _timestamp = bound(_timestamp, 0, _migrationOpen - 1);
    vm.warp(_timestamp);

    // it should revert with MigrationNotOpen
    vm.expectRevert(IMigration.MigrationNotOpen.selector);
    vm.prank(_caller);
    _migration.depositLiquid({_amount: _amount, _recipient: _recipient});
  }

  modifier whenTheMigrationHasOpened() {
    vm.warp(_migrationOpen);
    _;
  }

  function test_WhenTheDepositedAmountIsZero(
    address _recipient,
    address _caller
  ) external whenTheMigrationIsNotPaused whenNativeTokensAreNotSent whenTheMigrationHasOpened {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);

    // it should revert with ZeroAmount
    vm.expectRevert(IMigration.ZeroAmount.selector);
    vm.prank(_caller);
    _migration.depositLiquid({_amount: 0, _recipient: _recipient});
  }

  modifier whenTheDepositedAmountIsNotZero() {
    _;
  }

  function test_WhenTheRecipientIsTheZeroAddress(
    uint256 _amount,
    address _caller
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
  {
    _amount = bound(_amount, 1, type(uint256).max);
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    vm.prank(_caller);
    _migration.depositLiquid({_amount: _amount, _recipient: address(0)});
  }

  modifier whenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenTheConversionExceedsTheMigrationBudget(
    uint256 _amount,
    uint256 _availableBalance,
    address _recipient
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
  {
    _amount = bound(_amount, 1, type(uint256).max);
    _availableBalance = bound(_availableBalance, 0, _amount - 1);
    _assumeFuzzable(_recipient);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _availableBalance);

    // it should revert with BudgetExhausted
    vm.expectRevert(IAerodromeMigration.BudgetExhausted.selector);
    vm.prank(users.alice);
    _migration.depositLiquid({_amount: _amount, _recipient: _recipient});
  }

  modifier whenTheConversionFitsWithinTheMigrationBudget() {
    _;
  }

  function test_WhenTheMigrationParametersAreKnown()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheConversionFitsWithinTheMigrationBudget
  {
    uint256 _amount = 5000 ether;
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should transfer the deposited amount from the caller
    _mockAndExpect(
      _v2Token, abi.encodeCall(IERC20.transferFrom, (users.alice, address(_migration), _amount)), abi.encode(true)
    );
    // it should approve the v2 voting escrow to spend the deposited amount
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, _amount)), abi.encode(true));
    // it should increase the migration veNFT amount by the deposited amount
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, _amount)), '');
    // it should transfer the conversion output to the recipient as liquid tokens
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (users.bob, _amount)), abi.encode(true));
    // it should emit the LiquidMigrated event
    _expectEmit(address(_migration));
    emit IMigration.LiquidMigrated({_depositor: users.alice, _recipient: users.bob, _amountIn: _amount, _out: _amount});

    vm.prank(users.alice);
    _migration.depositLiquid({_amount: _amount, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
  }

  function test_WhenTheMigrationParametersVary(
    uint128 _amount,
    uint128 _initialPaidBasis,
    address _recipient,
    address _caller
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheConversionFitsWithinTheMigrationBudget
  {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _initialPaidBasis = uint128(bound(_initialPaidBasis, 0, _BUDGET_BASIS - 1));
    _amount = uint128(bound(_amount, 1, _BUDGET_BASIS));

    /// @dev Seed prior migration accounting
    stdstore.target(address(_migration)).sig(IMigration.paidBasis.selector).checked_write(_initialPaidBasis);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should transfer the deposited amount from the caller
    _mockAndExpect(
      _v2Token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_migration), uint256(_amount))), abi.encode(true)
    );
    // it should approve the v2 voting escrow to spend the deposited amount
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    // it should increase the migration veNFT amount by the deposited amount
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    // it should transfer the conversion output to the recipient as liquid tokens
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (_recipient, uint256(_amount))), abi.encode(true));
    // it should emit the LiquidMigrated event
    _expectEmit(address(_migration));
    emit IMigration.LiquidMigrated({_depositor: _caller, _recipient: _recipient, _amountIn: _amount, _out: _amount});

    vm.prank(_caller);
    _migration.depositLiquid({_amount: _amount, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _initialPaidBasis + _amount);
  }

  function testGas_depositLiquid()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheConversionFitsWithinTheMigrationBudget
  {
    uint128 _amount = 100 ether;
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    _mockAndExpect(
      _v2Token,
      abi.encodeCall(IERC20.transferFrom, (users.alice, address(_migration), uint256(_amount))),
      abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (users.bob, uint256(_amount))), abi.encode(true));

    vm.prank(users.alice);
    _migration.depositLiquid({_amount: _amount, _recipient: users.bob});
    vm.snapshotGasLastCall('AerodromeMigration_depositLiquid');
  }
}
