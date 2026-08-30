// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

contract UnitLeafVoterAllocateGauges is BaseLeafVoter {
  // ─── Setup helpers ─────────────────────────────────────────────

  /**
   * @notice Open the local voting master switch, authorize `_OPERATOR` for the tokenId, then stub the
   *         external forwards an allocation drives.
   * @dev The `localVotingEnabled` switch defaults to false and is the first check in `allocateGauges`,
   *      so every case that must reach a later branch opens it here. The emission cap is mocked
   *      uncapped so any settlement walk a warped case triggers books no cap surplus.
   */
  function _authorizeOperator() internal {
    _mockLocalVotingEnabled(true);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.setOperator(_TOKEN_ID, _OPERATOR);

    vm.mockCall(
      _GAUGE_FACTORY, abi.encodeWithSelector(IFactoryRegistry.emissionCap.selector), abi.encode(type(uint128).max)
    );
  }

  /**
   * @notice Wire `_REWARD_A` as `_gauge`'s reward contract and stub its
   *         checkpoint so the checkpoint forward fires and succeeds.
   * @param _gauge Gauge whose reward contract is wired.
   */
  function _mockReward(address _gauge) internal {
    _mockGaugeRewards(_gauge, _REWARD_A);
    vm.mockCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), '');
  }

  /**
   * @notice Set the tokenId's chain allocation budget the vote sum is bounded by.
   * @param _budget Budget to write.
   */
  function _mockBudget(uint128 _budget) internal {
    // chainAllocation sits alone in the second slot of the packed TokenState entry.
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_TOKEN_ID, _TOKEN_STATE_SLOT))) + 1);
    vm.store(address(_leafVoter), _slot, bytes32(uint256(_budget)));
    assertEq(_chainAllocationOf(_TOKEN_ID), _budget);
  }

  /**
   * @notice Set the tokenId's last-voted anchor the cooldown is measured from.
   * @param _timestamp Last-voted timestamp to write.
   */
  function _mockLastVoted(uint48 _timestamp) internal {
    // lastAllocated occupies bits 160..208 of the packed TokenState entry's first
    // slot. Read-modify-write so the slot's operator and flags survive.
    bytes32 _slot = keccak256(abi.encode(_TOKEN_ID, _TOKEN_STATE_SLOT));
    uint256 _current = uint256(vm.load(address(_leafVoter), _slot));
    uint256 _mask = uint256(type(uint48).max) << 160;
    vm.store(address(_leafVoter), _slot, bytes32((_current & ~_mask) | (uint256(_timestamp) << 160)));
    assertEq(_lastVotedOf(_TOKEN_ID), _timestamp);
  }

  /// @notice Single-gauge allocation list.
  function _single(
    address _gauge,
    uint128 _amount
  ) internal pure returns (IVoterCommon.GaugeAllocation[] memory _allocations) {
    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _gauge;
    _amounts[0] = _amount;
    _allocations = _list(_gauges, _amounts);
  }

  /**
   * @notice Cast a prior allocation as the operator to arrange vote state.
   * @dev Setup only. The allocation under test is written out inline in each case
   *      so the `allocateGauges` invocation being exercised stays visible.
   * @param _allocations Prior per-gauge allocations.
   */
  function _arrangePriorVote(IVoterCommon.GaugeAllocation[] memory _allocations) internal {
    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _allocations);
  }

  /*////////////////////////////////////////////////////////////
                          GUARDS
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheChainStatusIsNeitherActiveNorSunset(uint8 _statusRaw) external {
    // Bound to a blocked status (Paused or Suspended); the gate trips before any toggle check.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(IVoterCommon.ChainStatus.Suspended)));
    _mockChainStatus(IVoterCommon.ChainStatus(_statusRaw));

    vm.prank(_OPERATOR);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ChainNotActiveOrSunset.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));
  }

  function test_WhenTheChainStatusIsSunsetAndTheListCarriesOnlyTheDeallocationSentinel(
    uint128 _amount,
    uint256 _value
  ) external {
    // A sunset chain keeps the local vote open only as the exit vehicle: the lone sentinel still returns
    // the budget to root on a live stake.
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _value = bound(_value, 0, type(uint128).max);
    vm.deal(_OPERATOR, _value);
    _mockBudget(_amount);

    // it should process the deallocation sentinel and return the budget
    bytes memory _payload = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _amount}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges{value: _value}(_TOKEN_ID, _single(_DEALLOC_GAUGE, _amount));

    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    // it should anchor the cooldown at the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenTheChainStatusIsSunsetAndTheListCarriesANonDeallocationEntry(
    uint128 _amount,
    uint128 _deallocAmount
  ) external {
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _deallocAmount = uint128(bound(_deallocAmount, 1, _MAX_AMOUNT));

    // A sunset chain takes no new placement: a real gauge entry alone reverts even on a live stake...
    _mockBudget(_amount);
    vm.prank(_OPERATOR);
    // it should revert with SunsetDeallocOnly
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.SunsetDeallocOnly.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // ...and so does a partial return where a real gauge entry rides along with the sentinel.
    _mockBudget(_amount + _deallocAmount);
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _DEALLOC_GAUGE;
    _amounts[0] = _amount;
    _amounts[1] = _deallocAmount;
    vm.prank(_OPERATOR);
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.SunsetDeallocOnly.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenTheChainStatusIsSunsetAndTheListIsEmpty() external {
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    // An empty list only matches a zero budget; even that no-op poke is rejected while sunset.
    _mockBudget(0);

    vm.prank(_OPERATOR);
    // it should revert with SunsetDeallocOnly
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.SunsetDeallocOnly.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, new IVoterCommon.GaugeAllocation[](0));
  }

  function test_WhenLocalVotingIsDisabled(address _caller) external {
    // The master switch defaults to false, so no seeding is needed to arrange the disabled state.
    assertFalse(_leafVoter.localVotingEnabled());

    // Register `_OPERATOR` and call from someone else: if the switch were checked after the operator
    // gate this would surface `NotOperator` instead, so the expected error pins the ordering.
    _caller = _boundNotEq(_caller, _OPERATOR);
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.setOperator(_TOKEN_ID, _OPERATOR);

    vm.prank(_caller);
    // it should revert with LocalVotingDisabled before reaching the operator check
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.LocalVotingDisabled.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));
  }

  function test_WhenTheCallerIsNotTheRegisteredOperator(address _caller) external {
    _caller = _boundNotEq(_caller, _OPERATOR);
    _authorizeOperator();

    vm.prank(_caller);
    // it should revert with NotOperator
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotOperator.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));
  }

  function test_WhenTheCooldownSinceTheLastVoteHasNotElapsed(uint48 _elapsed) external {
    _authorizeOperator();

    // Anchor the prior vote so the cooldown window still covers the current
    // timestamp.
    _elapsed = uint48(bound(_elapsed, 0, _VOTE_COOLDOWN - 1));
    _mockLastVoted(uint48(block.timestamp) - _elapsed);

    vm.prank(_OPERATOR);
    // it should revert with CooldownActive
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.CooldownActive.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));
  }

  function test_WhenTheReducedCooldownHasNotElapsedWithAPendingReductionSeeded(
    uint48 _pending,
    uint48 _elapsed
  ) external {
    // Seed a pending reduction BELOW the full cooldown so `used = pending` and the reduced cooldown
    // `_VOTE_COOLDOWN - pending` is still non-zero. Anchor the prior vote so that reduced cooldown has
    // NOT elapsed: the vote must bounce and nothing may be consumed from the pending balance on revert.
    _authorizeOperator();
    _pending = uint48(bound(_pending, 1, _VOTE_COOLDOWN - 1));
    uint48 _reducedCooldown = _VOTE_COOLDOWN - _pending;
    // Elapse strictly less than the reduced cooldown so the gate is still active.
    _elapsed = uint48(bound(_elapsed, 0, _reducedCooldown - 1));
    _mockLastVoted(uint48(block.timestamp) - _elapsed);
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _pending);

    vm.prank(_OPERATOR);
    // it should revert with CooldownActive
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.CooldownActive.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));

    // it should not consume the pending reduction on revert
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _pending);
  }

  function test_WhenACooldownReductionExceedsTheCooldown(uint48 _leftover, uint48 _elapsed) external {
    // A pending reduction above the cooldown fully waives it on the local path too. Only the cooldown still
    // owed is consumed, so the elapsed part of the wait costs the grant nothing. Anchor the prior vote so,
    // without the reduction, the cooldown would still be active.
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockBudget(1);
    _leftover = uint48(bound(_leftover, 1, type(uint48).max - _VOTE_COOLDOWN));
    _elapsed = uint48(bound(_elapsed, 0, _VOTE_COOLDOWN - 1));
    _mockLastVoted(uint48(block.timestamp) - _elapsed);
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _VOTE_COOLDOWN + _leftover);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));

    uint48 _remainingCooldown = _VOTE_COOLDOWN - _elapsed;
    // it should persist the rest of the pending reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _VOTE_COOLDOWN + _leftover - _remainingCooldown);
    // it should anchor the cooldown at the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenACooldownReductionIsBelowTheCooldown(uint48 _pending, uint48 _elapsed) external {
    // A pending reduction below the full cooldown covers the shortfall exactly when the reduced cooldown has
    // just elapsed, and only the shortfall is spent. Anchor the prior vote against that reduced cooldown.
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockBudget(1);
    _pending = uint48(bound(_pending, 1, _VOTE_COOLDOWN - 1));
    // The reduced cooldown is `_VOTE_COOLDOWN - _pending`; ensure at least that much has elapsed.
    _elapsed = uint48(bound(_elapsed, _VOTE_COOLDOWN - _pending, _VOTE_COOLDOWN - 1));
    _mockLastVoted(uint48(block.timestamp) - _elapsed);
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _pending);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));

    uint48 _remainingCooldown = _VOTE_COOLDOWN - _elapsed;
    // it should keep the unspent part of the reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _pending - _remainingCooldown);
    // it should anchor the cooldown at the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenTheCooldownHasAlreadyElapsedWithAPendingReductionSeeded(uint48 _pending, uint48 _extra) external {
    // Nothing is owed, so nothing should be spent. A routine vote past the cooldown must leave the grant intact
    // for one that actually needs it; `lastAllocated` is zero on a token's first vote, which is the same case.
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockBudget(1);
    _pending = uint48(bound(_pending, 1, type(uint48).max));
    _extra = uint48(bound(_extra, 0, 52 weeks));
    _mockLastVoted(uint48(block.timestamp) - _VOTE_COOLDOWN - _extra);
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _pending);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));

    // it should preserve the whole pending reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _pending);
  }

  function test_WhenTheStakeSnapshotIsNotSeeded(uint128 _amount) external {
    // Budget is set but no chain allocation seeded the shape, so `tokenSnapshot` is the default
    // (staked 0). A vote must book against a seeded shape, so the front-of-function snapshot guard
    // rejects it before any list processing (the seed-on-`applyChainAllocation` guarantee).
    _authorizeOperator();
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockBudget(_amount);

    vm.prank(_OPERATOR);
    // it should revert with StakeSnapshotMissing
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.StakeSnapshotMissing.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));
  }

  function test_WhenTheSnapshotIsNotSeededAndTheListIsInvalid() external {
    // The snapshot guard runs BEFORE any list validation: an oversized list (maxGauges + 1 entries)
    // against an unseeded snapshot must surface the guard's error, not ExceedsMaxGauges.
    _authorizeOperator();

    uint256 _count = _MAX_GAUGES + 1;
    address[] memory _gauges = new address[](_count);
    uint128[] memory _amounts = new uint128[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _gauges[_i] = address(uint160(_i + 1));
      _amounts[_i] = 1;
    }

    vm.prank(_OPERATOR);
    // it should revert with StakeSnapshotMissing
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.StakeSnapshotMissing.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenTheSnapshotIsUnseededAndAlsoExpired(uint48 _stakeEnd) external {
    // Within the snapshot guard the seeded check runs first: `staked == 0` combined with a non-zero
    // PAST stakeEnd must surface StakeSnapshotMissing, not StakeExpired.
    _authorizeOperator();
    _stakeEnd = uint48(bound(_stakeEnd, 1, uint48(block.timestamp)));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: 0, _stakeEnd: _stakeEnd});

    vm.prank(_OPERATOR);
    // it should revert with StakeSnapshotMissing
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.StakeSnapshotMissing.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 1));
  }

  function test_WhenTheTokenStakeIsExpiredAndTheListCarriesOnlyTheDeallocationSentinel(
    uint128 _amount,
    uint48 _stakeEnd,
    uint256 _value
  ) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Fuzzed caller value: the expired return forwards funding the same way the live sentinel path does.
    _value = bound(_value, 0, type(uint128).max);
    vm.deal(_OPERATOR, _value);
    // A non-zero expiry at or before the chain settlement marks the stake expired. The local path must match
    // the bridged one: an expired position books no weight but still returns its budget through the sentinel,
    // else the owner cannot unwind locally and `withdraw` stays blocked on the un-returned budget.
    _stakeEnd = uint48(bound(_stakeEnd, 1, _leafVoter.lastSettlement()));
    _mockTokenSnapshot(_TOKEN_ID, _amount, _stakeEnd);
    // Wire a reward so the no-forward check holds even with a checkpoint target available.
    _mockReward(_DEALLOC_GAUGE);
    _mockBudget(_amount);

    // it should book no weight on any gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    // it should process the deallocation sentinel and return the budget
    bytes memory _payload = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _amount}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      ''
    );
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Deallocated(_TOKEN_ID, _amount);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges{value: _value}(_TOKEN_ID, _single(_DEALLOC_GAUGE, _amount));

    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    // it should book no weight on any gauge
    assertEq(_gaugeWeight(_DEALLOC_GAUGE), 0);
  }

  function test_WhenTheTokenStakeIsExpiredAndTheListCarriesANonDeallocationEntry(
    uint128 _amount,
    uint128 _deallocAmount,
    uint48 _stakeEnd
  ) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _deallocAmount = uint128(bound(_deallocAmount, 1, _MAX_AMOUNT));
    _stakeEnd = uint48(bound(_stakeEnd, 1, _leafVoter.lastSettlement()));
    _mockTokenSnapshot(_TOKEN_ID, _amount, _stakeEnd);

    // An expired position may only return its budget: a real gauge entry alone reverts...
    _mockBudget(_amount);
    vm.prank(_OPERATOR);
    // it should revert with StakeExpired
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.StakeExpired.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // ...and so does a partial return where a real gauge entry rides along with the sentinel.
    _mockBudget(_amount + _deallocAmount);
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _DEALLOC_GAUGE;
    _amounts[0] = _amount;
    _amounts[1] = _deallocAmount;
    vm.prank(_OPERATOR);
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.StakeExpired.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenTheTokenStakeIsExpiredAndTheListIsEmpty(
    uint128 _amount,
    uint48 _stakeEnd
  ) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _stakeEnd = uint48(bound(_stakeEnd, 1, _leafVoter.lastSettlement()));
    _mockTokenSnapshot(_TOKEN_ID, _amount, _stakeEnd);
    // An empty list only matches a zero budget; even that no-op is rejected while the stake is expired.
    _mockBudget(0);

    vm.prank(_OPERATOR);
    // it should revert with StakeExpired
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.StakeExpired.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, new IVoterCommon.GaugeAllocation[](0));
  }

  function test_WhenAnExpiredStakeReturnsItsBudgetAfterAPriorAllocation(
    uint128 _gaugeAmount,
    uint128 _idleAmount,
    uint48 _stakeEnd
  ) external whenTheVoteIsValid {
    // Floor both amounts well above MAXTIME wei so the decaying contributions are non-dust.
    _gaugeAmount = uint128(bound(_gaugeAmount, 1e18, _MAX_AMOUNT));
    _idleAmount = uint128(bound(_idleAmount, 1e18, _MAX_AMOUNT));
    // Snap the expiry to a future week boundary: the settle walk fires the scheduled slope reduction
    // exactly there, so both points resolve to zero once the stake expires by time. The boundary is at
    // least a week away, which also clears the cooldown the prior vote anchors.
    _stakeEnd = uint48(bound(_stakeEnd, uint48(block.timestamp) + _WEEK, uint48(block.timestamp) + 52 weeks));
    _stakeEnd = _nextWeekBoundary(_stakeEnd);

    uint128 _budget = _gaugeAmount + _idleAmount;
    _mockTokenSnapshot(_TOKEN_ID, _budget, _stakeEnd);
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_budget);

    // Prior vote while the stake is live and decaying: a real gauge plus an explicit ZERO_GAUGE idle park.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _ZERO_GAUGE;
    _gauges[1] = _GAUGE_A;
    _amounts[0] = _idleAmount;
    _amounts[1] = _gaugeAmount;
    _arrangePriorVote(_list(_gauges, _amounts));

    // The prior state really exists: allocation booked, decaying weight live, gauge voted, park recorded.
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _gaugeAmount);
    assertGt(_gaugeStateOf(_GAUGE_A).point.bias, 0);
    assertEq(_inVotedSet(_GAUGE_A), true);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _idleAmount);
    assertGt(_gaugeStateOf(_ZERO_GAUGE).point.bias, 0);

    // Expiry arrives by time, so the walk settles through the stake end before the unwind.
    vm.warp(uint256(_stakeEnd) + 1);

    // The dropped gauge is checkpointed at zero, under the unchanged stored shape.
    vm.expectCall(
      _REWARD_A, abi.encodeCall(IVotingRewardsManager.checkpoint, (_TOKEN_ID, uint128(0), _stakeEnd, bytes(''))), 1
    );

    // it should return the whole budget through the sentinel
    bytes memory _payload = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _budget}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      0,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      ''
    );
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Deallocated(_TOKEN_ID, _budget);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_DEALLOC_GAUGE, _budget));

    // it should unwind the prior gauge contribution and clear its allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    assertEq(_gaugeStateOf(_GAUGE_A).point.bias, 0);
    assertEq(_gaugeStateOf(_GAUGE_A).point.slope, 0);
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    // it should remove the gauge from the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    // it should clear the prior idle park
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    assertEq(_gaugeStateOf(_ZERO_GAUGE).point.bias, 0);
    assertEq(_gaugeStateOf(_ZERO_GAUGE).point.slope, 0);
    // it should return the whole budget through the sentinel
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
  }

  function test_WhenTheAllocationListExceedsMaxGauges() external {
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});

    // One past the cap; the length guard precedes any per-entry validation.
    uint256 _count = _MAX_GAUGES + 1;
    address[] memory _gauges = new address[](_count);
    uint128[] memory _amounts = new uint128[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _gauges[_i] = address(uint160(_i + 1));
      _amounts[_i] = 1;
    }

    vm.prank(_OPERATOR);
    // it should revert with ExceedsMaxGauges
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ExceedsMaxGauges.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenAnAllocationIsNotStrictlyAscendingByGauge(uint160 _first, uint160 _second) external {
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});

    // The first entry clears the address(0) anchor, then the second sits at or
    // below it so the pair is non ascending. Equal trips the dedup and lower trips
    // the ordering, both surface as GaugesNotStrictlyAscending.
    _first = uint160(bound(_first, 1, type(uint160).max));
    _second = uint160(bound(_second, 0, _first));

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = address(_first);
    _gauges[1] = address(_second);
    _amounts[0] = 1;
    _amounts[1] = 1;

    vm.prank(_OPERATOR);
    // it should revert with GaugesNotStrictlyAscending
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.GaugesNotStrictlyAscending.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenAZeroGaugeEntryIsNotTheFirstInTheList(uint128 _amountA, uint128 _idle) external {
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _idle = uint128(bound(_idle, 1, _MAX_AMOUNT));
    _mockBudget(_amountA + _idle);

    // address(0) (ZERO_GAUGE) is only valid as the FIRST list entry, where it is still the lowest
    // address and keeps the list sorted. Placed after a real gauge it breaks the strictly-ascending
    // order, so the pair `[realGauge, ZERO_GAUGE]` must revert.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _ZERO_GAUGE;
    _amounts[0] = _amountA;
    _amounts[1] = _idle;

    vm.prank(_OPERATOR);
    // it should revert with GaugesNotStrictlyAscending
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.GaugesNotStrictlyAscending.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));
  }

  function test_WhenAnAllocationCarriesAZeroAmount() external {
    _authorizeOperator();
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});

    vm.prank(_OPERATOR);
    // it should revert with ZeroAllocation
    vm.expectRevert(abi.encodeWithSelector(IVoterCommon.ZeroAllocation.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, 0));
  }

  function test_WhenTheAllocationTotalExceedsTheChainAllocationBudget(uint128 _budget, uint128 _amount) external {
    _authorizeOperator();

    // Allocate strictly more than the budget allows.
    _budget = uint128(bound(_budget, 0, _MAX_AMOUNT - 1));
    _amount = uint128(bound(_amount, _budget + 1, _MAX_AMOUNT));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockBudget(_budget);

    vm.prank(_OPERATOR);
    // it should revert with ChainAllocationMismatch
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ChainAllocationMismatch.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));
  }

  function test_WhenTheAllocationTotalIsBelowTheChainAllocationBudget(uint128 _budget, uint128 _amount) external {
    _authorizeOperator();

    // Allocate strictly less than the budget. The exact-match model has no automatic backfill, so an
    // under-allocation must revert rather than parking the remainder on ZERO_GAUGE. Idle VP would have
    // to be an explicit ZERO_GAUGE entry.
    _budget = uint128(bound(_budget, 2, _MAX_AMOUNT));
    _amount = uint128(bound(_amount, 1, _budget - 1));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _mockBudget(_budget);

    vm.prank(_OPERATOR);
    // it should revert with ChainAllocationMismatch
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ChainAllocationMismatch.selector));
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));
  }

  /*////////////////////////////////////////////////////////////
                          VALID VOTE
  ////////////////////////////////////////////////////////////*/

  modifier whenTheVoteIsValid() {
    _authorizeOperator();
    // Seed a permanent shape (staked > 0, stakeEnd 0) so the seeded-snapshot guard passes and gauge
    // weight books as permanent, matching what these cases assert. Cases needing a specific shape
    // re-seed in their body.
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: 0});
    _;
  }

  function test_WhenTheVoteIsValid(uint256 _emissionsPerVP, uint48 _delta) external whenTheVoteIsValid {
    // Empty allocation against a zero budget: nothing routes, only the chain
    // accumulator advances. Seed a live rate so the index actually moves and
    // warp inside the current week so no boundary is crossed. The index accrues
    // `emissionsPerVP` per second, so a single partial segment advances it by
    // `emissionsPerVP * _delta`.
    _emissionsPerVP = bound(_emissionsPerVP, 1, 1e24);
    uint48 _settledAt = _leafVoter.lastSettlement();
    _delta = uint48(bound(_delta, 1, _nextWeekBoundary(_settledAt) - _settledAt - 1));
    _mockChainAccumulator(_emissionsPerVP, 0);
    _mockBudget(0);

    vm.warp(_settledAt + _delta);
    uint256 _expectedIndex = _emissionsPerVP * _delta;

    // it should not checkpoint any reward
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _list(new address[](0), new uint128[](0)));

    // it should anchor the cooldown at the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
    // it should settle the chain index to the current timestamp
    assertEq(_leafVoter.lastSettlement(), uint48(block.timestamp));
    assertEq(_leafVoter.index(), _expectedIndex);
  }

  function test_WhenAnAllocationTargetsANewActivatedGauge(uint128 _amount) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should checkpoint the reward for the touched gauge
    vm.expectCall(
      _REWARD_A, abi.encodeCall(IVotingRewardsManager.checkpoint, (_TOKEN_ID, _amount, uint48(0), bytes('')))
    );

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should settle the gauge before applying the contribution
    // it should apply the contribution against the new snapshot
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    // it should add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
  }

  function test_WhenTheSnapshotHasAFutureDecayingStakeEnd(
    uint128 _amount,
    uint48 _stakeEnd
  ) external whenTheVoteIsValid {
    // Every other passing case votes with a permanent shape (`stakeEnd: 0`). A live decaying stake —
    // a non-zero stakeEnd strictly in the future — must clear the snapshot guard and apply normally.
    // Floor the amount at `MAXTIME` so the decaying slope is non-zero (a sub-`MAXTIME` allocation is
    // dust: it contributes zero weight and books no record).
    _amount = uint128(bound(_amount, uint128(MAXTIME), _MAX_AMOUNT));
    _stakeEnd = uint48(bound(_stakeEnd, uint48(block.timestamp) + 1, type(uint48).max));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: _stakeEnd});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should forward the snapshot stake end to the reward checkpoint
    vm.expectCall(
      _REWARD_A, abi.encodeCall(IVotingRewardsManager.checkpoint, (_TOKEN_ID, _amount, _stakeEnd, bytes('')))
    );

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should apply the allocation against the decaying snapshot
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    // it should add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
  }

  function test_WhenTheRewardCheckpointReverts(uint128 _amount) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockBudget(_amount);

    // Wire a reward whose checkpoint reverts, so the driven checkpoint fails inside the vote.
    bytes4 _rewardRevert = bytes4(keccak256('RewardReverted()'));
    _mockGaugeRewards(_GAUGE_A, _REWARD_A);
    vm.mockCallRevert(
      _REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), abi.encodePacked(_rewardRevert)
    );

    // it should propagate the revert so the whole vote reverts
    vm.expectRevert(_rewardRevert);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));
  }

  function test_WhenAnAllocationIsKeptOnAnAlreadyVotedGauge(
    uint128 _priorAmount,
    uint128 _newAmount
  ) external whenTheVoteIsValid {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _newAmount = uint128(bound(_newAmount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);

    // Each vote must allocate its whole budget exactly, so the budget tracks the vote sum: the prior
    // amount for the arrange, then the new amount for the vote under test.
    _mockBudget(_priorAmount);
    // Prior vote books weight on _GAUGE_A.
    _arrangePriorVote(_single(_GAUGE_A, _priorAmount));
    vm.warp(block.timestamp + _VOTE_COOLDOWN);
    _mockBudget(_newAmount);

    // it should checkpoint the reward for the touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _newAmount));

    // it should settle the gauge before reapplying the contribution
    // it should unwind the prior contribution against the old snapshot
    // it should reapply the contribution against the new snapshot
    assertEq(_gaugeWeight(_GAUGE_A), _newAmount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _newAmount);
    // it should keep the gauge in the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
  }

  function test_WhenAPreviouslyVotedGaugeIsDroppedFromTheAllocation(
    uint128 _amountA,
    uint128 _amountB
  ) external whenTheVoteIsValid {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _mockReward(_GAUGE_A);
    // The prior vote allocates both gauges exactly; the new vote keeps only _GAUGE_A, so the budget
    // drops to that gauge's share to stay exact.
    _mockBudget(_amountA + _amountB);

    // Prior vote books both gauges; the new vote keeps only _GAUGE_A.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;
    _arrangePriorVote(_list(_gauges, _amounts));
    vm.warp(block.timestamp + _VOTE_COOLDOWN);
    _mockBudget(_amountA);

    // Both the kept and the dropped gauge are touched, the dropped one through its
    // unwind. The reward is wired only on the kept gauge.
    // it should checkpoint the reward for the wired touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amountA));

    // it should settle the gauge before unwinding the contribution
    // it should unwind the prior contribution against the old snapshot
    assertEq(_gaugeWeight(_GAUGE_B), 0);
    // it should clear the stored allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_B), 0);
    // it should remove the gauge from the voted set
    assertEq(_inVotedSet(_GAUGE_B), false);
    // _GAUGE_A is left untouched in the set.
    assertEq(_gaugeWeight(_GAUGE_A), _amountA);
    assertEq(_inVotedSet(_GAUGE_A), true);
  }

  function test_WhenADroppedGaugeSortsBelowAKeptGauge(uint128 _amountA, uint128 _amountB) external whenTheVoteIsValid {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    // The kept gauge is the higher-addressed one, so loop 2's binary search for
    // the dropped lower gauge probes upward and walks the lower half.
    _mockReward(_GAUGE_B);
    // The prior vote allocates both gauges exactly; the new vote keeps only _GAUGE_B, so the budget
    // drops to that gauge's share to stay exact.
    _mockBudget(_amountA + _amountB);

    // Prior vote books both gauges; the new vote keeps only _GAUGE_B.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;
    _arrangePriorVote(_list(_gauges, _amounts));
    vm.warp(block.timestamp + _VOTE_COOLDOWN);
    _mockBudget(_amountB);

    // The kept gauge is processed first through the new list, the dropped one
    // after through its unwind. The reward is wired only on the kept gauge.
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_B, _amountB));

    // it should clear the stored allocation of the dropped gauge
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    assertEq(_inVotedSet(_GAUGE_A), false);
    // it should keep the higher gauge in the voted set
    assertEq(_gaugeWeight(_GAUGE_B), _amountB);
    assertEq(_inVotedSet(_GAUGE_B), true);
  }

  function test_WhenAnAllocationTargetsARegisteredInactiveGaugeAndTheTokenIsWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Registered but inactive. The whitelist covers only activated zero-cap
    // gauges, so it must not route this allocation.
    _mockRegisterGauge(_GAUGE_A, false);
    _mockReward(_GAUGE_A);
    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_TOKEN_ID, true);
    _mockBudget(_amount);

    // it should not checkpoint the reward for the redirected gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should redirect the allocation to the zero gauge because inactivity is absolute
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    assertEq(_gaugeWeight(_GAUGE_A), 0);
  }

  function test_WhenAnAllocationTargetsARegisteredInactiveGaugeAndTheTokenIsNotWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Registered but inactive, and the token is not whitelisted. Wire a reward so
    // the no-forward assertion holds even with a checkpoint target available.
    _mockRegisterGauge(_GAUGE_A, false);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should not checkpoint the reward for the redirected gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should redirect the allocation to the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    assertEq(_gaugeWeight(_GAUGE_A), 0);
  }

  function test_WhenAnAllocationTargetsAnActivatedZeroCapGaugeAndTheTokenIsNotWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Activated, but the emission cap is zeroed and the token is not
    // whitelisted, so the cap gate redirects the allocation.
    _mockRegisterGauge(_GAUGE_A, true);
    _mockEmissionCap(_GAUGE_A, 0);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should not checkpoint the reward for the redirected gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should redirect the allocation to the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    assertEq(_gaugeWeight(_GAUGE_A), 0);
  }

  function test_WhenAnAllocationTargetsAnActivatedZeroCapGaugeAndTheTokenIsWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Activated with a zeroed emission cap, and the token whitelisted for
    // zero-cap gauges, so the allocation routes to the real gauge.
    _mockRegisterGauge(_GAUGE_A, true);
    _mockEmissionCap(_GAUGE_A, 0);
    _mockReward(_GAUGE_A);
    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_TOKEN_ID, true);
    _mockBudget(_amount);

    // it should checkpoint the reward for the touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should route the allocation directly to the gauge
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    // it should add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    // the redirect sink stays empty
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
  }

  function test_WhenAnAllocationTargetsAnUnregisteredGaugeAndTheTokenIsNotWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // _GAUGE_A left unregistered, token not whitelisted.
    _mockBudget(_amount);

    // it should not checkpoint any reward
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should redirect the allocation to the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
  }

  function test_WhenAnAllocationTargetsAnUnregisteredGaugeAndTheTokenIsWhitelisted(uint128 _amount)
    external
    whenTheVoteIsValid
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // _GAUGE_A left unregistered; the whitelist does not extend to unregistered gauges.
    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_TOKEN_ID, true);
    _mockBudget(_amount);

    // it should not checkpoint any reward
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should redirect the allocation to the zero gauge because the whitelist does not cover unregistered gauges
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
  }

  function test_WhenIdleVotingPowerIsParkedWithAnExplicitZeroGaugeEntry(
    uint128 _amount,
    uint128 _idle
  ) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _idle = uint128(bound(_idle, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount + _idle);

    // Idle voting power is an explicit ZERO_GAUGE (address(0)) entry, never an automatic backfill.
    // address(0) is the lowest address, so it sits first and the list stays strictly ascending. The
    // list allocates the whole budget exactly (Σ == budget).
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _ZERO_GAUGE;
    _gauges[1] = _GAUGE_A;
    _amounts[0] = _idle;
    _amounts[1] = _amount;

    // The routable gauge is touched, the explicit idle entry parks on the sink which carries no forward.
    // it should checkpoint the reward for the touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));

    // it should park the idle amount on the zero gauge
    // it should settle the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), _idle);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _idle);
    // the routed gauge still receives its allocation
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
  }

  function test_WhenAnUnroutableAllocationAccompaniesAnExplicitIdleEntry(
    uint128 _routableAmount,
    uint128 _redirectedAmount,
    uint128 _idle
  ) external whenTheVoteIsValid {
    _routableAmount = uint128(bound(_routableAmount, 1, _MAX_AMOUNT));
    _redirectedAmount = uint128(bound(_redirectedAmount, 1, _MAX_AMOUNT));
    _idle = uint128(bound(_idle, 1, _MAX_AMOUNT));
    // _GAUGE_A routable, _GAUGE_B unregistered so its weight is redirected to the sink. An explicit
    // ZERO_GAUGE entry parks idle VP on the same sink. The list allocates the whole budget exactly.
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_idle + _routableAmount + _redirectedAmount);

    // address(0) sorts first, then the two real gauges ascend, so the list is strictly ascending.
    address[] memory _gauges = new address[](3);
    uint128[] memory _amounts = new uint128[](3);
    _gauges[0] = _ZERO_GAUGE;
    _gauges[1] = _GAUGE_A;
    _gauges[2] = _GAUGE_B;
    _amounts[0] = _idle;
    _amounts[1] = _routableAmount;
    _amounts[2] = _redirectedAmount;

    // Only the routable gauge is touched; the unroutable one and the explicit idle entry aggregate on
    // the sink.
    // it should checkpoint the reward for the routable gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _amounts));

    // it should accumulate the explicit idle entry and the redirected weight on the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), _redirectedAmount + _idle);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _redirectedAmount + _idle);
    // the routable gauge still receives its own allocation
    assertEq(_gaugeWeight(_GAUGE_A), _routableAmount);
    assertEq(_inVotedSet(_GAUGE_B), false);
  }

  function test_WhenTheAllocationTotalEqualsTheChainBudget(uint128 _amount) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should checkpoint the reward for the touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should park no shortfall on the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
  }

  function test_WhenAPriorZeroGaugeAllocationIsReplaced(
    uint128 _priorAmount,
    uint128 _newAmount
  ) external whenTheVoteIsValid {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _newAmount = uint128(bound(_newAmount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);

    // Budget exceeds either gauge allocation, so each vote parks its remainder on the zero gauge via an
    // explicit ZERO_GAUGE (address(0)) entry — the exact-match model has no automatic backfill. The
    // bounds keep each remainder non-zero so no entry trips ZeroAllocation.
    uint128 _budget = _MAX_AMOUNT * 2;
    _mockBudget(_budget);

    // Prior vote parks `_budget - _priorAmount` on the sink through an explicit ZERO_GAUGE entry.
    address[] memory _gauges = new address[](2);
    uint128[] memory _priorAmounts = new uint128[](2);
    _gauges[0] = _ZERO_GAUGE;
    _gauges[1] = _GAUGE_A;
    _priorAmounts[0] = _budget - _priorAmount;
    _priorAmounts[1] = _priorAmount;
    _arrangePriorVote(_list(_gauges, _priorAmounts));
    vm.warp(block.timestamp + _VOTE_COOLDOWN);

    // Only the routable gauge is touched. The sink is resettled but carries no
    // forward.
    // it should checkpoint the reward for the touched gauge
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 1);

    // New vote unwinds the prior sink contribution and re-parks the new remainder via an explicit entry.
    uint128[] memory _newAmounts = new uint128[](2);
    _newAmounts[0] = _budget - _newAmount;
    _newAmounts[1] = _newAmount;
    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _list(_gauges, _newAmounts));

    // it should settle the zero gauge
    // it should unwind the prior zero gauge contribution against the old snapshot
    // it should apply the new zero gauge contribution against the new snapshot
    assertEq(_gaugeWeight(_ZERO_GAUGE), _budget - _newAmount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _budget - _newAmount);
  }

  function test_WhenTheAllocationContainsTheDeallocationSentinel(
    uint128 _amount,
    uint256 _value
  ) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Funding sufficiency is the orchestrator's business now (it quotes the transport); the voter only forwards the
    // full `msg.value`, which the dispatch expectation pins.
    _value = bound(_value, 0, type(uint128).max);
    vm.deal(_OPERATOR, _value);
    // `DEALLOC_GAUGE` is a pure sentinel, never registered or parked on. Its amount counts toward the
    // validated total (so the budget must cover it) but is turned into an immediate deallocation
    // dispatch: the chain budget is decremented and a `Deallocate` message returns the weight to root.
    // Permanent stake so the seeded-snapshot guard passes.
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _amount, _stakeEnd: 0});
    // Wire a reward so the no-forward assertion holds even with a checkpoint target available.
    _mockReward(_DEALLOC_GAUGE);
    _mockBudget(_amount);

    // it should not forward a checkpoint for the sentinel
    // The sentinel returns early in `_processGauge`, so it is excluded from the forward list.
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    // it should dispatch a Deallocate message forwarding the caller value
    // The local caller (`_OPERATOR`) is the refund recipient; the gas limit is passed as zero because the
    // orchestrator substitutes its own configured `deallocationGasLimit`. `_fundFromPool` is false: the caller,
    // not the orchestrator's pre-funding, pays for a locally triggered return.
    bytes memory _payload = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _amount}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      ''
    );
    // it should emit the Deallocated event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Deallocated(_TOKEN_ID, _amount);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges{value: _value}(_TOKEN_ID, _single(_DEALLOC_GAUGE, _amount));

    // it should decrement the chain allocation by the sentinel amount
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    // it should not park the sentinel, store an allocation, or add it to the voted set
    assertEq(_gaugeWeight(_DEALLOC_GAUGE), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _DEALLOC_GAUGE), 0);
    assertEq(_inVotedSet(_DEALLOC_GAUGE), false);
  }

  /*////////////////////////////////////////////////////////////
                    LOCAL DEALLOCATION FUNDING
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheListCarriesTheDeallocationSentinelAndTheCallerFundsTheReturn(
    uint128 _sentinelAmount,
    uint256 _value
  ) external whenTheVoteIsValid {
    // The voter keeps nothing back: it hands the orchestrator the WHOLE `msg.value` with `_fundFromPool` false, so
    // the orchestrator charges the live quote against the caller's value and the transport refunds the excess to
    // the caller. Sufficiency is enforced in the orchestrator, not here.
    _sentinelAmount = uint128(bound(_sentinelAmount, 1, _MAX_AMOUNT));
    _value = bound(_value, 1, type(uint128).max);
    vm.deal(_OPERATOR, _value);
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _sentinelAmount, _stakeEnd: 0});
    _mockBudget(_sentinelAmount);

    // it should dispatch a Deallocate message forwarding the whole caller value without drawing from the pool
    // The gas limit is passed as zero: the orchestrator substitutes its own configured `deallocationGasLimit`.
    bytes memory _payload =
      abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _sentinelAmount}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      _value,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _OPERATOR, false)
      ),
      ''
    );
    // the caller's value must not be retained by the voter
    assertEq(address(_leafVoter).balance, 0);
    // it should emit the Deallocated event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Deallocated(_TOKEN_ID, _sentinelAmount);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges{value: _value}(_TOKEN_ID, _single(_DEALLOC_GAUGE, _sentinelAmount));

    // it should decrement the chain allocation by the sentinel amount
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    // it should not park the sentinel or add it to the voted set
    assertEq(_gaugeWeight(_DEALLOC_GAUGE), 0);
    assertEq(_inVotedSet(_DEALLOC_GAUGE), false);
  }

  function test_WhenNoSentinelIsPresentAndMsgValueIsZero(uint128 _amount) external whenTheVoteIsValid {
    // Guard-scoping sanity: a plain allocation with no sentinel entry is a pure local vote that never dispatches a
    // return message, so a zero `msg.value` must still succeed. The funding guard must not leak onto non-deallocation
    // votes.
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    // it should not dispatch a Deallocate message
    vm.expectCall(_LEAF_MESSAGE_ORCHESTRATOR, abi.encodeWithSelector(ILeafMessageOrchestrator.dispatch.selector), 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges{value: 0}(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should book the allocation
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    assertEq(_inVotedSet(_GAUGE_A), true);
  }

  function test_WhenNoSentinelIsPresentAndMsgValueIsNonZero(
    uint128 _amount,
    uint256 _msgValue
  ) external whenTheVoteIsValid {
    // A plain allocation dispatches no return message, so attached value would be trapped in the
    // LeafVoter's pre-funding. It must be rejected rather than silently kept.
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _msgValue = bound(_msgValue, 1, 100 ether);
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);
    vm.deal(_OPERATOR, _msgValue);

    // it should revert with UnexpectedValue
    vm.prank(_OPERATOR);
    vm.expectRevert(IVoterCommon.UnexpectedValue.selector);
    _leafVoter.allocateGauges{value: _msgValue}(_TOKEN_ID, _single(_GAUGE_A, _amount));
  }

  function test_WhenAGaugeAllocationIsApplied(uint128 _amount) external whenTheVoteIsValid {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);
    IVoterCommon.GaugeAllocation[] memory _allocations = _single(_GAUGE_A, _amount);

    // it should emit the GaugesAllocated event with the requested allocations
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, 0);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _allocations);
  }

  function test_WhenTheLatestSnapshotIsAheadOfTheStoredOne(uint128 _amount) external whenTheVoteIsValid {
    // A chain message stashed a fresher shape (decaying, future end) while the stored shape stayed
    // pinned (permanent, from the modifier). The local vote must consume the latest shape: book the
    // weight as decaying at the new stakeEnd and re-pin the stored snapshot.
    _amount = uint128(bound(_amount, uint128(MAXTIME), _MAX_AMOUNT));
    uint48 _newStakeEnd = uint48(block.timestamp) + 52 weeks;
    _mockLatestTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: _newStakeEnd});
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);

    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // it should re-pin the stored snapshot to the pending one
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, _MAX_AMOUNT);
    assertEq(_stakeEnd, _newStakeEnd);

    // it should book the vote at the latest shape: decaying weight, not permanent
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_GAUGE_A);
    assertEq(_point.permanentStakeBalance, 0);
    assertGt(_point.bias, 0);
  }

  function test_WhenTheLatestSnapshotWalksTheFullLifecycle(uint128 _amount) external whenTheVoteIsValid {
    // End-to-end invariant walk: pending is never behind stored, is ahead only after a chain-only
    // message, and re-converges on every gauge-iterating operation.
    _amount = uint128(bound(_amount, uint128(MAXTIME), _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockReward(_GAUGE_A);
    _mockBudget(_amount);
    uint48 _shapeA = uint48(block.timestamp) + 52 weeks;
    uint48 _shapeB = _shapeA + 4 weeks;

    // 1. Book weight so the stored shape pins (modifier seeded a permanent shape; vote at it).
    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));

    // 2. Newest chain message stashes shape A: pending ahead, stored pinned.
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: true,
      _refreshShape: true,
      _snapshot: IVoterCommon.TokenSnapshot({staked: _MAX_AMOUNT, stakeEnd: _shapeA, isPermanent: (_shapeA) == 0})
    });
    // it should stash the chain message shape while the stored one stays pinned
    (, uint48 _pendingEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    (, uint48 _storedEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_pendingEnd, _shapeA);
    assertEq(_storedEnd, 0);

    // 3. Local vote consumes it: stored re-pins to A.
    vm.warp(block.timestamp + _VOTE_COOLDOWN);
    vm.prank(_OPERATOR);
    _leafVoter.allocateGauges(_TOKEN_ID, _single(_GAUGE_A, _amount));
    // it should consume the latest shape on the local vote
    (, _storedEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_storedEnd, _shapeA);

    // 4. Bridged gauge vote with shape B: both move together.
    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;
    vm.warp(block.timestamp + _VOTE_COOLDOWN);
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations({
      _tokenId: _TOKEN_ID,
      _expiry: uint48(block.timestamp),
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: true,
      _newSnapshot: IVoterCommon.TokenSnapshot({staked: _MAX_AMOUNT, stakeEnd: _shapeB, isPermanent: (_shapeB) == 0}),
      _gauges: _list(_gauges, _amounts)
    });
    // it should keep pending equal to stored after a bridged vote
    (, _pendingEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    (, _storedEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_pendingEnd, _shapeB);
    assertEq(_storedEnd, _shapeB);
  }
}
