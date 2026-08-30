// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {Vm} from 'forge-std/Vm.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';

import {DEALLOC_GAUGE} from 'V3/libraries/ProtocolConstants.sol';

import {BaseVoter, IVoter, IVoterCommon, IVotingEscrow} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterAllocate is BaseVoter {
  /// @notice Bundled locals for the composed happy-path test. Packing the fuzzed inputs and
  ///         derived values into one struct keeps the test body under the legacy non-via-ir
  ///         stack-depth limit.
  struct AllocateContext {
    uint128 allocated;
    uint128 remainder;
    uint128 staked;
    uint48 ts;
    uint48 tAct;
    uint48 stakeEnd;
    uint256 chainFee;
    uint256 gaugeFee;
  }

  /// @notice Bundled locals for the sentinel happy-path test. Same stack-depth relief as
  ///         `AllocateContext`: packing the fuzzed inputs keeps the body under the legacy
  ///         non-via-ir stack limit.
  struct SentinelContext {
    uint128 staked;
    uint48 ts;
    uint48 tAct;
    uint48 stakeEnd;
    uint128 sentinelAlloc;
    uint256 entryValue;
  }

  /// @notice Bundled locals for the mid-call stake-growth regression. Same stack-depth relief as
  ///         `AllocateContext`.
  struct ReentrancyContext {
    uint128 allocated;
    uint128 stakeGrowth;
    uint48 ts;
    uint48 tAct;
    uint48 stakeEnd;
    uint256 emissionsPerVP;
  }

  /// @notice Bundled locals for the mixed plain/sentinel batch test. Same stack-depth relief as
  ///         `SentinelContext`: packing the fuzzed inputs keeps the body under the legacy
  ///         non-via-ir stack limit.
  struct MixedSentinelContext {
    uint128 staked;
    uint48 ts;
    uint48 tAct;
    uint48 stakeEnd;
    uint128 plainAlloc;
    uint128 sentinelAlloc;
    uint256 plainValue;
    uint256 sentinelValue;
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
    _voter.allocate(
      _TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), new IVoter.GaugeAllocationDispatch[](0), _REFUND_RECIPIENT
    );
  }

  function test_WhenMsgValueDoesNotEqualTheSumOfDeclaredValues(
    uint256 _chainValue,
    uint256 _gaugeValue,
    uint256 _msgValue
  ) external givenCallerIsAuthorized {
    // The value split is pinned before any phase runs: `msg.value` must equal Σ chain-entry values +
    // Σ gauge-entry values. Fuzz both declared legs and a mismatched msg.value on either side of the sum.
    _chainValue = bound(_chainValue, 0, 100 ether);
    _gaugeValue = bound(_gaugeValue, 0, 100 ether);
    _msgValue = bound(_msgValue, 0, 200 ether);
    vm.assume(_msgValue != _chainValue + _gaugeValue);

    // Entries only need declared values — the pin trips before any of their fields are validated.
    IVoter.ChainAllocationDispatch[] memory _chainDispatches = new IVoter.ChainAllocationDispatch[](1);
    _chainDispatches[0] =
      IVoter.ChainAllocationDispatch({chainId: _CHAIN_ID_1, delta: 1, gasLimit: _GAS_LIMIT, value: _chainValue});
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: _gaugeValue, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.deal(_CALLER, _msgValue);
    vm.prank(_CALLER);
    // it should revert with UnexpectedValue
    vm.expectRevert(IVoterCommon.UnexpectedValue.selector);
    _voter.allocate{value: _msgValue}(_TOKEN_ID, _chainDispatches, _gaugeDispatches, _REFUND_RECIPIENT);
  }

  function test_WhenTheTokenIdStakeHasExpiredBeforeTAct(
    uint128 _amount,
    uint48 _stakeEnd,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Fuzz `_amount`, `_stakeEnd`, `_ts` — they drive the phase-1 expiry check.
    _amount = uint128(bound(_amount, 0, _INT128_MAX));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP + 1, type(uint48).max));
    // Non-permanent stake that has already expired at T_act. Root anchors T_act at
    // `block.timestamp`, so any `stakeEnd <= _ts` trips the expiry guard.
    _stakeEnd = uint48(bound(_stakeEnd, 1, _ts));
    vm.warp(_ts);

    // Non-empty chain allocation to reach the expiry guard inside phase 1.
    IVoter.ChainAllocationDispatch[] memory _chainAllocations =
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: 1, _gasLimit: _GAS_LIMIT});

    _mockStaked({_amount: _amount, _end: _stakeEnd, _isPermanent: false});

    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocate(_TOKEN_ID, _chainAllocations, new IVoter.GaugeAllocationDispatch[](0), _REFUND_RECIPIENT);
  }

  function test_WhenTheStakeWasWithdrawn() external givenCallerIsAuthorized {
    // A withdrawn token reads back VE's cleared stake `{amount: 0, end: 0, isPermanent: false}`.
    // `_allocateChains` runs `_requireLiveStake` even for an empty batch, so the batcher surfaces
    // the guard at this entrypoint before any phase work.
    _mockStaked({_amount: 0, _end: 0, _isPermanent: false});

    vm.prank(_CALLER);
    // it should revert with StakeExpired
    vm.expectRevert(IVoterCommon.StakeExpired.selector);
    _voter.allocate(
      _TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), new IVoter.GaugeAllocationDispatch[](0), _REFUND_RECIPIENT
    );
  }

  /*////////////////////////////////////////////////////////////
              GAUGE DISPATCH ORDERING
  ////////////////////////////////////////////////////////////*/
  modifier whenTheGaugeDispatchesAreNotStrictlyAscending() {
    _;
  }

  function test_WhenALaterGaugeDispatchChainIdIsBelowThePreviousOne()
    external
    givenCallerIsAuthorized
    whenTheGaugeDispatchesAreNotStrictlyAscending
  {
    // Phase 1 is a no-op (empty chain scope + permanent stake so it never dispatches AllocateChain).
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});
    // Book a budget on the first (`_CHAIN_ID_2`) entry so its gauge list validates and iteration 2
    // reaches the ascending check rather than tripping ChainAllocationMismatch on entry 0.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_2, _amount: 1});
    // Each gauge entry dispatches independently, so the first (`_CHAIN_ID_2`) entry completes its
    // dispatch before iteration 2 trips: seed its point + ceiling cursor so the settle/refresh no-ops
    // and mock the orchestrator so that first dispatch succeeds.
    _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: uint48(block.timestamp), _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_2, _value: _voter.index()});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: uint48(block.timestamp), _perm: 0});
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));

    // `_CHAIN_ID_2 > _CHAIN_ID_1`, so placing `_CHAIN_ID_2` first and `_CHAIN_ID_1` second trips the
    // ascending check on iteration 2 (`_CHAIN_ID_1 <= _prevChainId == _CHAIN_ID_2`).
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](2);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_2, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });
    _gaugeDispatches[1] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.prank(_CALLER);
    // it should revert with GaugeDispatchesNotStrictlyAscending
    vm.expectRevert(IVoter.GaugeDispatchesNotStrictlyAscending.selector);
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  function test_WhenTheFirstGaugeDispatchChainIsChainZero()
    external
    givenCallerIsAuthorized
    whenTheGaugeDispatchesAreNotStrictlyAscending
  {
    // `_prevChainId` starts at 0, so a first entry on CHAIN0 (`0 <= 0`) trips the ascending guard
    // BEFORE the registered-chain check — it reverts GaugeDispatchesNotStrictlyAscending, not
    // Chain0NotConfigurable.
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN0, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.prank(_CALLER);
    // it should revert with GaugeDispatchesNotStrictlyAscending
    vm.expectRevert(IVoter.GaugeDispatchesNotStrictlyAscending.selector);
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              PER GAUGE DISPATCH GUARDS
  ////////////////////////////////////////////////////////////*/
  function test_WhenAGaugeDispatchChainIsNotRegistered() external givenCallerIsAuthorized {
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _UNREGISTERED_CHAIN_ID, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.prank(_CALLER);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _UNREGISTERED_CHAIN_ID));
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  function test_WhenAGaugeDispatchChainIsPausedOrSuspended(bool _suspended) external givenCallerIsAuthorized {
    // Fuzz only `_suspended` — both blocked statuses (Paused / Suspended) hit the same revert.
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});
    _mockChainStatus({
      _chainId: _CHAIN_ID_1, _status: _suspended ? IVoterCommon.ChainStatus.Suspended : IVoterCommon.ChainStatus.Paused
    });

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.prank(_CALLER);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN_ID_1));
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  function test_WhenANonRootGaugeDispatchChainHasAZeroGasLimit() external givenCallerIsAuthorized {
    // A non-root chain needs destination gas or the bridged AllocateGauge can't be delivered.
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: 0, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, 1)
    });

    vm.prank(_CALLER);
    // it should revert with MissingDestinationGasLimit
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              GAUGE LIST VALIDATION
  ////////////////////////////////////////////////////////////*/
  function test_WhenAGaugeListTotalExceedsTheFreshlyWrittenChainBudget(
    uint128 _booked,
    uint128 _overshoot
  ) external givenCallerIsAuthorized {
    // Book a budget below the shipped gauge total. Fuzz both the budget and the overshoot so the
    // gauge total lands strictly above the booked amount without overflowing `uint128`.
    _booked = uint128(bound(_booked, 0, type(uint128).max - 1));
    _overshoot = uint128(bound(_overshoot, 1, type(uint128).max - _booked));
    uint128 _gaugeAlloc = _booked + _overshoot;

    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _booked});

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc)
    });

    vm.prank(_CALLER);
    // it should revert with ChainAllocationMismatch
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainAllocationMismatch.selector, _CHAIN_ID_1));
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
              DEALLOCATION CHARGE DELEGATION
  ////////////////////////////////////////////////////////////*/
  function test_WhenAGaugeListCarriesTheDeallocationSentinel(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _sentinelAlloc,
    uint48 _ts,
    uint256 _entryValue
  ) external givenCallerIsAuthorized {
    SentinelContext memory _context;
    _context.staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _context.sentinelAlloc = uint128(bound(_sentinelAlloc, 1, type(uint128).max));
    // Keep the value well within a fundable balance. The deallocation return cost now lives on the
    // orchestrator, so root's Voter neither reads it nor splits against it.
    _context.entryValue = bound(_entryValue, 0, 100 ether);
    (_context.ts, _context.tAct, _context.stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _mockStaked({_amount: _context.staked, _end: _context.stakeEnd, _isPermanent: false});

    // No chain allocation in phase 1 — the whole stake parks on CHAIN0, so no AllocateChain dispatch
    // fires. Seed CHAIN0 + totalPoint at `tAct` so the resolve walk no-ops; phase 1 still re-anchors
    // the stored shape, so the per-entry StaleShape check passes without a token-state mock.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});

    // The sentinel amount draws from the booked budget; book exactly it so the check passes. Seed the
    // destination point too so the dispatch's rate refresh settles/resolves without walking from the epoch.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _context.sentinelAlloc});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});

    // Length-1 gauge list holding only the sentinel is trivially strictly ascending. The entry's whole
    // declared value goes to the orchestrator, which owns the cost split.
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(DEALLOC_GAUGE, _context.sentinelAlloc);
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: _context.entryValue, gauges: _gauges
    });

    // it should forward the entry's full declared value to the orchestrator
    // it should flag the dispatch to charge the deallocation return
    _expectAllocateGaugeBatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _gaugeFee: _context.entryValue,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        // No chain allocation booked: the whole stake parks on CHAIN0 as unbooked virgin VP, so
        // `totalPoint` weight stays zero and `_refreshEmissionsPerVP` returns 0.
        emissionsPerVP: 0,
        tokenSnapshot: IVoterCommon.TokenSnapshot({
          staked: _context.staked, stakeEnd: _context.stakeEnd, isPermanent: false
        }),
        allocations: _gauges
      })
    });

    // it should emit the GaugesAllocated event carrying the sentinel list
    _expectEmit(address(_voter));
    emit IVoter.GaugesAllocated(_TOKEN_ID, _CHAIN_ID_1, _gauges);

    // The Voter retains nothing on this path: the expectation above pins the forwarded value to the
    // entry's full declared value, and the orchestrator (mocked here) owns the cost retention.
    vm.deal(_CALLER, _context.entryValue);
    vm.prank(_CALLER);
    _voter.allocate{value: _context.entryValue}(
      _TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT
    );
  }

  function test_WhenOnlyOneOfSeveralGaugeEntriesCarriesTheDeallocationSentinel(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _plainAlloc,
    uint128 _sentinelAlloc,
    uint48 _ts,
    uint256 _plainValue,
    uint256 _sentinelValue
  ) external givenCallerIsAuthorized {
    MixedSentinelContext memory _context;
    _context.staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _context.plainAlloc = uint128(bound(_plainAlloc, 1, type(uint128).max));
    _context.sentinelAlloc = uint128(bound(_sentinelAlloc, 1, type(uint128).max));
    _context.plainValue = bound(_plainValue, 0, 100 ether);
    _context.sentinelValue = bound(_sentinelValue, 0, 100 ether);
    (_context.ts, _context.tAct, _context.stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _mockStaked({_amount: _context.staked, _end: _context.stakeEnd, _isPermanent: false});

    // No chain allocation in phase 1 — the whole stake parks on CHAIN0, so no AllocateChain dispatch
    // fires. Seed CHAIN0 + totalPoint at `tAct` so the resolve walk no-ops; phase 1 still re-anchors
    // the stored shape, so the per-entry StaleShape check passes without a token-state mock.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});

    // Book each entry's exact budget and seed both destination points so each dispatch's rate
    // refresh settles/resolves without walking from the epoch.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _context.plainAlloc});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_2, _amount: _context.sentinelAlloc});
    _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_2, _value: _voter.index()});

    // Ascending chainIds: entry A (plain gauge, `_CHAIN_ID_1`) then entry B (sentinel, `_CHAIN_ID_2`).
    // Only entry B carries the sentinel, so only its dispatch is flagged to charge the return cost.
    IVoterCommon.GaugeAllocation[] memory _plainGauges = _singleGaugeAllocation(_GAUGE_1, _context.plainAlloc);
    IVoterCommon.GaugeAllocation[] memory _sentinelGauges =
      _singleGaugeAllocation(DEALLOC_GAUGE, _context.sentinelAlloc);
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](2);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: _context.plainValue, gauges: _plainGauges
    });
    _gaugeDispatches[1] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_2, gasLimit: _GAS_LIMIT, value: _context.sentinelValue, gauges: _sentinelGauges
    });

    // Both legs ride ONE AllocateGauge batch, in the order they were supplied, funded by Σ leg values.
    IRootMessageOrchestrator.ChainDispatch[] memory _expectedBatch = new IRootMessageOrchestrator.ChainDispatch[](2);
    // it should leave the plain entry's dispatch unflagged
    // No sentinel on `_CHAIN_ID_1`, so its entry carries `chargeDeallocationReturn == false` and its whole
    // declared value. `emissionsPerVP` is 0 because no chain allocation is booked: the whole stake parks on
    // CHAIN0 as unbooked virgin VP, so `totalPoint` weight stays zero.
    _expectedBatch[0] = _gaugeDispatchEntry({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _context.plainValue,
      _chargeDeallocationReturn: false,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: 0,
        tokenSnapshot: IVoterCommon.TokenSnapshot({
          staked: _context.staked, stakeEnd: _context.stakeEnd, isPermanent: false
        }),
        allocations: _plainGauges
      })
    });

    // it should flag only the sentinel entry's dispatch to charge the deallocation return
    // Entry B carries its full declared value with the flag set; the flag never leaks onto entry A.
    _expectedBatch[1] = _gaugeDispatchEntry({
      _chainId: _CHAIN_ID_2,
      _gasLimit: _GAS_LIMIT,
      _nativeValue: _context.sentinelValue,
      _chargeDeallocationReturn: true,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        emissionsPerVP: 0,
        tokenSnapshot: IVoterCommon.TokenSnapshot({
          staked: _context.staked, stakeEnd: _context.stakeEnd, isPermanent: false
        }),
        allocations: _sentinelGauges
      })
    });

    uint256 _msgValue = _context.plainValue + _context.sentinelValue;
    _expectAllocateGaugeBatch(_expectedBatch, _msgValue);
    vm.deal(_CALLER, _msgValue);
    vm.prank(_CALLER);
    _voter.allocate{value: _msgValue}(
      _TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT
    );
  }

  /*////////////////////////////////////////////////////////////
              HAPPY PATHS
  ////////////////////////////////////////////////////////////*/
  function test_WhenEveryPhasePassesForASingleChain(
    uint128 _allocated,
    uint128 _remainder,
    uint48 _ts,
    uint48 _stakeEnd,
    uint256 _chainFee,
    uint256 _gaugeFee
  ) external givenCallerIsAuthorized {
    AllocateContext memory _context;
    _context.allocated = uint128(bound(_allocated, _MAXTIME, _INT128_MAX_HALF));
    _context.remainder = uint128(bound(_remainder, 0, _INT128_MAX_HALF));
    // Non-zero fee split so the AllocateChain / AllocateGauge value forwarding is exercised.
    _context.chainFee = bound(_chainFee, 1, 100 ether);
    _context.gaugeFee = bound(_gaugeFee, 1, 100 ether);
    (_context.ts, _context.tAct, _context.stakeEnd) = _setupFutureVote(_ts, _stakeEnd);
    _context.staked = _context.allocated + _context.remainder;

    // Independent phase-1 propagation scalar for the AllocateChain payload. Additive: only the
    // booked `allocated` lands in totalWeight; the virgin remainder never does.
    ExpectedContribution memory _expected = _computeExpected({
      _allocated: _context.allocated,
      _chain0: 0,
      _booked: _context.allocated,
      _tAct: _context.tAct,
      _stakeEnd: _context.stakeEnd
    });
    uint256 _emissionsPerVP = _expected.emissionsPerVP;

    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    // Strict model: `allocated` is parked on CHAIN0 and phase 1 redeploys it onto CHAIN_1. Seed CHAIN0
    // + totalPoint with the parked contribution at `_tAct`, CHAIN_1 empty; the move is committed-neutral.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: _expected.biasX, _slope: _expected.slopeX, _ts: _context.tAct, _perm: 0});
    _mockTotalPoint({_bias: _expected.biasT, _slope: _expected.slopeT, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _context.allocated});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _context.allocated, _lastStakeEnd: _context.stakeEnd, _lastAllocated: 0
    });

    _mockStaked({_amount: _context.staked, _end: _context.stakeEnd, _isPermanent: false});

    // Phase 1: redeploy CHAIN0-parked `allocated` onto `_CHAIN_ID_1` (the unbooked remainder is
    // untouched). The chain allocation entry carries the chain fee as its `value`.
    IVoter.ChainAllocationDispatch[] memory _chainAllocations = new IVoter.ChainAllocationDispatch[](1);
    _chainAllocations[0] = IVoter.ChainAllocationDispatch({
      chainId: _CHAIN_ID_1, delta: _context.allocated, gasLimit: _GAS_LIMIT, value: _context.chainFee
    });

    // Phase 2: distribute the entire freshly-written budget (`allocated`) to one gauge on the same
    // chain. The gauge dispatch carries the gauge fee.
    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _context.allocated);
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: _context.gaugeFee, gauges: _gauges
    });

    // it should dispatch the AllocateChain batch with the chain fee
    _expectAllocateChainBatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _chainFee: _context.chainFee,
      _message: IVoterCommon.AllocateChainMessage({
        tokenId: _TOKEN_ID,
        allocationDelta: _context.allocated,
        emissionsPerVP: _emissionsPerVP,
        snapshot: IVoterCommon.TokenSnapshot({staked: _context.staked, stakeEnd: _context.stakeEnd, isPermanent: false})
      })
    });

    // it should validate the gauge list against the freshly written budget
    // it should dispatch the AllocateGauge batch with the gauge fee
    _expectAllocateGaugeBatchWithFee({
      _chainId: _CHAIN_ID_1,
      _gasLimit: _GAS_LIMIT,
      _gaugeFee: _context.gaugeFee,
      _chargeDeallocationReturn: false,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        // Phase 2 reads the same global scalar phase 1 shipped: `totalPoint` was resolved in phase 1
        // and `_refreshEmissionsPerVP` is idempotent, so the gauge batch carries the AllocateChain value.
        emissionsPerVP: _emissionsPerVP,
        tokenSnapshot: IVoterCommon.TokenSnapshot({
          staked: _context.staked, stakeEnd: _context.stakeEnd, isPermanent: false
        }),
        allocations: _gauges
      })
    });

    // it should emit the ChainsAllocated event once for the chain dispatch array
    _expectEmit(address(_voter));
    emit IVoter.ChainsAllocated(_TOKEN_ID, _chainAllocations);
    // it should emit the GaugesAllocated event once per gauge dispatch carrying its chainId and gauges
    _expectEmit(address(_voter));
    emit IVoter.GaugesAllocated(_TOKEN_ID, _CHAIN_ID_1, _gauges);

    uint256 _msgValue = _context.chainFee + _context.gaugeFee;
    vm.deal(_CALLER, _msgValue);
    vm.prank(_CALLER);
    _voter.allocate{value: _msgValue}(_TOKEN_ID, _chainAllocations, _gaugeDispatches, _REFUND_RECIPIENT);

    // it should store the per chain allocated budget in phase one
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _context.allocated);
    // it should drain the parked chain zero balance (committed-neutral move)
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
    _assertTokenState({
      _target: _voter,
      _tokenId: _TOKEN_ID,
      _committed: _context.allocated,
      _lastStakeEnd: _context.stakeEnd,
      _lastAllocated: _context.ts
    });
  }

  function test_WhenAGaugeDispatchTargetsTheRootColocatedChainWithAZeroGasLimit(
    uint128 _staked,
    uint48 _stakeEnd,
    uint128 _gaugeAlloc,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    _staked = uint128(bound(_staked, _MAXTIME, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    uint48 _tAct;
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});

    // No chain allocation in phase 1 — the whole stake parks on CHAIN0, so no AllocateChain dispatch
    // fires. Seed CHAIN0 + totalPoint at `_tAct` so the resolve walk no-ops.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});

    // Book the budget for `block.chainid` directly so phase 2's gauge list validates. Seed its point too so
    // the dispatch's rate refresh settles/resolves without walking from the epoch.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: block.chainid, _amount: _gaugeAlloc});
    _mockChainPoint({_chainId: block.chainid, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainLastIndex({_chainId: block.chainid, _value: _voter.index()});

    IVoterCommon.GaugeAllocation[] memory _gauges = _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc);
    // Root-colocated chain with `gasLimit == 0`: delivered synchronously, so the zero limit is allowed.
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] =
      IVoter.GaugeAllocationDispatch({chainId: block.chainid, gasLimit: 0, value: 0, gauges: _gauges});

    // it should dispatch the AllocateGauge batch without reverting
    _expectAllocateGaugeBatchWithFee({
      _chainId: block.chainid,
      _gasLimit: 0,
      _gaugeFee: 0,
      _chargeDeallocationReturn: false,
      _message: IVoterCommon.AllocateGaugeMessage({
        tokenId: _TOKEN_ID,
        expiry: uint48(block.timestamp) + _ALLOCATION_LIFETIME,
        // No chain allocation booked: the whole stake parks on CHAIN0 as unbooked virgin VP, so
        // `totalPoint` weight stays zero and `_refreshEmissionsPerVP` returns 0.
        emissionsPerVP: 0,
        tokenSnapshot: IVoterCommon.TokenSnapshot({staked: _staked, stakeEnd: _stakeEnd, isPermanent: false}),
        allocations: _gauges
      })
    });

    vm.prank(_CALLER);
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);
  }

  /*////////////////////////////////////////////////////////////
        SINGLE SNAPSHOT ACROSS EVERY BATCH
  ////////////////////////////////////////////////////////////*/

  function test_WhenARefundRecipientGrowsTheStakeMidCall(
    uint128 _allocated,
    uint128 _stakeGrowth,
    uint48 _ts,
    uint48 _stakeEnd
  ) external givenCallerIsAuthorized {
    // `ORCHESTRATOR.dispatch` is a control-flow yield point: the transport refunds the excess fee to a
    // caller-supplied recipient, so an attacker-chosen address regains control mid-call and can reenter
    // the VotingEscrow — a separate contract, outside this one's `nonReentrant`. `increaseStakeAmount`
    // raises `amount` and leaves `end` alone, so the stored-shape guard cannot see it. One `allocate`
    // must still describe exactly one position: every payload it emits carries the snapshot taken before
    // the first send, never a re-read.
    ReentrancyContext memory _context;
    _context.allocated = uint128(bound(_allocated, _MAXTIME, _INT128_MAX_HALF));
    _context.stakeGrowth = uint128(bound(_stakeGrowth, 1, _INT128_MAX_HALF));
    (_context.ts, _context.tAct, _context.stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    // Independent propagation scalar for both payloads: the whole booked amount lands on `_CHAIN_ID_1`.
    ExpectedContribution memory _expected = _computeExpected({
      _allocated: _context.allocated,
      _chain0: 0,
      _booked: _context.allocated,
      _tAct: _context.tAct,
      _stakeEnd: _context.stakeEnd
    });
    _context.emissionsPerVP = _expected.emissionsPerVP;

    // `allocated` is parked on CHAIN0 and the chain leg redeploys it onto `_CHAIN_ID_1`; the gauge leg
    // then distributes that exact budget. Points are anchored at `tAct` so no walk enters the math.
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainPoint({_chainId: _CHAIN0, _bias: _expected.biasX, _slope: _expected.slopeX, _ts: _context.tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockTotalPoint({_bias: _expected.biasT, _slope: _expected.slopeT, _ts: _context.tAct, _perm: 0});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _context.allocated});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _context.allocated, _lastStakeEnd: _context.stakeEnd, _lastAllocated: 0
    });
    _mockStaked({_amount: _context.allocated, _end: _context.stakeEnd, _isPermanent: false});

    // The attacker sits behind the refund: on the FIRST dispatch it grows the stake and bumps the
    // emission rate, then records everything the Voter hands it. `vm.etch` keeps the orchestrator
    // address the Voter was constructed with; the double's immutables survive the etch.
    vm.etch(
      _ORCHESTRATOR,
      address(new ReentrantRefundOrchestrator(_VOTING_ESCROW, _MINTER, _TOKEN_ID, _context.stakeGrowth)).code
    );

    IVoter.ChainAllocationDispatch[] memory _chainAllocations = new IVoter.ChainAllocationDispatch[](1);
    _chainAllocations[0] = IVoter.ChainAllocationDispatch({
      chainId: _CHAIN_ID_1, delta: _context.allocated, gasLimit: _GAS_LIMIT, value: 1 ether
    });
    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1,
      gasLimit: _GAS_LIMIT,
      value: 1 ether,
      gauges: _singleGaugeAllocation(_GAUGE_1, _context.allocated)
    });

    // Overfunded legs are what produce a refund in production, hence the yield point under test.
    vm.deal(_CALLER, 2 ether);
    vm.prank(_CALLER);
    _voter.allocate{value: 2 ether}(_TOKEN_ID, _chainAllocations, _gaugeDispatches, _REFUND_RECIPIENT);

    _assertOneSnapshotAcrossBothBatches(_context);
  }

  /**
   * @notice Assert the recorded `AllocateChain` and `AllocateGauge` payloads describe one position.
   * @dev Split out of the test body to stay under the legacy non-via-ir stack limit. Also re-asserts
   *      that the double's mid-call mutations actually landed, so a silently inert double cannot make
   *      the equality checks vacuous.
   * @param _context The test's snapshotted inputs and independently computed scalar.
   */
  function _assertOneSnapshotAcrossBothBatches(ReentrancyContext memory _context) private {
    ReentrantRefundOrchestrator _recorder = ReentrantRefundOrchestrator(_ORCHESTRATOR);
    assertEq(_recorder.callCount(), 2);
    IVoterCommon.AllocateChainMessage memory _chainMessage =
      abi.decode(_recorder.payloadAt(0, 0), (IVoterCommon.AllocateChainMessage));
    IVoterCommon.AllocateGaugeMessage memory _gaugeMessage =
      abi.decode(_recorder.payloadAt(1, 0), (IVoterCommon.AllocateGaugeMessage));

    // Precondition: the attacker's mid-call reentrancy really did move both external values.
    assertEq(IVotingEscrow(_VOTING_ESCROW).staked(_TOKEN_ID).amount, _context.allocated + _context.stakeGrowth);
    assertEq(IMinter(_MINTER).emissionRate(), 2 * uint256(_MINTER_RATE));

    // it should ship the pre call staked amount in both batches
    assertEq(_chainMessage.snapshot.staked, _context.allocated);
    assertEq(_gaugeMessage.tokenSnapshot.staked, _chainMessage.snapshot.staked);
    // it should ship the pre call stake end in both batches
    assertEq(_chainMessage.snapshot.stakeEnd, _context.stakeEnd);
    assertEq(_gaugeMessage.tokenSnapshot.stakeEnd, _chainMessage.snapshot.stakeEnd);
    // it should ship one emissions per VP in both batches
    // Both are denominated by the single snapshotted `MINTER.emissionRate()`, i.e. the pre-call rate.
    assertEq(_chainMessage.emissionsPerVP, _context.emissionsPerVP);
    assertEq(_gaugeMessage.emissionsPerVP, _chainMessage.emissionsPerVP);
    assertEq(_voter.emissionsPerVP(), _context.emissionsPerVP);
  }

  function test_WhenTheCallCarriesSeveralGaugeLegs(
    uint128 _parked,
    uint128 _secondBooked,
    uint48 _ts
  ) external givenCallerIsAuthorized {
    // Foundry cannot assert call ORDER, so the send sequence is read off a recording double.
    _parked = uint128(bound(_parked, 1, _INT128_MAX_HALF));
    _secondBooked = uint128(bound(_secondBooked, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    // Permanent stake: shape-free, so nothing decays and each leg's shape guard passes on `stakeEnd == 0`.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockChainPoint({_chainId: _CHAIN_ID_2, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_2, _value: _voter.index()});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _parked});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _parked, _lastStakeEnd: uint48(0), _lastAllocated: 0});
    _mockStaked({_amount: _parked, _end: uint48(0), _isPermanent: true});
    // The second leg's chain carries its own booked budget, untouched by the chain phase.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_2, _amount: _secondBooked});

    vm.etch(_ORCHESTRATOR, address(new RecordingOrchestrator()).code);

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](2);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, _parked)
    });
    _gaugeDispatches[1] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_2, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_2, _secondBooked)
    });

    vm.prank(_CALLER);
    _voter.allocate(
      _TOKEN_ID,
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _parked, _gasLimit: _GAS_LIMIT}),
      _gaugeDispatches,
      _REFUND_RECIPIENT
    );

    RecordingOrchestrator _recorder = RecordingOrchestrator(_ORCHESTRATOR);
    // it should dispatch exactly two batches
    assertEq(_recorder.callCount(), 2);
    // it should send the chain batch before the gauge batch
    assertEq(uint8(_recorder.messageTypeAt(0)), uint8(IMessageOrchestrator.MessageType.AllocateChain));
    assertEq(uint8(_recorder.messageTypeAt(1)), uint8(IMessageOrchestrator.MessageType.AllocateGauge));
    // it should pack every gauge leg into one batch
    assertEq(_recorder.payloadCount(0), 1);
    assertEq(_recorder.payloadCount(1), 2);
  }

  /*////////////////////////////////////////////////////////////
              EMPTY BATCH SKIPS
  ////////////////////////////////////////////////////////////*/

  function test_WhenTheChainDispatchListIsEmpty(
    uint128 _staked,
    uint128 _gaugeAlloc,
    uint48 _ts,
    uint48 _stakeEnd
  ) external givenCallerIsAuthorized {
    // An empty chain list is a pure-local shape refresh: it books nothing and must not put an
    // AllocateChain message on the wire, while still re-anchoring the token locally.
    _staked = uint128(bound(_staked, 1, _INT128_MAX_HALF));
    _gaugeAlloc = uint128(bound(_gaugeAlloc, 1, type(uint128).max));
    uint48 _tAct;
    (_ts, _tAct, _stakeEnd) = _setupFutureVote(_ts, _stakeEnd);

    _mockStaked({_amount: _staked, _end: _stakeEnd, _isPermanent: false});
    // The whole stake stays unbooked on CHAIN0; seed CHAIN0 + totalPoint at `tAct` so the resolve no-ops.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    // The gauge leg validates against its own booked budget.
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN_ID_1, _amount: _gaugeAlloc});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _tAct, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});

    vm.etch(_ORCHESTRATOR, address(new RecordingOrchestrator()).code);

    IVoter.GaugeAllocationDispatch[] memory _gaugeDispatches = new IVoter.GaugeAllocationDispatch[](1);
    _gaugeDispatches[0] = IVoter.GaugeAllocationDispatch({
      chainId: _CHAIN_ID_1, gasLimit: _GAS_LIMIT, value: 0, gauges: _singleGaugeAllocation(_GAUGE_1, _gaugeAlloc)
    });

    vm.prank(_CALLER);
    _voter.allocate(_TOKEN_ID, new IVoter.ChainAllocationDispatch[](0), _gaugeDispatches, _REFUND_RECIPIENT);

    RecordingOrchestrator _recorder = RecordingOrchestrator(_ORCHESTRATOR);
    // it should not dispatch a chain batch
    assertEq(_recorder.callCount(), 1);
    assertEq(uint8(_recorder.messageTypeAt(0)), uint8(IMessageOrchestrator.MessageType.AllocateGauge));
    // it should still apply the local accounting
    _assertTokenState({
      _target: _voter, _tokenId: _TOKEN_ID, _committed: 0, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts
    });
  }

  function test_WhenTheGaugeDispatchListIsEmpty(uint128 _parked, uint48 _ts) external givenCallerIsAuthorized {
    // No gauge leg means no AllocateGauge message at all; the chain batch still ships on its own.
    _parked = uint128(bound(_parked, 1, _INT128_MAX_HALF));
    _ts = uint48(bound(_ts, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK));
    vm.warp(_ts);
    // Anchor the global settle cursor at now: the global settle banks the accumulator one week boundary
    // at a time, and this scenario asserts nothing about the index or the ceiling, so leaving the cursor
    // at the deploy timestamp would walk the whole fuzzed gap for no observable effect.
    _mockLastGlobalSettlement(_ts);

    // Permanent stake so the redeploy touches only `perm` and nothing decays.
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockChainLastIndex({_chainId: _CHAIN0, _value: _voter.index()});
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _ts, _perm: 0});
    _mockChainLastIndex({_chainId: _CHAIN_ID_1, _value: _voter.index()});
    _mockTotalPoint({_bias: 0, _slope: 0, _ts: _ts, _perm: _parked});
    _mockAllocationChainAmount({_tokenId: _TOKEN_ID, _chainId: _CHAIN0, _amount: _parked});
    _mockExistingChainIds({_tokenId: _TOKEN_ID, _chainIds: _singletonArray(_CHAIN0)});
    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _parked, _lastStakeEnd: uint48(0), _lastAllocated: 0});
    _mockStaked({_amount: _parked, _end: uint48(0), _isPermanent: true});

    vm.etch(_ORCHESTRATOR, address(new RecordingOrchestrator()).code);

    vm.prank(_CALLER);
    _voter.allocate(
      _TOKEN_ID,
      _singleChainAllocation({_chainId: _CHAIN_ID_1, _amount: _parked, _gasLimit: _GAS_LIMIT}),
      new IVoter.GaugeAllocationDispatch[](0),
      _REFUND_RECIPIENT
    );

    RecordingOrchestrator _recorder = RecordingOrchestrator(_ORCHESTRATOR);
    // it should not dispatch a gauge batch
    assertEq(_recorder.callCount(), 1);
    assertEq(uint8(_recorder.messageTypeAt(0)), uint8(IMessageOrchestrator.MessageType.AllocateChain));
    // it should still apply the local accounting
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN_ID_1), _parked);
    assertEq(_voter.allocationChainAmounts(_TOKEN_ID, _CHAIN0), 0);
  }

  /*////////////////////////////////////////////////////////////
              HELPERS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Expect the single-entry `AllocateChain` batch dispatch carrying the summed chain fee as
   *         the forwarded `msg.value`.
   * @dev `allocate` forwards `Σ _dispatchParams.value` to the AllocateChain dispatch. The per-chain
   *      `nativeValue` equals that same fee for the single-chain case. Chain allocations never carry a
   *      deallocation return, so the dispatch is always unflagged.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _chainFee Native value forwarded to the AllocateChain dispatch.
   * @param _message The `AllocateChainMessage` body the orchestrator will receive.
   */
  function _expectAllocateChainBatchWithFee(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _chainFee,
    IVoterCommon.AllocateChainMessage memory _message
  ) private {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _chainFee,
      chargeDeallocationReturn: false,
      payload: abi.encode(_message)
    });
    vm.expectCall(
      _ORCHESTRATOR,
      _chainFee,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.AllocateChain, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Expect the single-entry `AllocateGauge` batch dispatch carrying the entry's full declared
   *         value as the forwarded `msg.value`.
   * @dev `allocate` batches every gauge leg into ONE `ORCHESTRATOR.dispatch`, funded by Σ entry values —
   *      so for a one-leg call the batch fee is that leg's whole declared value. The deallocation return
   *      cost is retained by the orchestrator, not the Voter, so the Voter only signals it via
   *      `chargeDeallocationReturn`.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _gaugeFee Native value forwarded to the AllocateGauge batch.
   * @param _chargeDeallocationReturn Whether the entry's gauge list carries the `DEALLOC_GAUGE` sentinel.
   * @param _message The `AllocateGaugeMessage` body the orchestrator will receive.
   */
  function _expectAllocateGaugeBatchWithFee(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _gaugeFee,
    bool _chargeDeallocationReturn,
    IVoterCommon.AllocateGaugeMessage memory _message
  ) private {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = _gaugeDispatchEntry(_chainId, _gasLimit, _gaugeFee, _chargeDeallocationReturn, _message);
    _expectAllocateGaugeBatch(_dispatches, _gaugeFee);
  }

  /**
   * @notice Build one `AllocateGauge` batch entry.
   * @dev Its own frame so a multi-leg expectation can assemble each message without stacking every
   *      leg's locals in the caller.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _nativeValue The leg's declared value, carried through to the orchestrator.
   * @param _chargeDeallocationReturn Whether the leg's gauge list carries the `DEALLOC_GAUGE` sentinel.
   * @param _message The `AllocateGaugeMessage` body for this leg.
   * @return _entry The built dispatch entry.
   */
  function _gaugeDispatchEntry(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _nativeValue,
    bool _chargeDeallocationReturn,
    IVoterCommon.AllocateGaugeMessage memory _message
  ) private pure returns (IRootMessageOrchestrator.ChainDispatch memory _entry) {
    _entry = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: _chargeDeallocationReturn,
      payload: abi.encode(_message)
    });
  }

  /**
   * @notice Expect the one `AllocateGauge` batch `allocate` sends, whatever its leg count.
   * @param _dispatches Expected batch entries, in the order the contract builds them.
   * @param _batchFee Native value forwarded with the batch (Σ leg values).
   */
  function _expectAllocateGaugeBatch(
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches,
    uint256 _batchFee
  ) private {
    vm.expectCall(
      _ORCHESTRATOR,
      _batchFee,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.AllocateGauge, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }
}

/**
 * @notice Orchestrator test double that logs every `dispatch` it receives instead of sending anything.
 * @dev Foundry cannot assert the ORDER of two calls, nor that a call was NOT made in a specific shape, so
 *      the send sequence, batch count and per-batch payloads are asserted against this log. `vm.etch`ed
 *      onto the address the Voter was constructed with, so it runs against that address's (empty) storage.
 */
contract RecordingOrchestrator {
  /// @notice Message type of every recorded dispatch, in call order.
  IMessageOrchestrator.MessageType[] internal _messageTypes;
  /// @notice Forwarded `msg.value` of every recorded dispatch, in call order.
  uint256[] internal _values;
  /// @notice Every `ChainDispatch.payload` of call `_callIndex`, in batch order.
  mapping(uint256 _callIndex => bytes[] _payloads) internal _payloads;

  /**
   * @notice Record a dispatch, then run the reentrancy hook.
   * @param _msgType Message type the Voter is sending.
   * @param _dispatches Batch the Voter built.
   */
  function dispatch(
    IMessageOrchestrator.MessageType _msgType,
    IRootMessageOrchestrator.ChainDispatch[] calldata _dispatches,
    address
  ) external payable {
    uint256 _index = _messageTypes.length;
    _messageTypes.push(_msgType);
    _values.push(msg.value);

    uint256 _length = _dispatches.length;
    for (uint256 _i; _i < _length; ++_i) {
      _payloads[_index].push(_dispatches[_i].payload);
    }

    _afterDispatch(_index);
  }

  /**
   * @notice Number of dispatches recorded so far.
   * @return _count Recorded call count.
   */
  function callCount() external view returns (uint256 _count) {
    _count = _messageTypes.length;
  }

  /**
   * @notice Message type of a recorded dispatch.
   * @param _index Call index, in send order.
   * @return _msgType The recorded message type.
   */
  function messageTypeAt(uint256 _index) external view returns (IMessageOrchestrator.MessageType _msgType) {
    _msgType = _messageTypes[_index];
  }

  /**
   * @notice Forwarded native value of a recorded dispatch.
   * @param _index Call index, in send order.
   * @return _value The recorded `msg.value`.
   */
  function valueAt(uint256 _index) external view returns (uint256 _value) {
    _value = _values[_index];
  }

  /**
   * @notice Number of batch entries a recorded dispatch carried.
   * @param _index Call index, in send order.
   * @return _count Entry count of that batch.
   */
  function payloadCount(uint256 _index) external view returns (uint256 _count) {
    _count = _payloads[_index].length;
  }

  /**
   * @notice One entry's payload from a recorded dispatch.
   * @param _index Call index, in send order.
   * @param _entry Entry index within that batch.
   * @return _payload The recorded payload bytes.
   */
  function payloadAt(uint256 _index, uint256 _entry) external view returns (bytes memory _payload) {
    _payload = _payloads[_index][_entry];
  }

  /**
   * @notice Hook run after a dispatch is recorded. Inert here.
   * @dev Overridden by doubles that reenter mid-dispatch.
   */
  function _afterDispatch(uint256) internal virtual {}
}

/**
 * @notice Recording orchestrator that reenters on its FIRST dispatch, standing in for the attacker behind
 *         a caller-supplied refund recipient: the transport refunds the excess transport fee to it, which
 *         hands it control flow while the Voter is mid-call.
 * @dev It grows the VE stake the way `increaseStakeAmount` does — more `amount`, same `end`, so no
 *      stored-shape guard can see it — and bumps the emission rate. A Voter that re-reads either after its
 *      first send would emit two messages describing two different positions. Cheatcodes are called
 *      directly through the hevm address so the double works after `vm.etch`; constructor args live in
 *      immutables so the runtime code carries them through that etch.
 */
contract ReentrantRefundOrchestrator is RecordingOrchestrator {
  /// @notice Forge's cheatcode account.
  Vm internal constant _VM = Vm(address(uint160(uint256(keccak256('hevm cheat code')))));

  /// @notice VotingEscrow whose `staked` read is re-mocked mid-dispatch.
  address internal immutable _VOTING_ESCROW;
  /// @notice Minter whose `emissionRate` read is re-mocked mid-dispatch.
  address internal immutable _MINTER;
  /// @notice Token whose stake is grown.
  uint256 internal immutable _TOKEN_ID;
  /// @notice Amount added to the live staked balance, mirroring `increaseStakeAmount`.
  uint128 internal immutable _STAKE_GROWTH;

  /**
   * @notice Wire the double to the mocked externals it mutates mid-dispatch.
   * @param _votingEscrow VotingEscrow address.
   * @param _minter Minter address.
   * @param _tokenId Token whose stake is grown.
   * @param _stakeGrowth Amount added to the live staked balance.
   */
  constructor(address _votingEscrow, address _minter, uint256 _tokenId, uint128 _stakeGrowth) {
    _VOTING_ESCROW = _votingEscrow;
    _MINTER = _minter;
    _TOKEN_ID = _tokenId;
    _STAKE_GROWTH = _stakeGrowth;
  }

  /// @inheritdoc RecordingOrchestrator
  function _afterDispatch(uint256 _index) internal override {
    // Only the first send is the attack window; a Voter that finished reading before it is immune.
    if (_index != 0) return;

    IVotingEscrow.StakedBalance memory _stake = IVotingEscrow(_VOTING_ESCROW).staked(_TOKEN_ID);
    _VM.mockCall(
      _VOTING_ESCROW,
      abi.encodeCall(IVotingEscrow.staked, (_TOKEN_ID)),
      abi.encode(
        IVotingEscrow.StakedBalance({
          amount: _stake.amount + _STAKE_GROWTH, end: _stake.end, isPermanent: _stake.isPermanent
        })
      )
    );
    _VM.mockCall(_MINTER, abi.encodeCall(IMinter.emissionRate, ()), abi.encode(IMinter(_MINTER).emissionRate() * 2));
  }
}
