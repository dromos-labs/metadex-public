// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAXTIME, MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {MockMigrationMailbox} from 'V3-test/mocks/MockMigrationMailbox.sol';
import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationQuoteDepositVeNFT is UnitVelodromeMigration {
  using stdStorage for StdStorage;

  uint256 internal constant _RATIO_PIPS = 55_000;
  uint256 internal constant _DISPATCH_GAS_LIMIT = 500_000;
  uint256 internal constant _MESSAGE_FEE = 0.01 ether;

  function setUp() public override {
    super.setUp();

    _mailbox = address(new MockMigrationMailbox(_MESSAGE_FEE));
    _migration = new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheFinalTOKENAmountRoundsDownToZero(uint256 _tokenId, uint128 _amount) external {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, 1, (MAX_PIPS - 1) / _RATIO_PIPS));

    _mockV2Lock(_tokenId, _amount, 0, true);

    // it should revert with ZeroConversion
    vm.expectRevert(IVelodromeMigration.ZeroConversion.selector);
    _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: users.bob});
  }

  modifier whenTheFinalTOKENAmountDoesNotRoundDownToZero() {
    _;
  }

  function test_WhenTheV2LockIsPermanent(
    uint256 _tokenId,
    uint128 _amount,
    uint64 _initialNonce,
    address _recipient,
    address _caller
  ) external whenTheFinalTOKENAmountDoesNotRoundDownToZero {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, _minimumAmount, _BUDGET_BASIS));
    _initialNonce = uint64(bound(_initialNonce, 0, type(uint64).max - 1));
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    vm.warp(_migrationOpen);

    stdstore.target(address(_migration)).sig(IVelodromeMigration.dispatchNonce.selector).checked_write(_initialNonce);
    _mockV2Lock(_tokenId, _amount, 0, true);

    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    uint64 _nextNonce = _initialNonce + 1;

    // it should quote the next nonce and permanent settlement parameters for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({
      _nonce: _nextNonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: true,
      _durationWeeks: 0,
      _refundRecipient: _caller
    });

    vm.prank(_caller);
    uint256 _fee = _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: _recipient});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), _initialNonce);
    // it should encode the same message as depositVeNFT
    _assertDepositVeNFT({
      _tokenId: _tokenId,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: true,
      _durationWeeks: 0,
      _nonce: _nextNonce,
      _caller: _caller
    });
  }

  modifier whenTheV2LockIsNotPermanent() {
    _;
  }

  function test_WhenTheV2LockHasExpired(
    uint256 _tokenId,
    uint128 _amount
  ) external whenTheFinalTOKENAmountDoesNotRoundDownToZero whenTheV2LockIsNotPermanent {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, _minimumAmount, _BUDGET_BASIS));
    vm.warp(_migrationOpen);

    _mockV2Lock(_tokenId, _amount, block.timestamp, false);

    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;

    // it should quote the next nonce and liquid settlement parameters for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({
      _nonce: 1,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: true,
      _isPermanent: false,
      _durationWeeks: 0,
      _refundRecipient: users.alice
    });

    vm.prank(users.alice);
    uint256 _fee = _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), 0);
    // it should encode the same message as depositVeNFT
    _assertDepositVeNFT({
      _tokenId: _tokenId,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: true,
      _isPermanent: false,
      _durationWeeks: 0,
      _nonce: 1,
      _caller: users.alice
    });
  }

  modifier whenTheV2LockIsActive() {
    _;
  }

  function test_WhenTheRoundedDurationIsBelowTheMaximumV3StakeDuration(
    uint256 _tokenId,
    uint128 _amount,
    uint48 _stakingWeeks
  ) external whenTheFinalTOKENAmountDoesNotRoundDownToZero whenTheV2LockIsNotPermanent whenTheV2LockIsActive {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, _minimumAmount, _BUDGET_BASIS));
    vm.warp(_migrationOpen + 1 days);

    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _maximumDurationWeeks - 1));
    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_stakingWeeks) * WEEK;

    _mockV2Lock(_tokenId, _amount, _end, false);

    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;

    // it should quote the next nonce and decay settlement parameters with the remaining duration rounded up to weeks for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({
      _nonce: 1,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _stakingWeeks,
      _refundRecipient: users.alice
    });

    vm.prank(users.alice);
    uint256 _fee = _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), 0);
    // it should encode the same message as depositVeNFT
    _assertDepositVeNFT({
      _tokenId: _tokenId,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _stakingWeeks,
      _nonce: 1,
      _caller: users.alice
    });
  }

  modifier whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration() {
    _;
  }

  function test_WhenMigrationOccursDuringTheFirstThreeDaysOfTheEpoch()
    external
    whenTheFinalTOKENAmountDoesNotRoundDownToZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 1;
    uint128 _amount = 100 ether;
    vm.warp(_migrationOpen + 3 days - 1);

    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maximumDurationWeeks, 208);

    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_maximumDurationWeeks + 52) * WEEK;
    _mockV2Lock(_tokenId, _amount, _end, false);

    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;

    // it should quote the next nonce and decay settlement parameters with a 208 week maximum duration for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({
      _nonce: 1,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: 208,
      _refundRecipient: users.alice
    });

    vm.prank(users.alice);
    uint256 _fee = _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), 0);
    // it should encode the same message as depositVeNFT
    _assertDepositVeNFT({
      _tokenId: _tokenId,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: 208,
      _nonce: 1,
      _caller: users.alice
    });
  }

  function test_WhenMigrationOccursDuringTheFinalFourDaysOfTheEpoch()
    external
    whenTheFinalTOKENAmountDoesNotRoundDownToZero
    whenTheV2LockIsNotPermanent
    whenTheV2LockIsActive
    whenTheRoundedDurationReachesOrExceedsTheMaximumV3StakeDuration
  {
    uint256 _tokenId = _MIGRATION_TOKEN_ID + 2;
    uint128 _amount = 100 ether;
    vm.warp(_migrationOpen + 3 days);

    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maximumDurationWeeks, 209);

    uint256 _end = ProtocolTimeLibrary.epochStart(block.timestamp) + uint256(_maximumDurationWeeks) * WEEK;
    _mockV2Lock(_tokenId, _amount, _end, false);

    /// @dev Independently calculated TOKEN output for a 100 ether basis amount
    uint256 _tokenAmount = 5.5 ether;

    // it should quote the next nonce and decay settlement parameters with a 209 week maximum duration for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({
      _nonce: 1,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: 209,
      _refundRecipient: users.alice
    });

    vm.prank(users.alice);
    uint256 _fee = _migration.quoteDepositVeNFT({_tokenId: _tokenId, _recipient: users.bob});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), 0);
    // it should encode the same message as depositVeNFT
    _assertDepositVeNFT({
      _tokenId: _tokenId,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: 209,
      _nonce: 1,
      _caller: users.alice
    });
  }

  /// @dev Mocks the locked state for a v2 veNFT
  function _mockV2Lock(uint256 _tokenId, uint128 _amount, uint256 _end, bool _isPermanent) internal {
    _mockAndExpect(
      _v2Escrow,
      abi.encodeCall(IV2VotingEscrow.locked, (_tokenId)),
      abi.encode(IV2VotingEscrow.LockedBalance({amount: int128(_amount), end: _end, isPermanent: _isPermanent}))
    );
  }

  /// @dev Expects a v2 veNFT migration settlement quote
  function _expectQuote(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks,
    address _refundRecipient
  ) internal {
    bytes memory _body = _encodeMigrationMessage(
      _nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks
    );
    bytes memory _calldata = abi.encodeCall(
      MockMigrationMailbox.quoteDispatch,
      (
        _ROOT_DOMAIN,
        TypeCasts.addressToBytes32(address(_migration)),
        _body,
        StandardHookMetadata.format(0, _DISPATCH_GAS_LIMIT, _refundRecipient)
      )
    );
    vm.expectCall(_mailbox, _calldata);
  }

  /// @dev Asserts depositVeNFT dispatches the message used by the quote
  function _assertDepositVeNFT(
    uint256 _tokenId,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks,
    uint64 _nonce,
    address _caller
  ) internal {
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.NORMAL)
    );
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(false));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.ownerOf, (_tokenId)), abi.encode(_caller));
    if (_isPermanent) _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');
    _expectDispatch(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks, _caller);

    vm.deal(_caller, _MESSAGE_FEE);
    vm.prank(_caller);
    _migration.depositVeNFT{value: _MESSAGE_FEE}({_tokenId: _tokenId, _recipient: _recipient});
  }

  /// @dev Expects a v2 veNFT migration settlement dispatch
  function _expectDispatch(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks,
    address _refundRecipient
  ) internal {
    bytes memory _body = _encodeMigrationMessage(
      _nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks
    );
    bytes memory _calldata = abi.encodeCall(
      MockMigrationMailbox.dispatch,
      (
        _ROOT_DOMAIN,
        TypeCasts.addressToBytes32(address(_migration)),
        _body,
        StandardHookMetadata.format(0, _DISPATCH_GAS_LIMIT, _refundRecipient)
      )
    );
    vm.expectCall(_mailbox, _MESSAGE_FEE, _calldata);
  }
}
