// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @title LeafVoterCallLog
 * @notice Append-only log of the external calls a single LeafVoter allocation pass makes.
 * @dev Foundry cannot assert the relative order of two different external calls, so the reward and
 *      orchestrator doubles in this file append to one shared log and the tests read the ordering off it.
 *      Deliberately dumb: it records what it is handed and never calls back into the voter.
 */
contract LeafVoterCallLog {
  /**
   * @notice Which external surface recorded an entry.
   * @param Checkpoint A reward contract's `checkpoint`.
   * @param Deallocate The orchestrator's `dispatch` of a deallocation return.
   */
  enum CallKind {
    Checkpoint,
    Deallocate
  }

  /**
   * @notice One recorded external call.
   * @param kind Which surface recorded it.
   * @param recorder The double that recorded it, so a test can map an entry back to its gauge.
   * @param tokenId Token the call was made for.
   * @param amount Allocation the reward was checkpointed against, or the amount being deallocated.
   * @param stakeEnd Stake expiry the reward was checkpointed against. Zero on a `Deallocate`.
   * @param data Opaque payload the reward was checkpointed with. Empty on a `Deallocate`.
   */
  struct Entry {
    CallKind kind;
    address recorder;
    uint256 tokenId;
    uint128 amount;
    uint48 stakeEnd;
    bytes data;
  }

  /// @notice Entries in the order they were recorded.
  Entry[] internal _entries;

  /**
   * @notice Append `_entry` to the log.
   * @param _entry Entry to record.
   */
  function record(Entry memory _entry) external {
    _entries.push();
    _entries[_entries.length - 1] = _entry;
  }

  /**
   * @notice Number of recorded entries.
   * @return _length Entry count.
   */
  function length() external view returns (uint256 _length) {
    _length = _entries.length;
  }

  /**
   * @notice Read a recorded entry.
   * @param _index Position in the log.
   * @return _entry The entry at `_index`.
   */
  function entryAt(uint256 _index) external view returns (Entry memory _entry) {
    _entry = _entries[_index];
  }
}

/**
 * @title RecordingReward
 * @notice Reward-contract double that appends every `checkpoint` it receives to a shared log.
 * @dev Stands in for `vm.mockCall` where the test needs the call's position in the pass, not just its
 *      arguments. Makes no call back into the voter.
 */
contract RecordingReward {
  /// @notice Shared log every double in a pass appends to.
  LeafVoterCallLog public immutable LOG;

  /**
   * @notice Wire the double to a log.
   * @param _log Shared log to append to.
   */
  constructor(LeafVoterCallLog _log) {
    LOG = _log;
  }

  /**
   * @notice Record a checkpoint. Mirrors `IVotingRewardsManager.checkpoint`.
   * @param _tokenId The tokenId whose position is being checkpointed.
   * @param _allocation Weight the tokenId currently has on the gauge.
   * @param _stakeEnd Stake expiry. Zero encodes a permanent stake.
   * @param _data Opaque per-gauge payload carried from the vote.
   */
  function checkpoint(uint256 _tokenId, uint128 _allocation, uint48 _stakeEnd, bytes calldata _data) external {
    LOG.record(
      LeafVoterCallLog.Entry({
        kind: LeafVoterCallLog.CallKind.Checkpoint,
        recorder: address(this),
        tokenId: _tokenId,
        amount: _allocation,
        stakeEnd: _stakeEnd,
        data: _data
      })
    );
  }
}

/**
 * @title ReenteringReward
 * @notice Reward-contract double that rewrites the voter's storage from inside its own `checkpoint`,
 *         then records the call.
 * @dev Models a hostile reward contract. Every entrypoint that could mutate a token's allocation or
 *      snapshot is either `nonReentrant` (`allocateGauges`, `applyGaugeAllocations`,
 *      `applyEmergencyDeallocation`, `settleGauge`) or restricted to the orchestrator, so a genuine
 *      reentrant call is unreachable from here. The armed writes reproduce the same effect directly:
 *      whatever the old `_checkpointReward` re-read from storage per call is changed underneath it while
 *      the checkpoint loop is still running.
 */
contract ReenteringReward {
  /**
   * @notice One storage word to overwrite on the voter mid-checkpoint.
   * @param slot Storage slot to write.
   * @param value Word to write into `slot`.
   */
  struct StorageWrite {
    bytes32 slot;
    bytes32 value;
  }

  /// @notice Foundry cheatcode handle, used to rewrite the voter's storage mid-call.
  Vm internal constant _VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  /// @notice Shared log every double in a pass appends to.
  LeafVoterCallLog public immutable LOG;
  /// @notice Voter whose storage is rewritten mid-checkpoint.
  address public immutable VOTER;

  /// @notice Writes applied on every `checkpoint`.
  StorageWrite[] internal _writes;

  /**
   * @notice Wire the double to a log and its target voter.
   * @param _log Shared log to append to.
   * @param _voter Voter whose storage is rewritten mid-checkpoint.
   */
  constructor(LeafVoterCallLog _log, address _voter) {
    LOG = _log;
    VOTER = _voter;
  }

  /**
   * @notice Arm the storage words this double overwrites when it is checkpointed.
   * @param _storageWrites Slot and value pairs to apply, in order.
   */
  function arm(StorageWrite[] calldata _storageWrites) external {
    delete _writes;
    for (uint256 _i; _i < _storageWrites.length; ++_i) {
      _writes.push(_storageWrites[_i]);
    }
  }

  /**
   * @notice Apply the armed storage writes, then record the checkpoint. Mirrors
   *         `IVotingRewardsManager.checkpoint`.
   * @param _tokenId The tokenId whose position is being checkpointed.
   * @param _allocation Weight the tokenId currently has on the gauge.
   * @param _stakeEnd Stake expiry. Zero encodes a permanent stake.
   * @param _data Opaque per-gauge payload carried from the vote.
   */
  function checkpoint(uint256 _tokenId, uint128 _allocation, uint48 _stakeEnd, bytes calldata _data) external {
    uint256 _length = _writes.length;
    for (uint256 _i; _i < _length; ++_i) {
      _VM.store(VOTER, _writes[_i].slot, _writes[_i].value);
    }

    LOG.record(
      LeafVoterCallLog.Entry({
        kind: LeafVoterCallLog.CallKind.Checkpoint,
        recorder: address(this),
        tokenId: _tokenId,
        amount: _allocation,
        stakeEnd: _stakeEnd,
        data: _data
      })
    );
  }
}

/**
 * @title RecordingOrchestrator
 * @notice Orchestrator double that appends every deallocation `dispatch` it receives to a shared log.
 * @dev Etched over the voter's immutable `ORCHESTRATOR` so the dispatch lands in the same log as the
 *      reward checkpoints. Only the token and amount are recorded; the remaining dispatch arguments are
 *      pinned by `vm.expectCall` in the tests.
 */
contract RecordingOrchestrator {
  /// @notice Shared log every double in a pass appends to.
  LeafVoterCallLog public immutable LOG;

  /**
   * @notice Wire the double to a log.
   * @param _log Shared log to append to.
   */
  constructor(LeafVoterCallLog _log) {
    LOG = _log;
  }

  /**
   * @notice Record a dispatched deallocation return.
   * @param _payload Encoded `DeallocationMessageBody`.
   */
  function dispatch(
    IMessageOrchestrator.MessageType, /* _msgType */
    bytes calldata _payload,
    uint256, /* _gasLimit */
    address, /* _refundRecipient */
    bool /* _fundFromPool */
  ) external payable {
    IVoterCommon.DeallocationMessageBody memory _body = abi.decode(_payload, (IVoterCommon.DeallocationMessageBody));

    LOG.record(
      LeafVoterCallLog.Entry({
        kind: LeafVoterCallLog.CallKind.Deallocate,
        recorder: address(this),
        tokenId: _body.tokenId,
        amount: _body.amount,
        stakeEnd: 0,
        data: ''
      })
    );
  }
}
