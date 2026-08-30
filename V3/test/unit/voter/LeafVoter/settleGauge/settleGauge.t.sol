// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

contract UnitLeafVoterSettleGauge is BaseLeafVoter {
  /// @notice A registered gauge the tests act on. Distinct from the factory, orchestrator, and
  ///         `_ZERO_GAUGE`, so it needs no per-test bounding.
  address public immutable GAUGE = makeAddr('Gauge');

  // Shared fuzz bounds. Weight is raw voting power in token decimals, not a percentage. The share is
  // `index * weight / PRECISION`, so PRECISION scales the index, not the weight.

  /// @dev Upper bound for a fuzzed gauge weight, one whole token of voting power.
  uint128 internal constant _MAX_WEIGHT = 1e18;

  /// @dev Upper bound for a fuzzed chain index. Held above PRECISION and not PRECISION aligned so the
  ///      walk's truncating division runs for real.
  uint256 internal constant _MAX_INDEX = 1e24;

  /// @dev Upper bound for each per boundary index delta in a multi segment walk.
  uint256 internal constant _MAX_INDEX_STEP = 1e22;

  /// @dev Upper bound for the fuzzed surplus, claimed, and ceiling seeds in the surplus accounting tests.
  uint256 internal constant _MAX_ACCOUNTING = 1e30;

  /// @dev Per-walk tolerance for the decaying-gauge share, in wei. The contract floors its positive term and
  ///      ceils its negative term once per segment, while the independent segment-average model floors the
  ///      exact value once; the two agree to at most one wei per segment, so three segments allow three.
  uint256 internal constant _WALK_TOLERANCE = 3;

  // Shared settle-window fixtures. Stored rather than constant so each reference loads via SLOAD
  // instead of inlining a literal, which keeps the multi-segment settle tests off the stack.

  /// @dev Fixed effective emission share, weight times index over PRECISION (1e18 * 1e18 / 1e18).
  ///      The surplus-accounting tests pin the walk inputs and assert only the accounting.
  uint128 internal _fixedEffectiveShare = 1e18;

  /// @dev Start of the one-day settled window the surplus-accounting tests use.
  uint48 internal _fromOneDay = _SEED_TIMESTAMP - 1 days;

  /// @dev Chain settlement the two-boundary walk freezes on and targets. `timeIndex` weights the scalar by
  ///      absolute time (origin at the unix epoch), so the coefficient's `segmentEnd` term needs no relative
  ///      reference; the window just sits forward of the gauge's last settle so the walk has segments to price.
  uint48 internal _settleTwoWeeks = _SEED_TIMESTAMP + 3 * _WEEK;
  /// @dev Start of the two-week settled window the two-boundary walk spans.
  uint48 internal _fromTwoWeeks = _settleTwoWeeks - 2 * _WEEK;
  /// @dev First weekly boundary the walk crosses.
  uint48 internal _firstBoundary = _nextWeekBoundary(_fromTwoWeeks);
  /// @dev Second weekly boundary the walk crosses, one week after the first.
  uint48 internal _secondBoundary = _firstBoundary + _WEEK;

  /**
   * @dev Inputs for a two-boundary settle walk. Passed by memory reference so the per-scenario
   *      values stay off the test's stack, which keeps the multi-segment tests within the legacy
   *      codegen stack limit (the suite compiles without via_ir).
   * @param bias Gauge bias at the window start.
   * @param slope Gauge slope.
   * @param perm Permanent stake balance.
   * @param slopeChange Slope reduction scheduled at the second boundary; zero seeds none.
   * @param index1 Index snapshot at the first boundary.
   * @param timeIndex Index snapshot at the second boundary.
   * @param index3 Current chain index at `_SEED`.
   */
  struct WalkInputs {
    int128 bias;
    int128 slope;
    uint128 perm;
    int128 slopeChange;
    uint256 index1;
    uint256 timeIndex;
    uint256 index3;
  }

  /// @dev Bound a fuzzed gauge to a usable, non-special address: not the factory, orchestrator,
  ///      test contract, `_DEALLOC_GAUGE`, or (via _assumeFuzzable) _ZERO_GAUGE and precompiles.
  function _boundGauge(address _gauge) internal returns (address _bounded) {
    _assumeFuzzable(_gauge);
    _bounded = _boundNotEq(_gauge, _GAUGE_FACTORY);
    _bounded = _boundNotEq(_bounded, _LEAF_MESSAGE_ORCHESTRATOR);
    _bounded = _boundNotEq(_bounded, address(this));
    _bounded = _boundNotEq(_bounded, _DEALLOC_GAUGE);
  }

  /// @dev Fill `_inputs` with three strictly increasing, non aligned index snapshots from raw fuzz
  ///      seeds, so each crossed boundary carries a distinct value and the per segment truncation is
  ///      exercised. `_minStep3` floors the final step for tests that need a non trivial trailing
  ///      segment. The struct is memory so the writes land on the caller's `_inputs`.
  function _seedIndexSteps(
    WalkInputs memory _inputs,
    uint256 _r1,
    uint256 _r2,
    uint256 _r3,
    uint256 _minStep3
  ) internal view {
    _inputs.index1 = bound(_r1, 1, _MAX_INDEX_STEP);
    _inputs.timeIndex = _inputs.index1 + bound(_r2, 1, _MAX_INDEX_STEP);
    _inputs.index3 = _inputs.timeIndex + bound(_r3, _minStep3, _MAX_INDEX_STEP);
  }

  /// @dev Seed `_gauge` as a registered, empty gauge with a non decaying point of `_perm` anchored at
  ///      `_from`. The settle window runs from `_from` over a flat weight, no bias or slope to decay.
  ///      Ceiling, claimed, surplus, and lastIndex all start at zero.
  function _seedFlatGauge(address _gauge, uint48 _from, uint128 _perm) internal {
    _mockGaugeState(
      _gauge,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _from,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _from, _permanentStakeBalance: _perm})
      })
    );
  }

  /**
   * @dev Seed a gauge for a settle walk over the two-week window [_fromTwoWeeks, _settleTwoWeeks],
   *      crossing _firstBoundary and _secondBoundary plus a trailing partial segment. Freezes the
   *      chain on _settleTwoWeeks (warped and pinned as `lastSettlement`, so _settleIndex no-ops) and
   *      writes the gauge point, the _firstBoundary and _secondBoundary snapshots of BOTH chain
   *      accumulators, an optional slope change at _secondBoundary, and an uncapped emission cap.
   *      Returns the expected effective share, integrated segment by segment. Kept in its own frame so
   *      the per-segment locals never pile onto the test's stack.
   * @param _gauge Gauge to seed.
   * @param _inputs Walk scenario inputs.
   * @return _effectiveShare Expected effective share over the window.
   */
  function _seedTwoBoundaryWalk(address _gauge, WalkInputs memory _inputs) internal returns (uint128 _effectiveShare) {
    vm.warp(_settleTwoWeeks);
    _mockChainSettlement(_settleTwoWeeks);
    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _inputs.index3});
    _mockIndexAtBoundary(_firstBoundary, _inputs.index1);
    _mockIndexAtBoundary(_secondBoundary, _inputs.timeIndex);
    _seedConsistentTimeIndex(_inputs);
    if (_inputs.slopeChange != 0) _mockGaugeSlopeChange(_gauge, _secondBoundary, _inputs.slopeChange);
    _mockEmissionCap(_gauge, type(uint128).max);

    _mockGaugeState(
      _gauge,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _fromTwoWeeks,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({
          _bias: _inputs.bias, _slope: _inputs.slope, _ts: _fromTwoWeeks, _permanentStakeBalance: _inputs.perm
        })
      })
    );

    // Expected share, segment by segment. A weight that decays at a constant slope is linear in time, so
    // its exact integral over a segment against a constant scalar is the segment's index delta times the
    // mean of the segment's endpoint weights: (w(a) + w(b)) * indexDelta / (2 * PRECISION). The halving
    // stays fused with the PRECISION divide and floors once, so the model tracks the contract's exact
    // two-index form to within a wei or two per segment (the contract floors its positive term and ceils
    // its negative term separately). The scheduled slope change lands on _secondBoundary, so only the
    // trailing segment decays at the reduced slope. Every scenario seeded here holds the weight at or
    // above zero for the whole window, asserted per segment.
    int256 _start = int256(uint256(_inputs.perm)) + _inputs.bias;
    int256 _end = _start - int256(_inputs.slope) * int256(uint256(_firstBoundary - _fromTwoWeeks));
    assertGe(_end, 0);
    _effectiveShare = uint128(uint256(_start + _end) * _inputs.index1 / (2 * _PRECISION));

    _start = _end;
    _end = _start - int256(_inputs.slope) * int256(uint256(_secondBoundary - _firstBoundary));
    assertGe(_end, 0);
    _effectiveShare += uint128(uint256(_start + _end) * (_inputs.timeIndex - _inputs.index1) / (2 * _PRECISION));

    _start = _end;
    _end = _start - int256(_inputs.slope - _inputs.slopeChange) * int256(uint256(_settleTwoWeeks - _secondBoundary));
    assertGe(_end, 0);
    _effectiveShare += uint128(uint256(_start + _end) * (_inputs.index3 - _inputs.timeIndex) / (2 * _PRECISION));
  }

  /**
   * @dev Seed `timeIndex` and its boundary snapshots consistent with the `index` schedule in `_inputs`, so
   *      the walk's second accumulator prices the same piecewise-constant scalar the first one does.
   *      For a segment [a, b] whose `index` grows by `d = e * (b - a)`, the doubled time-weighted
   *      accumulator grows by `e * (b^2 - a^2) = d * (a + b)` (origin at the unix epoch, so `o = 0`). That
   *      exact-integer relation avoids reintroducing the scalar. The gauge's `lastTimeIndex` cursor stays zero,
   *      matching its zero `lastIndex`.
   * @param _inputs Walk scenario inputs whose `index` snapshots the `timeIndex` schedule mirrors.
   */
  function _seedConsistentTimeIndex(WalkInputs memory _inputs) internal {
    uint256 _origin = 0; // timeIndex weights by absolute time (origin at the unix epoch)
    uint256 _fromElapsed = _fromTwoWeeks - _origin;
    uint256 _b1Elapsed = _firstBoundary - _origin;
    uint256 _b2Elapsed = _secondBoundary - _origin;
    uint256 _toElapsed = _settleTwoWeeks - _origin;

    uint256 _timeIndexAtB1 = _inputs.index1 * (_fromElapsed + _b1Elapsed);
    uint256 _timeIndexAtB2 = _timeIndexAtB1 + (_inputs.timeIndex - _inputs.index1) * (_b1Elapsed + _b2Elapsed);
    uint256 _timeIndex = _timeIndexAtB2 + (_inputs.index3 - _inputs.timeIndex) * (_b2Elapsed + _toElapsed);

    _mockTimeIndexAtBoundary(_firstBoundary, _timeIndexAtB1);
    _mockTimeIndexAtBoundary(_secondBoundary, _timeIndexAtB2);
    _mockChainTimeIndex(_timeIndex);
  }

  function test_WhenTheGaugeIsNotRegistered(address _gauge) external {
    _gauge = _boundGauge(_gauge);

    // Prior chain snapshot with a non-zero index, plus a block timestamp ahead of
    // lastSettlement, so a registered gauge would settle the chain. An unregistered gauge
    // must return before any of that.
    uint256 _index = 1e18;
    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _index});
    vm.warp(_SEED_TIMESTAMP + 1 days);

    uint256 _cumulative = _leafVoter.settleGauge(_gauge);

    // it should return a zero cumulative reward share
    assertEq(_cumulative, 0);
    // it should not settle the chain index
    assertEq(_leafVoter.index(), _index);
    assertEq(_leafVoter.lastSettlement(), _SEED_TIMESTAMP);
    // it should not modify the gauge state
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    assertEq(_state.ceiling, 0);
    assertEq(_state.lastSettlement, 0);
    assertFalse(_state.isRegistered);
    assertEq(_state.lastIndex, 0);
    // it should equal the read only projection for the same input
    assertEq(_leafVoter.projectedCumulativeRewardShare(_gauge), _cumulative);
  }

  function test_WhenTheGaugeWasAlreadySettledAtTheChainSettlement() external {
    uint256 _indexValue = 1e18;
    uint128 _ceiling = 1e18;
    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});

    // The gauge cursor already sits on the chain settlement, so the settled window is empty.
    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: _ceiling,
        _claimed: 0,
        _lastSettlement: _SEED_TIMESTAMP,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: _indexValue,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _SEED_TIMESTAMP, _permanentStakeBalance: 1e18})
      })
    );

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should return the unchanged gauge cumulative reward share
    assertEq(_cumulative, _ceiling);
    // it should not credit the gauge ceiling
    assertEq(_gaugeStateOf(GAUGE).ceiling, _ceiling);
  }

  function test_WhenTheGaugeIsTheZeroGauge(uint128 _weightRaw, uint256 _indexRaw, uint48 _durRaw) external {
    uint48 _duration = uint48(bound(_durRaw, 1 hours, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    uint128 _weight = uint128(bound(_weightRaw, 1, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _seedFlatGauge(_ZERO_GAUGE, _from, _weight);
    // The sink forces its own cap to zero, so this nonzero registry value is ignored. Kept mocked so a
    // regression reintroducing the sink cap query fails on the assertions, not on a missing code revert.
    _mockEmissionCap(_ZERO_GAUGE, type(uint128).max);

    // The sink emits nothing, so the whole walked allocation is surplus and the ceiling stays zero.
    uint128 _allocation = uint128(_indexValue * _weight / _PRECISION);

    uint256 _cumulative = _leafVoter.settleGauge(_ZERO_GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_ZERO_GAUGE);
    // it should accrue the full allocation to the chain surplus accumulator
    assertEq(_leafVoter.surplusAccrued(), _allocation);
    // it should not credit the zero gauge ceiling
    assertEq(_state.ceiling, 0);
    // it should advance gaugeStates[_gauge].lastSettlement to the chain lastSettlement
    assertEq(_state.lastSettlement, _SEED_TIMESTAMP);
    // it should advance gaugeStates[_gauge].lastIndex to the chain index
    assertEq(_state.lastIndex, _indexValue);

    // it should settle the chain index to the current timestamp
    // it should return the zero gauge cumulative reward share
    assertEq(_cumulative, 0);
  }

  function test_WhenTheZeroGaugeHasANonzeroRegistryEmissionCap() external {
    uint128 _weight = 1e18;
    uint256 _indexValue = 1e18;

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _seedFlatGauge(_ZERO_GAUGE, _fromOneDay, _weight);
    // A finite nonzero cap the sink must ignore. Under the old code this carved an 8.64e16 effective share
    // (1e12 * 1 days) into the unclaimable ceiling instead of surplus.
    _mockEmissionCap(_ZERO_GAUGE, 1e12);

    // Hand calculation independent of the contract walk. The allocation is
    // indexValue * weight / PRECISION = 1e18 * 1e18 / 1e18 = 1e18.
    uint128 _allocation = 1e18;

    uint256 _cumulative = _leafVoter.settleGauge(_ZERO_GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_ZERO_GAUGE);
    // it should ignore the registry cap and accrue the full allocation to the chain surplus accumulator
    assertEq(_leafVoter.surplusAccrued(), _allocation);
    // it should not credit the zero gauge ceiling
    assertEq(_state.ceiling, 0);
    // it should return the zero gauge cumulative reward share
    assertEq(_cumulative, 0);
  }

  function test_WhenTheGaugeIsRegistered(
    address _gauge,
    uint128 _weightRaw,
    uint256 _indexRaw,
    uint48 _durRaw
  ) external {
    _gauge = _boundGauge(_gauge);
    uint48 _duration = uint48(bound(_durRaw, 1 hours, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    uint128 _weight = uint128(bound(_weightRaw, 1, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _seedFlatGauge(_gauge, _from, _weight);
    _mockEmissionCap(_gauge, type(uint128).max);

    uint128 _effective = uint128(_indexValue * _weight / _PRECISION);

    uint256 _cumulative = _leafVoter.settleGauge(_gauge);

    // it should settle the chain index to the current timestamp
    // it should return the gauge cumulative reward share
    assertEq(_cumulative, _effective);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    // it should credit the effective share to the gauge ceiling
    assertEq(_state.ceiling, _effective);
    // it should return the post settle gauge ceiling
    assertEq(_cumulative, _state.ceiling);
    // it should advance gaugeStates[_gauge].lastSettlement to the chain lastSettlement
    assertEq(_state.lastSettlement, _SEED_TIMESTAMP);
    // it should advance gaugeStates[_gauge].lastIndex to the chain index
    assertEq(_state.lastIndex, _indexValue);
  }

  function test_WhenTheProjectionIsQueriedInTheSameBlock(
    address _gauge,
    uint128 _weightRaw,
    uint256 _indexRaw,
    uint48 _durRaw
  ) external {
    // The read-only projection must return the exact value a settle in the same block would, without
    // writing. Query the projection first, then settle, and prove they agree and that the projection
    // left the gauge cursors and ceiling untouched.
    _gauge = _boundGauge(_gauge);
    uint48 _duration = uint48(bound(_durRaw, 1 hours, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    uint128 _weight = uint128(bound(_weightRaw, 1, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _seedFlatGauge(_gauge, _from, _weight);
    _mockEmissionCap(_gauge, type(uint128).max);

    ILeafVoter.GaugeState memory _before = _gaugeStateOf(_gauge);

    // it should not mutate the gauge state
    uint256 _projected = _leafVoter.projectedCumulativeRewardShare(_gauge);
    ILeafVoter.GaugeState memory _after = _gaugeStateOf(_gauge);
    assertEq(_after.ceiling, _before.ceiling);
    assertEq(_after.lastSettlement, _before.lastSettlement);
    assertEq(_after.lastIndex, _before.lastIndex);

    // it should equal the value a settle in the same block returns
    uint256 _cumulative = _leafVoter.settleGauge(_gauge);
    assertEq(_projected, _cumulative);
  }

  function test_WhenTheProjectionIsQueriedPastTheLastSettlement(
    address _gauge,
    uint128 _weightRaw,
    uint256 _indexRaw,
    uint256 _scalarRaw,
    uint48 _toRaw
  ) external {
    // The chain is left unsettled: block.timestamp moves past lastSettlement without a settle, so the
    // projection must source the crossed boundary and the walk target from the live-rate tail
    // `index + emissionsPerVP * (t - lastSettlement)` instead of stored snapshots. The target is bound
    // to cross exactly one weekly boundary so the expected share is a two-segment hand calculation.
    _gauge = _boundGauge(_gauge);
    uint128 _weight = uint128(bound(_weightRaw, 1, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);
    uint256 _emissionsPerVP = bound(_scalarRaw, 1, _MAX_INDEX);
    uint48 _boundary = _nextWeekBoundary(_SEED_TIMESTAMP);
    uint48 _to = uint48(bound(_toRaw, _boundary, _boundary + _WEEK - 1));

    _mockChainAccumulator({_emissionsPerVP: _emissionsPerVP, _index: _indexValue});
    _seedFlatGauge(_gauge, _SEED_TIMESTAMP, _weight);
    _mockEmissionCap(_gauge, type(uint128).max);

    vm.warp(_to);

    // Hand-computed two-segment share at the live rate, [_SEED, boundary] then [boundary, to], each
    // truncated as the walk does. The gauge's index cursor starts at zero, so the first segment's
    // delta is the full projected boundary index.
    uint256 _boundaryIndex = _indexValue + _emissionsPerVP * (_boundary - _SEED_TIMESTAMP);
    uint256 _expected =
      _boundaryIndex * _weight / _PRECISION + _emissionsPerVP * (_to - _boundary) * _weight / _PRECISION;

    // it should project the unsettled tail at the live rate
    uint256 _projected = _leafVoter.projectedCumulativeRewardShare(_gauge);
    assertEq(_projected, _expected);

    // it should equal the share the settle path writes
    uint256 _settled = _leafVoter.settleGauge(_gauge);
    assertEq(_projected, _settled);
  }

  function test_WhenTheGaugeCarriesASeededCeilingAndSurplus(
    uint128 _seedCeilingRaw,
    uint128 _seedSurplusRaw,
    uint128 _seedClaimedRaw
  ) external {
    // Seed a non-empty ceiling, surplus, and claimed, holding the ceiling >= claimed + surplus bound.
    // The pull model no longer routes any gauge-reported surplus through settle, so a settle over a
    // fresh window credits the effective share to the running ceiling and leaves the seeded surplus
    // and the chain accumulator untouched.
    uint128 _seedSurplus = uint128(bound(_seedSurplusRaw, 0, _MAX_ACCOUNTING));
    uint128 _seedClaimed = uint128(bound(_seedClaimedRaw, 0, _MAX_ACCOUNTING));
    uint128 _seedCeiling =
      uint128(bound(_seedCeilingRaw, uint256(_seedClaimed) + _seedSurplus, type(uint128).max - _fixedEffectiveShare));

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: 1e18});
    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: _seedCeiling,
        _claimed: _seedClaimed,
        _lastSettlement: _fromOneDay,
        _isRegistered: true,
        _surplus: _seedSurplus,
        _lastIndex: 0,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _fromOneDay, _permanentStakeBalance: 1e18})
      })
    );
    _mockEmissionCap(GAUGE, type(uint128).max);

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should return the post settle gauge cumulative reward share
    assertEq(_cumulative, _seedCeiling + _fixedEffectiveShare);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should credit the effective share to the gauge ceiling
    assertEq(_state.ceiling, _seedCeiling + _fixedEffectiveShare);
    // it should return the post settle gauge ceiling
    assertEq(_cumulative, _state.ceiling);
    // it should advance gaugeStates[_GAUGE].lastSettlement to the chain lastSettlement
    assertEq(_state.lastSettlement, _SEED_TIMESTAMP);
    // it should advance gaugeStates[_GAUGE].lastIndex to the chain index
    assertEq(_state.lastIndex, 1e18);
    // it should leave the seeded gauge surplus unchanged
    assertEq(_state.surplus, _seedSurplus);
    // it should leave the chain surplus accumulator unchanged
    assertEq(_leafVoter.surplusAccrued(), 0);
  }

  function test_WhenTheAllocatedShareExceedsTheEmissionCapShare(
    uint128 _weightRaw,
    uint256 _indexRaw,
    uint48 _durRaw,
    uint128 _capRaw
  ) external {
    uint48 _duration = uint48(bound(_durRaw, 1 hours, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    // Sizable weight so the allocated share comfortably clears the duration and leaves cap room.
    uint128 _weight = uint128(bound(_weightRaw, 1e6, _MAX_WEIGHT));
    // Index held at least PRECISION so the allocated share dwarfs the duration.
    uint256 _indexValue = bound(_indexRaw, _PRECISION, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _seedFlatGauge(GAUGE, _from, _weight);

    uint256 _allocated = _indexValue * _weight / _PRECISION;
    // A cap strictly below allocated/duration so the cap share bites and the excess spills.
    uint128 _cap = uint128(bound(_capRaw, 1, (_allocated - 1) / _duration));
    _mockEmissionCap(GAUGE, _cap);

    uint128 _capShare = uint128(uint256(_cap) * _duration);

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should credit only the capped share to the gauge ceiling
    assertEq(_gaugeStateOf(GAUGE).ceiling, _capShare);
    // it should return the capped cumulative reward share
    assertEq(_cumulative, _capShare);
    // it should accrue the cap excess to the chain surplus accumulator
    assertEq(_leafVoter.surplusAccrued(), _allocated - _capShare);
  }

  function test_WhenTheGaugeEmissionCapIsZero(uint128 _weightRaw, uint256 _indexRaw, uint48 _durRaw) external {
    uint48 _duration = uint48(bound(_durRaw, 1 hours, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    uint128 _weight = uint128(bound(_weightRaw, 1e6, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, _PRECISION, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    // Seeded weight stands in for a whitelisted tokenId's vote, the only path
    // that records weight on a zero-cap gauge. The routing half lives in the
    // allocateGauges and applyGaugeAllocations suites; this covers the settle
    // half, where the zero cap must hold regardless of how the weight arrived.
    _seedFlatGauge(GAUGE, _from, _weight);

    uint256 _allocated = _indexValue * _weight / _PRECISION;
    _mockEmissionCap(GAUGE, 0);

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should return a zero cumulative reward share
    assertEq(_cumulative, 0);
    // it should not credit the gauge ceiling
    assertEq(_gaugeStateOf(GAUGE).ceiling, 0);
    // it should accrue the full allocated share to the chain surplus accumulator
    assertEq(_leafVoter.surplusAccrued(), _allocated);
  }

  function test_WhenTheSettledWindowSpansTwoOrMoreWeeklyBoundaries(
    uint128 _slopeRaw,
    uint128 _biasRaw,
    uint256 _index1Raw,
    uint256 _timeIndexRaw,
    uint256 _index3Raw
  ) external {
    // A decaying stake that does not expire inside the window. Bias is held to a small multiple of
    // the decay across the window so each segment carries a meaningfully distinct weight, forcing
    // the walk to read every boundary snapshot rather than telescope. Staying above the full-window
    // decay keeps the resolved weight positive, so no clamp fires.
    uint48 _from = _fromTwoWeeks;
    int128 _slope = int128(uint128(bound(_slopeRaw, 1, 100)));
    // Decay across both crossed segments: slope times (b2 - from).
    uint128 _windowDecay = uint128(_slope) * (_nextWeekBoundary(_from) + _WEEK - _from);

    // it should snapshot the chain index at each crossed boundary
    WalkInputs memory _inputs;
    _inputs.slope = _slope;
    _inputs.bias = int128(uint128(bound(_biasRaw, _windowDecay * 2, _windowDecay * 50)));
    _seedIndexSteps(_inputs, _index1Raw, _timeIndexRaw, _index3Raw, 1);
    uint128 _effective = _seedTwoBoundaryWalk(GAUGE, _inputs);

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should sum the per segment shares at the mean of each segment endpoint weight
    // it should return the cumulative reward share derived from the summed shares
    assertApproxEqAbs(_cumulative, _effective, _WALK_TOLERANCE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    assertApproxEqAbs(_state.ceiling, _effective, _WALK_TOLERANCE);
    // it should return the post settle gauge ceiling
    assertEq(_cumulative, _state.ceiling);
    // it should advance gaugeStates[_GAUGE].lastSettlement to the chain lastSettlement
    assertEq(_state.lastSettlement, _settleTwoWeeks);
    // it should advance gaugeStates[_GAUGE].lastIndex to the chain index
    assertEq(_state.lastIndex, _leafVoter.index());
  }

  function test_WhenAGaugeStakeExpiryFallsInsideTheSettledWindow(
    uint128 _slopeRaw,
    uint256 _index1Raw,
    uint256 _timeIndexRaw,
    uint256 _index3Raw
  ) external {
    // Window [from, _settleTwoWeeks] crossing boundary b1 and the stake expiry at b2; the post-expiry
    // segment runs weightless to _settleTwoWeeks. Bias decays exactly to zero at the expiry, where the
    // scheduled slope change fires.
    uint48 _from = _fromTwoWeeks;
    int128 _slope = int128(uint128(bound(_slopeRaw, 1, 1000)));

    WalkInputs memory _inputs;
    _inputs.slope = _slope;
    _inputs.slopeChange = _slope;
    // Bias decays exactly to zero at the expiry, where the scheduled slope change fires.
    _inputs.bias = _slope * int128(uint128(_nextWeekBoundary(_from) + _WEEK - _from));
    _seedIndexSteps(_inputs, _index1Raw, _timeIndexRaw, _index3Raw, 1);
    uint128 _effective = _seedTwoBoundaryWalk(GAUGE, _inputs);

    _leafVoter.settleGauge(GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should accrue share only up to the expiry boundary
    assertApproxEqAbs(_state.ceiling, _effective, _WALK_TOLERANCE);
    // it should consume the scheduled slope change at the expiry boundary
    assertEq(_state.point.slope, 0);
    // it should not clamp the gauge weight
    assertEq(_state.point.bias, 0);
  }

  function test_WhenTheGaugeHasOnlyAPermanentStakeBalance(
    uint128 _permRaw,
    uint256 _index1Raw,
    uint256 _timeIndexRaw,
    uint256 _index3Raw
  ) external {
    uint128 _perm = uint128(bound(_permRaw, 1, _MAX_WEIGHT));

    // No decay: every segment weights by the full permanent balance. The helper sums the share per
    // segment, each truncated as the contract does (the closed form would diverge on non-aligned
    // snapshots).
    WalkInputs memory _inputs;
    _inputs.perm = _perm;
    _seedIndexSteps(_inputs, _index1Raw, _timeIndexRaw, _index3Raw, 1);
    uint128 _effective = _seedTwoBoundaryWalk(GAUGE, _inputs);

    _leafVoter.settleGauge(GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should weight every segment with the permanent balance
    // it should accrue share without decay across boundaries
    assertEq(_state.ceiling, _effective);
    // it should leave the permanent balance unchanged after the settle
    assertEq(_state.point.permanentStakeBalance, _perm);
  }

  function test_WhenTheGaugeHasBothAPermanentBalanceAndADecayingStake(
    uint128 _permRaw,
    uint128 _slopeRaw,
    uint256 _index1Raw,
    uint256 _timeIndexRaw,
    uint256 _index3Raw
  ) external {
    uint48 _from = _fromTwoWeeks;
    uint128 _perm = uint128(bound(_permRaw, 1, _MAX_WEIGHT));
    int128 _slope = int128(uint128(bound(_slopeRaw, 1, 100)));

    // The post-expiry delta clears PRECISION so the permanent-only final segment accrues a
    // non-zero share for any permanent balance, proving accrual continues past the expiry.
    WalkInputs memory _inputs;
    _inputs.perm = _perm;
    _inputs.slope = _slope;
    _inputs.slopeChange = _slope;
    // The decaying part expires at the second boundary; bias decays to zero there.
    _inputs.bias = _slope * int128(uint128(_nextWeekBoundary(_from) + _WEEK - _from));
    _seedIndexSteps(_inputs, _index1Raw, _timeIndexRaw, _index3Raw, _PRECISION);
    uint128 _finalShare = uint128((_inputs.index3 - _inputs.timeIndex) * _perm / _PRECISION);
    uint128 _effective = _seedTwoBoundaryWalk(GAUGE, _inputs);

    _leafVoter.settleGauge(GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should add the permanent balance to the decaying weight in each segment
    // it should keep accruing share after the decaying stake expires
    assertApproxEqAbs(_state.ceiling, _effective, _WALK_TOLERANCE);
    assertGt(_finalShare, 0);
    // it should not clamp the gauge weight
    assertEq(_state.point.permanentStakeBalance, _perm);
    assertEq(_state.point.bias, 0);
  }

  function test_WhenTheGaugeWeightIsZeroAcrossTheSettledWindow(
    uint256 _index1Raw,
    uint256 _timeIndexRaw,
    uint256 _index3Raw
  ) external {
    // Zero weight everywhere: no permanent balance, no bias, no slope. Non-aligned snapshots still
    // cross both boundaries, but every segment accrues nothing.
    WalkInputs memory _inputs;
    _seedIndexSteps(_inputs, _index1Raw, _timeIndexRaw, _index3Raw, 1);
    _seedTwoBoundaryWalk(GAUGE, _inputs);

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should return a zero cumulative reward share
    assertEq(_cumulative, 0);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should accrue no share in any segment
    assertEq(_state.ceiling, 0);
    // it should advance the gauge cursors
    assertEq(_state.lastSettlement, _settleTwoWeeks);
    assertEq(_state.lastIndex, _leafVoter.index());
  }

  function test_WhenTheChainSettlementLandsExactlyOnAWeeklyBoundary(uint128 _permRaw, uint256 _indexRaw) external {
    // Chain settles exactly on a weekly boundary; the gauge cursor sits one segment behind. `timeIndex` weights
    // by absolute time (origin at the unix epoch), so the coefficient's `segmentEnd` term is always valid.
    uint48 _boundary = _nextWeekBoundary(_SEED_TIMESTAMP + _WEEK);
    uint48 _from = _boundary - 2 days;
    uint128 _perm = uint128(bound(_permRaw, 1, _MAX_WEIGHT));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);

    // Freeze the chain on the boundary; the boundary snapshot equals the current index so the
    // zero-length final segment reads a zero delta. `timeIndex` mirrors the same single-scalar schedule:
    // over [from, boundary] its doubled time-weighted growth is `indexValue * ((from - o) + (boundary - o))`.
    uint256 _origin = 0; // timeIndex weights by absolute time (origin at the unix epoch)
    uint256 _timeIndexValue = _indexValue * ((_from - _origin) + (_boundary - _origin));
    vm.warp(_boundary);
    _mockChainSettlement(_boundary);
    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _mockChainTimeIndex(_timeIndexValue);
    _mockIndexAtBoundary(_boundary, _indexValue);
    _mockTimeIndexAtBoundary(_boundary, _timeIndexValue);
    _mockEmissionCap(GAUGE, type(uint128).max);
    _seedFlatGauge(GAUGE, _from, _perm);

    // Only the segment [from, boundary] accrues; the final [boundary, boundary] segment is empty.
    uint128 _effective = uint128(_indexValue * _perm / _PRECISION);

    _leafVoter.settleGauge(GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should accrue nothing in the zero length final segment
    assertEq(_state.ceiling, _effective);
    // it should advance the gauge cursors to the boundary
    assertEq(_state.lastSettlement, _boundary);
    assertEq(_state.lastIndex, _indexValue);
  }

  function test_WhenTheGaugeWeightResolvesNegativeAfterTheWalk(
    uint128 _biasRaw,
    uint128 _slopeRaw,
    uint256 _indexRaw,
    uint48 _durRaw
  ) external {
    // A negative resolved weight cannot arise from normal bookkeeping. Every decaying stake schedules
    // a slope change at its expiry boundary, so the slope is consumed as the bias reaches zero and the
    // weight floors at the permanent balance. If this clamp ever fires in normal operation it signals
    // an upstream math error in the bias and slope accounting, not a state the inputs can legitimately
    // reach. This test seeds an inconsistent point, a slope with no matching expiry slope change, so
    // the decay outruns the bias and the resolved weight goes sub zero, exercising the defensive guard.
    uint48 _duration = uint48(bound(_durRaw, 1 days, 2 days));
    uint48 _from = _SEED_TIMESTAMP - _duration;
    // The slope outruns the bias over the window, so the resolved weight goes negative.
    int128 _bias = int128(uint128(bound(_biasRaw, 1, 1e6)));
    int128 _slope = int128(uint128(bound(_slopeRaw, uint128(_bias) / _duration + 1, 1e6)));
    uint256 _indexValue = bound(_indexRaw, 1, _MAX_INDEX);

    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _indexValue});
    _mockEmissionCap(GAUGE, type(uint128).max);

    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _from,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({_bias: _bias, _slope: _slope, _ts: _from, _permanentStakeBalance: 0})
      })
    );

    int256 _detectedWeight = int256(_bias) - int256(_slope) * int256(uint256(_duration));

    // it should emit the GaugeWeightClamped event with the negative weight
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugeWeightClamped(GAUGE, _detectedWeight);

    _leafVoter.settleGauge(GAUGE);

    IVoterCommon.Point memory _point = _gaugeStateOf(GAUGE).point;
    // it should zero the persisted gauge bias and slope
    assertEq(_point.bias, 0);
    assertEq(_point.slope, 0);

    // it should settle cleanly on the next call: advance the chain past the clamp and re-settle.
    uint48 _next = _SEED_TIMESTAMP + 1 days;
    vm.warp(_next);
    _mockChainSettlement(_next);
    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);
    assertEq(_cumulative, _gaugeStateOf(GAUGE).ceiling);
  }

  function test_WhenTheEmissionsScalarIsZero(uint48 _aheadRaw) external {
    // The chain's emissions-per-VP scalar is zero, so no segment accrues. Settling the index over
    // the window leaves it untouched, but the settlement cursor still advances.
    uint256 _indexValue = 1e18;
    _mockChainAccumulator({_emissionsPerVP: 0, _index: _indexValue});

    uint48 _to = _SEED_TIMESTAMP + uint48(bound(_aheadRaw, 1 hours, 2 days));
    vm.warp(_to);

    _mockEmissionCap(GAUGE, type(uint128).max);
    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _SEED_TIMESTAMP,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: _indexValue,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _SEED_TIMESTAMP, _permanentStakeBalance: 0})
      })
    );

    uint256 _cumulative = _leafVoter.settleGauge(GAUGE);

    // it should leave the chain index untouched
    assertEq(_leafVoter.index(), _indexValue);
    // it should advance the chain settlement cursor
    assertEq(_leafVoter.lastSettlement(), _to);
    // it should return a zero cumulative reward share
    assertEq(_cumulative, 0);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should advance the gauge cursor without crediting the ceiling
    assertEq(_state.ceiling, 0);
    assertEq(_state.lastSettlement, _to);
    assertEq(_state.lastIndex, _indexValue);
  }

  function test_WhenALeftoverSlopeChangeCrossesAZeroedGaugePoint(uint128 _slopeChangeRaw) external {
    // The defensive clamp zeroes a desynced point but leaves its future schedule entries. Consuming one from a
    // zero slope must not drive the slope negative, where decay turns into growth the walk then credits.
    int128 _slopeChange = int128(uint128(bound(_slopeChangeRaw, 1, 1000)));

    // Freeze the chain a full two-boundary window forward of the gauge's last settle, matching the walk fixture.
    vm.warp(_settleTwoWeeks);
    _mockChainSettlement(_settleTwoWeeks);
    _mockChainAccumulator({_emissionsPerVP: _PRECISION, _index: _PRECISION});
    _mockIndexAtBoundary(_firstBoundary, 0);
    _mockIndexAtBoundary(_secondBoundary, 0);
    // Both crossed boundaries hold a flat `index` (delta zero), so their `timeIndex` snapshots stay zero too;
    // only the trailing segment [b2, _settleTwoWeeks] carries the whole `index` and `timeIndex` growth.
    WalkInputs memory _timeIndexSchedule;
    _timeIndexSchedule.index3 = _PRECISION;
    _seedConsistentTimeIndex(_timeIndexSchedule);
    _mockGaugeSlopeChange(GAUGE, _secondBoundary, _slopeChange);
    _mockEmissionCap(GAUGE, type(uint128).max);
    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _fromTwoWeeks,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _fromTwoWeeks, _permanentStakeBalance: 0})
      })
    );

    _leafVoter.settleGauge(GAUGE);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(GAUGE);
    // it should floor the slope at zero
    assertEq(_state.point.slope, 0);
    // it should leave the bias at zero
    assertEq(_state.point.bias, 0);
    // it should accrue nothing for the phantom weight
    assertEq(_state.ceiling, 0);
  }

  function test_WhenTheScalarChangesInsideADecayingGaugesSegment(
    uint256 _e0,
    uint256 _ratioRaw,
    uint48 _splitRaw
  ) external {
    // A single week segment [from, to] over which the gauge weight decays AND the scalar changes at `m`: the
    // chain accumulators encode `e0` over [from, m] and `e1` over [m, to]. The gauge settles once across the
    // whole segment. The old average-weight accrual would price it at `avg(w_from, w_to) * indexDelta` — wrong
    // when e0 != e1; the two-index accrual matches the exact per-sub-interval integral. Leaf twin of root's
    // `ceilingConservation` cadence-invariance test, guarding `_walkGauge` against a regression to the misprice.
    // `e1` is bounded strictly away from `e0` so every run genuinely distinguishes the two formulas.
    _e0 = bound(_e0, 1e12, 1e18);
    uint256 _e1 = _e0 * bound(_ratioRaw, 2, 20);
    uint48 _from = _SEED_TIMESTAMP; // deploy time; the window stays inside its week (next boundary is +4 days)
    uint48 _to = _from + 1 days;
    uint48 _m = _from + uint48(bound(_splitRaw, 1 hours, 23 hours)); // scalar change strictly inside (from, to)
    uint48 _stakeEnd = _from + 2 * _WEEK; // weight stays positive across the window; no slope change fires
    int128 _slope = 1e12; // decay rate; weight at `from` is `slope * (stakeEnd - from)` ~= 1.2e18

    _seedChainScalarChange(_e0, _e1, _from, _m, _to);
    _seedDecayingGauge(_from, _stakeEnd, _slope);

    vm.warp(_to);
    _leafVoter.settleGauge(GAUGE);

    _assertExactSubIntervalAccrual(_slope, _stakeEnd, _from, _m, _to, _e0, _e1);
  }

  /// @notice Seed a fully-settled chain whose accumulators encode `e0` over [from, m] and `e1` over [m, to]
  ///         (absolute-time origin): `index = e0*(m-from) + e1*(to-m)`, `timeIndex = e0*(m^2-from^2) +
  ///         e1*(to^2-m^2)` (doubled).
  function _seedChainScalarChange(uint256 _e0, uint256 _e1, uint48 _from, uint48 _m, uint48 _to) internal {
    _mockChainAccumulator({_emissionsPerVP: _e1, _index: _e0 * (_m - _from) + _e1 * (_to - _m)});
    _mockChainTimeIndex(
      _e0 * (uint256(_m) * _m - uint256(_from) * _from) + _e1 * (uint256(_to) * _to - uint256(_m) * _m)
    );
    _mockChainSettlement(_to);
  }

  /// @notice Seed a decaying `GAUGE` cursored at `_from` with both index cursors zero, uncapped.
  function _seedDecayingGauge(uint48 _from, uint48 _stakeEnd, int128 _slope) internal {
    _mockGaugeState(
      GAUGE,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _from,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({
          _bias: _slope * int128(uint128(_stakeEnd - _from)), _slope: _slope, _ts: _from, _permanentStakeBalance: 0
        })
      })
    );
    _mockEmissionCap(GAUGE, type(uint128).max); // uncapped, so the full allocation lands on the ceiling
  }

  /// @notice The gauge ceiling equals the exact integral over the two constant-scalar sub-intervals, not the
  ///         whole-segment average the old code used. Split out to keep the fuzz test in stack budget.
  function _assertExactSubIntervalAccrual(
    int128 _slope,
    uint48 _stakeEnd,
    uint48 _from,
    uint48 _m,
    uint48 _to,
    uint256 _e0,
    uint256 _e1
  ) internal {
    uint256 _wFrom = uint128(_slope * int128(uint128(_stakeEnd - _from)));
    uint256 _wM = uint128(_slope * int128(uint128(_stakeEnd - _m)));
    uint256 _wTo = uint128(_slope * int128(uint128(_stakeEnd - _to)));
    uint256 _exact =
      (_wFrom + _wM) * (_e0 * (_m - _from)) / (2 * _PRECISION) + (_wM + _wTo) * (_e1 * (_to - _m)) / (2 * _PRECISION);

    // The old average-weight formula prices the whole segment at `avg(w_from, w_to) * indexDelta`. It must
    // diverge from the exact integral by far more than the rounding tolerance, or the test would pass on the
    // pre-fix code too and guard nothing.
    uint256 _oldMisprice = (_wFrom + _wTo) * (_e0 * (_m - _from) + _e1 * (_to - _m)) / (2 * _PRECISION);
    assertGt(_exact > _oldMisprice ? _exact - _oldMisprice : _oldMisprice - _exact, 4);

    // it should credit the exact per sub interval integral not the whole segment average
    assertApproxEqAbs(_gaugeStateOf(GAUGE).ceiling, _exact, 4);
  }

  function test_WhenTwoGaugesExpireTogetherInsideTheSettledWindow() external {
    // Two gauges (slopes 1 and 29) and their aggregate (slope 30) all decay to zero over the final second
    // before a weekly boundary. Under `scalar = floor(1e18/11)` the raw per-gauge shares round to -1 and +1
    // while the aggregate rounds to 0. A per-gauge zero-clamp would keep only the +1, so the leaf sums to 1
    // while the root chain credits 0 — a one-wei over-credit that strands the final redeem. The sum of the
    // per-gauge shares must stay within the aggregate the root chain credits.
    uint48 _b = 1_787_184_000; // week-aligned boundary (604800 * 2955); the reproducing case from review
    uint256 _scalar = uint256(1e18) / 11;
    vm.warp(_b);

    // Chain fully settled to B, its accumulators reflecting `scalar` over the final second [B-1, B].
    _mockChainAccumulator({_emissionsPerVP: _scalar, _index: _scalar});
    _mockChainTimeIndex(_scalar * (uint256(_b) * _b - uint256(_b - 1) * (_b - 1)));
    _mockChainSettlement(_b);

    uint256 _c1 = _settleExpiringGauge(GAUGE, 1, _b);
    uint256 _c2 = _settleExpiringGauge(_GAUGE_A, 29, _b);
    uint256 _cAggregate = _settleExpiringGauge(_GAUGE_B, 30, _b);

    // it should credit each gauge its exact hand computed share
    // Hand model: over [B-1, B] the weight is the triangle `slope·(B − t)`, so the exact integral is its area
    // `slope·scalar/2`, floored once. With `scalar = 90909090909090909`:
    //   slope 1  ->  floor( 1·90909090909090909 / 2e18) = floor(0.045...) = 0
    //   slope 29 ->  floor(29·90909090909090909 / 2e18) = floor(1.318...) = 1
    //   slope 30 ->  floor(30·90909090909090909 / 2e18) = floor(1.363...) = 1
    assertEq(_c1, 0);
    assertEq(_c2, 1);
    assertEq(_cAggregate, 1);

    // it should keep the sum of the per gauge shares within the aggregate the root chain credits
    assertLe(_c1 + _c2, _cAggregate);
  }

  /// @notice Seed `_gauge` decaying from `_slope` (one second of decay left before `_b`) to zero at boundary
  ///         `_b`, settle it, and return the credited ceiling.
  function _settleExpiringGauge(address _gauge, int128 _slope, uint48 _b) internal returns (uint256 _ceiling) {
    _mockGaugeState(
      _gauge,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _b - 1,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({_bias: _slope, _slope: _slope, _ts: _b - 1, _permanentStakeBalance: 0})
      })
    );
    _mockGaugeSlopeChange(_gauge, _b, _slope);
    _mockEmissionCap(_gauge, type(uint128).max);
    _leafVoter.settleGauge(_gauge);
    _ceiling = _gaugeStateOf(_gauge).ceiling;
  }

  function test_WhenTheChainSunsetsMidwayThroughADecayingGaugesSegment(uint256 _e0, uint48 _splitRaw) external {
    // Sunset regression for the mixed-scalar drift: the flip settles the chain index at `m` and parks the
    // scalar at zero, but the decaying gauge only settles later at `to`. The old average-weight accrual
    // spread the pre-sunset index over the whole [from, to] segment, undercrediting emissions earned before
    // the wind-down; the two-index accrual must credit the exact [from, m] integral and nothing after.
    _e0 = bound(_e0, 1e12, 1e18);
    uint48 _from = _SEED_TIMESTAMP; // deploy time; the window stays inside its week (next boundary is +4 days)
    uint48 _to = _from + 1 days;
    uint48 _m = _from + uint48(bound(_splitRaw, 1 hours, 23 hours)); // sunset flip strictly inside (from, to)
    uint48 _stakeEnd = _from + 2 * _WEEK; // weight stays positive across the window; no slope change fires
    int128 _slope = 1e12; // decay rate; weight at `from` is `slope * (stakeEnd - from)` ~= 1.2e18

    // Live chain accruing at `e0` since deploy, both accumulators and the gauge cursors zeroed at `from`.
    _mockChainAccumulator({_emissionsPerVP: _e0, _index: 0});
    _seedDecayingGauge(_from, _stakeEnd, _slope);

    vm.warp(_m);
    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    // it should settle the chain index at the flip timestamp
    assertEq(_leafVoter.index(), _e0 * (_m - _from));
    assertEq(_leafVoter.lastSettlement(), _m);

    vm.warp(_to);
    _leafVoter.settleGauge(GAUGE);

    // it should credit the exact pre sunset integral and nothing for the post sunset window
    _assertExactPreSunsetAccrual(_slope, _stakeEnd, _from, _m, _to, _e0);
  }

  function test_WhenTheGaugeSettlesImmediatelyBeforeTheSunsetAndAgainAfterward(uint256 _e0, uint48 _splitRaw) external {
    // Cadence-invariance twin of the settle-once sunset regression: settling at the flip and again afterward
    // must land on the same pre-sunset accrual a single late settle credits, with the post-sunset settle
    // adding exactly nothing.
    _e0 = bound(_e0, 1e12, 1e18);
    uint48 _from = _SEED_TIMESTAMP;
    uint48 _to = _from + 1 days;
    uint48 _m = _from + uint48(bound(_splitRaw, 1 hours, 23 hours));
    uint48 _stakeEnd = _from + 2 * _WEEK;
    int128 _slope = 1e12;

    _mockChainAccumulator({_emissionsPerVP: _e0, _index: 0});
    _seedDecayingGauge(_from, _stakeEnd, _slope);

    vm.warp(_m);
    _leafVoter.settleGauge(GAUGE);
    uint128 _ceilingAtFlip = _gaugeStateOf(GAUGE).ceiling;

    vm.prank(_CHAIN_STATUS);
    _leafVoter.setChainStatus(IVoterCommon.ChainStatus.Sunset);

    vm.warp(_to);
    _leafVoter.settleGauge(GAUGE);

    // it should credit nothing on the post sunset settle
    assertEq(_gaugeStateOf(GAUGE).ceiling, _ceilingAtFlip);

    // it should credit the same exact pre sunset integral
    _assertExactPreSunsetAccrual(_slope, _stakeEnd, _from, _m, _to, _e0);
  }

  /// @notice The gauge ceiling equals the exact [from, m] trapezoid integral at `e0` with nothing for the
  ///         zero-scalar sunset tail [m, to]. Split out to keep the fuzz tests in stack budget.
  function _assertExactPreSunsetAccrual(
    int128 _slope,
    uint48 _stakeEnd,
    uint48 _from,
    uint48 _m,
    uint48 _to,
    uint256 _e0
  ) internal {
    uint256 _wFrom = uint128(_slope * int128(uint128(_stakeEnd - _from)));
    uint256 _wM = uint128(_slope * int128(uint128(_stakeEnd - _m)));
    uint256 _wTo = uint128(_slope * int128(uint128(_stakeEnd - _to)));
    uint256 _exact = (_wFrom + _wM) * (_e0 * (_m - _from)) / (2 * _PRECISION);

    // The old average-weight formula prices the whole segment at `avg(w_from, w_to) * indexDelta`, averaging
    // in the zero-scalar sunset tail. It must undercredit by far more than the rounding tolerance, or the
    // test would pass on the pre-fix code too and guard nothing.
    uint256 _oldMisprice = (_wFrom + _wTo) * (_e0 * (_m - _from)) / (2 * _PRECISION);
    assertGt(_exact - _oldMisprice, 4);

    assertApproxEqAbs(_gaugeStateOf(GAUGE).ceiling, _exact, 4);
  }
}
