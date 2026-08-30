// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {BaseVoter, IMinter, IRootMessageOrchestrator, IVoter, IVotingEscrow} from 'V3-test/unit/voter/BaseVoter.sol';

/**
 * @title Ceiling conservation invariant suite
 * @notice Proves the global-index accrual model conserves emissions across chains and fixes the
 *         stale-per-chain-rate bug of the old model. Under the index model every chain accrues
 *         `chainWeight * (index - lastIndex) / PRECISION`, and the global `index` integrates the
 *         sampled `emissionsPerVP` over time. Because `Σ chainWeight == totalWeight`, the sum of all
 *         chain ceilings equals the weighted global-index growth — no emission is created or lost when
 *         chains are settled at different times, and an untouched chain picks up every intervening
 *         `emissionsPerVP` change through the shared index.
 */
contract UnitVoterCeilingConservation is BaseVoter {
  /**
   * @notice Seed a permanent-weight chain: a point carrying `_weight` as permanent balance, anchored at
   *         `_t0`, with its ceiling cursor at the current global index. Status is already `Active` from
   *         `setUp`'s registration.
   */
  function _seedPermanentChain(uint256 _chainId, uint128 _weight, uint48 _t0) internal {
    _mockChainPoint({_chainId: _chainId, _bias: 0, _slope: 0, _ts: _t0, _perm: _weight});
    _mockChainLastIndex(_chainId, _voter.index());
  }

  /// @notice Settle a chain to `now` with no economic side effect (a zero-amount orchestrator redeem).
  /// @dev Settles `_CHAIN_ID_1` from a week-aligned `_from` across `_weeksCrossed` boundaries, returning the gas.
  function _measureSettleGas(uint48 _from, uint48 _weeksCrossed) internal returns (uint256 _gas) {
    _seedPermanentChain(_CHAIN_ID_1, _ONE_AERO, _from);
    _mockLastGlobalSettlement(_from);
    vm.warp(_from + uint256(_weeksCrossed) * _WEEK);

    uint256 _before = gasleft();
    _settleViaRedeem(_CHAIN_ID_1);
    _gas = _before - gasleft();
  }

  function _settleViaRedeem(uint256 _chainId) internal {
    vm.prank(_ORCHESTRATOR);
    _voter.processRedeem(_chainId, 0, _REFUND_RECIPIENT, 0);
  }

  /**
   * @notice A global scalar schedule with a single resample: `e0` governs `[t0, t1]`, `e1` governs `[t1, ...)`.
   * @dev Both conservation scenarios park VP once, at `t1`, and that is the only scalar change.
   */
  struct IndexSchedule {
    uint48 t0;
    uint48 t1;
    uint256 e0;
    uint256 e1;
  }

  /// @notice Value the global accumulator has reached at `_t` under `_schedule`.
  function _indexAt(IndexSchedule memory _schedule, uint48 _t) internal pure returns (uint256 _index) {
    _index = _t <= _schedule.t1
      ? _schedule.e0 * (_t - _schedule.t0)
      : _schedule.e0 * (_schedule.t1 - _schedule.t0) + _schedule.e1 * (_t - _schedule.t1);
  }

  /**
   * @notice Ghost accrual for a chain of constant weight settled across `[_from, _to]`.
   * @dev Root credits one segment per week boundary so it partitions time exactly like the leaf's gauge walk,
   *      and each segment divides the `PRECISION` scale back out on its own. Summing the pieces is not the
   *      same as dividing once over the whole window, so the ghost has to cut at the same boundaries or it
   *      drifts by a wei per boundary. A constant weight makes the segment average a no-op (start == end),
   *      which is why no averaging appears here.
   * @param _weight Constant chain weight over the window.
   * @param _from Start of the window (the chain's last settlement).
   * @param _to End of the window.
   * @param _schedule Scalar schedule driving the accumulator.
   * @return _accrual Emissions the chain earns over the window.
   */
  function _ghostAccrual(
    uint128 _weight,
    uint48 _from,
    uint48 _to,
    IndexSchedule memory _schedule
  ) internal pure returns (uint256 _accrual) {
    uint256 _cursor = _indexAt(_schedule, _from);
    uint48 _boundary = (_from / _WEEK + 1) * _WEEK;
    while (_boundary <= _to) {
      uint256 _boundaryIndex = _indexAt(_schedule, _boundary);
      _accrual += Math.mulDiv(_weight, _boundaryIndex - _cursor, _PRECISION);
      _cursor = _boundaryIndex;
      _boundary += _WEEK;
    }
    _accrual += Math.mulDiv(_weight, _indexAt(_schedule, _to) - _cursor, _PRECISION);
  }

  function test_WhenSettlingEveryChainToNowAcrossASequenceOfTouches(
    uint128 _weightA,
    uint128 _weightB,
    uint128 _weightC,
    uint128 _park,
    uint48 _dt1,
    uint48 _dt2
  ) external {
    // Permanent weights so no decay enters the accrual; the conservation is exact.
    _weightA = uint128(bound(_weightA, _ONE_AERO, 1e27));
    _weightB = uint128(bound(_weightB, _ONE_AERO, 1e27));
    _weightC = uint128(bound(_weightC, _ONE_AERO, 1e27));
    _park = uint128(bound(_park, _ONE_AERO, 1e27));
    _dt1 = uint48(bound(_dt1, 1, 30 days));
    _dt2 = uint48(bound(_dt2, 1, 30 days));

    uint48 _t0 = _INITIAL_TIMESTAMP; // setUp already warped here and anchored the global cursor
    uint256 _total0 = uint256(_weightA) + _weightB + _weightC;
    // Scalars in effect over each interval: e0 over [t0, t1], e1 over [t1, t2] (after the park grows total).
    IndexSchedule memory _schedule = IndexSchedule({
      t0: _t0,
      t1: _t0 + _dt1,
      e0: Math.mulDiv(_MINTER_RATE, _PRECISION, _total0),
      e1: Math.mulDiv(_MINTER_RATE, _PRECISION, _total0 + _park)
    });
    uint48 _t2 = _schedule.t1 + _dt2;

    // Seed A/B/C with permanent weight and CHAIN0 empty; totalPoint carries only A+B+C.
    _seedPermanentChain(_CHAIN_ID_1, _weightA, _t0);
    _seedPermanentChain(_CHAIN_ID_2, _weightB, _t0);
    _seedPermanentChain(_CHAIN_ID_3, _weightC, _t0);
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _t0, _perm: 0});
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _t0, _perm: uint128(_total0)});
    _mockLastGlobalSettlement(_t0);
    _mockEmissionsPerVP(_schedule.e0);

    // t1: a VE-initiated rebalance parks `_park` permanent VP on CHAIN0. This settles CHAIN0 (still zero
    // weight, so zero accrual) and resamples the global scalar to e1; A/B/C are NOT touched.
    vm.warp(_schedule.t1);
    _mockStakedFor(_TOKEN_ID_2, _park, 0, true);
    {
      IVotingEscrow.DestinationDelta[] memory _dests = new IVotingEscrow.DestinationDelta[](1);
      _dests[0] = IVotingEscrow.DestinationDelta({tokenId: _TOKEN_ID_2, amount: _park, recipient: address(0)});
      vm.prank(_VOTING_ESCROW);
      _voter.rebalanceChain0(new IVotingEscrow.SourceDelta[](0), _dests);
    }

    // t2: settle CHAIN0 (a no-op zero-amount source rebalance, which also advances the global index over
    // [t1, t2] at the resampled e1) then A/B/C via zero-amount redeems.
    vm.warp(_t2);
    {
      IVotingEscrow.SourceDelta[] memory _zeroSource = new IVotingEscrow.SourceDelta[](1);
      _zeroSource[0] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID_2, amount: 0});
      vm.prank(_VOTING_ESCROW);
      _voter.rebalanceChain0(_zeroSource, new IVotingEscrow.DestinationDelta[](0));
    }

    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));
    _settleViaRedeem(_CHAIN_ID_1);
    _settleViaRedeem(_CHAIN_ID_2);
    _settleViaRedeem(_CHAIN_ID_3);

    // Ghost accumulators: each chain accrues its weight times the index growth over the window it was
    // settled across, cut at every week boundary in that window. A/B/C span the whole window from `_t0`;
    // CHAIN0 was already settled at `_t1` (at zero weight), so it only carries `[t1, t2]` at `_park`.
    uint256 _ghostA = _ghostAccrual(_weightA, _t0, _t2, _schedule);
    uint256 _ghostB = _ghostAccrual(_weightB, _t0, _t2, _schedule);
    uint256 _ghostC = _ghostAccrual(_weightC, _t0, _t2, _schedule);
    uint256 _ghost0 = _ghostAccrual(_park, _schedule.t1, _t2, _schedule);

    // it should advance the global index to the integral of emissions per VP over time
    assertEq(_voter.index(), _schedule.e0 * uint256(_dt1) + _schedule.e1 * uint256(_dt2));

    // it should accrue each chain ceiling by its weight times the shared index delta
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _ghostA);
    assertEq(_chainState(_voter, _CHAIN_ID_2).ceiling, _ghostB);
    assertEq(_chainState(_voter, _CHAIN_ID_3).ceiling, _ghostC);
    assertEq(_chainState(_voter, _CHAIN0).ceiling, _ghost0);

    // it should conserve total emissions across every chain ceiling
    // Σ ceilings == Σ (chainWeight_c * emissionsPerVP * dt / PRECISION) over the two intervals, tracked by
    // the ghost accumulators. No emission is created or lost across the staggered settlements.
    uint256 _observed = _chainState(_voter, _CHAIN_ID_1).ceiling + _chainState(_voter, _CHAIN_ID_2).ceiling
      + _chainState(_voter, _CHAIN_ID_3).ceiling + _chainState(_voter, _CHAIN0).ceiling;
    assertEq(_observed, _ghostA + _ghostB + _ghostC + _ghost0);
  }

  function test_WhenADecayingChainIsPokedDailyForAWeek() external givenCallerIsAuthorized {
    // Root and the leaf must credit the same week the same way. The leaf walks week segments, so a gauge that
    // settles once a week credits `weight_at_week_start * weekly index delta`. A daily poke resolves the chain
    // point every day, so root credits seven finer segments at decayed weights and ends up BELOW that. The leaf's
    // cumulative share then outruns root's ceiling and the last redeem reverts `CeilingExceeded` with the receipt
    // already burned. Both sides must partition by week.
    uint48 _t0 = uint48((_INITIAL_TIMESTAMP / 1 weeks) * 1 weeks) + 2 weeks; // start on a boundary
    uint48 _stakeEnd = _t0 + 52 weeks; // decaying: with a permanent stake the partition cannot matter
    uint128 _booked = 1000 * _ONE_AERO;
    int128 _slope = _slopeOf(_booked);

    vm.warp(_t0);
    // The pokes dispatch; this suite otherwise never reaches the orchestrator.
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
    _mockStaked({_amount: _booked, _end: _stakeEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _booked, _lastStakeEnd: _stakeEnd, _lastAllocated: _t0});
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _booked);
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN_ID_1)});
    _mockChainPoint({
      _chainId: _CHAIN_ID_1, _bias: _slope * int128(uint128(_stakeEnd - _t0)), _slope: _slope, _ts: _t0, _perm: 0
    });
    // Permanent total weight so the resampled scalar stays constant and the only moving part is the chain's
    // own decay, which is what the partition has to handle.
    uint128 _totalWeight = 10_000 * _ONE_AERO;
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _t0, _perm: _totalWeight});
    _mockChainSlopeChange({_chainId: _CHAIN_ID_1, _expiry: _stakeEnd, _value: _slope});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockLastGlobalSettlement(_t0);
    uint256 _scalar = Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight);
    _mockEmissionsPerVP(_scalar); // in effect from `_t0`, so the first day accrues like the rest

    // What the leaf credits for this same week in ONE segment: the average of its start and end weight. Root must
    // land on the same number after seven daily settles, or the leaf hands out more than root can back.
    uint256 _weekStart = uint128(_slope * int128(uint128(_stakeEnd - _t0)));
    uint256 _weekEnd = uint128(_slope * int128(uint128(_stakeEnd - _t0 - 1 weeks)));
    uint256 _weeklyCredit = Math.mulDiv((_weekStart + _weekEnd) / 2, _scalar * 1 weeks, _PRECISION);

    // A delta-zero poke each day; every one runs `_settleChain`, so the point moves forward daily.
    IVoter.ChainAllocationDispatch[] memory _poke =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 0, _gasLimit: _GAS_LIMIT});
    for (uint256 _i = 1; _i <= 7; ++_i) {
      vm.warp(_t0 + uint48(_i) * 1 days);
      vm.prank(_CALLER);
      _voter.allocateChains(_TOKEN_ID, _poke, _REFUND_RECIPIENT);
    }

    // it should credit the week the same as one weekly segment however often the chain is touched
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _weeklyCredit);
  }

  function test_WhenTheGlobalSettleCrossesWeekBoundaries(
    uint256 _scalar,
    uint48 _offset,
    uint48 _weeksCrossed,
    uint48 _tail
  ) external {
    // The boundary marks are what let a chain cut its accrual into the same weekly segments the leaf's gauge
    // walk uses. Start off-boundary and stop off-boundary so both the leading and the trailing partial
    // segment are exercised.
    _scalar = bound(_scalar, 1, 1e18);
    _offset = uint48(bound(_offset, 0, _WEEK - 1));
    _weeksCrossed = uint48(bound(_weeksCrossed, 1, 8));
    _tail = uint48(bound(_tail, 0, _WEEK - 1));

    uint48 _t0 = _INITIAL_TIMESTAMP + _offset;
    uint48 _firstBoundary = (_t0 / _WEEK + 1) * _WEEK;
    uint48 _lastBoundary = _firstBoundary + (_weeksCrossed - 1) * _WEEK;
    uint48 _now = _lastBoundary + _tail;

    _seedPermanentChain(_CHAIN_ID_1, _ONE_AERO, _t0);
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _t0, _perm: _ONE_AERO});
    _mockLastGlobalSettlement(_t0);
    _mockEmissionsPerVP(_scalar);

    vm.warp(_now);
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));
    _settleViaRedeem(_CHAIN_ID_1);

    // it should record the accumulator at every boundary crossed
    // The scalar is constant over the whole window, so the mark at a boundary is the integral up to it.
    for (uint48 _i; _i < _weeksCrossed; ++_i) {
      uint48 _boundary = _firstBoundary + _i * _WEEK;
      assertEq(_voter.indexAtBoundary(_boundary), _scalar * (_boundary - _t0));
    }

    // it should record the time weighted accumulator at every boundary crossed
    // `timeIndex` sums the same scalar weighted by absolute unix time, doubled (∫2t·dt = t^2), so the mark at a
    // boundary is `scalar * (boundary^2 - t0^2)`. It is strictly larger than the `index` mark at that same
    // boundary (the extra factor is `boundary + t0`, a unix timestamp sum), which pins the getter to its own
    // mapping rather than the neighbouring `indexAtBoundary`.
    for (uint48 _i; _i < _weeksCrossed; ++_i) {
      uint48 _boundary = _firstBoundary + _i * _WEEK;
      uint256 _timeMark = _scalar * (uint256(_boundary) * _boundary - uint256(_t0) * _t0);
      assertEq(_voter.timeIndexAtBoundary(_boundary), _timeMark);
      assertGt(_timeMark, _voter.indexAtBoundary(_boundary));
    }

    // it should leave the next boundary unrecorded
    assertEq(_voter.indexAtBoundary(_lastBoundary + _WEEK), 0);
    assertEq(_voter.timeIndexAtBoundary(_lastBoundary + _WEEK), 0);

    // it should advance the index to the whole elapsed integral
    // Banking the marks must not change the total: the partial head and tail are carried at the same scalar.
    assertEq(_voter.index(), _scalar * (_now - _t0));

    // it should advance the time weighted accumulator to the whole elapsed integral
    assertEq(_voter.timeIndex(), _scalar * (uint256(_now) * _now - uint256(_t0) * _t0));
  }

  function test_WhenAnUntouchedChainSettlesAfterATotalWeightChange(
    uint128 _weightA,
    uint128 _weightB,
    uint128 _weightC,
    uint128 _park,
    uint48 _dt1,
    uint48 _dt2
  ) external {
    // Smaller weight bounds so `_park` can be forced strictly larger than the starting total, guaranteeing
    // the resampled scalar drops (e1 < e0) and the staleness gap is observable.
    _weightA = uint128(bound(_weightA, _ONE_AERO, 1e24));
    _weightB = uint128(bound(_weightB, _ONE_AERO, 1e24));
    _weightC = uint128(bound(_weightC, _ONE_AERO, 1e24));
    _dt1 = uint48(bound(_dt1, 1, 30 days));
    _dt2 = uint48(bound(_dt2, 1, 30 days));

    uint48 _t0 = _INITIAL_TIMESTAMP;
    uint256 _total0 = uint256(_weightA) + _weightB + _weightC;
    // Park at least the starting total so total at least doubles: e1 <= e0 / 2 < e0.
    _park = uint128(bound(_park, _total0, uint256(3) * _total0));

    uint256 _e0 = Math.mulDiv(_MINTER_RATE, _PRECISION, _total0);
    uint256 _e1 = Math.mulDiv(_MINTER_RATE, _PRECISION, _total0 + _park);

    _seedPermanentChain(_CHAIN_ID_1, _weightA, _t0);
    _seedPermanentChain(_CHAIN_ID_2, _weightB, _t0); // B: the untouched observer
    _seedPermanentChain(_CHAIN_ID_3, _weightC, _t0);
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _t0, _perm: 0});
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _t0, _perm: uint128(_total0)});
    _mockLastGlobalSettlement(_t0);
    _mockEmissionsPerVP(_e0);

    uint48 _t1 = _t0 + _dt1;
    uint48 _t2 = _t1 + _dt2;
    IndexSchedule memory _schedule = IndexSchedule({t0: _t0, t1: _t1, e0: _e0, e1: _e1});

    // t1: park grows total weight and resamples the scalar to e1. B is not touched — its ceiling cursor
    // stays anchored at index 0 while the global scalar changes.
    vm.warp(_t1);
    _mockStakedFor(_TOKEN_ID_2, _park, 0, true);
    IVotingEscrow.DestinationDelta[] memory _dests = new IVotingEscrow.DestinationDelta[](1);
    _dests[0] = IVotingEscrow.DestinationDelta({tokenId: _TOKEN_ID_2, amount: _park, recipient: address(0)});
    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(new IVotingEscrow.SourceDelta[](0), _dests);

    // t2: settle B for the first time. Its single settle advances the global index over [t1, t2] at the
    // resampled e1, then accrues over the full [t0, t2] delta.
    vm.warp(_t2);
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));
    _settleViaRedeem(_CHAIN_ID_2);

    // it should accrue the untouched chain at the resampled rate over the later interval
    // B's ceiling integrates e0 over [t0, t1] and the RESAMPLED e1 over [t1, t2], even though B was never
    // touched at t1. This is the shared-index fix: the post-change scalar reaches B through the index.
    assertEq(_chainState(_voter, _CHAIN_ID_2).ceiling, _ghostAccrual(_weightB, _t0, _t2, _schedule));

    // it should not accrue the untouched chain at the stale pre change rate
    // Under the old per-chain-rate model B would have kept its stale e0 rate for the whole window; that
    // value is strictly larger because e1 < e0. The observed ceiling must be below it.
    assertLt(_e1, _e0);
    uint256 _staleModel = Math.mulDiv(_weightB, _e0 * (uint256(_dt1) + _dt2), _PRECISION);
    assertLt(_chainState(_voter, _CHAIN_ID_2).ceiling, _staleModel);
  }

  function test_WhenTheSettleWalkCrossesManyWeekBoundaries() external {
    // Both walks in a settle are O(elapsed / WEEK), and `_settleGlobalIndex` banks a fresh mark per boundary.
    // Measuring the *marginal* cost of four extra boundaries cancels the settle's fixed overhead, so this only
    // moves if something lands inside a loop body. `_INITIAL_TIMESTAMP` is week-aligned, so warping N weeks
    // crosses exactly N boundaries.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(1e18);
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));

    // Warm the slots both measured settles share, so the difference below is boundary work and nothing else.
    // Foundry keeps storage warm across calls inside one test, so an unwarmed first measurement reads high.
    _measureSettleGas(_INITIAL_TIMESTAMP, 2);

    // Each window starts past the previous one, so every boundary banked is still an unwritten slot.
    uint256 _gasTwo = _measureSettleGas(_INITIAL_TIMESTAMP + 8 * _WEEK, 2);
    uint256 _gasSix = _measureSettleGas(_INITIAL_TIMESTAMP + 16 * _WEEK, 6);

    // it should keep the cost of each extra boundary bounded
    // A boundary banks two cold zero-to-nonzero SSTOREs (`index` and `timeIndex` marks, ~22.1k each) and reads a
    // cold slope change (2.1k); the marks are warm by the time the ceiling walk reads them back.
    uint256 _perBoundary = (_gasSix - _gasTwo) / 4;
    emit log_named_uint('gas per boundary', _perBoundary);
    assertLt(_perBoundary, 55_000);
  }

  function test_WhenAChainIsRegisteredAfterTheTimeWeightedAccumulatorHasGrown() external {
    // Regression (settle half): the first settle of a chain whose cursors were seeded late must credit the exact
    // integral. `lastTimeIndex` must move in lockstep with `lastIndex`; a stale-zero time cursor inflates the
    // decay correction with every `timeIndex` accrued before the seed and starves a decaying chain to zero. The
    // `registerChain` suite asserts the seeding itself; here the cursors are planted directly at the live
    // accumulators and only the settle math is under test. Only a NON-permanent (non-zero slope) chain triggers
    // the bug, so this seeds a decaying point and drives the ceiling to its exact positive value.
    uint48 _deployTime = _INITIAL_TIMESTAMP; // setUp warped here and deployed Voter, seeding the accumulators at 0
    uint256 _scalar = _PRECISION; // constant emissionsPerVP; scale divides out so the window integral is exact
    uint48 _tReg = _deployTime + 52 * _WEEK; // register a full year past deploy, so `timeIndex` is large and non-zero
    uint48 _boundary = _tReg + _WEEK; // settle exactly one week: a single full segment, no trailing partial
    uint48 _stakeEnd = _tReg + 2 * _WEEK; // stake outlives the window, so the slope never fires inside it

    // Drive the global accumulators to the values a continuous settle from deploy at `_scalar` would reach by
    // `_tReg`. `timeIndex` weights by absolute time (origin at the unix epoch), so from deploy it telescopes to
    // `scalar·(tReg^2 - deploy^2)`; `index` is origin-free, `scalar·(tReg - deploy)`. Live BEFORE `registerChain`.
    vm.warp(_tReg);
    _mockGlobalIndex(_scalar * uint256(_tReg - _deployTime));
    _mockGlobalTimeIndex(_scalar * (uint256(_tReg) * _tReg - uint256(_deployTime) * _deployTime));
    _mockEmissionsPerVP(_scalar);
    _mockLastGlobalSettlement(_tReg);

    // Seed the cursors of an already-registered chain to the live accumulators — the values `registerChain`
    // plants at `_tReg` (that seeding path is asserted in the `registerChain` suite). This isolates the settle
    // math: a wrong cursor here reproduces the starved first settle without routing through `registerChain`.
    uint256 _newChainId = _CHAIN_ID_1;
    _mockChainLastIndex(_newChainId, _voter.index());
    _mockChainLastTimeIndex(_newChainId, _voter.timeIndex());

    // Give the chain a decaying point: bias = slope·(stakeEnd − tReg), zero permanent balance.
    int128 _slope = _slopeOf(1000 * _ONE_AERO);
    int128 _bias = _slope * int128(uint128(_stakeEnd - _tReg));
    _mockChainPoint({_chainId: _newChainId, _bias: _bias, _slope: _slope, _ts: _tReg, _perm: 0});

    // First settle across the single week window.
    vm.warp(_boundary);
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));
    _settleViaRedeem(_newChainId);

    // Independent ghost: exact integral of a linear weight against a constant scalar over the window is the
    // trapezoid `(startWeight + endWeight) · indexDelta / (2·PRECISION)`. Start/end weights are read off the
    // seeded slope directly, not from the contract's own `coeff` form.
    uint256 _startWeight = uint128(_bias); // weight at `_tReg`
    uint256 _endWeight = uint128(_slope * int128(uint128(_stakeEnd - _boundary))); // weight decayed to `_boundary`
    uint256 _indexDelta = _scalar * _WEEK; // `index` growth over the week
    uint256 _ghost = Math.mulDiv(_startWeight + _endWeight, _indexDelta, 2 * _PRECISION);

    // it should credit a decaying chain the full positive accrual on its first settle
    // Pre-fix (`lastTimeIndex == 0`) this floors to zero; the ghost is far above the 1-wei rounding tolerance.
    assertApproxEqAbs(_chainState(_voter, _newChainId).ceiling, _ghost, 1);
  }

  /// @notice Weight of a decaying point at `_t`: `slope * (stakeEnd - _t)`.
  function _weightAt(int128 _slope, uint48 _stakeEnd, uint48 _t) internal pure returns (uint128) {
    return uint128(uint128(_slope) * uint128(_stakeEnd - _t));
  }

  /// @notice Exact accrual of one constant-scalar segment: `(startWeight + endWeight) * indexDelta / (2 * PRECISION)`,
  ///         floored once to match the contract's single final divide. Exact for a linear weight and constant scalar.
  function _driftGhostSegment(uint128 _wa, uint128 _wb, uint256 _indexDelta) internal pure returns (uint256) {
    return (uint256(_wa) + _wb) * _indexDelta / (2 * _PRECISION);
  }

  function test_WhenTheScalarChangesInsideADecayingChainsUnsettledSegment(
    uint256 _e0,
    uint256 _e1,
    uint48 _dt1,
    uint48 _dt2
  ) external {
    // Two identical decaying chains see the same scalar schedule (`e0` over [t0, t1], `e1` over [t1, t2]), all
    // inside one week so no boundary cuts the segment. Chain A settles once at t2 (a single segment spanning the
    // scalar change); chain B settles at t1 and t2 (two constant-scalar segments = the exact integral). The
    // average-weight accrual used to misprice A's single segment by up to tens of percent; the two-index accrual
    // makes both cadences agree within per-segment rounding.
    _e0 = bound(_e0, 1e12, 1e20);
    _e1 = bound(_e1, 1e12, 1e20);
    _dt1 = uint48(bound(_dt1, 1 hours, 3 days));
    _dt2 = uint48(bound(_dt2, 1 hours, 3 days));

    uint48 _t0 = _INITIAL_TIMESTAMP + 1 hours; // off a boundary, inside the first week
    uint48 _stakeEnd = _INITIAL_TIMESTAMP + _WEEK; // steep decay; the window stays before expiry
    int128 _slope = _slopeOf(1000 * _ONE_AERO);

    vm.warp(_t0);
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), bytes(''));
    for (uint256 _i; _i < 2; ++_i) {
      uint256 _chainId = _i == 0 ? _CHAIN_ID_1 : _CHAIN_ID_2;
      _mockChainPoint({
        _chainId: _chainId, _bias: _slope * int128(uint128(_stakeEnd - _t0)), _slope: _slope, _ts: _t0, _perm: 0
      });
      _mockChainSlopeChange({_chainId: _chainId, _expiry: _stakeEnd, _value: _slope});
      _mockChainLastIndex(_chainId, _voter.index());
    }
    _mockLastGlobalSettlement(_t0);
    _mockEmissionsPerVP(_e0);

    // t1: settle B only (banks e0 over [t0, t1] and accrues its first segment); then resample to e1. A is untouched.
    vm.warp(_t0 + _dt1);
    _settleViaRedeem(_CHAIN_ID_2);
    _mockEmissionsPerVP(_e1);

    // t2: settle A once (one segment across the scalar change) and B a second time (its [t1, t2] segment).
    vm.warp(_t0 + _dt1 + _dt2);
    _settleViaRedeem(_CHAIN_ID_1);
    _settleViaRedeem(_CHAIN_ID_2);

    _assertCadenceInvariant(_slope, _stakeEnd, _t0, _e0, _e1, _dt1, _dt2);
  }

  /// @notice Both settle cadences match the exact integral within per-segment rounding (floor positive, ceil
  ///         negative over one segment for A, and per constant-scalar segment for B, so the gap is a few wei).
  function _assertCadenceInvariant(
    int128 _slope,
    uint48 _stakeEnd,
    uint48 _t0,
    uint256 _e0,
    uint256 _e1,
    uint48 _dt1,
    uint48 _dt2
  ) internal {
    uint256 _exact = _driftGhostSegment(
      _weightAt(_slope, _stakeEnd, _t0), _weightAt(_slope, _stakeEnd, _t0 + _dt1), _e0 * _dt1
    )
    + _driftGhostSegment(
      _weightAt(_slope, _stakeEnd, _t0 + _dt1), _weightAt(_slope, _stakeEnd, _t0 + _dt1 + _dt2), _e1 * _dt2
    );

    // it should credit the same however often the chain settles
    assertApproxEqAbs(_chainState(_voter, _CHAIN_ID_1).ceiling, _exact, 4);
    assertApproxEqAbs(_chainState(_voter, _CHAIN_ID_2).ceiling, _exact, 4);
    assertApproxEqAbs(_chainState(_voter, _CHAIN_ID_1).ceiling, _chainState(_voter, _CHAIN_ID_2).ceiling, 4);
  }
}
