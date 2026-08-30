// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter, IVoter, Voter} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterBurn is BaseVoter {
  // Shared seeds for burn happy paths. Post-burn total.weight = 500_000e18 → the global
  // emissionsPerVP scalar = mulDiv(MINTER_RATE, PRECISION, 500_000e18) = 2e13. There is one global
  // scalar and one global index; the per-chain weight enters only at settlement.
  uint128 internal constant _BURN_AMOUNT = 200_000 ether;
  uint128 internal constant _BURN_CHAIN0_PERM_PRE = 500_000 ether;
  uint128 internal constant _BURN_TOTAL_PERM_PRE = 700_000 ether;
  // Distinctive non-zero pre-state GLOBAL emissionsPerVP scalar, kept different from the post-burn
  // recompute (2e13) so the index advance proves it integrates the pre-state scalar.
  uint256 internal constant _BURN_EPPVP_INIT = 12_345;

  /*////////////////////////////////////////////////////////////
                   PRECONDITION REVERTS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheCallerIsNotTheVotingEscrow(address _caller) external {
    // Caller is the only fuzzed input — the assertion is "any non-voting-escrow caller reverts".
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTING_ESCROW);

    vm.prank(_caller);
    // it should revert with NotVotingEscrow
    vm.expectRevert(IVoter.NotVotingEscrow.selector);
    _voter.burn(1);
  }

  function test_WhenTheBurnAmountIsZero() external {
    vm.prank(_VOTING_ESCROW);
    // it should revert with ZeroAmount
    vm.expectRevert(IVoter.ZeroAmount.selector);
    _voter.burn(0);
  }

  function test_WhenTheBurnAmountExceedsTheCommittedBalance(uint128 _amount, uint128 _committed) external {
    // Bound `_amount > 0` to clear ZeroAmount; `_committed < _amount` is the revert condition.
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _committed = uint128(bound(_committed, 0, _amount - 1));

    _mockTokenState({_tokenId: _TOKEN0, _committed: _committed, _lastStakeEnd: 0, _lastAllocated: 0});

    vm.prank(_VOTING_ESCROW);
    // it should revert with InsufficientCommitted
    vm.expectRevert(IVoter.InsufficientCommitted.selector);
    _voter.burn(_amount);
  }

  function test_WhenTheBurnAmountExceedsTheChainZeroAllocation(uint128 _amount, uint128 _chain0Alloc) external {
    // Bound `_amount > 0` to clear ZeroAmount; committed = amount to clear InsufficientCommitted;
    // `_chain0Alloc < _amount` is the revert condition.
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _chain0Alloc = uint128(bound(_chain0Alloc, 0, _amount - 1));

    _mockTokenState({_tokenId: _TOKEN0, _committed: _amount, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN0, _chainId: _CHAIN0, _amount: _chain0Alloc});

    vm.prank(_VOTING_ESCROW);
    // it should revert with InsufficientChain0Allocation
    vm.expectRevert(IVoter.InsufficientChain0Allocation.selector);
    _voter.burn(_amount);
  }

  /*////////////////////////////////////////////////////////////
                     DRAIN SCENARIOS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheBurnDoesNotDrainTheChainZeroAllocation(uint48 _ts, uint48 _pendingWindow) external {
    // Burn `_BURN_AMOUNT` from TOKEN0. chain0Alloc pre > amount, so post-burn the slot stays
    // positive and CHAIN0 remains in TOKEN0's chain set. Burn only mutates `permanentStakeBalance`
    // (bias/slope unchanged after resolve no-op). Recompute against the new totalWeight.
    // The pending settlement window is bounded: the global settle banks the index one week boundary
    // at a time, so an unbounded gap would be millions of iterations. 8 weeks crosses several. The
    // upper bound reserves a week of headroom so the boundary cursor stays inside `uint48`.
    _pendingWindow = uint48(bound(_pendingWindow, 1, 8 weeks));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 8 weeks, type(uint48).max - _WEEK));
    // TOKEN0 only allocates to CHAIN0, so committed == alloc. Pre > _BURN_AMOUNT → no drain.
    uint128 _committedPre = _BURN_CHAIN0_PERM_PRE;

    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    vm.warp(_ts);

    // TOKEN0 state.
    _mockTokenState({_tokenId: _TOKEN0, _committed: _committedPre, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN0, _chainId: _CHAIN0, _amount: _committedPre});
    _mockExistingChainIds({_tokenId: _TOKEN0, _chainIds: _singletonArray(_CHAIN0)});

    // Global state — points at _tAct so resolve no-ops. TOKEN0 is the only perm contributor to
    // chain0, so chain0Point.bias/slope are 0; totalPoint.perm > chain0Point.perm because other
    // chains carry perm contributions.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_CHAIN0_PERM_PRE});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_TOTAL_PERM_PRE});
    // Pre-state accrual lives on the GLOBAL scalar + settlement anchor; CHAIN0's cursor is still the
    // constructor default (`lastIndex == 0 == index`), so the whole pending window is unintegrated.
    _mockEmissionsPerVP(_BURN_EPPVP_INIT);
    _mockLastGlobalSettlement(_ts - _pendingWindow);
    _mockChainLastIndex(_CHAIN0, 0);

    // it should emit the Burned event
    vm.expectEmit(true, false, false, true, address(_voter));
    emit IVoter.Burned(_VOTING_ESCROW, _BURN_AMOUNT);

    vm.prank(_VOTING_ESCROW);
    _voter.burn(_BURN_AMOUNT);

    // it should advance the global index to T act
    // index = emissionsPerVP_pre * dt, dt == the pending window.
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_voter.index(), _BURN_EPPVP_INIT * _pendingWindow);

    // it should settle the chain zero ceiling to T act
    // The cursor catches up to the global index AND the ceiling accrues the index delta at the
    // chain0 weight (perm == _BURN_CHAIN0_PERM_PRE, and the point sits at _tAct so the ceiling walk
    // is a single non-decaying segment): accrual = weightOf(chain0) * emissionsPerVP_pre * dt / PRECISION.
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
    assertEq(
      _chainState(_voter, _CHAIN0).ceiling,
      uint256(_BURN_CHAIN0_PERM_PRE) * _BURN_EPPVP_INIT * _pendingWindow / _PRECISION
    );

    // it should resolve the chain zero point to T act
    // it should decrement permanentStakeBalance on the chain zero point by the burn amount
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_CHAIN0_PERM_PRE - _BURN_AMOUNT
    });

    // it should resolve totalPoint to T act
    // it should decrement permanentStakeBalance on totalPoint by the burn amount
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_TOTAL_PERM_PRE - _BURN_AMOUNT});

    // it should recompute the global emissions per VP against the new totalWeight
    // Global scalar = mulDiv(MINTER_RATE, PRECISION, weightOf(total)_post)
    //              = mulDiv(10e18, 1e18, 500_000e18) = 2e13 (no chainWeight factor).
    assertEq(_voter.emissionsPerVP(), uint256(_MINTER_RATE) * _PRECISION / (_BURN_TOTAL_PERM_PRE - _BURN_AMOUNT));

    // it should decrement committed on the token zero state by the burn amount
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN0, _committed: _committedPre - _BURN_AMOUNT, _lastStakeEnd: 0, _lastAllocated: 0
    });
    // it should decrement allocationChainAmounts for token zero on chain zero by the burn amount
    assertEq(_voter.allocationChainAmounts(_TOKEN0, _CHAIN0), _committedPre - _BURN_AMOUNT);

    // it should keep chain zero in the token zero chain set
    uint256[] memory _token0Chains = _voter.allocationChainIds(_TOKEN0);
    assertEq(_token0Chains.length, 1);
    assertEq(_token0Chains[0], _CHAIN0);
  }

  function test_WhenTheBurnDrainsTheChainZeroAllocation(uint48 _ts, uint48 _pendingWindow) external {
    // Drain: TOKEN0.alloc[CHAIN0]_pre == _BURN_AMOUNT → post-burn the slot zeros and CHAIN0
    // leaves TOKEN0's chain set. chain0Point.perm still has other perm contributors so the
    // recompute math matches the no-drain test.
    // The pending settlement window is bounded: the global settle banks the index one week boundary
    // at a time, so an unbounded gap would be millions of iterations. 8 weeks crosses several. The
    // upper bound reserves a week of headroom so the boundary cursor stays inside `uint48`.
    _pendingWindow = uint48(bound(_pendingWindow, 1, 8 weeks));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 8 weeks, type(uint48).max - _WEEK));
    uint128 _committedPre = _BURN_AMOUNT; // TOKEN0's entire balance drains

    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    vm.warp(_ts);

    _mockTokenState({_tokenId: _TOKEN0, _committed: _committedPre, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN0, _chainId: _CHAIN0, _amount: _committedPre});
    _mockExistingChainIds({_tokenId: _TOKEN0, _chainIds: _singletonArray(_CHAIN0)});

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_CHAIN0_PERM_PRE});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_TOTAL_PERM_PRE});
    _mockEmissionsPerVP(_BURN_EPPVP_INIT);
    _mockLastGlobalSettlement(_ts - _pendingWindow);
    _mockChainLastIndex(_CHAIN0, 0);

    // it should emit the Burned event
    vm.expectEmit(true, false, false, true, address(_voter));
    emit IVoter.Burned(_VOTING_ESCROW, _BURN_AMOUNT);

    vm.prank(_VOTING_ESCROW);
    _voter.burn(_BURN_AMOUNT);

    // it should advance the global index to T act
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_voter.index(), _BURN_EPPVP_INIT * _pendingWindow);

    // it should settle the chain zero ceiling to T act
    // accrual = weightOf(chain0)_pre * emissionsPerVP_pre * dt / PRECISION, dt == the pending window.
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _voter.index());
    assertEq(
      _chainState(_voter, _CHAIN0).ceiling,
      uint256(_BURN_CHAIN0_PERM_PRE) * _BURN_EPPVP_INIT * _pendingWindow / _PRECISION
    );

    // it should resolve the chain zero point to T act
    // it should decrement permanentStakeBalance on the chain zero point by the burn amount
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_CHAIN0_PERM_PRE - _BURN_AMOUNT
    });

    // it should resolve totalPoint to T act
    // it should decrement permanentStakeBalance on totalPoint by the burn amount
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_TOTAL_PERM_PRE - _BURN_AMOUNT});

    // it should recompute the global emissions per VP against the new totalWeight
    // Global scalar = mulDiv(MINTER_RATE, PRECISION, 500_000e18) = 2e13.
    assertEq(_voter.emissionsPerVP(), uint256(_MINTER_RATE) * _PRECISION / (_BURN_TOTAL_PERM_PRE - _BURN_AMOUNT));

    // it should decrement committed on the token zero state by the burn amount
    _assertTokenState({_target: _voter, _tokenId: _TOKEN0, _committed: 0, _lastStakeEnd: 0, _lastAllocated: 0});
    // it should zero allocationChainAmounts for token zero on chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN0, _CHAIN0), 0);

    // it should remove chain zero from the token zero chain set
    assertEq(_voter.allocationChainIds(_TOKEN0).length, 0);
  }

  /*////////////////////////////////////////////////////////////
                   ORTHOGONAL SCENARIOS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTotalWeightResolvesToZero(uint48 _ts) external {
    // TOKEN0 is the sole perm contributor system-wide: chain0Point.perm == totalPoint.perm ==
    // _BURN_AMOUNT. Burning drains both points → post totalWeight = 0 → the post-mutation refresh
    // hits the zero-weight guard and zeros the GLOBAL emissionsPerVP. Realistic edge case (every
    // other staker either non-perm or already drained).
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max));

    uint48 _tAct = _ts; // root anchors settlement at block.timestamp
    vm.warp(_ts);

    _mockTokenState({_tokenId: _TOKEN0, _committed: _BURN_AMOUNT, _lastStakeEnd: 0, _lastAllocated: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN0, _chainId: _CHAIN0, _amount: _BURN_AMOUNT});
    _mockExistingChainIds({_tokenId: _TOKEN0, _chainIds: _singletonArray(_CHAIN0)});

    // Both points pre-perm = _BURN_AMOUNT (TOKEN0 is the only perm contributor).
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_AMOUNT});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _BURN_AMOUNT});

    // Pre-seed the global emissionsPerVP so the zero-write assertion is non-vacuous.
    _mockEmissionsPerVP(_BURN_EPPVP_INIT);
    // Nothing here asserts the index, so anchor the settlement cursor at now: the global settle walks
    // one week boundary at a time and this test has no reason to pay for that walk.
    _mockLastGlobalSettlement(_ts);

    vm.prank(_VOTING_ESCROW);
    _voter.burn(_BURN_AMOUNT);

    // it should set the global emissions per VP to zero
    assertEq(_voter.emissionsPerVP(), 0);
  }
}
