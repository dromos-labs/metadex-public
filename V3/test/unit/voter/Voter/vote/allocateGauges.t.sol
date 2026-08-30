// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';

import {DEALLOC_GAUGE} from 'V3/libraries/ProtocolConstants.sol';

import {BaseVoter, IVoter, IVoterCommon, IVotingEscrow} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterAllocateGauges is BaseVoter {
  function test_WhenTheCallerIsNotApprovedOrOwnerOfTheTokenId(address _caller) external {
    _assumeFuzzable(_caller);
    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_caller, _TOKEN_ID)), abi.encode(false));

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IVoter.NotAuthorized.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, 1), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsNotRegistered() external givenCallerIsAuthorized givenTheStakeIsLive {
    // it should revert with ChainNotActiveOrSunset
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _UNREGISTERED_CHAIN_ID));
    _voter.allocateGauges(
      _TOKEN_ID, _UNREGISTERED_CHAIN_ID, _singleGaugeAllocation(_GAUGE_1, 1), _GAS_LIMIT, _REFUND_RECIPIENT
    );
  }

  function test_WhenTheChainIsChainZero() external givenCallerIsAuthorized givenTheStakeIsLive {
    // CHAIN0 is an implementation invariant and is never a valid gauge-distribution target.
    // it should revert with ChainNotActiveOrSunset
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN0));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN0, _singleGaugeAllocation(_GAUGE_1, 1), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsPausedOrSuspended(bool _suspended) external givenCallerIsAuthorized givenTheStakeIsLive {
    // Fuzz only `_suspended` — both blocked statuses (Paused / Suspended) hit the same revert.
    _mockChainStatus({
      _chainId: _CHAIN_ID_1, _status: _suspended ? IVoterCommon.ChainStatus.Suspended : IVoterCommon.ChainStatus.Paused
    });

    // it should revert with ChainNotActiveOrSunset
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN_ID_1));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, 1), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsSunsetAndTheGaugeListCarriesOnlyTheDeallocationSentinel(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // A sunset chain still accepts gauge dispatches: the vote is the exit vehicle for the sentinel.
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: this scenario asserts nothing about the index or the
    // ceiling, so leaving the cursor at the deploy timestamp would walk the fuzzed gap for nothing.
    _mockLastGlobalSettlement(_ts);

    _mockChainStatus({_chainId: _CHAIN_ID_1, _status: IVoterCommon.ChainStatus.Sunset});
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _ONE_AERO});

    // A sentinel-only list: the representative sunset vote returns the whole booked amount to root.
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(DEALLOC_GAUGE, _gaugeAlloc);
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});

    // it should flag the dispatch to charge the deallocation return
    // it should dispatch one AllocateGauge message to the chain
    _expectAllocateGaugeDispatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: 0,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _ONE_AERO),
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheChainIsSunsetAndTheGaugeListCarriesANonDeallocationEntry(
    uint128 _gaugeAlloc,
    uint128 _deallocAlloc
  ) external givenCallerIsAuthorized givenTheStakeIsLive {
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, _INT128_MAX_HALF));
    _deallocAlloc = uint128(bound(_deallocAlloc, 1, _INT128_MAX_HALF));
    _mockChainStatus({_chainId: _CHAIN_ID_1, _status: IVoterCommon.ChainStatus.Sunset});

    // A sunset chain takes no new placement: a real gauge entry alone reverts even on a live stake...
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});
    vm.prank(_CALLER);
    // it should revert with SunsetDeallocOnly
    vm.expectRevert(IVoterCommon.SunsetDeallocOnly.selector);
    _voter.allocateGauges(
      _TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc), _GAS_LIMIT, _REFUND_RECIPIENT
    );

    // ...and so does a partial return where a real gauge entry rides along with the sentinel.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc + _deallocAlloc});
    vm.prank(_CALLER);
    vm.expectRevert(IVoterCommon.SunsetDeallocOnly.selector);
    _voter.allocateGauges(
      _TOKEN_ID,
      _CHAIN_ID_1,
      _orderedPair(_GAUGE_1, _gaugeAlloc, DEALLOC_GAUGE, _deallocAlloc),
      _GAS_LIMIT,
      _REFUND_RECIPIENT
    );
  }

  function test_WhenTheChainIsSunsetAndTheGaugeListIsEmpty() external givenCallerIsAuthorized givenTheStakeIsLive {
    _mockChainStatus({_chainId: _CHAIN_ID_1, _status: IVoterCommon.ChainStatus.Sunset});

    // An empty list only matches a zero booked allocation; even that no-op poke is rejected while sunset.
    vm.prank(_CALLER);
    // it should revert with SunsetDeallocOnly
    vm.expectRevert(IVoterCommon.SunsetDeallocOnly.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, new IVoterCommon.GaugeAllocation[](0), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheDestinationGasLimitIsZeroForANonRootChain()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
  {
    // A non-root chain needs destination gas or the bridged AllocateGauge can't be delivered.
    // it should revert with MissingDestinationGasLimit
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, 1), 0, _REFUND_RECIPIENT);
  }

  function test_WhenTheTokenHasBeenWithdrawn() external givenCallerIsAuthorized {
    // A withdrawn token reads as `staked == 0`. The gauge path rejects it so a `{0, 0}` shape can never reach a
    // leaf, where it would be booked as phantom permanent weight. The empty list is the finding's trigger.
    _mockStaked({_amount: 0, _end: 0, _isPermanent: false});

    vm.prank(_CALLER);
    // it should revert with StakeWithdrawn
    vm.expectRevert(IVoter.StakeWithdrawn.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, new IVoterCommon.GaugeAllocation[](0), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              GAUGE LIST VALIDATION
  ////////////////////////////////////////////////////////////*/
  modifier whenTheGaugeListIsInvalid() {
    _;
  }

  function test_WhenGaugesAreNotStrictlyAscending()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheGaugeListIsInvalid
  {
    // Duplicate gauge address — second iteration sees `_gauge <= _prevGauge`.
    IVoterCommon.GaugeAllocation[] memory _gauges = new IVoterCommon.GaugeAllocation[](2);
    _gauges[0] = IVoterCommon.GaugeAllocation({gauge: _GAUGE_1, allocated: 1, data: bytes('')});
    _gauges[1] = IVoterCommon.GaugeAllocation({gauge: _GAUGE_1, allocated: 1, data: bytes('')});

    vm.prank(_CALLER);
    // it should revert with GaugesNotStrictlyAscending
    vm.expectRevert(IVoterCommon.GaugesNotStrictlyAscending.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenAGaugeAllocationAmountIsZero()
    external
    givenCallerIsAuthorized
    givenTheStakeIsLive
    whenTheGaugeListIsInvalid
  {
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, 0);

    vm.prank(_CALLER);
    // it should revert with ZeroAllocation
    vm.expectRevert(IVoterCommon.ZeroAllocation.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              HAPPY PATHS
  ////////////////////////////////////////////////////////////*/
  function test_WhenTheGaugeListIsValid(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts,
    uint128 _totalWeight
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    // Non-zero booked total drives `_refreshEmissionsPerVP` to `mulDiv(rate, PRECISION, weight)`.
    _totalWeight = uint128(bound(_totalWeight, 1, _INT128_MAX_HALF));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    // Live stake snapshot forwarded to the leaf so it can reshape each gauge's contribution.
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    // Seed a permanent booked `totalPoint` resolved at now so `_refreshEmissionsPerVP` reads
    // `weight == _totalWeight` (permanent balance does not decay, no slope walk).
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _totalWeight});
    uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight);

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc);

    // Book exactly the gauge total so the Σ-allocated ≤ booked-allocation check passes.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});

    // it should snapshot the live stake into the dispatched message
    // it should stamp the global emissions-per-VP scalar onto the message
    // it should dispatch one AllocateGauge message to the chain
    _expectAllocateGaugeDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: _expectedEmissionsPerVP,
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    // it should emit the GaugesAllocated event carrying the gauge array
    _expectEmit(address(_voter));
    emit IVoter.GaugesAllocated(_TOKEN_ID, _CHAIN_ID_1, _gauges);

    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              CHAIN ALLOCATION BUDGET
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheGaugeTotalExceedsTheBookedChainAllocation(
    uint128 _booked,
    uint128 _overshoot
  ) external givenCallerIsAuthorized givenTheStakeIsLive {
    // Book a budget below the shipped gauge total. Fuzz both the budget and the overshoot so the
    // gauge total lands strictly above the booked amount without overflowing `uint128`.
    _booked = uint128(bound(_booked, 0, type(uint128).max - 1));
    _overshoot = uint128(bound(_overshoot, 1, type(uint128).max - _booked));
    uint128 _gaugeAlloc = _booked + _overshoot;

    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _booked});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc);

    // it should revert with ChainAllocationMismatch
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainAllocationMismatch.selector, _CHAIN_ID_1));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheGaugeTotalIsBelowTheBookedChainAllocation(
    uint128 _booked,
    uint128 _shortfall
  ) external givenCallerIsAuthorized givenTheStakeIsLive {
    // Book a budget above the shipped gauge total. The exact-match model has no automatic backfill, so
    // an under-allocation must revert exactly like an over-allocation — idle VP must be an explicit
    // ZERO_GAUGE entry. Fuzz both the shortfall and the gauge total without underflowing `uint128`.
    _shortfall = uint128(bound(_shortfall, 1, type(uint128).max - 1));
    uint128 _gaugeAlloc = uint128(bound(_booked, 1, type(uint128).max - _shortfall));
    _booked = _gaugeAlloc + _shortfall;

    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _booked});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc);

    // it should revert with ChainAllocationMismatch
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainAllocationMismatch.selector, _CHAIN_ID_1));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheGaugeTotalEqualsTheBookedChainAllocation(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gauge1Alloc,
    uint128 _gauge2Alloc,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    // Two-gauge list so the boundary is Σ across entries, not a single amount. Split the budget:
    // bound each half so their sum stays within `uint128`.
    _gauge1Alloc = uint128(bound(_gauge1Alloc, 1, _INT128_MAX_HALF));
    _gauge2Alloc = uint128(bound(_gauge2Alloc, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    // Ascending two-gauge list so the boundary is Σ across entries. Entries are ordered by address.
    IVoterCommon.GaugeAllocation[] memory _gauges = _regularPair(_gauge1Alloc, _gauge2Alloc);

    // Book exactly the gauge total: Σ allocated == booked allocation is the accepted boundary.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gauge1Alloc + _gauge2Alloc});

    // Seed a zero-weight `totalPoint` resolved at now: `_refreshEmissionsPerVP` reads weight 0 and
    // returns 0 (the zero-total-weight branch). Anchoring at `_ts` avoids a multi-year slope walk.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: 0});

    // it should snapshot the live stake into the dispatched message
    // it should stamp a zero emissions-per-VP scalar when the total weight is zero
    // it should dispatch one AllocateGauge message to the chain
    _expectAllocateGaugeDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: 0,
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheGaugeListIsEmpty(
    uint128 _staked,
    uint48 _stakeEnd,
    uint48 _ts,
    uint128 _totalWeight
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    _totalWeight = uint128(bound(_totalWeight, 1, _INT128_MAX_HALF));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    // An empty list has Σ allocated == 0, so the exact-match check requires a zero booked amount: idle VP
    // must be an explicit ZERO_GAUGE entry, never an undistributed remainder.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: 0});

    // Seed a permanent booked `totalPoint` at now so the dispatched scalar is `mulDiv(rate, PRECISION, weight)`.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _totalWeight});
    uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight);

    IVoterCommon.GaugeAllocation[] memory _gauges = new IVoterCommon.GaugeAllocation[](0);

    // it should dispatch one AllocateGauge message to the chain when the booked allocation is zero
    _expectAllocateGaugeDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: _expectedEmissionsPerVP,
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheDeallocationSentinelAmountPushesTheTotalOverTheBookedChainAllocation(
    uint128 _gauge1Alloc,
    uint128 _sentinelAlloc
  ) external givenCallerIsAuthorized givenTheStakeIsLive {
    // Book exactly the distribution total so the regular gauge alone fits, but the sentinel entry
    // (which draws from the same budget) tips Σ allocated over. Fuzz both amounts.
    _gauge1Alloc = uint128(bound(_gauge1Alloc, 1, _INT128_MAX_HALF));
    _sentinelAlloc = uint128(bound(_sentinelAlloc, 1, _INT128_MAX_HALF));

    // Book only the distribution amount: distributions fit, distributions + sentinel do not.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gauge1Alloc});

    // Ascending two-entry list pairing the regular gauge with the sentinel.
    IVoterCommon.GaugeAllocation[] memory _gauges = _sentinelPair(_gauge1Alloc, _sentinelAlloc);

    // it should revert with ChainAllocationMismatch
    vm.prank(_CALLER);
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainAllocationMismatch.selector, _CHAIN_ID_1));
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheDeallocationSentinelAmountBringsTheTotalToTheBookedChainAllocation(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gauge1Alloc,
    uint128 _sentinelAlloc,
    uint48 _ts,
    uint256 _msgValue
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gauge1Alloc = uint128(bound(_gauge1Alloc, 1, _INT128_MAX_HALF));
    _sentinelAlloc = uint128(bound(_sentinelAlloc, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    _msgValue = bound(_msgValue, 0, 100 ether);
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    // Book exactly distributions + sentinel: the sentinel amount counted in Σ hits the boundary.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gauge1Alloc + _sentinelAlloc});

    // Seed a permanent booked `totalPoint` at now with a fixed `_ONE_AERO` weight (a constant, to
    // keep no extra fuzzed slot alive) so the dispatched scalar is `mulDiv(rate, PRECISION, weight)`.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _ONE_AERO});

    // Ascending two-entry list pairing the regular gauge with the sentinel.
    IVoterCommon.GaugeAllocation[] memory _gauges = _sentinelPair(_gauge1Alloc, _sentinelAlloc);

    vm.deal(_CALLER, _msgValue);

    // it should forward the full value to the orchestrator
    // it should dispatch one AllocateGauge message to the chain
    _expectAllocateGaugeDispatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _msgValue,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _ONE_AERO),
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges{value: _msgValue}(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
          DEALLOCATION CHARGE DELEGATION
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Expect the single-chain `AllocateGauge` dispatch carrying an explicit forwarded native
   *         value and deallocation-charge flag. Mirrors `_expectAllocateGaugeDispatch` but asserts a
   *         non-zero `nativeValue` / `msg.value` so the value forwarding is verified end to end.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _nativeValue Native value the Voter must forward to the orchestrator (the whole `msg.value`).
   * @param _chargeDeallocationReturn Whether the gauge list carries the `DEALLOC_GAUGE` sentinel.
   * @param _message The `AllocateGaugeMessage` body the orchestrator will receive.
   */
  function _expectAllocateGaugeDispatchWithFee(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _nativeValue,
    bool _chargeDeallocationReturn,
    IVoterCommon.AllocateGaugeMessage memory _message
  ) private {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: _chargeDeallocationReturn,
      payload: abi.encode(_message)
    });
    // Assert the forwarded `msg.value` equals the declared native value as well as the calldata.
    vm.expectCall(
      _ORCHESTRATOR,
      _nativeValue,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.AllocateGauge, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Build a strictly-ascending length-2 `GaugeAllocation[]` holding `_GAUGE_1` and the
   *         `DEALLOC_GAUGE` sentinel, ordered by address so the ascending check passes regardless
   *         of which address sorts first.
   * @dev Extracted to its own frame to keep the sentinel-budget tests below the stack-depth limit.
   * @param _regularAlloc Amount on the regular `_GAUGE_1` entry.
   * @param _sentinelAlloc Amount on the sentinel entry.
   * @return _gauges Ascending length-2 list.
   */
  function _sentinelPair(
    uint128 _regularAlloc,
    uint128 _sentinelAlloc
  ) private view returns (IVoterCommon.GaugeAllocation[] memory _gauges) {
    _gauges = _orderedPair(_GAUGE_1, _regularAlloc, DEALLOC_GAUGE, _sentinelAlloc);
  }

  /**
   * @notice Build a strictly-ascending length-2 `GaugeAllocation[]` from `_GAUGE_1` and `_GAUGE_2`.
   * @dev Extracted to its own frame to keep the boundary test below the stack-depth limit.
   * @param _alloc1 Amount on the `_GAUGE_1` entry.
   * @param _alloc2 Amount on the `_GAUGE_2` entry.
   * @return _gauges Ascending length-2 list.
   */
  function _regularPair(
    uint128 _alloc1,
    uint128 _alloc2
  ) private view returns (IVoterCommon.GaugeAllocation[] memory _gauges) {
    _gauges = _orderedPair(_GAUGE_1, _alloc1, _GAUGE_2, _alloc2);
  }

  /**
   * @notice Build a strictly-ascending length-2 `GaugeAllocation[]` from two gauges, ordering the
   *         entries by address so the ascending validation passes regardless of input order.
   * @param _gaugeA First gauge address.
   * @param _allocA Amount on the `_gaugeA` entry.
   * @param _gaugeB Second gauge address (must differ from `_gaugeA`).
   * @param _allocB Amount on the `_gaugeB` entry.
   * @return _gauges Ascending length-2 list.
   */
  function _orderedPair(
    address _gaugeA,
    uint128 _allocA,
    address _gaugeB,
    uint128 _allocB
  ) private pure returns (IVoterCommon.GaugeAllocation[] memory _gauges) {
    _gauges = new IVoterCommon.GaugeAllocation[](2);
    if (_gaugeA < _gaugeB) {
      _gauges[0] = IVoterCommon.GaugeAllocation({gauge: _gaugeA, allocated: _allocA, data: bytes('')});
      _gauges[1] = IVoterCommon.GaugeAllocation({gauge: _gaugeB, allocated: _allocB, data: bytes('')});
    } else {
      _gauges[0] = IVoterCommon.GaugeAllocation({gauge: _gaugeB, allocated: _allocB, data: bytes('')});
      _gauges[1] = IVoterCommon.GaugeAllocation({gauge: _gaugeA, allocated: _allocA, data: bytes('')});
    }
  }

  function test_WhenTheGaugeListCarriesOnlyTheDeallocationSentinel(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts,
    uint256 _msgValue
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    // Keep the value well within a fundable balance. The deallocation return cost lives on the
    // orchestrator now, so the Voter neither reads it nor splits against it.
    _msgValue = bound(_msgValue, 0, 100 ether);
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    // Seed a permanent booked `totalPoint` at now with a fixed `_ONE_AERO` weight (a constant, to
    // keep no extra fuzzed slot alive) so the dispatched scalar is `mulDiv(rate, PRECISION, weight)`.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _ONE_AERO});

    // Length-1 gauge list holding only the sentinel is trivially strictly ascending.
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(DEALLOC_GAUGE, _gaugeAlloc);

    // The sentinel amount draws from the same booked budget; book exactly it so the check passes.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});

    vm.deal(_CALLER, _msgValue);

    // it should forward the full value to the orchestrator
    // it should flag the dispatch to charge the deallocation return
    _expectAllocateGaugeDispatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _msgValue,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _ONE_AERO),
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    // The Voter retains nothing on this path: the expectation above pins the forwarded value to the
    // whole `msg.value`, and the orchestrator (mocked here) owns the cost retention. A balance
    // assertion can't confirm it because `vm.mockCall` does not move the forwarded value out of the
    // Voter — the real retention is asserted against the orchestrator in `UnitRootMessageOrchestrator`.
    vm.prank(_CALLER);
    _voter.allocateGauges{value: _msgValue}(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheStakeIsExpiredAndTheGaugeListCarriesOnlyTheDeallocationSentinel(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts,
    uint256 _msgValue
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    // A non-permanent expiry at or before now marks the stake expired: it can no longer vote, but the
    // sentinel-only return stays open so the budget can come back to root and unblock the withdrawal.
    _stakeEnd = uint48(bound(_stakeEnd, 1, _ts));
    _msgValue = bound(_msgValue, 0, 100 ether);
    vm.warp(_ts);
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _ONE_AERO});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(DEALLOC_GAUGE, _gaugeAlloc);
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});

    vm.deal(_CALLER, _msgValue);

    // it should dispatch one AllocateGauge message to the chain
    _expectAllocateGaugeDispatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _msgValue,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _ONE_AERO),
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges{value: _msgValue}(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenTheStakeIsExpiredAndTheGaugeListCarriesANonDeallocationEntry(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint128 _deallocAlloc,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, _INT128_MAX_HALF));
    _deallocAlloc = uint128(bound(_deallocAlloc, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, 1, _ts));
    vm.warp(_ts);
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});

    // An expired stake may only return its budget: a real gauge entry alone reverts...
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});
    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocateGauges(
      _TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc), _GAS_LIMIT, _REFUND_RECIPIENT
    );

    // ...and so does a partial return where a real gauge entry rides along with the sentinel.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc + _deallocAlloc});
    vm.prank(_CALLER);
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocateGauges(
      _TOKEN_ID,
      _CHAIN_ID_1,
      _orderedPair(_GAUGE_1, _gaugeAlloc, DEALLOC_GAUGE, _deallocAlloc),
      _GAS_LIMIT,
      _REFUND_RECIPIENT
    );
  }

  function test_WhenTheStakeIsExpiredAndTheGaugeListIsEmpty(
    uint128 _staked,
    uint48 _stakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, 1, _ts));
    vm.warp(_ts);
    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});

    // An empty list only matches a zero booked allocation; even that no-op poke is rejected while expired.
    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, new IVoterCommon.GaugeAllocation[](0), _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  function test_WhenNoDeallocationSentinelIsPresent(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts,
    uint256 _msgValue,
    uint128 _totalWeight
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max - _MAXTIME));
    _stakeEnd = uint48(bound(_stakeEnd, _ts + 1, _ts + _MAXTIME));
    _msgValue = bound(_msgValue, 0, 100 ether);
    _totalWeight = uint128(bound(_totalWeight, 1, _INT128_MAX_HALF));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // Stored root shape matches the live stake so the standalone gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: 0});
    // Seed a resolved destination-chain point so the dispatch's rate refresh settles/resolves without
    // walking from the epoch (in production a chain always has a seeded point before gauges land).
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 1});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    // Seed a permanent booked `totalPoint` at now so the dispatched scalar is `mulDiv(rate, PRECISION, weight)`.
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _totalWeight});

    // `_GAUGE_1` is a regular gauge, never the sentinel.
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc);

    // Book exactly the gauge total so the Σ-allocated ≤ booked-allocation check passes.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});

    vm.deal(_CALLER, _msgValue);

    // it should forward the full value to the orchestrator
    // it should leave the dispatch unflagged
    _expectAllocateGaugeDispatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _msgValue,
      _chargeDeallocationReturn: false,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight),
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    // Nothing is retained anywhere in the Voter: the unflagged dispatch means the orchestrator has no
    // cost to withhold either.
    vm.prank(_CALLER);
    _voter.allocateGauges{value: _msgValue}(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              ROOT-COLOCATED SYNCHRONOUS RETURN
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheDispatchSynchronouslyReturnsTheDeallocation(
    uint128 _onChain,
    uint128 _chain0Start
  ) external givenCallerIsAuthorized {
    // The root-colocated leaf has no transport: the `RootLocalAdapter` delivers the AllocateGauge in
    // the same transaction, and the leaf's deallocation return re-enters `processDeallocation` while
    // `allocateGauges` is still executing. The nested credit must land, not trip the caller's guard.
    _onChain = uint128(bound(_onChain, 1, _INT128_MAX_HALF / 2));
    _chain0Start = uint128(bound(_chain0Start, 0, _INT128_MAX_HALF / 2));
    uint128 _committed = _onChain + _chain0Start;

    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _stakeEnd = 1_893_628_800; // week-aligned, <= _ts + _MAXTIME
    vm.warp(_ts);

    _seedTwoChainPrior({
      _tAct: _ts, _stakeEnd: _stakeEnd, _originAlloc: _onChain, _chain0Alloc: _chain0Start, _committed: _committed
    });
    _mockStaked({_amount: _committed, _end: _stakeEnd, _isPermanent: false});

    // Replace the inert orchestrator mock with one that routes the deallocation return back into the
    // Voter synchronously, mirroring the co-located `RootLocalAdapter` round trip. `vm.etch` keeps the
    // orchestrator address the Voter was constructed with; the mock's immutables survive the etch.
    vm.etch(_ORCHESTRATOR, address(new SyncDeallocationReturnOrchestrator(_CHAIN_ID_1, _TOKEN_ID, _onChain)).code);

    // it should process the deallocation return within the same call
    vm.expectEmit(true, true, true, true, address(_voter));
    emit IVoter.DeallocationProcessed(_CHAIN_ID_1, _TOKEN_ID, _onChain);

    vm.prank(_CALLER);
    _voter.allocateGauges(
      _TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(DEALLOC_GAUGE, _onChain), _GAS_LIMIT, _REFUND_RECIPIENT
    );

    // it should credit the returned amount to chain zero
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), 0);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), _chain0Start + _onChain);
  }

  /*////////////////////////////////////////////////////////////
              SHAPE GUARD + RECOVERY
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheLiveStakeShapeDiffersFromTheStoredRootShape(
    uint48 _liveStakeEnd,
    uint48 _storedStakeEnd
  ) external givenCallerIsAuthorized {
    // The standalone gauge path never re-anchors root's chain point, so it rejects a live shape that no
    // longer matches the stored root shape — otherwise leaf gauge accrual would desync from the ceiling.
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    vm.warp(_ts);
    _liveStakeEnd = uint48(bound(_liveStakeEnd, _ts + 1, _ts + _MAXTIME));
    _storedStakeEnd = uint48(bound(_storedStakeEnd, _ts + 1, _ts + _MAXTIME));
    vm.assume(_liveStakeEnd != _storedStakeEnd);

    _mockStaked({_amount: _ONE_AERO, _end: _liveStakeEnd, _isPermanent: false});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _ONE_AERO, _lastStakeEnd: _storedStakeEnd, _lastAllocated: _ts});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _ONE_AERO});

    // The gauge total matches the booked amount exactly so validation passes and execution reaches the
    // shape guard under test, rather than bouncing on the earlier exact-match check.
    // it should revert with StaleShape
    vm.prank(_CALLER);
    vm.expectRevert(IVoter.StaleShape.selector);
    _voter.allocateGauges(
      _TOKEN_ID, _CHAIN_ID_1, _singleGaugeAllocation(_GAUGE_1, _ONE_AERO), _GAS_LIMIT, _REFUND_RECIPIENT
    );
  }

  function test_WhenAStaleShapeIsReconciledWithAnEmptyChainAllocation() external givenCallerIsAuthorized {
    // Seed a prior {CHAIN_ID_1, CHAIN0} position anchored at the old shape, then move the live stake to a
    // new shape so the standalone gauge path would reject it.
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    uint48 _oldStakeEnd = 1_893_628_800; // week-aligned, == _ts + _MAXTIME
    uint48 _newStakeEnd = _oldStakeEnd - 1 weeks; // still valid, distinct from the old shape
    uint128 _onChain = _ONE_AERO;
    uint128 _chain0 = _ONE_AERO;
    vm.warp(_ts);

    _seedTwoChainPrior(_ts, _oldStakeEnd, _onChain, _chain0, 2 * _ONE_AERO);
    // Live stake now reports the new shape; `_seedTwoChainPrior` left `lastStakeEnd` at the old shape.
    _mockStaked({_amount: 2 * _ONE_AERO, _end: _newStakeEnd, _isPermanent: false});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _onChain);

    // Precondition: the gauge-only vote is rejected while the shape is stale.
    vm.prank(_CALLER);
    vm.expectRevert(IVoter.StaleShape.selector);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);

    // Recover: an empty chain allocation re-anchors the whole position to the live shape, no dispatch.
    vm.prank(_CALLER);
    _voter.allocateChains(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _REFUND_RECIPIENT);

    // it should re-anchor the stored root shape to the live stake
    (, uint48 _lastStakeEnd,,) = _voter.tokenStates(_TOKEN_ID);
    assertEq(_lastStakeEnd, _newStakeEnd);

    // it should let the retried gauge allocation dispatch
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
    vm.expectCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector));
    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
          DESTINATION CHAIN EMISSIONS PER VP LOCKSTEP
  ////////////////////////////////////////////////////////////*/

  function test_WhenAPriorTotalWeightChangeLeftTheGlobalEmissionsPerVPStale(
    uint128 _chainWeight,
    uint128 _totalExtra
  ) external givenCallerIsAuthorized {
    // A burn/park/rebalance moves `totalWeight`, so the stored global `emissionsPerVP` sampled before it
    // no longer matches the current weights. `allocateGauges` ships a scalar to the leaf, so it must
    // resample first — otherwise the leaf accrues at a scalar the root ceiling never integrated and
    // legitimate receipts can hit `CeilingExceeded`.
    _chainWeight = uint128(bound(_chainWeight, _MAXTIME, 1e30));
    _totalExtra = uint128(bound(_totalExtra, 1, 1e30));
    uint128 _totalWeight = _chainWeight + _totalExtra; // total strictly above this chain's own weight
    uint48 _ts = _INITIAL_TIMESTAMP + 3 days;
    vm.warp(_ts);

    // Permanent stake so the shape guard passes with `lastStakeEnd == 0` and the points carry no decay.
    _mockStaked({_amount: _chainWeight, _end: 0, _isPermanent: true});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _chainWeight);
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _chainWeight});
    // Stored shape matches the live permanent stake so the gauge path's shape guard passes.
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _chainWeight, _lastStakeEnd: 0, _lastAllocated: 0});

    // Chain carries `_chainWeight` (permanent), resolved at now; total carries a larger `_totalWeight`.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: _chainWeight});
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _totalWeight});

    // Seed a global scalar that does NOT match the current weights, as a prior totalWeight change would
    // leave it. Anchoring `lastGlobalSettlement` at now pins the index advance to zero, so the stale
    // scalar cannot leak into the accumulator and the resample is the only observable effect.
    uint256 _staleEmissionsPerVP = 1;
    _mockEmissionsPerVP(_staleEmissionsPerVP);
    _mockLastGlobalSettlement(_ts);

    // it should ship the freshly resampled emissionsPerVP in the dispatched message
    // Global scalar mulDiv(MINTER_RATE, PRECISION, totalWeight) — no chainWeight factor.
    uint256 _expectedEmissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, _totalWeight);
    _expectAllocateGaugeDispatch({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: _ts + _ALLOCATION_LIFETIME,
        emissionsPerVP: _expectedEmissionsPerVP,
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _chainWeight, stakeEnd: 0, isPermanent: true}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocateGauges(_TOKEN_ID, _CHAIN_ID_1, _gauges, _GAS_LIMIT, _REFUND_RECIPIENT);

    // it should resample the stored global emissionsPerVP against the current total weight
    assertEq(_voter.emissionsPerVP(), _expectedEmissionsPerVP);
    assertTrue(_expectedEmissionsPerVP != _staleEmissionsPerVP);
  }
}

/**
 * @notice Minimal orchestrator standing in for the root-colocated round trip: `dispatch` synchronously
 *         routes the leaf's deallocation return back into the calling Voter, exactly as
 *         `RootMessageOrchestrator` → `RootLocalAdapter` → `LeafMessageOrchestrator` → `LeafVoter` →
 *         back to `Voter.processDeallocation` does when the destination chain is `block.chainid`.
 * @dev Constructor args live in immutables so the runtime code carries them through `vm.etch`.
 */
contract SyncDeallocationReturnOrchestrator {
  uint256 internal immutable _ORIGIN_CHAIN_ID;
  uint256 internal immutable _RETURNED_TOKEN_ID;
  uint128 internal immutable _RETURNED_AMOUNT;

  constructor(uint256 _originChainId, uint256 _returnedTokenId, uint128 _returnedAmount) {
    _ORIGIN_CHAIN_ID = _originChainId;
    _RETURNED_TOKEN_ID = _returnedTokenId;
    _RETURNED_AMOUNT = _returnedAmount;
  }

  function dispatch(
    IMessageOrchestrator.MessageType,
    IRootMessageOrchestrator.ChainDispatch[] calldata,
    address
  ) external payable {
    IVoter(msg.sender).processDeallocation(_ORIGIN_CHAIN_ID, _RETURNED_TOKEN_ID, _RETURNED_AMOUNT);
  }
}
