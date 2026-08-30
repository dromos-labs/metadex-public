// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoter, IVoter, IVoterCommon, Voter} from 'V3-test/unit/voter/BaseVoter.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVoterEmergencyDeallocate is BaseVoter {
  function test_WhenTheCallerIsNotAuthorizedForTheToken(address _caller) external {
    // The owner/operator gate runs first: an unauthorized caller is rejected before any state read.
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_caller, _TOKEN_ID)), abi.encode(false));

    // it should revert with NotAuthorized
    vm.prank(_caller);
    vm.expectRevert(IVoter.NotAuthorized.selector);
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsNotRegistered() external givenCallerIsAuthorized {
    // `_UNREGISTERED_CHAIN_ID` is deliberately kept out of the registered set in `setUp`. It is not in
    // `_chains`, so `isChainInStatus` fails the registered check and the status gate reverts.
    // it should revert with ChainNotSuspended
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotSuspended.selector, _UNREGISTERED_CHAIN_ID));
    _voter.emergencyDeallocate(_TOKEN_ID, _UNREGISTERED_CHAIN_ID, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsNotSuspended() external givenCallerIsAuthorized {
    // A registered but Active chain still routes through the normal leaf-first deallocate path,
    // so the emergency pull is rejected.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    // it should revert with ChainNotSuspended
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotSuspended.selector, _CHAIN_ID_1));
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsSunset() external givenCallerIsAuthorized {
    // A sunset chain keeps its normal exit paths, so the emergency pull is rejected. A dead or compromised
    // sunset chain flips to Suspended first and recovers through the branch above.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);

    // it should revert with ChainNotSuspended
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotSuspended.selector, _CHAIN_ID_1));
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsSuspendedButEmergencyDeallocationIsNotAllowed() external givenCallerIsAuthorized {
    // The chain is Suspended (so the `ChainNotSuspended` gate clears) but governance has not enabled
    // the per-suspension switch (it defaults false and is reset on every suspend). The second gate must fire
    // here, after the status check and before `MissingDestinationGasLimit`/the drain: a zero gas limit and
    // an empty booking are both seeded, yet the revert is the switch error, proving ordering.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, 0);

    // it should revert with EmergencyDeallocationNotAllowed
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.EmergencyDeallocationNotAllowed.selector, _CHAIN_ID_1));
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, 0, _REFUND_RECIPIENT);
  }

  function test_WhenTheDestinationGasLimitIsZeroForANonLocalChain() external givenCallerIsAuthorized {
    // `_CHAIN_ID_1` is a non-local Suspended chain, so a zero destination gas limit means the
    // emergency message could never be delivered. The gas-limit guard runs after the status check
    // and before any credit accounting.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    // Switch ON so the gate clears and the gas-limit guard is the check under test.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);

    // it should revert with MissingDestinationGasLimit
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, 0, _REFUND_RECIPIENT);
  }

  function test_WhenTheTokenHasNothingBookedOnTheSuspendedChain() external givenCallerIsAuthorized {
    // Chain is Suspended but root books nothing for the token there (already pulled, or never
    // allocated). The full-drain credit clamps to zero, so the pull reverts rather than no-op.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    // Switch ON so the gate clears and the empty-booking drain is the check under test.
    _mockEmergencyDeallocationAllowed(_CHAIN_ID_1, true);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, 0);

    // it should revert with NothingToDeallocate
    vm.prank(_CALLER);
    vm.expectRevert(IVoter.NothingToDeallocate.selector);
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheTokenHasVotingPowerBookedOnTheSuspendedChain(uint256 _value) external givenCallerIsAuthorized {
    // Full drain of a Suspended chain: the owner pulls the entire booked amount back to CHAIN0
    // without a leaf confirmation. Points anchored at the current timestamp so settlement is a
    // no-op and no decay (or suspended-surplus divergence) enters the move.
    _value = bound(_value, 0, 100 ether);
    vm.deal(_CALLER, _value);
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME
    vm.warp(_ts);

    // Suspended chain holds 1 AERO, CHAIN0 holds 3 AERO; committed = 4 AERO. Non-permanent stake
    // so contributions are slope*delta with delta = _stakeEnd - _tAct.
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
    // (`minterRate / totalWeight`) but deliberately NOT the exact post-drain value, so the resample assertion
    // below cannot pass on a stale scalar.
    uint48 _pendingWindow = 1 days;
    uint256 _pendingScalar = 2.5e18;
    _seedSuspendedPrior(_tAct - _pendingWindow, _stakeEnd, _onChain, _chain0Start, _committed);
    _mockEmissionsPerVP(_pendingScalar);
    _mockLastGlobalSettlement(_ts - _pendingWindow);

    // it should dispatch one EmergencyDeallocate message forwarding the value
    // The payload carries the drained amount (`_credit`), which for a full drain is the booked
    // `_onChain` — the same value credited to CHAIN0 and emitted below.
    _expectEmergencyDeallocateDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _value: _value,
      _message: IVoterCommon.EmergencyDeallocateMessage({tokenId: _TOKEN_ID, amount: _onChain})
    });

    // it should emit EmergencyDeallocated with the amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.EmergencyDeallocated(_CHAIN_ID_1, _TOKEN_ID, _onChain);

    vm.prank(_CALLER);
    _voter.emergencyDeallocate{value: _value}(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);

    // it should move the full booked amount from the suspended chain to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _onChain);

    // it should remove the suspended chain from the tokens allocation set
    assertFalse(_containsChain(_TOKEN_ID, _CHAIN_ID_1));
    assertTrue(_containsChain(_TOKEN_ID, _CHAIN0));

    // it should conserve the total weight across the full-drain move
    // The suspended chain drains to zero and CHAIN0 absorbs the full committed amount, so the
    // post-move total is the single CHAIN0 contribution `slopeOf(chain0Start + onChain)`.
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _totalSlope = _slopeOf(_chain0Start + _onChain);
    _assertTotalPoint(_voter, _totalSlope * _delta, _totalSlope, _tAct, 0);

    // Suspended chain point drained to zero, CHAIN0 point holds the full 4 AERO now.
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

    // it should route the suspended chain accrual into its cumulative suspended surplus keeping its ceiling frozen
    // it should accrue the chain zero ceiling from the global index delta over its decaying pre drain weight
    // `_settleChain` runs before the move. Each point sits a full `_pendingWindow` behind `_ts`, so settlement
    // decays it over the same window the global index advanced. For a constant scalar the exact segment accrual
    // is the average of the window-start and window-end weight times the index delta, taken with a single floor:
    // the suspended chain draws on its 1-AERO contribution and CHAIN0 on its 3-AERO one. The suspended chain's
    // share is tracked as surplus rather than redeemable ceiling.
    int128 _windowDelta = int128(uint128(_pendingWindow));
    uint256 _suspendedStartWeight = uint128(_slopeOf(_onChain) * (_delta + _windowDelta));
    uint256 _suspendedEndWeight = uint128(_slopeOf(_onChain) * _delta);
    uint256 _chain0StartWeight = uint128(_slopeOf(_chain0Start) * (_delta + _windowDelta));
    uint256 _chain0EndWeight = uint128(_slopeOf(_chain0Start) * _delta);
    assertEq(
      _chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus,
      ((_suspendedStartWeight + _suspendedEndWeight) * _indexDelta) / (2 * _PRECISION)
    );
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, 0);
    assertEq(
      _chainState(_voter, _CHAIN0).ceiling, ((_chain0StartWeight + _chain0EndWeight) * _indexDelta) / (2 * _PRECISION)
    );

    // it should resample the global emissions per voting power scalar against the post drain total weight
    // There is one global scalar now, and the credit path resamples it after the move: the suspended leaf is
    // sent no scalar, but the shared index carries the change to every chain including that one.
    uint128 _totalWeight = uint128(_totalSlope * _delta);
    uint256 _expectedEmissionsPerVP = (uint256(_MINTER_RATE) * _PRECISION) / _totalWeight;
    assertEq(_voter.emissionsPerVP(), _expectedEmissionsPerVP);
  }

  function test_WhenTheSuspendedChainIsTheLocalChain(uint256 _value) external givenCallerIsAuthorized {
    // The root-colocated leaf (`block.chainid`) is gas-exempt: the RootLocalAdapter delivers the
    // emergency message synchronously, so a zero destination gas limit is accepted and the drain still
    // dispatches with `gasLimit == 0`. Points anchored at the current timestamp so settlement no-ops.
    _value = bound(_value, 0, 100 ether);
    vm.deal(_CALLER, _value);
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME
    vm.warp(_ts);

    uint128 _onChain = _ONE_AERO;
    uint128 _chain0Start = 3 * _ONE_AERO;
    uint128 _committed = 4 * _ONE_AERO;

    _seedSuspendedPriorOn(block.chainid, _tAct, _stakeEnd, _onChain, _chain0Start, _committed);

    // it should dispatch one EmergencyDeallocate message with a zero gas limit forwarding the value
    // The payload carries the drained amount (`_credit`), which for a full drain is the booked
    // `_onChain` — the same value credited to CHAIN0 and emitted below.
    _expectEmergencyDeallocateDispatch({
      _chainId: block.chainid,
      _gasLimit: 0,
      _value: _value,
      _message: IVoterCommon.EmergencyDeallocateMessage({tokenId: _TOKEN_ID, amount: _onChain})
    });

    // it should emit EmergencyDeallocated with the amount
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.EmergencyDeallocated(block.chainid, _TOKEN_ID, _onChain);

    // it should not revert despite the zero gas limit
    vm.prank(_CALLER);
    _voter.emergencyDeallocate{value: _value}(_TOKEN_ID, block.chainid, 0, _REFUND_RECIPIENT);

    // it should move the full booked amount from the local chain to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, block.chainid), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _onChain);
  }

  function test_WhenDrainedTwiceOnTheSameChain(uint256 _value) external givenCallerIsAuthorized {
    // Post-drain idempotency: a first successful drain zeroes the token's booking on the suspended chain,
    // so a second `emergencyDeallocate` on the same token/chain finds nothing booked and reverts
    // `NothingToDeallocate`. The orchestrator is therefore dispatched exactly once across both calls.
    _value = bound(_value, 0, 100 ether);
    vm.deal(_CALLER, _value);
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _tAct = _ts;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _tAct + _MAXTIME
    vm.warp(_ts);

    uint128 _onChain = _ONE_AERO;
    uint128 _chain0Start = 3 * _ONE_AERO;
    uint128 _committed = 4 * _ONE_AERO;

    _seedSuspendedPrior(_tAct, _stakeEnd, _onChain, _chain0Start, _committed);

    // it should dispatch exactly one EmergencyDeallocate message across both calls
    // The single dispatch (from the first drain) carries the drained amount (`_credit`), which for a
    // full drain is the booked `_onChain`.
    _expectEmergencyDeallocateDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _value: _value,
      _message: IVoterCommon.EmergencyDeallocateMessage({tokenId: _TOKEN_ID, amount: _onChain})
    });

    // First drain succeeds and clears the booking.
    vm.prank(_CALLER);
    _voter.emergencyDeallocate{value: _value}(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);

    // it should revert NothingToDeallocate on the second drain
    vm.prank(_CALLER);
    vm.expectRevert(IVoter.NothingToDeallocate.selector);
    _voter.emergencyDeallocate(_TOKEN_ID, _CHAIN_ID_1, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /**
   * @notice Seed a prior `{suspended origin, CHAIN0}` allocation for `_TOKEN_ID` on `_CHAIN_ID_1`.
   * @dev Thin wrapper over `_seedSuspendedPriorOn` for the common non-local suspended chain.
   * @param _tAct Activation timestamp all points are anchored at.
   * @param _stakeEnd Non-permanent stake expiry (`> _tAct`).
   * @param _originAlloc Suspended-chain allocation.
   * @param _chain0Alloc CHAIN0 allocation.
   * @param _committed Token committed weight (drives totalPoint).
   */
  function _seedSuspendedPrior(
    uint48 _tAct,
    uint48 _stakeEnd,
    uint128 _originAlloc,
    uint128 _chain0Alloc,
    uint128 _committed
  ) internal {
    _seedSuspendedPriorOn(_CHAIN_ID_1, _tAct, _stakeEnd, _originAlloc, _chain0Alloc, _committed);
  }

  /**
   * @notice Seed a prior `{suspended origin, CHAIN0}` allocation for `_TOKEN_ID` anchored at `_tAct`.
   * @dev Mirrors the two-chain prior used by `processDeallocation`, but marks the origin chain
   *      `Suspended` so the emergency-pull path is exercised. Points sit at `_tAct` and each ceiling
   *      cursor at the current global `index`, so `_settleCeiling`/`_resolveWeight` early-exit and no decay
   *      enters the move. Non-permanent stake: `bias = slope * (stakeEnd - tAct)`, `perm = 0`.
   * @param _originChainId The suspended origin chain the prior allocation books on.
   * @param _tAct Activation timestamp all points are anchored at.
   * @param _stakeEnd Non-permanent stake expiry (`> _tAct`).
   * @param _originAlloc Suspended-chain allocation.
   * @param _chain0Alloc CHAIN0 allocation.
   * @param _committed Token committed weight (drives totalPoint).
   */
  function _seedSuspendedPriorOn(
    uint256 _originChainId,
    uint48 _tAct,
    uint48 _stakeEnd,
    uint128 _originAlloc,
    uint128 _chain0Alloc,
    uint128 _committed
  ) internal {
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _originSlope = _slopeOf(_originAlloc);
    int128 _chain0Slope = _slopeOf(_chain0Alloc);
    // totalPoint is the SUM of the per-chain contributions (each floored), NOT `slopeOf(committed)`.
    // The credit path mirrors per-chain swaps onto the total, so seeding the per-chain sum keeps the
    // intra-token move dust-free.
    _committed; // committed drives token state below, not the total slope
    int128 _totalSlope = _originSlope + _chain0Slope;

    _mockChainPoint({
      _chainId: _originChainId, _bias: _originSlope * _delta, _slope: _originSlope, _ts: _tAct, _perm: 0
    });
    _mockChainPoint({_chainId: _CHAIN0, _bias: _chain0Slope * _delta, _slope: _chain0Slope, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _totalSlope * _delta, _slope: _totalSlope, _ts: _tAct, _perm: 0});

    _mockChainLastIndex(_originChainId, _voter.index());
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainStatus(_originChainId, IVoterCommon.ChainStatus.Suspended);
    // The emergency switch being ON is a precondition for every drain scenario here (the gate itself
    // gets its own dedicated branch). Seed it directly rather than calling the setter.
    _mockEmergencyDeallocationAllowed(_originChainId, true);

    _mockAllocationChainAmount(_TOKEN_ID, _originChainId, _originAlloc);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _chain0Alloc);
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _originChainId;
    _mockExistingChainIds(_TOKEN_ID, _prior);

    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: _stakeEnd, _lastAllocated: _tAct});
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
