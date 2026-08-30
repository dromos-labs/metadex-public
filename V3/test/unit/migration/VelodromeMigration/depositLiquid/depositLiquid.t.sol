// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {MockMigrationMailbox} from 'V3-test/mocks/MockMigrationMailbox.sol';
import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationDepositLiquid is UnitVelodromeMigration {
  using stdStorage for StdStorage;

  uint256 internal constant _RATIO_PIPS = 55_000;
  uint256 internal constant _DISPATCH_GAS_LIMIT = 500_000;
  uint256 internal constant _MESSAGE_FEE = 0.01 ether;

  MockMigrationMailbox internal _mockMailbox;

  function setUp() public override {
    super.setUp();

    _mockMailbox = new MockMigrationMailbox(_MESSAGE_FEE);
    _mailbox = address(_mockMailbox);
    _migration = new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
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

  function test_WhenTheMigrationHasNotOpened(
    uint256 _amount,
    address _recipient,
    address _caller,
    uint256 _timestamp
  ) external whenTheMigrationIsNotPaused {
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
  ) external whenTheMigrationIsNotPaused whenTheMigrationHasOpened {
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
  ) external whenTheMigrationIsNotPaused whenTheMigrationHasOpened whenTheDepositedAmountIsNotZero {
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

  function test_WhenTheTOKENConversionOutputIsZero(
    uint256 _amount,
    address _recipient,
    address _caller
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
  {
    _amount = bound(_amount, 1, (MAX_PIPS - 1) / _RATIO_PIPS);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);

    // it should revert with ZeroConversion
    vm.expectRevert(IVelodromeMigration.ZeroConversion.selector);
    vm.prank(_caller);
    _migration.depositLiquid({_amount: _amount, _recipient: _recipient});
  }

  modifier whenTheTOKENConversionOutputIsNotZero() {
    _;
  }

  function test_WhenTheCallerReentersDepositLiquidDuringTheNativeTokenRefund(
    uint128 _amount,
    address _recipient
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheTOKENConversionOutputIsNotZero
  {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _assumeFuzzable(_recipient);
    uint256 _value = _MESSAGE_FEE * 2;
    vm.deal(address(this), _value);

    ReentrantLiquidDepositor _depositor = new ReentrantLiquidDepositor(_migration);

    _mockAndExpect(
      _v2Token,
      abi.encodeCall(IERC20.transferFrom, (address(_depositor), address(_migration), uint256(_amount))),
      abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    _mockAndExpectLiquidDispatch(_recipient, _tokenAmount, _value, address(_depositor));

    // it should revert the reentrant deposit with ReentrancyGuardReentrantCall
    vm.expectRevert(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    _depositor.depositLiquid{value: _value}(_amount, _recipient);
  }

  modifier whenTheCallerDoesNotReenterDuringTheNativeTokenRefund() {
    _;
  }

  function test_WhenTheMigrationParametersAreKnown()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheTOKENConversionOutputIsNotZero
    whenTheCallerDoesNotReenterDuringTheNativeTokenRefund
  {
    uint128 _amount = 10_000 ether;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    // it should capture the deposited amount in the migration veNFT
    _mockAndExpect(
      _v2Token,
      abi.encodeCall(IERC20.transferFrom, (users.alice, address(_migration), uint256(_amount))),
      abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    /// @dev Independently calculated TOKEN output for a 10,000 ether basis amount
    uint256 _tokenAmount = 550 ether;
    // it should dispatch the incremented nonce and liquid settlement parameters to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectLiquidDispatch(users.bob, _tokenAmount, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the LiquidMigrated event
    _expectEmit(address(_migration));
    emit IMigration.LiquidMigrated({
      _depositor: users.alice, _recipient: users.bob, _amountIn: _amount, _out: _tokenAmount
    });

    vm.prank(users.alice);
    _migration.depositLiquid{value: _value}({_amount: _amount, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function test_WhenTheMigrationParametersVary(
    uint128 _amount,
    uint128 _initialPaidBasis,
    address _recipient,
    address _caller,
    uint96 _value
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheTOKENConversionOutputIsNotZero
    whenTheCallerDoesNotReenterDuringTheNativeTokenRefund
  {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    /// @dev Restrict the caller to an EOA that can receive the mocked native-token refund
    vm.assume(_caller.code.length == 0);
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _value = uint96(bound(_value, _MESSAGE_FEE, type(uint96).max));
    vm.deal(_caller, _value);
    uint256 _callerBalance = _caller.balance;

    /// @dev Seed prior migration accounting
    stdstore.target(address(_migration)).sig(IMigration.paidBasis.selector).checked_write(_initialPaidBasis);

    // it should capture the deposited amount in the migration veNFT
    _mockAndExpect(
      _v2Token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_migration), uint256(_amount))), abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    // it should dispatch the incremented nonce and liquid settlement parameters to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectLiquidDispatch(_recipient, _tokenAmount, _value, _caller);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: _recipient});
    // it should emit the LiquidMigrated event
    _expectEmit(address(_migration));
    emit IMigration.LiquidMigrated({
      _depositor: _caller, _recipient: _recipient, _amountIn: _amount, _out: _tokenAmount
    });

    vm.prank(_caller);
    _migration.depositLiquid{value: _value}({_amount: _amount, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), uint256(_initialPaidBasis) + _amount);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(_caller.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function testGas_depositLiquid()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheDepositedAmountIsNotZero
    whenTheRecipientIsNotTheZeroAddress
    whenTheTOKENConversionOutputIsNotZero
  {
    uint128 _amount = 100 ether;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);

    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;

    _mockAndExpect(
      _v2Token,
      abi.encodeCall(IERC20.transferFrom, (users.alice, address(_migration), uint256(_amount))),
      abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, uint256(_amount))), ''
    );
    _mockAndExpectLiquidDispatch(users.bob, _tokenAmount, _value, users.alice);

    vm.prank(users.alice);
    _migration.depositLiquid{value: _value}({_amount: _amount, _recipient: users.bob});
    vm.snapshotGasLastCall('VelodromeMigration_depositLiquid');
  }

  /// @dev Mocks and expects a liquid migration settlement dispatch
  function _mockAndExpectLiquidDispatch(
    address _recipient,
    uint256 _tokenAmount,
    uint256 _value,
    address _refundRecipient
  ) internal {
    bytes memory _body = _encodeMigrationMessage(uint64(1), _recipient, _tokenAmount, true, false, uint48(0));
    bytes memory _calldata = abi.encodeWithSignature(
      'dispatch(uint32,bytes32,bytes,bytes)',
      _ROOT_DOMAIN,
      TypeCasts.addressToBytes32(address(_migration)),
      _body,
      StandardHookMetadata.format(0, _DISPATCH_GAS_LIMIT, _refundRecipient)
    );
    vm.expectCall(_mailbox, _value, _calldata);
  }
}

contract ReentrantLiquidDepositor {
  IMigration internal immutable _MIGRATION;

  uint256 internal _amount;
  address internal _recipient;

  constructor(IMigration _migration) {
    _MIGRATION = _migration;
  }

  function depositLiquid(uint256 _depositAmount, address _depositRecipient) external payable {
    _amount = _depositAmount;
    _recipient = _depositRecipient;
    _MIGRATION.depositLiquid{value: msg.value}({_amount: _depositAmount, _recipient: _depositRecipient});
  }

  receive() external payable {
    _MIGRATION.depositLiquid{value: msg.value}({_amount: _amount, _recipient: _recipient});
  }
}
