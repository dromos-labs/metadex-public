// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAXTIME, MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {MockMigrationMailbox} from 'V3-test/mocks/MockMigrationMailbox.sol';
import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationDepositVeNFT is UnitVelodromeMigration {
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

  function test_WhenTheMigrationIsPaused(uint256 _tokenId, address _recipient, address _caller) external {
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    stdstore.target(address(_migration)).sig(Pausable.paused.selector).enable_packed_slots().checked_write(true);

    // it should revert with EnforcedPause
    vm.expectRevert(Pausable.EnforcedPause.selector);
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheMigrationIsNotPaused() {
    _;
  }

  function test_WhenTheMigrationHasNotOpened(
    uint256 _tokenId,
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
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheMigrationHasOpened() {
    vm.warp(_migrationOpen);
    _;
  }

  function test_WhenTheRecipientIsTheZeroAddress(
    uint256 _tokenId,
    address _caller
  ) external whenTheMigrationIsNotPaused whenTheMigrationHasOpened {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: address(0)});
  }

  modifier whenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenTheV2VeNFTIsRestricted(
    uint256 _tokenId,
    address _recipient,
    address _caller
  ) external whenTheMigrationIsNotPaused whenTheMigrationHasOpened whenTheRecipientIsNotTheZeroAddress {
    _tokenId = bound(_tokenId, _RESTRICTED_TOKEN_ID_1, _RESTRICTED_TOKEN_ID_2);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);

    // it should revert with Restricted
    vm.expectRevert(abi.encodeWithSelector(IMigration.Restricted.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheV2VeNFTIsNotRestricted() {
    _;
  }

  function test_WhenTheV2VeNFTIsLocked(
    uint256 _tokenId,
    address _recipient,
    address _caller
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.LOCKED)
    );

    // it should revert with NotNormalVeNFT
    vm.expectRevert(abi.encodeWithSelector(IMigration.NotNormalVeNFT.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  function test_WhenTheV2VeNFTIsManaged(
    uint256 _tokenId,
    address _recipient,
    address _caller
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.MANAGED)
    );

    // it should revert with NotNormalVeNFT
    vm.expectRevert(abi.encodeWithSelector(IMigration.NotNormalVeNFT.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheV2VeNFTIsNormal() {
    _;
  }

  function test_WhenTheLockedAmountIsZero(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint256 _end,
    bool _isPermanent
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _end = !_isPermanent ? ProtocolTimeLibrary.epochStart(_end) : 0;
    _mockNormalLock(_tokenId, 0, _end, _isPermanent);

    // it should revert with NothingToConvert
    vm.expectRevert(abi.encodeWithSelector(IMigration.NothingToConvert.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheLockedAmountIsNotZero() {
    _;
  }

  function test_WhenTheV2VeNFTHasAnActiveVote(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint128 _amount,
    uint256 _end,
    bool _isPermanent
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    _end = !_isPermanent ? ProtocolTimeLibrary.epochStart(_end) : 0;
    _mockNormalLock(_tokenId, int128(_amount), _end, _isPermanent);
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(true));

    // it should revert with AlreadyVoted
    vm.expectRevert(abi.encodeWithSelector(IMigration.AlreadyVoted.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheV2VeNFTDoesNotHaveAnActiveVote() {
    _;
  }

  function test_WhenTheCallerDoesNotOwnTheV2VeNFT(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    address _veNFTOwner,
    uint128 _amount,
    uint256 _end,
    bool _isPermanent
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _caller = _boundNotEq(_caller, _veNFTOwner);
    _assumeFuzzable(_caller);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    _end = !_isPermanent ? ProtocolTimeLibrary.epochStart(_end) : 0;
    _mockNormalLock(_tokenId, int128(_amount), _end, _isPermanent);
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(false));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.ownerOf, (_tokenId)), abi.encode(_veNFTOwner));

    // it should revert with NotOwner
    vm.expectRevert(abi.encodeWithSelector(IMigration.NotOwner.selector, _tokenId));
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheCallerOwnsTheV2VeNFT() {
    _;
  }

  function test_WhenTheTOKENConversionOutputIsZero(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint128 _amount
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _amount = uint128(bound(_amount, 1, (MAX_PIPS - 1) / _RATIO_PIPS));
    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), 0, false);
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');

    // it should revert with ZeroConversion
    vm.expectRevert(IVelodromeMigration.ZeroConversion.selector);
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheTOKENConversionOutputIsNotZero() {
    _;
  }

  modifier whenTheV2LockIsPermanent() {
    _;
  }

  function test_WhenTheV2LockIsPermanent(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint128 _amount,
    uint96 _value
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    /// @dev Restrict the caller to an EOA that can receive the mocked native-token refund
    vm.assume(_caller.code.length == 0);
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    uint128 _initialPaidBasis = uint128(_BUDGET_BASIS / 10);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _value = uint96(bound(_value, _MESSAGE_FEE, type(uint96).max));
    vm.deal(_caller, _value);
    uint256 _callerBalance = _caller.balance;

    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), 0, true);

    /// @dev Seed prior migration accounting
    stdstore.target(address(_migration)).sig(IMigration.paidBasis.selector).checked_write(_initialPaidBasis);

    // it should unlock the permanent v2 veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    // it should dispatch the incremented nonce and permanent settlement parameters to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(_recipient, _tokenAmount, false, true, 0, _value, _caller);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: _recipient});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: _caller,
      _recipient: _recipient,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: true,
      _liquid: false
    });

    vm.prank(_caller);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _initialPaidBasis + _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), _caller);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(_caller.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  modifier whenTheV2LockIsNotPermanent() {
    _;
  }

  modifier whenTheV2LockHasExpired() {
    _;
  }

  function test_WhenTheV2LockHasExpired(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint128 _amount,
    uint256 _end,
    uint96 _value
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    /// @dev Restrict the caller to an EOA that can receive the mocked native-token refund
    vm.assume(_caller.code.length == 0);
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _end = ProtocolTimeLibrary.epochStart(bound(_end, 0, block.timestamp));
    _value = uint96(bound(_value, _MESSAGE_FEE, type(uint96).max));
    vm.deal(_caller, _value);
    uint256 _callerBalance = _caller.balance;

    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    // it should dispatch the incremented nonce and liquid settlement parameters to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(_recipient, _tokenAmount, true, false, 0, _value, _caller);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: _recipient});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: _caller,
      _recipient: _recipient,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: true
    });

    vm.prank(_caller);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), _caller);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(_caller.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  modifier whenTheV2LockIsActive() {
    _;
  }

  modifier whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration() {
    _;
  }

  function test_WhenTheMigrationParametersAreKnown()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 10_000 ether;
    uint48 _stakingWeeks = 156;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    vm.warp(block.timestamp + 1 days);
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    /// @dev Independently calculated TOKEN output for a 10,000 ether basis amount
    uint256 _tokenAmount = 550 ether;
    // it should dispatch the incremented nonce and decay settlement parameters with the remaining duration rounded up to weeks to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _stakingWeeks, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function test_WhenTheMigrationParametersVary(
    uint256 _tokenId,
    uint128 _amount,
    uint48 _stakingWeeks,
    uint48 _offset,
    uint96 _value
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    _value = uint96(bound(_value, _MESSAGE_FEE, type(uint96).max));
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _maxStakingWeeks - 1));
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    // it should dispatch the incremented nonce and decay settlement parameters with the remaining duration rounded up to weeks to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _stakingWeeks, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  modifier whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration() {
    _;
  }

  modifier whenTheMigrationParametersAreKnown_() {
    _;
  }

  function test_WhenMigrationOccursDuringTheFirstThreeDaysOfTheEpoch()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
    whenTheMigrationParametersAreKnown_
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 100 ether;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    /// @dev Migrate during the first three days of the epoch so the maximum v3 stake duration is 208 weeks
    uint48 _offset = 3 days - 1;
    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maxStakingWeeks, 208);

    uint48 _stakingWeeks = _maxStakingWeeks + 52;
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;
    // it should dispatch the incremented nonce and decay settlement parameters with the maximum duration to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _maxStakingWeeks, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function test_WhenMigrationOccursDuringTheFinalFourDaysOfTheEpoch()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
    whenTheMigrationParametersAreKnown_
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 2;
    uint128 _amount = 100 ether;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    /// @dev Migrate during the final four days of the epoch so the maximum v3 stake duration is 209 weeks
    uint48 _offset = 3 days;
    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maxStakingWeeks, 209);

    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_maxStakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;
    // it should dispatch the incremented nonce and decay settlement parameters with the maximum duration to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _maxStakingWeeks, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function test_WhenTheMigrationParametersVary_(
    uint256 _tokenId,
    uint128 _amount,
    uint48 _stakingWeeks,
    uint48 _offset
  )
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, uint128(type(int128).max)));
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint256 _callerBalance = users.alice.balance;

    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    _stakingWeeks = uint48(bound(_stakingWeeks, _maxStakingWeeks, type(uint48).max));
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should convert the basis output to TOKEN at the configured ratio, rounding down
    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    // it should dispatch the incremented nonce and decay settlement parameters with the maximum duration to the migration entrypoint on root
    // it should forward the native tokens to the Hyperlane mailbox
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _maxStakingWeeks, _value, users.alice);
    // it should emit the MessageDispatched event
    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _tokenAmount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
    // it should increment the dispatch nonce
    assertEq(_migration.dispatchNonce(), 1);
    // it should refund surplus native tokens to the caller
    assertEq(users.alice.balance, _callerBalance - _MESSAGE_FEE);
    assertEq(_mailbox.balance, _MESSAGE_FEE);
  }

  function testGas_depositVeNFT_permanent()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsPermanent
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 100 ether;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);
    uint64 _expectedNonce = 1;

    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), 0, true);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;
    _mockAndExpectVeNFTDispatch(_expectedNonce, users.bob, _tokenAmount, false, true, 0, _value, users.alice);

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('VelodromeMigration_depositVeNFT_permanent');
  }

  function testGas_depositVeNFT_nonPermanent_active()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 10_000 ether;
    uint48 _stakingWeeks = 156;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);

    vm.warp(block.timestamp + 1 days);
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    /// @dev Independently calculated TOKEN output for a 10,000 ether basis amount
    uint256 _tokenAmount = 550 ether;
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, false, false, _stakingWeeks, _value, users.alice);

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('VelodromeMigration_depositVeNFT_nonPermanent_active');
  }

  function testGas_depositVeNFT_nonPermanent_expired()
    external
    whenTheMigrationIsNotPaused
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheTOKENConversionOutputIsNotZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockHasExpired
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 100 ether;
    uint256 _end = block.timestamp;
    uint256 _value = 1 ether;
    vm.deal(users.alice, _value);

    vm.warp(block.timestamp + WEEK);
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;
    _mockAndExpectVeNFTDispatch(users.bob, _tokenAmount, true, false, 0, _value, users.alice);

    vm.prank(users.alice);
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('VelodromeMigration_depositVeNFT_nonPermanent_expired');
  }

  /// @dev Bounds a fuzzed token identifier above the restricted and migration veNFT identifiers
  function _boundUnrestrictedTokenId(uint256 _tokenId) internal pure returns (uint256) {
    return bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
  }

  /// @dev Mocks a normal v2 veNFT and its locked balance
  function _mockNormalLock(uint256 _tokenId, int128 _amount, uint256 _end, bool _isPermanent) internal {
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.NORMAL)
    );
    _mockAndExpect(
      _v2Escrow,
      abi.encodeCall(IV2VotingEscrow.locked, (_tokenId)),
      abi.encode(IV2VotingEscrow.LockedBalance({amount: _amount, end: _end, isPermanent: _isPermanent}))
    );
  }

  /// @dev Mocks a normal v2 veNFT owned by the caller without an active vote
  function _mockOwnedNormalVeNFT(
    uint256 _tokenId,
    address _caller,
    int128 _amount,
    uint256 _end,
    bool _isPermanent
  ) internal {
    _mockNormalLock(_tokenId, _amount, _end, _isPermanent);
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(false));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.ownerOf, (_tokenId)), abi.encode(_caller));
  }

  /// @dev Mocks and expects a v2 veNFT migration settlement dispatch
  function _mockAndExpectVeNFTDispatch(
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks,
    uint256 _value,
    address _refundRecipient
  ) internal {
    _mockAndExpectVeNFTDispatch(
      1, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks, _value, _refundRecipient
    );
  }

  /// @dev Mocks and expects a v2 veNFT migration settlement dispatch with the provided nonce
  function _mockAndExpectVeNFTDispatch(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks,
    uint256 _value,
    address _refundRecipient
  ) internal {
    bytes memory _body =
      _encodeMigrationMessage(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);
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
