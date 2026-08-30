// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationPreviewConversion is UnitAerodromeMigration {
  function setUp() public override {
    super.setUp();

    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenTheV2LockIsPermanent(uint256 _tokenId, uint128 _amount) external {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, 0, _BUDGET_BASIS));
    vm.warp(_migrationOpen);

    _mockV2Lock(_tokenId, _amount, 0, true);

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the v2 token amount as the converted v3 token amount
    assertEq(_out, _amount);
    // it should indicate the v2 lock is permanent
    assertTrue(_isPermanent);
    // it should indicate the conversion does not settle as liquid tokens
    assertFalse(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    if (_amountToMigrate > 0 && _out > 0) {
      _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid);
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

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the v2 token amount as the converted v3 token amount
    assertEq(_out, _amount);
    // it should indicate the v2 lock is not permanent
    assertFalse(_isPermanent);
    // it should indicate the conversion settles as liquid tokens
    assertTrue(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    if (_amountToMigrate > 0 && _out > 0) {
      _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid);
    }
  }

  function test_WhenTheV2LockIsActive(
    uint256 _tokenId,
    uint128 _amount,
    uint256 _end
  ) external whenTheV2LockIsNotPermanent {
    _tokenId = bound(_tokenId, _MIGRATION_TOKEN_ID + 1, type(uint256).max);
    _amount = uint128(bound(_amount, 0, _BUDGET_BASIS));
    vm.warp(_migrationOpen);
    _end = ProtocolTimeLibrary.epochStart(bound(_end, block.timestamp + WEEK, block.timestamp + MAX_TIME));

    _mockV2Lock(_tokenId, _amount, _end, false);

    (uint256 _amountToMigrate, uint256 _out, bool _isPermanent, bool _isLiquid) = _migration.previewConversion(_tokenId);

    // it should return the amount to be migrated from the v2 veNFT
    assertEq(_amountToMigrate, _amount);
    // it should return the v2 token amount as the converted v3 token amount
    assertEq(_out, _amount);
    // it should indicate the v2 lock is not permanent
    assertFalse(_isPermanent);
    // it should indicate the conversion does not settle as liquid tokens
    assertFalse(_isLiquid);
    // it should return the conversion parameters used by depositVeNFT
    if (_amountToMigrate > 0 && _out > 0) {
      _assertDepositVeNFT(_tokenId, _amountToMigrate, _out, _isPermanent, _isLiquid);
    }
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
    bool _isLiquid
  ) internal {
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.escrowType, (_tokenId)), abi.encode(IV2VotingEscrow.EscrowType.NORMAL)
    );
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.voted, (_tokenId)), abi.encode(false));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.ownerOf, (_tokenId)), abi.encode(users.alice));
    if (_isPermanent) _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.unlockPermanent, (_tokenId)), '');
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.merge, (_tokenId, _MIGRATION_TOKEN_ID)), '');

    _mockAndExpectTokenBalance(_v3Token, address(_migration), _BUDGET_BASIS);

    if (_isLiquid) {
      _mockAndExpectTokenTransfer(_v3Token, users.bob, _out);
    } else {
      uint256 _stakedTokenId = 42;
      _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, _out)), abi.encode(true));
      vm.mockCall(_v3Escrow, abi.encodeWithSelector(IVotingEscrow.createStake.selector), abi.encode(_stakedTokenId));
      _mockAndExpect(
        _v3Escrow,
        abi.encodeWithSignature(
          'safeTransferFrom(address,address,uint256)', address(_migration), users.bob, _stakedTokenId
        ),
        ''
      );
    }

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
    vm.prank(users.alice);
    _migration.depositVeNFT({_tokenId: _tokenId, _recipient: users.bob});
  }
}
