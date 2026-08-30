// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

/// @notice Unit tests for `VotingEscrow.tokenByIndex`, the reader over the global ERC721Enumerable token list.
/// @dev `tokenByIndex` reads two things: `totalSupply()` for the bound check and `_allTokens[index]` for the
///      result. Both live in ERC721Enumerable's private `uint256[] _allTokens`, which `_setGlobalEnumeration`
///      seeds directly through the length slot that stdStorage resolves from the `totalSupply()` getter. The
///      suite therefore never calls a sister write path, and `_allTokens` is the whole pre-state the reader
///      touches. The seeded ids are deliberately unordered: a real mint hands out ids 1..N against indices
///      0..N-1, so `tokenByIndex(i) == i + 1` also holds for a reader that ignores the array. Unordered ids are
///      the only pre-state that can fail such a reader. Append-on-mint is a `_update` property and belongs to
///      the createStake suite.
contract UnitVotingEscrowTokenByIndex is BaseVotingEscrow {
  /// @dev Ids written into the global enumeration by `givenTheEnumerationHoldsTokens`, in index order. Storage,
  ///      because a modifier cannot hand a memory array back to the test body.
  uint256[] internal _seededIds;

  /// @notice Every index is out of bounds while the global token list holds nothing.
  function test_WhenTheEnumerationIsEmpty(address _caller, uint256 _index) external {
    _assumeFuzzable(_caller);

    // it should revert with ERC721OutOfBoundsIndex
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, address(0), _index));
    vm.prank(_caller);
    _ve.tokenByIndex(_index);
  }

  /// @dev Seed the global token list with `_tokenIds` and record it for the body to assert against.
  modifier givenTheEnumerationHoldsTokens(uint256[] memory _tokenIds) {
    _seededIds = _tokenIds;
    _setGlobalEnumeration(_tokenIds);
    _;
  }

  /// @notice Each seeded id comes back at its own index, in the order the list holds them.
  function test_WhenTheIndexIsWithinTheEnumeration(
    address _caller,
    uint256 _seed,
    uint8 _count
  ) external givenTheEnumerationHoldsTokens(_unorderedIds(_seed, bound(uint256(_count), 1, 8))) {
    _assumeFuzzable(_caller);
    uint256 _supply = _seededIds.length;

    // it should return the token id at that index
    vm.startPrank(_caller);
    for (uint256 _i; _i < _supply; ++_i) {
      assertEq(_ve.tokenByIndex(_i), _seededIds[_i]);
    }
    vm.stopPrank();
  }

  /// @notice A hand written unordered list proves the reader indexes the array instead of the index itself.
  function test_WhenUsingAKnownUnorderedExample(address _caller)
    external
    givenTheEnumerationHoldsTokens(_ids(77, 3, 9001))
  {
    _assumeFuzzable(_caller);

    // it should return the token id at that index
    vm.startPrank(_caller);
    assertEq(_ve.tokenByIndex(0), 77);
    assertEq(_ve.tokenByIndex(1), 3);
    assertEq(_ve.tokenByIndex(2), 9001);
    vm.stopPrank();
  }

  /// @notice The first index past the end is out of bounds, so the reader rejects `totalSupply()` itself.
  function test_WhenTheIndexEqualsTheTotalSupply(
    address _caller,
    uint256 _seed,
    uint8 _count
  ) external givenTheEnumerationHoldsTokens(_unorderedIds(_seed, bound(uint256(_count), 1, 8))) {
    _assumeFuzzable(_caller);
    // Valid indices run 0..totalSupply()-1, so the first out-of-bounds index is exactly `totalSupply()`.
    uint256 _supply = _seededIds.length;

    // it should revert with ERC721OutOfBoundsIndex
    vm.expectRevert(abi.encodeWithSelector(ERC721Enumerable.ERC721OutOfBoundsIndex.selector, address(0), _supply));
    vm.prank(_caller);
    _ve.tokenByIndex(_supply);
  }

  /// @dev Derive `_count` unordered, nonzero token ids from one fuzz seed. Hashing keeps every id unrelated to
  ///      its index, which is what stops an index-derived reader from passing.
  function _unorderedIds(uint256 _seed, uint256 _count) internal pure returns (uint256[] memory _tokenIds) {
    _tokenIds = new uint256[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _tokenIds[_i] = bound(uint256(keccak256(abi.encode(_seed, _i))), 1, type(uint256).max);
    }
  }

  /// @dev Pack three literal ids into the memory array the seeding modifier takes.
  function _ids(uint256 _first, uint256 _second, uint256 _third) internal pure returns (uint256[] memory _tokenIds) {
    _tokenIds = new uint256[](3);
    _tokenIds[0] = _first;
    _tokenIds[1] = _second;
    _tokenIds[2] = _third;
  }
}
