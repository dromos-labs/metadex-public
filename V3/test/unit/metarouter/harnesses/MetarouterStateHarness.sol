// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

/// @title MetarouterStateHarness
/// @notice External boundary over the internal `MetarouterState` accessors, plus raw windows onto the transient slots
///         they read and write, so the library can be exercised without a router or a driven batch.
/// @dev The `seed*` writers and the raw readers go straight to the slots through `TransientTracking`, never through a
///      sister `MetarouterState` accessor, so each test drives exactly one library function. The raw readers also
///      re-derive the namespaced flag slot independently of the library's private `_nftFlagSlot`, which keeps the
///      assertions from restating the derivation under test. Transient storage lives for the whole transaction, so a
///      seed call and the operation that follows it observe the same slots even across the external-call boundary.
contract MetarouterStateHarness {
  // --- library functions under test ---

  /// @notice Tracks an ERC20 through `MetarouterState.trackERC20`.
  /// @param _token ERC20 to bring into custody.
  function trackERC20(address _token) external {
    MetarouterState.trackERC20(_token);
  }

  /// @notice Tracks an NFT through `MetarouterState.trackNft`.
  /// @param _collection NFT collection to bring into custody.
  /// @param _tokenId Token id within `_collection`.
  function trackNft(address _collection, uint256 _tokenId) external {
    MetarouterState.trackNft(_collection, _tokenId);
  }

  /// @notice Clears an NFT's custody flag through `MetarouterState.untrackNft`.
  /// @param _collection NFT collection whose flag is cleared.
  /// @param _tokenId Token id within `_collection`.
  function untrackNft(address _collection, uint256 _tokenId) external {
    MetarouterState.untrackNft(_collection, _tokenId);
  }

  /// @notice Resets the NFT custody arrays through `MetarouterState.clearNftArrays`.
  function clearNftArrays() external {
    MetarouterState.clearNftArrays();
  }

  /// @notice Records an in-flight NFT through `MetarouterState.setInFlightNft`.
  /// @param _collection Collection of the produced NFT.
  /// @param _tokenId Token id of the produced NFT.
  function setInFlightNft(address _collection, uint256 _tokenId) external {
    MetarouterState.setInFlightNft(_collection, _tokenId);
  }

  /// @notice Consumes an in-flight NFT through `MetarouterState.consumeInFlightNft`.
  /// @param _collection Collection of the consumed NFT.
  /// @param _tokenId Token id of the consumed NFT.
  function consumeInFlightNft(address _collection, uint256 _tokenId) external {
    MetarouterState.consumeInFlightNft(_collection, _tokenId);
  }

  /// @notice Reads the in-flight NFT through `MetarouterState.inFlightNft`.
  /// @return _collection In-flight NFT collection, or zero when none is in flight.
  /// @return _tokenId In-flight NFT token id.
  function inFlightNft() external view returns (address _collection, uint256 _tokenId) {
    (_collection, _tokenId) = MetarouterState.inFlightNft();
  }

  /// @notice Resolves a position input through `MetarouterState.resolvePositionId`.
  /// @param _collection Collection the command operates on.
  /// @param _tokenId Token id from the command, or zero to use the in-flight NFT.
  /// @return _resolved Concrete token id the command acts on.
  function resolvePositionId(address _collection, uint256 _tokenId) external view returns (uint256 _resolved) {
    _resolved = MetarouterState.resolvePositionId(_collection, _tokenId);
  }

  /// @notice Queries NFT custody through `MetarouterState.isNftInCustody`.
  /// @param _collection NFT collection to query.
  /// @param _tokenId Token id within `_collection`.
  /// @return _inCustody Whether the NFT is in custody for the active batch.
  function isNftInCustody(address _collection, uint256 _tokenId) external view returns (bool _inCustody) {
    _inCustody = MetarouterState.isNftInCustody(_collection, _tokenId);
  }

  /// @notice Reads the tracked-NFT count through `MetarouterState.trackedNftLength`.
  /// @return _length Count of tracked NFTs.
  function trackedNftLength() external view returns (uint256 _length) {
    _length = MetarouterState.trackedNftLength();
  }

  /// @notice Reads a tracked NFT by index through `MetarouterState.trackedNftAt`.
  /// @param _index Element index to read.
  /// @return _collection NFT collection at the index.
  /// @return _tokenId Token id at the index.
  function trackedNftAt(uint256 _index) external view returns (address _collection, uint256 _tokenId) {
    (_collection, _tokenId) = MetarouterState.trackedNftAt(_index);
  }

  /// @notice Reads the logical sender through `MetarouterState.msgSender`.
  /// @return _sender Account whose assets and approvals command modules may use.
  function msgSender() external view returns (address _sender) {
    _sender = MetarouterState.msgSender();
  }

  /// @notice Reads the spendable native balance through `MetarouterState.availableNativeBalance`.
  /// @return _balance Native ETH available to spend this batch.
  function availableNativeBalance() external view returns (uint256 _balance) {
    _balance = MetarouterState.availableNativeBalance();
  }

  /// @notice Reads a token's spendable balance through `MetarouterState.availableErc20Balance`.
  /// @param _token ERC20 whose available balance is read.
  /// @return _balance Token balance available to spend this batch.
  function availableErc20Balance(address _token) external view returns (uint256 _balance) {
    _balance = MetarouterState.availableErc20Balance(_token);
  }

  // --- raw slot writers ---

  /// @notice Writes the locker slot directly, as the router's batch opening would.
  /// @param _sender Logical sender to seed.
  function seedLocker(address _sender) external {
    TransientTracking.store(MetarouterState.LOCKER_SLOT, uint256(uint160(_sender)));
  }

  /// @notice Writes the pre-batch native-balance snapshot directly, as the router's batch opening would.
  /// @param _balance Snapshot value to seed.
  function seedNativeBalanceBefore(uint256 _balance) external {
    TransientTracking.store(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT, _balance);
  }

  /// @notice Writes the native ERC20 and its scale directly, as the router's batch opening would.
  /// @param _token Native ERC20 to seed.
  /// @param _scale Native value per raw native ERC20 unit to seed.
  function seedNativeErc20(address _token, uint256 _scale) external {
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SLOT, uint256(uint160(_token)));
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SCALE_SLOT, _scale);
  }

  /// @notice Writes both in-flight slots directly, bypassing the `setInFlightNft` occupancy guard.
  /// @param _collection In-flight NFT collection to seed.
  /// @param _tokenId In-flight NFT token id to seed.
  function seedInFlightNft(address _collection, uint256 _tokenId) external {
    TransientTracking.store(MetarouterState.IN_FLIGHT_COLLECTION_SLOT, uint256(uint160(_collection)));
    TransientTracking.store(MetarouterState.IN_FLIGHT_TOKEN_ID_SLOT, _tokenId);
  }

  /// @notice Records an ERC20 as already in custody directly, writing both its flag and its array entry.
  /// @param _token ERC20 to seed as tracked.
  function seedTrackedErc20(address _token) external {
    TransientTracking.storeMapping(MetarouterState.TRACKED_SLOT, _token, 1);
    TransientTracking.push(MetarouterState.ERC20_ARRAY_SLOT, _token);
  }

  /// @notice Sets an NFT's custody flag directly, without appending it to the custody arrays.
  /// @param _collection NFT collection whose flag is set.
  /// @param _tokenId Token id within `_collection`.
  function seedNftFlag(address _collection, uint256 _tokenId) external {
    TransientTracking.store(_nftFlagSlot(_collection, _tokenId), 1);
  }

  /// @notice Appends an NFT to the index-aligned custody arrays directly, without setting its flag.
  /// @param _collection NFT collection to append.
  /// @param _tokenId Token id to append.
  function seedTrackedNft(address _collection, uint256 _tokenId) external {
    TransientTracking.push(MetarouterState.NFT_COLLECTION_ARRAY_SLOT, _collection);
    TransientTracking.pushUint(MetarouterState.NFT_TOKEN_ID_ARRAY_SLOT, _tokenId);
  }

  // --- raw slot readers ---

  /// @notice Reads both in-flight slots as raw words, so assertions never route through `inFlightNft`.
  /// @return _collection Raw value held in the in-flight collection slot.
  /// @return _tokenId Raw value held in the in-flight token-id slot.
  function inFlightSlots() external view returns (uint256 _collection, uint256 _tokenId) {
    _collection = TransientTracking.load(MetarouterState.IN_FLIGHT_COLLECTION_SLOT);
    _tokenId = TransientTracking.load(MetarouterState.IN_FLIGHT_TOKEN_ID_SLOT);
  }

  /// @notice Reads an NFT's custody flag from its independently derived slot.
  /// @param _collection NFT collection whose flag is read.
  /// @param _tokenId Token id within `_collection`.
  /// @return _flag Raw value held in the NFT's flag slot.
  function nftFlag(address _collection, uint256 _tokenId) external view returns (uint256 _flag) {
    _flag = TransientTracking.load(_nftFlagSlot(_collection, _tokenId));
  }

  /// @notice Reads the length of the NFT collection custody array.
  /// @return _length Number of entries in the collection array.
  function nftCollectionLength() external view returns (uint256 _length) {
    _length = TransientTracking.length(MetarouterState.NFT_COLLECTION_ARRAY_SLOT);
  }

  /// @notice Reads an entry of the NFT collection custody array.
  /// @param _index Element index to read.
  /// @return _collection Collection stored at the index.
  function nftCollectionAt(uint256 _index) external view returns (address _collection) {
    _collection = TransientTracking.at(MetarouterState.NFT_COLLECTION_ARRAY_SLOT, _index);
  }

  /// @notice Reads the length of the NFT token-id custody array.
  /// @return _length Number of entries in the token-id array.
  function nftTokenIdLength() external view returns (uint256 _length) {
    _length = TransientTracking.length(MetarouterState.NFT_TOKEN_ID_ARRAY_SLOT);
  }

  /// @notice Reads an entry of the NFT token-id custody array.
  /// @param _index Element index to read.
  /// @return _tokenId Token id stored at the index.
  function nftTokenIdAt(uint256 _index) external view returns (uint256 _tokenId) {
    _tokenId = TransientTracking.atUint(MetarouterState.NFT_TOKEN_ID_ARRAY_SLOT, _index);
  }

  /// @notice Reads an ERC20's custody deduplication flag.
  /// @param _token Token whose flag is read.
  /// @return _flag Raw value held in the token's tracked-flag slot.
  function erc20Flag(address _token) external view returns (uint256 _flag) {
    _flag = TransientTracking.loadMapping(MetarouterState.TRACKED_SLOT, _token);
  }

  /// @notice Reads the length of the tracked-ERC20 array.
  /// @return _length Number of entries in the tracked-ERC20 array.
  function trackedErc20Length() external view returns (uint256 _length) {
    _length = TransientTracking.length(MetarouterState.ERC20_ARRAY_SLOT);
  }

  /// @notice Reads an entry of the tracked-ERC20 array.
  /// @param _index Element index to read.
  /// @return _token Token stored at the index.
  function trackedErc20At(uint256 _index) external view returns (address _token) {
    _token = TransientTracking.at(MetarouterState.ERC20_ARRAY_SLOT, _index);
  }

  /// @notice Re-derives an NFT's flag slot, mirroring the library's namespacing independently of its private helper.
  /// @param _collection NFT collection.
  /// @param _tokenId Token id within `_collection`.
  /// @return _slot Transient slot holding the NFT's custody flag.
  function _nftFlagSlot(address _collection, uint256 _tokenId) private pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_collection, _tokenId, MetarouterState.NFT_TRACKED_SLOT));
  }
}
