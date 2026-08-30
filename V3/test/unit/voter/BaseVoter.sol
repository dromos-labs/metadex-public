// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IVoter, Voter} from 'V3/voter/Voter.sol';

abstract contract BaseVoter is TestHelpers {
  address internal immutable _VOTING_ESCROW = makeAddr('VotingEscrow');
  address internal immutable _ORCHESTRATOR = makeAddr('MessageOrchestrator');
  address internal immutable _MINTER = makeAddr('Minter');
  address internal immutable _TOKEN = makeAddr('Token');
  address internal immutable _GOVERNOR = makeAddr('Governor');
  address internal immutable _CONFIG_ADMIN = makeAddr('ConfigAdmin');
  address internal immutable _VOTER_CONFIG = makeAddr('VoterConfig');
  address internal immutable _CHAIN_CONFIG = makeAddr('ChainConfig');
  address internal immutable _CHAIN_STATUS = makeAddr('ChainStatus');
  address internal immutable _AUTHORIZED_VPM = makeAddr('AuthorizedVPM');
  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _REFUND_RECIPIENT = makeAddr('RefundRecipient');

  /// @notice Baseline `block.timestamp` warped into before deploying Voter so the constructor
  ///         seeds CHAIN0 at a realistic time. Fixed at 2026-01-01 00:00 UTC.
  uint48 internal constant _INITIAL_TIMESTAMP = 1_767_225_600;
  uint128 internal constant _MINTER_RATE = 10 ether;
  /// @notice Mirrors `Minter.MIN_MINT_AMOUNT` (`MAX_PIPS`). Mints below it revert `AmountTooLow`.
  uint256 internal constant _MIN_MINT_AMOUNT = 1_000_000;
  /// @notice `PRECISION` scaling factor mirrored from `ProtocolConstants.PRECISION` (`1e18`).
  ///         The dispatched `emissionsPerVP` is `PRECISION`-scaled.
  uint256 internal constant _PRECISION = 1e18;
  uint48 internal constant _MAXTIME = 4 * 365 days;
  uint48 internal constant _WEEK = 7 days;
  /// @notice 1 AERO in wei. Matches V2 test anchor (`TOKEN_1`). Use as the unit input for
  ///         hardcoded-literal walk/contribution tests so expected bias/slope values are
  ///         comparable across the two repos.
  uint128 internal constant _ONE_AERO = 1e18;
  /// @notice Slope contribution of 1 AERO over `_MAXTIME`. `1e18 / 126_144_000 = 7_927_447_995`
  ///         (integer division). Matches V2's `TOKEN_1 / MAXTIME` anchor.
  int128 internal constant _SLOPE_ONE_AERO = 7_927_447_995;
  /// @notice `type(int128).max` expressed as `uint128`. Upper bound for fuzzed amounts that
  ///         the contract casts to `int128` via `SafeCastLibrary.toInt128`.
  uint128 internal constant _INT128_MAX = uint128(type(int128).max);
  /// @notice Half of `_INT128_MAX`. Use as the upper bound on two amounts that get summed
  ///         (e.g. `_allocated + _remainder = _staked`) so the sum still fits in `int128`.
  uint128 internal constant _INT128_MAX_HALF = _INT128_MAX / 2;

  /// @notice Shared test actors / scopes. Tests that aren't specifically exercising routing or
  ///         auth use these as constants so fuzz slots stay reserved for variables that
  ///         actually drive their assertions. Tests that DO turn on these values (auth-revert,
  ///         ordering checks) keep their own fuzz parameters.
  address internal immutable _CALLER = makeAddr('Caller');
  address internal immutable _GAUGE_1 = makeAddr('Gauge1');
  address internal immutable _GAUGE_2 = makeAddr('Gauge2');
  uint256 internal constant _TOKEN_ID = 1;
  uint256 internal constant _TOKEN_ID_2 = 2;
  uint256 internal constant _TOKEN0 = 0; // mirrors Voter.TOKEN0 — the burn-token id
  uint256 internal constant _CHAIN0 = 0; // mirrors Voter.CHAIN0 — the idle-sink chain id
  uint256 internal constant _CHAIN_ID_1 = 100;
  uint256 internal constant _CHAIN_ID_2 = 200;
  uint256 internal constant _CHAIN_ID_3 = 300;
  /// @notice Chain id deliberately left out of the registered set; use for unregistered-chain paths.
  uint256 internal constant _UNREGISTERED_CHAIN_ID = 999;
  uint256 internal constant _GAS_LIMIT = 1_000_000;
  /// @notice Message lifetime passed to the constructor. `_buildGaugeMessage` stamps every gauge
  ///         dispatch with the absolute deadline `block.timestamp + _ALLOCATION_LIFETIME`.
  uint48 internal constant _ALLOCATION_LIFETIME = 1 hours;
  /// @notice Claim and operator message lifetime passed to the constructor. Stamped onto every claim
  ///         and operator dispatch as the absolute deadline `block.timestamp + _MESSAGE_LIFETIME`.
  uint48 internal constant _MESSAGE_LIFETIME = 2 hours;

  /// @notice Voter's storage slots. `AccessControlEnumerable` reserves slots 0 (`_roles`) and 1
  ///         (`_roleMembers`); the `VoterStorage` holder declared in `VoterStorageBase` starts at slot 2.
  ///         Each constant is the slot of a struct field — value slots are derived via
  ///         `keccak256(abi.encode(key, _SLOT_*))` for mappings or `_SLOT_* + offset` for fixed structs.
  ///         Update these (and only these) when storage layout shifts; verify with
  ///         `forge inspect V3/src/voter/Voter.sol:Voter storage`.
  uint256 internal constant _SLOT_ALLOCATION_CHAIN_IDS = 2;
  uint256 internal constant _SLOT_ALLOCATION_CHAIN_AMOUNTS = 3;
  uint256 internal constant _SLOT_TOKEN_STATES = 4;
  uint256 internal constant _SLOT_CHAIN_STATES = 5;
  uint256 internal constant _SLOT_CHAIN_SLOPE_CHANGES = 6;
  /// @notice `emergencyDeallocationAllowed` (uint256 => bool) occupies slot 7.
  uint256 internal constant _SLOT_EMERGENCY_DEALLOCATION_ALLOWED = 7;
  /// @notice `totalPoint` occupies slots 8 and 9 (`Point` is 2 slots: bias/slope, then perm/ts).
  uint256 internal constant _SLOT_TOTAL_POINT = 8;
  uint256 internal constant _SLOT_TOTAL_POINT_PERM_TS = 9;
  uint256 internal constant _SLOT_TOTAL_SLOPE_CHANGES = 10;
  /// @notice Global emissions accumulator `index` (`∫ emissionsPerVP·dt`, `PRECISION`-scaled).
  uint256 internal constant _SLOT_INDEX = 11;
  /// @notice Global time-weighted accumulator `timeIndex` (`∫ 2(t-origin)·emissionsPerVP·dt`, `PRECISION`-scaled).
  uint256 internal constant _SLOT_TIME_INDEX = 12;
  /// @notice Global sampled `emissionsPerVP` (`minterRate * PRECISION / totalWeight`).
  uint256 internal constant _SLOT_EMISSIONS_PER_VP = 13;
  /// @notice `lastGlobalSettlement` (uint48) — the timestamp `index` was last advanced to.
  uint256 internal constant _SLOT_LAST_GLOBAL_SETTLEMENT = 14;
  /// @notice `allocationLifetime` and `messageLifetime` pack in slot 19, after `indexAtBoundary` (15),
  ///         `timeIndexAtBoundary` (16) and `chains` (17-18).

  Voter internal _voter;

  /**
   * @notice Mock + expect the canonical "caller is authorized for `_TOKEN_ID`" VE call.
   * @dev Setup that's identical across all happy-path tests — apply with `givenCallerIsAuthorized`
   *      modifier so the test body stays focused on the scenario-specific state. Auth-revert
   *      tests mock `false` inline and skip the modifier.
   */
  modifier givenCallerIsAuthorized() {
    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _;
  }

  /**
   * @notice Mock a live, shape-free VE stake for `_TOKEN_ID`.
   * @dev Every allocation entrypoint snapshots `VOTING_ESCROW.staked` up front — before it validates its
   *      inputs — so even a test that only exercises input validation reaches that read and must have it
   *      mocked. A 1-wei permanent stake is live under `_requireLiveStake` and carries `stakeEnd == 0`,
   *      matching the default `tokenStates.lastStakeEnd` so the gauge path's shape guard passes too.
   *      Tests that assert on the snapshotted values mock their own stake instead.
   */
  modifier givenTheStakeIsLive() {
    _mockStaked({_amount: 1, _end: uint48(0), _isPermanent: true});
    _;
  }

  /**
   * @notice Mock `_VOTING_ESCROW.staked(_TOKEN_ID)` to return the given snapshot.
   * @dev Wraps the 4-line StakedBalance literal that repeats in every vote-pipeline test.
   *      Parameters differ per scenario (permanent vs non-permanent, amount, expiry), so
   *      this lives as a helper rather than a modifier. For multi-token scenarios
   *      (e.g. rebalanceChain0's src/dst), use `_mockStakedFor` directly.
   * @param _amount Staked AERO amount.
   * @param _end Week-aligned stake expiry. Pass `uint48(0)` together with `_isPermanent = true`.
   * @param _isPermanent True for permanent stakes; the contract normalizes `veStakeEnd` to 0.
   */
  function _mockStaked(uint128 _amount, uint48 _end, bool _isPermanent) internal {
    _mockStakedFor(_TOKEN_ID, _amount, _end, _isPermanent);
  }

  /**
   * @notice Mock `_VOTING_ESCROW.staked(_tokenId)` to return the given snapshot.
   * @dev Token-parameterized variant of `_mockStaked`. Use for tests that mock multiple
   *      tokens (e.g. rebalanceChain0 with distinct src/dst stakes).
   * @param _tokenId Token id whose staked balance the call returns.
   * @param _amount Staked AERO amount.
   * @param _end Week-aligned stake expiry. Pass `uint48(0)` together with `_isPermanent = true`.
   * @param _isPermanent True for permanent stakes; the contract normalizes `veStakeEnd` to 0.
   */
  function _mockStakedFor(uint256 _tokenId, uint128 _amount, uint48 _end, bool _isPermanent) internal {
    _mockAndExpect(
      _VOTING_ESCROW,
      abi.encodeCall(IVotingEscrow.staked, (_tokenId)),
      abi.encode(IVotingEscrow.StakedBalance({amount: _amount, end: _end, isPermanent: _isPermanent}))
    );
  }

  /**
   * @notice Wrap a single `uint256` in a length-1 array.
   * @dev Convenience for callers like `_mockExistingChainIds(_TOKEN_ID, _singletonArray(_chainId))`.
   * @param _value The element to wrap.
   * @return _array Length-1 array containing `_value`.
   */
  function _singletonArray(uint256 _value) internal pure returns (uint256[] memory _array) {
    _array = new uint256[](1);
    _array[0] = _value;
  }

  /// @notice Hand-computed contribution math for a single additive add: one leaf chain X carrying
  ///         `_allocated` VP, with `totalPoint` carrying the booked total (`committed`). Under the
  ///         additive model there is NO CHAIN0 auto-remainder — virgin VP is never booked and never
  ///         enters `totalWeight`. `slope0`/`bias0`/`chainRate0` model an explicitly-booked CHAIN0
  ///         position (deallocation return) when a scenario seeds one; leave the CHAIN0 amount at
  ///         `0` for a pure single-chain add.
  struct ExpectedContribution {
    int128 slopeX;
    int128 slope0;
    int128 slopeT;
    int128 biasX;
    int128 bias0;
    int128 biasT;
    uint256 chainRateX;
    uint256 chainRate0;
    uint256 emissionsPerVP;
  }

  /**
   * @notice Hand-compute the expected post-add contribution for a non-permanent stake, for a chain X
   *         carrying `_allocated`, an (optional) explicitly-booked CHAIN0 carrying `_chain0`, and a
   *         `totalPoint` carrying the booked total `_booked`. Independent of the contract's own
   *         formula (propagation check): the contract reads its computed state into points and the
   *         dispatch payload, and this recomputes the same values by hand.
   * @dev `slope = amount / _MAXTIME`, `bias = slope * (stakeEnd - tAct)`, `perm = 0` for a
   *      non-permanent stake. `chainRate` uses `mulDiv(chainBias, _MINTER_RATE * PRECISION,
   *      totalBias)`. There is no auto-CHAIN0 remainder in the additive model; `_booked` is the
   *      in-system total that lands in `totalWeight`, NOT the live stake.
   * @param _allocated Booked amount on chain X.
   * @param _chain0 Booked amount on CHAIN0 (`0` when no CHAIN0 position exists).
   * @param _booked In-system booked total driving `totalPoint` (`Σ allocationChainAmounts`).
   * @param _tAct Activation timestamp.
   * @param _stakeEnd Stake expiry (must be strictly greater than `_tAct`).
   * @return _expected Bundled bias/slope/chainRate for chain X, CHAIN0, and totalPoint.
   */
  function _computeExpected(
    uint128 _allocated,
    uint128 _chain0,
    uint128 _booked,
    uint48 _tAct,
    uint48 _stakeEnd
  ) internal pure returns (ExpectedContribution memory _expected) {
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    _expected.slopeX = int128(uint128(_allocated / _MAXTIME));
    _expected.slope0 = int128(uint128(_chain0 / _MAXTIME));
    _expected.slopeT = int128(uint128(_booked / _MAXTIME));
    _expected.biasX = _expected.slopeX * _delta;
    _expected.bias0 = _expected.slope0 * _delta;
    _expected.biasT = _expected.slopeT * _delta;
    // `PRECISION`-scaled to mirror `Voter._recomputeChainRate` (`chainWeight * emissionRate * PRECISION / totalWeight`).
    _expected.chainRateX = Math.mulDiv(uint128(_expected.biasX), _MINTER_RATE * _PRECISION, uint128(_expected.biasT));
    _expected.chainRate0 = Math.mulDiv(uint128(_expected.bias0), _MINTER_RATE * _PRECISION, uint128(_expected.biasT));
    // Global emissions per unit voting power dispatched to every leaf: `minterRate * PRECISION /
    // totalWeight`. For a non-permanent stake the resolved totalPoint weight is `biasT`.
    _expected.emissionsPerVP = Math.mulDiv(_MINTER_RATE, _PRECISION, uint128(_expected.biasT));
  }

  /**
   * @notice Build a one-chain `ChainAllocationDispatch[]` with a single entry and `value: 0`.
   * @dev Covers the most common `allocateChains` test shape (single leaf chain). The merged
   *      `ChainAllocationDispatch` bundles the chain amount with its dispatch gas budget; `allocateChains`
   *      carries no gauges (gauge distribution is a separate `allocateGauges` concern). Call sites
   *      that need a non-zero per-chain `value` build the entry inline.
   * @param _chainId Target chain id.
   * @param _amount Allocation amount on the chain entry.
   * @param _gasLimit Destination gas budget for the chain entry.
   * @return _allocations Array of length 1 with the constructed entry.
   */
  function _singleChainAllocation(
    uint256 _chainId,
    uint128 _amount,
    uint256 _gasLimit
  ) internal pure returns (IVoter.ChainAllocationDispatch[] memory _allocations) {
    _allocations = new IVoter.ChainAllocationDispatch[](1);
    _allocations[0] = IVoter.ChainAllocationDispatch({chainId: _chainId, delta: _amount, gasLimit: _gasLimit, value: 0});
  }

  /**
   * @notice Build a one-gauge `GaugeAllocation[]` with an empty calldata payload.
   * @dev Covers the common single-gauge `allocateGauges` test shape. Multi-gauge and
   *      non-empty calldata variants stay inline at their call sites.
   * @param _gauge Gauge address on the target chain.
   * @param _amount Allocation amount on the gauge entry.
   * @return _gauges Array of length 1 with the constructed entry.
   */
  function _singleGaugeAllocation(
    address _gauge,
    uint128 _amount
  ) internal pure returns (IVoterCommon.GaugeAllocation[] memory _gauges) {
    _gauges = new IVoterCommon.GaugeAllocation[](1);
    _gauges[0] = IVoterCommon.GaugeAllocation({gauge: _gauge, allocated: _amount, data: bytes('')});
  }

  /**
   * @notice Set up `vm.expectCall` + `vm.mockCall` for an `ORCHESTRATOR.dispatch`
   *         carrying an `AllocateChain` payload. Tests build the `_dispatches` array (1 entry per
   *         leaf chain in scope) and pass it in.
   * @param _dispatches Expected dispatch entries, in the order the contract sends them.
   */
  function _expectAllocateChainDispatch(IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) internal {
    vm.expectCall(
      _ORCHESTRATOR,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.AllocateChain, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Shortcut for the common single-leaf-chain `AllocateChain` dispatch shape (`value = 0`).
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _message The `AllocateChainMessage` body the orchestrator will receive on that chain.
   */
  function _expectSingleChainDispatch(
    uint256 _chainId,
    uint256 _gasLimit,
    IVoterCommon.AllocateChainMessage memory _message
  ) internal {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: 0,
      chargeDeallocationReturn: false,
      payload: abi.encode(_message)
    });
    _expectAllocateChainDispatch(_dispatches);
  }

  /**
   * @notice Set up `vm.expectCall` + `vm.mockCall` for the single-chain `ORCHESTRATOR.dispatch`
   *         carrying an `AllocateGauge` payload.
   * @dev `allocateGauges` always dispatches exactly one chain via the single-chain path with
   *      `nativeValue == msg.value`. Callers assert `value = 0` here; non-zero fee
   *      variants build the expectation inline.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _message The `AllocateGaugeMessage` body the orchestrator will receive on that chain.
   */
  function _expectAllocateGaugeDispatch(
    uint256 _chainId,
    uint256 _gasLimit,
    IVoterCommon.AllocateGaugeMessage memory _message
  ) internal {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: 0,
      chargeDeallocationReturn: false,
      payload: abi.encode(_message)
    });
    vm.expectCall(
      _ORCHESTRATOR,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.AllocateGauge, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Set up `vm.expectCall` (with forwarded value) + `vm.mockCall` for the single-chain
   *         `ORCHESTRATOR.dispatch` carrying a `ReduceCooldown` payload.
   * @dev `reduceCooldown` forwards `msg.value` as the transport fee, so the expected dispatch entry
   *      carries `nativeValue == _value` and the outer call carries the same `_value`.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _value Forwarded native value (`msg.value`).
   * @param _message The `ReduceCooldownMessage` body the orchestrator will receive.
   */
  function _expectReduceCooldownDispatch(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _value,
    IVoterCommon.ReduceCooldownMessage memory _message
  ) internal {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _value,
      chargeDeallocationReturn: false,
      payload: abi.encode(_message)
    });
    vm.expectCall(
      _ORCHESTRATOR,
      _value,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ReduceCooldown, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Set up `vm.expectCall` (with forwarded value) + `vm.mockCall` for the single-chain
   *         `ORCHESTRATOR.dispatch` carrying an `EmergencyDeallocate` payload.
   * @dev `emergencyDeallocate` forwards the whole `msg.value` as the transport fee, so the expected
   *      dispatch entry carries `nativeValue == _value` and the outer call carries the same
   *      `_value`. Mirrors `_expectReduceCooldownDispatch`.
   * @param _chainId Destination chain id.
   * @param _gasLimit Destination gas budget.
   * @param _value Forwarded native value (`msg.value`).
   * @param _message The `EmergencyDeallocateMessage` body the orchestrator will receive.
   */
  function _expectEmergencyDeallocateDispatch(
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _value,
    IVoterCommon.EmergencyDeallocateMessage memory _message
  ) internal {
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _value,
      chargeDeallocationReturn: false,
      payload: abi.encode(_message)
    });
    vm.expectCall(
      _ORCHESTRATOR,
      _value,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.EmergencyDeallocate, _dispatches, _REFUND_RECIPIENT)
      )
    );
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  function setUp() external {
    vm.warp(_INITIAL_TIMESTAMP);
    // Etched so the token mock carries bytecode like a real ERC20 would.
    vm.etch(_TOKEN, hex'69');
    _voter = new Voter({
      _orchestrator: _ORCHESTRATOR,
      _votingEscrow: _VOTING_ESCROW,
      _minter: _MINTER,
      _token: _TOKEN,
      _adapterAuthority: _ADAPTER_AUTHORITY,
      _governor: _GOVERNOR,
      _configAdmin: _CONFIG_ADMIN,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });

    // Grant operational roles to dedicated test actors so config-setter tests can prank them
    // directly. Cascade flows through `_CONFIG_ADMIN`, mirroring the production rotation pattern.
    bytes32 _voterConfigRole = Roles.VOTER_CONFIG_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _voter.grantRole(_voterConfigRole, _VOTER_CONFIG);
    bytes32 _chainConfigRole = Roles.CHAIN_CONFIG_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _voter.grantRole(_chainConfigRole, _CHAIN_CONFIG);
    bytes32 _chainStatusRole = Roles.CHAIN_STATUS_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _voter.grantRole(_chainStatusRole, _CHAIN_STATUS);

    // Mock the Minter's canonical emission rate. Read by `_recomputeChainRate`.
    vm.mockCall(_MINTER, abi.encodeWithSelector(IMinter.emissionRate.selector), abi.encode(uint256(_MINTER_RATE)));
    // Mock the Minter's minimum mint. Read by `processRedeem` when the donated buffer covers the amount.
    vm.mockCall(_MINTER, abi.encodeCall(IMinter.MIN_MINT_AMOUNT, ()), abi.encode(_MIN_MINT_AMOUNT));

    // Register the chains tests vote against. Seeds `lastIndex = index` (0 at deploy),
    // `point.ts = _INITIAL_TIMESTAMP`, `status = Active`.
    // `block.chainid` is included so dispatch-scope tests covering the root chain succeed.
    // Tests that exercise unregistered-chain paths use a chainId outside this set.
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_CHAIN_ID_1);
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_CHAIN_ID_2);
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(_CHAIN_ID_3);
    vm.prank(_CHAIN_CONFIG);
    _voter.registerChain(block.chainid);
  }

  /**
   * @notice Pack and write `tokenStates[_tokenId]` in a single store.
   * @dev `tokenStates` is at `_SLOT_TOKEN_STATES`; the value slot is `keccak256(abi.encode(_tokenId, slot))`.
   *      Within the slot, `committed` sits at offset 0 (16 bytes), `lastStakeEnd` at offset 16 (6 bytes),
   *      and `lastAllocated` at offset 22 (6 bytes). Clobbers all three — callers that only need one should
   *      pass `0` for the others.
   * @param _tokenId Token whose state is being seeded.
   * @param _committed Value for `committed`.
   * @param _lastStakeEnd Value for `lastStakeEnd`.
   * @param _lastAllocated Value for `lastAllocated`.
   */
  function _mockTokenState(uint256 _tokenId, uint128 _committed, uint48 _lastStakeEnd, uint48 _lastAllocated) internal {
    // A live root shape is permanent exactly when its stake end is zero, so derive the flag for the common case.
    // Use the explicit overload to seed an inconsistent shape (e.g. a withdrawn `{committed>0, 0, false}`).
    _mockTokenState(_tokenId, _committed, _lastStakeEnd, _lastAllocated, _lastStakeEnd == 0);
  }

  function _mockTokenState(
    uint256 _tokenId,
    uint128 _committed,
    uint48 _lastStakeEnd,
    uint48 _lastAllocated,
    bool _isPermanent
  ) internal {
    vm.store(
      address(_voter),
      keccak256(abi.encode(_tokenId, _SLOT_TOKEN_STATES)),
      bytes32(
        (uint256(_isPermanent ? 1 : 0) << 224) | (uint256(_lastAllocated) << 176) | (uint256(_lastStakeEnd) << 128)
          | uint256(_committed)
      )
    );

    // Read back via the auto-generated getter and assert each field — packing bugs (shifts, widths,
    // field order) fail here at the mock call instead of producing a confusing downstream miss.
    IVoter.TokenState memory _stored = _tokenState(_voter, _tokenId);
    assertEq(_stored.committed, _committed);
    assertEq(_stored.lastStakeEnd, _lastStakeEnd);
    assertEq(_stored.lastAllocated, _lastAllocated);
    assertEq(_stored.isPermanent, _isPermanent);
  }

  function _tokenState(Voter _target, uint256 _tokenId) internal view returns (IVoter.TokenState memory _state) {
    (uint128 _committed, uint48 _lastStakeEnd, uint48 _lastAllocated, bool _isPermanent) = _target.tokenStates(_tokenId);
    _state = IVoter.TokenState({
      committed: _committed, lastStakeEnd: _lastStakeEnd, lastAllocated: _lastAllocated, isPermanent: _isPermanent
    });
  }

  function _chainState(Voter _target, uint256 _chainId) internal view returns (IVoter.ChainState memory _state) {
    (
      IVoter.Point memory _point,
      uint256 _ceiling,
      uint256 _totalRedeemed,
      uint256 _reportedSurplus,
      uint256 _cumulativeSuspendedSurplus,
      uint256 _surplusSpent,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      uint256 _donatedBuffer,
      IVoterCommon.ChainStatus _status
    ) = _target.chainStates(_chainId);
    _state = IVoter.ChainState({
      point: _point,
      ceiling: _ceiling,
      totalRedeemed: _totalRedeemed,
      reportedSurplus: _reportedSurplus,
      cumulativeSuspendedSurplus: _cumulativeSuspendedSurplus,
      surplusSpent: _surplusSpent,
      lastIndex: _lastIndex,
      lastTimeIndex: _lastTimeIndex,
      donatedBuffer: _donatedBuffer,
      status: _status
    });
  }

  /**
   * @notice Seed the global emissions accumulator `index`.
   * @dev Full `uint256` at `_SLOT_INDEX`. `PRECISION`-scaled (`∫ emissionsPerVP·dt`).
   * @param _value Value to write.
   */
  function _mockGlobalIndex(uint256 _value) internal {
    vm.store(address(_voter), bytes32(_SLOT_INDEX), bytes32(_value));
    assertEq(_voter.index(), _value);
  }

  /**
   * @notice Seed the global `emissionsPerVP` scalar.
   * @dev Full `uint256` at `_SLOT_EMISSIONS_PER_VP`. `PRECISION`-scaled
   *      (`minterRate * PRECISION / totalWeight`).
   * @param _value Value to write.
   */
  function _mockEmissionsPerVP(uint256 _value) internal {
    vm.store(address(_voter), bytes32(_SLOT_EMISSIONS_PER_VP), bytes32(_value));
    assertEq(_voter.emissionsPerVP(), _value);
  }

  /**
   * @notice Seed `lastGlobalSettlement` — the timestamp the global `index` was last advanced to.
   * @dev `uint48` alone in `_SLOT_LAST_GLOBAL_SETTLEMENT`, so a plain store is safe.
   * @param _value Value to write.
   */
  function _mockLastGlobalSettlement(uint48 _value) internal {
    vm.store(address(_voter), bytes32(_SLOT_LAST_GLOBAL_SETTLEMENT), bytes32(uint256(_value)));
    assertEq(_voter.lastGlobalSettlement(), _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].status`.
   * @dev Packed slot at offset 10 of the per-chain struct; `status` is the only field there (`lastIndex`,
   *      `lastTimeIndex` and `donatedBuffer` occupy offsets 7 to 9 on their own), so it sits at bit 0, 1 byte wide.
   * @param _chainId Chain whose status is being seeded.
   * @param _status Status to write.
   */
  function _mockChainStatus(uint256 _chainId, IVoterCommon.ChainStatus _status) internal {
    _writePackedChainField(_chainId, 0, 8, uint256(uint8(_status)));
    assertEq(uint8(_chainState(_voter, _chainId).status), uint8(_status));
  }

  /**
   * @notice Seed `_allocationChainIds[_tokenId]` to contain `_chainIds` in order.
   * @dev `_allocationChainIds` is at `_SLOT_ALLOCATION_CHAIN_IDS` holding `EnumerableSet.UintSet` (OZ v5), which
   *      wraps `Set { bytes32[] _values; mapping(bytes32 => uint256) _positions; }`. Layout at base
   *      slot `S = keccak256(abi.encode(_tokenId, _SLOT_ALLOCATION_CHAIN_IDS))`:
   *        - `S + 0`: array length
   *        - `S + 1`: positions mapping base
   *        - value at index `i`: `keccak256(S) + i`
   *        - position of value `v`: `keccak256(abi.encode(bytes32(v), S + 1))`, 1-indexed
   *      The values array is covered by the fixture regression test. The positions mapping has no public exposure,
   *      so downstream `vote` / `burn` / `rebalanceChain0` tests exercise `contains` / `remove` and surface any
   *      layout drift organically.
   * @param _tokenId Token whose chain set is being seeded.
   * @param _chainIds Chain ids to add. Caller chooses ordering; positions are assigned in array order.
   */
  function _mockExistingChainIds(uint256 _tokenId, uint256[] memory _chainIds) internal {
    bytes32 _base = keccak256(abi.encode(_tokenId, _SLOT_ALLOCATION_CHAIN_IDS));
    uint256 _len = _chainIds.length;

    vm.store(address(_voter), _base, bytes32(_len));

    bytes32 _arrayBase = keccak256(abi.encode(_base));
    bytes32 _positionsBase = bytes32(uint256(_base) + 1);
    for (uint256 _i; _i < _len; ++_i) {
      bytes32 _valueSlot = bytes32(uint256(_arrayBase) + _i);
      vm.store(address(_voter), _valueSlot, bytes32(_chainIds[_i]));

      bytes32 _positionSlot = keccak256(abi.encode(bytes32(_chainIds[_i]), _positionsBase));
      vm.store(address(_voter), _positionSlot, bytes32(_i + 1));
    }

    // Read back via the public getter and assert every entry — EnumerableSet layout has three
    // co-dependent slots (length, value-at-index, position-of-value); any drift fails here.
    uint256[] memory _stored = _voter.allocationChainIds(_tokenId);
    assertEq(_stored.length, _len);
    for (uint256 _i; _i < _len; ++_i) {
      assertEq(_stored[_i], _chainIds[_i]);
    }
  }

  /**
   * @notice Seed `allocationChainAmounts[_tokenId][_chainId]`.
   * @dev `allocationChainAmounts` is at `_SLOT_ALLOCATION_CHAIN_AMOUNTS`; inner value slot is
   *      `keccak256(abi.encode(_chainId, keccak256(abi.encode(_tokenId, _SLOT_ALLOCATION_CHAIN_AMOUNTS))))`.
   *      `uint128` at offset 0.
   * @param _tokenId Token whose per-chain allocation is being seeded.
   * @param _chainId Chain key.
   * @param _amount Value to write.
   */
  function _mockAllocationChainAmount(uint256 _tokenId, uint256 _chainId, uint128 _amount) internal {
    bytes32 _outer = keccak256(abi.encode(_tokenId, _SLOT_ALLOCATION_CHAIN_AMOUNTS));
    bytes32 _slot = keccak256(abi.encode(_chainId, _outer));
    vm.store(address(_voter), _slot, bytes32(uint256(_amount)));
    assertEq(_voter.allocationChainAmounts(_tokenId, _chainId), _amount);
  }

  /**
   * @notice Seed `emergencyDeallocationAllowed[_chainId]`.
   * @dev `emergencyDeallocationAllowed` is at `_SLOT_EMERGENCY_DEALLOCATION_ALLOWED`; the value slot is
   *      `keccak256(abi.encode(_chainId, _SLOT_EMERGENCY_DEALLOCATION_ALLOWED))`. Stored as a full-word
   *      boolean (`1` == true).
   * @param _chainId Chain whose emergency-deallocation switch is being seeded.
   * @param _allowed Value to write.
   */
  function _mockEmergencyDeallocationAllowed(uint256 _chainId, bool _allowed) internal {
    vm.store(
      address(_voter),
      keccak256(abi.encode(_chainId, _SLOT_EMERGENCY_DEALLOCATION_ALLOWED)),
      bytes32(uint256(_allowed ? 1 : 0))
    );
    assertEq(_voter.emergencyDeallocationAllowed(_chainId), _allowed);
  }

  /**
   * @notice Mock `VOTING_ESCROW.isAuthorizedVPM(_vpm)` to return `_authorized`.
   * @param _vpm Candidate VPM address.
   * @param _authorized Return value.
   */
  function _mockAuthorizedVPM(address _vpm, bool _authorized) internal {
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_vpm)), abi.encode(_authorized));
  }

  /**
   * @notice Seed `chainStates[_chainId].ceiling`.
   * @dev `chainStates` is at `_SLOT_CHAIN_STATES`; `ceiling` is at offset 2 within the per-chain struct.
   * @param _chainId Chain whose ceiling is being seeded.
   * @param _value Value to write.
   */
  function _mockChainCeiling(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 2);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).ceiling, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].totalRedeemed`.
   * @dev `totalRedeemed` is at offset 3 within the per-chain struct.
   * @param _chainId Chain whose redeemed accumulator is being seeded.
   * @param _value Value to write.
   */
  function _mockTotalRedeemed(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 3);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).totalRedeemed, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].reportedSurplus`.
   * @dev `reportedSurplus` is at offset 4 within the per-chain struct.
   * @param _chainId Chain whose surplus accumulator is being seeded.
   * @param _value Value to write.
   */
  function _mockSurplusAlreadyReported(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 4);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).reportedSurplus, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].cumulativeSuspendedSurplus`.
   * @dev `cumulativeSuspendedSurplus` is at offset 5 within the per-chain struct. Full `uint256`.
   * @param _chainId Chain whose suspended surplus is being seeded.
   * @param _value Value to write.
   */
  function _mockCumulativeSuspendedSurplus(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 5);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).cumulativeSuspendedSurplus, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].surplusSpent`.
   * @dev `surplusSpent` is at offset 6 within the per-chain struct. Full `uint256`.
   * @param _chainId Chain whose spent surplus is being seeded.
   * @param _value Value to write.
   */
  function _mockSurplusSpent(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 6);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).surplusSpent, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].donatedBuffer`.
   * @dev `donatedBuffer` is at offset 9 within the per-chain struct.
   * @param _chainId Chain whose donated buffer is being seeded.
   * @param _value Value to write.
   */
  function _mockDonatedBuffer(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 9);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_voter.donatedBuffer(_chainId), _value);
  }

  /**
   * @notice Seed `chainSlopeChanges[_chainId][_expiry]`.
   * @dev `chainSlopeChanges` is at `_SLOT_CHAIN_SLOPE_CHANGES`, nested mapping. Outer slot:
   *      `keccak256(abi.encode(_chainId, _SLOT_CHAIN_SLOPE_CHANGES))`. Inner slot:
   *      `keccak256(abi.encode(_expiry, outer))`.
   * @param _chainId Chain whose slope schedule is being seeded.
   * @param _expiry Boundary timestamp the reduction is keyed by.
   * @param _value Signed slope-reduction value.
   */
  function _mockChainSlopeChange(uint256 _chainId, uint48 _expiry, int128 _value) internal {
    bytes32 _outer = keccak256(abi.encode(_chainId, _SLOT_CHAIN_SLOPE_CHANGES));
    bytes32 _slot = keccak256(abi.encode(uint256(_expiry), _outer));
    vm.store(address(_voter), _slot, bytes32(uint256(uint128(_value))));
    assertEq(_voter.chainSlopeChanges(_chainId, _expiry), _value);
  }

  /**
   * @notice Seed `totalSlopeChanges[_expiry]`.
   * @dev `totalSlopeChanges` is at `_SLOT_TOTAL_SLOPE_CHANGES`, single-level mapping `(uint48 => int128)`.
   *      Value slot: `keccak256(abi.encode(_expiry, _SLOT_TOTAL_SLOPE_CHANGES))`.
   * @param _expiry Boundary timestamp the reduction is keyed by.
   * @param _value Signed slope-reduction value.
   */
  function _mockTotalSlopeChange(uint48 _expiry, int128 _value) internal {
    bytes32 _slot = keccak256(abi.encode(uint256(_expiry), _SLOT_TOTAL_SLOPE_CHANGES));
    vm.store(address(_voter), _slot, bytes32(uint256(uint128(_value))));
    assertEq(_voter.totalSlopeChanges(_expiry), _value);
  }

  /**
   * @notice Seed `chainPoints[_chainId]` in a two-slot store.
   * @dev `chainStates` is at `_SLOT_CHAIN_STATES`; the `Point` struct occupies two slots at base
   *      `B = keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))`:
   *        - `B + 0`: `bias` (offset 0, 16B) + `slope` (offset 16, 16B)
   *        - `B + 1`: `ts` (offset 0, 6B) + `permanentStakeBalance` (offset 6, 16B)
   *      `uint128(int128)` casts preserve the bit pattern; negative values round-trip.
   * @param _chainId Chain whose point is being seeded.
   * @param _bias Bias value.
   * @param _slope Slope value.
   * @param _ts Timestamp value.
   * @param _perm Permanent stake balance value.
   */
  function _mockChainPoint(uint256 _chainId, int128 _bias, int128 _slope, uint48 _ts, uint128 _perm) internal {
    // `chainStates` is at `_SLOT_CHAIN_STATES`; the per-chain struct base slot is `keccak256(abi.encode(_chainId, slot))`.
    // `point` is the first struct field, occupying offsets 0 and 1 (bias|slope, then ts|permanentStakeBalance).
    bytes32 _base = keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES));
    vm.store(address(_voter), _base, bytes32((uint256(uint128(_slope)) << 128) | uint256(uint128(_bias))));
    vm.store(address(_voter), bytes32(uint256(_base) + 1), bytes32((uint256(_perm) << 48) | uint256(_ts)));

    IVoter.Point memory _stored = _chainState(_voter, _chainId).point;
    assertEq(_stored.bias, _bias);
    assertEq(_stored.slope, _slope);
    assertEq(_stored.ts, _ts);
    assertEq(_stored.permanentStakeBalance, _perm);
  }

  /**
   * @notice Seed `totalPoint` in a two-slot store.
   * @dev `totalPoint` is at `_SLOT_TOTAL_POINT` (two slots, perm/ts in the second). Same packing as `chainStates.point`.
   * @param _bias Bias value.
   * @param _slope Slope value.
   * @param _ts Timestamp value.
   * @param _perm Permanent stake balance value.
   */
  function _mockTotalPoint(int128 _bias, int128 _slope, uint48 _ts, uint128 _perm) internal {
    vm.store(
      address(_voter), bytes32(_SLOT_TOTAL_POINT), bytes32((uint256(uint128(_slope)) << 128) | uint256(uint128(_bias)))
    );
    vm.store(address(_voter), bytes32(_SLOT_TOTAL_POINT_PERM_TS), bytes32((uint256(_perm) << 48) | uint256(_ts)));

    _assertTotalPoint(_voter, _bias, _slope, _ts, _perm);
  }

  /**
   * @notice Assert every field of `_target.totalPoint()` against an expected `Point`.
   * @dev `_target` is explicit so this composes with constructor tests that deploy a fresh `Voter`
   *      separate from the `setUp`-deployed `_voter`.
   * @param _target Voter instance to read from.
   * @param _bias Expected bias.
   * @param _slope Expected slope.
   * @param _ts Expected timestamp.
   * @param _perm Expected permanent stake balance.
   */
  function _assertTotalPoint(Voter _target, int128 _bias, int128 _slope, uint48 _ts, uint128 _perm) internal view {
    (int128 _aBias, int128 _aSlope, uint48 _aTs, uint128 _aPerm) = _target.totalPoint();
    assertEq(_aBias, _bias);
    assertEq(_aSlope, _slope);
    assertEq(_aTs, _ts);
    assertEq(_aPerm, _perm);
  }

  /**
   * @notice Assert every field of `_chainState(_target, _chainId).point` against an expected `Point`.
   * @param _target Voter instance to read from.
   * @param _chainId Chain identifier.
   * @param _bias Expected bias.
   * @param _slope Expected slope.
   * @param _ts Expected timestamp.
   * @param _perm Expected permanent stake balance.
   */
  function _assertChainPoint(
    Voter _target,
    uint256 _chainId,
    int128 _bias,
    int128 _slope,
    uint48 _ts,
    uint128 _perm
  ) internal view {
    IVoter.Point memory _point = _chainState(_target, _chainId).point;
    assertEq(_point.bias, _bias);
    assertEq(_point.slope, _slope);
    assertEq(_point.ts, _ts);
    assertEq(_point.permanentStakeBalance, _perm);
  }

  /**
   * @notice Compute a Voter slope from a token amount. Mirrors the production formula
   *         `amount / MAXTIME` and casts to `int128` for use in bias/slope arithmetic.
   */
  function _slopeOf(uint128 _amount) internal pure returns (int128) {
    return int128(uint128(_amount / _MAXTIME));
  }

  /**
   * @notice Standard vote-test setup: bound `_ts` to a safe range, derive `_tAct`, bound
   *         `_stakeEnd` to `(_tAct, _tAct + _MAXTIME]`, and `vm.warp` to the bounded `_ts`.
   * @dev The upper bound on `_ts` reserves `_WEEK + _MAXTIME` headroom under `uint48.max` to
   *      keep `_walkPoint`'s trailing `_nextExpiry += _WEEK` from overflowing past `stakeEnd`.
   *      Root anchors `T_act` at `block.timestamp`, so `_tAct == _ts`.
   *
   *      Anchors the global settle cursor at `_ts` as well. These scenarios seed every point at
   *      `_tAct` and assert no pending accrual, and the global settle walks one week boundary at a
   *      time; leaving the cursor at the deploy timestamp would make it walk the whole fuzzed gap
   *      for no observable effect. Tests that DO want pending accrual re-seed the cursor behind
   *      `_ts` themselves.
   * @return _ts Bounded current timestamp.
   * @return _tAct Action timestamp (`block.timestamp`, i.e. `_ts`).
   * @return _stakeEnd Bounded stake-end in the future.
   */
  function _setupFutureVote(
    uint48 _tsIn,
    uint48 _stakeEndIn
  ) internal returns (uint48 _ts, uint48 _tAct, uint48 _stakeEnd) {
    _ts = uint48(bound(_tsIn, _INITIAL_TIMESTAMP, type(uint48).max - _WEEK - _MAXTIME));
    _tAct = _ts;
    _stakeEnd = uint48(bound(_stakeEndIn, _tAct + 1, _tAct + _MAXTIME));
    vm.warp(_ts);
    _mockLastGlobalSettlement(_ts);
  }

  /**
   * @notice Seed a canonical additive single-leaf-chain prior: the token has booked exactly
   *         `_chainAlloc` on `_chainId` and nothing else.
   * @dev Additive & partial: only `_chainId` is in the allocation set (no CHAIN0 auto-remainder),
   *      `committed == _chainAlloc` (the in-system booked total), and `totalPoint` carries only the
   *      booked contribution. Virgin VP (`veStaked - committed`) is NOT booked and does not appear in
   *      `totalWeight`. Chain point + total point are resolved at `_tAct`, and the chain's ceiling
   *      cursor is anchored at the current global `index` so no accrual is pending.
   *      Root no longer enforces cooldown, so `lastAllocated` is anchored at `_ts`.
   * @param _tokenId Voter token id.
   * @param _chainId Single leaf chain the token has booked on.
   * @param _chainAlloc AERO booked on `_chainId` (equals `committed`).
   * @param _stakeEnd Non-permanent stake expiry.
   * @param _tAct Activation timestamp the points and settlements are anchored at.
   * @param _ts Block timestamp recorded as `lastAllocated`.
   */
  function _seedSingleChainPriorVote(
    uint256 _tokenId,
    uint256 _chainId,
    uint128 _chainAlloc,
    uint48 _stakeEnd,
    uint48 _tAct,
    uint48 _ts
  ) internal {
    _mockExistingChainIds({_tokenId: _tokenId, _chainIds: _singletonArray(_chainId)});

    int128 _slopeX = _slopeOf(_chainAlloc);
    int128 _delta = int128(uint128(_stakeEnd - _tAct));

    _mockChainPoint({_chainId: _chainId, _bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _slopeX * _delta, _slope: _slopeX, _ts: _tAct, _perm: 0});

    _mockAllocationChainAmount({_tokenId: _tokenId, _chainId: _chainId, _amount: _chainAlloc});

    _mockTokenState({_tokenId: _tokenId, _committed: _chainAlloc, _lastStakeEnd: _stakeEnd, _lastAllocated: _ts});
    _mockChainLastIndex({_chainId: _chainId, _value: _voter.index()});
  }

  /**
   * @notice Assert every field of `_target.tokenStates(_tokenId)` against an expected triple.
   * @param _target Voter instance to read from.
   * @param _tokenId Token identifier.
   * @param _committed Expected committed amount.
   * @param _lastStakeEnd Expected last stake end.
   * @param _lastAllocated Expected last vote timestamp.
   */
  function _assertTokenState(
    Voter _target,
    uint256 _tokenId,
    uint128 _committed,
    uint48 _lastStakeEnd,
    uint48 _lastAllocated
  ) internal view {
    IVoter.TokenState memory _state = _tokenState(_target, _tokenId);
    assertEq(_state.committed, _committed);
    assertEq(_state.lastStakeEnd, _lastStakeEnd);
    assertEq(_state.lastAllocated, _lastAllocated);
  }

  /**
   * @notice Seed `chainStates[_chainId].lastIndex` (the chain's ceiling cursor into the global index).
   * @dev A full `uint256` at offset 7 of the per-chain struct (its own slot). `PRECISION`-scaled in
   *      production; this helper writes the raw stored value.
   * @param _chainId Chain whose cursor is being seeded.
   * @param _value Index value to write (`PRECISION`-scaled).
   */
  function _mockChainLastIndex(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 7);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).lastIndex, _value);
  }

  /**
   * @notice Seed `chainStates[_chainId].lastTimeIndex` (the chain's cursor into the global `timeIndex`).
   * @dev A full `uint256` at offset 8 of the per-chain struct (its own slot).
   * @param _chainId Chain whose cursor is being seeded.
   * @param _value Time-weighted index value to write.
   */
  function _mockChainLastTimeIndex(uint256 _chainId, uint256 _value) internal {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 8);
    vm.store(address(_voter), _slot, bytes32(_value));
    assertEq(_chainState(_voter, _chainId).lastTimeIndex, _value);
  }

  /**
   * @notice Seed the global time-weighted emissions accumulator `timeIndex`.
   * @dev Full `uint256` at `_SLOT_TIME_INDEX` (doubled, `PRECISION`-scaled).
   * @param _value Accumulator value to write.
   */
  function _mockGlobalTimeIndex(uint256 _value) internal {
    vm.store(address(_voter), bytes32(_SLOT_TIME_INDEX), bytes32(_value));
    assertEq(_voter.timeIndex(), _value);
  }

  /**
   * @notice RMW a sub-field of the per-chain packed slot (offset 10 of `chainStates[id]`) so
   *         sibling fields stay intact. That slot holds only `status` [0..8) now that `lastIndex`,
   *         `lastTimeIndex` and `donatedBuffer` occupy offsets 7 to 9 on their own.
   * @param _chainId Chain whose packed slot is being updated.
   * @param _bitOffset Starting bit offset within the 256-bit slot.
   * @param _bitWidth Width of the field in bits.
   * @param _value Value to write (must fit in `_bitWidth` bits).
   */
  function _writePackedChainField(uint256 _chainId, uint256 _bitOffset, uint256 _bitWidth, uint256 _value) private {
    bytes32 _slot = bytes32(uint256(keccak256(abi.encode(_chainId, _SLOT_CHAIN_STATES))) + 10);
    uint256 _mask = ((uint256(1) << _bitWidth) - 1) << _bitOffset;
    uint256 _current = uint256(vm.load(address(_voter), _slot));
    uint256 _next = (_current & ~_mask) | ((_value << _bitOffset) & _mask);
    vm.store(address(_voter), _slot, bytes32(_next));
  }

  /**
   * @notice Seed the canonical "single voter, single chain, prior vote at _INITIAL_TIMESTAMP"
   *         pre-state used by walk/rate/contribution-math tests. Chain and total points are
   *         seeded with independent values (bias, slope, perm, ts) so a slot-routing bug shows
   *         up as a mismatched assertion. `_chainPointTs <= _totalPointTs` is the realistic
   *         order since totalPoint is touched on every vote while chainPoints[chainId] is only
   *         touched when in scope, so the chain can lag behind. Each chain's ceiling cursor
   *         (`lastIndex`) is anchored at the current global `index` so nothing is pending. Also mocks
   *         the dispatch since math-isolation tests don't assert on the payload. Callers that want
   *         pending accrual (e.g. to test ceiling growth across weeks) seed
   *         `_mockEmissionsPerVP` + `_mockLastGlobalSettlement` after the seed.
   * @dev `_isPermanent == true` forces both VE.stakeEnd and tokenStates.lastStakeEnd to 0
   *      regardless of `_stakeEnd`. Root no longer enforces cooldown, so callers only need
   *      `_ts >= _INITIAL_TIMESTAMP` to keep the seeded points resolvable forward.
   * @param _chainBias Pre-walk bias for chainPoints[_CHAIN_ID_1].
   * @param _chainSlope Pre-walk slope for chainPoints[_CHAIN_ID_1].
   * @param _chainPerm Pre-walk permanent balance for chainPoints[_CHAIN_ID_1].
   * @param _chainPointTs Pre-walk timestamp on chainPoints[_CHAIN_ID_1].
   * @param _totalBias Pre-walk bias for totalPoint.
   * @param _totalSlope Pre-walk slope for totalPoint.
   * @param _totalPerm Pre-walk permanent balance for totalPoint.
   * @param _totalPointTs Pre-walk timestamp on totalPoint. Should satisfy `>= _chainPointTs`.
   * @param _stakeEnd Stake expiry. Ignored when `_isPermanent` is true.
   * @param _isPermanent VE permanent flag.
   */
  function _seedSingleVoterPrior(
    int128 _chainBias,
    int128 _chainSlope,
    uint128 _chainPerm,
    uint48 _chainPointTs,
    int128 _totalBias,
    int128 _totalSlope,
    uint128 _totalPerm,
    uint48 _totalPointTs,
    uint48 _stakeEnd,
    bool _isPermanent
  ) internal {
    uint48 _effectiveStakeEnd = _isPermanent ? uint48(0) : _stakeEnd;

    _mockChainPoint({
      _chainId: _CHAIN_ID_1, _bias: _chainBias, _slope: _chainSlope, _ts: _chainPointTs, _perm: _chainPerm
    });
    // Include the 1-wei CHAIN0 park (seeded below) in the total so `Σ chains == totalPoint` stays exact:
    // +1 perm for a permanent stake, +0 for non-permanent (1 wei floors to zero decaying weight).
    _mockTotalPoint({
      _bias: _totalBias, _slope: _totalSlope, _ts: _totalPointTs, _perm: _totalPerm + (_isPermanent ? 1 : 0)
    });
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);
    _mockTokenState({
      _tokenId: _TOKEN_ID, _committed: _ONE_AERO, _lastStakeEnd: _effectiveStakeEnd, _lastAllocated: _INITIAL_TIMESTAMP
    });
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _ONE_AERO);
    // Seed a 1-wei CHAIN0-parked source so the walk/rate tests' 1-wei delta can draw from CHAIN0 (chain
    // allocations now draw only from CHAIN0-parked VP). For a non-permanent stake 1 wei carries zero
    // weight, so the draw is a total-point no-op; for a permanent stake it carries weight 1 and the draw
    // nets neutral (the delta's +1 on `_CHAIN_ID_1` cancels the -1 removed from CHAIN0).
    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _chainPointTs, _perm: _isPermanent ? 1 : 0});
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, 1);
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _prior);
    // Live stake reports `_ONE_AERO` committed; the 1-wei CHAIN0 park funds the walk/rate tests' tiny
    // re-vote delta, leaving every seeded point/rate exactly as mocked.
    _mockStaked({_amount: _ONE_AERO + _MAXTIME, _end: _effectiveStakeEnd, _isPermanent: _isPermanent});

    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), bytes(''));
  }

  /**
   * @notice Seed a prior `{origin, CHAIN0}` allocation for `_TOKEN_ID` anchored at `_tAct`.
   * @dev Points sit at `_tAct` and each ceiling cursor at the current global `index`, so
   *      `_settleCeiling`/`_resolveWeight` early-exit and no decay enters the move. Non-permanent stake: `bias = slope * (stakeEnd - tAct)`,
   *      `perm = 0`. TotalPoint carries the full committed contribution.
   * @param _tAct Activation timestamp all points are anchored at.
   * @param _stakeEnd Non-permanent stake expiry (`> _tAct`).
   * @param _originAlloc Origin-chain allocation.
   * @param _chain0Alloc CHAIN0 allocation.
   * @param _committed Token committed weight (drives totalPoint).
   */
  function _seedTwoChainPrior(
    uint48 _tAct,
    uint48 _stakeEnd,
    uint128 _originAlloc,
    uint128 _chain0Alloc,
    uint128 _committed
  ) internal {
    int128 _delta = int128(uint128(_stakeEnd - _tAct));
    int128 _originSlope = _slopeOf(_originAlloc);
    int128 _chain0Slope = _slopeOf(_chain0Alloc);
    // totalPoint is the SUM of the per-chain contributions (each with its own floored slope), NOT
    // `slopeOf(committed)`. The additive credit path mirrors each per-chain swap onto the total, so
    // seeding it as the per-chain sum keeps the intra-token move dust-free (total conserved exactly).
    _committed; // committed drives token state below, not the total slope
    int128 _totalSlope = _originSlope + _chain0Slope;

    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: _originSlope * _delta, _slope: _originSlope, _ts: _tAct, _perm: 0});
    _mockChainPoint({_chainId: _CHAIN0, _bias: _chain0Slope * _delta, _slope: _chain0Slope, _ts: _tAct, _perm: 0});
    _mockTotalPoint({_bias: _totalSlope * _delta, _slope: _totalSlope, _ts: _tAct, _perm: 0});

    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Active);

    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN_ID_1, _originAlloc);
    _mockAllocationChainAmount(_TOKEN_ID, _CHAIN0, _chain0Alloc);
    uint256[] memory _prior = new uint256[](2);
    _prior[0] = _CHAIN0;
    _prior[1] = _CHAIN_ID_1;
    _mockExistingChainIds(_TOKEN_ID, _prior);

    _mockTokenState({_tokenId: _TOKEN_ID, _committed: _committed, _lastStakeEnd: _stakeEnd, _lastAllocated: _tAct});
  }
}
