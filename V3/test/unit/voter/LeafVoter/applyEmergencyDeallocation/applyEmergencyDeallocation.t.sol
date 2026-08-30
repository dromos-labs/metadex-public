// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

contract UnitLeafVoterApplyEmergencyDeallocation is BaseLeafVoter {
  /// @notice Permanent-stake snapshot. Its contribution is the allocation itself.
  function _permanentSnapshot(uint128 _staked) internal pure returns (IVoterCommon.TokenSnapshot memory _snapshot) {
    _snapshot = IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: 0, isPermanent: (0) == 0});
  }

  /// @notice Read the decaying `(bias, slope)` booked on `_gauge`'s point.
  function _gaugeBiasSlope(address _gauge) internal view returns (int128 _bias, int128 _slope) {
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_gauge);
    _bias = _point.bias;
    _slope = _point.slope;
  }

  /**
   * @notice Book a prior gauge allocation as the orchestrator so the token holds a live position.
   * @dev Setup only. Mirrors `applyGaugeAllocations`'s `_arrangePriorVote` — the token is fresh
   *      (`lastAllocated == 0`) so its cooldown is already elapsed. Seeds `chainAllocation` to the
   *      allocated sum via the shared helper.
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

  /*////////////////////////////////////////////////////////////
                          ACCESS CONTROL
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheCallerIsNotTheMessageOrchestrator(address _caller, uint128 _amount) external {
    _caller = _boundNotEq(_caller, _LEAF_MESSAGE_ORCHESTRATOR);

    // it should revert with NotMessageOrchestrator
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(ILeafVoter.NotMessageOrchestrator.selector));
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _amount);
  }

  /*////////////////////////////////////////////////////////////
                          FULL DRAIN
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheAmountIsAtLeastTheChainBudget(uint128 _amountA, uint128 _amountB, uint128 _drain) external {
    // The token voted two routable gauges at its full permanent budget. A drain of at least the whole
    // budget (`_amount >= budget`) reduces to the prior full unwind: `remaining == 0`, every gauge's
    // booked weight drops to zero, its stored allocation clears, it leaves the voted set, nothing is
    // parked on ZERO_GAUGE, and the chain budget is zeroed to match root's drain to CHAIN0.
    _amountA = uint128(bound(_amountA, 1, _MAX_AMOUNT));
    _amountB = uint128(bound(_amountB, 1, _MAX_AMOUNT));
    uint128 _budget = _amountA + _amountB;
    // Drain at or above the whole budget so `remaining == 0`, spanning the full `[budget, max]` range.
    _drain = uint128(bound(_drain, _budget, type(uint128).max));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockRegisterGauge(_GAUGE_B, true);

    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _GAUGE_A;
    _gauges[1] = _GAUGE_B;
    _amounts[0] = _amountA;
    _amounts[1] = _amountB;
    _arrangePriorVote(_permanentSnapshot(_budget), _list(_gauges, _amounts));

    // Sanity: the prior vote booked both gauges before the unwind.
    assertEq(_gaugeWeight(_GAUGE_A), _amountA);
    assertEq(_gaugeWeight(_GAUGE_B), _amountB);

    // it should emit EmergencyDeallocationApplied
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmergencyDeallocationApplied(_TOKEN_ID);

    // It should NOT dispatch a leaf->root return (no DEALLOC_GAUGE sentinel in the empty-list unwind).
    vm.expectCall(_LEAF_MESSAGE_ORCHESTRATOR, abi.encodeWithSignature('dispatch(uint8,bytes,uint256,address,bool)'), 0);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _drain);

    // it should unwind every voted gauge
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    assertEq(_gaugeWeight(_GAUGE_B), 0);
    // it should clear the stored gauge allocations
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_B), 0);
    // it should empty the voted gauge set
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
    // it should park nothing on the zero gauge
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    // it should zero the chain allocation budget
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
  }

  /*////////////////////////////////////////////////////////////
                        PARTIAL DRAIN
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheAmountIsBelowTheChainBudgetAndTheSnapshotIsPermanent(
    uint128 _gaugeAmount,
    uint128 _shortfall,
    uint128 _drain
  ) external {
    // The token voted one routable gauge for less than its permanent chain budget, so the unallocated
    // remainder already parked on ZERO_GAUGE. A partial emergency drain (`_amount < budget`) SUBTRACTS
    // `_amount` instead of zeroing: every real gauge clears, and the surviving `remaining = budget -
    // amount` is re-parked on ZERO_GAUGE, with `chainAllocation` set to that remainder (not zeroed).
    _gaugeAmount = uint128(bound(_gaugeAmount, 1, _MAX_AMOUNT));
    _shortfall = uint128(bound(_shortfall, 1, _MAX_AMOUNT));
    uint128 _budget = _gaugeAmount + _shortfall;
    // Drain strictly below the budget so this is the partial path, across `[1, budget - 1]`.
    _drain = uint128(bound(_drain, 1, _budget - 1));
    uint128 _remaining = _budget - _drain;
    _mockRegisterGauge(_GAUGE_A, true);

    // The prior vote parks `_shortfall` on ZERO_GAUGE through an explicit ZERO_GAUGE (address(0)) entry
    // — the exact-match model has no automatic backfill — so the emergency partial drain has a live
    // ZERO_GAUGE park to re-park onto. address(0) sorts first, keeping the list strictly ascending.
    address[] memory _gauges = new address[](2);
    uint128[] memory _amounts = new uint128[](2);
    _gauges[0] = _ZERO_GAUGE;
    _gauges[1] = _GAUGE_A;
    _amounts[0] = _shortfall;
    _amounts[1] = _gaugeAmount;

    // The list allocates the whole budget exactly (`_gaugeAmount + _shortfall == _budget`).
    _mockChainAllocation(_TOKEN_ID, _budget);
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyGaugeAllocations(
      _TOKEN_ID, uint48(block.timestamp), 0, false, true, _permanentSnapshot(_budget), _list(_gauges, _amounts)
    );

    // Sanity: the gauge booked its amount and the shortfall parked on ZERO_GAUGE.
    assertEq(_gaugeWeight(_GAUGE_A), _gaugeAmount);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _shortfall);

    // it should emit EmergencyDeallocationApplied
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmergencyDeallocationApplied(_TOKEN_ID);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _drain);

    // it should unwind every voted gauge
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    // it should clear the stored gauge allocations
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should empty the voted gauge set
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
    // it should repark the surviving remainder on the zero gauge
    // Independent hand-computation: for a permanent snapshot the ZERO_GAUGE contribution is the parked
    // amount itself (`permanentStakeBalance == remaining`), and only ZERO_GAUGE carries it.
    assertEq(_gaugeWeight(_ZERO_GAUGE), _remaining);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _remaining);
    // it should set the chain allocation budget to the remainder
    assertEq(_chainAllocationOf(_TOKEN_ID), _remaining);
  }

  function test_WhenTheAmountIsBelowTheChainBudgetAndTheSnapshotIsDecaying(
    uint128 _remaining,
    uint128 _drain
  ) external {
    // Same partial-drain path against a DECAYING stake shape: the surviving remainder must re-park on
    // ZERO_GAUGE as decaying bias/slope (not a permanent balance), hand-computed from the stored shape.
    // Floor the surviving remainder at `MAXTIME` so its decaying slope is non-zero (non-dust).
    _remaining = uint128(bound(_remaining, uint128(MAXTIME), _MAX_AMOUNT));
    _drain = uint128(bound(_drain, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);

    uint48 _settledAt = _leafVoter.lastSettlement();
    // A decaying shape 52 weeks out.
    uint48 _stakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;

    // Independent hand-computation of the surviving remainder's decaying contribution at `lastSettlement`
    // (no warp, so the emergency's `_settleGauge(ZERO_GAUGE)` no-ops and the contribution resolves at
    // `_SEED_TIMESTAMP`): slope = remaining / MAXTIME, bias = slope * (stakeEnd - lastSettlement).
    int128 _expectedSlope = int128(_remaining / uint128(MAXTIME));
    int128 _expectedBias = _expectedSlope * int128(uint128(_stakeEnd - _settledAt));

    // Arrange: allocate the whole budget to the gauge (no prior ZERO_GAUGE park). `_arrangePriorVote`
    // seeds `chainAllocation = budget`. Scoped so the setup locals free their stack slots.
    {
      uint128 _budget = _remaining + _drain;
      address[] memory _gauges = new address[](1);
      uint128[] memory _amounts = new uint128[](1);
      _gauges[0] = _GAUGE_A;
      _amounts[0] = _budget;
      _arrangePriorVote(
        IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0}),
        _list(_gauges, _amounts)
      );

      // Sanity: the gauge booked the decaying weight and nothing parked on ZERO_GAUGE yet.
      (, int128 _priorGaugeSlope) = _gaugeBiasSlope(_GAUGE_A);
      assertEq(_priorGaugeSlope, int128(_budget / uint128(MAXTIME)));
      assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), 0);
    }

    // it should emit EmergencyDeallocationApplied
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmergencyDeallocationApplied(_TOKEN_ID);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _drain);

    // it should unwind every voted gauge
    {
      (int128 _clearedBias, int128 _clearedSlope) = _gaugeBiasSlope(_GAUGE_A);
      assertEq(_clearedBias, 0);
      assertEq(_clearedSlope, 0);
    }
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);

    // it should repark the surviving remainder as decaying weight on the zero gauge
    {
      (int128 _zeroBias, int128 _zeroSlope) = _gaugeBiasSlope(_ZERO_GAUGE);
      assertEq(_zeroBias, _expectedBias);
      assertEq(_zeroSlope, _expectedSlope);
    }
    // No permanent balance: the remainder booked purely as decaying weight.
    assertEq(_gaugeWeight(_ZERO_GAUGE), 0);
    assertEq(_leafVoter.gaugeSlopeChanges(_ZERO_GAUGE, _stakeEnd), _expectedSlope);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _remaining);

    // it should set the chain allocation budget to the remainder
    assertEq(_chainAllocationOf(_TOKEN_ID), _remaining);
  }

  /*////////////////////////////////////////////////////////////
                        EXPIRED SNAPSHOT
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheTokenSnapshotHasExpired(uint128 _amount, uint128 _drain) external {
    // The token holds a live position, but its stake snapshot expires before the emergency lands. With
    // `_context.expired` set, the unwind still fully clears the position without reverting. A full drain
    // (`_amount >= budget`) leaves `remaining == 0` so the budget zeroes. Non-permanent snapshot so
    // `stakeEnd != 0` and can be warped past. Floor the amount well above `MAXTIME` wei so the decaying
    // contribution (slope = amount / MAXTIME) is non-dust and the prior vote actually books weight.
    _amount = uint128(bound(_amount, 1e18, _MAX_AMOUNT));
    // Drain the whole budget (`budget == _amount`) so `remaining == 0`.
    _drain = uint128(bound(_drain, _amount, type(uint128).max));
    _mockRegisterGauge(_GAUGE_A, true);
    // Warping past a weekly boundary makes the emergency unwind's `_settleGauge` walk, which queries the
    // factory's per-gauge cap. Leave it effectively uncapped.
    _mockEmissionCap(_GAUGE_A, type(uint128).max);

    address[] memory _gauges = new address[](1);
    uint128[] memory _amounts = new uint128[](1);
    _gauges[0] = _GAUGE_A;
    _amounts[0] = _amount;

    // Non-permanent snapshot expiring one week out, then warp past it so `stakeEnd <= lastSettlement`.
    uint48 _stakeEnd = uint48(block.timestamp) + _WEEK;
    IVoterCommon.TokenSnapshot memory _snapshot =
      IVoterCommon.TokenSnapshot({staked: _amount, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0});
    _arrangePriorVote(_snapshot, _list(_gauges, _amounts));

    // Sanity: the prior vote booked the gauge before the snapshot expired.
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _amount);

    // Warp past the snapshot expiry so the emergency path sees `_context.expired`.
    vm.warp(_stakeEnd + 1);

    // it should emit EmergencyDeallocationApplied
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmergencyDeallocationApplied(_TOKEN_ID);

    // it should not revert
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _drain);

    // it should fully unwind the voted gauge
    assertEq(_gaugeWeight(_GAUGE_A), 0);
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), 0);
    // it should empty the voted gauge set
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
    // it should zero the chain allocation budget
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
  }

  /*////////////////////////////////////////////////////////////
                        IDEMPOTENT NO-OP
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheTokenHasNoPosition(uint128 _amount) external {
    // A token with nothing booked (already unwound, or never allocated) unwinds an empty gauge set: the
    // emergency deallocation is a no-op that still leaves the budget at zero and emits, so a redelivered
    // message is safe. With a zero budget any `_amount` clamps `remaining` to zero.

    // it should emit EmergencyDeallocationApplied
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.EmergencyDeallocationApplied(_TOKEN_ID);

    // it should not revert
    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _amount);

    // it should leave the chain allocation at zero
    assertEq(_chainAllocationOf(_TOKEN_ID), 0);
    assertEq(_leafVoter.allocatedGauges(_TOKEN_ID).length, 0);
  }

  function test_WhenTheSnapshotHasExpiredAndTheDrainIsPartial(uint128 _remaining, uint128 _drain) external {
    // The stored snapshot expires while `latestTokenSnapshot` stays live, which is the state a reshape leaves
    // behind until the next gauge vote lands. A partial drain must still park the survivor, or `chainAllocation`
    // outruns the weight backing it. Floor the remainder at `MAXTIME` so its slope is non-dust.
    _remaining = uint128(bound(_remaining, uint128(MAXTIME), _MAX_AMOUNT));
    _drain = uint128(bound(_drain, 1, _MAX_AMOUNT));
    _mockRegisterGauge(_GAUGE_A, true);
    _mockEmissionCap(_GAUGE_A, type(uint128).max);

    uint48 _staleEnd = _nextWeekBoundary(uint48(block.timestamp));
    {
      uint128 _budget = _remaining + _drain;
      address[] memory _gauges = new address[](1);
      uint128[] memory _amounts = new uint128[](1);
      _gauges[0] = _GAUGE_A;
      _amounts[0] = _budget;
      _arrangePriorVote(
        IVoterCommon.TokenSnapshot({staked: 5e18, stakeEnd: _staleEnd, isPermanent: (_staleEnd) == 0}),
        _list(_gauges, _amounts)
      );
    }

    // Warp past the stored shape, then re-anchor only the latest: stored expired, latest live.
    vm.warp(_staleEnd + 1);
    uint48 _liveEnd = _nextWeekBoundary(uint48(block.timestamp)) + 52 * _WEEK;
    _mockLatestTokenSnapshot(_TOKEN_ID, 5e18, _liveEnd);

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.applyEmergencyDeallocation(_TOKEN_ID, _drain);

    // it should set the chain allocation budget to the remainder
    assertEq(_chainAllocationOf(_TOKEN_ID), _remaining);

    // it should repark the remainder against the latest live snapshot
    assertEq(_leafVoter.allocations(_TOKEN_ID, _ZERO_GAUGE), _remaining);
    int128 _expectedSlope = int128(_remaining / uint128(MAXTIME));
    (int128 _bias, int128 _slope) = _gaugeBiasSlope(_ZERO_GAUGE);
    assertEq(_slope, _expectedSlope);
    assertEq(_bias, _expectedSlope * int128(uint128(_liveEnd - _leafVoter.lastSettlement())));
  }
}
