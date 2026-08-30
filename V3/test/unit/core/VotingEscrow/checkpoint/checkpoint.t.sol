// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowCheckpoint is BaseVotingEscrow {
  /// @dev Slope upper bound derived from the realistic decay ceiling. With `_DECAY_AMOUNT_CAP = 1e30`
  ///      and `iMAXTIME ≈ 1.26e8`, the worst-case realistic slope is `~7.9e21`, so `1e22` covers it
  ///      with ~25% headroom while keeping `slope * WEEK` (~6e27) well below `int128.max`.
  int128 internal constant _SLOPE_CAP = 1e22;

  function test_WhenThereIsNoPriorGlobalCheckpoint(uint48 _now) external {
    // Pick a NOW not on a week boundary so the loop's t_i overshoots and clamps in a single iteration.
    _now = uint48(bound(_now, _WEEK + 1, 100 * _WEEK - 1));
    vm.assume(_now % _WEEK != 0);
    vm.warp(_now);

    _ve.checkpoint();

    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(1);
    // it should set epoch to one
    assertEq(_ve.epoch(), 1);
    // it should record a zeroed point at the current timestamp
    assertEq(_point.bias, 0);
    assertEq(_point.slope, 0);
    assertEq(_point.ts, _now);
    assertEq(_point.permanentStakeBalance, 0);
    // it should report zero total supply through totalVotingPowerAt
    assertEq(_ve.totalVotingPowerAt(block.timestamp), 0, 'totalVotingPowerAt drift');
    _assertGlobalPointInvariants();
  }

  function test_WhenCalledInTheSameBlockAsThePreviousCheckpoint(uint48 _now) external {
    _now = uint48(bound(_now, _WEEK + 1, 100 * _WEEK - 1));
    vm.assume(_now % _WEEK != 0);
    vm.warp(_now);

    _ve.checkpoint();
    IVotingEscrow.GlobalPoint memory _before = _ve.pointHistory(1);
    _ve.checkpoint();
    IVotingEscrow.GlobalPoint memory _after = _ve.pointHistory(1);

    // it should keep epoch unchanged
    assertEq(_ve.epoch(), 1);
    // it should overwrite the latest point with the same data
    assertEq(_after.bias, _before.bias);
    assertEq(_after.slope, _before.slope);
    assertEq(_after.ts, _before.ts);
    assertEq(_after.permanentStakeBalance, _before.permanentStakeBalance);
    // and no new entry should appear at slot 2
    IVotingEscrow.GlobalPoint memory _empty = _ve.pointHistory(2);
    assertEq(_empty.ts, 0);
    _assertGlobalPointInvariants();
  }

  function test_WhenCalledWithinTheSameWeekAsThePreviousCheckpoint(
    int128 _bias,
    int128 _slope,
    uint48 _elapsed
  ) external {
    // Seed point at (1 week + 1): one second past the week-1 boundary, so the next boundary is _WEEK - 1 away.
    uint48 _t0 = _WEEK + 1;
    // Cap inputs so bias - slope * elapsed stays representable and positive. With slope <= _SLOPE_CAP
    // and elapsed <= WEEK, decay <= ~6e27, which leaves headroom below int128 max for the bias upper bound.
    _slope = int128(bound(_slope, 0, _SLOPE_CAP));
    _elapsed = uint48(bound(_elapsed, 1, _WEEK - 2));
    int128 _decay = _slope * int128(uint128(_elapsed));
    _bias = int128(bound(_bias, _decay, type(int128).max));

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    vm.warp(_t0 + _elapsed);

    _ve.checkpoint();

    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(2);
    // it should increment epoch by one
    assertEq(_ve.epoch(), 2);
    // it should decay the bias by slope times the elapsed seconds
    assertEq(_point.bias, _bias - _decay);
    assertEq(_point.slope, _slope);
    assertEq(_point.ts, _t0 + _elapsed);
    _assertGlobalPointInvariants();
  }

  function test_WhenOneOrMoreWeekBoundariesAreCrossed(int128 _bias, int128 _slope) external {
    // Anchor the prior point to the week-1 boundary so the iteration math is clean.
    uint48 _t0 = _WEEK;
    _slope = int128(bound(_slope, 0, _SLOPE_CAP));
    int128 _twoWeekDecay = _slope * int128(uint128(2 * _WEEK));
    _bias = int128(bound(_bias, _twoWeekDecay, type(int128).max));

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    // Advance exactly two weeks so the loop iterates twice: first crosses _t0 + _WEEK and writes an
    // intermediate point, second lands on _t0 + 2*_WEEK == block.timestamp and breaks before writing
    // an intermediate (the final write happens outside the loop).
    vm.warp(_t0 + 2 * _WEEK);

    _ve.checkpoint();

    // it should write an intermediate point at each crossed boundary
    IVotingEscrow.GlobalPoint memory _mid = _ve.pointHistory(2);
    assertEq(_mid.ts, _t0 + _WEEK);
    assertEq(_mid.bias, _bias - _slope * int128(uint128(_WEEK)));
    assertEq(_mid.slope, _slope);
    // it should end with a final point at the current timestamp
    IVotingEscrow.GlobalPoint memory _final = _ve.pointHistory(3);
    assertEq(_ve.epoch(), 3);
    assertEq(_final.ts, _t0 + 2 * _WEEK);
    assertEq(_final.bias, _bias - 2 * _slope * int128(uint128(_WEEK)));
    assertEq(_final.slope, _slope);
    _assertGlobalPointInvariants();
  }

  function test_WhenAScheduledSlopeChangeExistsAtACrossedWeekBoundary(
    int128 _bias,
    int128 _slope,
    int128 _delta
  ) external {
    uint48 _t0 = _WEEK;
    _slope = int128(bound(_slope, 1, _SLOPE_CAP));
    // Bound delta so (slope + delta) stays positive and the bias never goes negative across both weeks.
    _delta = int128(bound(_delta, -_slope + 1, _SLOPE_CAP));
    int128 _newSlope = _slope + _delta;
    int128 _totalDecay = _slope * int128(uint128(_WEEK)) + _newSlope * int128(uint128(_WEEK));
    _bias = int128(bound(_bias, _totalDecay, type(int128).max));

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    _setSlopeChange(_t0 + _WEEK, _delta);
    vm.warp(_t0 + 2 * _WEEK);

    _ve.checkpoint();

    // The intermediate point at the boundary should already carry (slope + delta).
    IVotingEscrow.GlobalPoint memory _mid = _ve.pointHistory(2);
    assertEq(_mid.ts, _t0 + _WEEK);
    assertEq(_mid.bias, _bias - _slope * int128(uint128(_WEEK)));
    // it should add the scheduled change to the running slope
    assertEq(_mid.slope, _newSlope);

    // The final point decays from the intermediate at the new slope for another _WEEK.
    IVotingEscrow.GlobalPoint memory _final = _ve.pointHistory(3);
    assertEq(_final.ts, _t0 + 2 * _WEEK);
    assertEq(_final.bias, _bias - _slope * int128(uint128(_WEEK)) - _newSlope * int128(uint128(_WEEK)));
    assertEq(_final.slope, _newSlope);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheScheduledChangeWouldDriveTheRunningSlopeNegative() external {
    // CKPT-1: exercise the loop slope-clamp true-arm (VotingEscrow.sol:642). Schedule a slope change at the
    // first crossed boundary that is MORE NEGATIVE than the running slope, so `slope + delta < 0` and clamps to 0.
    // All values are concrete literals so the clamp and the pre-clamp bias decay are hand-verifiable.
    uint48 _t0 = _WEEK; // prior point anchored to the week-1 boundary
    int128 _slope = 5; // running slope before the boundary
    int128 _delta = -10; // scheduled change at _t0 + _WEEK; -10 < -5 so the sum 5 + (-10) = -5 < 0
    int128 _bias = 10_000_000; // large enough that the single-step decay stays positive

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    _setSlopeChange(_t0 + _WEEK, _delta);
    // Advance two weeks: iteration 0 crosses _t0 + _WEEK (applies the clamp), iteration 1 lands on now and breaks.
    vm.warp(_t0 + 2 * _WEEK);

    _ve.checkpoint();

    // it should clamp the running slope to zero
    // Intermediate point at the crossed boundary. The bias decays at the PRE-clamp slope (5) for one full _WEEK
    // BEFORE the negative delta is applied: decay = 5 * 604800 = 3_024_000, so bias = 10_000_000 - 3_024_000.
    IVotingEscrow.GlobalPoint memory _mid = _ve.pointHistory(2);
    assertEq(_mid.ts, _t0 + _WEEK);
    assertEq(_mid.bias, 6_976_000);
    // 5 + (-10) = -5 < 0, so the clamp forces the slope to 0.
    assertEq(_mid.slope, 0);

    // Final point: slope is already 0, so the second step decays nothing; bias stays at 6_976_000.
    IVotingEscrow.GlobalPoint memory _final = _ve.pointHistory(3);
    assertEq(_ve.epoch(), 3);
    assertEq(_final.ts, _t0 + 2 * _WEEK);
    assertEq(_final.bias, 6_976_000);
    assertEq(_final.slope, 0);
    _assertGlobalPointInvariants();
  }

  function test_WhenUsingAKnownDecayExample() external {
    // CKPT-2: independent hand-computed decay case (no contract formula restated). Seed one second past the
    // week-1 boundary so the next boundary is _WEEK - 1 away and the elapsed time stays within a single week,
    // forcing exactly one loop iteration that decays at the seeded slope.
    uint48 _t0 = _WEEK + 1;
    int128 _slope = 7; // S
    uint48 _elapsed = 3 days; // E = 259_200 seconds, < _WEEK - 1 so we stay within the same week
    int128 _bias = 5_000_000; // B

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    vm.warp(_t0 + _elapsed);

    _ve.checkpoint();

    // it should match the hand computed decayed bias
    // Hand derivation: decay = S * E = 7 * 259_200 = 1_814_400; bias = B - decay = 5_000_000 - 1_814_400.
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(2);
    assertEq(_ve.epoch(), 2);
    assertEq(_point.bias, 3_185_600);
    assertEq(_point.slope, 7);
    assertEq(_point.ts, _t0 + _elapsed);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheDecayWouldDriveTheBiasNegative(int128 _bias, int128 _slope) external {
    uint48 _t0 = _WEEK;
    _slope = int128(bound(_slope, 1, type(int64).max));
    // Force overshoot: pick bias < slope * _WEEK (the smallest decay across one iteration).
    int128 _oneWeekDecay = _slope * int128(uint128(_WEEK));
    _bias = int128(bound(_bias, 0, _oneWeekDecay - 1));

    _setEpoch(1);
    _setPointHistory(1, _bias, _slope, _t0, 0);
    vm.warp(_t0 + 2 * _WEEK);

    _ve.checkpoint();

    // it should clamp the bias to zero
    IVotingEscrow.GlobalPoint memory _mid = _ve.pointHistory(2);
    assertEq(_mid.bias, 0);
    IVotingEscrow.GlobalPoint memory _final = _ve.pointHistory(3);
    assertEq(_final.bias, 0);
    // Slope is preserved since no slope changes were scheduled.
    assertEq(_final.slope, _slope);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheGlobalPermanentStakeBalanceHasChangedSinceThePriorPoint(
    uint128 _priorPermanent,
    uint128 _livePermanent
  ) external {
    vm.assume(_priorPermanent != _livePermanent);
    uint48 _t0 = _WEEK + 1;

    _setEpoch(1);
    _setPointHistory(1, 0, 0, _t0, _priorPermanent);
    // Live storage diverges from the prior point's permanent value.
    _setSupplyAndPermanent(_livePermanent, _livePermanent);
    vm.warp(_t0 + 1 days);

    _ve.checkpoint();

    // it should sync the live permanent balance into the new point
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(2);
    assertEq(_point.permanentStakeBalance, _livePermanent);
    _assertGlobalPointInvariants();
  }

  function test_WhenMoreThanTheMaximumNumberOfWeekBoundariesHaveElapsed() external {
    // CKPT-3: the week-walk loop (VotingEscrow.sol:631) is hard-bounded to 255 iterations. When far more than
    // 255 weeks have elapsed since the last global checkpoint, the loop caps and leaves the global point STALE:
    // its ts never reaches block.timestamp. Use slope = 0 / bias = 0 so no decay math interferes and the only
    // observable effect is the iteration cap. The prior point is anchored to a week boundary (T0 = _WEEK) so each
    // loop step advances _ti by exactly one _WEEK.
    uint48 _t0 = _WEEK;

    _setEpoch(1);
    _setPointHistory(1, 0, 0, _t0, 0);
    // Warp 300 weeks past the prior point, well beyond the 255-iteration cap so the loop never reaches now.
    vm.warp(_t0 + 300 * _WEEK);

    _ve.checkpoint();

    // it should cap the epoch at the maximum loop iterations
    // The loop runs the full 255 iterations, each incrementing epoch once: 1 + 255 = 256.
    assertEq(_ve.epoch(), 256);
    // it should leave the global point timestamp stale before the current time
    // Each iteration advances _ti by one _WEEK from the week-aligned start, so the final ts is
    // T0 + 255 * _WEEK = _WEEK + 255 * _WEEK = 256 * _WEEK = 154_828_800, NOT block.timestamp.
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(256);
    assertEq(_point.ts, 154_828_800);
    // block.timestamp = T0 + 300 * _WEEK = 301 * _WEEK = 182_044_800, so the point is left stale.
    assertEq(block.timestamp, 182_044_800);
    assertLt(uint256(_point.ts), block.timestamp);
    // Bias/slope stay zero (seeded zero, no decay, no scheduled changes).
    assertEq(_point.bias, 0);
    assertEq(_point.slope, 0);
    // NOTE: _assertGlobalPointInvariants is intentionally NOT called here: it asserts the point ts equals
    // block.timestamp, which is precisely the staleness this test is proving cannot hold past the cap.
  }
}
