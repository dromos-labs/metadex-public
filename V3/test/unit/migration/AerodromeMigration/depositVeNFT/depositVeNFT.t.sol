// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationDepositVeNFT is UnitAerodromeMigration {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();

    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
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

  function test_WhenNativeTokensAreSent(
    uint256 _tokenId,
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
    _migration.depositVeNFT{value: _value}({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenNativeTokensAreNotSent() {
    _;
  }

  function test_WhenTheMigrationHasNotOpened(
    uint256 _tokenId,
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
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheMigrationHasOpened() {
    vm.warp(_migrationOpen);
    _;
  }

  function test_WhenTheRecipientIsTheZeroAddress(
    uint256 _tokenId,
    address _caller
  ) external whenTheMigrationIsNotPaused whenNativeTokensAreNotSent whenTheMigrationHasOpened {
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
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
  {
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
    whenNativeTokensAreNotSent
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
    whenNativeTokensAreNotSent
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
    whenNativeTokensAreNotSent
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
    whenNativeTokensAreNotSent
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
    whenNativeTokensAreNotSent
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

  function test_WhenTheConversionExceedsTheMigrationBudget(
    uint256 _tokenId,
    address _recipient,
    address _caller,
    uint128 _amount,
    uint256 _availableBalance,
    uint256 _end,
    bool _isPermanent
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
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
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    _availableBalance = bound(_availableBalance, 0, _amount - 1);
    _end = !_isPermanent ? ProtocolTimeLibrary.epochStart(_end) : 0;
    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), _end, _isPermanent);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _availableBalance);

    // it should revert with BudgetExhausted
    vm.expectRevert(IAerodromeMigration.BudgetExhausted.selector);
    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});
  }

  modifier whenTheConversionFitsWithinTheMigrationBudget() {
    _;
  }

  modifier whenTheV2LockIsPermanent() {
    _;
  }

  function test_WhenTheConversionIsWithinTheMigrationBudget(
    uint256 _tokenId,
    uint256 _stakedTokenId,
    address _recipient,
    address _caller,
    uint128 _amount
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsPermanent
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    uint128 _initialPaidBasis = uint128(_BUDGET_BASIS / 10);
    _amount = uint128(bound(_amount, 1, _BUDGET_BASIS));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);
    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), 0, true);

    /// @dev Seed the initial paid basis
    stdstore.target(address(_migration)).sig(IMigration.paidBasis.selector).checked_write(_initialPaidBasis);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should unlock the permanent v2 veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a permanent v3 staked position
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, uint48(0), true)), abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), _recipient, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: _caller,
      _recipient: _recipient,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: true,
      _liquid: false
    });

    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _initialPaidBasis + _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), _caller);
  }

  function test_WhenTheConversionExactlyExhaustsTheMigrationBudget()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsPermanent
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint256 _nextTokenId = _MIGRATION_TOKEN_ID + 2;
    uint256 _stakedTokenId = 42;
    uint128 _amount = 10_000 ether;
    uint128 _additionalAmount = 100 ether;
    uint128 _initialPaidBasis = 10_000 ether;

    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), 0, true);
    _mockOwnedNormalVeNFT(_nextTokenId, users.alice, int128(_additionalAmount), 0, true);
    stdstore.target(address(_migration)).sig(IMigration.paidBasis.selector).checked_write(_initialPaidBasis);

    /// @dev Set the available TOKEN balance equal to the locked amount
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_migration), [uint256(_amount), 0]);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a permanent v3 staked position with the locked amount
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, uint48(0), true)), abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the locked amount
    assertEq(_migration.paidBasis(), _initialPaidBasis + _amount);

    // it should revert the next conversion with BudgetExhausted
    vm.expectRevert(IAerodromeMigration.BudgetExhausted.selector);
    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _nextTokenId, _recipient: users.bob});
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
    uint256 _end
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockHasExpired
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    _amount = uint128(bound(_amount, 1, _BUDGET_BASIS));
    _end = ProtocolTimeLibrary.epochStart(bound(_end, 0, block.timestamp));
    _mockOwnedNormalVeNFT(_tokenId, _caller, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should transfer the conversion output to the recipient as liquid tokens
    _mockAndExpectTokenTransfer(_v3Token, _recipient, _amount);
    // it should not create a v3 staked position
    vm.expectCall(_v3Escrow, abi.encodeWithSelector(IVotingEscrow.createStake.selector), 0);
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: _caller,
      _recipient: _recipient,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: true
    });

    vm.prank(_caller);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: _recipient});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), _caller);
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
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint256 _stakedTokenId = 42;
    uint128 _amount = 10_000 ether;
    uint48 _stakingWeeks = 156;

    vm.warp(block.timestamp + 1 days);
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a decay v3 staked position with the remaining duration rounded up to weeks
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, _stakingWeeks, false)), abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
  }

  function test_WhenTheMigrationParametersVary(
    uint256 _tokenId,
    uint256 _stakedTokenId,
    uint128 _amount,
    uint48 _stakingWeeks,
    uint48 _offset
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _amount = uint128(bound(_amount, 1, _BUDGET_BASIS));
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _maxStakingWeeks - 1));
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a decay v3 staked position with the remaining duration rounded up to weeks
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, _stakingWeeks, false)), abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
  }

  modifier whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration() {
    _;
  }

  modifier whenTheMigrationParametersAreKnown_() {
    _;
  }

  modifier whenMigrationOccursDuringTheFirstThreeDaysOfTheEpoch() {
    _;
  }

  function test_WhenMigrationOccursDuringTheFirstThreeDaysOfTheEpoch()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
    whenTheMigrationParametersAreKnown_
    whenMigrationOccursDuringTheFirstThreeDaysOfTheEpoch
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint256 _stakedTokenId = 43;
    uint128 _amount = 100 ether;

    /// @dev Migrate during the first three days of the epoch so the maximum v3 stake duration is 208 weeks
    uint48 _offset = 3 days - 1;
    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maxStakingWeeks, 208);

    uint48 _stakingWeeks = _maxStakingWeeks + 52;
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a decay v3 staked position with the maximum duration
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_amount, _maxStakingWeeks, false)),
      abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
  }

  modifier whenMigrationOccursDuringTheFinalFourDaysOfTheEpoch() {
    _;
  }

  function test_WhenMigrationOccursDuringTheFinalFourDaysOfTheEpoch()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
    whenTheMigrationParametersAreKnown_
    whenMigrationOccursDuringTheFinalFourDaysOfTheEpoch
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 2;
    uint256 _stakedTokenId = 44;
    uint128 _amount = 100 ether;

    /// @dev Migrate during the final four days of the epoch so the maximum v3 stake duration is 209 weeks
    uint48 _offset = 3 days;
    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maxStakingWeeks, 209);

    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_maxStakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a decay v3 staked position with the maximum duration
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_amount, _maxStakingWeeks, false)),
      abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
  }

  function test_WhenTheMigrationParametersVary_(
    uint256 _tokenId,
    uint256 _stakedTokenId,
    uint128 _amount,
    uint48 _stakingWeeks,
    uint48 _offset
  )
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
  {
    _tokenId = _boundUnrestrictedTokenId(_tokenId);
    _amount = uint128(bound(_amount, 1, _BUDGET_BASIS));
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    vm.warp(block.timestamp + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maxStakingWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    _stakingWeeks = uint48(bound(_stakingWeeks, _maxStakingWeeks, type(uint48).max));
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    // it should not unlock the v2 veNFT
    vm.expectCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), 0);
    // it should merge the v2 veNFT into the migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    // it should approve the v3 voting escrow to spend the conversion output
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    // it should create a decay v3 staked position with the maximum duration
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_amount, _maxStakingWeeks, false)),
      abi.encode(_stakedTokenId)
    );
    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );
    // it should emit the VeNFTMigrated event
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _amount,
      _permanent: false,
      _liquid: false
    });

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should increase the paid basis by the conversion output
    assertEq(_migration.paidBasis(), _amount);
    // it should record the caller as the depositor
    assertEq(_migration.depositorOf(_tokenId), users.alice);
  }

  function testGas_depositVeNFT_permanent()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsPermanent
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint256 _stakedTokenId = 42;
    uint128 _amount = 100 ether;
    uint256 _end = 0;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, true);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, uint48(0), true)), abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('AerodromeMigration_depositVeNFT_permanent');
  }

  function testGas_depositVeNFT_nonPermanent_expired()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockHasExpired
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 100 ether;
    uint256 _end = block.timestamp;
    vm.warp(block.timestamp + WEEK);
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpectTokenTransfer(_v3Token, users.bob, _amount);

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('AerodromeMigration_depositVeNFT_nonPermanent_expired');
  }

  function testGas_depositVeNFT_nonPermanent_active()
    external
    whenTheMigrationIsNotPaused
    whenNativeTokensAreNotSent
    whenTheMigrationHasOpened
    whenTheRecipientIsNotTheZeroAddress
    whenTheV2VeNFTIsNotRestricted
    whenTheV2VeNFTIsNormal
    whenTheLockedAmountIsNotZero
    whenTheV2VeNFTDoesNotHaveAnActiveVote
    whenTheCallerOwnsTheV2VeNFT
    whenTheConversionFitsWithinTheMigrationBudget
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationIsBelowTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint256 _stakedTokenId = 42;
    uint128 _amount = 10_000 ether;
    uint48 _stakingWeeks = 156;

    vm.warp(block.timestamp + 1 days);
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;
    _mockOwnedNormalVeNFT(_tokenId, users.alice, int128(_amount), _end, false);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_amount))), abi.encode(true));
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_amount, _stakingWeeks, false)), abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow,
      abi.encodeWithSignature(
        'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
      ),
      ''
    );

    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});
    vm.snapshotGasLastCall('AerodromeMigration_depositVeNFT_nonPermanent_active');
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
}
