// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {LeafVoterHarness} from 'V3-test/unit/voter/LeafVoterHarness.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {DEALLOC_GAUGE} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {ILeafVoter, LeafVoter} from 'V3/voter/LeafVoter.sol';

abstract contract BaseLeafVoter is TestHelpers {
  /// @notice Mirrors `WEEK`; used to position fuzzed timestamps relative to boundaries.
  uint48 internal constant _WEEK = 1 weeks;
  /// @notice Mirrors `PRECISION`; used to recompute the expected index advance.
  uint256 internal constant _PRECISION = 1e18;
  uint48 internal constant _VOTE_COOLDOWN = 1 days;
  uint256 internal constant _MAX_GAUGES = 25;

  /// @notice Deploy timestamp, offset into a week so boundary math is exercised on both sides.
  ///         Becomes the initial `lastSettlement` the constructor anchors.
  uint48 internal constant _SEED_TIMESTAMP = 100 weeks + 3 days;

  // Storage slots from `forge inspect LeafVoter storage-layout`.
  // `AccessControlEnumerable` reserves slots 0 (`_roles`) and 1 (`_roleMembers`);
  // LeafVoter's own state starts at slot 2, the `emissionsPerVP` scalar.
  uint256 internal constant _EMISSIONS_PER_VP_SLOT = 2;
  uint256 internal constant _INDEX_SLOT = 3;
  uint256 internal constant _TIME_INDEX_SLOT = 4;

  // `lastSettlement` holds slot 5. The `indexAtBoundary`, `timeIndexAtBoundary`, `gaugeStates`, and
  // `gaugeSlopeChanges` mappings hold slots 6, 7, 8, and 9.
  uint256 internal constant _LAST_SETTLEMENT_SLOT = 5;
  uint256 internal constant _INDEX_AT_BOUNDARY_SLOT = 6;
  uint256 internal constant _TIME_INDEX_AT_BOUNDARY_SLOT = 7;
  uint256 internal constant _GAUGE_STATES_SLOT = 8;
  uint256 internal constant _GAUGE_SLOPE_CHANGES_SLOT = 9;
  // `tokenStates` holds slot 10. Per entry, the first slot packs operator (bits
  // 0..160), lastAllocated (bits 160..208), and canVoteForZeroCapGauges (bit 208);
  // chainAllocation (bits 0..128) lands in the next slot.
  uint256 internal constant _TOKEN_STATE_SLOT = 10;
  uint256 internal constant _TOKEN_SNAPSHOT_SLOT = 11;
  uint256 internal constant _ACCUMULATED_COOLDOWN_REDUCTION_SLOT = 12;
  uint256 internal constant _ALLOCATIONS_SLOT = 13;
  uint256 internal constant _VOTED_GAUGES_SLOT = 14;
  uint256 internal constant _SURPLUS_ACCRUED_SLOT = 15;
  // Slot 16 packs, in order, `chainStatus` (byte 0), `localVotingEnabled` (byte 1),
  // `allocationCooldown` (bytes 2..7) and `maxAccumulatedCooldownReduction` (bytes 8..13).
  uint256 internal constant _CHAIN_STATUS_SLOT = 16;
  /// @notice Bit offset of `localVotingEnabled` inside `_CHAIN_STATUS_SLOT`.
  uint256 internal constant _LOCAL_VOTING_ENABLED_BIT_OFFSET = 8;
  uint256 internal constant _MAX_GAUGES_SLOT = 17;
  uint256 internal constant _LATEST_TOKEN_SNAPSHOT_SLOT = 18;

  address internal immutable _LEAF_MESSAGE_ORCHESTRATOR = makeAddr('LeafMessageOrchestrator');
  address internal immutable _RECEIPT_TOKEN = makeAddr('ReceiptToken');
  address internal immutable _GAUGE_FACTORY = makeAddr('GaugeFactory');
  address internal immutable _GAUGE_MANAGER = makeAddr('GaugeManager');
  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _EMISSIONS_HANDLER = makeAddr('EmissionsHandler');
  address internal immutable _GOVERNOR = makeAddr('Governor');
  address internal immutable _CONFIG_ADMIN = makeAddr('ConfigAdmin');
  address internal immutable _VOTER_CONFIG = makeAddr('VoterConfig');
  address internal immutable _TOKEN_WHITELIST = makeAddr('TokenWhitelist');
  address internal immutable _CHAIN_STATUS = makeAddr('ChainStatus');
  address internal immutable _EMERGENCY_COUNCIL = makeAddr('EmergencyCouncil');
  address internal immutable _GAS_CONFIGURER = makeAddr('GasConfigurer');
  address internal immutable _NATIVE_WITHDRAWER = makeAddr('NativeWithdrawer');

  /// @notice Deployed as a harness so the contribution-math internals are reachable; substitutes for
  ///         LeafVoter everywhere since it adds only test wrappers and no state.
  LeafVoterHarness internal _leafVoter;
  /// @notice Sink the redirected weight parks on, mirrors `LeafVoter.ZERO_GAUGE`.
  address internal constant _ZERO_GAUGE = address(0);

  /// @dev The deallocation-queue sentinel, single-sourced from `ProtocolConstants`. Reserved like
  ///      `_ZERO_GAUGE`, so fuzzed gauge addresses must exclude it.
  address internal constant _DEALLOC_GAUGE = DEALLOC_GAUGE;

  /// @notice TokenId the cases vote with.
  uint256 internal constant _TOKEN_ID = 1;

  /// @notice Registered operator authorized to drive the local vote.
  address internal immutable _OPERATOR = makeAddr('operator');

  // Strictly ascending so multi-gauge allocations satisfy the calldata ordering
  // the allocation path enforces and `_inAllocations` relies on.
  address internal constant _GAUGE_A = address(0xAAA1);
  address internal constant _GAUGE_B = address(0xBBB2);

  /// @notice Gauge the rate and checkpoint forwards target. Etched with code by
  ///         the helpers so the high-level dispatch passes the extcodesize check.
  address internal immutable _GAUGE = makeAddr('Gauge');

  /// @notice Reward contract wired to a gauge so the checkpoint forward fires.
  address internal constant _REWARD_A = address(0xDEAD);

  /// @notice Upper bound on fuzzed allocations. Keeps two-gauge sums inside
  ///         `uint128` and the permanent cast inside `int128`.
  uint128 internal constant _MAX_AMOUNT = 1e30;

  /// @notice Floor for fuzzed gas caps on forward paths. The recording gauge or
  ///         reward needs enough budget to run and store the gas it observed.
  uint256 internal constant _MIN_GAS_LIMIT = 100_000;

  function setUp() external {
    vm.warp(_SEED_TIMESTAMP);
    _leafVoter = new LeafVoterHarness(
      _GOVERNOR,
      _CONFIG_ADMIN,
      _LEAF_MESSAGE_ORCHESTRATOR,
      _RECEIPT_TOKEN,
      _GAUGE_FACTORY,
      _GAUGE_MANAGER,
      _VOTE_COOLDOWN,
      _MAX_GAUGES,
      _ADAPTER_AUTHORITY,
      _EMISSIONS_HANDLER,
      _EMERGENCY_COUNCIL
    );

    // Default every rewards lookup to unset. Per-gauge mocks via _mockGaugeRewards
    // override this with their longer calldata match.
    vm.mockCall(
      _GAUGE_FACTORY, abi.encodeWithSelector(IFactoryRegistry.gaugeToRewards.selector), abi.encode(address(0))
    );

    // Grant operational roles to dedicated test actors so config-setter tests can prank them
    // directly. Cascade flows through `_CONFIG_ADMIN`, mirroring the production rotation pattern.
    bytes32 _voterConfigRole = Roles.VOTER_CONFIG_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _leafVoter.grantRole(_voterConfigRole, _VOTER_CONFIG);
    bytes32 _tokenWhitelistRole = Roles.TOKEN_WHITELIST_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _leafVoter.grantRole(_tokenWhitelistRole, _TOKEN_WHITELIST);
    bytes32 _chainStatusRole = Roles.CHAIN_STATUS_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _leafVoter.grantRole(_chainStatusRole, _CHAIN_STATUS);
    bytes32 _gasConfigurerRole = Roles.GAS_CONFIGURER_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _leafVoter.grantRole(_gasConfigurerRole, _GAS_CONFIGURER);
    bytes32 _nativeWithdrawerRole = Roles.NATIVE_WITHDRAWER_ROLE;
    vm.prank(_CONFIG_ADMIN);
    _leafVoter.grantRole(_nativeWithdrawerRole, _NATIVE_WITHDRAWER);
  }

  /**
   * @notice Overwrite the `localVotingEnabled` master switch directly in storage.
   * @dev The flag packs into `_CHAIN_STATUS_SLOT` at `_LOCAL_VOTING_ENABLED_BIT_OFFSET`, so only that
   *      byte is rewritten and the neighbouring `chainStatus`, `allocationCooldown` and
   *      `maxAccumulatedCooldownReduction` fields survive. Written straight to storage so the local
   *      allocation cases never call `setLocalVotingEnabled` to arrange state. Self-verifies against
   *      the getter.
   * @param _enabled Whether the local `allocateGauges` path is open.
   */
  function _mockLocalVotingEnabled(bool _enabled) internal {
    uint256 _slot = uint256(vm.load(address(_leafVoter), bytes32(_CHAIN_STATUS_SLOT)));
    uint256 _mask = uint256(0xff) << _LOCAL_VOTING_ENABLED_BIT_OFFSET;
    uint256 _updated = (_slot & ~_mask) | (uint256(_enabled ? 1 : 0) << _LOCAL_VOTING_ENABLED_BIT_OFFSET);
    vm.store(address(_leafVoter), bytes32(_CHAIN_STATUS_SLOT), bytes32(_updated));

    assertEq(_leafVoter.localVotingEnabled(), _enabled);
  }

  /**
   * @notice Overwrite `chainStatus` directly in storage.
   * @dev `chainStatus` packs into `_CHAIN_STATUS_SLOT` with `localVotingEnabled`,
   *      `allocationCooldown` and
   *      `maxAccumulatedCooldownReduction`, so only the low
   *      status byte is rewritten and the neighbor is preserved. Self-verifies
   *      against the getter.
   * @param _status Status to seed.
   */
  function _mockChainStatus(IVoterCommon.ChainStatus _status) internal {
    bytes32 _slot = vm.load(address(_leafVoter), bytes32(_CHAIN_STATUS_SLOT));
    bytes32 _updated = (_slot & ~bytes32(uint256(0xff))) | bytes32(uint256(uint8(_status)));
    vm.store(address(_leafVoter), bytes32(_CHAIN_STATUS_SLOT), _updated);

    assertEq(uint8(_leafVoter.chainStatus()), uint8(_status));
  }

  /**
   * @notice Seed the chain accumulator snapshot `_settleIndex` reads.
   * @dev Writes straight to storage so the tests never call the contract under
   *      test to arrange state. Self-verifies each write against its getter.
   * @param _emissionsPerVP Prior `emissionsPerVP` scalar.
   * @param _index Prior `index`.
   */
  function _mockChainAccumulator(uint256 _emissionsPerVP, uint256 _index) internal {
    vm.store(address(_leafVoter), bytes32(_EMISSIONS_PER_VP_SLOT), bytes32(_emissionsPerVP));
    vm.store(address(_leafVoter), bytes32(_INDEX_SLOT), bytes32(_index));

    assertEq(_leafVoter.emissionsPerVP(), _emissionsPerVP);
    assertEq(_leafVoter.index(), _index);
  }

  /**
   * @notice Seed the time-weighted chain accumulator `timeIndex` directly in storage.
   * @dev Twin of `_mockChainAccumulator`'s `index` write for the second accumulator the exact per-gauge
   *      walk prices a decaying share against. Written straight to storage so the tests never call the
   *      contract under test to arrange state. Self-verifies against the getter.
   * @param _timeIndex Prior `timeIndex` (doubled, time-weighted integral of `emissionsPerVP`).
   */
  function _mockChainTimeIndex(uint256 _timeIndex) internal {
    vm.store(address(_leafVoter), bytes32(_TIME_INDEX_SLOT), bytes32(_timeIndex));
    assertEq(_leafVoter.timeIndex(), _timeIndex);
  }

  /**
   * @notice Snap a timestamp up to the next `WEEK`-aligned boundary.
   * @dev Mirror of `LeafVoter._nextWeekBoundary`, used to assert which
   *      boundaries a settlement window should (not) snapshot.
   * @param _ts Timestamp to snap.
   * @return _boundary First `WEEK`-aligned boundary strictly after `_ts`.
   */
  function _nextWeekBoundary(uint48 _ts) internal view returns (uint48 _boundary) {
    _boundary = (_ts / _WEEK + 1) * _WEEK;
  }

  /**
   * @notice Overwrite the chain `lastSettlement` cursor directly in storage.
   * @dev Writes straight to storage so tests never call the contract under test
   *      to advance the cursor. Settle tests pair it with a matching `vm.warp`
   *      so `settleGauge`'s `_settleIndex` call no-ops and the gauge walk runs
   *      against the frozen index and boundary snapshots; contribution-math
   *      tests use it to advance the activation timestamp the helpers evaluate
   *      against. Self-verifies the write against the getter.
   * @param _ts Timestamp to anchor `lastSettlement` at.
   */
  function _mockChainSettlement(uint48 _ts) internal {
    vm.store(address(_leafVoter), bytes32(_LAST_SETTLEMENT_SLOT), bytes32(uint256(_ts)));
    assertEq(_leafVoter.lastSettlement(), _ts);
  }

  /**
   * @notice Seed an `indexAtBoundary` snapshot the per-gauge walk reads at a
   *         crossed weekly boundary.
   * @param _boundary Weekly-aligned boundary timestamp.
   * @param _index Index snapshot to record at `_boundary`.
   */
  function _mockIndexAtBoundary(uint48 _boundary, uint256 _index) internal {
    vm.store(address(_leafVoter), keccak256(abi.encode(_boundary, _INDEX_AT_BOUNDARY_SLOT)), bytes32(_index));
    assertEq(_leafVoter.indexAtBoundary(_boundary), _index);
  }

  /**
   * @notice Seed an `timeIndexAtBoundary` snapshot the per-gauge walk reads at a crossed weekly boundary.
   * @dev Twin of `_mockIndexAtBoundary` for the time-weighted accumulator. Seed it alongside the
   *      matching `indexAtBoundary` write so the two accumulators stay consistent and the walk's
   *      `timeIndex` delta never underflows.
   * @param _boundary Weekly-aligned boundary timestamp.
   * @param _timeIndex `timeIndex` snapshot to record at `_boundary`.
   */
  function _mockTimeIndexAtBoundary(uint48 _boundary, uint256 _timeIndex) internal {
    vm.store(address(_leafVoter), keccak256(abi.encode(_boundary, _TIME_INDEX_AT_BOUNDARY_SLOT)), bytes32(_timeIndex));
    assertEq(_leafVoter.timeIndexAtBoundary(_boundary), _timeIndex);
  }

  /**
   * @notice Write a full `GaugeState` for `_gauge` straight to storage.
   * @dev Packs the struct across its six slots so tests arrange settlement
   *      state without calling the contract under test. Self-verifies the
   *      packed slots through the `gaugeStates` getter.
   * @param _gauge Gauge whose state is being seeded.
   * @param _state State to write.
   */
  function _mockGaugeState(address _gauge, ILeafVoter.GaugeState memory _state) internal {
    bytes32 _base = keccak256(abi.encode(_gauge, _GAUGE_STATES_SLOT));

    // Slot 0: ceiling (low 128) | claimed (high 128).
    vm.store(address(_leafVoter), _base, bytes32(uint256(_state.ceiling) | (uint256(_state.claimed) << 128)));
    // Slot 1: lastSettlement (bits 0..47) | isRegistered (bit 48) | isActivated (bit 56) | surplus (bits 64..191).
    vm.store(
      address(_leafVoter),
      bytes32(uint256(_base) + 1),
      bytes32(
        uint256(_state.lastSettlement) | (uint256(_state.isRegistered ? 1 : 0) << 48)
          | (uint256(_state.isActivated ? 1 : 0) << 56) | (uint256(_state.surplus) << 64)
      )
    );
    // Slot 2: lastIndex.
    vm.store(address(_leafVoter), bytes32(uint256(_base) + 2), bytes32(_state.lastIndex));
    // Slot 3: lastTimeIndex.
    vm.store(address(_leafVoter), bytes32(uint256(_base) + 3), bytes32(_state.lastTimeIndex));
    // Slot 4: point.bias (low 128) | point.slope (high 128).
    vm.store(
      address(_leafVoter),
      bytes32(uint256(_base) + 4),
      bytes32(uint256(uint128(_state.point.bias)) | (uint256(uint128(_state.point.slope)) << 128))
    );
    // Slot 5: point.ts (bits 0..47) | point.permanentStakeBalance (bits 48..175).
    vm.store(
      address(_leafVoter),
      bytes32(uint256(_base) + 5),
      bytes32(uint256(_state.point.ts) | (uint256(_state.point.permanentStakeBalance) << 48))
    );

    (
      uint128 _ceiling,
      uint128 _claimed,
      uint48 _lastSettlement,
      bool _isRegistered,
      bool _isActivated,
      uint128 _surplus,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      IVoterCommon.Point memory _point
    ) = _leafVoter.gaugeStates(_gauge);
    assertEq(_ceiling, _state.ceiling);
    assertEq(_claimed, _state.claimed);
    assertEq(_lastSettlement, _state.lastSettlement);
    assertEq(_isRegistered, _state.isRegistered);
    assertEq(_isActivated, _state.isActivated);
    assertEq(_surplus, _state.surplus);
    assertEq(_lastIndex, _state.lastIndex);
    assertEq(_lastTimeIndex, _state.lastTimeIndex);
    assertEq(_point.bias, _state.point.bias);
    assertEq(_point.slope, _state.point.slope);
    assertEq(_point.ts, _state.point.ts);
    assertEq(_point.permanentStakeBalance, _state.point.permanentStakeBalance);
  }

  /**
   * @notice Read a gauge's full `GaugeState` into a single memory struct.
   * @dev Collapses the eight-field `gaugeStates` getter tuple into one value so callers assert
   *      against `_state.field` instead of a wide in-place destructuring, which keeps the
   *      heavier settle tests within the legacy-codegen stack limit.
   * @param _gauge Gauge to read.
   * @return _state The gauge's current state.
   */
  function _gaugeStateOf(address _gauge) internal view returns (ILeafVoter.GaugeState memory _state) {
    // Split across two reads so neither tuple destructure materializes all nine fields plus the `Point` at once,
    // which overruns the legacy-codegen stack.
    (
      _state.ceiling,
      _state.claimed,
      _state.lastSettlement,
      _state.isRegistered,
      _state.isActivated,
      _state.surplus,
      _state.lastIndex,
      _state.lastTimeIndex,
    ) = _leafVoter.gaugeStates(_gauge);
    (,,,,,,,, _state.point) = _leafVoter.gaugeStates(_gauge);
  }

  /**
   * @notice Seed a scheduled slope reduction for `_gauge` at `_expiry`.
   * @param _gauge Gauge whose slope schedule is being seeded.
   * @param _expiry Weekly-aligned expiry boundary.
   * @param _slopeDelta Slope reduction the walk consumes at `_expiry`.
   */
  function _mockGaugeSlopeChange(address _gauge, uint48 _expiry, int128 _slopeDelta) internal {
    bytes32 _inner = keccak256(abi.encode(_gauge, _GAUGE_SLOPE_CHANGES_SLOT));
    vm.store(address(_leafVoter), keccak256(abi.encode(_expiry, _inner)), bytes32(uint256(uint128(_slopeDelta))));
    assertEq(_leafVoter.gaugeSlopeChanges(_gauge, _expiry), _slopeDelta);
  }

  /**
   * @notice Mock the FactoryRegistry's per-gauge emission cap query.
   * @param _gauge Gauge the cap is queried for.
   * @param _cap Per-second cap to return. `type(uint128).max` leaves the walk
   *             effectively uncapped.
   */
  function _mockEmissionCap(address _gauge, uint128 _cap) internal {
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IFactoryRegistry.emissionCap, (_gauge)), abi.encode(_cap));
  }

  /**
   * @notice Mock the FactoryRegistry's per-gauge rewards contract query.
   * @param _gauge Gauge the rewards contract is queried for.
   * @param _rewards Rewards contract to return.
   */
  function _mockGaugeRewards(address _gauge, address _rewards) internal {
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IFactoryRegistry.gaugeToRewards, (_gauge)), abi.encode(_rewards));
  }

  /**
   * @notice Overwrite a token's stored AND pending stake snapshots directly in storage.
   * @dev `TokenSnapshot` packs staked into the low 16 bytes of the slot and stakeEnd into the next 6.
   *      Writes both mappings, mirroring the contract invariant that `latestTokenSnapshot` is never
   *      behind `tokenSnapshot`. Use `_mockLatestTokenSnapshot` to stash a diverging latest shape.
   *      Self-verifies against the getters.
   * @param _tokenId Token whose snapshot is being seeded.
   * @param _staked Staked amount to write.
   * @param _stakeEnd Stake expiry to write. Zero encodes a permanent stake.
   */
  function _mockTokenSnapshot(uint256 _tokenId, uint128 _staked, uint48 _stakeEnd) internal {
    _mockTokenSnapshot(_tokenId, _staked, _stakeEnd, _stakeEnd == 0);
  }

  /**
   * @notice Overwrite a token's applied and pending stake snapshot with an explicit permanent flag.
   * @param _tokenId Token whose snapshot is being seeded.
   * @param _staked Staked amount to write.
   * @param _stakeEnd Stake expiry to write. Ignored when `_isPermanent` is true.
   * @param _isPermanent Permanent flag to write.
   */
  function _mockTokenSnapshot(uint256 _tokenId, uint128 _staked, uint48 _stakeEnd, bool _isPermanent) internal {
    vm.store(
      address(_leafVoter),
      keccak256(abi.encode(_tokenId, _TOKEN_SNAPSHOT_SLOT)),
      bytes32(uint256(_staked) | (uint256(_stakeEnd) << 128) | (uint256(_isPermanent ? 1 : 0) << 176))
    );
    (uint128 _storedStaked, uint48 _storedStakeEnd, bool _storedPermanent) = _leafVoter.tokenSnapshot(_tokenId);
    assertEq(_storedStaked, _staked);
    assertEq(_storedStakeEnd, _stakeEnd);
    assertEq(_storedPermanent, _isPermanent);
    _mockLatestTokenSnapshot(_tokenId, _staked, _stakeEnd, _isPermanent);
  }

  /**
   * @notice Overwrite only a token's pending stake snapshot directly in storage.
   * @param _tokenId Token whose latest snapshot is being seeded.
   * @param _staked Staked amount to write.
   * @param _stakeEnd Stake expiry to write. Zero encodes a permanent stake.
   */
  function _mockLatestTokenSnapshot(uint256 _tokenId, uint128 _staked, uint48 _stakeEnd) internal {
    _mockLatestTokenSnapshot(_tokenId, _staked, _stakeEnd, _stakeEnd == 0);
  }

  /**
   * @notice Overwrite a token's pending stake snapshot with an explicit permanent flag.
   * @param _tokenId Token whose latest snapshot is being seeded.
   * @param _staked Staked amount to write.
   * @param _stakeEnd Stake expiry to write. Ignored when `_isPermanent` is true.
   * @param _isPermanent Permanent flag to write.
   */
  function _mockLatestTokenSnapshot(uint256 _tokenId, uint128 _staked, uint48 _stakeEnd, bool _isPermanent) internal {
    vm.store(
      address(_leafVoter),
      keccak256(abi.encode(_tokenId, _LATEST_TOKEN_SNAPSHOT_SLOT)),
      bytes32(uint256(_staked) | (uint256(_stakeEnd) << 128) | (uint256(_isPermanent ? 1 : 0) << 176))
    );
    (uint128 _pendingStaked, uint48 _pendingStakeEnd, bool _pendingPermanent) = _leafVoter.latestTokenSnapshot(_tokenId);
    assertEq(_pendingStaked, _staked);
    assertEq(_pendingStakeEnd, _stakeEnd);
    assertEq(_pendingPermanent, _isPermanent);
  }

  /**
   * @notice Overwrite a tokenId's parked allocation on `_gauge` directly in storage.
   * @dev `allocations` is a nested mapping at `_ALLOCATIONS_SLOT`: the inner key is the gauge, the outer key the
   *      tokenId. Self-verifies against the getter.
   * @param _tokenId Token whose allocation is being seeded.
   * @param _gauge Gauge the allocation is booked on.
   * @param _amount Allocation amount to write.
   */
  function _mockAllocation(uint256 _tokenId, address _gauge, uint128 _amount) internal {
    vm.store(
      address(_leafVoter),
      keccak256(abi.encode(_gauge, keccak256(abi.encode(_tokenId, _ALLOCATIONS_SLOT)))),
      bytes32(uint256(_amount))
    );
    assertEq(_leafVoter.allocations(_tokenId, _gauge), _amount);
  }

  /**
   * @notice Overwrite a tokenId's `chainAllocation` budget directly in storage.
   * @dev `chainAllocation` packs into the second sub-slot of the packed `TokenState`, one past the
   *      slot the operator and cooldown flags occupy. Self-verifies against the getter.
   * @param _tokenId Token whose budget is being seeded.
   * @param _budget Chain allocation to write.
   */
  function _mockChainAllocation(uint256 _tokenId, uint128 _budget) internal {
    vm.store(
      address(_leafVoter),
      bytes32(uint256(keccak256(abi.encode(_tokenId, _TOKEN_STATE_SLOT))) + 1),
      bytes32(uint256(_budget))
    );
    assertEq(_chainAllocationOf(_tokenId), _budget);
  }

  /**
   * @notice Overwrite a tokenId's `accumulatedCooldownReduction` directly in storage.
   * @dev `accumulatedCooldownReduction` is a single-level `(uint256 => uint48)` mapping at
   *      `_ACCUMULATED_COOLDOWN_REDUCTION_SLOT`; the
   *      value slot is `keccak256(abi.encode(_tokenId, 11))`. `uint48` fits in the low 6 bytes.
   *      Self-verifies against the getter. Tests seed the accumulated grant this way instead of calling
   *      `applyCooldownReduction`, keeping the consume paths isolated to one execution.
   * @param _tokenId Token whose accumulated reduction is being seeded.
   * @param _reduction Accumulated reduction to write.
   */
  function _mockAccumulatedCooldownReduction(uint256 _tokenId, uint48 _reduction) internal {
    vm.store(
      address(_leafVoter),
      keccak256(abi.encode(_tokenId, _ACCUMULATED_COOLDOWN_REDUCTION_SLOT)),
      bytes32(uint256(_reduction))
    );
    assertEq(_leafVoter.accumulatedCooldownReduction(_tokenId), _reduction);
  }

  /**
   * @notice Seed `_gauge` into a tokenId's voted `EnumerableSet.AddressSet` directly in storage.
   * @dev The set at `_VOTED_GAUGES_SLOT` wraps a `Bytes32Set { bytes32[] _values; mapping(bytes32 => uint256)
   *      _positions }`. Writes the array length, element zero, and the one-based position so the
   *      OZ invariants hold. Self-verifies the gauge is present through the `allocatedGauges` getter.
   *      Only seeds a single-element set, enough for the allocation cases.
   * @param _tokenId Token whose voted set is being seeded.
   * @param _gauge Gauge to insert.
   */
  function _mockVotedGauge(uint256 _tokenId, address _gauge) internal {
    bytes32 _base = keccak256(abi.encode(_tokenId, _VOTED_GAUGES_SLOT));
    bytes32 _key = bytes32(uint256(uint160(_gauge)));

    // `_values` length lives at `_base`; its element zero at `keccak256(_base)`.
    vm.store(address(_leafVoter), _base, bytes32(uint256(1)));
    vm.store(address(_leafVoter), keccak256(abi.encode(uint256(_base))), _key);
    // `_positions[_key]` is one-based, stored at the mapping slot `_base + 1`.
    vm.store(address(_leafVoter), keccak256(abi.encode(_key, bytes32(uint256(_base) + 1))), bytes32(uint256(1)));

    address[] memory _gauges = _leafVoter.allocatedGauges(_tokenId);
    bool _present;
    for (uint256 _i; _i < _gauges.length; ++_i) {
      if (_gauges[_i] == _gauge) _present = true;
    }
    assertTrue(_present);
  }

  /// @notice Current surplus booked on a gauge.
  function _gaugeSurplus(address _gauge) internal view returns (uint128 _surplus) {
    (,,,,, _surplus,,,) = _leafVoter.gaugeStates(_gauge);
  }

  /// @notice Seed the chain-level surplus accumulator. Self-verifies against the getter.
  function _mockSurplusAccrued(uint256 _surplusAccrued) internal {
    vm.store(address(_leafVoter), bytes32(_SURPLUS_ACCRUED_SLOT), bytes32(_surplusAccrued));
    assertEq(_leafVoter.surplusAccrued(), _surplusAccrued);
  }

  /**
   * @notice Register `_gauge` and optionally activate it.
   * @dev Writes straight to storage so the tests never call the contract under
   *      test to arrange routing state. Seeding `lastSettlement` to the chain's
   *      keeps an unwarped `_settleGauge` a zero-length no-op. The emission cap
   *      defaults to the uncapped sentinel so the routing cap gate passes;
   *      zero-cap cases override with `_mockEmissionCap`. Self-verifies each
   *      write against its getter.
   * @param _gauge Gauge to register.
   * @param _activated Whether to also flip the activation flag.
   */
  function _mockRegisterGauge(address _gauge, bool _activated) internal {
    uint48 _settledAt = _leafVoter.lastSettlement();
    _mockEmissionCap(_gauge, type(uint128).max);

    // The gaugeStates struct's second slot packs lastSettlement (low 6 bytes)
    // with isRegistered (byte 6) and isActivated (byte 7).
    bytes32 _stateBase = keccak256(abi.encode(_gauge, _GAUGE_STATES_SLOT));
    vm.store(
      address(_leafVoter),
      bytes32(uint256(_stateBase) + 1),
      bytes32(uint256(_settledAt) | (uint256(1) << 48) | (uint256(_activated ? 1 : 0) << 56))
    );

    (,, uint48 _lastSettled, bool _isRegistered, bool _isActivated,,,,) = _leafVoter.gaugeStates(_gauge);
    assertEq(_isRegistered, true);
    assertEq(_lastSettled, _settledAt);
    assertEq(_isActivated, _activated);
  }

  /**
   * @notice Build a `Point` from its fields.
   * @param _bias Decaying voting power at `_ts`.
   * @param _slope Decay rate per second.
   * @param _ts Timestamp the point is resolved at.
   * @param _permanentStakeBalance Non-decaying voting power.
   * @return _point The assembled point.
   */
  function _buildPoint(
    int128 _bias,
    int128 _slope,
    uint48 _ts,
    uint128 _permanentStakeBalance
  ) internal pure returns (IVoterCommon.Point memory _point) {
    _point = IVoterCommon.Point({bias: _bias, slope: _slope, ts: _ts, permanentStakeBalance: _permanentStakeBalance});
  }

  /**
   * @notice Build a fully-populated `GaugeState` from its fields.
   * @param _ceiling Cumulative emission share credited to the gauge.
   * @param _claimed Portion of the ceiling already pulled.
   * @param _lastSettlement Gauge's prior settlement cursor.
   * @param _isRegistered Whether the gauge is registered.
   * @param _surplus Claimable headroom carried forward.
   * @param _lastIndex Index snapshot at the prior settlement.
   * @param _point Decaying weight of the gauge.
   * @return _state The assembled state. `isActivated` defaults to false and `lastTimeIndex` to zero; callers that
   *                need either set it on the result.
   */
  function _buildGaugeState(
    uint128 _ceiling,
    uint128 _claimed,
    uint48 _lastSettlement,
    bool _isRegistered,
    uint128 _surplus,
    uint256 _lastIndex,
    IVoterCommon.Point memory _point
  ) internal pure returns (ILeafVoter.GaugeState memory _state) {
    _state = ILeafVoter.GaugeState({
      ceiling: _ceiling,
      claimed: _claimed,
      lastSettlement: _lastSettlement,
      isRegistered: _isRegistered,
      isActivated: false,
      surplus: _surplus,
      lastIndex: _lastIndex,
      lastTimeIndex: 0,
      point: _point
    });
  }

  /**
   * @notice Build an allocation list from paired gauge and amount arrays.
   * @param _gauges Gauges to allocate to, strictly ascending.
   * @param _amounts Amount allocated to each gauge, index-aligned with `_gauges`.
   */
  function _list(
    address[] memory _gauges,
    uint128[] memory _amounts
  ) internal pure returns (IVoterCommon.GaugeAllocation[] memory _allocations) {
    _allocations = new IVoterCommon.GaugeAllocation[](_gauges.length);
    for (uint256 _i; _i < _gauges.length; ++_i) {
      _allocations[_i] = IVoterCommon.GaugeAllocation({gauge: _gauges[_i], allocated: _amounts[_i], data: ''});
    }
  }

  /**
   * @notice Builds a `(recipients, amounts)` pair of length `_arrayLen` where every recipient is unique and every
   * amount equals `_amountSeed`.
   * @param _arrayLen Number of entries in the returned arrays.
   * @param _recipientSeed Base address used to derive unique recipients (`_recipientSeed + i`).
   * @param _amountSeed Amount value used for every entry.
   * @return _recipients Generated recipient addresses.
   * @return _amounts Generated amounts.
   */
  function _buildRecipientsAmounts(
    uint256 _arrayLen,
    address _recipientSeed,
    uint256 _amountSeed
  ) internal pure returns (address[] memory _recipients, uint128[] memory _amounts) {
    _recipients = new address[](_arrayLen);
    _amounts = new uint128[](_arrayLen);
    for (uint256 _i; _i < _arrayLen; ++_i) {
      _recipients[_i] = address(uint160(uint256(uint160(_recipientSeed)) + _i));
      _amounts[_i] = uint128(_amountSeed);
    }
  }

  /// @notice Permanent-stake weight currently booked on `_gauge`.
  function _gaugeWeight(address _gauge) internal view returns (uint128 _weight) {
    (,,,,,,,, IVoterCommon.Point memory _point) = _leafVoter.gaugeStates(_gauge);
    _weight = _point.permanentStakeBalance;
  }

  /// @notice The tokenId's registered operator.
  function _operatorOf(uint256 _tokenId) internal view returns (address _operator) {
    (_operator,,,) = _leafVoter.tokenStates(_tokenId);
  }

  /// @notice The tokenId's last-voted cooldown anchor.
  function _lastVotedOf(uint256 _tokenId) internal view returns (uint48 _lastAllocated) {
    (, _lastAllocated,,) = _leafVoter.tokenStates(_tokenId);
  }

  /// @notice Whether the tokenId may route weight onto activated zero-cap gauges.
  function _canVoteForZeroCapGaugesOf(uint256 _tokenId) internal view returns (bool _canVoteForZeroCapGauges) {
    (,, _canVoteForZeroCapGauges,) = _leafVoter.tokenStates(_tokenId);
  }

  /// @notice The tokenId's chain allocation budget.
  function _chainAllocationOf(uint256 _tokenId) internal view returns (uint128 _chainAllocation) {
    (,,, _chainAllocation) = _leafVoter.tokenStates(_tokenId);
  }

  /// @notice Whether `_gauge` is in the tokenId's voted set.
  function _inVotedSet(address _gauge) internal view returns (bool _present) {
    address[] memory _gauges = _leafVoter.allocatedGauges(_TOKEN_ID);
    for (uint256 _i; _i < _gauges.length; ++_i) {
      if (_gauges[_i] == _gauge) return true;
    }
    return false;
  }

  /**
   * @notice Mock a value-carrying call and require it happens exactly once.
   * @dev `_mockAndExpectWithValue` asserts at-least-once; this counted variant pins single-dispatch
   *      invariants (e.g. exactly one deallocation return per sentinel).
   */
  function _mockAndExpectOnceWithValue(
    address _receiver,
    uint256 _value,
    bytes memory _calldata,
    bytes memory _returned
  ) internal {
    vm.mockCall(_receiver, _value, _calldata, _returned);
    vm.expectCall(_receiver, _value, _calldata, 1);
  }
}
