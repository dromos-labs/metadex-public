// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {MockMigrationMailbox} from 'V3-test/mocks/MockMigrationMailbox.sol';
import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationQuoteDepositLiquid is UnitVelodromeMigration {
  using stdStorage for StdStorage;

  uint256 internal constant _RATIO_PIPS = 55_000;
  uint256 internal constant _DISPATCH_GAS_LIMIT = 500_000;
  uint256 internal constant _MESSAGE_FEE = 0.01 ether;

  function setUp() public override {
    super.setUp();

    _mailbox = address(new MockMigrationMailbox(_MESSAGE_FEE));
    _migration = new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheFinalTOKENAmountRoundsDownToZero(uint256 _amount) external {
    _amount = bound(_amount, 1, (MAX_PIPS - 1) / _RATIO_PIPS);

    // it should revert with ZeroConversion
    vm.expectRevert(IVelodromeMigration.ZeroConversion.selector);
    _migration.quoteDepositLiquid({_amount: _amount, _recipient: users.bob});
  }

  function test_WhenTheFinalTOKENAmountDoesNotRoundDownToZero(
    uint128 _amount,
    uint64 _initialNonce,
    address _recipient,
    address _caller
  ) external {
    uint256 _minimumAmount = _ceilDiv(MAX_PIPS, _RATIO_PIPS);
    _amount = uint128(bound(_amount, _minimumAmount, _BUDGET_BASIS));
    _initialNonce = uint64(bound(_initialNonce, 0, type(uint64).max - 1));
    _assumeFuzzable(_recipient);
    _assumeFuzzable(_caller);
    vm.warp(_migrationOpen);

    stdstore.target(address(_migration)).sig(IVelodromeMigration.dispatchNonce.selector).checked_write(_initialNonce);

    uint256 _tokenAmount = (uint256(_amount) * _RATIO_PIPS) / MAX_PIPS;
    uint64 _nextNonce = _initialNonce + 1;

    // it should quote the next nonce and liquid settlement parameters for the migration entrypoint on root
    // it should use the caller as the Hyperlane refund address
    _expectQuote({_nonce: _nextNonce, _recipient: _recipient, _tokenAmount: _tokenAmount, _refundRecipient: _caller});

    vm.prank(_caller);
    uint256 _fee = _migration.quoteDepositLiquid({_amount: _amount, _recipient: _recipient});

    // it should return the native token dispatch fee
    assertEq(_fee, _MESSAGE_FEE);
    // it should leave the dispatch nonce unchanged
    assertEq(_migration.dispatchNonce(), _initialNonce);
    // it should encode the same message as depositLiquid
    _assertDepositLiquid({
      _amount: _amount, _recipient: _recipient, _tokenAmount: _tokenAmount, _nonce: _nextNonce, _caller: _caller
    });
  }

  /// @dev Expects a liquid migration settlement quote
  function _expectQuote(uint64 _nonce, address _recipient, uint256 _tokenAmount, address _refundRecipient) internal {
    bytes memory _body = _encodeMigrationMessage(_nonce, _recipient, _tokenAmount, true, false, 0);
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

  /// @dev Asserts depositLiquid dispatches the message used by the quote
  function _assertDepositLiquid(
    uint256 _amount,
    address _recipient,
    uint256 _tokenAmount,
    uint64 _nonce,
    address _caller
  ) internal {
    _mockAndExpect(
      _v2Token, abi.encodeCall(IERC20.transferFrom, (_caller, address(_migration), _amount)), abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, _amount)), abi.encode(true));
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.increaseAmount, (_MIGRATION_TOKEN_ID, _amount)), '');
    _expectDispatch(_nonce, _recipient, _tokenAmount, _caller);

    vm.deal(_caller, _MESSAGE_FEE);
    vm.prank(_caller);
    _migration.depositLiquid{value: _MESSAGE_FEE}({_amount: _amount, _recipient: _recipient});
  }

  /// @dev Expects a liquid migration settlement dispatch
  function _expectDispatch(uint64 _nonce, address _recipient, uint256 _tokenAmount, address _refundRecipient) internal {
    bytes memory _body = _encodeMigrationMessage(_nonce, _recipient, _tokenAmount, true, false, 0);
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
