// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';

import {BaseVoter, IVoter, IVoterCommon, IVotingEscrow, Voter} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterAllocateChains is BaseVoter {
  // Shape-change scenario: prior allocation scheduled at `priorStakeEnd`; live VE stake's `end` has
  // moved to `newStakeEnd`. The token already books CHAIN_1 + CHAIN0. The caller redeploys CHAIN0
  // parked VP onto CHAIN_1 only; the shape change re-anchors every allocated chain (CHAIN_1 as part
  // of its add, CHAIN0 locally & free) to the new stake end.
  uint128 internal constant _SHAPE_STAKED = 1000 ether;
  uint128 internal constant _SHAPE_ALLOC_X = 300 ether;
  uint128 internal constant _SHAPE_ALLOC_0 = 200 ether;
  // Booked in-system total before the add (CHAIN_1 + CHAIN0), well below the live stake so the add fits.
  uint128 internal constant _SHAPE_COMMITTED = _SHAPE_ALLOC_X + _SHAPE_ALLOC_0;
  uint128 internal constant _SHAPE_ADD = 100 ether;

  struct ShapeChangeContext {
    uint48 tAct;
    int128 deltaNew;
    int128 biasTNew;
    uint48 priorStakeEnd;
    uint48 newStakeEnd;
    uint48 ts;
  }

  /*////////////////////////////////////////////////////////////
                 PRECONDITION REVERTS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheCallerIsNotApprovedOrOwnerOfTheTokenId(address _caller) external {
    // Caller is the only fuzzed input — the assertion is "any non-authorized caller reverts".
    _assumeFuzzable(_caller);

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_caller, _TOKEN_ID)), abi.encode(false));

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IVoter.NotAuthorized.selector);
    _voter.allocateChains(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _REFUND_RECIPIENT);
  }

  function test_WhenTheChainDispatchListIsEmptyAndValueIsAttached(uint256 _value) external givenCallerIsAuthorized {
    // An empty list is a pure-local shape refresh that dispatches nothing, so attached value would be
    // trapped in the Voter. It must be rejected rather than silently kept.
    _value = bound(_value, 1, 100 ether);
    vm.deal(_CALLER, _value);

    // it should revert with UnexpectedValue
    vm.prank(_CALLER);
    vm.expectRevert(IVoterCommon.UnexpectedValue.selector);
    _voter.allocateChains{value: _value}(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _REFUND_RECIPIENT);
  }

  function test_WhenTheTokenIdStakeHasExpiredBeforeTAct(
    uint128 _amount,
    uint48 _stakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Fuzz `_amount`, `_stakeEnd`, `_ts` — they drive the expiry check.
    _amount = uint128(bound(_amount, 0, _INT128_MAX));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max));
    // Non-permanent stake that has already expired at T_act. Root anchors T_act at
    // `block.timestamp`, so any `stakeEnd <= _ts` trips the expiry guard.
    _stakeEnd = uint48(bound(_stakeEnd, 1, _ts));

    vm.warp(_ts);

    // Non-empty allocation to reach the expiry guard.
    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _amount, _end: _stakeEnd, _isPermanent: false});

    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  function test_WhenTheStakeWasWithdrawnButStaleBookingsRemain() external givenCallerIsAuthorized {
    // Regression for the withdrawn-stake resurrection bug. `withdraw` in VotingEscrow zeroes the
    // StakedBalance to `{amount: 0, end: 0, isPermanent: false}` WITHOUT burning the NFT, so the
    // Voter's stale bookings from a prior decaying allocation survive. The `staked == 0` guard in
    // `_requireLiveStake` is what catches this: without it the shape change would re-anchor the stale
    // `allocationChainAmounts[CHAIN_1]` and resurrect a withdrawn token's weight. A withdrawn stake
    // must revert.
    //
    // Concrete (non-fuzzed) seed so the resurrected amount is unambiguous: the token holds one
    // decaying position of 300 AERO on CHAIN_1, anchored to a non-zero prior stake end.
    uint48 _tAct = _INITIAL_TIMESTAMP; // setUp already warped here; T_act == now
    uint48 _priorStakeEnd = _INITIAL_TIMESTAMP + _MAXTIME; // non-zero prior expiry (stored shape)
    uint128 _staleAlloc = 300 ether;

    // Prior decaying allocation on CHAIN_1: allocationChainAmounts + committed + lastStakeEnd, with
    // the matching contribution booked into the chain point and totalPoint. Pre-call permanent
    // balance on both points is 0.
    _seedSingleChainPriorVote({
      _tokenId: _TOKEN_ID,
      _chainId: _CHAIN_ID_1,
      _chainAlloc: _staleAlloc,
      _stakeEnd: _priorStakeEnd,
      _tAct: _tAct,
      _ts: _INITIAL_TIMESTAMP
    });

    // VE now reports the WITHDRAWN state: zeroed amount, zeroed end, not permanent. NFT ownership is
    // unchanged so `onlyAuthorizedForToken` still passes.
    _mockStaked({_amount: 0, _end: uint48(0), _isPermanent: false});

    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocateChains(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _REFUND_RECIPIENT);
  }

  function test_WhenTheDeltaExceedsTheChainZeroParkedAmount(
    uint128 _parked,
    uint128 _overshoot,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Chain allocations draw ONLY from CHAIN0-parked VP — never from unbooked headroom. Seed live-but-
    // unbooked headroom (`_overshoot`) and a delta that fits within `chain0Parked + unbooked` yet exceeds
    // `chain0Parked`: it must still revert, proving unbooked cannot fund an allocation.
    _parked = uint128(bound(_parked, 1, _INT128_MAX_HALF / 2));
    _overshoot = uint128(bound(_overshoot, 1, _INT128_MAX_HALF / 2));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    vm.warp(_ts);

    // Permanent stake keeps the seed shape-free. committed == chain0Parked; the extra `_overshoot` is
    // live-but-unbooked headroom that the strict bound must ignore.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _parked});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _parked, _lastStakeEnd: uint48(0), _lastAllocated: 0});
    _mockStaked({_amount: _parked + _overshoot, _end: uint48(0), _isPermanent: true});

    // delta == chain0Parked + unbooked: inside the live stake, but above the parked balance.
    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _parked + _overshoot, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    // it should revert with InsufficientChain0Allocation
    vm.expectRevert(IVoter.InsufficientChain0Allocation.selector);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  function test_WhenTheDeltaEqualsTheChainZeroParkedAmount(
    uint128 _parked,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Boundary: delta == parked moves the whole CHAIN0 balance onto the listed chain and drains CHAIN0.
    // Permanent stake so the move touches only `perm`; committed stays put (committed-neutral).
    _parked = uint128(bound(_parked, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _parked});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _parked, _lastStakeEnd: uint48(0), _lastAllocated: 0});
    _mockStaked({_amount: _parked, _end: uint48(0), _isPermanent: true});

    // it should dispatch the whole drained balance as one AllocateChain entry to the listed chain
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _parked,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _parked),
        snapshot: IVoterCommon.TokenSnapshot({staked: _parked, stakeEnd: uint48(0), isPermanent: true})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID,
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _parked, _gasLimit: _GAS_LIMIT}),
      _REFUND_RECIPIENT
    );

    // it should fully drain chain zero to zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    // it should remove chain zero from the set
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 1);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _parked);
    // it should leave committed unchanged
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _parked, _lastStakeEnd: uint48(0), _lastAllocated: _ts
    });
    _assertChainPoint({_target: _voter, _chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    // total point stays at _parked (neutral move: +_parked on CHAIN_ID_1, -_parked on CHAIN0)
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
  }

  function test_WhenAChainInTheDispatchScopeIsNotRegistered() external givenCallerIsAuthorized givenTheStakeIsLive {
    // The entrypoint snapshots the live stake first, then `_validateAllocations` rejects the chain.
    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _UNREGISTERED_CHAIN_ID, _amount: 1, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    // it should revert with ChainNotActive
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActive.selector, _UNREGISTERED_CHAIN_ID));
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
            ALLOCATIONS ARRAY VALIDATION
  ////////////////////////////////////////////////////////////*/
  modifier whenTheAllocationsArrayIsInvalid() {
    _;
  }

  function test_WhenAllocationChainIdsAreNotStrictlyAscending()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheAllocationsArrayIsInvalid
  {
    // Two chainIds in non-ascending order — `_CHAIN_ID_2 > _CHAIN_ID_1` by construction in
    // BaseVoter, so placing `_CHAIN_ID_2` first and `_CHAIN_ID_1` second trips the check.
    IVoter.ChainAllocationDispatch[] memory _allocations = new IVoter.ChainAllocationDispatch[](2);
    _allocations[0] = IVoter.ChainAllocationDispatch({chainId: _CHAIN_ID_2, delta: 1, gasLimit: _GAS_LIMIT, value: 0});
    _allocations[1] = IVoter.ChainAllocationDispatch({chainId: _CHAIN_ID_1, delta: 1, gasLimit: _GAS_LIMIT, value: 0});

    vm.prank(_CALLER);
    // it should revert with AllocationsNotStrictlyAscending
    vm.expectRevert(IVoter.AllocationsNotStrictlyAscending.selector);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  function test_WhenAChainIsNotActive(bool _suspended)
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheAllocationsArrayIsInvalid
  {
    // Fuzz only `_suspended` — covers the two halted statuses (Paused / Suspended) hitting the same
    // revert in `_validateAllocations`; the Sunset case is pinned separately below.
    _mockChainStatus({
      _chainId: _CHAIN_ID_1, _status: _suspended ? IVoterCommon.ChainStatus.Suspended : IVoterCommon.ChainStatus.Paused
    });

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    // it should revert with ChainNotActive
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActive.selector, _CHAIN_ID_1));
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  function test_WhenAChainIsSunset()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheAllocationsArrayIsInvalid
  {
    // The core sunset intent: no new power can enter a winding-down chain, so the direct chain
    // allocation is rejected while the gauge path stays open only for the sentinel exit.
    _mockChainStatus({_chainId: _CHAIN_ID_1, _status: IVoterCommon.ChainStatus.Sunset});

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    // it should revert with ChainNotActive
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActive.selector, _CHAIN_ID_1));
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  function test_WhenALeafChainEntryHasZeroGasLimit()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheAllocationsArrayIsInvalid
  {
    // A non-root entry with `gasLimit == 0` trips the destination-gas guard in `_validateAllocations`,
    // during the upfront input pass.
    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: 0});

    vm.prank(_CALLER);
    // it should revert with MissingDestinationGasLimit
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              ADDITIVE ADDS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheTokenIdAllocatesAChainFromParkedChainZeroVp(
    uint128 _delta,
    uint48 _ts,
    uint48 _stakeEnd
  ) external givenCallerIsAuthorized {
    // Strict model: the token has parked `_delta` on CHAIN0; the add redeploys it onto the listed
    // chain. The move is committed-neutral (VP shifts off CHAIN0, committed unchanged) and CHAIN0
    // drains to zero and leaves the set.
    uint48 _tAct;
    _delta = uint128(bound(_delta, _MAXTIME, _INT128_MAX_HALF));
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    // Post-state: the whole `_delta` lands on CHAIN_ID_1, CHAIN0 drains to zero, totalPoint unchanged.
    ExpectedContribution memory _expected =
      _computeExpected({_allocated: _delta, _chain0: 0, _booked: _delta, _tAct: _tAct, _stakeEnd: _stakeEnd});

    // Prior: `_delta` parked on CHAIN0 at the token shape; CHAIN_ID_1 empty. totalPoint carries the
    // parked contribution, committed == the parked amount, and the set holds only CHAIN0.
    _mockChainPoint({_chainId: _CHAIN0, _bias: _expected.biasX, _slope: _expected.slopeX, _ts: _tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _expected.biasT, _slope: _expected.slopeT, _ts: _tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _delta});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _delta, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _delta, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _delta, _end: _stakeEnd, _isPermanent: false});

    // it should call MessageOrchestrator dispatch with one AllocateChain entry carrying the delta
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _delta,
        emissionsPerVP: _expected.emissionsPerVP,
        snapshot: IVoterCommon.TokenSnapshot({staked: _delta, stakeEnd: _stakeEnd, isPermanent: false})
      })
    });

    // it should emit the ChainsAllocated event carrying the dispatch array
    _expectEmit(address(_voter));
    emit IVoter.ChainsAllocated(_TOKEN_ID, _allocations);

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should leave committed unchanged
    // it should set lastStakeEnd to the live stake end
    // it should set lastAllocated to the block timestamp
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _delta, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts
    });

    // it should store the per chain allocated amount
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _delta);
    // it should drain chain zero to zero and remove it from the set
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 1);

    // it should advance the global settlement to T act and anchor the listed chain cursor at the index
    assertEq(_voter.lastGlobalSettlement(), _tAct);
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());

    // it should move the delta contribution onto the listed chain point and keep totalPoint neutral
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: _expected.biasX, _slope: _expected.slopeX, _ts: _tAct, _perm: 0
    });
    _assertTotalPoint({_target: _voter, _bias: _expected.biasT, _slope: _expected.slopeT, _ts: _tAct, _perm: 0});

    // it should resample the global emissionsPerVP against the post add total weight
    assertEq(_voter.emissionsPerVP(), _expected.emissionsPerVP);
  }

  function test_WhenTheTokenIdAddsToASecondChainAcrossCalls(
    uint128 _priorX,
    uint128 _deltaY,
    uint48 _ts,
    uint48 _stakeEnd
  ) external givenCallerIsAuthorized {
    // Cross-call partial add: the token books `_priorX` on CHAIN_1 and parks `_deltaY` on CHAIN0
    // (permanent shape). The caller redeploys `_deltaY` onto CHAIN_2 only. CHAIN_1 stays untouched and
    // receives NO message; the move is committed-neutral (VP shifts off CHAIN0) and CHAIN0 drains.
    _priorX = uint128(bound(_priorX, 1, _INT128_MAX_HALF));
    _deltaY = uint128(bound(_deltaY, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    _stakeEnd; // unused: permanent stake
    uint128 _staked = _priorX + _deltaY;
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    // Prior: CHAIN_1 books `_priorX` permanently; committed == _priorX; nothing else booked.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: _priorX});
    _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _deltaY});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _staked});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN_ID_2, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _priorX});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _deltaY});
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _CHAIN_ID_1;
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _prior});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _staked, _lastStakeEnd: uint48(0), _lastAllocated: _ts});

    _mockStaked({_amount: _staked, _end: uint48(0), _isPermanent: true});

    // it should dispatch only the second chain carrying its delta (no CHAIN_1 entry)
    uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, _staked);
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_2,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _deltaY,
        emissionsPerVP: _expectedEmissionsPerVP,
        snapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: uint48(0), isPermanent: true})
      })
    });

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_2, _amount: _deltaY, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should leave the first chain amount unchanged
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _priorX);
    // it should store the second chain amount
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_2), _deltaY);
    // it should drain chain zero and remove it from the set (CHAIN_1 + CHAIN_2 remain)
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 2);
    // it should leave committed unchanged (committed-neutral move off CHAIN0)
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _staked, _lastStakeEnd: uint48(0), _lastAllocated: _ts
    });

    // it should leave the first chain point unchanged (untouched by a partial add on CHAIN_2)
    _assertChainPoint({_target: _voter, _chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: _priorX});
    // CHAIN_2 booked its delta permanently.
    _assertChainPoint({_target: _voter, _chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _ts, _perm: _deltaY});
    // totalPoint carries both booked contributions.
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _ts, _perm: _staked});
  }

  /*////////////////////////////////////////////////////////////
              PERMANENT STAKE
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheTokenIdHasAPermanentStake(
    uint128 _delta,
    uint128 _remainder,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Permanent stake: `_delta` is parked on CHAIN0's `permanentStakeBalance`; the add redeploys it
    // onto CHAIN_1's `permanentStakeBalance` (bias/slope stay 0). The move is committed-neutral, CHAIN0
    // drains, and the unbooked `_remainder` is never touched.
    _delta = uint128(bound(_delta, 1, _INT128_MAX_HALF));
    _remainder = uint128(bound(_remainder, 0, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    uint48 _tAct = _ts;
    uint128 _staked = _delta + _remainder;
    // Propagation: emissionsPerVP is the GLOBAL scalar mulDiv(MINTER_RATE, PRECISION, totalWeight).
    // For a permanent stake, weight = `permanentStakeBalance` (bias clamped to 0). Only `_delta` is
    // booked, so totalWeight == _delta.
    uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, _delta);

    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _delta});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: _delta});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _delta});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _delta, _lastStakeEnd: uint48(0), _lastAllocated: 0});

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _delta, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _staked, _end: uint48(0), _isPermanent: true});

    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _delta,
        emissionsPerVP: _expectedEmissionsPerVP,
        snapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: uint48(0), isPermanent: true})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should leave committed unchanged and lastStakeEnd at zero
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _delta, _lastStakeEnd: uint48(0), _lastAllocated: _ts
    });
    // it should drain chain zero and remove it from the set
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    assertEq(_voter.allocationChainIds(_TOKEN_ID).length, 1);

    // it should add the delta to permanentStakeBalance on the chain point
    // it should leave bias and slope unchanged on the chain point
    _assertChainPoint({_target: _voter, _chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: _delta});
    // it should add the delta to totalPoint permanentStakeBalance
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: _delta});

    // it should not schedule a slope reduction (permanent path doesn't touch slopeChanges).
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, 0), int128(0));
    assertEq(_voter.totalSlopeChanges(0), int128(0));

    // emissionsPerVP is resampled as the global scalar against the post-add total weight.
    assertEq(_voter.emissionsPerVP(), _expectedEmissionsPerVP);
  }

  /*////////////////////////////////////////////////////////////
              SHAPE CHANGE RE-ANCHOR
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheStakeShapeHasChangedAndTheCallerAddsToOneChain(
    uint48 _priorStakeEnd,
    uint48 _newStakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Token books CHAIN_1 (300) + CHAIN0 (200); committed = 500; live stake = 1000. The caller
    // redeploys 100 onto CHAIN_1 (drawn from CHAIN0's parked 200) while the live stake shape moved
    // from `priorStakeEnd` to `newStakeEnd`. The shape change re-anchors every allocated chain to
    // `newStakeEnd`: CHAIN_1 as part of its add, CHAIN0 locally & free (no dispatch). The move is
    // committed-neutral, so committed stays 500 and CHAIN0 drops 200 -> 100.
    ShapeChangeContext memory _context;
    (_context.ts, _context.tAct, _context.newStakeEnd) = _setupFutureVote(_ts, _newStakeEnd);
    _context.priorStakeEnd = uint48(bound(_priorStakeEnd, _context.tAct + 1, _context.tAct + _MAXTIME));
    // The two stake ends must differ — that's what makes this the "shape change" scenario.
    vm.assume(_context.priorStakeEnd != _context.newStakeEnd);
    _context.deltaNew = int128(uint128(_context.newStakeEnd - _context.tAct));

    uint128 _newX = _SHAPE_ALLOC_X + _SHAPE_ADD;
    // Committed-neutral: the add is drawn from CHAIN0, so committed stays put.
    uint128 _newCommitted = _SHAPE_COMMITTED;
    // Re-anchored total weight after the add. totalPoint is the SUM of per-chain contributions, each
    // with its own floored slope — so compute it as `slopeX + slope0`, not `slopeOf(sum)`. CHAIN0
    // dropped by `_SHAPE_ADD` (redeployed onto CHAIN_1).
    int128 _slopeTNew = _slopeOf(_newX) + _slopeOf(_SHAPE_ALLOC_0 - _SHAPE_ADD);
    _context.biasTNew = _slopeTNew * _context.deltaNew;

    {
      uint256[] memory _existingArr = new uint256[](2);
      _existingArr[0] = _CHAIN0;
      _existingArr[1] = _CHAIN_ID_1;
      _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _existingArr});

      int128 _slopeX = _slopeOf(_SHAPE_ALLOC_X);
      int128 _slope0 = _slopeOf(_SHAPE_ALLOC_0);
      // totalPoint is the sum of the per-chain contributions — seed it that way so the per-chain
      // re-anchor swaps cancel exactly (no `slopeOf(sum)` flooring mismatch).
      int128 _slopeT = _slopeX + _slope0;
      int128 _deltaPrior = int128(uint128(_context.priorStakeEnd - _context.tAct));

      _mockChainPoint({
        _chainId: _CHAIN_ID_1, _bias: _slopeX * _deltaPrior, _slope: _slopeX, _ts: _context.tAct, _perm: 0
      });
      _mockChainPoint({_chainId: _CHAIN0, _bias: _slope0 * _deltaPrior, _slope: _slope0, _ts: _context.tAct, _perm: 0});
      _mockTotalPoint({_bias: _slopeT * _deltaPrior, _slope: _slopeT, _ts: _context.tAct, _perm: 0});

      // Prior slope schedule at the prior stake-end. Post-vote this is zeroed and re-scheduled
      // at the new stake-end.
      _mockChainSlopeChange({_chainId: _CHAIN_ID_1, _expiry: _context.priorStakeEnd, _value: _slopeX});
      _mockChainSlopeChange({_chainId: _CHAIN0, _expiry: _context.priorStakeEnd, _value: _slope0});
      _mockTotalSlopeChange(_context.priorStakeEnd, _slopeT);

      _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _SHAPE_ALLOC_X});
      _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _SHAPE_ALLOC_0});
      _mockTokenState({
        _tokenId: _TOKEN_ID,
        _committed: _SHAPE_COMMITTED,
        _lastStakeEnd: _context.priorStakeEnd,
        _lastAllocated: _context.ts
      });
      _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
      _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    }

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _SHAPE_ADD, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _SHAPE_STAKED, _end: _context.newStakeEnd, _isPermanent: false});

    {
      // Only CHAIN_1 (listed) is dispatched, carrying its delta and the new snapshot. CHAIN0 is
      // re-anchored locally with no dispatch.
      uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, uint128(_context.biasTNew));
      _expectSingleChainDispatch({
        _chainId: _CHAIN_ID_1,
        _gasLimit: _GAS_LIMIT,
        _message: IVoterCommon.AllocateChainMessage({
          tokenId: _TOKEN_ID,
          allocationDelta: _SHAPE_ADD,
          emissionsPerVP: _expectedEmissionsPerVP,
          snapshot: IVoterCommon.TokenSnapshot({
            staked: _SHAPE_STAKED, stakeEnd: _context.newStakeEnd, isPermanent: false
          })
        })
      });
    }

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should set lastStakeEnd to the live stake end
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID,
      _committed: _newCommitted,
      _lastStakeEnd: _context.newStakeEnd,
      _lastAllocated: _context.ts
    });

    int128 _slopeXNew = _slopeOf(_newX);
    int128 _slope0New = _slopeOf(_SHAPE_ALLOC_0 - _SHAPE_ADD);

    // it should re-anchor every allocated chain to the new stake end
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN_ID_1,
      _bias: _slopeXNew * _context.deltaNew,
      _slope: _slopeXNew,
      _ts: _context.tAct,
      _perm: 0
    });
    // it should re-anchor chain zero to the new stake end
    _assertChainPoint({
      _target: _voter,
      _chainId: _CHAIN0,
      _bias: _slope0New * _context.deltaNew,
      _slope: _slope0New,
      _ts: _context.tAct,
      _perm: 0
    });
    _assertTotalPoint({
      _target: _voter, _bias: _slopeTNew * _context.deltaNew, _slope: _slopeTNew, _ts: _context.tAct, _perm: 0
    });

    // it should move the prior slope schedule entries to the live stakeEnd
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _context.priorStakeEnd), int128(0));
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _context.priorStakeEnd), int128(0));
    assertEq(_voter.totalSlopeChanges(_context.priorStakeEnd), int128(0));
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _context.newStakeEnd), _slopeXNew);
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _context.newStakeEnd), _slope0New);
    assertEq(_voter.totalSlopeChanges(_context.newStakeEnd), _slopeTNew);

    // it should draw the delta from chain zero (no message) and grow only the listed chain
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _SHAPE_ALLOC_0 - _SHAPE_ADD);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _newX);
  }

  function test_WhenTheStakeShapeChangedToPermanentAndTheCallerAddsToOneChain(
    uint48 _priorStakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Regression for the re-anchor permanence-flip: stored shape DECAYING, live shape PERMANENT, plus a delta on
    // an already-allocated chain. The re-anchor moves every chain onto the permanent balance; the following
    // delta must unwind at the re-anchored (permanent) shape, not the stale stored (decaying) one — else the
    // unwind subtracts nothing and `permanentStakeBalance` doubles. Same 300/200 book; add 100 to CHAIN_1.
    uint48 _tAct;
    (_ts, _tAct,) = _setupFutureVote(_ts, uint48(_INITIAL_TIMESTAMP + 1));
    _priorStakeEnd = uint48(bound(_priorStakeEnd, _tAct + 1, _tAct + _MAXTIME));
    int128 _deltaPrior = int128(uint128(_priorStakeEnd - _tAct));

    int128 _slopeX = _slopeOf(_SHAPE_ALLOC_X);
    int128 _slope0 = _slopeOf(_SHAPE_ALLOC_0);
    int128 _slopeT = _slopeX + _slope0;

    {
      uint256[] memory _existingArr = new uint256[](2);
      _existingArr[0] = _CHAIN0;
      _existingArr[1] = _CHAIN_ID_1;
      _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _existingArr});

      _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _slopeX * _deltaPrior, _slope: _slopeX, _ts: _tAct, _perm: 0});
      _mockChainPoint({_chainId: _CHAIN0, _bias: _slope0 * _deltaPrior, _slope: _slope0, _ts: _tAct, _perm: 0});
      _mockTotalPoint({_bias: _slopeT * _deltaPrior, _slope: _slopeT, _ts: _tAct, _perm: 0});
      _mockChainSlopeChange({_chainId: _CHAIN_ID_1, _expiry: _priorStakeEnd, _value: _slopeX});
      _mockChainSlopeChange({_chainId: _CHAIN0, _expiry: _priorStakeEnd, _value: _slope0});
      _mockTotalSlopeChange(_priorStakeEnd, _slopeT);
      _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _SHAPE_ALLOC_X});
      _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _SHAPE_ALLOC_0});
      _mockTokenState({
        _tokenId: _TOKEN_ID, _committed: _SHAPE_COMMITTED, _lastStakeEnd: _priorStakeEnd, _lastAllocated: _ts
      });
      _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
      _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    }

    // Live stake is now PERMANENT.
    _mockStaked({_amount: _SHAPE_STAKED, _end: 0, _isPermanent: true});

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _SHAPE_ADD, _gasLimit: _GAS_LIMIT});

    // Total weight after the re-anchor is the permanent committed (500), so the resampled scalar divides by it.
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _SHAPE_ADD,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _SHAPE_COMMITTED),
        snapshot: IVoterCommon.TokenSnapshot({staked: _SHAPE_STAKED, stakeEnd: 0, isPermanent: true})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should re-anchor every allocated chain onto the permanent balance with no double count
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: _SHAPE_ALLOC_X + _SHAPE_ADD
    });
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: _SHAPE_ALLOC_0 - _SHAPE_ADD
    });
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _tAct, _perm: _SHAPE_COMMITTED});

    // it should clear the prior decaying slope schedule and add no permanent schedule
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _priorStakeEnd), int128(0));
    assertEq(_voter.chainSlopeChanges(_CHAIN0, _priorStakeEnd), int128(0));
    assertEq(_voter.totalSlopeChanges(_priorStakeEnd), int128(0));

    // it should store the permanent shape
    (,,, bool _isPermanent) = _voter.tokenStates(_TOKEN_ID);
    assertTrue(_isPermanent);
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _SHAPE_COMMITTED, _lastStakeEnd: 0, _lastAllocated: _ts
    });
  }

  function test_WhenADeltaZeroRefreshIsSuppliedWithChainZeroParked(
    uint128 _real,
    uint128 _parked,
    uint128 _unbooked,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // A `delta == 0` refresh on an existing real chain with CHAIN0 parked: `fromChain0 == 0`, so CHAIN0
    // is untouched and committed is unchanged. The token books `_real` on CHAIN_1 and `_parked` on
    // CHAIN0; the caller refreshes CHAIN_1 with delta 0.
    _real = uint128(bound(_real, 1, _INT128_MAX / 8));
    _parked = uint128(bound(_parked, 1, _INT128_MAX / 8));
    _unbooked = uint128(bound(_unbooked, 0, _INT128_MAX / 8));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    uint128 _committed = _real + _parked;
    uint128 _veStaked = _committed + _unbooked;

    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: _real});
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _committed});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _real});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _parked});
    uint256[] memory _existingArr = new uint256[](2);
    _existingArr[0] = _CHAIN0;
    _existingArr[1] = _CHAIN_ID_1;
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _existingArr});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: uint48(0), _lastAllocated: 0});

    _mockStaked({_amount: _veStaked, _end: uint48(0), _isPermanent: true});

    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 0, _gasLimit: _GAS_LIMIT});

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should leave chain zero parked untouched
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _parked);
    _assertChainPoint({_target: _voter, _chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});

    // it should leave committed unchanged
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: uint48(0), _lastAllocated: _ts
    });
    // Real chain amount and totalPoint unchanged by a delta-0 refresh at the same shape.
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _real);
    _assertTotalPoint({_target: _voter, _bias: 0, _slope: 0, _ts: _ts, _perm: _committed});
  }

  /*////////////////////////////////////////////////////////////
              DELTA ZERO REFRESH
  ////////////////////////////////////////////////////////////*/
  function test_WhenADeltaZeroRefreshEntryIsSuppliedAndTheShapeChanged(
    uint48 _priorStakeEnd,
    uint48 _newStakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Token books CHAIN_1 at the prior shape. The live shape moved, and the caller submits a
    // `delta == 0` refresh on CHAIN_1: re-anchor its position to the new shape and ship a
    // delta-0 message with the new snapshot. `committed` is unchanged.
    uint48 _tAct;
    (_ts, _tAct, _newStakeEnd) = _setupFutureVote(_ts, _newStakeEnd);
    _priorStakeEnd = uint48(bound(_priorStakeEnd, _tAct + 1, _tAct + _MAXTIME));
    vm.assume(_priorStakeEnd != _newStakeEnd);
    int128 _slopeX = _slopeOf(_SHAPE_ALLOC_X);

    {
      int128 _deltaPrior = int128(uint128(_priorStakeEnd - _tAct));
      _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _slopeX * _deltaPrior, _slope: _slopeX, _ts: _tAct, _perm: 0});
      _mockTotalPoint({_bias: _slopeX * _deltaPrior, _slope: _slopeX, _ts: _tAct, _perm: 0});
      _mockChainSlopeChange({_chainId: _CHAIN_ID_1, _expiry: _priorStakeEnd, _value: _slopeX});
      _mockTotalSlopeChange(_priorStakeEnd, _slopeX);
      _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _SHAPE_ALLOC_X});
      _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN_ID_1)});
      _mockTokenState({
        _tokenId: _TOKEN_ID, _committed: _SHAPE_ALLOC_X, _lastStakeEnd: _priorStakeEnd, _lastAllocated: _ts
      });
      _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    }

    _mockStaked({_amount: _SHAPE_STAKED, _end: _newStakeEnd, _isPermanent: false});

    int128 _deltaNew = int128(uint128(_newStakeEnd - _tAct));

    // it should dispatch the chain with a zero allocation delta and the new snapshot
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: 0,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, uint128(_slopeX * _deltaNew)),
        snapshot: IVoterCommon.TokenSnapshot({staked: _SHAPE_STAKED, stakeEnd: _newStakeEnd, isPermanent: false})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(
      _TOKEN_ID, _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 0, _gasLimit: _GAS_LIMIT}), _REFUND_RECIPIENT
    );

    // it should re-anchor the chain to the live stake end (amount unchanged, new shape)
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: _slopeX * _deltaNew, _slope: _slopeX, _ts: _tAct, _perm: 0
    });
    _assertTotalPoint({_target: _voter, _bias: _slopeX * _deltaNew, _slope: _slopeX, _ts: _tAct, _perm: 0});
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _priorStakeEnd), int128(0));
    assertEq(_voter.chainSlopeChanges(_CHAIN_ID_1, _newStakeEnd), _slopeX);
    // committed is unchanged by a refresh.
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _SHAPE_ALLOC_X, _lastStakeEnd: _newStakeEnd, _lastAllocated: _ts
    });
  }

  function test_WhenADeltaZeroRefreshEntryIsSuppliedButTheShapeDidNotChange(
    uint48 _stakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Shape unchanged (`veStakeEnd == lastStakeEnd`) + `delta == 0` on a chain the token already holds
    // (`old > 0`): a refresh poke. The re-anchor short-circuits (same amount, same shape) so root state
    // is untouched, but a delta-0 message still ships so the leaf settles its index.
    uint48 _tAct;
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _seedSingleChainPriorVote({
      _tokenId: _TOKEN_ID,
      _chainId: _CHAIN_ID_1,
      _chainAlloc: _SHAPE_ALLOC_X,
      _stakeEnd: _stakeEnd,
      _tAct: _tAct,
      _ts: _ts
    });

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 0, _gasLimit: _GAS_LIMIT});

    // Live stake shape equals the stored shape → shape unchanged.
    _mockStaked({_amount: _SHAPE_STAKED, _end: _stakeEnd, _isPermanent: false});

    int128 _slopeX = _slopeOf(_SHAPE_ALLOC_X);
    int128 _delta = int128(uint128(_stakeEnd - _tAct));

    // it should dispatch the chain with a zero allocation delta and the current snapshot
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: 0,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, uint128(_slopeX * _delta)),
        snapshot: IVoterCommon.TokenSnapshot({staked: _SHAPE_STAKED, stakeEnd: _stakeEnd, isPermanent: false})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should leave the chain point and total point unchanged
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0
    });
    _assertTotalPoint({_target: _voter, _bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0});
    // it should leave committed unchanged
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _SHAPE_ALLOC_X, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts
    });
  }

  function test_WhenADeltaZeroRefreshEntryIsSuppliedForAChainWithNoPosition(
    uint48 _stakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // A position-free poke: the token books only CHAIN_1, yet refreshes CHAIN_2. This is the supported way to
    // keep a quiet chain's leaf in step with root, so it must ship the message and leave the token untouched.
    uint48 _tAct;
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _seedSingleChainPriorVote({
      _tokenId: _TOKEN_ID,
      _chainId: _CHAIN_ID_1,
      _chainAlloc: _SHAPE_ALLOC_X,
      _stakeEnd: _stakeEnd,
      _tAct: _tAct,
      _ts: _ts
    });

    // The poked chain is registered but empty, with its point already resolved to the prior vote: `_settleCeiling`
    // walks week boundaries from the stored `ts`, so leaving it at registration time would make the fuzz's
    // far-future warp walk millions of weeks. A chain that anyone has voted on recently looks like this.
    _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});

    IVoter.ChainAllocationDispatch[] memory _allocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_2, _amount: 0, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _SHAPE_STAKED, _end: _stakeEnd, _isPermanent: false});

    int128 _slopeX = _slopeOf(_SHAPE_ALLOC_X);
    int128 _delta = int128(uint128(_stakeEnd - _tAct));

    // it should dispatch the poked chain with a zero allocation delta and the current snapshot
    _expectSingleChainDispatch({
      _chainId: _CHAIN_ID_2,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: 0,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, uint128(_slopeX * _delta)),
        snapshot: IVoterCommon.TokenSnapshot({staked: _SHAPE_STAKED, stakeEnd: _stakeEnd, isPermanent: false})
      })
    });

    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, _allocations, _REFUND_RECIPIENT);

    // it should book nothing for the token on the poked chain
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_2), 0);
    // it should not add the poked chain to the tokens allocation set
    uint256[] memory _trackedChains = _voter.allocationChainIds(_TOKEN_ID);
    assertEq(_trackedChains.length, 1);
    assertEq(_trackedChains[0], _CHAIN_ID_1);
    // it should leave the poked chain point empty
    _assertChainPoint({_target: _voter, _chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    // it should leave the held chain point and the total point unchanged
    _assertChainPoint({
      _target: _voter, _chainId: _CHAIN_ID_1, _bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0
    });
    _assertTotalPoint({_target: _voter, _bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0});
    // it should leave committed unchanged
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: _SHAPE_ALLOC_X, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts
    });
  }
}
