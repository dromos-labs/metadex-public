// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVelodromeMigrationEntrypoint} from 'V3/interfaces/migration/IVelodromeMigrationEntrypoint.sol';

import {
  UnitVelodromeMigrationEntrypoint
} from 'V3-test/unit/migration/VelodromeMigrationEntrypoint/VelodromeMigrationEntrypoint.t.sol';

contract UnitVelodromeMigrationEntrypointHandle is UnitVelodromeMigrationEntrypoint {
  using stdStorage for StdStorage;

  function test_WhenTheCallerIsNotTheHyperlaneMailbox(
    address _caller,
    uint32 _origin,
    bytes32 _sender,
    bytes calldata _body
  ) external {
    _caller = _boundNotEq(_caller, _mailbox);
    _assumeFuzzable(_caller);

    // it should revert with CallerNotMailbox
    vm.expectRevert(IVelodromeMigrationEntrypoint.CallerNotMailbox.selector);
    vm.prank(_caller);
    _entrypoint.handle(_origin, _sender, _body);
  }

  function test_WhenTheOriginIsNotTheOPDomain(uint32 _origin, bytes32 _sender, bytes calldata _body) external {
    vm.assume(_origin != _OP_DOMAIN);

    // it should revert with UnauthorizedOrigin
    vm.expectRevert(IVelodromeMigrationEntrypoint.UnauthorizedOrigin.selector);
    vm.prank(_mailbox);
    _entrypoint.handle(_origin, _sender, _body);
  }

  function test_WhenTheSenderIsNotTheEntrypointContract(bytes32 _sender, bytes calldata _body) external {
    vm.assume(_sender != TypeCasts.addressToBytes32(address(_entrypoint)));

    // it should revert with UnauthorizedSender
    vm.expectRevert(IVelodromeMigrationEntrypoint.UnauthorizedSender.selector);
    vm.prank(_mailbox);
    _entrypoint.handle(_OP_DOMAIN, _sender, _body);
  }

  function test_WhenTheMessageLengthIsInvalid(bytes calldata _body) external {
    vm.assume(_body.length != 68);

    // it should revert with InvalidMessageLength
    vm.expectRevert(IVelodromeMigrationEntrypoint.InvalidMessageLength.selector);
    vm.prank(_mailbox);
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);
  }

  modifier whenTheMessageIsValid() {
    vm.startPrank(_mailbox);
    _;
    vm.stopPrank();
  }

  function test_WhenTheNonceHasAlreadyBeenUsed(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) external whenTheMessageIsValid {
    _isPermanent = !_isLiquid && _isPermanent;
    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.noncesUsed.selector).with_key(_nonce)
      .checked_write(true);
    bytes memory _body =
      _encodeMigrationMessage(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);

    // it should revert with NonceAlreadyUsed
    vm.expectRevert(IVelodromeMigrationEntrypoint.NonceAlreadyUsed.selector);
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);
  }

  modifier whenTheNonceHasNotBeenUsed() {
    _;
  }

  function test_WhenTheTokenAmountExceedsTheRemainingBudget(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    uint256 _availableBalance,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) external whenTheMessageIsValid whenTheNonceHasNotBeenUsed {
    _availableBalance = bound(_availableBalance, 0, type(uint128).max - 1);
    _tokenAmount = bound(_tokenAmount, _availableBalance + 1, type(uint128).max);
    _isPermanent = !_isLiquid && _isPermanent;
    _durationWeeks = _isPermanent ? 0 : _durationWeeks;
    bytes memory _body =
      _encodeMigrationMessage(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _availableBalance);

    // it should revert with BudgetExhausted
    vm.expectRevert(IVelodromeMigrationEntrypoint.BudgetExhausted.selector);
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    assertFalse(_entrypoint.noncesUsed(_nonce));
    assertEq(_entrypoint.paid(), 0);

    /// @dev Simulate a token top-up to unblock the settlement
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _tokenAmount);

    // it should process the same settlement after the entrypoint is topped up
    if (_isLiquid) {
      _mockAndExpectTokenTransfer(_v3Token, _recipient, _tokenAmount);
    } else {
      _expectStakeSettlement({
        _recipient: _recipient, _tokenAmount: _tokenAmount, _isPermanent: _isPermanent, _durationWeeks: _durationWeeks
      });
    }

    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    assertTrue(_entrypoint.noncesUsed(_nonce));
    assertEq(_entrypoint.paid(), _tokenAmount);
  }

  modifier whenTheTokenAmountDoesNotExceedTheRemainingBudget() {
    _;
  }

  modifier whenTheMigrationIsLiquid() {
    _;
  }

  function test_WhenTheTokenAmountExhaustsTheRemainingBudget(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    uint256 _initialPaid
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsLiquid
  {
    _assumeFuzzable(_recipient);
    _tokenAmount = bound(_tokenAmount, 1, type(uint256).max);
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: true,
      _isPermanent: false,
      _durationWeeks: 0
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _tokenAmount);

    // it should transfer the token amount to the recipient
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (_recipient, _tokenAmount)), abi.encode(true));

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: _recipient, _tokenAmount: _tokenAmount, _isLiquid: true
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  function test_WhenTheTokenAmountLeavesRemainingBudget(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    uint256 _initialPaid,
    uint256 _availableBalance
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsLiquid
  {
    _assumeFuzzable(_recipient);
    _availableBalance = bound(_availableBalance, 2, type(uint256).max);
    _tokenAmount = bound(_tokenAmount, 1, _availableBalance - 1);
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: true,
      _isPermanent: false,
      _durationWeeks: 0
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _availableBalance);

    // it should transfer the token amount to the recipient
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (_recipient, _tokenAmount)), abi.encode(true));

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: _recipient, _tokenAmount: _tokenAmount, _isLiquid: true
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  modifier whenTheMigrationIsStaked() {
    _;
  }

  function test_WhenTheStakeIsPermanent(
    address _recipient,
    uint128 _tokenAmount,
    uint256 _initialPaid,
    uint256 _stakedTokenId
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
  {
    uint64 _nonce = 1;
    _assumeFuzzable(_recipient);
    _tokenAmount = uint128(bound(_tokenAmount, 1, _BUDGET));
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);
    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: true,
      _durationWeeks: 0
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);

    // it should approve the v3 voting escrow to spend the token amount
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_tokenAmount))), abi.encode(true));

    // it should create a permanent v3 staked position with zero duration
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IVotingEscrow.createStake, (_tokenAmount, uint48(0), true)), abi.encode(_stakedTokenId)
    );

    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), _recipient, _stakedTokenId)), ''
    );

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: _recipient, _tokenAmount: _tokenAmount, _isLiquid: false
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  modifier whenTheStakeIsNotPermanent() {
    _;
  }

  modifier whenTheDurationExceedsTheMaximumAcceptedAfterDelivery() {
    _;
  }

  function test_WhenSettlementOccursDuringTheFirstThreeDaysOfTheEpoch(
    uint128 _tokenAmount,
    uint256 _initialPaid,
    uint48 _offset,
    uint48 _durationWeeks,
    uint256 _stakedTokenId
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
    whenTheStakeIsNotPermanent
    whenTheDurationExceedsTheMaximumAcceptedAfterDelivery
  {
    uint64 _nonce = 1;
    _tokenAmount = uint128(bound(_tokenAmount, 1, _BUDGET));
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    _offset = uint48(bound(_offset, 0, 3 days - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    /// @dev Settle during the first three days of the epoch so the maximum v3 stake duration is 208 weeks
    vm.warp(WEEK + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maximumDurationWeeks, 208);
    _durationWeeks = uint48(bound(_durationWeeks, _maximumDurationWeeks + 1, type(uint48).max));

    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _durationWeeks
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);

    // it should approve the v3 voting escrow to spend the token amount
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_tokenAmount))), abi.encode(true));

    // it should create a decaying v3 staked position
    // it should clamp the duration to the maximum accepted after delivery
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_tokenAmount, _maximumDurationWeeks, false)),
      abi.encode(_stakedTokenId)
    );

    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), users.bob, _stakedTokenId)), ''
    );

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: users.bob, _tokenAmount: _tokenAmount, _isLiquid: false
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  function test_WhenSettlementOccursDuringTheFinalFourDaysOfTheEpoch(
    uint128 _tokenAmount,
    uint256 _initialPaid,
    uint48 _offset,
    uint48 _durationWeeks,
    uint256 _stakedTokenId
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
    whenTheStakeIsNotPermanent
    whenTheDurationExceedsTheMaximumAcceptedAfterDelivery
  {
    uint64 _nonce = 1;
    _tokenAmount = uint128(bound(_tokenAmount, 1, _BUDGET));
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    _offset = uint48(bound(_offset, 3 days, WEEK - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    /// @dev Settle during the final four days of the epoch so the maximum v3 stake duration is 209 weeks
    vm.warp(WEEK + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertEq(_maximumDurationWeeks, 209);
    _durationWeeks = uint48(bound(_durationWeeks, _maximumDurationWeeks + 1, type(uint48).max));

    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _durationWeeks
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);

    // it should approve the v3 voting escrow to spend the token amount
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_tokenAmount))), abi.encode(true));

    // it should create a decaying v3 staked position
    // it should clamp the duration to the maximum accepted after delivery
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_tokenAmount, _maximumDurationWeeks, false)),
      abi.encode(_stakedTokenId)
    );

    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), users.bob, _stakedTokenId)), ''
    );

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: users.bob, _tokenAmount: _tokenAmount, _isLiquid: false
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  modifier whenTheDurationDoesNotExceedTheMaximumAcceptedAfterDelivery() {
    _;
  }

  function test_WhenTheMaximumAcceptedDurationIsRequested(
    uint128 _tokenAmount,
    uint256 _initialPaid,
    uint48 _offset,
    uint256 _stakedTokenId
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
    whenTheStakeIsNotPermanent
    whenTheDurationDoesNotExceedTheMaximumAcceptedAfterDelivery
  {
    uint64 _nonce = 1;
    _tokenAmount = uint128(bound(_tokenAmount, 1, _BUDGET));
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    vm.warp(WEEK + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertTrue(_maximumDurationWeeks == 208 || _maximumDurationWeeks == 209);

    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _maximumDurationWeeks
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);

    // it should leave the duration unchanged
    // it should approve the v3 voting escrow to spend the token amount
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_tokenAmount))), abi.encode(true));

    // it should create a decaying v3 staked position
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_tokenAmount, _maximumDurationWeeks, false)),
      abi.encode(_stakedTokenId)
    );

    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), users.bob, _stakedTokenId)), ''
    );

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: users.bob, _tokenAmount: _tokenAmount, _isLiquid: false
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  function test_WhenTheDurationIsBelowTheMaximumAcceptedAfterDelivery(
    uint128 _tokenAmount,
    uint256 _initialPaid,
    uint48 _offset,
    uint48 _durationWeeks,
    uint256 _stakedTokenId
  )
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
    whenTheStakeIsNotPermanent
    whenTheDurationDoesNotExceedTheMaximumAcceptedAfterDelivery
  {
    uint64 _nonce = 1;
    _tokenAmount = uint128(bound(_tokenAmount, 1, _BUDGET));
    _initialPaid = bound(_initialPaid, 0, type(uint256).max - _tokenAmount);
    _offset = uint48(bound(_offset, 0, WEEK - 1));
    _stakedTokenId = bound(_stakedTokenId, 1, type(uint256).max);

    vm.warp(WEEK + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);
    assertTrue(_maximumDurationWeeks == 208 || _maximumDurationWeeks == 209);
    _durationWeeks = uint48(bound(_durationWeeks, 1, _maximumDurationWeeks - 1));

    stdstore.target(address(_entrypoint)).sig(IVelodromeMigrationEntrypoint.paid.selector).checked_write(_initialPaid);
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: users.bob,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _durationWeeks
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);

    // it should leave the duration unchanged
    // it should approve the v3 voting escrow to spend the token amount
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, uint256(_tokenAmount))), abi.encode(true));

    // it should create a decaying v3 staked position
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (_tokenAmount, _durationWeeks, false)),
      abi.encode(_stakedTokenId)
    );

    // it should transfer the v3 staked position to the recipient
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), users.bob, _stakedTokenId)), ''
    );

    // it should emit the Migrated event
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.Migrated({
      _nonce: _nonce, _recipient: users.bob, _tokenAmount: _tokenAmount, _isLiquid: false
    });
    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);

    // it should mark the nonce as used
    assertTrue(_entrypoint.noncesUsed(_nonce));

    // it should increase paid by the token amount
    assertEq(_entrypoint.paid(), _initialPaid + _tokenAmount);
  }

  function testGas_handle_liquid()
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsLiquid
  {
    uint64 _nonce = 1;
    address _recipient = users.bob;
    uint256 _tokenAmount = 100 ether;
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: true,
      _isPermanent: false,
      _durationWeeks: 0
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.transfer, (_recipient, _tokenAmount)), abi.encode(true));

    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);
    vm.snapshotGasLastCall('VelodromeMigrationEntrypoint_handle_liquid');
  }

  function testGas_handle_permanent()
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
  {
    uint64 _nonce = 1;
    uint256 _stakedTokenId = 1;
    address _recipient = users.bob;
    uint256 _tokenAmount = 100 ether;
    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: true,
      _durationWeeks: 0
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, _tokenAmount)), abi.encode(true));
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (uint128(_tokenAmount), uint48(0), true)),
      abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), _recipient, _stakedTokenId)), ''
    );

    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);
    vm.snapshotGasLastCall('VelodromeMigrationEntrypoint_handle_permanent');
  }

  function testGas_handle_nonPermanent()
    external
    whenTheMessageIsValid
    whenTheNonceHasNotBeenUsed
    whenTheTokenAmountDoesNotExceedTheRemainingBudget
    whenTheMigrationIsStaked
    whenTheStakeIsNotPermanent
    whenTheDurationExceedsTheMaximumAcceptedAfterDelivery
  {
    uint64 _nonce = 1;
    uint256 _stakedTokenId = 1;
    address _recipient = users.bob;
    uint256 _tokenAmount = 100 ether;
    uint48 _durationWeeks = 260;
    uint48 _offset = 3 days;

    /// @dev Settle during the final four days of the epoch so the maximum v3 stake duration is 209 weeks
    vm.warp(WEEK + _offset);
    uint256 _maximumEnd = ProtocolTimeLibrary.epochStart(block.timestamp + MAXTIME);
    /// @dev MAXTIME permits 208 or 209 staking weeks depending on the current epoch offset
    uint48 _maximumDurationWeeks = uint48((_maximumEnd - ProtocolTimeLibrary.epochStart(block.timestamp)) / WEEK);

    bytes memory _body = _encodeMigrationMessage({
      _nonce: _nonce,
      _recipient: _recipient,
      _tokenAmount: _tokenAmount,
      _isLiquid: false,
      _isPermanent: false,
      _durationWeeks: _durationWeeks
    });

    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _BUDGET);
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, _tokenAmount)), abi.encode(true));
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (uint128(_tokenAmount), _maximumDurationWeeks, false)),
      abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), _recipient, _stakedTokenId)), ''
    );

    _entrypoint.handle(_OP_DOMAIN, TypeCasts.addressToBytes32(address(_entrypoint)), _body);
    vm.snapshotGasLastCall('VelodromeMigrationEntrypoint_handle_nonPermanent');
  }

  /// @dev Expects the external calls required to settle a staked migration
  function _expectStakeSettlement(
    address _recipient,
    uint256 _tokenAmount,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal {
    /// @dev Clamp decaying stakes to the maximum duration accepted at settlement
    if (!_isPermanent) {
      uint48 _maximumDurationWeeks = uint48((MAXTIME + (block.timestamp % WEEK)) / WEEK);
      if (_durationWeeks > _maximumDurationWeeks) _durationWeeks = _maximumDurationWeeks;
    }

    uint256 _stakedTokenId = 1;
    _mockAndExpect(_v3Token, abi.encodeCall(IERC20.approve, (_v3Escrow, _tokenAmount)), abi.encode(true));
    _mockAndExpect(
      _v3Escrow,
      abi.encodeCall(IVotingEscrow.createStake, (uint128(_tokenAmount), _durationWeeks, _isPermanent)),
      abi.encode(_stakedTokenId)
    );
    _mockAndExpect(
      _v3Escrow, abi.encodeCall(IERC721.transferFrom, (address(_entrypoint), _recipient, _stakedTokenId)), ''
    );
  }
}
