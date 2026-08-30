// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotes} from 'V3/interfaces/core/IVotes.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowDelegateBySig is BaseVotingEscrow {
  uint256 internal constant _SIGNER_PK = 0xA11CE;
  uint256 internal constant _S_THRESHOLD = 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

  /// @dev Standards-compliant EIP-712 domain typehash matching the contract's OZ EIP712 implementation.
  bytes32 internal constant _DOMAIN_TYPEHASH =
    keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)');

  /// @dev Builds an EIP-712 digest the standards-compliant way: the domain typehash declares all five fields
  ///      and the encoded domain has the matching five elements.
  function _digest(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _nonce,
    uint256 _expiry
  ) internal view returns (bytes32) {
    bytes32 _domainSeparator = keccak256(
      abi.encode(
        _DOMAIN_TYPEHASH, keccak256(bytes(_ve.name())), keccak256(bytes(_ve.VERSION())), block.chainid, address(_ve)
      )
    );
    bytes32 _structHash = keccak256(abi.encode(_ve.DELEGATION_TYPEHASH(), _delegator, _delegatee, _nonce, _expiry));
    return keccak256(abi.encodePacked('\x19\x01', _domainSeparator, _structHash));
  }

  function test_WhenTheSignatureSComponentIsInTheUpperHalfOrder() external {
    // it should revert with InvalidSignatureS
    vm.expectRevert(IVotingEscrow.InvalidSignatureS.selector);
    _ve.delegateBySig(0, 0, 0, 0, 27, bytes32(0), bytes32(_S_THRESHOLD + 1));
  }

  /// @dev The malleability guard uses a strict `>` so `s == threshold` is still inside the valid range.
  ///      At the boundary the InvalidSignatureS branch must NOT fire; execution falls through to
  ///      `ecrecover`, which returns `address(0)` for this r=0 input, so the call reverts later with
  ///      `InvalidSignature` instead. Asserting that specific later selector proves the boundary passes.
  function test_WhenTheSignatureSComponentEqualsTheUpperBoundOfTheValidRange() external {
    // it should not revert with InvalidSignatureS
    vm.expectRevert(IVotingEscrow.InvalidSignature.selector);
    _ve.delegateBySig(0, 0, 0, 0, 27, bytes32(0), bytes32(_S_THRESHOLD));
  }

  /// @dev `ecrecover` returns `address(0)` for invalid v / r / s combinations. The check fires before
  ///      the authorization step so the signer-zero path is observable via `InvalidSignature`.
  function test_WhenTheRecoveredSignatoryIsZero() external {
    // it should revert with InvalidSignature
    vm.expectRevert(IVotingEscrow.InvalidSignature.selector);
    // v=26 is outside the valid {27, 28} range — ecrecover returns 0.
    _ve.delegateBySig(0, 0, 0, 0, 26, bytes32(0), bytes32(0));
  }

  function test_WhenTheRecoveredSignatoryIsNotTheOwnerOrApprovedOperator(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _nonce,
    uint256 _expiry
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _setOwner(_delegator, _owner);
    bytes32 _msgDigest = _digest(_delegator, _delegatee, _nonce, _expiry);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SIGNER_PK, _msgDigest);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(
      abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, vm.addr(_SIGNER_PK), _delegator)
    );
    _ve.delegateBySig(_delegator, _delegatee, _nonce, _expiry, _v, _r, _s);
  }

  function test_WhenTheNonceDoesNotMatchTheSignatoryNextNonce(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _expiry,
    uint256 _badNonce
  ) external {
    address _signer = vm.addr(_SIGNER_PK);
    _delegator = bound(_delegator, 1, type(uint128).max);
    _badNonce = bound(_badNonce, 1, type(uint256).max);
    vm.assume(_delegator != _delegatee);
    _setOwner(_delegator, _signer);
    _setStaked(_delegator, 1, 0, true);
    if (_delegatee != 0) {
      _setOwner(_delegatee, makeAddr('DelegateeOwner'));
      _setStaked(_delegatee, 1, 0, true);
    }
    bytes32 _msgDigest = _digest(_delegator, _delegatee, _badNonce, _expiry);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SIGNER_PK, _msgDigest);

    // it should revert with InvalidNonce
    vm.expectRevert(IVotingEscrow.InvalidNonce.selector);
    _ve.delegateBySig(_delegator, _delegatee, _badNonce, _expiry, _v, _r, _s);
  }

  function test_WhenTheSignatureHasExpired(uint256 _delegator, uint256 _delegatee, uint48 _pastExpiry) external {
    address _signer = vm.addr(_SIGNER_PK);
    _delegator = bound(_delegator, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    vm.warp(1 weeks + 1);
    _pastExpiry = uint48(bound(_pastExpiry, 1, block.timestamp - 1));
    _setOwner(_delegator, _signer);
    _setStaked(_delegator, 1, 0, true);
    if (_delegatee != 0) {
      _setOwner(_delegatee, makeAddr('DelegateeOwner'));
      _setStaked(_delegatee, 1, 0, true);
    }
    bytes32 _msgDigest = _digest(_delegator, _delegatee, 0, _pastExpiry);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SIGNER_PK, _msgDigest);

    // it should revert with SignatureExpired
    vm.expectRevert(IVotingEscrow.SignatureExpired.selector);
    _ve.delegateBySig(_delegator, _delegatee, 0, _pastExpiry, _v, _r, _s);
  }

  function test_WhenTheSignatureIsValidAndCurrent(
    uint256 _delegator,
    uint256 _delegatee,
    uint48 _expiry,
    uint128 _oldAmount
  ) external {
    address _signer = vm.addr(_SIGNER_PK);
    address _delegateeOwner = makeAddr('DelegateeOwner');
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_delegator, _signer);
    _setOwner(_delegatee, _delegateeOwner);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_delegatee, _oldAmount, 0, true);
    // Seed the delegatee's mint-time checkpoint so the subsequent delegateBySig() propagates the
    // real owner forward. Using fromTimestamp = block.timestamp makes checkpointDelegatee overwrite
    // in place (same-block path), preserving numCheckpoints == 1 below.
    _setNumCheckpoints(_delegatee, 1);
    _setCheckpoint(_delegatee, 0, block.timestamp, _delegateeOwner, 0, 0);
    bytes32 _msgDigest = _digest(_delegator, _delegatee, 0, _expiry);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SIGNER_PK, _msgDigest);

    // it should emit the DelegateChanged event with the delegator owner as the indexed delegator
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_signer, 0, _delegatee);

    _ve.delegateBySig(_delegator, _delegatee, 0, _expiry, _v, _r, _s);

    // it should increment the signatory nonce
    assertEq(_ve.nonces(_signer), 1);
    // it should set the delegate slot to the delegatee
    assertEq(_ve.delegates(_delegator), _delegatee);
    // it should record a delegator checkpoint with the new delegatee
    assertEq(_ve.numCheckpoints(_delegator), 1);
    assertEq(_ve.checkpoints(_delegator, 0).delegatee, _delegatee);
    // it should record a delegatee checkpoint with delegated balance equal to the delegator amount
    assertEq(_ve.numCheckpoints(_delegatee), 1);
    assertEq(_ve.checkpoints(_delegatee, 0).delegatedBalance, _oldAmount);
    assertEq(_ve.checkpoints(_delegatee, 0).owner, _delegateeOwner);
    // it should reflect the new delegated balance in getPastVotes with the delegatee owner
    assertEq(_ve.getPastVotes(_delegateeOwner, _delegatee, block.timestamp), _oldAmount, 'getPastVotes drift');
  }

  /// @dev DBS-1: the signatory is NOT the delegator's owner but an approved-for-all operator of it. This is the
  ///      authorization branch the owner-signs-for-self happy path never exercises. The DelegateChanged event must
  ///      index `_ownerOf(_delegator)` (the real owner), not the operator signer.
  function test_WhenTheSignatoryIsAnApprovedOperatorOfTheDelegatorOwner(
    uint256 _delegator,
    uint256 _delegatee,
    uint48 _expiry,
    uint128 _oldAmount
  ) external {
    address _signer = vm.addr(_SIGNER_PK);
    address _delegatorOwner = makeAddr('DelegatorOwner');
    address _delegateeOwner = makeAddr('DelegateeOwner');
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    // The delegator is owned by someone other than the signer; the signer is only an approved operator.
    _setOwner(_delegator, _delegatorOwner);
    _setOwner(_delegatee, _delegateeOwner);
    _setOperatorApproval(_delegatorOwner, _signer, true);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_delegatee, _oldAmount, 0, true);
    // Seed the delegatee's mint-time checkpoint so delegateBySig() overwrites in place (same-block path).
    _setNumCheckpoints(_delegatee, 1);
    _setCheckpoint(_delegatee, 0, block.timestamp, _delegateeOwner, 0, 0);
    bytes32 _msgDigest = _digest(_delegator, _delegatee, 0, _expiry);
    (uint8 _v, bytes32 _r, bytes32 _s) = vm.sign(_SIGNER_PK, _msgDigest);

    // it should emit the DelegateChanged event with the delegator owner not the signatory
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_delegatorOwner, 0, _delegatee);

    _ve.delegateBySig(_delegator, _delegatee, 0, _expiry, _v, _r, _s);

    // The nonce increments on the signatory (operator), and the delegate slot is updated.
    assertEq(_ve.nonces(_signer), 1);
    assertEq(_ve.delegates(_delegator), _delegatee);
    // The delegator checkpoint records the real owner, not the operator signer.
    assertEq(_ve.checkpoints(_delegator, 0).owner, _delegatorOwner);
  }
}
