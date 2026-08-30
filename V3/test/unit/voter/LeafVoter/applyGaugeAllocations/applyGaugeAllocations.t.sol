// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

contract UnitLeafVoterApplyGaugeAllocations is BaseLeafVoter {
  // ─── Setup helpers ─────────────────────────────────────────────

  /// @notice Reduction that brings the effective cooldown to zero, so a re-vote in the same block clears the gate.
  uint48 internal constant _MAX_REDUCTION = _VOTE_COOLDOWN;

  /// @notice Permanent-stake snapshot. Its contribution is the allocation itself.
  function _permanentSnapshot(uint128 _staked) internal pure returns (IVoterCommon.TokenSnapshot memory _snapshot) {
    _snapshot = IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: 0, isPermanent: (0) == 0});
  }

  /**
   * @notice Apply a prior allocation as the orchestrator to arrange vote state.
   * @dev Setup only. The call under test is written out inline in each case so
   *      the `applyGaugeAllocations` invocation being exercised stays visible.
   *      The prior call runs on a fresh token (`lastAllocated == 0`), so its cooldown is already
   *      elapsed. It anchors `lastAllocated` at `block.timestamp`, so a same-block call under test
   *      must seed a pending reduction that clears the cooldown; see `_MAX_REDUCTION` and
   *      `_mockAccumulatedCooldownReduction`.
   * @param _snapshot Token snapshot for the prior vote.
   * @param _allocations Prior per-gauge allocations.
   */
  function _arrangePriorVote(
    IVoterCommon.TokenSnapshot memory _snapshot,
    IVoterCommon.GaugeAllocation[] memory _allocations
  ) internal {
    uint128 _sum;
    for (uint256 _i; _i < _allocations.length; ++_i) {
      _sum += _allocations[_i].allocated;
    }
    _mockChainAllocation(_TOKEN_ID, _sum);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(_TOKEN_ID, uint48(block.timestamp), 0, false, true, _snapshot, _allocations);
  }

  /**
   * @notice Seed the budget and apply a single-gauge decaying vote as the orchestrator.
   * @dev Extracted so the decaying-stake case keeps each block's stack small (the inline snapshot and
   *      list construction otherwise trip the legacy-codegen stack limit). Never updates the scalar.
   * @param _gauges Single-element gauge list to vote.
   * @param _amount Allocation booked on the gauge and the budget seeded.
   * @param _stakeEnd Decaying stake expiry for the snapshot.
   */
  function _decayingVote(address[] memory _gauges, uint128 _amount, uint48 _stakeEnd) internal {
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _amount;
    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      IVoterCommon.TokenSnapshot({staked: _amount, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0}),
      _list(_gauges, _amounts)
    );
  }

  /*////////////////////////////////////////////////////////////
                          ACCESS CONTROL
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheCallerIsNotTheLeafMessageOrchestrator(address _caller) external {
    _caller = _boundNotEq(_caller, _LEAF_MESSAGE_ORCHESTRATOR);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should revert with NotMessageOrchestrator
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotMessageOrchestrator.selector));
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );
  }

  function test_WhenTheChainIsSuspended(uint128 _amountA, uint128 _amountB) external {
    // A suspended chain keeps processing root allocations so the mirror self-repairs: the token
    // state applies exactly as in the active case (only the chain rate is masked elsewhere).
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;

    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB);

    // it should still distribute the allocation without reverting
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      _permanentSnapshot(_amountA + _amountB),
      _list(_gauges, _amounts)
    );

    // The suspended chain applies token state exactly as the active case: gauge weight is booked,
    // gauges are added to the voted set, and a call params entry is returned per gauge.
    assertEq(_gaugeWeight(_GAUGE_A), _amountA);
    assertEq(_gaugeWeight(_GAUGE_B), _amountB);
    assertEq(_inVotedSet(_GAUGE_A), true);
    assertEq(_inVotedSet(_GAUGE_B), true);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amountA);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_B), _amountB);
    assertEq(_callParamsList.length, 2);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
    assertEq(_callParamsList[1].gauge, _GAUGE_B);
    // Each entry carries the allocation it was recorded at, so a reentrant reward cannot change what a
    // later checkpoint is checkpointed against.
    assertEq(_callParamsList[0].allocated, _amountA);
    assertEq(_callParamsList[1].allocated, _amountB);
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  /*////////////////////////////////////////////////////////////
                            COOLDOWN
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheCooldownHasNotElapsedAfterApplyingTheReduction(uint48 _elapsed, uint48 _reduction) external {
    // Anchor the prior vote so `block.timestamp < lastAllocated + (allocationCooldown - used)` holds: the
    // remaining effective cooldown strictly exceeds the elapsed time. `used = min(pending, cooldown)`; keep
    // the pending reduction below the full cooldown so it cannot fully waive it.
    _reduction = uint48(bound(_reduction, 0, _VOTE_COOLDOWN - 1));
    uint48 _effectiveCooldown = _VOTE_COOLDOWN - _reduction;
    _elapsed = uint48(bound(_elapsed, 0, _effectiveCooldown - 1));

    // Seed the pending reduction the consume path clamps and applies.
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _reduction);

    // Seed lastAllocated so exactly `_elapsed` seconds have passed at the current timestamp.
    bytes32 _slot = keccak256(abi.encode(_TOKEN_ID, _TOKEN_STATE_SLOT));
    uint256 _current = uint256(vm.load(address(_leafVoter), _slot));
    uint256 _mask = uint256(type(uint48).max) << 160;
    uint48 _lastAllocated = uint48(block.timestamp) - _elapsed;
    vm.store(address(_leafVoter), _slot, bytes32((_current & ~_mask) | (uint256(_lastAllocated) << 160)));

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should revert with CooldownActive
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.CooldownActive.selector));
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should not consume the pending reduction on revert
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _reduction);
  }

  function test_WhenASufficientReductionBringsTheEffectiveCooldownToZero() external {
    // Prior vote anchors lastAllocated at the current block, so with no reduction a same-block re-vote
    // would revert. A pending reduction equal to the full cooldown zeroes the effective cooldown and lets
    // it through, consuming exactly the cooldown from the pending balance.
    _arrangePriorVote(_permanentSnapshot(0), new IVoterCommon.GaugeAllocation[](0));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should clear the pending reduction it consumed
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), 0);
    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenAPartialReductionExceedsTheCooldown(uint48 _leftover) external {
    // A pending reduction above the full cooldown consumes only the cooldown (clamped); the surplus
    // persists for the next allocation. The prior vote anchors lastAllocated at this block, so the
    // clamped consume must still fully waive the cooldown for a same-block re-vote.
    _leftover = uint48(bound(_leftover, 1, type(uint48).max - _VOTE_COOLDOWN));
    _arrangePriorVote(_permanentSnapshot(0), new IVoterCommon.GaugeAllocation[](0));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _VOTE_COOLDOWN + _leftover);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should persist the leftover pending reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), _leftover);
    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenAPartialReductionFullyClearsAReducedCooldownThatJustElapsed(uint48 _pending) external {
    // Pending is bounded in [1, _VOTE_COOLDOWN-1] so `used = pending` and the reduced cooldown
    // `allocationCooldown - pending` is non-zero. Anchor lastAllocated so that reduced cooldown has
    // JUST elapsed at the current timestamp: the allocation succeeds and the whole pending is consumed.
    _pending = uint48(bound(_pending, 1, _VOTE_COOLDOWN - 1));
    uint48 _reducedCooldown = _VOTE_COOLDOWN - _pending;

    _mockAccumulatedCooldownReduction(_TOKEN_ID, _pending);

    // Seed lastAllocated so exactly `_reducedCooldown` seconds have passed: the gate just clears.
    bytes32 _slot = keccak256(abi.encode(_TOKEN_ID, _TOKEN_STATE_SLOT));
    uint256 _current = uint256(vm.load(address(_leafVoter), _slot));
    uint256 _mask = uint256(type(uint48).max) << 160;
    uint48 _lastAllocated = uint48(block.timestamp) - _reducedCooldown;
    vm.store(address(_leafVoter), _slot, bytes32((_current & ~_mask) | (uint256(_lastAllocated) << 160)));

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should clear the pending reduction
    assertEq(_leafVoter.accumulatedCooldownReduction(_TOKEN_ID), 0);
    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
  }

  function test_WhenTheAllocationSetExceedsTheMaxGauges() external {
    // The remote path must enforce the leaf-owned cap exactly as the local `allocateGauges` does.
    // Root ships the gauge list without a count cap, so the leaf is the only place it is bounded;
    // an unbounded list would make the message's forward loop undeliverable.
    vm.prank(_VOTER_CONFIG);
    _leafVoter.setMaxGauges(1);

    // A fresh token has lastAllocated == 0, so the cooldown is already elapsed at the seed timestamp.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = 1;
    _amounts[1] = 1;

    // it should revert with ExceedsMaxGauges
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ExceedsMaxGauges.selector));
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(2), _list(_gauges, _amounts)
    );
  }

  function test_WhenTheAllocationSumExceedsTheChainAllocation() external {
    // The remote path must bound the gauge distribution by the tokenId's chain budget, exactly as the
    // local allocateGauges does. Root does not pre-validate the sum, so without this the leaf would book
    // gauge weight beyond the budget the token parked on the chain.
    _mockChainAllocation(_TOKEN_ID, 1);

    // A fresh token has lastAllocated == 0, so the cooldown is already elapsed at the seed timestamp.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = 1;
    _amounts[1] = 1; // total 2 exceeds the budget of 1

    // it should revert with ChainAllocationMismatch
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ChainAllocationMismatch.selector));
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(2), _list(_gauges, _amounts)
    );
  }

  function test_WhenAStaleAllocationExceedsAChainAllocationReducedByAPriorDeallocation(
    uint128 _priorAmount,
    uint128 _drained
  ) external {
    // The deallocation race: the token voted GAUGE_A at its full budget, then deallocate() drained
    // part of that budget back to root, reducing chainAllocation. A stale in-flight AllocateGauge
    // carrying the pre-deallocation full amount must bounce, so the leaf never re-books voting power
    // root no longer holds on this chain. Post-deallocate state is seeded directly (unit isolation).
    _priorAmount = uint128(bound(_priorAmount, 2, _MAX_AMOUNT));
    _drained = uint128(bound(_drained, 1, _priorAmount - 1));
    uint128 _remaining = _priorAmount - _drained;
    _mockRegisterGauge(_GAUGE_A, true);

    address[] memory _gauges = new address[](1);
    uint128[] memory _priorAmounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _priorAmounts[0] = _priorAmount;
    // Prior vote books GAUGE_A at the full budget (the helper seeds chainAllocation to the sum).
    _arrangePriorVote(_permanentSnapshot(_priorAmount), _list(_gauges, _priorAmounts));
    // Prior vote anchored lastAllocated this block; a full pending reduction waives the same-block cooldown.
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    // deallocate() reduced the budget to the remainder.
    _mockChainAllocation(_TOKEN_ID, _remaining);

    // A stale AllocateGauge re-votes the pre-deallocation full amount, exceeding the reduced budget.
    uint128[] memory _staleAmounts = new uint128[](1);
    _staleAmounts[0] = _priorAmount;

    // it should revert with ChainAllocationMismatch
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.ChainAllocationMismatch.selector));
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      _permanentSnapshot(_priorAmount),
      _list(_gauges, _staleAmounts)
    );
  }

  /*////////////////////////////////////////////////////////////
                        WRAPPER BOOKKEEPING
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheAllocationSetIsEmptyAndTheTokenHasNoPriorVotedGauges() external {
    // A fresh token has lastAllocated == 0 and no pending reduction, so the cooldown is already
    // elapsed and nothing is consumed.
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
    // it should return an empty call params list
    assertEq(_callParamsList.length, 0);
  }

  function test_WhenTheAllocationSetIsEmptyAndTheTokenHasPriorVotedGauges(uint128 _priorAmount) external {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);

    // Prior vote books weight on _GAUGE_A.
    address[] memory _priorGauges = new address[](1);
    uint128[] memory _priorAmounts = new uint128[](1);
    _priorGauges[0] = _GAUGE_A;
    _priorAmounts[0] = _priorAmount;
    _arrangePriorVote(_permanentSnapshot(_priorAmount), _list(_priorGauges, _priorAmounts));

    // The prior vote anchored lastAllocated at this block; seed a full pending reduction so the
    // same-block re-vote clears the cooldown.
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    _mockChainAllocation(_TOKEN_ID, 0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(0), _allocations
    );

    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
    // it should decrease the stored gauge allocation by the prior amount
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should decrease the chain weight by the prior allocated amount
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    // it should remove the gauge from the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    // it should return a call params entry per prior voted gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  function test_WhenEveryAllocationTargetsARoutableGauge(uint128 _amountA, uint128 _amountB) external {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;

    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      _permanentSnapshot(_amountA + _amountB),
      _list(_gauges, _amounts)
    );

    // A fresh token has no pending reduction, so nothing is consumed.
    // it should set the last voted timestamp to the current timestamp
    assertEq(_lastVotedOf(_TOKEN_ID), uint48(block.timestamp));
    // it should increase the chain weight by each allocated amount
    assertEq(_gaugeWeight(_GAUGE_A), _amountA);
    assertEq(_gaugeWeight(_GAUGE_B), _amountB);
    // it should add each gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    assertEq(_inVotedSet(_GAUGE_B), true);
    // it should store each gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amountA);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_B), _amountB);
    // it should return one call params entry per gauge
    assertEq(_callParamsList.length, 2);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
    assertEq(_callParamsList[1].gauge, _GAUGE_B);
  }

  function test_WhenARoutableGaugeReceivesADecayingStake(uint128 _amount, uint128 _newAmount) external {
    // A decaying stake books bias and slope instead of permanent balance. At or
    // above MAXTIME the slope rounds to a non-zero value, so the gauge is stored.
    uint128 _maxtime = uint128(MAXTIME);
    _amount = uint128(bound(_amount, _maxtime, _MAX_AMOUNT));
    _newAmount = uint128(bound(_newAmount, _maxtime, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _stakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;

    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;

    // Contribution evaluated at the unchanged lastSettlement, mirroring `_contribution`.
    {
      int128 _slope = int128(_amount / _maxtime);
      int128 _bias = _slope * int128(uint128(_stakeEnd - _settledAt));

      _decayingVote(_gauges, _amount, _stakeEnd);

      (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_GAUGE_A);
      // it should book the decaying bias and slope on the gauge point
      assertEq(_point.bias, _bias);
      assertEq(_point.slope, _slope);
      assertEq(_point.permanentStakeBalance, 0);
      // it should schedule the slope change at the stake expiry
      assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), _slope);
      // it should add the gauge to the voted set
      assertEq(_inVotedSet(_GAUGE_A), true);
      // it should store the gauge allocation
      assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    }

    // Re-vote with a new amount and a later expiry. A full pending reduction clears the same-block cooldown.
    {
      uint48 _newStakeEnd = _nextWeekBoundary(_settledAt) + 104 * _WEEK;
      int128 _newSlope = int128(_newAmount / _maxtime);
      int128 _newBias = _newSlope * int128(uint128(_newStakeEnd - _settledAt));

      _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);
      _decayingVote(_gauges, _newAmount, _newStakeEnd);

      (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_GAUGE_A);
      // it should unwind the prior bias and slope when the gauge is re-voted with a new expiry
      assertEq(_point.bias, _newBias);
      assertEq(_point.slope, _newSlope);
      // it should rewrite the scheduled slope change at the new expiry
      assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), 0);
      assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _newStakeEnd), _newSlope);
      assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _newAmount);
      assertEq(_inVotedSet(_GAUGE_A), true);
    }
  }

  /*////////////////////////////////////////////////////////////
                          VOTE CLASSES
  ////////////////////////////////////////////////////////////*/

  modifier whenAnAllocationKeepsAPreviouslyVotedGauge() {
    _mockRegisterGauge(_GAUGE_A, true);
    _;
  }

  function test_GivenTheNewAllocationEqualsThePriorAllocation(uint128 _amount)
    external
    whenAnAllocationKeepsAPreviouslyVotedGauge
  {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;
    _arrangePriorVote(_permanentSnapshot(_amount), _list(_gauges, _amounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should leave the net chain weight unchanged
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    // it should overwrite the stored gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    // it should leave the gauge in the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    // it should return one call params entry for the gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  function test_GivenTheNewAllocationIsGreaterThanThePriorAllocation(
    uint128 _priorAmount,
    uint128 _delta
  ) external whenAnAllocationKeepsAPreviouslyVotedGauge {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    uint128 _newAmount = _priorAmount + _delta;

    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;
    uint128[] memory _priorAmounts = new uint128[](1);
    _priorAmounts[0] = _priorAmount;
    uint128[] memory _newAmounts = new uint128[](1);
    _newAmounts[0] = _newAmount;
    _arrangePriorVote(_permanentSnapshot(_priorAmount), _list(_gauges, _priorAmounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    _mockChainAllocation(_TOKEN_ID, _newAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_newAmount), _list(_gauges, _newAmounts)
    );

    // it should increase the net chain weight by the allocation difference
    assertEq(_gaugeWeight(_GAUGE_A), _newAmount);
    // it should overwrite the stored gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _newAmount);
    // it should leave the gauge in the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    // it should return one call params entry for the gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  function test_GivenTheNewAllocationIsLessThanThePriorAllocation(
    uint128 _newAmount,
    uint128 _delta
  ) external whenAnAllocationKeepsAPreviouslyVotedGauge {
    _newAmount = uint128(bound(_newAmount, 1, _MAX_AMOUNT));
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    uint128 _priorAmount = _newAmount + _delta;

    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;
    uint128[] memory _priorAmounts = new uint128[](1);
    _priorAmounts[0] = _priorAmount;
    uint128[] memory _newAmounts = new uint128[](1);
    _newAmounts[0] = _newAmount;
    _arrangePriorVote(_permanentSnapshot(_priorAmount), _list(_gauges, _priorAmounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    _mockChainAllocation(_TOKEN_ID, _newAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_newAmount), _list(_gauges, _newAmounts)
    );

    // it should decrease the net chain weight by the allocation difference
    assertEq(_gaugeWeight(_GAUGE_A), _newAmount);
    // it should overwrite the stored gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _newAmount);
    // it should leave the gauge in the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    // it should return one call params entry for the gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  function test_WhenAPreviouslyVotedGaugeIsOmittedFromTheAllocationSet(uint128 _amountA, uint128 _amountB) external {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);

    // Prior vote books both gauges; the new vote keeps only _GAUGE_A.
    address[] memory _priorGauges = new address[](2);
    uint128[] memory _priorAmounts = new uint128[](2);
    _priorGauges[0] = _GAUGE_A;
    _priorGauges[1] = _GAUGE_B;
    _priorAmounts[0] = _amountA;
    _priorAmounts[1] = _amountB;
    _arrangePriorVote(_permanentSnapshot(_amountA + _amountB), _list(_priorGauges, _priorAmounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    address[] memory _newGauges = new address[](1);
    uint128[] memory _newAmounts = new uint128[](1);
    _newGauges[0] = _GAUGE_A;
    _newAmounts[0] = _amountA;

    _mockChainAllocation(_TOKEN_ID, _amountA);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amountA), _list(_newGauges, _newAmounts)
    );

    // it should decrease the stored gauge allocation by the prior amount
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_B), 0);
    // it should decrease the chain weight by the prior allocated amount
    assertEq(_gaugeWeight(_GAUGE_B), 0);
    // it should remove the gauge from the voted set
    assertEq(_inVotedSet(_GAUGE_B), false);
    // it should return a call params entry for the dropped gauge
    ILeafVoter.CheckpointData memory _dropped;
    for (uint256 _i; _i < _callParamsList.length; ++_i) {
      if (_callParamsList[_i].gauge == _GAUGE_B) {
        _dropped = _callParamsList[_i];
        break;
      }
    }
    assertEq(_dropped.gauge, _GAUGE_B);
    // A cleared position is recorded at zero, not left to be resolved from storage at checkpoint time.
    assertEq(_dropped.allocated, 0);
  }

  /*////////////////////////////////////////////////////////////
                            ROUTING
  ////////////////////////////////////////////////////////////*/

  function test_WhenAnAllocationTargetsAnUnregisteredGauge(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));

    // _GAUGE_A is left unregistered.
    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should park the allocation weight on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
  }

  function test_WhenAnAllocationTargetsAnInactiveGaugeAndTheTokenIsNotWhitelisted(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Registered but not activated, and the token is not whitelisted.
    _mockRegisterGauge(_GAUGE_A, false);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should park the allocation weight on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
  }

  function test_WhenSeveralAllocationsTargetUnroutableGauges(uint128 _amountA, uint128 _amountB) external {
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    // _GAUGE_A unregistered, _GAUGE_B registered-inactive with no whitelist.
    _mockRegisterGauge(_GAUGE_B, false);

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;

    _mockChainAllocation(_TOKEN_ID, _amountA + _amountB);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      _permanentSnapshot(_amountA + _amountB),
      _list(_gauges, _amounts)
    );

    // it should sum the redirected weight into a single zero gauge contribution
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amountA + _amountB);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amountA + _amountB);
    // it should not add any of the gauges to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    assertEq(_inVotedSet(_GAUGE_B), false);
  }

  function test_WhenTheTokenIsWhitelistedForAnInactiveGauge(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, false);
    // The whitelist covers only activated zero-cap gauges, so it must not
    // route this inactive-gauge allocation.
    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_TOKEN_ID, true);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should park the allocation weight on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    assertEq(_gaugeWeight(_GAUGE_A), 0);
  }

  function test_WhenAnAllocationTargetsAZeroCapGaugeAndTheTokenIsNotWhitelisted(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Activated, but the emission cap is zeroed and the token is not whitelisted.
    _mockRegisterGauge(_GAUGE_A, true);
    _mockEmissionCap(_GAUGE_A, 0);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should park the allocation weight on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _amount);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _amount);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
  }

  function test_WhenTheTokenIsWhitelistedForAZeroCapGauge(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    // Activated with a zeroed emission cap, and the token whitelisted for
    // zero-cap gauges, so the allocation routes to the real gauge.
    _mockRegisterGauge(_GAUGE_A, true);
    _mockEmissionCap(_GAUGE_A, 0);
    vm.prank(_TOKEN_WHITELIST);
    _leafVoter.setCanVoteForZeroCapGauges(_TOKEN_ID, true);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should increase the chain weight by the allocated amount
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    // it should add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), true);
    // the redirect sink stays empty
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
  }

  /*////////////////////////////////////////////////////////////
                            EDGE CASES
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheNewSnapshotIsExpired(
    uint128 _priorGaugeAmount,
    uint128 _priorZeroAmount,
    uint128 _newGaugeAmount,
    uint128 _newZeroAmount
  ) external {
    // The prior vote uses a decaying stake (above MAXTIME so its bias and slope
    // are really booked) with a future expiry. The new snapshot carries an expiry
    // at or before lastSettlement, so the apply side is skipped everywhere and the
    // prior contribution is unwound against the old snapshot's still-future expiry.
    uint128 _maxtime = uint128(MAXTIME);
    _priorGaugeAmount = uint128(bound(_priorGaugeAmount, _maxtime, _MAX_AMOUNT));
    _priorZeroAmount = uint128(bound(_priorZeroAmount, _maxtime, _MAX_AMOUNT));
    _newGaugeAmount = uint128(bound(_newGaugeAmount, 1, _MAX_AMOUNT));
    _newZeroAmount = uint128(bound(_newZeroAmount, 1, _MAX_AMOUNT));
    // _GAUGE_A routable, _GAUGE_B unregistered so its weight parks on the sink.
    _mockRegisterGauge(_GAUGE_A, true);

    uint48 _stakeEnd = _nextWeekBoundary(_leafVoter.lastSettlement()) + 52 * _WEEK;

    address[] memory _gauges = new address[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;

    // Prior decaying vote books bias and slope on _GAUGE_A and the zero gauge sink.
    {
      uint128[] memory _priorAmounts = new uint128[](2);
      _priorAmounts[0] = _priorGaugeAmount;
      _priorAmounts[1] = _priorZeroAmount;
      _arrangePriorVote(
        IVoterCommon.TokenSnapshot({
          staked: _priorGaugeAmount + _priorZeroAmount, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0
        }),
        _list(_gauges, _priorAmounts)
      );
    }
    // Prior vote anchored lastAllocated this block; a full pending reduction waives the same-block cooldown.
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    // The new snapshot has already expired at the last settlement.
    uint128[] memory _newAmounts = new uint128[](2);
    _newAmounts[0] = _newGaugeAmount;
    _newAmounts[1] = _newZeroAmount;
    IVoterCommon.TokenSnapshot memory _expired = IVoterCommon.TokenSnapshot({
      staked: 0, stakeEnd: _leafVoter.lastSettlement() - 1, isPermanent: (_leafVoter.lastSettlement() - 1) == 0
    });

    _mockChainAllocation(_TOKEN_ID, _newGaugeAmount + _newZeroAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _expired, _list(_gauges, _newAmounts)
    );

    // it should contribute nothing to any incoming gauge
    // it should decrease the chain weight by the prior allocated amount
    {
      (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_GAUGE_A);
      assertEq(_point.bias, 0);
      assertEq(_point.slope, 0);
      assertEq(_leafVoter.gaugeSlopeChanges(_GAUGE_A, _stakeEnd), 0);
    }
    // it should decrease the stored gauge allocation by the prior amount
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should remove every prior voted gauge from the voted set
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
    // it should return a call params entry per prior voted gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
    // it should decrease the chain weight by the prior zero gauge allocated amount
    {
      (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_ZERO_GAUGE);
      assertEq(_point.bias, 0);
      assertEq(_point.slope, 0);
      assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _stakeEnd), 0);
    }
    // it should clear the zero gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
  }

  function test_WhenAFreshAllocationRoundsDownToZeroWeightOnAGaugePendingSettlement(uint128 _amount) external {
    // Decaying allocations below MAXTIME wei round slope and bias to zero.
    _amount = uint128(bound(_amount, 1, uint128(MAXTIME) - 1));

    // _GAUGE_A is routable and carries cross-voter weight over an unsettled
    // window: its cursor sits a day behind the chain with a stale index, so a
    // settle would walk a non-zero share, credit the ceiling, and advance the
    // cursor. The dust vote must not trigger that settle.
    uint48 _gaugeSettledAt = _SEED_TIMESTAMP - 1 days;
    uint128 _crossVoterWeight = 1e18;
    _mockChainAccumulator({_emissionsPerVP: 0, _index: _PRECISION});
    _mockEmissionCap(_GAUGE_A, type(uint128).max);
    ILeafVoter.GaugeState memory _gaugeState = _buildGaugeState({
      _ceiling: 0,
      _claimed: 0,
      _lastSettlement: _gaugeSettledAt,
      _isRegistered: true,
      _surplus: 0,
      _lastIndex: 0,
      _point: _buildPoint({_bias: 0, _slope: 0, _ts: _gaugeSettledAt, _permanentStakeBalance: _crossVoterWeight})
    });
    // _GAUGE_A must be activated so the fresh allocation routes to it directly.
    _gaugeState.isActivated = true;
    _mockGaugeState(_GAUGE_A, _gaugeState);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;
    IVoterCommon.TokenSnapshot memory _decaying = IVoterCommon.TokenSnapshot({
      staked: _amount,
      stakeEnd: _leafVoter.lastSettlement() + 52 * _WEEK,
      isPermanent: (_leafVoter.lastSettlement() + 52 * _WEEK) == 0
    });

    ILeafVoter.GaugeState memory _before = _gaugeStateOf(_GAUGE_A);

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _decaying, _list(_gauges, _amounts)
    );

    // it should leave the gauge settlement cursor unchanged
    assertEq(_gaugeStateOf(_GAUGE_A).lastSettlement, _before.lastSettlement);
    // it should leave the gauge ceiling unchanged
    assertEq(_gaugeStateOf(_GAUGE_A).ceiling, _before.ceiling);
    // it should not store the gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should not add the gauge to the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    // it should not return a call params entry for the gauge
    assertEq(_callParamsList.length, 0);
  }

  function test_WhenAKeptGaugeAllocationRoundsDownToZeroWeight(uint128 _priorAmount, uint128 _dustAmount) external {
    _priorAmount = uint128(bound(_priorAmount, 1, _MAX_AMOUNT));
    _dustAmount = uint128(bound(_dustAmount, 1, uint128(MAXTIME) - 1));
    _mockRegisterGauge(_GAUGE_A, true);

    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;
    uint128[] memory _priorAmounts = new uint128[](1);
    _priorAmounts[0] = _priorAmount;
    uint128[] memory _dustAmounts = new uint128[](1);
    _dustAmounts[0] = _dustAmount;

    // Prior permanent vote books real weight on _GAUGE_A.
    _arrangePriorVote(_permanentSnapshot(_priorAmount), _list(_gauges, _priorAmounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    // New decaying vote rounds to zero, so the kept gauge is dropped.
    IVoterCommon.TokenSnapshot memory _decaying = IVoterCommon.TokenSnapshot({
      staked: _dustAmount,
      stakeEnd: _leafVoter.lastSettlement() + 52 * _WEEK,
      isPermanent: (_leafVoter.lastSettlement() + 52 * _WEEK) == 0
    });

    _mockChainAllocation(_TOKEN_ID, _dustAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _decaying, _list(_gauges, _dustAmounts)
    );

    // it should decrease the stored gauge allocation by the prior amount
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should decrease the chain weight by the prior allocated amount
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    // it should remove the gauge from the voted set
    assertEq(_inVotedSet(_GAUGE_A), false);
    // it should return a call params entry for the gauge
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  function test_WhenTheTokenCarriedAPriorZeroGaugeAllocation(
    uint128 _priorZeroAmount,
    uint128 _newZeroAmount
  ) external {
    _priorZeroAmount = uint128(bound(_priorZeroAmount, 1, _MAX_AMOUNT));
    _newZeroAmount = uint128(bound(_newZeroAmount, 1, _MAX_AMOUNT));

    // _GAUGE_A unregistered, so both votes park their weight on the sink.
    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;
    uint128[] memory _priorAmounts = new uint128[](1);
    _priorAmounts[0] = _priorZeroAmount;
    uint128[] memory _newAmounts = new uint128[](1);
    _newAmounts[0] = _newZeroAmount;
    _arrangePriorVote(_permanentSnapshot(_priorZeroAmount), _list(_gauges, _priorAmounts));
    _mockAccumulatedCooldownReduction(_TOKEN_ID, _MAX_REDUCTION);

    _mockChainAllocation(_TOKEN_ID, _newZeroAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID,
      uint48(block.timestamp),
      0,
      false,
      true,
      _permanentSnapshot(_newZeroAmount),
      _list(_gauges, _newAmounts)
    );

    // it should decrease the chain weight by the prior zero gauge allocated amount
    // it should increase the chain weight by the new zero gauge allocated amount
    // Net of both is the new amount, proving the prior was unwound before the apply.
    assertEq(_gaugeWeight(_ZERO_GAUGE), _newZeroAmount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _newZeroAmount);
  }

  /*////////////////////////////////////////////////////////////
                          MESSAGE EXPIRY
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheAllocationMessageHasExpired(uint48 _expiry) external {
    // A root-stamped deadline strictly before now is rejected before any state mutation.
    _expiry = uint48(bound(_expiry, 0, block.timestamp - 1));

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should revert with AllocationExpired
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.AllocationExpired.selector));
    _leafVoter.applyGaugeAllocations(_TOKEN_ID, _expiry, 0, false, true, _permanentSnapshot(0), _allocations);
  }

  function test_WhenTheMessageExpiryHasNotPassed(uint128 _amount, uint48 _expiry) external {
    // Any deadline at or after now (including a leaf clock behind the root stamp) passes the expiry
    // gate and applies normally. Reuse the routable happy-path assertions.
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));
    _mockRegisterGauge(_GAUGE_A, true);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    _mockChainAllocation(_TOKEN_ID, _amount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, _expiry, 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should apply the allocation normally
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    assertEq(_inVotedSet(_GAUGE_A), true);
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  /*////////////////////////////////////////////////////////////
                          DEALLOCATION SENTINEL
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheAllocationContainsTheDeallocationSentinel(
    uint128 _gaugeAmount,
    uint128 _deallocAmount
  ) external {
    _gaugeAmount = uint128(bound(_gaugeAmount, 1, _MAX_AMOUNT));
    _deallocAmount = uint128(bound(_deallocAmount, 1, _MAX_AMOUNT));
    // `_GAUGE_A` (0xAAA1) sorts below the keccak-derived `_DEALLOC_GAUGE`, so the list is ascending.
    // The routable gauge must behave exactly as in the plain routable case, while the sentinel is
    // turned into an immediate deallocation dispatch: its amount counts toward the validated total (so
    // the budget covers both) but is never parked, stored, settled, or added to the voted set.
    _mockRegisterGauge(_GAUGE_A, true);

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _DEALLOC_GAUGE;
    _amounts[0] = _gaugeAmount;
    _amounts[1] = _deallocAmount;

    uint128 _budget = _gaugeAmount + _deallocAmount;
    _mockChainAllocation(_TOKEN_ID, _budget);

    // Root-triggered path: the voter attaches no value at all. It flags `_fundFromPool` so the
    // orchestrator draws the live quote from its own pre-funding, and passes a zero gas limit so the
    // orchestrator substitutes its own configured `deallocationGasLimit`.

    // it should dispatch a Deallocate message drawing from the orchestrator pool on the inbound path
    // Zero transport value plus `_fundFromPool == true` is what tells the orchestrator to charge the quote
    // against its pre-funding; the refund recipient is the inbound caller, which the orchestrator overrides
    // to itself for a pool-funded return.
    bytes memory _payload =
      abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _TOKEN_ID, amount: _deallocAmount}));
    _mockAndExpectOnceWithValue(
      _LEAF_MESSAGE_ORCHESTRATOR,
      0,
      abi.encodeCall(
        ILeafMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.Deallocate, _payload, uint256(0), _LEAF_MESSAGE_ORCHESTRATOR, true)
      ),
      ''
    );
    // it should emit the Deallocated event
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.Deallocated(_TOKEN_ID, _deallocAmount);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_budget), _list(_gauges, _amounts)
    );

    // it should decrement the chain allocation by the sentinel amount
    assertEq(_chainAllocationOf(_TOKEN_ID), _gaugeAmount);
    // the voter never holds native for the return: funding lives entirely in the orchestrator
    assertEq(address(_leafVoter).balance, 0);
    // it should book the routable gauge exactly as usual
    assertEq(_gaugeWeight(_GAUGE_A), _gaugeAmount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _gaugeAmount);
    assertEq(_inVotedSet(_GAUGE_A), true);
    // it should not park the sentinel, store an allocation, add it to the voted set, or checkpoint it
    assertEq(_gaugeWeight(_DEALLOC_GAUGE), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _DEALLOC_GAUGE), 0);
    assertEq(_inVotedSet(_DEALLOC_GAUGE), false);
    (,, uint48 _sentinelSettled, bool _sentinelRegistered,,,,,) = _leafVoter.gaugeStates(_DEALLOC_GAUGE);
    assertEq(_sentinelRegistered, false);
    assertEq(_sentinelSettled, 0);
    // it should return only the routable gauge in the call params list
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
  }

  /*////////////////////////////////////////////////////////////
                            CHAIN SCALAR
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheMessageIsTheNewestGaugeAllocationAndTheChainIsActive(uint256 _emissionsPerVP) external {
    // Gauge votes are far more frequent than chain allocations, so the newest gauge message refreshes
    // the global scalar the same way `applyChainAllocation` does. With `_refreshEmissionsPerVP` true and the
    // chain active, the passed scalar lands in storage and `GaugesAllocated` carries the stored value.
    _emissionsPerVP = bound(_emissionsPerVP, 1, 1e36);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should emit GaugesAllocated carrying the stored scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, _emissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), _emissionsPerVP, true, true, _permanentSnapshot(0), _allocations
    );

    // it should set the emissions scalar to the passed value
    assertEq(_leafVoter.emissionsPerVP(), _emissionsPerVP);
  }

  function test_WhenTheMessageDoesNotUpdateTheScalar(
    uint256 _priorEmissionsPerVP,
    uint256 _staleEmissionsPerVP
  ) external {
    // A not-newest gauge message (`_refreshEmissionsPerVP == false`) must not touch the scalar: a distinct prior
    // value seeded via storage stays put. Bound the two apart so the assertions prove the passed value
    // was never written.
    _priorEmissionsPerVP = bound(_priorEmissionsPerVP, 1, 1e36);
    _staleEmissionsPerVP = bound(_staleEmissionsPerVP, 1e36 + 1, 2e36);
    _mockChainAccumulator({_emissionsPerVP: _priorEmissionsPerVP, _index: 0});

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should emit GaugesAllocated carrying the unchanged prior scalar, not the stale passed one
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, _priorEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), _staleEmissionsPerVP, false, true, _permanentSnapshot(0), _allocations
    );

    // it should leave the emissions scalar unchanged
    assertEq(_leafVoter.emissionsPerVP(), _priorEmissionsPerVP);
  }

  function test_WhenTheMessageUpdatesTheScalarButTheChainIsSuspended(uint256 _emissionsPerVP) external {
    // With `_refreshEmissionsPerVP` true but the chain Suspended, `_setEmissionsPerVP` masks the scalar to zero
    // (root diverts the suspended period to surplus), so the stored value is zero regardless of the
    // passed scalar. `GaugesAllocated` carries the stored (masked) zero.
    _emissionsPerVP = bound(_emissionsPerVP, 1, 1e36);
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should emit GaugesAllocated carrying the masked zero scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, 0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), _emissionsPerVP, true, true, _permanentSnapshot(0), _allocations
    );

    // it should mask the emissions scalar to zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
  }

  function test_WhenTheMessageUpdatesTheScalarButTheChainIsSunset(uint256 _emissionsPerVP) external {
    // An in-flight gauge message can land after the sunset flip carrying a positive scalar. Bridged
    // deliveries stay ungated, so it must apply, but `_setEmissionsPerVP` masks the scalar to zero
    // exactly as under Suspended, keeping the wind-down rate parked at zero.
    _emissionsPerVP = bound(_emissionsPerVP, 1, 1e36);
    _mockChainStatus(IVoterCommon.ChainStatus.Sunset);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    // it should emit GaugesAllocated carrying the masked zero scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, 0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), _emissionsPerVP, true, true, _permanentSnapshot(0), _allocations
    );

    // it should mask the emissions scalar to zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
  }

  function test_WhenTheScalarUpdateIsAppliedAfterTheIndexSettlesAtTheOldScalar(
    uint256 _mult,
    uint256 _priorIndex,
    uint256 _settleToRaw,
    uint256 _newEmissionsPerVP
  ) external {
    // Ordering guarantee: the index settles at the PRIOR scalar before the new one is applied. Seed a
    // prior scalar `_mult * PRECISION` and a settlement gap, then apply a distinct new scalar. The
    // settled `index` must reflect the OLD scalar (`priorIndex + old * dt`), and only afterwards is the
    // new scalar stored. Mirrors the `applyChainAllocation` ordering proof.
    _mult = bound(_mult, 1, 1e18);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _newEmissionsPerVP = bound(_newEmissionsPerVP, 1, 1e36);
    _mockChainAccumulator({_emissionsPerVP: _mult * _PRECISION, _index: _priorIndex});

    // Warp strictly after `lastSettlement` but before the next weekly boundary so the settle advances
    // by exactly `old * dt` with no boundary snapshot to reason about.
    uint48 _nextBoundary = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _settleTo = uint48(bound(_settleToRaw, _SEED_TIMESTAMP + 1, _nextBoundary - 1));
    vm.warp(_settleTo);

    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), _newEmissionsPerVP, true, true, _permanentSnapshot(0), _allocations
    );

    // it should settle the index at the old scalar before applying the new one
    assertEq(_leafVoter.index(), _priorIndex + _mult * (_settleTo - _SEED_TIMESTAMP) * _PRECISION);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
    // it should store the new scalar after settling
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
  }

  function test_WhenAGaugeAllocationIsApplied(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockChainAllocation(_TOKEN_ID, _amount);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;
    IVoterCommon.GaugeAllocation[] memory _allocations = _list(_gauges, _amounts);

    // it should emit the GaugesAllocated event with the requested allocations
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugesAllocated(_TOKEN_ID, _allocations, 0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _allocations
    );
  }

  function test_WhenABridgedGaugeMessageApplies(uint128 _amount, uint48 _stakeEnd) external {
    // Any gauge message reaching the voter is the token's newest, so the latest snapshot must track
    // its shape, landing equal to the stored one after the apply.
    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _stakeEnd = uint48(bound(_stakeEnd, block.timestamp + 1, type(uint48).max));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockChainAllocation(_TOKEN_ID, _amount);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations({
      _tokenId: _TOKEN_ID,
      _expiry: uint48(block.timestamp),
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: true,
      _newSnapshot: IVoterCommon.TokenSnapshot({
        staked: _MAX_AMOUNT, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0
      }),
      _gauges: _list(_gauges, _amounts)
    });

    // it should sync the latest snapshot to the message shape
    (uint128 _pendingStaked, uint48 _pendingStakeEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    assertEq(_pendingStaked, _MAX_AMOUNT);
    assertEq(_pendingStakeEnd, _stakeEnd);
    (uint128 _storedStaked, uint48 _storedStakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_storedStaked, _pendingStaked);
    assertEq(_storedStakeEnd, _pendingStakeEnd);
  }

  function test_WhenTheMessageSnapshotIsStalerThanTheLatest(uint128 _amount) external {
    // Attack: a delayed gauge message carries an OLD permanent shape (stakeEnd 0). Meanwhile the token
    // was downgraded and a chain reallocation moved `latestTokenSnapshot` to a DECAYING shape. Because a
    // chain message does not advance the orchestrator's token-gauge nonce, this stale gauge message is
    // still forwarded — and today the voter books the distribution at the message's PERMANENT shape,
    // resurrecting non-decaying voting power the token no longer has. The vote must book at the current
    // (latest) decaying shape instead.
    _amount = uint128(bound(_amount, uint128(MAXTIME), _MAX_AMOUNT));
    uint48 _decayEnd = uint48(block.timestamp) + 52 weeks;
    _mockRegisterGauge(_GAUGE_A, true);
    _mockChainAllocation(_TOKEN_ID, _amount);
    // Current shape is decaying, in both stored and latest (as a chain reallocation would leave it).
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _MAX_AMOUNT, _stakeEnd: _decayEnd});

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    // Stale message: `_refreshEmissionsPerVP == false` and a PERMANENT snapshot.
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations({
      _tokenId: _TOKEN_ID,
      _expiry: uint48(block.timestamp),
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: false,
      _newSnapshot: _permanentSnapshot(_MAX_AMOUNT),
      _gauges: _list(_gauges, _amounts)
    });

    // it should book the vote at the latest (decaying) shape, not the stale permanent one
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_GAUGE_A);
    assertEq(_point.permanentStakeBalance, 0);
    assertGt(_point.bias, 0);
  }

  function test_WhenLocalVotingIsDisabled(uint128 _amount) external {
    // `localVotingEnabled` gates only the local `allocateGauges` entrypoint. The bridged path stays
    // open with the switch closed, so a leaf can still move its budget through the orchestrator before
    // governance opens local voting. The switch defaults to false, so no seeding arranges it.
    assertFalse(_leafVoter.localVotingEnabled());

    _amount = uint128(bound(_amount, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockChainAllocation(_TOKEN_ID, _amount);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    ILeafVoter.CheckpointData[] memory _callParamsList = _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_amount), _list(_gauges, _amounts)
    );

    // it should still apply the bridged allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);
    assertEq(_gaugeWeight(_GAUGE_A), _amount);
    assertEq(_callParamsList.length, 1);
    assertEq(_callParamsList[0].gauge, _GAUGE_A);
    // it should still add the gauge to the voted set
    assertTrue(_inVotedSet(_GAUGE_A));
  }
}
