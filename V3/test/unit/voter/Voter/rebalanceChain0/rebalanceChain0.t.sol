// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter, IVoter, Voter} from 'V3-test/unit/voter/BaseVoter.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVoterRebalanceChain0 is BaseVoter {
  // Shared point-math seeds. _DIFF_PRE_BIAS / _DIFF_POST_BIAS are _SLOPE_ONE_AERO * (stakeEnd - tAct)
  // at stakeEnd = tAct + {4, 8} weeks — hardcoded anchors per the V2-style literal-with-formula pattern.
  uint128 internal constant _DIFF_AMOUNT = _ONE_AERO;
  uint128 internal constant _DIFF_SRC_ALLOC = 100 * _ONE_AERO;
  uint128 internal constant _DIFF_DST_ALLOC = 50 * _ONE_AERO;
  uint48 internal constant _DIFF_DST_LAST_VOTED_INIT = _INITIAL_TIMESTAMP - 1;
  int128 internal constant _DIFF_PRE_BIAS = 19_178_082_189_504_000; // _SLOPE_ONE_AERO * 4 weeks
  int128 internal constant _DIFF_POST_BIAS = 38_356_164_379_008_000; // _SLOPE_ONE_AERO * 8 weeks
  int128 internal constant _SLOPE_ONE_AERO_WEEK = 4_794_520_547_376_000; // _SLOPE_ONE_AERO * 1 week
  // Per-amount slopes (`amount / MAXTIME`, floored), hand-computed independently of `_slopeOf` so a coordinated
  // change to the production formula cannot make the implementation and this expectation agree on a wrong value.
  // Not `n * _SLOPE_ONE_AERO`: the floor is taken on the whole amount, which differs from summing per-AERO floors.
  int128 internal constant _DIFF_SRC_SLOPE = 792_744_799_594; // 100e18 / 126_144_000
  int128 internal constant _DIFF_DST_SLOPE = 396_372_399_797; // 50e18 / 126_144_000
  int128 internal constant _DIFF_SRC_SLOPE_AFTER = 784_817_351_598; // 99e18 / 126_144_000
  int128 internal constant _DIFF_DST_SLOPE_AFTER = 404_299_847_792; // 51e18 / 126_144_000
  // Distinctive non-zero pre-state GLOBAL emissionsPerVP scalar; the post-batch refresh overwrites it,
  // so the index advance proves the elapsed interval integrated the pre-state value.
  uint256 internal constant _DIFF_EPPVP_INIT = 12_345;

  // Multi-leg seeds. All legs are permanent so the point math is exact (no slope truncation):
  // sources drain `permanentStakeBalance`, destinations refill it. tokenIds 3/4 are the destinations.
  uint256 internal constant _DST_A = 3;
  uint256 internal constant _DST_B = 4;
  uint128 internal constant _MULTI_CHAIN0_PERM = 300 * _ONE_AERO;
  uint128 internal constant _MULTI_TOTAL_PERM = 600 * _ONE_AERO;
  uint256 internal constant _MULTI_EPPVP_INIT = 12_345; // distinctive global scalar; the refresh overwrites it

  /*////////////////////////////////////////////////////////////
                          DELTA BUILDERS
  ////////////////////////////////////////////////////////////*/
  function _legs(
    uint256 _tokenId,
    uint128 _amount
  ) internal pure returns (IVotingEscrow.DestinationDelta[] memory _arr) {
    _arr = new IVotingEscrow.DestinationDelta[](1);
    _arr[0] = IVotingEscrow.DestinationDelta({tokenId: _tokenId, amount: _amount, recipient: address(0)});
  }

  function _noLegs() internal pure returns (IVotingEscrow.DestinationDelta[] memory _arr) {
    _arr = new IVotingEscrow.DestinationDelta[](0);
  }

  function _srcLegs(uint256 _tokenId, uint128 _amount) internal pure returns (IVotingEscrow.SourceDelta[] memory _arr) {
    _arr = new IVotingEscrow.SourceDelta[](1);
    _arr[0] = IVotingEscrow.SourceDelta({tokenId: _tokenId, amount: _amount});
  }

  function _noSrcLegs() internal pure returns (IVotingEscrow.SourceDelta[] memory _arr) {
    _arr = new IVotingEscrow.SourceDelta[](0);
  }

  /// @dev Expected chain0 ceiling for the DIFF scenario: one segment of the combined position decaying at
  ///      `_DIFF_SRC_SLOPE + _DIFF_DST_SLOPE` against the constant pre-state scalar over `_window`. The index
  ///      growth (`_DIFF_EPPVP_INIT * _window`) times the average of the window's start and end weight (`_preBias`
  ///      end, `_preBias + slope * window` start). The scenario constants live inside so the caller passes only two
  ///      values, keeping the test body within the legacy codegen stack limit.
  function _expectedDiffCeiling(int128 _preBias, uint48 _window) internal pure returns (uint256 _ceiling) {
    uint256 _startPlusEnd =
      2 * uint256(uint128(_preBias)) + uint256(uint128(_DIFF_SRC_SLOPE + _DIFF_DST_SLOPE)) * _window;
    _ceiling = _startPlusEnd * _DIFF_EPPVP_INIT * _window / (2 * _PRECISION);
  }

  /*////////////////////////////////////////////////////////////
                       PRECONDITION REVERTS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheCallerIsNotTheVotingEscrow(address _caller) external {
    // Caller is the only fuzzed input — the assertion is "any non-VotingEscrow caller reverts".
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTING_ESCROW);

    vm.prank(_caller);
    // it should revert with NotVotingEscrow
    vm.expectRevert(IVoter.NotVotingEscrow.selector);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, 1), _legs(_TOKEN_ID_2, 1));
  }

  function test_WhenBothSourceAndDestinationArraysAreEmpty(uint48 _ts) external {
    // Empty batch → early return before any state read. Seed distinctive global state so the
    // unchanged-assertions are non-vacuous; the point ts is arbitrary because no resolve runs.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max));
    vm.warp(_ts);
    _mockChainPoint({_chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _INITIAL_TIMESTAMP, _perm: 500 ether});
    _mockTotalPoint({_bias: 7e18, _slope: 5e9, _ts: _INITIAL_TIMESTAMP, _perm: 800 ether});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_noSrcLegs(), _noLegs());

    // it should leave the chain zero point unchanged
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _INITIAL_TIMESTAMP, _perm: 500 ether
    });
    // it should leave totalPoint unchanged
    _assertTotalPoint({_target: _voter, _bias: 7e18, _slope: 5e9, _ts: _INITIAL_TIMESTAMP, _perm: 800 ether});
  }

  function test_WhenASourceAmountExceedsItsChainZeroAllocation(uint128 _amount, uint128 _existing) external {
    // Bound `_amount > 0`; `_existing < _amount` is the revert condition. Settle/resolve run before the
    // source loop, so the chain0 point is seeded at _tAct to keep `_resolveWeight` a no-op.
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _existing = uint128(bound(_existing, 0, _amount - 1));
    uint48 _tAct = uint48(block.timestamp); // root anchors settlement at block.timestamp

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _existing});

    vm.prank(_VOTING_ESCROW);
    // it should revert with InsufficientChain0Allocation
    vm.expectRevert(IVoter.InsufficientChain0Allocation.selector);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _noLegs());
  }

  function test_WhenADestinationHasVotedAndItsStoredStakeEndDiffersFromTheLiveStakeEnd(
    uint48 _storedDstStakeEnd,
    uint48 _liveDstStakeEnd
  ) external {
    // Source loop is empty; the destination has voted (chain set non-empty) with `stored != live`.
    // Fuzz both ends with `stored != live` to catch direction-flipped bugs (`>` / `<` instead of `!=`).
    uint48 _tAct = uint48(block.timestamp); // root anchors settlement at block.timestamp
    _liveDstStakeEnd = uint48(bound(_liveDstStakeEnd, 1, type(uint48).max));
    vm.assume(_storedDstStakeEnd != _liveDstStakeEnd);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID_2, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID_2, _committed: 0, _lastStakeEnd: _storedDstStakeEnd, _lastAllocated: 0});
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 1, _end: _liveDstStakeEnd, _isPermanent: false});

    vm.prank(_VOTING_ESCROW);
    // it should revert with DstShapeStale
    vm.expectRevert(IVoter.DstShapeStale.selector);
    _voter.rebalanceChain0(_noSrcLegs(), _legs(_TOKEN_ID_2, 1));
  }

  /*////////////////////////////////////////////////////////////
                        BATCH MATH (SINGLE LEG)
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheBatchMovesAllocationBetweenDifferingStakeEnds(uint48 _ts, uint48 _pendingWindow) external {
    // One source → one destination at differing stakeEnds. Pre-state books both whole positions coherently:
    // src 100 AERO at _srcStakeEnd, dst 50 AERO at _dstStakeEnd, each point carrying `contribution(total)`.
    // The batch moves _DIFF_AMOUNT, so each leg swaps its position to the new total at its own stakeEnd.
    // The pending settlement window is bounded: the global settle banks the index one week boundary at a
    // time, so an unbounded gap would be millions of iterations. 8 weeks crosses several.
    _pendingWindow = uint48(bound(_pendingWindow, 1, 8 weeks));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 8 weeks, type(uint48).max - 8 weeks));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _srcStakeEnd = _tAct + 4 weeks;
    uint48 _dstStakeEnd = _tAct + 8 weeks;
    vm.warp(_ts);

    // Coherent seeds and expected swap results. Slopes are hand-computed literals (the `_DIFF_*_SLOPE`
    // constants), not derived through `_slopeOf`, so the expectation is independent of the production formula.
    int128 _srcSlope = _DIFF_SRC_SLOPE;
    int128 _dstSlope = _DIFF_DST_SLOPE;
    int128 _srcSlopeAfter = _DIFF_SRC_SLOPE_AFTER;
    int128 _dstSlopeAfter = _DIFF_DST_SLOPE_AFTER;
    int128 _preBias = _srcSlope * int128(uint128(4 weeks)) + _dstSlope * int128(uint128(8 weeks));
    int128 _postBias = _srcSlopeAfter * int128(uint128(4 weeks)) + _dstSlopeAfter * int128(uint128(8 weeks));

    // Src state.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _DIFF_SRC_ALLOC});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _DIFF_SRC_ALLOC, _lastStakeEnd: _srcStakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});

    // Dst state: has voted; stored stakeEnd matches live → no DstShapeStale.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID_2, _chainId: _CHAIN0, _amount: _DIFF_DST_ALLOC});
    _mockTokenState({
      _tokenId: _TOKEN_ID_2,
      _committed: _DIFF_DST_ALLOC,
      _lastStakeEnd: _dstStakeEnd,
      _lastAllocated: _DIFF_DST_LAST_VOTED_INIT
    });
    _mockExistingChainIds({_tokenId: _TOKEN_ID_2, _chainIds: _singletonArray(_CHAIN0)});
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: _DIFF_DST_ALLOC, _end: _dstStakeEnd, _isPermanent: false});

    // Chain0 / totalPoint seeded with both whole positions. Points at _tAct ⇒ _resolveWeight no-ops.
    _mockChainPoint({_chainId: _CHAIN0, _bias: _preBias, _slope: _srcSlope + _dstSlope, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _preBias, _slope: _srcSlope + _dstSlope, _ts: _tAct, _perm: 0});
    _mockChainSlopeChange(_CHAIN0, _srcStakeEnd, _srcSlope);
    _mockChainSlopeChange(_CHAIN0, _dstStakeEnd, _dstSlope);
    _mockTotalSlopeChange(_srcStakeEnd, _srcSlope);
    _mockTotalSlopeChange(_dstStakeEnd, _dstSlope);
    // Pre-state accrual lives on the GLOBAL scalar + settlement anchor; CHAIN0's cursors are still the
    // constructor defaults (`lastIndex == 0 == index`, `lastTimeIndex == 0 == timeIndex`), so the whole pending
    // window is unintegrated.
    _mockEmissionsPerVP(_DIFF_EPPVP_INIT);
    _mockLastGlobalSettlement(_ts - _pendingWindow);
    _mockChainLastIndex(_CHAIN0, 0);
    _mockChainLastTimeIndex(_CHAIN0, 0);

    IVotingEscrow.SourceDelta[] memory _sources = _srcLegs(_TOKEN_ID, _DIFF_AMOUNT);
    IVotingEscrow.DestinationDelta[] memory _destinations = _legs(_TOKEN_ID_2, _DIFF_AMOUNT);

    // it should emit the Chain zero Rebalanced event
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.Chain0Rebalanced(_sources, _destinations);

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_sources, _destinations);

    // it should advance the global index to T act
    // index = emissionsPerVP_pre * dt, dt == the pending window.
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_voter.index(), _DIFF_EPPVP_INIT * _pendingWindow);

    // it should settle the chain zero ceiling to T act
    // The point sits at _tAct, so the ceiling is one segment spanning the pending window at a DECAYING weight
    // (combined slope _srcSlope + _dstSlope, perm 0) against the constant pre-state scalar. The exact integral
    // credits the average of the window's start and end weight: end weight is the seeded bias (_preBias), start
    // weight is end + slope*window. Independent of the contract's timeIndex math.
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
    // Within one wei of the exact average: the two-index accrual floors both terms, so it credits at most a wei
    // below the real integral (conservative, never over root).
    assertApproxEqAbs(_chainState(_voter, _CHAIN0).ceiling, _expectedDiffCeiling(_preBias, _pendingWindow), 1);

    // it should resolve the chain zero point to T act
    // Each leg swaps its whole position to the new total at its own stakeEnd.
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN0,
      _bias: _postBias,
      _slope: _srcSlopeAfter + _dstSlopeAfter,
      _ts: _tAct,
      _perm: 0
    });
    // it should remove the source contribution from the chain zero point at the source stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _srcStakeEnd), _srcSlopeAfter);
    // it should add the destination contribution to the chain zero point at the destination stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _dstStakeEnd), _dstSlopeAfter);

    // it should resolve totalPoint to T act
    _assertTotalPoint({
      _target: _voter, _bias: _postBias, _slope: _srcSlopeAfter + _dstSlopeAfter, _ts: _tAct, _perm: 0
    });
    // it should remove the source contribution from totalPoint at the source stake end
    assertEq(_voter.totalSlopeChanges(_srcStakeEnd), _srcSlopeAfter);
    // it should add the destination contribution to totalPoint at the destination stake end
    assertEq(_voter.totalSlopeChanges(_dstStakeEnd), _dstSlopeAfter);

    // it should recompute the global emissions per VP against the new totalWeight
    // Global scalar = mulDiv(MINTER_RATE, PRECISION, weightOf(total)_post); post totalWeight == _postBias.
    assertEq(_voter.emissionsPerVP(), uint256(_MINTER_RATE) * _PRECISION / uint128(_postBias));

    // it should decrement committed on the source by the amount
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID,
      _committed: _DIFF_SRC_ALLOC - _DIFF_AMOUNT,
      _lastStakeEnd: _srcStakeEnd,
      _lastAllocated: 0
    });
    // it should decrement allocationChainAmounts for the source on chain zero by the amount
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _DIFF_SRC_ALLOC - _DIFF_AMOUNT);

    // it should increment committed on the destination by the amount
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID_2,
      _committed: _DIFF_DST_ALLOC + _DIFF_AMOUNT,
      _lastStakeEnd: _dstStakeEnd,
      _lastAllocated: _DIFF_DST_LAST_VOTED_INIT
    });
    // it should increment allocationChainAmounts for the destination on chain zero by the amount
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), _DIFF_DST_ALLOC + _DIFF_AMOUNT);
  }

  /*////////////////////////////////////////////////////////////
                       BATCH (MULTIPLE LEGS)
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheBatchHasMultipleSourcesAndDestinations(uint48 _ts, uint48 _pendingWindow) external {
    // Two sources, two destinations, all permanent so the perm math is exact. Sources drain the chain0 /
    // total `permanentStakeBalance`, destinations refill it. Σout == Σin so both points net unchanged,
    // letting the rate assertion (recompute ran) and the per-token ledger deltas stay deterministic.
    // The pending settlement window is bounded: the global settle banks the index one week boundary at a
    // time, so an unbounded gap would be millions of iterations. 8 weeks crosses several. The upper bound
    // reserves a week of headroom so the boundary cursor stays inside `uint48`.
    _pendingWindow = uint48(bound(_pendingWindow, 1, 8 weeks));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 8 weeks, type(uint48).max - _WEEK));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    vm.warp(_ts);

    // Sources (permanent, lastStakeEnd 0). S_A drains 30, S_B drains 70.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 100 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: 100 * _ONE_AERO});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID_2, _committed: 200 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID_2, _chainId: _CHAIN0, _amount: 200 * _ONE_AERO});
    _mockExistingChainIds({_tokenId: _TOKEN_ID_2, _chainIds: _singletonArray(_CHAIN0)});

    // Destinations. D_A has voted permanent (stored lastStakeEnd 0 matches live) and gains 40; D_B is a
    // first-time permanent recipient gaining 60.
    _mockTokenState({_tokenId: _DST_A, _committed: 50 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 7});
    _mockAllocationChainAmount({_tokenId: _DST_A, _chainId: _CHAIN0, _amount: 50 * _ONE_AERO});
    _mockExistingChainIds({_tokenId: _DST_A, _chainIds: _singletonArray(_CHAIN0)});
    _mockStakedFor({_tokenId: _DST_A, _amount: 0, _end: 0, _isPermanent: true});
    _mockStakedFor({_tokenId: _DST_B, _amount: 0, _end: 0, _isPermanent: true});

    // Global state: permanent balances large enough to absorb the source drains without underflow.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _MULTI_CHAIN0_PERM});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _MULTI_TOTAL_PERM});
    _mockEmissionsPerVP(_MULTI_EPPVP_INIT);
    _mockLastGlobalSettlement(_ts - _pendingWindow);
    _mockChainLastIndex(_CHAIN0, 0);

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID, amount: 30 * _ONE_AERO});
    _sources[1] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID_2, amount: 70 * _ONE_AERO});
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta({tokenId: _DST_A, amount: 40 * _ONE_AERO, recipient: address(0)});
    _destinations[1] = IVotingEscrow.DestinationDelta({tokenId: _DST_B, amount: 60 * _ONE_AERO, recipient: address(0)});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_sources, _destinations);

    // it should settle the chain zero ceiling once
    // accrual = weightOf(chain0)_pre * emissionsPerVP_pre * dt / PRECISION; pre chain0 weight is
    // its permanent balance (_MULTI_CHAIN0_PERM, bias 0) so the ceiling walk never decays,
    // dt == the pending window.
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_voter.index(), _MULTI_EPPVP_INIT * _pendingWindow);
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
    assertEq(
      _chainState(_voter, _CHAIN0).ceiling,
      uint256(_MULTI_CHAIN0_PERM) * _MULTI_EPPVP_INIT * _pendingWindow / _PRECISION
    );

    // it should decrement committed and chain zero allocation on every source
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 70 * _ONE_AERO);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), 130 * _ONE_AERO);
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: 70 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 0
    });
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID_2, _committed: 130 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 0
    });

    // it should increment committed and chain zero allocation on every destination
    assertEq(_voter.allocationChainAmounts(_DST_A, _CHAIN0), 90 * _ONE_AERO);
    assertEq(_voter.allocationChainAmounts(_DST_B, _CHAIN0), 60 * _ONE_AERO);
    _assertTokenState({
      _target: _voter, _tokenId: _DST_A, _committed: 90 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 7
    });
    _assertTokenState({
      _target: _voter, _tokenId: _DST_B, _committed: 60 * _ONE_AERO, _lastStakeEnd: 0, _lastAllocated: 0
    });

    // it should recompute the global emissions per VP once against the final totalWeight
    // Σout == Σin ⇒ perm balances unchanged ⇒ global scalar = mulDiv(MINTER_RATE, PRECISION, _MULTI_TOTAL_PERM).
    assertEq(_voter.emissionsPerVP(), uint256(_MINTER_RATE) * _PRECISION / _MULTI_TOTAL_PERM);
  }

  /*////////////////////////////////////////////////////////////
                       ORTHOGONAL SCENARIOS
  ////////////////////////////////////////////////////////////*/
  function test_WhenASourceDrainsItsChainZeroAllocation(uint48 _ts, uint48 _stakeEnd) external {
    // Drain: source amount == its chain0 allocation → the slot zeroes and CHAIN0 leaves the chain set.
    // Equal src/dst stakeEnds keep the point math netting to its seed; the focus is the chain-set delta.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 1));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _stakeEnd = uint48(bound(_stakeEnd, _tAct + 1, type(uint48).max));
    uint128 _amount = 100 ether;
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Src holds exactly `_amount` on chain0 (only allocation) → drains to 0.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});

    // Dst: first-time recipient with a matching live stakeEnd.
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _stakeEnd, _isPermanent: false});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _legs(_TOKEN_ID_2, _amount));

    // it should remove chain zero from the source chain set
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 0);
  }

  function test_WhenADestinationHasNotVotedBefore(uint48 _ts, uint48 _stakeEnd) external {
    // First-time dst: chain set empty pre, stored lastStakeEnd 0 pre. After the batch CHAIN0 joins the
    // chain set, lastStakeEnd is seeded to the live stake end, and lastAllocated stays untouched.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 1));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _stakeEnd = uint48(bound(_stakeEnd, _tAct + 1, type(uint48).max));
    uint128 _amount = 100 ether;
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Src.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});

    // Dst: first-time, defaults (empty chain set, zero token state). Live VE end matches src's end.
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _stakeEnd, _isPermanent: false});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _legs(_TOKEN_ID_2, _amount));

    // it should add chain zero to the destination chain set
    uint256[] memory _dstChains = _voter.allocationChainIds(_TOKEN_ID_2);
    assertEq(_dstChains.length, 1);
    assertEq(_dstChains[0], _CHAIN0);

    // it should seed the destination lastStakeEnd to the live stake end
    // it should keep the destination lastAllocated unchanged
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID_2, _committed: _amount, _lastStakeEnd: _stakeEnd, _lastAllocated: 0
    });
  }

  function test_WhenADestinationHasAPermanentStake(uint48 _ts) external {
    // Mixed stake types: src non-permanent live, dst permanent. The source bias/slope is removed and the
    // destination amount lands on `permanentStakeBalance` — exercises the perm branch of `_contribution`
    // and `_applyContribution`.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 4 weeks));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _srcStakeEnd = _tAct + 4 weeks;
    uint128 _amount = _ONE_AERO;
    uint128 _prePerm = 50 ether;
    vm.warp(_ts);

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Src.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _srcStakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});

    // Dst: permanent stake, not voted before → DstShapeStale skipped.
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: 0, _isPermanent: true});

    // Pre-state mirrors "src previously voted with _amount on chain0"; perm pre-seeded.
    _mockChainPoint({_chainId: _CHAIN0, _bias: _DIFF_PRE_BIAS, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: _prePerm});
    _mockTotalPoint({_bias: _DIFF_PRE_BIAS, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: _prePerm});
    _mockChainSlopeChange(_CHAIN0, _srcStakeEnd, _SLOPE_ONE_AERO);
    _mockTotalSlopeChange(_srcStakeEnd, _SLOPE_ONE_AERO);

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _legs(_TOKEN_ID_2, _amount));

    // it should remove the source bias and slope from the chain zero point
    // it should add the amount to the chain zero permanent stake balance
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _prePerm + _amount});
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _srcStakeEnd), 0);

    // it should add the amount to the totalPoint permanent stake balance
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: _prePerm + _amount});
    assertEq(_voter.totalSlopeChanges(_srcStakeEnd), 0);
  }

  /*////////////////////////////////////////////////////////////
                       ZERO-AMOUNT LEGS
  ////////////////////////////////////////////////////////////*/
  function test_WhenASourceLegHasAZeroAmount(uint48 _ts, uint48 _stakeEnd) external {
    // A zero-amount source is skipped entirely while the real source/destination legs process.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 1));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _stakeEnd = uint48(bound(_stakeEnd, _tAct + 1, type(uint48).max));
    uint128 _amount = 100 ether;
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Zero-amount source carries seeded ledger state that must survive untouched.
    _mockAllocationChainAmount({_tokenId: _DST_A, _chainId: _CHAIN0, _amount: 5 ether});
    _mockTokenState({_tokenId: _DST_A, _committed: 5 ether, _lastStakeEnd: _stakeEnd, _lastAllocated: 9});

    // Real legs.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _stakeEnd, _isPermanent: false});

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _DST_A, amount: 0});
    _sources[1] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID, amount: _amount});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_sources, _legs(_TOKEN_ID_2, _amount));

    // it should leave that source ledger untouched
    assertEq(_voter.allocationChainAmounts(_DST_A, _CHAIN0), 5 ether);
    _assertTokenState({
      _target: _voter, _tokenId: _DST_A, _committed: 5 ether, _lastStakeEnd: _stakeEnd, _lastAllocated: 9
    });
  }

  function test_WhenADestinationLegHasAZeroAmount(uint48 _ts, uint48 _stakeEnd) external {
    // A zero-amount destination is skipped: no ledger credit, no chain-set add, no lastStakeEnd seed.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 1));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _stakeEnd = uint48(bound(_stakeEnd, _tAct + 1, type(uint48).max));
    uint128 _amount = 100 ether;
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Real source.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});

    // Real destination.
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _stakeEnd, _isPermanent: false});

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta({tokenId: _DST_A, amount: 0, recipient: address(0)});
    _destinations[1] = IVotingEscrow.DestinationDelta({tokenId: _TOKEN_ID_2, amount: _amount, recipient: address(0)});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _destinations);

    // it should leave that destination ledger untouched
    assertEq(_voter.allocationChainAmounts(_DST_A, _CHAIN0), 0);
    assertEq(_voter.allocationChainIds(_DST_A).length, 0);
    _assertTokenState({_target: _voter, _tokenId: _DST_A, _committed: 0, _lastStakeEnd: 0, _lastAllocated: 0});
  }

  /*////////////////////////////////////////////////////////////
                       SELF MOVE / EXPIRED
  ////////////////////////////////////////////////////////////*/
  function test_WhenASourceEqualsADestination(uint48 _ts, uint48 _stakeEnd) external {
    // src == one destination. The source drains 100 from S; S receives 90 back and D2 receives 10. The
    // equal portion nets on S's ledger (−10 net), and only the D2 leg is a real outbound move. S keeps a
    // non-empty chain set throughout so the shape check stays meaningful.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 1));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _stakeEnd = uint48(bound(_stakeEnd, _tAct + 1, type(uint48).max));
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // S (== _TOKEN_ID): 150 on chain0 so the 100 drain leaves 50 (set stays non-empty), then +90.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: 150 ether});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 150 ether, _lastStakeEnd: _stakeEnd, _lastAllocated: 3});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockStakedFor({_tokenId: _TOKEN_ID, _amount: 150 ether, _end: _stakeEnd, _isPermanent: false});

    // D2 (== _TOKEN_ID_2): first-time recipient, matching live end.
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _stakeEnd, _isPermanent: false});

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta({tokenId: _TOKEN_ID, amount: 90 ether, recipient: address(0)});
    _destinations[1] = IVotingEscrow.DestinationDelta({tokenId: _TOKEN_ID_2, amount: 10 ether, recipient: address(0)});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, 100 ether), _destinations);

    // it should net the equal portion to zero on the shared ledger
    // S net: 150 − 100 + 90 = 140 (only the 10 routed to D2 left S).
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 140 ether);
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: 140 ether, _lastStakeEnd: _stakeEnd, _lastAllocated: 3
    });

    // it should apply only the remaining destination legs as real moves
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), 10 ether);
  }

  function test_WhenAFullDrainSelfReshapeChangesTheStakeShape(uint48 _ts, uint128 _amount) external {
    // A batch leg that hands a token's whole CHAIN0 balance back to itself while its shape changed. The drain
    // empties the chain set, so the re-add counts as a first booking and re-seeds `lastStakeEnd`; without that the
    // token would keep the old shape and its next gauge vote would revert `StaleShape`.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 5 weeks));
    _amount = uint128(bound(_amount, _ONE_AERO, _INT128_MAX_HALF));
    uint48 _tAct = _ts;
    uint48 _newEnd = _tAct + 4 weeks;
    vm.warp(_ts);

    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // Booked as permanent: the whole balance on CHAIN0, stored shape `0`, contribution in `permanentStakeBalance`.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _amount});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: 0, _lastAllocated: 3});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _amount});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _amount});

    // The VotingEscrow already committed the decaying stake before calling in.
    _mockStakedFor({_tokenId: _TOKEN_ID, _amount: _amount, _end: _newEnd, _isPermanent: false});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _amount), _legs(_TOKEN_ID, _amount));

    // it should re seed the stored shape at the live decaying end
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _amount, _lastStakeEnd: _newEnd, _lastAllocated: 3
    });
    // it should leave the chain zero booking whole
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _amount);
    // it should keep chain zero in the tokens allocation set
    uint256[] memory _tracked = _voter.allocationChainIds(_TOKEN_ID);
    assertEq(_tracked.length, 1);
    assertEq(_tracked[0], _CHAIN0);
    // it should move the contribution from permanent to decaying on chain zero and total
    int128 _slope = _slopeOf(_amount);
    int128 _bias = _slope * int128(uint128(_newEnd - _tAct));
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: _bias, _slope: _slope, _ts: _tAct, _perm: 0});
    _assertTotalPoint({_target: _voter, _bias: _bias, _slope: _slope, _ts: _tAct, _perm: 0});
  }

  function test_WhenADestinationStakeHasExpired(uint48 _ts, uint48 _dstStakeEnd) external {
    // dst live VE stake non-permanent and expired (end <= _tAct). The Voter no longer reverts; the
    // contribution is zero so the point is untouched while the ledger is still credited. Source array is
    // empty to isolate the destination leg.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _dstStakeEnd = uint48(bound(_dstStakeEnd, 1, _tAct)); // expired: 0 < end <= _tAct
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _tAct, _perm: 11 ether});
    _mockTotalPoint({_bias: 7e18, _slope: 5e9, _ts: _tAct, _perm: 13 ether});
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: 0, _end: _dstStakeEnd, _isPermanent: false});
    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // it should not revert
    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_noSrcLegs(), _legs(_TOKEN_ID_2, 100 ether));

    // it should credit the destination chain zero allocation
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), 100 ether);
    // it should leave the chain zero point unchanged for the expired destination leg
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _tAct, _perm: 11 ether});
    _assertTotalPoint({_target: _voter, _bias: 7e18, _slope: 5e9, _ts: _tAct, _perm: 13 ether});
  }

  function test_WhenASourceStakeHasExpired(uint48 _ts, uint48 _srcStakeEnd) external {
    // src recorded stakeEnd non-permanent and expired. The Voter no longer reverts; the contribution is
    // zero so the point is untouched while the ledger is still drained. Destination array is empty to
    // isolate the source leg.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    _srcStakeEnd = uint48(bound(_srcStakeEnd, 1, _tAct)); // expired: 0 < end <= _tAct
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _tAct, _perm: 11 ether});
    _mockTotalPoint({_bias: 7e18, _slope: 5e9, _ts: _tAct, _perm: 13 ether});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: 100 ether});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 100 ether, _lastStakeEnd: _srcStakeEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    // it should not revert
    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, 100 ether), _noLegs());

    // it should drain the source chain zero allocation
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    // it should leave the chain zero point unchanged for the expired source leg
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 4e18, _slope: 3e9, _ts: _tAct, _perm: 11 ether});
    _assertTotalPoint({_target: _voter, _bias: 7e18, _slope: 5e9, _ts: _tAct, _perm: 13 ether});
  }

  /*////////////////////////////////////////////////////////////
                  BATCH (MULTIPLE LEGS, REAL POINT MATH)
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheBatchHasMultipleSourcesAndDestinationsAtDifferingStakeEnds(
    uint48 _ts,
    uint48 _pendingWindow
  ) external {
    // Two sources and two destinations, each holding/receiving exactly one AERO at a DISTINCT non-permanent
    // stake end (so every leg's slope is _SLOPE_ONE_AERO). Pre-state models both sources already contributing on
    // chain0. The batch must settle/resolve ONCE, then drain both sources at their own ends and credit both
    // destinations at their own ends — exercising several slope-change buckets in a single resolution.
    // The pending settlement window is bounded: the global settle banks the index one week boundary at a
    // time, so an unbounded gap would be millions of iterations. 8 weeks crosses several.
    _pendingWindow = uint48(bound(_pendingWindow, 1, 8 weeks));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 8 weeks, type(uint48).max - 10 weeks));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _srcEndA = _tAct + 4 weeks;
    uint48 _srcEndB = _tAct + 6 weeks;
    uint48 _dstEndA = _tAct + 8 weeks;
    uint48 _dstEndB = _tAct + 10 weeks;
    vm.warp(_ts);

    // Sources: each holds exactly one AERO on chain0 → both drain to zero.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _ONE_AERO});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _ONE_AERO, _lastStakeEnd: _srcEndA, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID_2, _chainId: _CHAIN0, _amount: _ONE_AERO});
    _mockTokenState({_tokenId: _TOKEN_ID_2, _committed: _ONE_AERO, _lastStakeEnd: _srcEndB, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID_2, _chainIds: _singletonArray(_CHAIN0)});

    // Destinations: first-time recipients with distinct live stake ends.
    _mockStakedFor({_tokenId: _DST_A, _amount: 0, _end: _dstEndA, _isPermanent: false});
    _mockStakedFor({_tokenId: _DST_B, _amount: 0, _end: _dstEndB, _isPermanent: false});

    // Pre-state: both sources contributing (bias = slope*(4w+6w), slope = 2*_SLOPE_ONE_AERO) with their slope
    // changes scheduled at their ends. Points at _tAct ⇒ _resolveWeight no-ops.
    _mockChainPoint({
      _chainId: _CHAIN0, _bias: _SLOPE_ONE_AERO_WEEK * 10, _slope: _SLOPE_ONE_AERO * 2, _ts: _tAct, _perm: 0
    });
    _mockTotalPoint({_bias: _SLOPE_ONE_AERO_WEEK * 10, _slope: _SLOPE_ONE_AERO * 2, _ts: _tAct, _perm: 0});
    _mockChainSlopeChange(_CHAIN0, _srcEndA, _SLOPE_ONE_AERO);
    _mockChainSlopeChange(_CHAIN0, _srcEndB, _SLOPE_ONE_AERO);
    _mockTotalSlopeChange(_srcEndA, _SLOPE_ONE_AERO);
    _mockTotalSlopeChange(_srcEndB, _SLOPE_ONE_AERO);
    _mockEmissionsPerVP(_DIFF_EPPVP_INIT);
    _mockLastGlobalSettlement(_ts - _pendingWindow);
    _mockChainLastIndex(_CHAIN0, 0);
    _mockChainLastTimeIndex(_CHAIN0, 0);

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID, amount: _ONE_AERO});
    _sources[1] = IVotingEscrow.SourceDelta({tokenId: _TOKEN_ID_2, amount: _ONE_AERO});
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta({tokenId: _DST_A, amount: _ONE_AERO, recipient: address(0)});
    _destinations[1] = IVotingEscrow.DestinationDelta({tokenId: _DST_B, amount: _ONE_AERO, recipient: address(0)});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_sources, _destinations);

    // it should settle and resolve the chain zero point once
    // The point sits at _tAct, so the ceiling is one segment spanning the pending window at a DECAYING
    // weight (slope 2*_SLOPE_ONE_AERO) against the constant pre-state scalar. The exact integral credits the
    // average of the window's start and end weight: end weight is the seeded bias (_SLOPE_ONE_AERO_WEEK * 10,
    // perm 0), start weight is end + slope*window. Independent of the contract's coeff/timeIndex math.
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_voter.index(), _DIFF_EPPVP_INIT * _pendingWindow);
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
    uint256 _endWeight = uint256(uint128(_SLOPE_ONE_AERO_WEEK)) * 10;
    uint256 _startWeight = _endWeight + uint256(uint128(_SLOPE_ONE_AERO)) * 2 * _pendingWindow;
    // Within one wei of the exact average: the contract floors the positive term and ceils the slope
    // correction, so it credits at most a wei below the real integral (conservative, never over root).
    assertApproxEqAbs(
      _chainState(_voter, _CHAIN0).ceiling,
      (_startWeight + _endWeight) * _DIFF_EPPVP_INIT * _pendingWindow / (2 * _PRECISION),
      1
    );

    // it should remove every source contribution at its own stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _srcEndA), 0);
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _srcEndB), 0);
    assertEq(_voter.totalSlopeChanges(_srcEndA), 0);
    assertEq(_voter.totalSlopeChanges(_srcEndB), 0);

    // it should add every destination contribution at its own stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _dstEndA), _SLOPE_ONE_AERO);
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _dstEndB), _SLOPE_ONE_AERO);
    assertEq(_voter.totalSlopeChanges(_dstEndA), _SLOPE_ONE_AERO);
    assertEq(_voter.totalSlopeChanges(_dstEndB), _SLOPE_ONE_AERO);
    // Aggregate bias = slope*(8w + 10w); slope net unchanged (two legs in, two out).
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN0,
      _bias: _SLOPE_ONE_AERO_WEEK * 18,
      _slope: _SLOPE_ONE_AERO * 2,
      _ts: _tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: _SLOPE_ONE_AERO_WEEK * 18, _slope: _SLOPE_ONE_AERO * 2, _ts: _tAct, _perm: 0
    });

    // it should move each token ledger by its own amount
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), 0);
    assertEq(_voter.allocationChainAmounts(_DST_A, _CHAIN0), _ONE_AERO);
    assertEq(_voter.allocationChainAmounts(_DST_B, _CHAIN0), _ONE_AERO);
    _assertTokenState({
      _target: _voter, _tokenId: _DST_A, _committed: _ONE_AERO, _lastStakeEnd: _dstEndA, _lastAllocated: 0
    });
    _assertTokenState({
      _target: _voter, _tokenId: _DST_B, _committed: _ONE_AERO, _lastStakeEnd: _dstEndB, _lastAllocated: 0
    });
  }

  /*////////////////////////////////////////////////////////////
                     ACCUMULATOR / SELF RESHAPE
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheAccumulatorIsADestination(uint48 _ts, uint128 _amount) external {
    // Routing chain0 allocation to the accumulator (tokenId 0). The accumulator is a permanent stake, so the
    // contribution lands on permanentStakeBalance and the ledger credits tokenId 0.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max));
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max) - 50 ether));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    vm.warp(_ts);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 50 ether});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 50 ether});
    // The accumulator (tokenId 0) is a permanent stake.
    _mockStakedFor({_tokenId: 0, _amount: 0, _end: 0, _isPermanent: true});
    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_noSrcLegs(), _legs(0, _amount));

    // it should credit the accumulator chain zero allocation
    assertEq(_voter.allocationChainAmounts(0, _CHAIN0), _amount);
    // it should add the amount to the permanent stake balance
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 50 ether + _amount});
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: 50 ether + _amount});
  }

  function test_WhenAFullyDrainedSourceIsRecreditedAtANewStakeEnd(uint48 _ts) external {
    // T voted on chain0 at _oldEnd, then extended its VE lock to _newEnd without re-voting. A self-referential
    // batch (T as a full-drain source AND a destination) removes T's contribution at the stored _oldEnd and
    // re-adds it at the live _newEnd. Draining empties T's chain set, so DstShapeStale is skipped and T's shape
    // is reseeded — the result is internally consistent (single stake end, matching the live stake), just
    // relocated to _newEnd. This documents the intentional self-move behavior.
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - 8 weeks));
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _oldEnd = _tAct + 4 weeks;
    uint48 _newEnd = _tAct + 8 weeks;
    vm.warp(_ts);

    // T holds exactly one AERO on chain0 at the stored _oldEnd; live VE stake already extended to _newEnd.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _ONE_AERO});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _ONE_AERO, _lastStakeEnd: _oldEnd, _lastAllocated: 0});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockStakedFor({_tokenId: _TOKEN_ID, _amount: _ONE_AERO, _end: _newEnd, _isPermanent: false});

    // Pre-state: T contributing at _oldEnd.
    _mockChainPoint({_chainId: _CHAIN0, _bias: _DIFF_PRE_BIAS, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _DIFF_PRE_BIAS, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0});
    _mockChainSlopeChange(_CHAIN0, _oldEnd, _SLOPE_ONE_AERO);
    _mockTotalSlopeChange(_oldEnd, _SLOPE_ONE_AERO);
    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks one
    // week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID, _ONE_AERO), _legs(_TOKEN_ID, _ONE_AERO));

    // it should relocate the token contribution to the new stake end
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _oldEnd), 0);
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _newEnd), _SLOPE_ONE_AERO);
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN0, _bias: _DIFF_POST_BIAS, _slope: _SLOPE_ONE_AERO, _ts: _tAct, _perm: 0
    });

    // it should leave the token shape and ledger consistent
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _ONE_AERO);
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _ONE_AERO, _lastStakeEnd: _newEnd, _lastAllocated: 0
    });
    uint256[] memory _chains = _voter.allocationChainIds(_TOKEN_ID);
    assertEq(_chains.length, 1);
    assertEq(_chains[0], _CHAIN0);
  }

  /*////////////////////////////////////////////////////////////
                     CONTRIBUTION COHERENCE
  ////////////////////////////////////////////////////////////*/
  function test_WhenDestinationLegsAccumulateBeforeASourceLegDrainsTheTotal(
    uint48 _ts,
    uint48 _stakeEnd,
    uint128 _first,
    uint128 _second
  ) external {
    // Two destination legs credit the same token in separate batches, then one source leg drains the
    // accumulated total. Every leg swaps the position to `contribution(total)`, so slope flooring leaves no
    // residue: the drain cancels the points and the slope schedules exactly.
    uint48 _tAct;
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);
    _first = uint128(bound(_first, 1, _INT128_MAX_HALF));
    _second = uint128(bound(_second, 1, _INT128_MAX_HALF));
    uint128 _total = _first + _second;

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockStakedFor({_tokenId: _TOKEN_ID_2, _amount: _total, _end: _stakeEnd, _isPermanent: false});

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_noSrcLegs(), _legs(_TOKEN_ID_2, _first));
    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_noSrcLegs(), _legs(_TOKEN_ID_2, _second));

    // it should book the chain zero point at the contribution of the accumulated total
    int128 _slope = _slopeOf(_total);
    int128 _bias = _slope * int128(uint128(_stakeEnd - _tAct));
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: _bias, _slope: _slope, _ts: _tAct, _perm: 0});
    _assertTotalPoint({_target: _voter, _bias: _bias, _slope: _slope, _ts: _tAct, _perm: 0});
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _stakeEnd), _slope);
    assertEq(_voter.totalSlopeChanges(_stakeEnd), _slope);

    vm.prank(_VOTING_ESCROW);
    _voter.rebalanceChain0(_srcLegs(_TOKEN_ID_2, _total), _noLegs());

    // it should clear the chain zero point and its slope schedule after the drain
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _stakeEnd), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID_2, _CHAIN0), 0);
    assertEq(_voter.allocationChainIds(_TOKEN_ID_2).length, 0);

    // it should clear totalPoint and its slope schedule after the drain
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    assertEq(_voter.totalSlopeChanges(_stakeEnd), 0);
  }
}
