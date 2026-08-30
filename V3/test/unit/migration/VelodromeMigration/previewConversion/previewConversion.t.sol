// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';

import {MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {MockMigrationMailbox} from 'V3-test/mocks/MockMigrationMailbox.sol';
import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationPreviewConversion is UnitVelodromeMigration {
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

  function test_WhenTheV2LockIsPermanent(uint256 _tokenId, uint128 _amount) external {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, 0, _BUDGET_BASIS));
    vm.warp(_migrationOpen);

    _mockV2Lock(_tokenId, _amount, 0, true);

    uint256 _expectedOut = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the ratio-adjusted v3 token amount
    assertEq(_out, _expectedOut);
    // it should indicate the v2 lock is permanent
    assertTrue(_isPermanent);
    // it should indicate the conversion does not settle as liquid tokens
    assertFalse(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    if (_amountToMigrate > 0 && _out > 0) {
      _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid, 0);
    }
  }

  modifier whenTheV2LockIsNotPermanent() {
    _;
  }

  function test_WhenTheV2LockHasExpired(
    uint256 _tokenId,
    uint128 _amount,
    uint256 _end
  ) external whenTheV2LockIsNotPermanent {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, 0, _BUDGET_BASIS));
    vm.warp(_migrationOpen);
    _end = ProtocolTimeLibrary.epochStart(bound(_end, 0, block.timestamp));

    _mockV2Lock(_tokenId, _amount, _end, false);

    /// @dev Convert the v2 amount to TOKEN at the configured ratio, rounded down
    uint256 _expectedOut = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the ratio-adjusted v3 token amount
    assertEq(_out, _expectedOut);
    // it should indicate the v2 lock is not permanent
    assertFalse(_isPermanent);
    // it should indicate the conversion settles as liquid tokens
    assertTrue(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    if (_amountToMigrate > 0 && _out > 0) {
      _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid, 0);
    }
  }

  modifier whenTheV2LockIsActive() {
    _;
  }

  function test_WhenTheFinalV3TokenAmountRoundsDownToZero(
    uint256 _tokenId,
    uint128 _amount,
    uint256 _end
  ) external whenTheV2LockIsNotPermanent whenTheV2LockIsActive {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    /// @dev Keep the positive basis output below the minimum amount that converts to one TOKEN wei
    _amount = uint128(bound(_amount, 1, (MAX_PIPS - 1) / _RATIO_PIPS));
    vm.warp(_migrationOpen);
    _end = ProtocolTimeLibrary.epochStart(bound(_end, block.timestamp + WEEK, block.timestamp + MAX_TIME));

    _mockV2Lock(_tokenId, _amount, _end, false);

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return zero as the converted v3 token amount
    assertEq(_out, 0);
    // it should indicate the v2 lock is not permanent
    assertFalse(_isPermanent);
    // it should indicate the conversion does not settle as liquid tokens
    assertFalse(_isLiquid);
  }

  function test_WhenTheFinalV3TokenAmountDoesNotRoundDownToZero(
    uint256 _tokenId,
    uint128 _amount,
    uint256 _end
  ) external whenTheV2LockIsNotPermanent whenTheV2LockIsActive {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);

    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, _minimumAmount, _BUDGET_BASIS));
    vm.warp(_migrationOpen);
    _end = ProtocolTimeLibrary.epochStart(bound(_end, block.timestamp + WEEK, block.timestamp + MAX_TIME));

    _mockV2Lock(_tokenId, _amount, _end, false);

    /// @dev Convert the v2 amount to TOKEN at the configured ratio, rounded down
    uint256 _expectedOut = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the ratio-adjusted v3 token amount
    assertEq(_out, _expectedOut);
    // it should indicate the v2 lock is not permanent
    assertFalse(_isPermanent);
    // it should indicate the conversion does not settle as liquid tokens
    assertFalse(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    uint48 _durationWeeks = uint48((_end - block.timestamp) / WEEK);
    _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid, _durationWeeks);
  }

  /// @dev Mocks the locked state for a v2 veNFT
  function _mockV2Lock(uint256 _tokenId, uint128 _amount, uint256 _end, bool _isPermanent) internal {
    _mockAndExpect(
      _v2Escrow,
      abi.encodeCall(IV2VotingEscrow.locked, (_tokenId)),
      abi.encode(IV2VotingEscrow.LockedBalance({amount: int128(_amount), end: _end, isPermanent: _isPermanent}))
    );
  }

  /// @dev Asserts depositVeNFT uses the conversion parameters returned by previewConversion
  function _assertDepositVeNFT(
    uint256 _tokenId,
    uint256 _amount,
    uint256 _out,
    bool _isPermanent,
    bool _isLiquid,
    uint48 _durationWeeks
  ) internal {
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.NORMAL)
    );
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(false));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.ownerOf, (_tokenId)), abi.encode(users.alice));
    if (_isPermanent) _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');

    bytes memory _body = _encodeMigrationMessage(uint64(1), users.bob, _out, _isLiquid, _isPermanent, _durationWeeks);
    bytes memory _calldata = abi.encodeWithSignature(
      'dispatch(uint32,bytes32,bytes,bytes)',
      _ROOT_DOMAIN,
      TypeCasts.addressToBytes32(address(_migration)),
      _body,
      StandardHookMetadata.format(0, _DISPATCH_GAS_LIMIT, users.alice)
    );
    vm.expectCall(_mailbox, _MESSAGE_FEE, _calldata);

    _expectEmit(address(_migration));
    emit IVelodromeMigration.MessageDispatched({_nonce: 1, _recipient: users.bob});
    _expectEmit(address(_migration));
    emit IMigration.VeNFTMigrated({
      _depositor: users.alice,
      _recipient: users.bob,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _out,
      _permanent: _isPermanent,
      _liquid: _isLiquid
    });

    vm.deal(users.alice, _MESSAGE_FEE);
    vm.prank(users.alice);
    _migration.depositVeNFT{value: _MESSAGE_FEE}({_tokenId: _tokenId, _recipient: users.bob});
  }
}
