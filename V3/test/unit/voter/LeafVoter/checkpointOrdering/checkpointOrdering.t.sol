// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';
import {
  LeafVoterCallLog,
  RecordingOrchestrator,
  RecordingReward,
  ReenteringReward
} from 'V3-test/unit/voter/LeafVoterCallLog.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

/**
 * @title UnitLeafVoterCheckpointOrdering
 * @notice Regression coverage for the two ordering properties of an allocation pass: the deallocation
 *         return dispatches only after every reward checkpoint has run, and every checkpoint ships the
 *         allocation and stake shape captured when its entry was recorded.
 * @dev Both interactions hand control flow to code the caller chooses — the transport refunds the
 *      deallocation's excess fee to a caller-supplied address, and the reward checkpoints are a loop of
 *      external calls. `vm.expectCall` cannot express "before", so a shared append-only log
 *      (`LeafVoterCallLog`) collects both surfaces and the assertions read the order off it.
 */
contract UnitLeafVoterCheckpointOrdering is BaseLeafVoter {
  /// @notice Third gauge, above `_GAUGE_A` and `_GAUGE_B` so a three-entry list stays strictly ascending.
  address internal constant _GAUGE_C = address(0xCCC3);

  /// @notice Per-gauge payload carried on a written allocation. A cleared position must carry none of it.
  bytes internal constant _KEPT_PAYLOAD = hex'c0ffee';

  /// @notice Shared log the reward and orchestrator doubles append to, one instance per test.
  LeafVoterCallLog internal _log;

  // ─── Setup helpers ─────────────────────────────────────────────

  /**
   * @notice Stand up the shared log and put the recording orchestrator behind the voter's `ORCHESTRATOR`.
   * @dev `ORCHESTRATOR` is immutable, so the double is etched over `_LEAF_MESSAGE_ORCHESTRATOR` instead of
   *      redeploying the voter. `vm.etch` copies runtime code only, and the double holds its log handle as
   *      an immutable baked into that code, so the etched copy appends to the same instance.
   */
  modifier withRecorders() {
    _log = new LeafVoterCallLog();
    RecordingOrchestrator _orchestrator = new RecordingOrchestrator(_log);
    vm.etch(_LEAF_MESSAGE_ORCHESTRATOR, address(_orchestrator).code);
    _;
  }

  /**
   * @notice Open the local `allocateGauges` path for `_OPERATOR`.
   * @dev Mirrors the `allocateGauges` suite: the master switch defaults closed and is the first check, and
   *      the per-gauge cap is mocked uncapped so any settlement walk books no cap surplus.
   */
  function _openLocalVoting() internal {
    _mockLocalVotingEnabled(true);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.setOperator(_TOKEN_ID, _OPERATOR);

    vm.mockCall(
      _GAUGE_FACTORY, abi.encodeWithSelector(IFactoryRegistry.emissionCap.selector), abi.encode(type(uint128).max)
    );
  }

  /**
   * @notice Point `_gauge`'s reward contract at `_reward`.
   * @dev Mocks the FactoryRegistry lookup so no setter on the contract under test arranges the wiring.
   * @param _gauge Gauge whose reward contract is wired.
   * @param _reward Reward contract to wire.
   */
  function _wireReward(address _gauge, address _reward) internal {
    _mockGaugeRewards(_gauge, _reward);
  }

  /**
   * @notice Deploy a recording reward and wire it to `_gauge`.
   * @param _gauge Gauge whose reward contract is wired.
   * @return _reward The deployed double.
   */
  function _recordingRewardFor(address _gauge) internal returns (RecordingReward _reward) {
    _reward = new RecordingReward(_log);
    _wireReward(_gauge, address(_reward));
  }

  /**
   * @notice Slot holding `allocations[_tokenId][_gauge]`.
   * @dev Nested mapping: the inner key is the gauge, the outer key the tokenId.
   * @param _tokenId Token the allocation belongs to.
   * @param _gauge Gauge the allocation is booked on.
   * @return _slot The value slot.
   */
  function _allocationSlot(uint256 _tokenId, address _gauge) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_gauge, keccak256(abi.encode(_tokenId, _ALLOCATIONS_SLOT))));
  }

  /**
   * @notice Slot holding the packed `tokenSnapshot[_tokenId]`.
   * @param _tokenId Token whose snapshot slot is resolved.
   * @return _slot The value slot.
   */
  function _snapshotSlot(uint256 _tokenId) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_tokenId, _TOKEN_SNAPSHOT_SLOT));
  }

  /**
   * @notice Pack a `TokenSnapshot` the way the voter stores it.
   * @param _staked Staked amount, low 16 bytes.
   * @param _stakeEnd Stake expiry, next 6 bytes.
   * @return _word The packed word.
   */
  function _snapshotWord(uint128 _staked, uint48 _stakeEnd) internal pure returns (bytes32 _word) {
    _word = bytes32(uint256(_staked) | (uint256(_stakeEnd) << 128));
  }

  /**
   * @notice Arm `_hostile` with a single storage word to overwrite mid-checkpoint.
   * @param _hostile The reentering reward double.
   * @param _slot Slot on the voter to overwrite.
   * @param _value Word to write.
   */
  function _armOneWrite(ReenteringReward _hostile, bytes32 _slot, bytes32 _value) internal {
    ReenteringReward.StorageWrite[] memory _writes = new ReenteringReward.StorageWrite[](1);
    _writes[0] = ReenteringReward.StorageWrite({slot: _slot, value: _value});
    _hostile.arm(_writes);
  }

  /**
   * @notice Seed a prior permanent position on `_gauge` straight into storage.
   * @dev Registers and activates the gauge with its cursor anchored at the chain's, books `_amount` of
   *      permanent weight on its point, writes the allocation record, and inserts it into the voted set —
   *      exactly what a prior pass would have left. Never routed through `allocateGauges`, so the pass
   *      under test is the only execution of the contract under test.
   * @param _gauge Gauge to seed the position on.
   * @param _amount Permanent weight and allocation to seed.
   */
  function _seedPriorPosition(address _gauge, uint128 _amount) internal {
    uint48 _settledAt = _leafVoter.lastSettlement();
    ILeafVoter.GaugeState memory _state = _buildGaugeState({
      _ceiling: 0,
      _claimed: 0,
      _lastSettlement: _settledAt,
      _isRegistered: true,
      _surplus: 0,
      _lastIndex: 0,
      _point: _buildPoint({_bias: 0, _slope: 0, _ts: _settledAt, _permanentStakeBalance: _amount})
    });
    _state.isActivated = true;
    _mockGaugeState(_gauge, _state);

    _mockAllocation(_TOKEN_ID, _gauge, _amount);
    _mockVotedGauge(_TOKEN_ID, _gauge);
  }

  /**
   * @notice Build a strictly ascending three-entry allocation list.
   * @param _amountA Allocation for `_GAUGE_A`.
   * @param _amountB Allocation for `_GAUGE_B`.
   * @param _thirdGauge Third, highest gauge in the list.
   * @param _thirdAmount Allocation for `_thirdGauge`.
   * @return _allocations The assembled list.
   */
  function _tripleList(
    uint128 _amountA,
    uint128 _amountB,
    address _thirdGauge,
    uint128 _thirdAmount
  ) internal pure returns (IVoterCommon.GaugeAllocation[] memory _allocations) {
    address[] memory _gauges = new address[](3);
    uint128[] memory _amounts = new uint128[](3);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _gauges[2] = _thirdGauge;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;
    _amounts[2] = _thirdAmount;
    _allocations = _list(_gauges, _amounts);
  }

  /**
   * @notice Build a strictly ascending two-entry allocation list over `_GAUGE_A` and `_GAUGE_B`.
   * @param _amountA Allocation for `_GAUGE_A`.
   * @param _amountB Allocation for `_GAUGE_B`.
   * @return _allocations The assembled list.
   */
  function _pairList(
    uint128 _amountA,
    uint128 _amountB
  ) internal pure returns (IVoterCommon.GaugeAllocation[] memory _allocations) {
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;
    _allocations = _list(_gauges, _amounts);
  }

  // ─── Assertion helpers ─────────────────────────────────────────

  /**
   * @notice Assert the log holds exactly `_expectedCheckpoints` checkpoints, then exactly one deallocation
   *         dispatch, with every checkpoint recorded strictly before it.
   * @dev The count check at the dispatch entry is what pins the ordering: reaching the deallocation with
   *      fewer checkpoints logged means the return went out while checkpoints were still pending.
   * @param _expectedCheckpoints Checkpoints the pass must have driven.
   * @param _expectedDeallocAmount Amount the deallocation return must carry.
   */
  function _assertCheckpointsBeforeDeallocation(
    uint256 _expectedCheckpoints,
    uint128 _expectedDeallocAmount
  ) internal view {
    uint256 _length = _log.length();
    assertEq(_length, _expectedCheckpoints + 1);

    uint256 _checkpoints;
    uint256 _deallocations;
    for (uint256 _i; _i < _length; ++_i) {
      LeafVoterCallLog.Entry memory _entry = _log.entryAt(_i);
      if (_entry.kind == LeafVoterCallLog.CallKind.Deallocate) {
        assertEq(_checkpoints, _expectedCheckpoints);
        assertEq(_entry.tokenId, _TOKEN_ID);
        assertEq(_entry.amount, _expectedDeallocAmount);
        ++_deallocations;
      } else {
        ++_checkpoints;
      }
    }
    assertEq(_deallocations, 1);
  }

  /*////////////////////////////////////////////////////////////
              CHECKPOINTS BEFORE THE DEALLOCATION RETURN
  ////////////////////////////////////////////////////////////*/

  function test_WhenALocalAllocationCarriesBothAGaugeAndTheDeallocationSentinel(
    uint128 _amountA,
    uint128 _amountB,
    uint128 _deallocAmount
  ) external withRecorders {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _deallocAmount = uint128(bound(_deallocAmount, 1, _MAX_AMOUNT));

    _openLocalVoting();
    // Permanent shape so both routable allocations book weight and neither is dust.
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _recordingRewardFor(_GAUGE_A);
    _recordingRewardFor(_GAUGE_B);
    // The sentinel amount counts toward the exact-match budget even though it is never parked.
    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB + _deallocAmount);

    // it should dispatch exactly one deallocation return carrying the sentinel amount
    // The local caller is the refund recipient and funds the return, so `_fundFromPool` is false. No value
    // is attached, so the whole forwarded `msg.value` is zero.
    bytes memory _payload =
      abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _deallocAmount}));
    vm.expectCall(
      _LEAF_MESSAGE_ORCHESTRATOR,
      0,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      1
    );

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _tripleList(_amountA, _amountB, _DEALLOC_GAUGE, _deallocAmount));

    // it should record one checkpoint per allocated gauge
    // it should record every reward checkpoint before the deallocation dispatch
    _assertCheckpointsBeforeDeallocation(2, _deallocAmount);
  }

  function test_WhenABridgedAllocationCarriesBothAGaugeAndTheDeallocationSentinel(
    uint128 _amountA,
    uint128 _amountB,
    uint128 _deallocAmount
  ) external withRecorders {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _deallocAmount = uint128(bound(_deallocAmount, 1, _MAX_AMOUNT));

    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _recordingRewardFor(_GAUGE_A);
    _recordingRewardFor(_GAUGE_B);
    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB + _deallocAmount);

    // it should dispatch exactly one deallocation return drawing from the orchestrator pool
    // The inbound path attaches no value and flags `_fundFromPool`, so the orchestrator charges the quote
    // against its own pre-funding.
    bytes memory _payload =
      abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _deallocAmount}));
    vm.expectCall(
      _LEAF_MESSAGE_ORCHESTRATOR,
      0,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _LEAF_MESSAGE_ORCHESTRATOR, true)
      ),
      1
    );

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations({
      _tokenId: _TOKEN_ID,
      _expiry: uint48(block.timestamp),
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: true,
      _newSnapshot: IVoterCommon.TokenSnapshot({staked: _MAX_AMOUNT, stakeEnd: 0, isPermanent: (0) == 0}),
      _gauges: _tripleList(_amountA, _amountB, _DEALLOC_GAUGE, _deallocAmount)
    });

    // it should record one checkpoint per allocated gauge
    // it should record every reward checkpoint before the deallocation dispatch
    _assertCheckpointsBeforeDeallocation(2, _deallocAmount);
  }

  /*////////////////////////////////////////////////////////////
                  SNAPSHOTTED CHECKPOINT ARGUMENTS
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheFirstRewardContractRewritesTheAllocationAndTheSnapshotMidPass(
    uint128 _amountA,
    uint128 _amountB,
    uint128 _poisonAllocated,
    uint48 _stakeEnd,
    uint48 _poisonStakeEnd
  ) external withRecorders {
    // Decaying shape: the stake end is a non-zero value a mutation can move, and floors at MAXTIME keep
    // both contributions above dust.
    _amountA = uint128(bound(_amountA, uint128(MAXTIME), _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, uint128(MAXTIME), _MAX_AMOUNT));
    _stakeEnd = uint48(bound(_stakeEnd, block.timestamp + 1, type(uint48).max - 1));
    _poisonStakeEnd = uint48(bound(_poisonStakeEnd, uint256(_stakeEnd) + 1, type(uint48).max));
    // Poison the allocation record into a band the fuzzed amounts cannot reach, so shipping the mutated
    // slot instead of the recorded entry is unambiguous.
    _poisonAllocated = uint128(bound(_poisonAllocated, uint256(_MAX_AMOUNT) + 1, type(uint128).max));

    _openLocalVoting();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: _stakeEnd});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB);

    // `_GAUGE_A` is checkpointed first, so its reward is the one that gets to mutate what a later
    // checkpoint would read: `_GAUGE_B`'s allocation record and the token's stored stake shape.
    ReenteringReward _hostile = new ReenteringReward(_log, address(_leafVoter));
    _wireReward(_GAUGE_A, address(_hostile));
    RecordingReward _rewardB = _recordingRewardFor(_GAUGE_B);

    ReenteringReward.StorageWrite[] memory _writes = new ReenteringReward.StorageWrite[](2);
    _writes[0] = ReenteringReward.StorageWrite({
      slot: _allocationSlot(_TOKEN_ID, _GAUGE_B), value: bytes32(uint256(_poisonAllocated))
    });
    _writes[1] = ReenteringReward.StorageWrite({
      slot: _snapshotSlot(_TOKEN_ID), value: _snapshotWord(_MAX_AMOUNT, _poisonStakeEnd)
    });
    _hostile.arm(_writes);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _pairList(_amountA, _amountB));

    assertEq(_log.length(), 2);
    LeafVoterCallLog.Entry memory _first = _log.entryAt(0);
    LeafVoterCallLog.Entry memory _second = _log.entryAt(1);
    assertEq(_first.recorder, address(_hostile));
    assertEq(_second.recorder, address(_rewardB));

    // it should checkpoint the second gauge against the allocation recorded for it
    assertEq(_first.amount, _amountA);
    assertEq(_second.amount, _amountB);
    // it should checkpoint the second gauge against the stake end the first one got
    assertEq(_first.stakeEnd, _stakeEnd);
    assertEq(_second.stakeEnd, _first.stakeEnd);
  }

  function test_WhenAPreviouslyAllocatedGaugeIsDroppedFromTheList(
    uint128 _priorAmount,
    uint128 _newAmount
  ) external withRecorders {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _newAmount = uint128(bound(_newAmount, 1, _MAX_AMOUNT));

    _openLocalVoting();
    // Permanent shape, so the seeded permanent weight below is exactly what the drop unwinds.
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _seedPriorPosition(_GAUGE_B, _priorAmount);
    _mockChainAllocation(_TOKEN_ID, _newAmount);

    RecordingReward _rewardA = _recordingRewardFor(_GAUGE_A);
    RecordingReward _rewardB = _recordingRewardFor(_GAUGE_B);

    // The kept gauge carries a payload; the cleared one is not in the list, so it has none to carry.
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _GAUGE_A, allocated: _newAmount, data: _KEPT_PAYLOAD});

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _allocations);

    // The incoming list is walked first, then the entry snapshot of the prior set, so the kept gauge is
    // recorded before the dropped one.
    assertEq(_log.length(), 2);
    LeafVoterCallLog.Entry memory _kept = _log.entryAt(0);
    LeafVoterCallLog.Entry memory _cleared = _log.entryAt(1);
    assertEq(_kept.recorder, address(_rewardA));
    assertEq(_cleared.recorder, address(_rewardB));

    // it should checkpoint the kept gauge at its new allocation with its payload
    assertEq(_kept.amount, _newAmount);
    assertEq(_kept.data, _KEPT_PAYLOAD);
    // it should checkpoint the cleared position at zero
    assertEq(_cleared.amount, 0);
    // it should carry no payload for the cleared position
    assertEq(_cleared.data.length, 0);
  }

  function test_WhenTheFirstRewardContractResurrectsAClearedGaugeRecordMidPass(
    uint128 _priorAmount,
    uint128 _newAmount
  ) external withRecorders {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _newAmount = uint128(bound(_newAmount, 1, _MAX_AMOUNT));

    _openLocalVoting();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _seedPriorPosition(_GAUGE_B, _priorAmount);
    _mockChainAllocation(_TOKEN_ID, _newAmount);

    // `_GAUGE_B` is dropped, so the pass deletes its allocation record and its entry was recorded at zero.
    // The kept gauge's reward runs first and writes the record back, which is the value the checkpoint
    // would pick up if it resolved the amount at call time instead of at record time.
    ReenteringReward _hostile = new ReenteringReward(_log, address(_leafVoter));
    _wireReward(_GAUGE_A, address(_hostile));
    RecordingReward _rewardB = _recordingRewardFor(_GAUGE_B);
    _armOneWrite(_hostile, _allocationSlot(_TOKEN_ID, _GAUGE_B), bytes32(uint256(_priorAmount)));

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _GAUGE_A, allocated: _newAmount, data: ''});

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _allocations);

    assertEq(_log.length(), 2);
    LeafVoterCallLog.Entry memory _cleared = _log.entryAt(1);
    assertEq(_cleared.recorder, address(_rewardB));
    // it should still checkpoint the cleared position at zero
    assertEq(_cleared.amount, 0);
  }

  function test_WhenSeveralRewardContractsRewriteTheSnapshotMidPass(
    uint128 _amount,
    uint48 _stakeEnd,
    uint48 _firstPoisonStakeEnd,
    uint48 _secondPoisonStakeEnd
  ) external withRecorders {
    // Three gauges at the same allocation, all above dust, against a decaying shape.
    _amount = uint128(bound(_amount, uint128(MAXTIME), _MAX_AMOUNT / 3));
    _stakeEnd = uint48(bound(_stakeEnd, block.timestamp + 1, type(uint48).max - 2));
    _firstPoisonStakeEnd = uint48(bound(_firstPoisonStakeEnd, uint256(_stakeEnd) + 1, type(uint48).max - 1));
    _secondPoisonStakeEnd = uint48(bound(_secondPoisonStakeEnd, uint256(_firstPoisonStakeEnd) + 1, type(uint48).max));

    _openLocalVoting();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: _stakeEnd});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _mockRegisterGauge(_GAUGE_C, true);
    _mockChainAllocation(_TOKEN_ID, _amount * 3);

    // The first two rewards each move the stored stake shape to a different value. The shape is read once
    // before the loop, so all three entries must still land on the shape the pass distributed at.
    ReenteringReward _firstHostile = new ReenteringReward(_log, address(_leafVoter));
    ReenteringReward _secondHostile = new ReenteringReward(_log, address(_leafVoter));
    _wireReward(_GAUGE_A, address(_firstHostile));
    _wireReward(_GAUGE_B, address(_secondHostile));
    _recordingRewardFor(_GAUGE_C);
    _armOneWrite(_firstHostile, _snapshotSlot(_TOKEN_ID), _snapshotWord(_MAX_AMOUNT, _firstPoisonStakeEnd));
    _armOneWrite(_secondHostile, _snapshotSlot(_TOKEN_ID), _snapshotWord(_MAX_AMOUNT, _secondPoisonStakeEnd));

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _tripleList(_amount, _amount, _GAUGE_C, _amount));

    // it should record one checkpoint per allocated gauge
    assertEq(_log.length(), 3);
    // it should checkpoint every gauge against the stake end read before the loop
    for (uint256 _i; _i < 3; ++_i) {
      LeafVoterCallLog.Entry memory _entry = _log.entryAt(_i);
      assertEq(_entry.amount, _amount);
      assertEq(_entry.stakeEnd, _stakeEnd);
    }
  }
}
