// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {Metarouter} from 'V3/metarouter/Metarouter.sol';
import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/// @title MetarouterHarness
/// @notice Metarouter plus read-only windows into the execution transient slots, so tests can assert the closure
///         leaves no transient state behind.
/// @dev Adds no behavior; every getter is a transient read through `MetarouterState`/`TransientTracking` in the
///      router's own storage context. Transient storage persists across the external-call boundary within a test
///      transaction, so these views observe the exact state `execute` left after `_endExecution`.
contract MetarouterHarness is Metarouter {
  /// @notice Forwards the deployment arguments to the Metarouter constructor.
  /// @param _weth Wrapped native token used by payment commands.
  /// @param _voter Leaf Voter used to validate gauge targets and, on leaf, to resolve the emission token.
  /// @param _rootVoter Root Voter used only on root to resolve the emission token via its Minter.
  /// @param _positionManager Canonical CL position manager the router stakes, unstakes, and takes NFT custody through.
  /// @param _icaRouter Interchain account router used by the cross-chain commands.
  /// @param _relayFactory RelayFactory used only on root to authenticate deposit relays; unused on leaf.
  /// @param _factoryRegistry Registry used to authenticate swap pool factories.
  /// @param _nativeErc20 ERC20 entry point of the chain's native asset, or zero when the chain has none.
  constructor(
    IWETH _weth,
    ILeafVoter _voter,
    IVoter _rootVoter,
    INonfungiblePositionManager _positionManager,
    IInterchainAccountRouter _icaRouter,
    IRelayFactory _relayFactory,
    IFactoryRegistry _factoryRegistry,
    IERC20 _nativeErc20
  )
    Metarouter(_weth, _voter, _rootVoter, _positionManager, _icaRouter, _relayFactory, _factoryRegistry, _nativeErc20)
  {}

  /**
   * @notice Seeds the expected CL callback caller for focused callback tests.
   * @param _caller Caller to authorize.
   */
  function seedExpectedCallbackCaller(address _caller) external {
    TransientTracking.store(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT, uint256(uint160(_caller)));
  }

  /**
   * @notice Reads the currently expected CL callback caller.
   * @return _caller Authorized callback caller, or zero when none is armed.
   */
  function expectedCallbackCaller() external view returns (address _caller) {
    _caller = address(uint160(TransientTracking.load(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT)));
  }

  /**
   * @notice Seeds the expected inbound position and its sender for focused receiver-hook tests.
   * @dev Writes the slots directly, as a withdrawal command's setting would, so the hook is exercised without driving
   *      a sister command on the contract under test.
   * @param _sender Sender to authorize an inbound position from.
   * @param _tokenId Position the sender is authorized to return.
   */
  function seedExpectedNft(address _sender, uint256 _tokenId) external {
    TransientTracking.store(MetarouterState.EXPECTED_NFT_SENDER_SLOT, uint256(uint160(_sender)));
    TransientTracking.store(MetarouterState.EXPECTED_NFT_TOKEN_ID_SLOT, _tokenId);
  }

  /**
   * @notice Reads the currently expected inbound position and its sender.
   * @return _sender Authorized NFT sender, or zero when none is set.
   * @return _tokenId Position the authorized sender must return.
   */
  function expectedNft() external view returns (address _sender, uint256 _tokenId) {
    (_sender, _tokenId) = MetarouterState.expectedNft();
  }

  /// @notice Seeds the batch-active locker so a receiver-hook call can be exercised outside a driven batch.
  /// @dev A non-zero locker is the batch-active flag (`MetarouterState.LOCKER_SLOT`), so this makes the router treat a
  ///      batch as active for `onERC721Received`; callers clear it before driving a real `execute`.
  /// @param _active Value to store in the locker slot; non-zero marks a batch active.
  function setExecutionActive(uint256 _active) external {
    TransientTracking.store(MetarouterState.LOCKER_SLOT, _active);
  }

  /// @notice Seeds the pre-batch native snapshot, the native ERC20 slot, and its unit scale directly, as
  ///         `_beginExecution` would when a batch opens.
  /// @dev Focused command tests bypass `execute`, so the accounting the opening writes is seeded here without
  ///      exercising the batch lifecycle on the contract under test.
  /// @param _nativeBalanceBefore Pre-batch native balance to record as the snapshot.
  /// @param _nativeErc20 Native ERC20 to publish for balance resolution.
  /// @param _nativeErc20Scale Native value per raw native ERC20 unit to publish alongside the native ERC20.
  function seedNativeAccounting(
    uint256 _nativeBalanceBefore,
    address _nativeErc20,
    uint256 _nativeErc20Scale
  ) external {
    TransientTracking.store(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT, _nativeBalanceBefore);
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SLOT, uint256(uint160(_nativeErc20)));
    TransientTracking.store(MetarouterState.NATIVE_ERC20_SCALE_SLOT, _nativeErc20Scale);
  }

  /// @notice Seeds an NFT into the batch custody arrays directly, without driving the receiver hook.
  /// @dev Writes the same transient custody state `onERC721Received` would, so a custody-precondition test sets up its
  ///      state without exercising a sister entry point on the contract under test.
  /// @param _collection NFT collection to record as custodied.
  /// @param _tokenId Token id within `_collection`.
  function trackNft(address _collection, uint256 _tokenId) external {
    MetarouterState.trackNft(_collection, _tokenId);
  }

  /// @notice Seeds an NFT's complete custody state directly for isolated command tests.
  /// @dev Derives the flag slot independently and writes both index-aligned arrays without calling
  ///      `MetarouterState.trackNft`, so a defect in that writer cannot mask a command test.
  /// @param _collection NFT collection to record as custodied.
  /// @param _tokenId Token id within `_collection`.
  function seedNftCustody(address _collection, uint256 _tokenId) external {
    bytes32 _flagSlot = keccak256(abi.encode(_collection, _tokenId, MetarouterState.NFT_TRACKED_SLOT));
    TransientTracking.store(_flagSlot, 1);
    TransientTracking.push(MetarouterState.NFT_COLLECTION_ARRAY_SLOT, _collection);
    TransientTracking.pushUint(MetarouterState.NFT_TOKEN_ID_ARRAY_SLOT, _tokenId);
  }

  /// @notice Reads the number of NFTs taken into custody during the active batch.
  /// @return _length Count of tracked NFTs.
  function trackedNftLength() external view returns (uint256 _length) {
    _length = MetarouterState.trackedNftLength();
  }

  /// @notice Reads a tracked NFT by index.
  /// @param _index Element index to read.
  /// @return _collection NFT collection at the index.
  /// @return _tokenId Token id at the index.
  function trackedNftAt(uint256 _index) external view returns (address _collection, uint256 _tokenId) {
    (_collection, _tokenId) = MetarouterState.trackedNftAt(_index);
  }

  /// @notice Reads the pre-batch native-balance snapshot slot.
  /// @return _balance Raw value held in the pre-batch native-balance slot.
  function nativeBalanceBefore() external view returns (uint256 _balance) {
    _balance = TransientTracking.load(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT);
  }

  /// @notice Reads the length of the tracked-ERC20 transient array.
  /// @return _length Number of entries in the tracked-ERC20 array.
  function trackedLength() external view returns (uint256 _length) {
    _length = TransientTracking.length(MetarouterState.ERC20_ARRAY_SLOT);
  }

  /// @notice Reads the deduplication flag for a tracked token.
  /// @param _token Token whose tracked flag is read.
  /// @return _flag Raw value held in the token's tracked-flag slot.
  function tracked(address _token) external view returns (uint256 _flag) {
    _flag = TransientTracking.loadMapping(MetarouterState.TRACKED_SLOT, _token);
  }

  /// @notice Seeds the in-flight NFT slots directly, as a producer command would.
  /// @param _collection In-flight NFT collection to record.
  /// @param _tokenId In-flight NFT token id to record.
  function setInFlightNft(address _collection, uint256 _tokenId) external {
    MetarouterState.setInFlightNft(_collection, _tokenId);
  }

  /// @notice Seeds the in-flight NFT slots directly for isolated command tests.
  /// @dev Bypasses `MetarouterState.setInFlightNft` so the command test does not depend on a sister state writer.
  /// @param _collection In-flight NFT collection to record.
  /// @param _tokenId In-flight NFT token id to record.
  function seedInFlightNft(address _collection, uint256 _tokenId) external {
    TransientTracking.store(MetarouterState.IN_FLIGHT_COLLECTION_SLOT, uint256(uint160(_collection)));
    TransientTracking.store(MetarouterState.IN_FLIGHT_TOKEN_ID_SLOT, _tokenId);
  }

  /// @notice Reads the in-flight NFT slots.
  /// @return _collection In-flight NFT collection, or zero when none is in flight.
  /// @return _tokenId In-flight NFT token id.
  function inFlightNft() external view returns (address _collection, uint256 _tokenId) {
    (_collection, _tokenId) = MetarouterState.inFlightNft();
  }
}
