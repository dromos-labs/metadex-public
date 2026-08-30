// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';

import {BaseVoter, IVoter, IVoterCommon} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterVoteRates is BaseVoter {
  function test_WhenTheVoteResamplesEmissionsPerVPForALeafChain() external givenCallerIsAuthorized {
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // Both points seeded at _tAct (= block.timestamp) so the resolve early-exits and no walk
    // decay enters the post-swap weight. Chain models "1 AERO of voting power"; total models
    // "4 AERO". emissionsPerVP is the single GLOBAL scalar mulDiv(MINTER_RATE, PRECISION, totalWeight)
    // — no chainWeight factor — so it depends only on the total (4 AERO equivalent), not the leaf chain.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 999_990_486_943_686_000, // chain weight (1 AERO equivalent)
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: 0,
      _chainPointTs: _tAct,
      _totalBias: 3_999_961_947_774_744_000, // total weight (4 AERO equivalent)
      _totalSlope: 4 * _SLOPE_ONE_AERO,
      _totalPerm: 0,
      _totalPointTs: _tAct,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });

    // Additive re-vote of a tiny `delta = 1` wei: `contribution(_ONE_AERO + 1) - contribution(_ONE_AERO)`
    // is a bias/slope no-op (same floored slope), so totalWeight is unchanged and the rate math holds.
    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID, _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}), _REFUND_RECIPIENT
    );

    // it should set emissionsPerVP to mulDiv minter rate precision total weight
    // Global scalar: mulDiv(10e18, 1e18, 3_999_961_947_774_744_000). Depends only on the total weight.
    assertEq(_voter.emissionsPerVP(), Math.mulDiv(_MINTER_RATE, _PRECISION, 3_999_961_947_774_744_000));
    // The touched leaf ends anchored at the global accumulator (nothing accrued: the scalar was 0 over
    // the whole interval, so `index` never moved).
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    assertEq(_voter.lastGlobalSettlement(), _tAct);
  }

  function test_WhenTheVoteReanchorsChainZeroToANewShape() external givenCallerIsAuthorized {
    // CHAIN0 is re-anchored only on a shape change, since it is never in the caller's dispatch scope.
    // Prior: {CHAIN_ID_1: 3 AERO, CHAIN0: 1 AERO} at `_priorStakeEnd`; committed = 4 AERO. The live shape
    // moved to `_newStakeEnd` and the caller adds 1 wei to CHAIN_1, so the pipeline re-anchors both
    // allocated chains to the new shape and resamples the single global scalar against the resulting
    // totalWeight (CHAIN0's re-anchored weight included). The +1 wei is a bias/slope no-op on CHAIN_1.
    uint48 _tAct = _INITIAL_TIMESTAMP + 1 days;
    uint48 _ts = _tAct;
    uint48 _priorStakeEnd = _tAct + 2 * _WEEK;
    uint48 _newStakeEnd = _tAct + 4 * _WEEK; // shape change
    uint128 _staked = 4 * _ONE_AERO + _MAXTIME; // committed 4 AERO + virgin headroom

    int128 _slopeX = _slopeOf(3 * _ONE_AERO);
    int128 _slope0 = _slopeOf(_ONE_AERO);
    int128 _deltaPrior = int128(uint128(_priorStakeEnd - _tAct));
    int128 _deltaNew = int128(uint128(_newStakeEnd - _tAct));

    vm.warp(_ts);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _slopeX * _deltaPrior, _slope: _slopeX, _ts: _tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: _slope0 * _deltaPrior, _slope: _slope0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: (_slopeX + _slope0) * _deltaPrior, _slope: _slopeX + _slope0, _ts: _tAct, _perm: 0});
    _mockChainSlopeChange(_CHAIN_ID_1, _priorStakeEnd, _slopeX);
    _mockChainSlopeChange(_CHAIN0, _priorStakeEnd, _slope0);
    _mockTotalSlopeChange(_priorStakeEnd, _slopeX + _slope0);
    // Both chains sit on the current global accumulator, so no accrual is pending.
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: 4 * _ONE_AERO, _lastStakeEnd: _priorStakeEnd, _lastAllocated: _INITIAL_TIMESTAMP
    });
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, 3 * _ONE_AERO);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _ONE_AERO);
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _prior);
    _mockStaked({_amount: _staked, _end: _newStakeEnd, _isPermanent: false});

    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID, _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}), _REFUND_RECIPIENT
    );

    // it should set emissionsPerVP to mulDiv minter rate precision the reanchored total weight
    // After the re-anchor both chains sit at `_newStakeEnd`: total weight = (slopeX + slope0) * deltaNew.
    uint128 _totalWeight = uint128((_slopeX + _slope0) * _deltaNew);
    assertEq(_voter.emissionsPerVP(), Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight));
    // it should anchor chain zero at the global index
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
  }

  function test_WhenTotalWeightResolvesToZeroBeforeTheResample() external givenCallerIsAuthorized {
    // Defensive guard: not reachable via vote() under normal stakes (the swap adds the
    // voter's contribution to total). Realistic triggers live in burn() / rebalanceChain0().
    // Test pins the zero-weight protection in the emissionsPerVP resample.
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800;

    // All points seeded at zero weight so totalWeight = 0 post-swap. The additive `delta = 1` wei add
    // nets to zero on the point (remove `contribution(_ONE_AERO)`, add `contribution(_ONE_AERO + 1)`,
    // same floored slope), so totalWeight stays 0 and the div-by-zero rate guard fires. A tiny virgin
    // headroom on the live stake lets the delta clear the bound.
    uint128 _staked = 2 * _ONE_AERO + _MAXTIME;
    vm.warp(_ts);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: 2 * _ONE_AERO, _lastStakeEnd: _stakeEnd, _lastAllocated: _INITIAL_TIMESTAMP
    });
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _ONE_AERO);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _ONE_AERO);
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _prior);
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});

    // Pre-seed the global emissionsPerVP to a distinctive non-zero value so the assertion proves the
    // guard actually wrote 0 (rather than the test passing because default storage was already 0).
    // Both chains carry zero weight, so the index this scalar accrues adds nothing to any ceiling.
    _mockEmissionsPerVP(999_999);

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT});

    // Dispatch carries a zero emissions-per-VP scalar: the div-by-zero guard yields 0 when
    // totalWeight resolves to 0.
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: 1,
        emissionsPerVP: 0,
        snapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should set emissionsPerVP to zero
    // totalWeight = 0 triggers the zero-weight guard on the single global scalar.
    assertEq(_voter.emissionsPerVP(), 0);
    // Zero-weight chains accrue nothing even though the index advanced at the pre-seeded scalar.
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, 0);
    assertEq(_chainState(_voter, _CHAIN0).ceiling, 0);
  }

  function test_WhenTheVoteSpansMultipleLeafChainsInTheDispatchScope() external givenCallerIsAuthorized {
    // Two leaf chains in _scope. chain1 holds 1 AERO weight, chain2 holds 3 AERO, total = 4 AERO. Both
    // sit on the same shared global accumulator: there is a single `emissionsPerVP` scalar and a single
    // `index`, so the two chains' ceilings differ ONLY by their own weight, and both end anchored at the
    // same `index`. Accrual = mulDiv(weightOf(chain), index - lastIndex, PRECISION).
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _stakeEnd = 1_893_628_800;
    int128 _chain1Bias = 1e18;
    int128 _chain2Bias = 3e18;
    // The two additive `delta = 1` wei adds are funded from a 2-wei CHAIN0 park (seeded below); chain
    // allocations draw only from CHAIN0. The extra `_MAXTIME` is inert live-but-unbooked headroom.
    uint128 _staked = 2 * _ONE_AERO + _MAXTIME;
    // Pre-state global scalar, deliberately != the post-vote resampled scalar (2.5e18), so the ceiling
    // assertions prove the settle integrates the scalar that governed the closed interval.
    uint256 _priorEmissionsPerVP = 1e18;

    {
      uint48 _chainPointTs = _tAct - 1 hours; // both chains lag tAct by the same elapsed window
      vm.warp(_ts);
      _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _chain1Bias, _slope: 0, _ts: _chainPointTs, _perm: 0});
      _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: _chain2Bias, _slope: 0, _ts: _chainPointTs, _perm: 0});
      _mockTotalPoint({_bias: _chain1Bias + _chain2Bias, _slope: 0, _ts: _tAct, _perm: 0}); // total at _tAct -> early-exit
      _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);
      _mockChainStatus(_CHAIN_ID_2, IVoterCommon.ChainStatus.Active);
      // One shared accumulator: both chains are anchored at the same cursor and the global scalar has
      // been in force since `_chainPointTs`, so the settle integrates one hour at `_priorEmissionsPerVP`.
      _mockEmissionsPerVP(_priorEmissionsPerVP);
      _mockLastGlobalSettlement(_chainPointTs);
      _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
      _mockChainLastIndex(_CHAIN_ID_2, _voter.index());

      _mockTokenState({
        _tokenId: _TOKEN_ID, _committed: 2 * _ONE_AERO, _lastStakeEnd: _stakeEnd, _lastAllocated: _INITIAL_TIMESTAMP
      });
      _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _ONE_AERO);
      _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_2, _ONE_AERO);
      // Fund the two 1-wei deltas from CHAIN0 (chain allocations now draw only from CHAIN0-parked VP).
      // 2 wei carries zero decaying weight, so it is a walk/rate no-op.
      _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _chainPointTs, _perm: 0});
      _mockChainLastIndex(_CHAIN0, _voter.index());
      _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, 2);
      uint256[] memory _prior = new uint256[](3);
      _prior[0] = _CHAIN0;
      _prior[1] = _CHAIN_ID_1;
      _prior[2] = _CHAIN_ID_2;
      _mockExistingChainIds(_TOKEN_ID, _prior);
      _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    }

    // Build 2-chain additive allocation (ascending by chainId). A `delta = 1` wei add on each chain is
    // a bias/slope no-op (same floored slope), so the walk and the resampled scalar are observed cleanly.
    IVoter.ChainAllocationDispatch[] memory _allocations = new IVoter.ChainAllocationDispatch[](2);
    _allocations[0] = IVoter.ChainAllocationDispatch({chainId: _CHAIN_ID_1, delta: 1, gasLimit: _GAS_LIMIT, value: 0});
    _allocations[1] = IVoter.ChainAllocationDispatch({chainId: _CHAIN_ID_2, delta: 1, gasLimit: _GAS_LIMIT, value: 0});

    // Both chains dispatch the SAME global emissions-per-VP scalar:
    // mulDiv(_MINTER_RATE, _PRECISION, _totalBias) = mulDiv(10e18, 1e18, 4e18) = 2.5e18.
    {
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches =
        new IRootMessageOrchestrator.ChainDispatch[](2);
      _expectedDispatches[0] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _CHAIN_ID_1,
        gasLimit: _GAS_LIMIT,
        nativeValue: 0,
        chargeDeallocationReturn: false,
        payload: abi.encode(
          IVoterCommon.AllocateChainMessage({
            tokenId: _TOKEN_ID,
            allocationDelta: 1,
            emissionsPerVP: 2.5e18,
            snapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false})
          })
        )
      });
      _expectedDispatches[1] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _CHAIN_ID_2,
        gasLimit: _GAS_LIMIT,
        nativeValue: 0,
        chargeDeallocationReturn: false,
        payload: abi.encode(
          IVoterCommon.AllocateChainMessage({
            tokenId: _TOKEN_ID,
            allocationDelta: 1,
            emissionsPerVP: 2.5e18,
            snapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false})
          })
        )
      });
      _expectAllocateChainDispatch(_expectedDispatches);
    }

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should settle both chains off the shared global index
    // The shared index advances by `1e18 * 3600 = 3.6e21` over the hour, then each chain applies its own
    // weight: chain1 = mulDiv(1e18, 3.6e21, 1e18) = 3.6e21; chain2 = mulDiv(3e18, 3.6e21, 1e18) = 1.08e22.
    assertEq(_voter.index(), 3_600_000_000_000_000_000_000);
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, 3_600_000_000_000_000_000_000);
    assertEq(_chainState(_voter, _CHAIN_ID_2).ceiling, 10_800_000_000_000_000_000_000);
    // it should leave both chains anchored at the current global index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, 3_600_000_000_000_000_000_000);
    assertEq(_chainState(_voter, _CHAIN_ID_2).lastIndex, 3_600_000_000_000_000_000_000);
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    // it should resample the single global emissionsPerVP against the total weight
    // mulDiv(MINTER_RATE, PRECISION, totalBias) = mulDiv(10e18, 1e18, 4e18) = 2.5e18.
    assertEq(_voter.emissionsPerVP(), 2.5e18);
  }

  function test_WhenChainPointDecaysThroughTheWalkBeforeTheResample() external givenCallerIsAuthorized {
    uint48 _ts = _INITIAL_TIMESTAMP + 1 days;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _chainPointTs = _tAct - 2 hours; // walk window has actual decay work to do
    uint48 _stakeEnd = 1_893_628_800;

    // chain.bias_in is the "1 AERO at chainPointTs" value (1_000_047_564_569_250_000).
    // After 2h walk it decays to "1 AERO at _tAct" (999_990_486_943_686_000). The walk must resolve
    // the chain point (and hence totalPoint) before the resample. total at _tAct (= block.timestamp)
    // -> early-exit, weight = 4 AERO equivalent (3_999_961_947_774_744_000). emissionsPerVP is the
    // single GLOBAL scalar mulDiv(MINTER_RATE, PRECISION, totalWeight); it depends on the resolved
    // total, not on the leaf chain weight.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 1_000_047_564_569_250_000, // _SLOPE_ONE_AERO * (_stakeEnd - _chainPointTs)
      _chainSlope: _SLOPE_ONE_AERO,
      _chainPerm: 0,
      _chainPointTs: _chainPointTs,
      _totalBias: 3_999_961_947_774_744_000, // 4 * _SLOPE_ONE_AERO * (_stakeEnd - _tAct)
      _totalSlope: 4 * _SLOPE_ONE_AERO,
      _totalPerm: 0,
      _totalPointTs: _tAct,
      _stakeEnd: _stakeEnd,
      _isPermanent: false
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID, _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}), _REFUND_RECIPIENT
    );

    // it should use the resolved total weight when computing emissionsPerVP
    // expected = mulDiv(10e18, 1e18, 3_999_961_947_774_744_000)
    assertEq(_voter.emissionsPerVP(), Math.mulDiv(_MINTER_RATE, _PRECISION, 3_999_961_947_774_744_000));
  }

  function test_WhenAChainInScopeIsSettledAtTheGlobalIndexDelta(
    uint128 _emissionsPerVP,
    uint128 _initialCeiling,
    uint48 _elapsed
  ) external givenCallerIsAuthorized {
    // Bounds keep the accrual + `_initialCeiling` inside uint256. The seeded chain weight is 1 AERO
    // (== PRECISION), so accrual = mulDiv(weight, index - lastIndex, PRECISION) = emissionsPerVP * elapsed.
    // Range includes 0 so "ceiling unchanged when the index does not move" falls out naturally.
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 0, type(uint64).max));
    _initialCeiling = uint128(bound(_initialCeiling, 0, type(uint128).max));
    _elapsed = uint48(bound(_elapsed, 1, 4 weeks));

    // Anchor _ts well past cooldown so `_tAct - _elapsed` stays >= _INITIAL_TIMESTAMP.
    uint48 _ts = _INITIAL_TIMESTAMP + 5 weeks;
    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    uint48 _chainPointTs = _tAct - _elapsed; // the global accumulator is anchored here too

    // Permanent stake so the swap only touches `perm`. perm = _ONE_AERO avoids the underflow.
    vm.warp(_ts);
    _seedSingleVoterPrior({
      _chainBias: 0,
      _chainSlope: 0,
      _chainPerm: _ONE_AERO,
      _chainPointTs: _chainPointTs,
      _totalBias: 0,
      _totalSlope: 0,
      _totalPerm: _ONE_AERO,
      _totalPointTs: _tAct, // total at _tAct so resolve early-exits; we only care about chain ceiling
      _stakeEnd: 0,
      _isPermanent: true
    });
    // Seed the global scalar and rewind the accumulator's cursor by `_elapsed`. The helper already
    // anchored each chain's `lastIndex` at the (still zero) `index`, so the whole `_elapsed` window
    // accrues at `_emissionsPerVP`; with weight == PRECISION the accrual is `emissionsPerVP * elapsed`.
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_chainPointTs);
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID, _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT}), _REFUND_RECIPIENT
    );

    // it should accrue chainCeiling by weight times index delta
    // index delta = _emissionsPerVP * _elapsed; weight == PRECISION cancels the scaling.
    // (When _emissionsPerVP == 0 the index never moves and the ceiling stays put.)
    uint256 _indexDelta = uint256(_emissionsPerVP) * _elapsed;
    assertEq(_voter.index(), _indexDelta);
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, uint256(_initialCeiling) + _indexDelta);
    // it should advance the chain cursor and the global settlement to T act
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _indexDelta);
    assertEq(_voter.lastGlobalSettlement(), _tAct);
  }
}
