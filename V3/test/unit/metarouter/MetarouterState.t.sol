// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {MetarouterStateHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterStateHarness.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Unit tests for the shared MetarouterState transient accessors, exercised without a router or a driven
///         batch so each accessor is asserted against the slots it owns.
/// @dev Preconditions are seeded through the harness's raw slot writers, never through a sister accessor, so a bug in
///      one accessor cannot mask another's test. Fuzzed addresses are never called, so they need no `_assumeFuzzable`
///      filtering; they are constrained only where a zero value would change the branch under test.
contract UnitMetarouterState is TestHelpers {
  /// @notice Native units per native ERC20 unit for the lower-decimals native ERC20 scenarios, the stablecoin-native shape
  ///         where a six-decimal ERC20 mirrors the eighteen-decimal native asset.
  uint256 internal constant _NATIVE_ERC20_SCALE = 1e12;

  MetarouterStateHarness internal _harness;

  function setUp() public {
    _harness = new MetarouterStateHarness();
  }

  // --- trackERC20 ---

  function test_TrackERC20WhenTheTokenHasAlreadyBeenTracked(address _token) external {
    _harness.seedTrackedErc20(_token);

    _harness.trackERC20(_token);

    // it should not append the token again
    assertEq(_harness.trackedErc20Length(), 1);
    assertEq(_harness.trackedErc20At(0), _token);
  }

  function test_TrackERC20WhenTheTokenHasNotBeenTracked(address _token) external {
    _harness.trackERC20(_token);

    // it should flag _token under the tracked namespace
    assertEq(_harness.erc20Flag(_token), 1);
    // it should append _token to the tracked erc20 array
    assertEq(_harness.trackedErc20Length(), 1);
    assertEq(_harness.trackedErc20At(0), _token);
  }

  // --- trackNft ---

  function test_TrackNftWhenTheNftHasAlreadyBeenTracked(address _collection, uint256 _tokenId) external {
    // The flag is the deduplication key, so the seeded pair must carry both the flag and its array entries to
    // represent an NFT that already entered custody this batch.
    _harness.seedNftFlag(_collection, _tokenId);
    _harness.seedTrackedNft(_collection, _tokenId);

    _harness.trackNft(_collection, _tokenId);

    // it should not append the collection again
    assertEq(_harness.nftCollectionLength(), 1);
    // it should not append the token id again
    assertEq(_harness.nftTokenIdLength(), 1);
  }

  function test_TrackNftWhenTheNftHasNotBeenTracked(address _collection, uint256 _tokenId) external {
    _harness.trackNft(_collection, _tokenId);

    // it should flag the nft under its derived flag slot
    assertEq(_harness.nftFlag(_collection, _tokenId), 1);
    // it should append _collection to the collection array
    assertEq(_harness.nftCollectionLength(), 1);
    assertEq(_harness.nftCollectionAt(0), _collection);
    // it should append _tokenId to the token id array
    assertEq(_harness.nftTokenIdLength(), 1);
    assertEq(_harness.nftTokenIdAt(0), _tokenId);
  }

  // --- untrackNft ---

  function test_UntrackNftWhenATrackedNftIsUntracked(address _collection, uint256 _tokenId) external {
    _harness.seedNftFlag(_collection, _tokenId);
    _harness.seedTrackedNft(_collection, _tokenId);

    _harness.untrackNft(_collection, _tokenId);

    // it should clear the nft flag
    assertEq(_harness.nftFlag(_collection, _tokenId), 0);
    // it should leave the collection array length unchanged
    assertEq(_harness.nftCollectionLength(), 1);
  }

  // --- clearNftArrays ---

  function test_ClearNftArraysWhenTheCustodyArraysHoldEntries(uint256 _seed, uint256 _count) external {
    _count = bound(_count, 1, 5);
    for (uint256 _i; _i < _count; ++_i) {
      _harness.seedTrackedNft(_derivedCollection(_seed, _i), _derivedTokenId(_seed, _i));
    }

    _harness.clearNftArrays();

    // it should reset the collection array length
    assertEq(_harness.nftCollectionLength(), 0);
    // it should reset the token id array length
    assertEq(_harness.nftTokenIdLength(), 0);
  }

  // --- setInFlightNft ---

  function test_SetInFlightNftWhenAnNftIsAlreadyInFlight(
    address _inFlightCollection,
    uint256 _inFlightTokenId,
    address _collection,
    uint256 _tokenId
  ) external {
    // A non-zero collection is what marks the slots occupied, so the guard only trips on one.
    _assumeFuzzable(_inFlightCollection);
    _harness.seedInFlightNft(_inFlightCollection, _inFlightTokenId);

    // it should revert with InFlightNftPresent
    vm.expectRevert(IMetarouter.InFlightNftPresent.selector);
    _harness.setInFlightNft(_collection, _tokenId);
  }

  function test_SetInFlightNftWhenNoNftIsInFlight(address _collection, uint256 _tokenId) external {
    _harness.setInFlightNft(_collection, _tokenId);

    (uint256 _storedCollection, uint256 _storedTokenId) = _harness.inFlightSlots();
    // it should store _collection in the in flight collection slot
    assertEq(_storedCollection, uint256(uint160(_collection)));
    // it should store _tokenId in the in flight token id slot
    assertEq(_storedTokenId, _tokenId);
  }

  // --- consumeInFlightNft ---

  function test_ConsumeInFlightNftWhenTheInFlightNftMatches(address _collection, uint256 _tokenId) external {
    // Both operands are seeded non-zero so the clearing is observable rather than trivially already-zero.
    _assumeFuzzable(_collection);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _harness.seedInFlightNft(_collection, _tokenId);

    _harness.consumeInFlightNft(_collection, _tokenId);

    (uint256 _storedCollection, uint256 _storedTokenId) = _harness.inFlightSlots();
    // it should clear the in flight collection slot
    assertEq(_storedCollection, 0);
    // it should clear the in flight token id slot
    assertEq(_storedTokenId, 0);
  }

  function test_ConsumeInFlightNftWhenTheCollectionDiffersFromTheInFlightNft(
    address _collection,
    address _differentCollection,
    uint256 _tokenId
  ) external {
    // Same token id, different collection: the match fails on its collection operand, so nothing is cleared.
    _assumeFuzzable(_collection);
    _differentCollection = _boundNotEq(_differentCollection, _collection);
    _harness.seedInFlightNft(_collection, _tokenId);

    _harness.consumeInFlightNft(_differentCollection, _tokenId);

    // it should leave the in flight slots unchanged
    (uint256 _storedCollection, uint256 _storedTokenId) = _harness.inFlightSlots();
    assertEq(_storedCollection, uint256(uint160(_collection)));
    assertEq(_storedTokenId, _tokenId);
  }

  function test_ConsumeInFlightNftWhenTheTokenIdDiffersFromTheInFlightNft(
    address _collection,
    uint256 _tokenId,
    uint256 _differentTokenId
  ) external {
    // Same collection, different token id: the match fails on its token-id operand, so nothing is cleared.
    _assumeFuzzable(_collection);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    vm.assume(_differentTokenId != _tokenId);
    _harness.seedInFlightNft(_collection, _tokenId);

    _harness.consumeInFlightNft(_collection, _differentTokenId);

    // it should leave the in flight slots unchanged
    (uint256 _storedCollection, uint256 _storedTokenId) = _harness.inFlightSlots();
    assertEq(_storedCollection, uint256(uint160(_collection)));
    assertEq(_storedTokenId, _tokenId);
  }

  // --- inFlightNft ---

  function test_InFlightNftWhenNoNftIsInFlight() external view {
    (address _collection, uint256 _tokenId) = _harness.inFlightNft();

    // it should return address zero as _collection
    assertEq(_collection, address(0));
    // it should return zero as _tokenId
    assertEq(_tokenId, 0);
  }

  function test_InFlightNftWhenAnNftIsInFlight(address _seededCollection, uint256 _seededTokenId) external {
    _assumeFuzzable(_seededCollection);
    _seededTokenId = bound(_seededTokenId, 1, type(uint256).max);
    _harness.seedInFlightNft(_seededCollection, _seededTokenId);

    (address _collection, uint256 _tokenId) = _harness.inFlightNft();

    // it should return the in flight collection as _collection
    assertEq(_collection, _seededCollection);
    // it should return the in flight token id as _tokenId
    assertEq(_tokenId, _seededTokenId);
  }

  // --- resolvePositionId ---

  function test_ResolvePositionIdWhenTheTokenIdIsNonzero(address _collection, uint256 _tokenId) external view {
    _tokenId = bound(_tokenId, 1, type(uint256).max);

    // it should return _tokenId as _resolved
    assertEq(_harness.resolvePositionId(_collection, _tokenId), _tokenId);
  }

  function test_ResolvePositionIdWhenTheCollectionDoesNotMatchTheInFlightCollection(
    address _collection,
    address _inFlightCollection,
    uint256 _inFlightTokenId
  ) external {
    // Fuzzing the in-flight collection to anything other than the queried one covers both empty slots (their
    // collection reads zero) and slots holding a different collection; neither satisfies the sentinel.
    _inFlightCollection = _boundNotEq(_inFlightCollection, _collection);
    _harness.seedInFlightNft(_inFlightCollection, _inFlightTokenId);

    // it should revert with NoInFlightNft
    vm.expectRevert(IMetarouter.NoInFlightNft.selector);
    _harness.resolvePositionId(_collection, 0);
  }

  function test_ResolvePositionIdWhenTheTokenIdIsTheInFlightSentinel(
    address _collection,
    uint256 _inFlightTokenId
  ) external {
    _assumeFuzzable(_collection);
    _harness.seedInFlightNft(_collection, _inFlightTokenId);

    // it should return the in flight token id as _resolved
    assertEq(_harness.resolvePositionId(_collection, 0), _inFlightTokenId);
  }

  // --- isNftInCustody ---

  function test_IsNftInCustodyWhenTheNftFlagIsSet(address _collection, uint256 _tokenId) external {
    _assumeFuzzable(_collection);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _harness.seedNftFlag(_collection, _tokenId);

    // it should return true as _inCustody
    assertTrue(_harness.isNftInCustody(_collection, _tokenId));
  }

  function test_IsNftInCustodyWhenTheNftFlagIsNotSet(address _collection, uint256 _tokenId) external view {
    _tokenId = bound(_tokenId, 1, type(uint256).max);

    // it should return false as _inCustody
    assertFalse(_harness.isNftInCustody(_collection, _tokenId));
  }

  // --- trackedNftLength ---

  function test_TrackedNftLengthWhenTheCollectionArrayIsEmpty() external view {
    // it should return zero as _length
    assertEq(_harness.trackedNftLength(), 0);
  }

  function test_TrackedNftLengthWhenTheCollectionArrayHoldsEntries(uint256 _seed, uint256 _count) external {
    _count = bound(_count, 1, 5);
    for (uint256 _i; _i < _count; ++_i) {
      _harness.seedTrackedNft(_derivedCollection(_seed, _i), _derivedTokenId(_seed, _i));
    }

    // it should return the number of entries as _length
    assertEq(_harness.trackedNftLength(), _count);
  }

  // --- trackedNftAt ---

  function test_TrackedNftAtWhenTheIndexIsWithinTheCustodyArrays(
    uint256 _seed,
    uint256 _count,
    uint256 _index
  ) external {
    _count = bound(_count, 1, 5);
    _index = bound(_index, 0, _count - 1);
    for (uint256 _i; _i < _count; ++_i) {
      _harness.seedTrackedNft(_derivedCollection(_seed, _i), _derivedTokenId(_seed, _i));
    }

    (address _collection, uint256 _tokenId) = _harness.trackedNftAt(_index);

    // it should return the collection at the index as _collection
    assertEq(_collection, _derivedCollection(_seed, _index));
    // it should return the token id at the index as _tokenId
    assertEq(_tokenId, _derivedTokenId(_seed, _index));
  }

  // --- msgSender ---

  function test_MsgSenderWhenTheLockerSlotIsEmpty() external view {
    // it should return address zero as _sender
    assertEq(_harness.msgSender(), address(0));
  }

  function test_MsgSenderWhenTheLockerSlotHoldsTheOuterCaller(address _sender) external {
    _harness.seedLocker(_sender);

    // it should return the outer caller as _sender
    assertEq(_harness.msgSender(), _sender);
  }

  // --- availableNativeBalance ---

  function test_AvailableNativeBalanceWhenTheBalanceIsBelowThePreBatchSnapshot(
    uint256 _balance,
    uint256 _snapshot
  ) external {
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _snapshot = bound(_snapshot, _balance + 1, type(uint256).max);
    vm.deal(address(_harness), _balance);
    _harness.seedNativeBalanceBefore(_snapshot);

    // it should revert with PreBatchNativeBalanceSpent
    vm.expectRevert(IMetarouter.PreBatchNativeBalanceSpent.selector);
    _harness.availableNativeBalance();
  }

  function test_AvailableNativeBalanceWhenTheBalanceEqualsThePreBatchSnapshot(uint256 _balance) external {
    vm.deal(address(_harness), _balance);
    _harness.seedNativeBalanceBefore(_balance);

    // it should return zero as _balance
    assertEq(_harness.availableNativeBalance(), 0);
  }

  function test_AvailableNativeBalanceWhenTheBalanceExceedsThePreBatchSnapshot(
    uint256 _balance,
    uint256 _snapshot
  ) external {
    _balance = bound(_balance, 1, type(uint256).max);
    _snapshot = bound(_snapshot, 0, _balance - 1);
    vm.deal(address(_harness), _balance);
    _harness.seedNativeBalanceBefore(_snapshot);

    // it should return the balance above the snapshot as _balance
    assertEq(_harness.availableNativeBalance(), _balance - _snapshot);
  }

  // --- availableErc20Balance ---

  /// @notice A token that is not the published native ERC20 spends its full balance, untouched by the snapshot.
  function test_AvailableErc20BalanceWhenTheTokenIsNotTheNativeMirrorToken(
    uint256 _balance,
    uint256 _snapshot
  ) external {
    address _token = _mockContract('token');
    // A different published native ERC20 plus a nonzero snapshot prove the deduction only applies to the native ERC20 itself.
    _snapshot = bound(_snapshot, 1, type(uint256).max);
    _harness.seedNativeErc20(makeAddr('nativeMirror'), _NATIVE_ERC20_SCALE);
    _harness.seedNativeBalanceBefore(_snapshot);
    _mockAndExpectTokenBalance(_token, address(_harness), _balance);

    // it should return the full token balance as _balance
    assertEq(_harness.availableErc20Balance(_token), _balance);
  }

  /// @notice The published native ERC20 spends the batch's own native converted to the native ERC20 decimals, flooring any
  ///         sub-raw-unit remainder, without ever reading the native ERC20's `balanceOf`.
  function test_AvailableErc20BalanceWhenTheTokenIsTheNativeMirrorToken(
    uint256 _preBatchWholeAmount,
    uint256 _preBatchRemainder,
    uint256 _batchWholeAmount,
    uint256 _batchRemainder
  ) external {
    // The native ERC20 has no code and no mocked balanceOf, so the returned amount must come from the native balance alone.
    address _token = makeAddr('nativeMirror');
    _preBatchWholeAmount = bound(_preBatchWholeAmount, 0, type(uint64).max);
    _preBatchRemainder = bound(_preBatchRemainder, 0, _NATIVE_ERC20_SCALE - 1);
    _batchWholeAmount = bound(_batchWholeAmount, 0, type(uint64).max);
    _batchRemainder = bound(_batchRemainder, 0, _NATIVE_ERC20_SCALE - 1);
    uint256 _preBatchNative = _preBatchWholeAmount * _NATIVE_ERC20_SCALE + _preBatchRemainder;
    uint256 _batchNative = _batchWholeAmount * _NATIVE_ERC20_SCALE + _batchRemainder;
    vm.deal(address(_harness), _preBatchNative + _batchNative);
    _harness.seedNativeBalanceBefore(_preBatchNative);
    _harness.seedNativeErc20(_token, _NATIVE_ERC20_SCALE);

    // it should return the batch native floored to the mirror decimals
    assertEq(_harness.availableErc20Balance(_token), _batchWholeAmount);
  }

  /// @notice Regression for the hidden-unit bug: rounding the pre-batch native up to the native ERC20 decimals hid one
  ///         batch-introduced raw unit whenever the pre-batch carried a fractional remainder. Flooring the batch
  ///         native instead keeps every raw unit the batch introduced spendable.
  function test_AvailableErc20BalanceWhenAFractionalPreBatchRemainderMeetsAWholeRawUnitBatchValue() external {
    address _token = makeAddr('nativeMirror');
    // Five raw native ERC20 units of pre-batch native plus a seven-wei remainder, then exactly three raw units of batch
    // native; the removed ceil formula charged the remainder a full raw unit and returned two.
    uint256 _preBatchNative = 5 * _NATIVE_ERC20_SCALE + 7;
    uint256 _batchNative = 3 * _NATIVE_ERC20_SCALE;
    vm.deal(address(_harness), _preBatchNative + _batchNative);
    _harness.seedNativeBalanceBefore(_preBatchNative);
    _harness.seedNativeErc20(_token, _NATIVE_ERC20_SCALE);

    // it should return the full batch amount
    assertEq(_harness.availableErc20Balance(_token), 3);
  }

  /// @notice Batch native short of one raw native ERC20 unit floors to zero spendable raw units.
  function test_AvailableErc20BalanceWhenTheBatchNativeIsBelowOneRawMirrorUnit(
    uint256 _preBatchNative,
    uint256 _batchNative
  ) external {
    address _token = makeAddr('nativeMirror');
    _preBatchNative = bound(_preBatchNative, 0, type(uint128).max);
    _batchNative = bound(_batchNative, 0, _NATIVE_ERC20_SCALE - 1);
    vm.deal(address(_harness), _preBatchNative + _batchNative);
    _harness.seedNativeBalanceBefore(_preBatchNative);
    _harness.seedNativeErc20(_token, _NATIVE_ERC20_SCALE);

    // it should return zero as _balance
    assertEq(_harness.availableErc20Balance(_token), 0);
  }

  // --- helpers ---

  /// @notice Derives the collection seeded at `_index`, so multi-entry arrays hold unrelated collections.
  /// @param _seed Fuzzed seed shared by every entry of one test run.
  /// @param _index Entry index within the custody arrays.
  /// @return _collection Collection to seed at the index.
  function _derivedCollection(uint256 _seed, uint256 _index) internal pure returns (address _collection) {
    _collection = address(uint160(uint256(keccak256(abi.encode(_seed, _index)))));
  }

  /// @notice Derives the token id seeded at `_index`, keeping it independent of the entry's collection.
  /// @param _seed Fuzzed seed shared by every entry of one test run.
  /// @param _index Entry index within the custody arrays.
  /// @return _tokenId Token id to seed at the index.
  function _derivedTokenId(uint256 _seed, uint256 _index) internal pure returns (uint256 _tokenId) {
    _tokenId = uint256(keccak256(abi.encode(_index, _seed)));
  }
}
