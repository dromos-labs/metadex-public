// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter, IVoter, IVoterCommon, Voter} from 'V3-test/unit/voter/BaseVoter.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVoterProcessDeallocation is BaseVoter {
  function test_WhenTheCallerIsNotTheOrchestrator(address _caller) external {
    // Any address other than the orchestrator is rejected before touching state.
    vm.assume(_caller != _ORCHESTRATOR);

    // it should revert with NotAuthorized
    vm.prank(_caller);
    vm.expectRevert(IVoter.NotAuthorized.selector);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, uint128(_ONE_AERO));
  }

  function test_WhenTheOriginChainIsNotRegistered() external {
    // `_UNREGISTERED_CHAIN_ID` is deliberately kept out of the registered set in `setUp`.
    // it should revert with ChainNotRegistered
    vm.prank(_ORCHESTRATOR);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _UNREGISTERED_CHAIN_ID));
    _voter.processDeallocation(_UNREGISTERED_CHAIN_ID, _TOKEN_ID, uint128(_ONE_AERO));
  }

  function test_WhenTheTokenHasNoRemainingAllocationOnTheOriginChain(uint128 _amount) external {
    // Late/duplicate message: root already books nothing on the origin chain. Credit clamps
    // to 0 and the function early-returns without moving any weight to CHAIN0.
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    vm.warp(_ts);

    // Origin allocation is zero; CHAIN0 holds a distinctive balance we assert stays untouched.
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, 0);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _ONE_AERO);

    // it should emit DeallocationProcessed with a zero amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, 0);

    vm.prank(_ORCHESTRATOR);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, _amount);

    // it should credit nothing to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _ONE_AERO);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
  }

  function test_WhenTheReportedAmountExceedsTheTokensOriginChainAllocation(uint128 _excess) external {
    // Reported amount overshoots what root still books. The credit clamps to the full origin
    // balance, so the origin fully drains and the surplus is dropped.
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME

    // Origin holds 1 AERO, CHAIN0 holds 3 AERO; token committed = 4 AERO. Reported amount is
    // origin balance + fuzzed excess, so it always exceeds `_onChain`.
    uint128 _onChain = _ONE_AERO;
    uint128 _chain0Start = 3 * _ONE_AERO;
    uint128 _committed = 4 * _ONE_AERO;
    _excess = uint128(bound(_excess, 1, _INT128_MAX_HALF));
    uint128 _amount = _onChain + _excess;

    _seedTwoChainPrior(_tAct, _stakeEnd, _onChain, _chain0Start, _committed);

    // it should emit DeallocationProcessed with the clamped amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, _onChain);

    vm.prank(_ORCHESTRATOR);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, _amount);

    // it should clamp the credit to the remaining origin chain allocation
    // it should move the clamped amount from the origin chain to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _onChain);

    // it should remove the origin chain from the tokens allocation set
    assertFalse(_containsChain(_TOKEN_ID, _CHAIN_ID_1));
    assertTrue(_containsChain(_TOKEN_ID, _CHAIN0));
  }

  modifier whenTheReportedAmountIsWithinTheTokensOriginChainAllocation() {
    _;
  }

  function test_WhenTheAmountDrainsTheFullOriginChainAllocation()
    external
    whenTheReportedAmountIsWithinTheTokensOriginChainAllocation
  {
    // Full drain: reported amount == origin balance. Origin empties, CHAIN0 absorbs it, and the
    // total weight is conserved (the move only shuffles between two chains).
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800;
    vm.warp(_ts);

    // Origin holds 1 AERO, CHAIN0 holds 3 AERO; committed = 4 AERO. Non-permanent stake so
    // contributions are slope*delta. delta = _stakeEnd - _tAct.
    uint128 _onChain = _ONE_AERO;
    uint128 _chain0Start = 3 * _ONE_AERO;
    uint128 _committed = 4 * _ONE_AERO;

    // Distinctive non-zero starting index, so both chain cursors anchor away from zero and the asserted
    // accrual can only come from the elapsed index delta, never from the absolute index.
    uint256 _priorIndex = 7e21;
    _mockGlobalIndex(_priorIndex);

    // A full day of global index is pending (`lastGlobalSettlement` a day behind `_ts`). Anchor every point a
    // day back too, so `_settleChain` decays each contribution over exactly the window the global index
    // advances — the production-consistent shape (`_settleChain` never credits a decaying weight at a frozen
    // value). The scalar `2.5e18` is the order of magnitude a 4-AERO total weight yields
    // (`minterRate / totalWeight`) but deliberately NOT the exact post-move value, so the resample assertion
    // below cannot pass on a stale scalar.
    uint48 _pendingWindow = 1 days;
    uint256 _pendingScalar = 2.5e18;
    _seedTwoChainPrior(_tAct - _pendingWindow, _stakeEnd, _onChain, _chain0Start, _committed);
    _mockEmissionsPerVP(_pendingScalar);
    _mockLastGlobalSettlement(_ts - _pendingWindow);

    // it should emit DeallocationProcessed with the amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, _onChain);

    vm.prank(_ORCHESTRATOR);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, _onChain);

    // it should move the full amount from the origin chain to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _onChain);

    // it should remove the origin chain from the tokens allocation set
    assertFalse(_containsChain(_TOKEN_ID, _CHAIN_ID_1));
    assertTrue(_containsChain(_TOKEN_ID, _CHAIN0));

    // it should leave the total weight conserved
    // Origin drains to zero and CHAIN0 absorbs the full committed amount, so the post-move total is
    // the single CHAIN0 contribution `slopeOf(chain0Start + onChain)` == `slopeOf(committed)`.
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _totalSlope = _slopeOf(_chain0Start + _onChain);
    _assertTotalPoint(_voter, _totalSlope * _delta, _totalSlope, _tAct, 0);

    // Origin point drained to zero, CHAIN0 point holds the full 4 AERO now.
    _assertChainPoint(_voter, _CHAIN_ID_1, 0, 0, _tAct, 0);
    int128 _chain0Slope = _slopeOf(_chain0Start + _onChain);
    _assertChainPoint(_voter, _CHAIN0, _chain0Slope * _delta, _chain0Slope, _tAct, 0);

    // it should advance the global settlement cursor to the current timestamp
    // it should anchor both chain cursors at the advanced global index
    // The elapsed day is integrated at the scalar that governed it: `index += pendingScalar * window`.
    uint256 _indexDelta = _pendingScalar * _pendingWindow;
    assertEq(_voter.index(), _priorIndex + _indexDelta);
    assertEq(_voter.lastGlobalSettlement(), _ts);
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _priorIndex + _indexDelta);
    assertEq(_chainState(_voter, _CHAIN0).lastIndex, _priorIndex + _indexDelta);

    // it should accrue both chain ceilings from the global index delta over their decaying pre move weights
    // `_settleChain` runs before the move. Each point sits a full `_pendingWindow` behind `_ts`, so settlement
    // decays it over the same window the global index advanced. For a constant scalar the exact segment accrual
    // is the average of the window-start and window-end weight times the index delta, taken with a single floor:
    // the origin draws on its 1-AERO contribution and CHAIN0 on its 3-AERO one.
    int128 _windowDelta = int128(uint128(_pendingWindow));
    uint256 _originStartWeight = uint128(_slopeOf(_onChain) * (_delta + _windowDelta));
    uint256 _originEndWeight = uint128(_slopeOf(_onChain) * _delta);
    uint256 _chain0StartWeight = uint128(_slopeOf(_chain0Start) * (_delta + _windowDelta));
    uint256 _chain0EndWeight = uint128(_slopeOf(_chain0Start) * _delta);
    assertEq(
      _chainState(_voter, _CHAIN_ID_1).ceiling,
      ((_originStartWeight + _originEndWeight) * _indexDelta) / (2 * _PRECISION)
    );
    assertEq(
      _chainState(_voter, _CHAIN0).ceiling, ((_chain0StartWeight + _chain0EndWeight) * _indexDelta) / (2 * _PRECISION)
    );

    // it should resample the global emissions per voting power scalar against the post move total weight
    // There is one global scalar now, and the credit path resamples it after the move: the origin leaf is
    // sent no scalar here, but the shared index carries the change to every chain including the origin.
    uint128 _totalWeight = uint128(_totalSlope * _delta);
    uint256 _expectedEmissionsPerVP = (uint256(_MINTER_RATE) * _PRECISION) / _totalWeight;
    assertEq(_voter.emissionsPerVP(), _expectedEmissionsPerVP);
  }

  function test_WhenTheAmountDrainsPartOfTheOriginChainAllocation(uint128 _credit)
    external
    whenTheReportedAmountIsWithinTheTokensOriginChainAllocation
  {
    // Partial drain: reported amount < origin balance. Origin keeps the remainder and stays in
    // the set; CHAIN0 gains the credited amount; total weight is conserved.
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800;

    // Origin holds 4 AERO, CHAIN0 holds 1 AERO; committed = 5 AERO. Credit is a strict fraction
    // of the origin balance so the origin retains a non-zero remainder.
    uint128 _onChain = 4 * _ONE_AERO;
    uint128 _chain0Start = _ONE_AERO;
    uint128 _committed = 5 * _ONE_AERO;
    _credit = uint128(bound(_credit, 1, _onChain - 1));

    _seedTwoChainPrior(_tAct, _stakeEnd, _onChain, _chain0Start, _committed);

    // it should emit DeallocationProcessed with the amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, _credit);

    vm.prank(_ORCHESTRATOR);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, _credit);

    // it should move the amount from the origin chain to chain zero
    // it should leave the origin chain in the tokens allocation set with the remainder
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _onChain - _credit);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _credit);
    assertTrue(_containsChain(_TOKEN_ID, _CHAIN_ID_1));
    assertTrue(_containsChain(_TOKEN_ID, _CHAIN0));

    // it should conserve the total weight across the intra-token move
    // Post-move the token books `onChain - credit` on the origin and `chain0Start + credit` on CHAIN0;
    // the total is the sum of those two per-chain contributions (each floored independently).
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _totalSlope = _slopeOf(_onChain - _credit) + _slopeOf(_chain0Start + _credit);
    _assertTotalPoint(_voter, _totalSlope * _delta, _totalSlope, _tAct, 0);
  }

  function test_WhenAHeldDeallocationLandsAfterEmergencyAndReallocation(uint128 _heldReturn) external {
    // REPRODUCTION: emergency drain already accounted X_d (root still booked B at emergency time), so the
    // full drain moved the whole booking B to CHAIN0. The late leaf `Deallocate{X_d}` return finally lands
    // AFTER the chain resumed and the token re-booked `d` on it, and processDeallocation subtracts X_d a
    // SECOND time against the refilled budget -> leaf believes the chain holds `d` while root now books only
    // `d - X_d`, and CHAIN0 is credited X_d on top of the emergency's B. To be fixed by a per-(token,chain)
    // generation fence on processDeallocation.
    //
    // Approach: genuine end-to-end. The real `emergencyDeallocate` drains B (so CHAIN0's +B credit is real),
    // then the resume + re-allocation is seeded directly (a real `allocateChains` re-book needs live-stake,
    // ordering, and dispatch setup that is orthogonal to this bug), then the real `processDeallocation` lands
    // the held return. Everything is anchored at `_tAct` so every `_settleCeiling`/`_resolveWeight` early-exits
    // and the asserted `allocationChainAmounts` depend only on the shared clamp, not on point/slope internals.
    uint48 _tAct = _INITIAL_TIMESTAMP + 3 days;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME
    vm.warp(_tAct);

    // Concrete scenario: root books B on chain X, CHAIN0 already holds a distinctive base. Re-allocation
    // re-books `d < B`; the held leaf return carries `X_d` with `0 < X_d <= d <= B` so the clamp keeps `X_d`.
    uint128 _bookedAtEmergency = 100 * _ONE_AERO; // B
    uint128 _chain0Start = 3 * _ONE_AERO;
    uint128 _reallocated = 50 * _ONE_AERO; // d
    _heldReturn = uint128(bound(_heldReturn, 1, _reallocated)); // X_d ∈ (0, d], and d <= B so X_d <= B holds
    uint128 _committed = _chain0Start + _bookedAtEmergency;

    // 1-2. Seed the {X: B, CHAIN0: chain0Start} prior and Suspend X (emergencyDeallocate reverts otherwise).
    _seedTwoChainPrior(_tAct, _stakeEnd, _bookedAtEmergency, _chain0Start, _committed);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    // Governance authorization for the emergency drain is a precondition here, not the subject; seed it
    // directly rather than calling the setter.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    // 3. Emergency full-drain of X back to CHAIN0. Root still booked the whole B, so all of it moves.
    _expectEmergencyDeallocateDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _value: 0,
      _message: IVoterCommon.EmergencyDeallocateMessage({tokenId: _TOKEN_ID, amount: _bookedAtEmergency})
    });
    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    vm.prank(_CALLER);
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);

    // Emergency accounted the whole booking: X drained to 0, CHAIN0 now holds chain0Start + B.
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _bookedAtEmergency);

    // 4. Resume X (Active) and re-book it to `d`. Simulates a post-resume re-allocation: seed the re-booked
    // X position and total directly; leave CHAIN0 at its real post-emergency balance (chain0Start + B).
    uint128 _chain0AfterEmergency = _chain0Start + _bookedAtEmergency;
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _reallocSlope = _slopeOf(_reallocated);
    int128 _chain0Slope = _slopeOf(_chain0AfterEmergency);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _reallocSlope * _delta, _slope: _reallocSlope, _ts: _tAct, _perm: 0});
    _mockTotalPoint({
      _bias: (_reallocSlope + _chain0Slope) * _delta, _slope: _reallocSlope + _chain0Slope, _ts: _tAct, _perm: 0
    });
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _reallocated);
    uint256[] memory _reallocatedSet = new uint256[](2);
    _reallocatedSet[0] = _CHAIN0;
    _reallocatedSet[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _reallocatedSet);

    // 5. The held pre-suspension leaf `Deallocate{X_d}` return finally lands. Credit clamps to min(X_d, d) = X_d.
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, _heldReturn);
    vm.prank(_ORCHESTRATOR);
    _voter.processDeallocation(_CHAIN_ID_1, _TOKEN_ID, _heldReturn);

    // 6. Buggy outcome (documented, not desired):
    // it should double subtract the held amount leaving the origin chain below the reallocated budget
    // Root books `d - min(X_d, d) == d - X_d`, strictly below the `d` the leaf believes it holds.
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _reallocated - _heldReturn);
    assertLt(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _reallocated);
    // it should credit chain zero an extra time on top of the emergency drain
    // CHAIN0 already absorbed the full B at emergency; the late return credits an extra X_d.
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0AfterEmergency + _heldReturn);
  }

  /// @notice Whether `_chainId` is currently in `_TOKEN_ID`'s tracked allocation set.
  function _containsChain(uint256 _tokenId, uint256 _chainId) internal view returns (bool) {
    uint256[] memory _ids = _voter.allocationChainIds(_tokenId);
    for (uint256 _i; _i < _ids.length; ++_i) {
      if (_ids[_i] == _chainId) return true;
    }
    return false;
  }
}
