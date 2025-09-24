// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

/**
 * @title MetarouterState
 * @notice Namespaced transient-storage slots and the accessors over them, shared by the Metarouter and its
 *         command libraries.
 * @dev The command libraries run via `DELEGATECALL` in the router's storage context, so both the router and the
 *      libraries must reference the exact same slots. Keeping the constants and their accessors here is the single
 *      source of truth that prevents the two from drifting. The accessors re-express the router's former custody
 *      virtuals (`_track`/`_msgSender`/`_availableNativeBalance`) as slot reads through `TransientTracking`.
 */
library MetarouterState {
  /**
   * @notice Original caller of the active outer batch, which doubles as the batch-active flag.
   * @dev Set to the outer caller when a batch opens and cleared on close. Because the opener's `msg.sender` can never
   *      be `address(0)` on-chain, a non-zero locker is an exact proxy for "a batch is active", so no separate active
   *      flag is stored.
   * @return The locker slot.
   */
  bytes32 public constant LOCKER_SLOT = keccak256('dromos.metarouter.execution.locker');

  /**
   * @notice Native balance held before the outer batch, excluding its `msg.value`.
   * @return The pre-batch native-balance slot.
   */
  bytes32 public constant NATIVE_BALANCE_BEFORE_SLOT = keccak256('dromos.metarouter.execution.native.before');

  /**
   * @notice ERC20 entry point of the chain's native asset, published by the router when a batch opens.
   * @dev The command libraries run via `DELEGATECALL` and cannot read the router's `NATIVE_ERC20` immutable, so the
   *      batch opening copies it here for `availableErc20Balance`. Zero on a chain whose native asset has no ERC20
   *      entry point, where no token ever matches it.
   * @return The native ERC20 slot.
   */
  bytes32 public constant NATIVE_ERC20_SLOT = keccak256('dromos.metarouter.execution.nativeErc20');

  /**
   * @notice Native value in wei represented by one raw unit of the native ERC20, published by the router when a batch opens.
   * @dev Copied from the router's `NATIVE_ERC20_SCALE` immutable alongside the native ERC20 token, so the decimal conversions
   *      in `availableErc20Balance` and `availableErc20BalanceAfterMessageFee` are reachable via `DELEGATECALL`. Written
   *      only when a native ERC20 exists, so it is never read while zero.
   * @return The native-native ERC20 scale slot.
   */
  bytes32 public constant NATIVE_ERC20_SCALE_SLOT = keccak256('dromos.metarouter.execution.nativeErc20Scale');

  /**
   * @notice CL pool currently authorized to invoke the swap callback.
   * @return The expected-callback-caller slot.
   */
  bytes32 public constant EXPECTED_CALLBACK_CALLER_SLOT = keccak256('dromos.metarouter.callback.caller');

  /**
   * @notice Deduplication flags for ERC20s brought into custody during the active batch.
   * @return The tracked-flag namespace slot.
   */
  bytes32 public constant TRACKED_SLOT = keccak256('dromos.metarouter.sweep.token.tracked');

  /**
   * @notice Length-prefixed array of ERC20s brought into custody during the active batch.
   * @return The tracked-array slot.
   */
  bytes32 public constant ERC20_ARRAY_SLOT = keccak256('dromos.metarouter.sweep.token.array');

  /**
   * @notice Length-prefixed array of NFT collections brought into custody during the active batch, index-aligned
   *         with `NFT_TOKEN_ID_ARRAY_SLOT`.
   * @return The tracked NFT-collection array slot.
   */
  bytes32 public constant NFT_COLLECTION_ARRAY_SLOT = keccak256('dromos.metarouter.nft.collection.array');

  /**
   * @notice Length-prefixed array of NFT token IDs brought into custody during the active batch, index-aligned with
   *         `NFT_COLLECTION_ARRAY_SLOT`.
   * @return The tracked NFT-token-id array slot.
   */
  bytes32 public constant NFT_TOKEN_ID_ARRAY_SLOT = keccak256('dromos.metarouter.nft.tokenId.array');

  /**
   * @notice Namespace seed for an NFT's deduplication-flag slot,
   *         `keccak256(abi.encode(collection, tokenId, NFT_TRACKED_SLOT))`.
   * @return The tracked NFT-flag namespace seed.
   */
  bytes32 public constant NFT_TRACKED_SLOT = keccak256('dromos.metarouter.nft.tracked');

  /**
   * @notice Collection of the single NFT a producer command left for a later command to consume, or zero when none is
   *         in flight; paired with `IN_FLIGHT_TOKEN_ID_SLOT`.
   * @return The in-flight NFT-collection slot.
   */
  bytes32 public constant IN_FLIGHT_COLLECTION_SLOT = keccak256('dromos.metarouter.inflight.collection');

  /**
   * @notice Token id of the single in-flight NFT, paired with `IN_FLIGHT_COLLECTION_SLOT`.
   * @return The in-flight NFT-token-id slot.
   */
  bytes32 public constant IN_FLIGHT_TOKEN_ID_SLOT = keccak256('dromos.metarouter.inflight.tokenId');

  /**
   * @notice Sender the router currently expects an inbound position from, set only around the external call that
   *         returns one, or zero when the router solicited none; paired with `EXPECTED_NFT_TOKEN_ID_SLOT`.
   * @return The expected-NFT-sender slot.
   */
  bytes32 public constant EXPECTED_NFT_SENDER_SLOT = keccak256('dromos.metarouter.nft.expectedSender');

  /**
   * @notice Position the router currently expects back, paired with `EXPECTED_NFT_SENDER_SLOT`.
   * @return The expected-NFT-token-id slot.
   */
  bytes32 public constant EXPECTED_NFT_TOKEN_ID_SLOT = keccak256('dromos.metarouter.nft.expectedTokenId');

  /**
   * @notice Registers a token brought into custody so it is returned to the caller at batch closure.
   * @param _token ERC20 touched during the active batch.
   */
  function trackERC20(address _token) internal {
    TransientTracking.track(ERC20_ARRAY_SLOT, TRACKED_SLOT, _token);
  }

  /**
   * @notice Registers an NFT brought into custody so batch closure can verify it left the execution address.
   * @dev Deduplicated per `(collection, tokenId)`; both are appended to the index-aligned arrays only on the first
   *      touch.
   * @param _collection NFT collection touched during the active batch.
   * @param _tokenId Token id within `_collection`.
   */
  function trackNft(address _collection, uint256 _tokenId) internal {
    bytes32 _flagSlot = _nftFlagSlot(_collection, _tokenId);
    if (TransientTracking.load(_flagSlot) != 0) return;
    TransientTracking.store(_flagSlot, 1);
    TransientTracking.push(NFT_COLLECTION_ARRAY_SLOT, _collection);
    TransientTracking.pushUint(NFT_TOKEN_ID_ARRAY_SLOT, _tokenId);
  }

  /**
   * @notice Clears an NFT's custody deduplication flag.
   * @dev Transient storage is transaction-scoped, so flags must be cleared between batches in one transaction.
   * @param _collection NFT collection whose flag is cleared.
   * @param _tokenId Token id within `_collection`.
   */
  function untrackNft(address _collection, uint256 _tokenId) internal {
    TransientTracking.store(_nftFlagSlot(_collection, _tokenId), 0);
  }

  /**
   * @notice Resets the NFT custody arrays for reuse in the same transaction.
   */
  function clearNftArrays() internal {
    TransientTracking.clear(NFT_COLLECTION_ARRAY_SLOT);
    TransientTracking.clear(NFT_TOKEN_ID_ARRAY_SLOT);
  }

  /**
   * @notice Records the position an inbound transfer is expected to return, and the sender it must come from, ahead of
   *         the external call that returns it.
   * @dev Mirrors the expected-callback-caller handshake the CL swap path uses: the sender slot must be empty, so a
   *      command cannot overwrite another command's pending authorization. `onERC721Received` accepts a position only
   *      while this is set and both the transfer's `from` and its token id match; the setting command clears it once
   *      its operation returns. Left unset the router solicits nothing, and an unsolicited transfer cannot mint a
   *      custody flag a later command could operate. The withdrawal command names the exact position it asks back, so
   *      binding the id as well keeps a misbehaving source from substituting another position it custodies.
   * @param _sender Address the position is expected to arrive from.
   * @param _tokenId Position the sender is expected to return.
   */
  function setExpectedNft(address _sender, uint256 _tokenId) internal {
    if (TransientTracking.load(EXPECTED_NFT_SENDER_SLOT) != 0) revert IMetarouter.NftSenderNotCleared();
    TransientTracking.store(EXPECTED_NFT_SENDER_SLOT, uint256(uint160(_sender)));
    TransientTracking.store(EXPECTED_NFT_TOKEN_ID_SLOT, _tokenId);
  }

  /**
   * @notice Clears the expected NFT once the operation that returns a position has completed.
   * @dev Unconditional, so an operation that returned no position leaves no authorization behind for a later command
   *      in the same batch to inherit.
   */
  function clearExpectedNft() internal {
    TransientTracking.store(EXPECTED_NFT_SENDER_SLOT, 0);
    TransientTracking.store(EXPECTED_NFT_TOKEN_ID_SLOT, 0);
  }

  /**
   * @notice Records the single NFT a producer command leaves for a later command to consume.
   * @dev Only one NFT may be in flight at a time, so a second producer before the first is consumed reverts. The
   *      producer also tracks the NFT for custody so closure verifies it left even if no later command consumes it.
   * @param _collection Collection of the produced NFT.
   * @param _tokenId Token id of the produced NFT.
   */
  function setInFlightNft(address _collection, uint256 _tokenId) internal {
    if (TransientTracking.load(IN_FLIGHT_COLLECTION_SLOT) != 0) revert IMetarouter.InFlightNftPresent();
    TransientTracking.store(IN_FLIGHT_COLLECTION_SLOT, uint256(uint160(_collection)));
    TransientTracking.store(IN_FLIGHT_TOKEN_ID_SLOT, _tokenId);
  }

  /**
   * @notice Clears the in-flight slots when they hold the given NFT.
   * @dev Called by a command that finishes using the in-flight NFT (staking, transferring, or burning it).
   *      Batch closure never clears these slots, so consuming here is the only thing keeping a stale pair from
   *      surviving into a later batch of the same transaction, where the next producer command would revert with
   *      `InFlightNftPresent`. A no-op when the NFT is not the in-flight one.
   * @param _collection Collection of the consumed NFT.
   * @param _tokenId Token id of the consumed NFT.
   */
  function consumeInFlightNft(address _collection, uint256 _tokenId) internal {
    (address _inFlightCollection, uint256 _inFlightTokenId) = inFlightNft();
    if (_inFlightCollection == _collection && _inFlightTokenId == _tokenId) {
      TransientTracking.store(IN_FLIGHT_COLLECTION_SLOT, 0);
      TransientTracking.store(IN_FLIGHT_TOKEN_ID_SLOT, 0);
    }
  }

  /**
   * @notice Returns the position the router currently expects back and the sender it must come from.
   * @return _sender Expected sender, or zero when the router solicited no position.
   * @return _tokenId Position the expected sender must return.
   */
  function expectedNft() internal view returns (address _sender, uint256 _tokenId) {
    _sender = address(uint160(TransientTracking.load(EXPECTED_NFT_SENDER_SLOT)));
    _tokenId = TransientTracking.load(EXPECTED_NFT_TOKEN_ID_SLOT);
  }

  /**
   * @notice Returns the in-flight NFT, or `(address(0), 0)` when none is in flight.
   * @return _collection In-flight NFT collection.
   * @return _tokenId In-flight NFT token id.
   */
  function inFlightNft() internal view returns (address _collection, uint256 _tokenId) {
    _collection = address(uint160(TransientTracking.load(IN_FLIGHT_COLLECTION_SLOT)));
    _tokenId = TransientTracking.load(IN_FLIGHT_TOKEN_ID_SLOT);
  }

  /**
   * @notice Resolves a command's position input, substituting the in-flight token id for the zero sentinel.
   * @dev The position manager never mints token id zero, so zero is a safe sentinel for "operate the NFT the batch just
   *      produced" whose id the plan could not know in advance. The sentinel resolves only when an in-flight NFT of the
   *      expected collection is present, which binds the reference to the producer's exact output.
   * @param _collection Collection the command operates on, matched against the in-flight collection for the sentinel.
   * @param _tokenId Token id from the command, or zero to use the in-flight NFT.
   * @return _resolved Concrete token id the command acts on.
   */
  function resolvePositionId(address _collection, uint256 _tokenId) internal view returns (uint256 _resolved) {
    if (_tokenId != 0) return _tokenId;
    (address _inFlightCollection, uint256 _inFlightTokenId) = inFlightNft();
    if (_inFlightCollection != _collection) revert IMetarouter.NoInFlightNft();
    return _inFlightTokenId;
  }

  /**
   * @notice Returns whether an NFT is in the router's custody for the active batch.
   * @dev Reads the NFT's own flag slot, not membership of the custody arrays. The two diverge: a command that releases
   *      a position clears the flag while its array entry stays behind until closure resets the array lengths.
   * @param _collection NFT collection to query.
   * @param _tokenId Token id within `_collection`.
   * @return _inCustody Whether the NFT entered custody during the active batch and has not been released.
   */
  function isNftInCustody(address _collection, uint256 _tokenId) internal view returns (bool _inCustody) {
    return TransientTracking.load(_nftFlagSlot(_collection, _tokenId)) != 0;
  }

  /**
   * @notice Number of NFTs brought into custody during the active batch.
   * @return _length Count of tracked NFTs.
   */
  function trackedNftLength() internal view returns (uint256 _length) {
    return TransientTracking.length(NFT_COLLECTION_ARRAY_SLOT);
  }

  /**
   * @notice Returns a tracked NFT by index.
   * @param _index Element index to read.
   * @return _collection NFT collection at the index.
   * @return _tokenId Token id at the index.
   */
  function trackedNftAt(uint256 _index) internal view returns (address _collection, uint256 _tokenId) {
    _collection = TransientTracking.at(NFT_COLLECTION_ARRAY_SLOT, _index);
    _tokenId = TransientTracking.atUint(NFT_TOKEN_ID_ARRAY_SLOT, _index);
  }

  /**
   * @notice Returns the logical sender (outer caller) for the current batch.
   * @return _sender Account whose assets and approvals command modules may use.
   */
  function msgSender() internal view returns (address _sender) {
    return address(uint160(TransientTracking.load(LOCKER_SLOT)));
  }

  /**
   * @notice Returns native ETH introduced during the active batch, excluding the pre-batch balance.
   * @return _balance Native ETH available to spend this batch.
   */
  function availableNativeBalance() internal view returns (uint256 _balance) {
    uint256 _nativeBalance = address(this).balance;
    uint256 _nativeBalanceBefore = TransientTracking.load(NATIVE_BALANCE_BEFORE_SLOT);
    if (_nativeBalance < _nativeBalanceBefore) revert IMetarouter.PreBatchNativeBalanceSpent();
    return _nativeBalance - _nativeBalanceBefore;
  }

  /**
   * @notice Returns a token balance the active batch may spend, which for the chain's native ERC20 is the
   *         batch's own native converted to the native ERC20 decimals.
   * @dev The native ERC20's `balanceOf` is the native balance in token decimals, so it is not read: spending the returned
   *      amount moves that many raw native ERC20 units, and flooring the batch native keeps the movement within what the
   *      batch introduced. The floored remainder only returns through the native refund. Every other token spends its
   *      full balance.
   * @param _token ERC20 whose available balance is read.
   * @return _balance Token balance available to spend this batch.
   */
  function availableErc20Balance(address _token) internal view returns (uint256 _balance) {
    if (_token == nativeErc20()) return availableNativeBalance() / nativeErc20Scale();
    _balance = IERC20(_token).balanceOf(address(this));
  }

  /**
   * @notice Returns the native ERC20 balance the active batch may spend once a committed native message fee
   *         is reserved.
   * @dev A native ERC20 pull and the native message fee draw from the same batch native, so the fee is deducted from the
   *      batch native before the conversion to the native ERC20 decimals floors it. Saturates to zero instead of
   *      underflowing. Only meaningful for the native ERC20; callers match the token against `nativeErc20`
   *      first.
   * @param _messageFee Native message fee committed alongside the native ERC20 spend.
   * @return _balance Token balance available to spend this batch after the fee reservation.
   */
  function availableErc20BalanceAfterMessageFee(uint256 _messageFee) internal view returns (uint256 _balance) {
    uint256 _nativeBalance = availableNativeBalance();
    if (_messageFee >= _nativeBalance) return 0;
    return (_nativeBalance - _messageFee) / nativeErc20Scale();
  }

  /**
   * @notice Returns the chain's native ERC20 published for the active batch.
   * @return _token The native ERC20, or zero when the chain has none.
   */
  function nativeErc20() internal view returns (address _token) {
    return address(uint160(TransientTracking.load(NATIVE_ERC20_SLOT)));
  }

  /**
   * @notice Returns the native value per raw native ERC20 unit published for the active batch.
   * @return _scale Native value per raw native ERC20 unit; meaningful only while a native ERC20 is published.
   */
  function nativeErc20Scale() internal view returns (uint256 _scale) {
    return TransientTracking.load(NATIVE_ERC20_SCALE_SLOT);
  }

  /**
   * @notice Derives the transient deduplication-flag slot for an NFT.
   * @param _collection NFT collection.
   * @param _tokenId Token id within `_collection`.
   * @return _slot Transient slot holding the NFT's custody flag.
   */
  function _nftFlagSlot(address _collection, uint256 _tokenId) private pure returns (bytes32 _slot) {
    return keccak256(abi.encode(_collection, _tokenId, NFT_TRACKED_SLOT));
  }
}
