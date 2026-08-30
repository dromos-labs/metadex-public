// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

/// @dev The owner enumeration read by `tokenOfOwnerByIndex` lives in two private, getter-less mappings
///      (`_ownedTokens`, `_ownedTokensIndex`) that stdStorage cannot probe, and it is written exclusively as a
///      side effect of the `_update` hook. There is no setter to seed; injecting the final state with `vm.store`
///      would both hardcode brittle slots and reduce the read tests to a tautology. Per the testing standards,
///      the sister write path is therefore itself the subject under test, so these tests drive real mint
///      (createStake / rebalanceUnderlying), transfer, and withdraw paths, keeping all external dependencies
///      (token, voter) mocked so the suite stays solitary.
contract UnitVotingEscrowTokenOfOwnerByIndex is BaseVotingEscrow {
  /// @dev Mint a permanent stake to `_to` through the real createStake path so `_update` maintains the
  ///      owner enumeration. Real mints are required (see contract note); `_setOwner` writes `_owners` but not
  ///      `_balances`, which would leave enumeration unset and underflow the unchecked `_balances` on transfer.
  function _mintPermanentTo(address _to, uint128 _value) internal returns (uint256 _tokenId) {
    _mockTransferFrom(_to, address(_ve), _value);
    vm.prank(_to);
    _tokenId = _ve.createStake(_value, 0, true);
  }

  function test_WhenTheOwnerHoldsNoTokens(address _account, uint256 _index) external {
    _assumeFuzzable(_account);

    // it should revert with ERC721OutOfBoundsIndex
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, _account, _index));
    _ve.tokenOfOwnerByIndex(_account, _index);
  }

  function test_WhenTheIndexEqualsTheOwnerBalance(uint128 _value, uint8 _count) external {
    // Cap per-stake value so the aggregate supply/permanentStakeBalance (uint128) cannot overflow across mints.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 6));
    uint256 _balance = bound(_count, 1, 5);
    for (uint256 _i; _i < _balance; ++_i) {
      _mintPermanentTo(_owner, _value);
    }

    // it should revert with ERC721OutOfBoundsIndex
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, _owner, _balance));
    _ve.tokenOfOwnerByIndex(_owner, _balance);
  }

  function test_WhenTheOwnerHoldsASingleMintedToken(uint128 _value) external {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    uint256 _tokenId = _mintPermanentTo(_owner, _value);

    // it should return that token id at index zero
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _tokenId);
  }

  function test_WhenTheOwnerHoldsSeveralMintedTokens(uint128 _value, uint8 _count) external {
    // Cap per-stake value so the aggregate supply/permanentStakeBalance (uint128) cannot overflow across mints.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 6));
    uint256 _balance = bound(_count, 2, 6);
    uint256[] memory _ids = new uint256[](_balance);
    for (uint256 _i; _i < _balance; ++_i) {
      _ids[_i] = _mintPermanentTo(_owner, _value);
    }

    // it should return each minted token id at its index
    assertEq(_ve.balanceOf(_owner), _balance);
    for (uint256 _i; _i < _balance; ++_i) {
      assertEq(_ve.tokenOfOwnerByIndex(_owner, _i), _ids[_i]);
    }
  }

  function test_WhenANonLastTokenIsTransferredAway(uint128 _value, address _recipient) external {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _owner && _recipient != address(_ve));
    // Cap per-stake value so the aggregate supply/permanentStakeBalance (uint128) cannot overflow across mints.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 6));

    uint256 _first = _mintPermanentTo(_owner, _value);
    uint256 _second = _mintPermanentTo(_owner, _value);
    uint256 _last = _mintPermanentTo(_owner, _value);

    // Transfer the token at index zero, which is not the last entry, forcing the swap-and-pop branch.
    vm.prank(_owner);
    _ve.transferFrom(_owner, _recipient, _first);

    // it should shrink the sender balance by one
    assertEq(_ve.balanceOf(_owner), 2);
    // it should swap the last sender token into the freed slot
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _last);
    // it should keep every remaining sender token discoverable
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 1), _second);
    // it should expose the token under the recipient
    assertEq(_ve.balanceOf(_recipient), 1);
    assertEq(_ve.tokenOfOwnerByIndex(_recipient, 0), _first);
  }

  function test_WhenTheLastTokenIsTransferredAway(uint128 _value, address _recipient) external {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _owner && _recipient != address(_ve));
    // Cap per-stake value so the aggregate supply/permanentStakeBalance (uint128) cannot overflow across mints.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 6));

    uint256 _first = _mintPermanentTo(_owner, _value);
    uint256 _second = _mintPermanentTo(_owner, _value);
    uint256 _last = _mintPermanentTo(_owner, _value);

    // Transfer the last entry, which skips the swap and only pops the tail.
    vm.prank(_owner);
    _ve.transferFrom(_owner, _recipient, _last);

    // it should shrink the sender balance by one
    assertEq(_ve.balanceOf(_owner), 2);
    // it should keep the earlier sender tokens discoverable
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _first);
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 1), _second);
    // it should expose the token under the recipient
    assertEq(_ve.balanceOf(_recipient), 1);
    assertEq(_ve.tokenOfOwnerByIndex(_recipient, 0), _last);
  }

  function test_WhenATokenIsTransferredToItsCurrentOwner(uint128 _value) external {
    // Cap per-stake value so the aggregate supply/permanentStakeBalance (uint128) cannot overflow across mints.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 6));

    uint256 _first = _mintPermanentTo(_owner, _value);
    uint256 _second = _mintPermanentTo(_owner, _value);

    // Self-transfer: both enumeration branches are guarded by `_from != _to` and must be skipped.
    vm.prank(_owner);
    _ve.transferFrom(_owner, _owner, _first);

    // it should keep the owner balance unchanged
    assertEq(_ve.balanceOf(_owner), 2);
    // it should keep the token discoverable at its index
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _first);
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 1), _second);
  }

  function test_WhenAnExpiredStakeIsWithdrawn(uint128 _value) external {
    _value = uint128(bound(_value, 1, _DECAY_AMOUNT_CAP));
    vm.warp(_WEEK);

    // Mint a decaying stake through the real path, then let it expire. Withdraw preserves the NFT (VE never
    // burns), so it never calls `_update` and the owner enumeration must stay intact.
    _mockTransferFrom(_owner, address(_ve), _value);
    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, 10, false);

    vm.warp(11 * _WEEK); // stake end = (_WEEK / _WEEK) * _WEEK + 10 * _WEEK
    // The whole stake sits on CHAIN0, so the return-to-chain0 check passes.
    _mockVoterChain0Allocation(_tokenId, _value);
    _mockTransfer(_owner, _value);
    vm.prank(_owner);
    _ve.withdraw(_tokenId, _owner);

    // it should keep the owner balance unchanged
    assertEq(_ve.balanceOf(_owner), 1);
    // it should keep the token discoverable at its index
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _tokenId);
  }
}
