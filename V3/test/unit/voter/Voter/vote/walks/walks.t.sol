// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterVoteWalks is BaseVoter {
  function test_WhenTheWalkWindowStaysWithinASingleWeek() external givenCallerIsAuthorized {
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _chainPointTs = _tAct - 2 hours;
    uint48 _totalPointTs = _tAct - 1 hours; // chain <= total
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_000_047_564_569_250_000, // _SLOPE_ONE_AERO * (_stakeEnd - _chainPointTs)
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 2_000_038_051_512_936_000, // 2 * _SLOPE_ONE_AERO * (_stakeEnd - _totalPointTs)
      _totalSlope: 2 * _SLOPE_ONE_AERO,
      _totalPerm: 0,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should decay chain point bias by slope times the partial week delta
    // chain expected = _chainBias - _chainSlope * 2 hours = 999_990_486_943_686_000
    // total expected = _totalBias - _totalSlope * 1 hours = 1_999_980_973_887_372_000
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 999_990_486_943_686_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 1_999_980_973_887_372_000, _slope: 2 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }

  function test_WhenTheWalkCrossesASingleWeekBoundaryWithAScheduledSlopeReduction() external givenCallerIsAuthorized {
    uint48 _boundary = _INITIAL_TIMESTAMP + _WEEK; // start of week 2923, first crossable boundary
    uint48 _chainPointTs = _boundary - 2 hours;
    uint48 _totalPointTs = _boundary - 1 hours; // chain <= total
    uint48 _tAct = _boundary + 2 hours;
    uint48 _ts = _tAct; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // Pre-state: chain has tokenId + 1 ghost (ending at _boundary). Total has 2 such pairs.
    int128 _chainSlope = 2 * _SLOPE_ONE_AERO;
    int128 _totalSlope = 2 * _chainSlope; // = 4 * _SLOPE_ONE_AERO
    int128 _slopeReduction = _SLOPE_ONE_AERO; // same reduction applied to both sides at _boundary

    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_994_634_702_959_544_000, // _chainSlope * (_stakeEnd - _chainPointTs)
      _chainSlope: _chainSlope,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 3_989_155_250_667_960_000, // _totalSlope * (_stakeEnd - _totalPointTs)
      _totalSlope: _totalSlope,
      _totalPerm: 0,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });
    _mockChainSlopeChange(_CHAIN_ID_1, _boundary, _slopeReduction);
    _mockTotalSlopeChange(_boundary, _slopeReduction);

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should decay bias up to the boundary at the pre boundary slope
    // it should reduce slope by the scheduled reduction at the boundary
    // it should decay the trailing partial week with the post boundary slope
    // chain: bias = _chainBias - _chainSlope * 2 hours - (_chainSlope - _slopeReduction) * 2 hours
    //             = 1_994_463_470_082_852_000;   slope = _chainSlope - _slopeReduction = _SLOPE_ONE_AERO
    // total: bias = _totalBias - _totalSlope * 1 hours - (_totalSlope - _slopeReduction) * 2 hours
    //             = 3_988_869_862_540_140_000;   slope = _totalSlope - _slopeReduction = 3 * _SLOPE_ONE_AERO
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 1_994_463_470_082_852_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 3_988_869_862_540_140_000, _slope: 3 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }

  function test_WhenTheWalkCrossesMultipleWeekBoundaries() external givenCallerIsAuthorized {
    uint48 _boundary1 = _INITIAL_TIMESTAMP + _WEEK; // first crossable boundary
    uint48 _boundary2 = _INITIAL_TIMESTAMP + 2 * _WEEK; // second
    uint48 _chainPointTs = _boundary1 - 2 hours;
    uint48 _totalPointTs = _boundary1 - 1 hours; // chain <= total
    uint48 _tAct = _boundary2 + 2 hours;
    uint48 _ts = _tAct; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_894_233_600; // week-aligned, <= _tAct + _MAXTIME

    // Asymmetric reductions (R1 != R2) so any out-of-chronological-order processing
    // produces a different final state.
    int128 _chainSlope = 5 * _SLOPE_ONE_AERO; // enough headroom for R1 + R2 + swap_contrib
    int128 _totalSlope = 10 * _SLOPE_ONE_AERO; // 2 * _chainSlope
    int128 _reduction1 = _SLOPE_ONE_AERO; // smaller, at B1
    int128 _reduction2 = 2 * _SLOPE_ONE_AERO; // bigger, at B2

    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 5_010_559_360_135_740_000, // _chainSlope * (_stakeEnd - _chainPointTs)
      _chainSlope: _chainSlope,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 10_020_833_332_143_660_000, // _totalSlope * (_stakeEnd - _totalPointTs)
      _totalSlope: _totalSlope,
      _totalPerm: 0,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });
    _mockChainSlopeChange(_CHAIN_ID_1, _boundary1, _reduction1);
    _mockChainSlopeChange(_CHAIN_ID_1, _boundary2, _reduction2);
    _mockTotalSlopeChange(_boundary1, _reduction1);
    _mockTotalSlopeChange(_boundary2, _reduction2);

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should apply each scheduled reduction in chronological order
    // chain: 5S * 2 hours + 4S * WEEK + 2S * 2 hours decay; final slope = 5S - S - 2S = 2S
    //        exp_bias = 4_990_981_734_567_288_000
    // total: 10S * 1 hours + 9S * WEEK + 7S * 2 hours decay; final slope = 10S - S - 2S = 7S
    //        exp_bias = 9_976_997_715_710_508_000
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 4_990_981_734_567_288_000,
      _slope: 2 * _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 9_976_997_715_710_508_000, _slope: 7 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }

  function test_WhenBiasWouldUnderflowDuringTheWalk() external givenCallerIsAuthorized {
    // Defensive clamp: balanced slope schedules make this state unreachable in production.
    // Test pins WGT-1 (bias >= 0 after resolution) by forcing the `_max(_bias - _decay, 0)` path.
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _chainPointTs = _tAct - 2 hours;
    uint48 _totalPointTs = _tAct - 1 hours; // chain <= total

    // Permanent stake makes the contribution `(0, 0, _allocated)` so the swap touches only
    // `perm` and leaves chain.bias / chain.slope alone. chain.perm pre-state must be >=
    // _allocated so the removal's `perm -= _allocated` doesn't underflow.
    // Pre-walk bias is tiny (1 wei) and slope is non-trivial, so `slope * delta` overshoots
    // and the walk clamps bias to zero.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1, // tiny; slope * 2 hours = 57_077_625_564_000 >> 1
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: _ONE_AERO,
      _chainPointTs: _chainPointTs,
      _totalBias: 1,
      _totalSlope: 2 * _SLOPE_ONE_AERO,
      _totalPerm: _ONE_AERO,
      _totalPointTs: _totalPointTs,
      _stakeEnd: 0, // ignored when _isPermanent
      _isPermanent: true
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should clamp bias at zero
    // chain: walk decay (_SLOPE_ONE_AERO * 2 hours) >> 1, so max(0, 1 - decay) = 0.
    //        slope unchanged (no reductions in scope). Permanent delta = 1 adds 1 wei to perm.
    // total: walk decay (2 * _SLOPE_ONE_AERO * 1 hours) >> 1, same clamp.
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: 0, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: _ONE_AERO + 1
    });
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 2 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: _ONE_AERO + 1});
  }

  function test_WhenSlopeWouldUnderflowAtABoundary() external givenCallerIsAuthorized {
    // Defensive clamp: balanced slope schedules make this state unreachable in production.
    // Test pins WGT-2 (slope >= 0 in any resolved point) by forcing the `_max(_slope - r, 0)` path.
    uint48 _boundary = _INITIAL_TIMESTAMP + _WEEK;
    uint48 _chainPointTs = _boundary - 2 hours;
    uint48 _totalPointTs = _boundary - 1 hours; // chain <= total
    uint48 _tAct = _boundary + 2 hours;
    uint48 _ts = _tAct; // root anchors settlement at block.timestamp

    // Permanent stake again: swap touches only perm, leaves bias/slope alone (see test 4).
    // Each side's reduction at _boundary exceeds its slope, so the walk clamps slope to 0.
    // Pre-walk bias is sized > slope * 2 hours so the bias-clamp (test 4's case) does not fire here.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 114_155_251_128_000, // = _chainSlope * 4 hours; safely > pre-boundary decay
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: _ONE_AERO,
      _chainPointTs: _chainPointTs,
      _totalBias: 228_310_502_256_000, // = _totalSlope * 4 hours
      _totalSlope: 2 * _SLOPE_ONE_AERO,
      _totalPerm: _ONE_AERO,
      _totalPointTs: _totalPointTs,
      _stakeEnd: 0, // ignored when _isPermanent
      _isPermanent: true
    });
    _mockChainSlopeChange(_CHAIN_ID_1, _boundary, 2 * _SLOPE_ONE_AERO); // > chain slope
    _mockTotalSlopeChange(_boundary, 4 * _SLOPE_ONE_AERO); // > total slope

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should clamp slope at zero
    // chain: decay pre-boundary = _SLOPE_ONE_AERO * 2 hours = 57_077_625_564_000.
    //        slope clamps to 0 at boundary; post-boundary decay = 0.
    //        exp_bias = 114_155_251_128_000 - 57_077_625_564_000 = 57_077_625_564_000.
    // total: decay pre-boundary = 2 * _SLOPE_ONE_AERO * 1 hours = 57_077_625_564_000.
    //        slope clamps to 0; post-boundary decay = 0.
    //        exp_bias = 228_310_502_256_000 - 57_077_625_564_000 = 171_232_876_692_000.
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: 57_077_625_564_000, _slope: 0, _ts: _tAct, _perm: _ONE_AERO + 1
    });
    _assertTotalPoint({_target: _voter, _bias: 171_232_876_692_000, _slope: 0, _ts: _tAct, _perm: _ONE_AERO + 1});
  }

  function test_WhenTheChainPointTimestampIsAlreadyAtBlockTimestamp() external givenCallerIsAuthorized {
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // chainPoint.ts == _tAct exercises the `if (_point.ts == _ts) return;` early-exit in
    // `_resolveChainWeight` (and the parallel one in `_resolveTotalWeight`). Both ts values
    // equal _tAct here, satisfying chain.ts <= total.ts trivially.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 999_990_486_943_686_000, // _SLOPE_ONE_AERO * (_stakeEnd - _tAct)
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: 0,
      _chainPointTs: _tAct,
      _totalBias: 1_999_980_973_887_372_000, // 2 * _SLOPE_ONE_AERO * (_stakeEnd - _tAct)
      _totalSlope: 2 * _SLOPE_ONE_AERO,
      _totalPerm: 0,
      _totalPointTs: _tAct,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should leave the chain point bias slope and timestamp unchanged
    // Walk early-exits because chainPoint.ts == _tAct. Swap removes and re-adds the same
    // contribution (same stake shape, same amount) so chain/total state ends == pre-state.
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 999_990_486_943_686_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 1_999_980_973_887_372_000, _slope: 2 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }

  function test_WhenThePointHasANonZeroPermanentBalanceAndTheWalkRuns() external givenCallerIsAuthorized {
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _chainPointTs = _tAct - 2 hours;
    uint48 _totalPointTs = _tAct - 1 hours; // chain <= total
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // Non-permanent stake here so the walk has decay work to do. The point's `perm` field
    // represents some *other* (ghost) permanent voter's contribution to the chain. Our
    // tokenId's swap contribution is non-permanent (`perm = 0`) so it never touches perm.
    // Distinct chain vs total perm catches a routing bug that reads the wrong slot.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_000_047_564_569_250_000, // _SLOPE_ONE_AERO * (_stakeEnd - _chainPointTs)
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: _ONE_AERO,
      _chainPointTs: _chainPointTs,
      _totalBias: 2_000_038_051_512_936_000, // 2 * _SLOPE_ONE_AERO * (_stakeEnd - _totalPointTs)
      _totalSlope: 2 * _SLOPE_ONE_AERO,
      _totalPerm: 2 * _ONE_AERO,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should leave permanent stake balance unchanged by the walk
    // Bias/slope decay normally; perm is copied through unchanged (see `_walkPoint`'s final
    // Point assignment). The non-permanent swap contributes 0 to perm, preserving the seed.
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 999_990_486_943_686_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: _ONE_AERO
    });
    _assertTotalPoint({
      _target: _voter, _bias: 1_999_980_973_887_372_000, _slope: 2 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 2 * _ONE_AERO
    });
  }

  function test_WhenTotalPointAndChainPointHaveSeparateSlopeReductionsAtTheSameBoundary()
    external
    givenCallerIsAuthorized
  {
    uint48 _boundary = _INITIAL_TIMESTAMP + _WEEK;
    uint48 _chainPointTs = _boundary - 2 hours;
    uint48 _totalPointTs = _boundary - 1 hours; // chain <= total
    uint48 _tAct = _boundary + 2 hours;
    uint48 _ts = _tAct; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // The point of this test: chain and total receive DIFFERENT slope reductions at the same
    // boundary. A routing bug that reads `chainSlopeChanges` for the total walk (or vice
    // versa) would apply the wrong reduction on one side and the assertions catch it.
    int128 _chainSlope = 2 * _SLOPE_ONE_AERO;
    int128 _totalSlope = 5 * _SLOPE_ONE_AERO;
    int128 _chainReduction = _SLOPE_ONE_AERO; // chain drops by 1 SLOPE
    int128 _totalReduction = 3 * _SLOPE_ONE_AERO; // total drops by 3 SLOPE

    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_994_634_702_959_544_000, // _chainSlope * (_stakeEnd - _chainPointTs)
      _chainSlope: _chainSlope,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 4_986_444_063_334_950_000, // _totalSlope * (_stakeEnd - _totalPointTs)
      _totalSlope: _totalSlope,
      _totalPerm: 0,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });
    _mockChainSlopeChange(_CHAIN_ID_1, _boundary, _chainReduction);
    _mockTotalSlopeChange(_boundary, _totalReduction);

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should apply the chain slope reduction using chainSlopeChanges
    // it should apply the totalPoint slope reduction using totalSlopeChanges
    // chain: bias = _chainBias - _chainSlope * 2 hours - (_chainSlope - _chainReduction) * 2 hours
    //             = 1_994_463_470_082_852_000;   slope = _chainSlope - _chainReduction = _SLOPE_ONE_AERO
    // total: bias = _totalBias - _totalSlope * 1 hours - (_totalSlope - _totalReduction) * 2 hours
    //             = 4_986_187_214_019_912_000;   slope = _totalSlope - _totalReduction = 2 * _SLOPE_ONE_AERO
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 1_994_463_470_082_852_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 4_986_187_214_019_912_000, _slope: 2 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }

  function test_WhenBlockTimestampLandsExactlyOnAWeekBoundary() external givenCallerIsAuthorized {
    // Walk loop condition is `_nextExpiry <= _ts`, so when block.timestamp itself is a boundary the
    // iteration at that boundary fires (decay + slope reduction), then `cursor = boundary = _ts`
    // and the trailing `if (_ts > _cursor)` block is skipped.
    uint48 _tAct = _INITIAL_TIMESTAMP + _WEEK; // week-aligned
    uint48 _chainPointTs = _tAct - 2 hours;
    uint48 _totalPointTs = _tAct - 1 hours; // chain <= total
    uint48 _ts = _tAct; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    int128 _chainSlope = 2 * _SLOPE_ONE_AERO;
    int128 _totalSlope = 4 * _SLOPE_ONE_AERO;
    int128 _slopeReduction = _SLOPE_ONE_AERO; // same on both sides; routing isn't the focus here

    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_994_634_702_959_544_000, // _chainSlope * (_stakeEnd - _chainPointTs)
      _chainSlope: _chainSlope,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 3_989_155_250_667_960_000, // _totalSlope * (_stakeEnd - _totalPointTs)
      _totalSlope: _totalSlope,
      _totalPerm: 0,
      _totalPointTs: _totalPointTs,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });
    _mockChainSlopeChange(_CHAIN_ID_1, _tAct, _slopeReduction);
    _mockTotalSlopeChange(_tAct, _slopeReduction);

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      // delta = 1 wei: bias/slope no-op (floor unchanged); observes the WALK only
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should apply the boundary slope reduction
    // it should skip the trailing partial decay
    // chain: bias = _chainBias - _chainSlope * 2 hours = 1_994_520_547_708_416_000.
    //        slope = _chainSlope - _slopeReduction = _SLOPE_ONE_AERO.  No trailing decay applied.
    // total: bias = _totalBias - _totalSlope * 1 hours = 3_989_041_095_416_832_000.
    //        slope = _totalSlope - _slopeReduction = 3 * _SLOPE_ONE_AERO.
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: 1_994_520_547_708_416_000,
      _slope: _SLOPE_ONE_AERO,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: 3_989_041_095_416_832_000, _slope: 3 * _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });
  }
}
