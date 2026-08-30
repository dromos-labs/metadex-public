// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

contract UnitLeafVoterApplyChainAllocation is BaseLeafVoter {
  /// @dev Fixed permanent VE shape carried by the message. Distinctive so the seed cases can assert it
  ///      landed. A permanent stake (`stakeEnd == 0`) parks the whole delta as `permanentStakeBalance`.
  function _snap() internal pure returns (IVoterCommon.TokenSnapshot memory _snapshot) {
    _snapshot = IVoterCommon.TokenSnapshot({staked: 7e18, stakeEnd: 0, isPermanent: (0) == 0});
  }

  /// @notice Read the decaying `(bias, slope)` booked on `_gauge`'s point.
  function _gaugeBiasSlope(address _gauge) internal view returns (int128 _bias, int128 _slope) {
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_gauge);
    _bias = _point.bias;
    _slope = _point.slope;
  }

  function test_WhenTheCallerIsNotTheLeafMessageOrchestrator(
    address _caller,
    uint128 _allocated,
    uint256 _emissionsPerVP
  ) external {
    _caller = _boundNotEq(_caller, _LEAF_MESSAGE_ORCHESTRATOR);

    // it should revert with NotMessageOrchestrator
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotMessageOrchestrator.selector));
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _emissionsPerVP, true, true, _snap());
  }

  function test_WhenTheChainIsSuspended(uint128 _allocated, uint256 _emissionsPerVP) external {
    // Self-repair: a suspended chain keeps applying root state so its mirror stays in sync. The
    // scalar setter masks the emissions scalar to zero regardless of the payload — root diverts
    // the suspended period to surplus — while the budget delta still lands and parks on `ZERO_GAUGE`.
    // Bound the delta so the permanent contribution stays inside `int128`.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _emissionsPerVP = bound(_emissionsPerVP, 1, 1e36);
    _mockChainStatus(IVoterCommon.ChainStatus.Suspended);

    // it should emit the ChainAllocated event carrying the masked (zero) scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, 0);

    // it should not revert
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _emissionsPerVP, true, true, _snap());

    // it should mask the emissions scalar to zero
    assertEq(_leafVoter.emissionsPerVP(), 0);
    // it should still record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
  }

  function test_WhenTheSettlementWindowIsEmpty(
    uint256 _priorEmissionsPerVP,
    uint256 _priorIndex,
    uint128 _allocated,
    uint256 _newEmissionsPerVP
  ) external {
    // Prior snapshot carries a non-zero scalar so a stray settlement would move `index`.
    _priorEmissionsPerVP = bound(_priorEmissionsPerVP, 1, 1e36);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: _priorEmissionsPerVP, _index: _priorIndex});

    // Settlement targets `block.timestamp`, which equals `lastSettlement` at the seed timestamp,
    // so the already-settled window stays untouched.

    // it should emit the ChainAllocated event carrying the new scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, _newEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _newEmissionsPerVP, true, true, _snap());

    // it should not advance the index
    assertEq(_leafVoter.index(), _priorIndex);
    // it should not change the last settlement
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP);
    // it should not snapshot any weekly boundary
    assertEq(_leafVoter.indexAtBoundary(_nextWeekBoundary(_SEED_TIMESTAMP)), 0);
    // it should override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
    // it should record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
    // it should not set the last voted timestamp (chain allocation must not reset the gauge cooldown)
    assertEq(_lastVotedOf(_TOKEN_ID), 0);
  }

  function test_WhenTheSettlementWindowCrossesNoWeeklyBoundary(
    uint256 _mult,
    uint256 _priorIndex,
    uint256 _settleToRaw,
    uint128 _allocated,
    uint256 _newEmissionsPerVP
  ) external {
    // Prior scalar `_mult * PRECISION` mirrors the old `chainRate * PRECISION / chainWeight` with
    // `chainRate == _mult * chainWeight`, so the expected index stays the closed-form
    // `_mult * elapsed * PRECISION`.
    _mult = bound(_mult, 1, 1e18);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: _mult * _PRECISION, _index: _priorIndex});

    // Settlement runs to `block.timestamp`: warp strictly after `lastSettlement` but before the
    // next weekly boundary.
    uint48 _nextBoundary = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _settleTo = uint48(bound(_settleToRaw, _SEED_TIMESTAMP + 1, _nextBoundary - 1));
    vm.warp(_settleTo);

    // it should emit the ChainAllocated event carrying the new scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, _newEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _newEmissionsPerVP, true, true, _snap());

    // it should advance the index using the prior emissions scalar
    assertEq(_leafVoter.index(), _priorIndex + _mult * (_settleTo - _SEED_TIMESTAMP) * _PRECISION);
    // it should not snapshot any weekly boundary
    assertEq(_leafVoter.indexAtBoundary(_nextBoundary), 0);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
    // it should override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
    // it should record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
    // it should not set the last voted timestamp (chain allocation must not reset the gauge cooldown)
    assertEq(_lastVotedOf(_TOKEN_ID), 0);
  }

  function test_WhenTheSettlementWindowCrossesWeeklyBoundaries(
    uint256 _mult,
    uint256 _priorIndex,
    uint256 _settleToRaw,
    uint128 _allocated,
    uint256 _newEmissionsPerVP
  ) external {
    _mult = bound(_mult, 1, 1e18);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: _mult * _PRECISION, _index: _priorIndex});

    // The first two boundaries after `lastSettlement` fall inside the window; the third does not.
    uint48 _boundary1 = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _boundary2 = _boundary1 + _WEEK;
    uint48 _boundary3 = _boundary1 + 2 * _WEEK;
    uint48 _settleTo = uint48(bound(_settleToRaw, _boundary2, _boundary3 - 1));
    vm.warp(_settleTo);

    // it should emit the ChainAllocated event carrying the new scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, _newEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _newEmissionsPerVP, true, true, _snap());

    // it should snapshot the index at each crossed boundary
    assertEq(_leafVoter.indexAtBoundary(_boundary1), _priorIndex + _mult * (_boundary1 - _SEED_TIMESTAMP) * _PRECISION);
    assertEq(_leafVoter.indexAtBoundary(_boundary2), _priorIndex + _mult * (_boundary2 - _SEED_TIMESTAMP) * _PRECISION);
    assertEq(_leafVoter.indexAtBoundary(_boundary3), 0);
    // it should advance the index using the prior emissions scalar
    assertEq(_leafVoter.index(), _priorIndex + _mult * (_settleTo - _SEED_TIMESTAMP) * _PRECISION);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
    // it should override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
    // it should record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
  }

  function test_WhenThePriorEmissionsScalarIsZero(
    uint256 _priorIndex,
    uint256 _settleToRaw,
    uint128 _allocated,
    uint256 _newEmissionsPerVP
  ) external {
    // A zero prior scalar advances the index by `0 * dt`, so each crossed boundary still records
    // the unchanged index. This subsumes the old zero-rate and zero-weight branches: both folded
    // into a single `emissionsPerVP == 0`.
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: 0, _index: _priorIndex});

    uint48 _boundary1 = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _boundary2 = _boundary1 + _WEEK;
    uint48 _boundary3 = _boundary1 + 2 * _WEEK;
    uint48 _settleTo = uint48(bound(_settleToRaw, _boundary2, _boundary3 - 1));
    vm.warp(_settleTo);

    // it should emit the ChainAllocated event carrying the new scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, _newEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _newEmissionsPerVP, true, true, _snap());

    // it should not advance the index
    assertEq(_leafVoter.index(), _priorIndex);
    // it should snapshot the unchanged index at each crossed boundary
    assertEq(_leafVoter.indexAtBoundary(_boundary1), _priorIndex);
    assertEq(_leafVoter.indexAtBoundary(_boundary2), _priorIndex);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
    // it should override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
    // it should record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
  }

  function test_WhenTheIndexAdvanceUsesAFractionalScalarOnAKnownExample(
    uint128 _allocated,
    uint256 _newEmissionsPerVP
  ) external {
    // Hand-computed example that pins the advance against a scalar that is not a clean multiple of
    // PRECISION. `emissionsPerVP` is the old rate-1 weight-7 snapshot folded down:
    // `floor(1 * 1e18 / 7) = 142857142857142857`. Over a 5 second window the index advances by
    // `142857142857142857 * 5 = 714285714285714285`, the same value the old `chainRate * dt *
    // PRECISION / chainWeight` produced.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: 142_857_142_857_142_857, _index: 0});

    // Settle 5 seconds after `lastSettlement`, still inside the first weekly segment.
    uint48 _settleTo = _SEED_TIMESTAMP + 5;
    vm.warp(_settleTo);

    // it should emit the ChainAllocated event carrying the new scalar
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _allocated, _allocated, _newEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _newEmissionsPerVP, true, true, _snap());

    // it should advance the index by the scalar times the elapsed seconds
    assertEq(_leafVoter.index(), 714_285_714_285_714_285);
    // it should not snapshot any weekly boundary
    assertEq(_leafVoter.indexAtBoundary(_nextWeekBoundary(_SEED_TIMESTAMP)), 0);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
    // it should override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _newEmissionsPerVP);
    // it should record the chain allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _allocated);
  }

  function test_WhenTheIndexSettlesEvenWithoutAScalarUpdate(
    uint256 _mult,
    uint256 _priorIndex,
    uint256 _settleToRaw,
    uint128 _delta,
    uint256 _staleEmissionsPerVP
  ) external {
    // The index now settles unconditionally, before any scalar override, so a not-newest message
    // (`_refreshEmissionsPerVP == false`) that still carries a delta closes the accrual at the prior rate.
    // This is required because the `ZERO_GAUGE` park below assumes the index is current.
    _mult = bound(_mult, 1, 1e18);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: _mult * _PRECISION, _index: _priorIndex});

    // Warp strictly after `lastSettlement` but before the next boundary.
    uint48 _nextBoundary = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _settleTo = uint48(bound(_settleToRaw, _SEED_TIMESTAMP + 1, _nextBoundary - 1));
    vm.warp(_settleTo);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _staleEmissionsPerVP, false, false, _snap());

    // it should settle the index at the prior scalar
    assertEq(_leafVoter.index(), _priorIndex + _mult * (_settleTo - _SEED_TIMESTAMP) * _PRECISION);
    // it should set the last settlement to the current timestamp
    assertEq(_leafVoter.lastSettlement(), _settleTo);
  }

  function test_WhenTheMessageIsNotTheNewestChainAllocation(
    uint256 _priorEmissionsPerVP,
    uint256 _priorIndex,
    uint128 _priorBudget,
    uint128 _delta,
    uint256 _staleEmissionsPerVP
  ) external {
    // A not-newest (stale-nonce) message: the orchestrator passes `_refreshEmissionsPerVP == false` and
    // `_refreshShape == false`. The budget delta still applies additively and still parks on `ZERO_GAUGE`, but
    // the global scalar is left untouched so a lower-nonce message can never overwrite the live rate. The index
    // still settles unconditionally, but here `block.timestamp == lastSettlement` so it is a no-op.
    // A not-newest shape means a newer message already established the token's shape, so seed a permanent one:
    // the stale park books against it, not against a default (unset) shape.
    _priorEmissionsPerVP = bound(_priorEmissionsPerVP, 1, 1e36);
    _priorIndex = bound(_priorIndex, 1, 1e30);
    _priorBudget = uint128(bound(_priorBudget, 0, _MAX_AMOUNT));
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    _mockChainAccumulator({_emissionsPerVP: _priorEmissionsPerVP, _index: _priorIndex});
    _mockChainAllocation(_TOKEN_ID, _priorBudget);
    _mockTokenSnapshot(_TOKEN_ID, 7e18, 0);

    // The event carries the unchanged (effective) scalar, not the stale one.
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _delta, _priorBudget + _delta, _priorEmissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _staleEmissionsPerVP, false, false, _snap());

    // it should add the allocation delta to the budget
    assertEq(_chainAllocationOf(_TOKEN_ID), _priorBudget + _delta);
    // it should leave the index and last settlement unchanged
    assertEq(_leafVoter.index(), _priorIndex);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP);
    // it should not override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _priorEmissionsPerVP);
    // it should still park the delta on the zero gauge (park is gated only on `_delta > 0`, not the scalar)
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _delta);
    assertEq(_gaugeWeight(_ZERO_GAUGE), _delta);
  }

  function test_WhenTheBudgetAlreadyHoldsAPriorAllocation(
    uint128 _priorBudget,
    uint128 _delta,
    uint256 _emissionsPerVP
  ) external {
    // Additive apply: a message adds its delta on top of the existing budget, never overwriting it.
    // This is what lets a reordered or in-flight `AllocateChain` commute with the leaf-first
    // `deallocate` decrement instead of resurrecting a deallocated budget — the fix for the stale
    // re-inflation double-count.
    _priorBudget = uint128(bound(_priorBudget, 1, _MAX_AMOUNT));
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    _mockChainAllocation(_TOKEN_ID, _priorBudget);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _emissionsPerVP, true, true, _snap());

    // it should add the delta on top of the prior allocation
    // it should not overwrite the prior allocation
    assertEq(_chainAllocationOf(_TOKEN_ID), _priorBudget + _delta);
  }

  function test_WhenNoGaugeWeightIsBookedYet(uint128 _allocated, uint256 _emissionsPerVP) external {
    // Fresh token, no gauges booked: the newest chain allocation seeds the stake shape so a local
    // allocateGauges before the first AllocateGauge distributes against the true shape, not a default
    // permanent one. With `_allocated > 0` the freshly-assigned budget is also parked on `ZERO_GAUGE`
    // at the seeded (permanent) shape. Bound the delta so the permanent cast stays inside `int128`.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _emissionsPerVP, true, true, _snap());

    // it should seed the token snapshot from the message
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    // it should seed the latest snapshot from the message
    {
      (uint128 _pendingStaked, uint48 _pendingStakeEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
      assertEq(_pendingStaked, _snap().staked);
      assertEq(_pendingStakeEnd, _snap().stakeEnd);
    }
    assertEq(_staked, _snap().staked);
    assertEq(_stakeEnd, _snap().stakeEnd);

    // it should park the delta on the zero gauge at the seeded (permanent) shape: the whole amount
    // lands as permanent balance since the seeded snapshot has `stakeEnd == 0`.
    assertEq(_gaugeWeight(_ZERO_GAUGE), _allocated);
    // it should track the parked allocation on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _allocated);
  }

  function test_WhenGaugeWeightIsAlreadyBooked(
    uint128 _allocated,
    uint256 _emissionsPerVP,
    uint128 _priorStaked
  ) external {
    // Once weight is booked, tokenSnapshot must stay pinned to the shape those contributions were
    // applied at; otherwise the next AllocateGauge unwinds against the wrong stakeEnd. The park uses
    // that STORED permanent shape, not the message's. Use a permanent stored shape so the parked
    // amount lands as permanent balance for an exact assertion.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _priorStaked = uint128(bound(_priorStaked, 1, _MAX_AMOUNT));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _priorStaked, _stakeEnd: 0});
    _mockVotedGauge(_TOKEN_ID, _GAUGE_A);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _allocated, _emissionsPerVP, true, true, _snap());

    // it should not overwrite the token snapshot
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, _priorStaked);
    assertEq(_stakeEnd, 0);

    // it should stash the message shape as the latest snapshot
    (uint128 _pendingStaked, uint48 _pendingStakeEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    assertEq(_pendingStaked, _snap().staked);
    assertEq(_pendingStakeEnd, _snap().stakeEnd);

    // it should park the delta on the zero gauge at the stored (permanent) shape
    assertEq(_gaugeWeight(_ZERO_GAUGE), _allocated);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _allocated);
  }

  function test_WhenAStaleMessageArrivesWithGaugeWeightBooked(
    uint128 _allocated,
    uint256 _emissionsPerVP,
    uint128 _priorStaked
  ) external {
    // A reordered stale message (`_refreshEmissionsPerVP == false`) must not roll the latest shape
    // backwards; the stored shape stays pinned too.
    _allocated = uint128(bound(_allocated, 1, _MAX_AMOUNT));
    _priorStaked = uint128(bound(_priorStaked, 1, _MAX_AMOUNT));
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: _priorStaked, _stakeEnd: 0});
    _mockVotedGauge(_TOKEN_ID, _GAUGE_A);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: _allocated,
      _emissionsPerVP: _emissionsPerVP,
      _refreshEmissionsPerVP: false,
      _refreshShape: false,
      _snapshot: _snap()
    });

    // it should leave the latest snapshot unchanged
    (uint128 _pendingStaked, uint48 _pendingStakeEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    assertEq(_pendingStaked, _priorStaked);
    assertEq(_pendingStakeEnd, 0);
  }

  function test_WhenTheMessageIsNotTheNewestChainAllocationForTheSnapshot(
    uint128 _delta,
    uint256 _staleEmissionsPerVP,
    uint256 _priorEmissionsPerVP
  ) external {
    // A not-newest message (`_refreshEmissionsPerVP == false`) that is the token's FIRST booking (no gauges, no
    // ZERO_GAUGE) STILL seeds `tokenSnapshot` from the message shape. The seed is decoupled from the
    // chain-global freshness flag: a token's first message can be non-fresh purely from cross-token
    // nonce reordering, and the park below must book at the token's real shape, not the default
    // permanent one. Regression against the over-booked-surplus bug where a skipped seed left a default
    // `(0,0)` = permanent shape and parked the whole budget as a permanent contribution.
    //
    // The message carries a DECAYING shape, so the park must land as decaying bias/slope, NOT
    // `permanentStakeBalance`. `_settleGauge(ZERO_GAUGE)` no-ops here (its cursor and `lastSettlement`
    // are both `_SEED_TIMESTAMP`), so the contribution resolves at `lastSettlement == _SEED_TIMESTAMP`.
    // Bound the delta at or above `MAXTIME` so the decaying slope is non-zero.
    _delta = uint128(bound(_delta, uint128(MAXTIME), _MAX_AMOUNT));
    // A non-zero prior scalar so a stray scalar update would be visible; it must stay untouched.
    _priorEmissionsPerVP = bound(_priorEmissionsPerVP, 1, 1e36);
    _mockChainAccumulator({_emissionsPerVP: _priorEmissionsPerVP, _index: 0});

    uint48 _settledAt = _leafVoter.lastSettlement();
    // A decaying message shape 52 weeks out.
    uint48 _messageStakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;
    IVoterCommon.TokenSnapshot memory _messageSnapshot =
      IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _messageStakeEnd, isPermanent: (_messageStakeEnd) == 0});

    // Independent hand-computation of the decaying contribution at `lastSettlement`.
    int128 _expectedSlope = int128(_delta / uint128(MAXTIME));
    int128 _expectedBias = _expectedSlope * int128(uint128(_messageStakeEnd - _settledAt));

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    // Chain-global stale (scalar not refreshed) but the token's first message, so shape-fresh: it seeds.
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _staleEmissionsPerVP, false, true, _messageSnapshot);

    // it should seed the token snapshot from the message shape even when not the newest
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, _messageSnapshot.staked);
    assertEq(_stakeEnd, _messageStakeEnd);

    // it should park the delta on the zero gauge at the seeded decaying shape: decaying bias/slope from
    // the message, and zero permanent balance (a default permanent shape would have booked `_delta` as
    // permanent).
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertEq(_bias, _expectedBias);
    assertEq(_slope, _expectedSlope);
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _messageStakeEnd), _expectedSlope);
    // it should track the parked allocation on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _delta);

    // it should not override the emissions scalar
    assertEq(_leafVoter.emissionsPerVP(), _priorEmissionsPerVP);
  }

  function test_WhenTheMessageIsNotTheNewestButWeightIsAlreadyBooked(
    uint128 _firstDelta,
    uint128 _secondDelta,
    uint256 _emissionsPerVP
  ) external {
    // Regression proving the pin still holds AFTER the first booking. A first not-newest message seeds a
    // prior DECAYING shape S1 and parks weight on ZERO_GAUGE. A second not-newest message carrying a
    // DIFFERENT shape S2 must NOT re-seed `tokenSnapshot` (the seed guard is now closed because
    // ZERO_GAUGE is booked), and its park must use the ORIGINAL stored S1. This proves the decoupled
    // seed did not break the pinning invariant.
    _firstDelta = uint128(bound(_firstDelta, uint128(MAXTIME), _MAX_AMOUNT / 2));
    _secondDelta = uint128(bound(_secondDelta, uint128(MAXTIME), _MAX_AMOUNT / 2));

    uint48 _settledAt = _leafVoter.lastSettlement();
    // S1: a decaying stake 52 weeks out, seeded by the first booking.
    uint48 _stakeEndOne = _nextWeekBoundary(_settledAt) + 52 * _WEEK;
    // S2: a DIFFERENT decaying stake, 26 weeks out. Must be ignored by the second call.
    uint48 _stakeEndTwo = _nextWeekBoundary(_settledAt) + 26 * _WEEK;

    vm.startPrank(_LEAF_MESSAGE_ORCHESTRATOR);
    // First message establishes the shape (per-token shape-fresh), even though it is chain-global stale.
    _leafVoter.applyChainAllocation(
      _TOKEN_ID,
      _firstDelta,
      _emissionsPerVP,
      false,
      true,
      IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _stakeEndOne, isPermanent: (_stakeEndOne) == 0})
    );
    // Second message is genuinely stale for the shape too, so it must not re-seed or roll it back.
    _leafVoter.applyChainAllocation(
      _TOKEN_ID,
      _secondDelta,
      _emissionsPerVP,
      false,
      false,
      IVoterCommon.TokenSnapshot({staked: 9e18, stakeEnd: _stakeEndTwo, isPermanent: (_stakeEndTwo) == 0})
    );
    vm.stopPrank();

    // it should keep the token snapshot pinned to the first shape
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, 5e18);
    assertEq(_stakeEnd, _stakeEndOne);

    // Independent hand-computation: both parks resolve against the pinned S1 stakeEnd at `lastSettlement`,
    // and each park swaps the sink to the new total, so the slope is the total's floor.
    int128 _totalSlope = int128(uint128((uint256(_firstDelta) + _secondDelta) / MAXTIME));

    // it should park the second delta using the pinned first shape not the second message shape: the park
    // books the total as decaying bias/slope against S1, S2's shape never reaches the slope schedule.
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertEq(_bias, _totalSlope * int128(uint128(_stakeEndOne - _settledAt)));
    assertEq(_slope, _totalSlope);
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _stakeEndOne), _totalSlope);
    // S2's stakeEnd never booked a slope change.
    assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _stakeEndTwo), 0);
    // it should accumulate both deltas on the zero gauge allocation
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), uint256(_firstDelta) + _secondDelta);
  }

  function test_WhenTwoNoWeightMessagesArriveOutOfOrder() external {
    // The bug: with no weight booked, a stale (shape-stale) message must not seed its own shape and roll
    // back the shape a newer message already established. Newer message (shape-fresh) sets a decaying
    // shape; a later, shape-stale message carrying a permanent shape must leave both snapshots at the
    // newer decaying shape. Both carry a zero delta so nothing books and the no-weight branch stays open.
    uint48 _freshEnd = _nextWeekBoundary(_leafVoter.lastSettlement()) + 52 * _WEEK;

    vm.startPrank(_LEAF_MESSAGE_ORCHESTRATOR);
    // Newer message: shape-fresh, seeds the decaying shape.
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: true,
      _refreshShape: true,
      _snapshot: IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _freshEnd, isPermanent: (_freshEnd) == 0})
    });
    // Reordered stale message: shape-stale, carries a permanent shape it must NOT seed.
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: false,
      _snapshot: IVoterCommon.TokenSnapshot({staked: 9e18, stakeEnd: 0, isPermanent: (0) == 0})
    });
    vm.stopPrank();

    // it should keep the shape at the newer message and not roll it back
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, 5e18);
    assertEq(_stakeEnd, _freshEnd);
    (uint128 _latestStaked, uint48 _latestStakeEnd,) = _leafVoter.latestTokenSnapshot(_TOKEN_ID);
    assertEq(_latestStaked, 5e18);
    assertEq(_latestStakeEnd, _freshEnd);
  }

  function test_WhenAStalePositiveDeltaArrivesAfterANewerShape(uint128 _delta) external {
    // Reorder with a POSITIVE delta: a newer message (shape-fresh) sets a decaying shape with no weight;
    // a later shape-stale message carrying a permanent shape AND a positive delta must NOT roll the shape
    // back, and its park must land at the newer decaying shape, not the permanent one it carries.
    _delta = uint128(bound(_delta, uint128(MAXTIME), _MAX_AMOUNT));
    uint48 _freshEnd = _nextWeekBoundary(_leafVoter.lastSettlement()) + 52 * _WEEK;

    vm.startPrank(_LEAF_MESSAGE_ORCHESTRATOR);
    // Newer, shape-fresh, zero delta: seeds the decaying shape, nothing parked yet.
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: 0,
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: true,
      _refreshShape: true,
      _snapshot: IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _freshEnd, isPermanent: (_freshEnd) == 0})
    });
    // Reordered, shape-stale, positive delta, carrying a permanent shape.
    _leafVoter.applyChainAllocation({
      _tokenId: _TOKEN_ID,
      _allocationDelta: _delta,
      _emissionsPerVP: 0,
      _refreshEmissionsPerVP: false,
      _refreshShape: false,
      _snapshot: IVoterCommon.TokenSnapshot({staked: 9e18, stakeEnd: 0, isPermanent: (0) == 0})
    });
    vm.stopPrank();

    // it should keep the shape at the newer message
    (, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_stakeEnd, _freshEnd);

    // it should park the stale delta at the newer (decaying) shape, not the permanent one it carried
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertGt(_bias, 0);
    assertGt(_slope, 0);
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_ZERO_GAUGE);
    assertEq(_point.permanentStakeBalance, 0);
  }

  function test_WhenTheDeltaIsZero(uint128 _priorBudget, uint256 _emissionsPerVP) external {
    // A refresh message (`_delta == 0`) carries no new budget: the `ZERO_GAUGE` park is gated on
    // `_delta > 0`, so nothing is parked and the budget is unchanged.
    _priorBudget = uint128(bound(_priorBudget, 0, _MAX_AMOUNT));
    _mockChainAllocation(_TOKEN_ID, _priorBudget);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, 0, _emissionsPerVP, true, true, _snap());

    // it should not park anything on the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    // it should record the unchanged budget
    assertEq(_chainAllocationOf(_TOKEN_ID), _priorBudget);
  }

  function test_WhenAPositionFreePokeArrives(uint256 _priorEmissionsPerVP, uint256 _pokedEmissionsPerVP) external {
    // Root lets any veNFT holder send a `delta == 0` message for a chain their token holds no budget on, purely
    // so this leaf re-reads the scalar. The refresh must land while the poking token stays absent from the leaf:
    // no budget, no gauge position, nothing parked on `ZERO_GAUGE`.
    _priorEmissionsPerVP = bound(_priorEmissionsPerVP, 1, type(uint128).max);
    _pokedEmissionsPerVP = bound(_pokedEmissionsPerVP, 1, type(uint128).max);
    vm.assume(_pokedEmissionsPerVP != _priorEmissionsPerVP);
    _mockChainAccumulator({_emissionsPerVP: _priorEmissionsPerVP, _index: 0});

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, 0, _pokedEmissionsPerVP, true, true, _snap());

    // it should re-read the chain emissions scalar from the poke
    assertEq(_leafVoter.emissionsPerVP(), _pokedEmissionsPerVP);
    // it should leave the poking token with no budget
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    // it should give the poking token no gauge position
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
    // it should park nothing on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
  }

  function test_WhenTheStoredShapeDiffersFromTheMessageShapeAndWeightExists(
    uint128 _delta,
    uint256 _emissionsPerVP
  ) external {
    // D4 invariant: the leaf refreshes lazily, the stored shape pins. Pre-seed a DECAYING stored
    // shape S1 and book gauge weight, then apply a chain allocation whose message snapshot is a
    // DIFFERENT permanent shape S2. The park must use S1 (stored), booking decaying bias/slope, not
    // S2's permanent balance. `_refreshEmissionsPerVP == true` but the pinned-shape guard (weight already
    // exists) keeps `tokenSnapshot` on S1.
    _delta = uint128(bound(_delta, uint128(MAXTIME), _MAX_AMOUNT));
    uint48 _settledAt = _leafVoter.lastSettlement();
    // S1: a decaying stake 52 weeks out.
    uint48 _storedStakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;
    _mockTokenSnapshot({_tokenId: _TOKEN_ID, _staked: 5e18, _stakeEnd: _storedStakeEnd});
    _mockVotedGauge(_TOKEN_ID, _GAUGE_A);

    // Independent hand-computation of the S1 contribution at `lastSettlement`.
    int128 _expectedSlope = int128(_delta / uint128(MAXTIME));
    int128 _expectedBias = _expectedSlope * int128(uint128(_storedStakeEnd - _settledAt));

    // Message carries S2, a permanent shape — must be ignored for the park.
    IVoterCommon.TokenSnapshot memory _messageSnapshot =
      IVoterCommon.TokenSnapshot({staked: 9e18, stakeEnd: 0, isPermanent: (0) == 0});

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _emissionsPerVP, true, true, _messageSnapshot);

    // it should park using the stored shape not the message shape: decaying bias/slope from S1, and
    // zero permanent balance (S2 would have booked `_delta` as permanent).
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertEq(_bias, _expectedBias);
    assertEq(_slope, _expectedSlope);
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _storedStakeEnd), _expectedSlope);
    // The stored shape stays pinned to S1.
    (, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_stakeEnd, _storedStakeEnd);
  }

  function test_WhenMultipleDeltasAreApplied(uint128 _delta1, uint128 _delta2, uint256 _emissionsPerVP) external {
    // Two successive chain allocations accumulate on `ZERO_GAUGE` at the single stored (permanent)
    // shape seeded by the first call. The second call finds weight already parked, so the seed guard
    // keeps the shape pinned and the second delta stacks as permanent balance.
    _delta1 = uint128(bound(_delta1, 1, _MAX_AMOUNT));
    _delta2 = uint128(bound(_delta2, 1, _MAX_AMOUNT));

    vm.startPrank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta1, _emissionsPerVP, true, true, _snap());
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta2, _emissionsPerVP, true, true, _snap());
    vm.stopPrank();

    // it should accumulate the parked allocation on the zero gauge
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), uint256(_delta1) + _delta2);
    assertEq(_gaugeWeight(_ZERO_GAUGE), uint256(_delta1) + _delta2);
    // it should keep the stored shape pinned across the calls (still the first seeded permanent shape)
    (uint128 _staked, uint48 _stakeEnd,) = _leafVoter.tokenSnapshot(_TOKEN_ID);
    assertEq(_staked, _snap().staked);
    assertEq(_stakeEnd, _snap().stakeEnd);
  }

  function test_WhenAChainAllocationIsApplied(uint128 _priorBudget, uint128 _delta, uint256 _emissionsPerVP) external {
    _priorBudget = uint128(bound(_priorBudget, 0, _MAX_AMOUNT));
    _delta = uint128(bound(_delta, 0, _MAX_AMOUNT));
    _mockChainAllocation(_TOKEN_ID, _priorBudget);

    // it should emit the ChainAllocated event with the delta and resulting budget
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.ChainAllocated(_TOKEN_ID, _delta, _priorBudget + _delta, _emissionsPerVP);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _emissionsPerVP, true, true, _snap());
  }

  function test_WhenTheStoredShapeIsWithdrawn(uint128 _delta, uint256 _emissionsPerVP) external {
    // Phantom-weight hardening. A withdrawn stake reads as `{staked: 0, stakeEnd: 0, isPermanent: false}`. A
    // stale delta parked against it must NOT be booked as permanent weight (the root cause of the finding): the
    // `isPermanent` flag is false, so the park resolves to the zero triple. The nominal budget still tracks the
    // delta; a later real shape reconciles the position.
    _delta = uint128(bound(_delta, 1, _MAX_AMOUNT));
    _mockTokenSnapshot(_TOKEN_ID, 0, 0, false);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyChainAllocation(_TOKEN_ID, _delta, _emissionsPerVP, false, false, _snap());

    // it should add the delta to the budget
    assertEq(_chainAllocationOf(_TOKEN_ID), _delta);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _delta);
    // it should book no phantom weight on the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertEq(_bias, 0);
    assertEq(_slope, 0);
  }
}
