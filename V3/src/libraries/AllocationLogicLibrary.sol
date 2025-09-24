// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {DEALLOC_GAUGE, MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {VoterStorage} from 'V3/voter/VoterStorageLayout.sol';

/**
 * @title AllocationLogicLibrary
 * @notice Voter's allocation and settlement logic, extracted as an externally linked library so the Voter runtime
 *         stays under the EIP-170 size limit. Entries take the Voter's allocation state as one storage struct;
 *         auth and orchestrator sends stay in the Voter, which passes the VotingEscrow and Minter handles in
 *         so external reads stay lazy and run only on the paths that need them.
 */
library AllocationLogicLibrary {
  using EnumerableSet for EnumerableSet.UintSet;

  /**
   * @notice Everything one chain's gauge-allocation leg needs besides the gauge list, bundled so the entries
   *         below take a single memory argument instead of a stack-deep argument list.
   * @param tokenId veNFT id being allocated.
   * @param chainId Destination chain.
   * @param gasLimit Destination gas budget for the leaf `handle()` call.
   * @param value Native value forwarded whole to the orchestrator, which keeps any return cost from it.
   * @param allocationLifetime Message lifetime stamped onto the payload as an absolute expiry.
   * @param snapshot Live external state read once by the entrypoint.
   */
  struct GaugeAllocationInput {
    uint256 tokenId;
    uint256 chainId;
    uint256 gasLimit;
    uint256 value;
    uint48 allocationLifetime;
    IVoter.AllocationSnapshot snapshot;
  }

  /// @notice Reserved chainId for idle voting power; mirrors `Voter.CHAIN0`.
  uint256 internal constant _CHAIN0 = 0;

  /// @notice Reserved tokenId that books burned permanent voting power; mirrors `Voter.TOKEN0`.
  uint256 internal constant _TOKEN0 = 0;

  /*//////////////////////////////////////////////////////////////
                       DISPATCH BUILDER ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Validates the caller amounts, runs `_applyAllocation`, and returns the built batch. Sends nothing.
   * @dev Shared by `allocateChains` and `allocate`, which differ only in the native value each forwards.
   * @dev Takes the snapshot as a parameter instead of reading it: the entrypoint vets it once, so no dispatch in
   *      the same call can change what this books.
   * @param _voterStorage Voter allocation state the allocation is applied to
   * @param _tokenId veNFT id being allocated
   * @param _allocations Caller chain allocations, strictly ascending by chainId and free of `CHAIN0`
   * @param _snapshot Live external state read once by the entrypoint
   * @return _dispatches Built `AllocateChain` entries; the caller sends them
   */
  function prepareChainAllocations(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.ChainAllocationDispatch[] calldata _allocations,
    IVoter.AllocationSnapshot memory _snapshot
  ) external returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    uint128 _totalDelta = _validateAllocations(_voterStorage, _allocations);

    // Build the context from the stake the entrypoint already vetted, so a dispatch later in the same call
    // cannot swap the shape or size this books against.
    IVoter.TokenState memory _prev = _voterStorage.tokenStates[_tokenId];
    // slither-disable-next-line uninitialized-local
    IVoter.AllocationContext memory _context;
    _context.veStaked = _snapshot.staked;
    _context.veStakeEnd = _snapshot.stakeEnd;
    _context.veIsPermanent = _snapshot.isPermanent;
    _context.prevCommitted = _prev.committed;
    _context.oldStakeEnd = _prev.lastStakeEnd;
    _context.oldIsPermanent = _prev.isPermanent;
    // Sending is the caller's job, once every read this call needs is done.
    _dispatches = _applyAllocation({
      _voterStorage: _voterStorage,
      _tokenId: _tokenId,
      _allocations: _allocations,
      _totalDelta: _totalDelta,
      _context: _context,
      _emissionRate: _snapshot.emissionRate
    });

    emit IVoter.ChainsAllocated(_tokenId, _allocations);
  }

  /**
   * @notice Validates, settles and builds the single `AllocateGauge` dispatch of `allocateGauges`. Sends nothing.
   * @dev One entry for the whole entrypoint: the caller only forwards the returned dispatch.
   * @param _voterStorage Voter allocation state the allocation is validated and settled against
   * @param _input Everything the leg needs besides the gauge list
   * @param _gauges Per-gauge allocations, strictly ascending; may carry the `DEALLOC_GAUGE` sentinel
   * @return _dispatch Built `AllocateGauge` entry for this chain; the caller sends it
   */
  function prepareGaugeAllocation(
    VoterStorage storage _voterStorage,
    GaugeAllocationInput memory _input,
    IVoterCommon.GaugeAllocation[] calldata _gauges
  ) external returns (IRootMessageOrchestrator.ChainDispatch memory _dispatch) {
    _dispatch = _prepareGaugeAllocation(_voterStorage, _input, _gauges);
  }

  /**
   * @notice Validates, settles, and builds every `AllocateGauge` entry of a composed `allocate`. Sends nothing.
   * @dev One entry for the whole gauge phase, so the batch is fully built before the caller's first send.
   * @param _voterStorage Voter allocation state the allocations are validated and settled against
   * @param _tokenId veNFT id being allocated
   * @param _gaugeDispatches Per-chain gauge lists with dispatch params, strictly ascending by `chainId`
   * @param _allocationLifetime Message lifetime stamped onto every payload as an absolute expiry
   * @param _snapshot Live external state read once by the entrypoint
   * @return _dispatches One entry per gauge leg, ready to hand to the orchestrator
   */
  function prepareGaugeBatch(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.GaugeAllocationDispatch[] calldata _gaugeDispatches,
    uint48 _allocationLifetime,
    IVoter.AllocationSnapshot memory _snapshot
  ) external returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    uint256 _length = _gaugeDispatches.length;
    _dispatches = new IRootMessageOrchestrator.ChainDispatch[](_length);

    // slither-disable-next-line uninitialized-local
    uint256 _prevChainId;
    // Every leg aliases the same `_snapshot` buffer, so nothing here may mutate it: a per-leg write would
    // leak into every following chain's payload.
    for (uint256 _i; _i < _length; ++_i) {
      IVoter.GaugeAllocationDispatch calldata _gaugeDispatch = _gaugeDispatches[_i];
      // Strict ascending also rejects CHAIN0 (id 0) and duplicates.
      if (_gaugeDispatch.chainId <= _prevChainId) revert IVoter.GaugeDispatchesNotStrictlyAscending();
      _prevChainId = _gaugeDispatch.chainId;
      GaugeAllocationInput memory _input = GaugeAllocationInput({
        tokenId: _tokenId,
        chainId: _gaugeDispatch.chainId,
        gasLimit: _gaugeDispatch.gasLimit,
        value: _gaugeDispatch.value,
        allocationLifetime: _allocationLifetime,
        snapshot: _snapshot
      });
      _dispatches[_i] = _prepareGaugeAllocation(_voterStorage, _input, _gaugeDispatch.gauges);
    }
  }

  /**
   * @notice Validates and builds every reward-claim dispatch. Sends nothing.
   * @dev Chain ids must be strictly ascending. Only registered `Active` or `Sunset` chains accept new claims.
   * @param _voterStorage Voter allocation state the chain statuses are read from
   * @param _tokenId veNFT id being claimed for
   * @param _claimRewardsParams Per-chain claims and dispatch params, strictly ascending by `chainId`
   * @param _messageLifetime Message lifetime stamped onto every payload as an absolute expiry
   * @return _dispatches One entry per claim leg, ready to hand to the orchestrator
   */
  function prepareClaimRewardsDispatches(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.ClaimRewardsParams[] calldata _claimRewardsParams,
    uint48 _messageLifetime
  ) external returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    uint256 _length = _claimRewardsParams.length;
    _dispatches = new IRootMessageOrchestrator.ChainDispatch[](_length);

    // The recipient is fixed at dispatch, so the expiry bounds how long a stalled claim can still pay it out.
    uint48 _expiry = uint48(block.timestamp) + _messageLifetime;
    // slither-disable-next-line uninitialized-local
    uint256 _prevChainId;
    for (uint256 _i; _i < _length; ++_i) {
      IVoter.ClaimRewardsParams calldata _params = _claimRewardsParams[_i];
      uint256 _chainId = _params.chainId;

      // Strict ascending also rejects CHAIN0 (id 0) and duplicates.
      if (_chainId <= _prevChainId) revert IVoter.ClaimRewardsParamsNotStrictlyAscending();
      requireDispatchableChain(_voterStorage, _chainId, _params.gasLimit);
      if (_params.recipient == address(0)) revert IVoterCommon.ZeroAddress();
      if (_params.feeClaims.length == 0 && _params.incentiveClaims.length == 0) {
        revert IVoter.EmptyClaimRewardsParams();
      }

      _dispatches[_i] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _chainId,
        gasLimit: _params.gasLimit,
        nativeValue: _params.value,
        chargeDeallocationReturn: false,
        payload: abi.encode(_tokenId, _expiry, _params.recipient, _params.feeClaims, _params.incentiveClaims)
      });

      emit IVoter.RewardsClaimDispatched(_tokenId, _chainId, _params.recipient);

      _prevChainId = _chainId;
    }
  }

  /*//////////////////////////////////////////////////////////////
                          SETTLEMENT ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Brings one chain fully current: accrues its ceiling for the elapsed global-index delta and resolves
   *         its point to now.
   * @dev The entry the Voter's own settle sites (`processRedeem`, `setChainStatus`, `spendSurplus`) go through.
   * @param _voterStorage Voter allocation state the settle is applied to
   * @param _chainId Chain to settle and resolve
   */
  function settleChain(VoterStorage storage _voterStorage, uint256 _chainId) external {
    _settleChain(_voterStorage, _chainId);
  }

  /**
   * @notice Advances the global emissions accumulators to now, banking a mark at every week boundary crossed.
   * @dev The entry `registerChain` goes through, so the cursors it plants describe the registration instant.
   * @param _voterStorage Voter allocation state the accumulators live in
   */
  function settleGlobalIndex(VoterStorage storage _voterStorage) external {
    _settleGlobalIndex(_voterStorage);
  }

  /*//////////////////////////////////////////////////////////////
                        CHAIN0 LEDGER ENTRIES
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Drops `_amount` of permanent voting power booked by `TOKEN0` on `CHAIN0` and resamples the scalar.
   * @dev The whole body of `Voter.burn` past its access gate. Emits `Burned` with the Voter as the emitter, the
   *      library running under `delegatecall`.
   * @param _voterStorage Voter allocation state the burn is applied to
   * @param _amount Permanent voting power removed from `CHAIN0` and `totalPoint`
   * @param _minter Minter the emission rate is read from, lazily, once the guards have passed
   */
  function applyBurn(VoterStorage storage _voterStorage, uint128 _amount, IMinter _minter) external {
    // 1. The burn token must hold enough VP committed to chain0.
    if (_amount == 0) revert IVoter.ZeroAmount();
    if (_voterStorage.tokenStates[_TOKEN0].committed < _amount) revert IVoter.InsufficientCommitted();
    if (_voterStorage.allocationChainAmounts[_TOKEN0][_CHAIN0] < _amount) {
      revert IVoter.InsufficientChain0Allocation();
    }

    // 2. Settle before moving weight.
    _settleChain0AndTotal(_voterStorage);

    // 3. Drop permanent VP from chain0 and totalPoint. The precondition above plus the invariant
    //    `Σ allocationChainAmounts[id][*] == tokenStates[id].committed` keep both non-negative.
    int128 _negativeAmount = -SafeCastLibrary.toInt128(_amount);
    _applyChain0AndTotal({
      _voterStorage: _voterStorage, _bias: 0, _slope: 0, _permanent: _negativeAmount, _stakeEnd: 0, _isPermanent: true
    });

    // 4. Drop the per-tokenId state, removing CHAIN0 from the set when drained to keep the pairing invariant.
    _voterStorage.tokenStates[_TOKEN0].committed -= _amount;
    _voterStorage.allocationChainAmounts[_TOKEN0][_CHAIN0] -= _amount;
    if (_voterStorage.allocationChainAmounts[_TOKEN0][_CHAIN0] == 0) {
      // slither-disable-next-line unused-return
      _voterStorage.allocationChainIds[_TOKEN0].remove(_CHAIN0);
    }

    // 5. Resample `emissionsPerVP`; chains pick the change up through the shared index on their next settle.
    _refreshEmissionsPerVP(_voterStorage, _minter);

    emit IVoter.Burned(msg.sender, _amount);
  }

  /**
   * @notice Moves chain0-parked voting power between tokens in one batch, then resamples the scalar.
   * @dev The whole body of `Voter.rebalanceChain0` past its access gate. `_votingEscrow` is passed in rather
   *      than read here, so the destination stake read keeps happening exactly where it did: once per non-zero
   *      destination leg. Emits `Chain0Rebalanced` with the Voter as the emitter.
   * @param _voterStorage Voter allocation state the batch is applied to
   * @param _votingEscrow VotingEscrow each destination's live stake shape is read from
   * @param _sources Source legs losing chain0 allocation at their recorded shape
   * @param _destinations Destination legs gaining chain0 allocation at their live shape
   * @param _minter Minter the emission rate is read from, lazily, at the closing resample
   */
  function rebalanceChain0(
    VoterStorage storage _voterStorage,
    IVotingEscrow _votingEscrow,
    IVotingEscrow.SourceDelta[] calldata _sources,
    IVotingEscrow.DestinationDelta[] calldata _destinations,
    IMinter _minter
  ) external {
    // 1. Settle chain0 / totalPoint once for the whole batch, before any leg moves weight. Sources and
    //    destinations move on their own: `rebalanceUnderlying` conserves totals, so the net deltas match.
    _settleChain0AndTotal(_voterStorage);

    // 2. Sources: drop each contribution at its recorded stakeEnd.
    uint256 _sourcesLength = _sources.length;
    for (uint256 _i; _i < _sourcesLength; ++_i) {
      _removeChain0Contribution(_voterStorage, _sources[_i].tokenId, _sources[_i].amount);
    }

    // 3. Destinations: add each contribution at its live VE stakeEnd. VE already resolved the tokenIds.
    uint256 _destinationsLength = _destinations.length;
    for (uint256 _i; _i < _destinationsLength; ++_i) {
      _addChain0Contribution(_voterStorage, _votingEscrow, _destinations[_i].tokenId, _destinations[_i].amount);
    }

    // 4. Resample `emissionsPerVP` once against the post-batch total weight.
    _refreshEmissionsPerVP(_voterStorage, _minter);

    emit IVoter.Chain0Rebalanced(_sources, _destinations);
  }

  /**
   * @notice Books every unallocated unit of a token's live stake onto `CHAIN0`, re-anchoring a stale stored
   *         shape first, then resamples the scalar.
   * @dev The whole body of `Voter.parkOnChain0` past its access gate and its live-stake read. Emits
   *      `ParkedOnChain0` with the Voter as the emitter.
   * @param _voterStorage Voter allocation state the park is applied to
   * @param _votingEscrow VotingEscrow the destination shape is read from when the chain0 leg lands
   * @param _tokenId veNFT id being parked
   * @param _stake Live VE stake read once by the caller and already vetted as funded and unexpired
   * @param _minter Minter the emission rate is read from, lazily, at the closing resample
   */
  function parkOnChain0(
    VoterStorage storage _voterStorage,
    IVotingEscrow _votingEscrow,
    uint256 _tokenId,
    IVoterCommon.TokenSnapshot memory _stake,
    IMinter _minter
  ) external {
    // Everything in `committed` already sits on some chain, so `staked - committed` is what is left to park.
    // Zero is the norm and still runs the re-anchor below, so a lock extension alone syncs through here.
    uint128 _committed = _voterStorage.tokenStates[_tokenId].committed;
    // `committed > staked` should not exist, but it saturates instead of reverting: VotingEscrow drives this
    // from its deposit and reshape paths, so a bad ledger must not lock an owner out of their own stake.
    uint128 _amount = _stake.staked > _committed ? _stake.staked - _committed : 0;

    _settleChain0AndTotal(_voterStorage);

    // A stale stored shape re-anchors first (local, no dispatch) so the new CHAIN0 leg lands at one shared shape
    // instead of reverting `DstShapeStale`. Unmessaged leaves lag lower, so `Σ leaf ≤ ceiling` still holds.
    IVoter.TokenState memory _stored = _voterStorage.tokenStates[_tokenId];
    bool _shapeChanged = _voterStorage.allocationChainIds[_tokenId].length() > 0
      && _shapeDiffers(_stored.lastStakeEnd, _stored.isPermanent, _stake.stakeEnd, _stake.isPermanent);
    if (_shapeChanged) _reanchorToLiveShape(_voterStorage, _tokenId, _stake.stakeEnd, _stake.isPermanent);

    // `lastAllocated` stays untouched: parking must not move the cooldown anchor.
    _addChain0Contribution(_voterStorage, _votingEscrow, _tokenId, _amount);

    // Resample against the final total weight; the re-anchor already settled every touched chain's ceiling.
    _refreshEmissionsPerVP(_voterStorage, _minter);

    emit IVoter.ParkedOnChain0(_tokenId, _amount);
  }

  /**
   * @notice Moves a token's booked voting power on `_originChainId` back to `CHAIN0`, clamped to what root
   *         still books there, and returns the credited amount.
   * @dev Shared by `processDeallocation` and `emergencyDeallocate`. The clamp is the only `CHAIN0` credit in
   *      the system, so a late or duplicate move credits nothing and the same VP never reaches `CHAIN0` twice.
   * @dev Settles before moving weight, then resamples the emissions scalar. Moves at the token's stored shape,
   *      not the live one; its next allocation takes the live VE shape. Returns early when nothing is booked.
   * @param _voterStorage Voter allocation state the credit is applied to
   * @param _originChainId Chain to move the voting power off
   * @param _tokenId veNFT id whose voting power is moving
   * @param _amount Requested move, clamped to the token's origin-chain balance
   * @param _minter Minter the emission rate is read from, lazily, and never on the zero-credit early return
   * @return _credit AERO amount actually credited to `CHAIN0`
   */
  function creditDeallocation(
    VoterStorage storage _voterStorage,
    uint256 _originChainId,
    uint256 _tokenId,
    uint128 _amount,
    IMinter _minter
  ) external returns (uint128 _credit) {
    uint128 _onChain = _voterStorage.allocationChainAmounts[_tokenId][_originChainId];
    _credit = _amount < _onChain ? _amount : _onChain;
    if (_credit == 0) return 0;

    // Settle before moving weight. The two settles are independent, so their order does not matter.
    _settleChain0AndTotal(_voterStorage);
    _settleChain(_voterStorage, _originChainId);

    // No re-anchor, so both shape sides carry the stored shape.
    IVoter.TokenState memory _state = _voterStorage.tokenStates[_tokenId];
    IVoter.AllocationContext memory _context = _sameShapeContext(_state.lastStakeEnd, _state.isPermanent);
    _applyChainAllocation(_voterStorage, _tokenId, _originChainId, _onChain - _credit, _context);
    uint128 _chain0Allocated = _voterStorage.allocationChainAmounts[_tokenId][_CHAIN0];
    _applyChainAllocation(_voterStorage, _tokenId, _CHAIN0, _chain0Allocated + _credit, _context);

    // The shared index carries the change to every chain, including the origin, whose leaf gets no scalar here.
    _refreshEmissionsPerVP(_voterStorage, _minter);
  }

  /*//////////////////////////////////////////////////////////////
                             CHAIN GUARDS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice True when `_chainId` is registered and currently in `_status`.
   * @dev Route every "chain is in status X" gate through this so registration cannot be forgotten.
   * @dev Shared with the Voter, which routes its own status gates here so both call paths read one rule.
   *      Being `internal`, this inlines into the Voter at its call sites there, so no `delegatecall` is paid.
   * @param _voterStorage Voter allocation state the registration and status are read from
   * @param _chainId Chain to check
   * @param _status Required status
   * @return _match True when `_chainId` is registered and in `_status`
   */
  function isChainInStatus(
    VoterStorage storage _voterStorage,
    uint256 _chainId,
    IVoterCommon.ChainStatus _status
  ) internal view returns (bool _match) {
    _match = _voterStorage.chains.contains(_chainId) && _voterStorage.chainStates[_chainId].status == _status;
  }

  /**
   * @notice Reverts `ChainNotActive` unless `_chainId` is a registered, `Active` chain.
   * @param _voterStorage Voter allocation state the registration and status are read from
   * @param _chainId Chain whose status is being checked
   */
  function requireChainActive(VoterStorage storage _voterStorage, uint256 _chainId) internal view {
    if (!isChainInStatus(_voterStorage, _chainId, IVoterCommon.ChainStatus.Active)) {
      revert IVoter.ChainNotActive(_chainId);
    }
  }

  /**
   * @notice Reverts `ChainNotActiveOrSunset` unless `_chainId` is a registered chain in `Active` or `Sunset`.
   * @dev A sunset chain accrues nothing and takes no new voting power, so keeping gauge votes, reward claims and
   *      cooldown reductions dispatchable only lets booked power exit through `DEALLOC_GAUGE`. `setOperator`
   *      gates itself instead, staying open under `Suspended` so a stale operator can still be replaced.
   * @param _voterStorage Voter allocation state the registration and status are read from
   * @param _chainId Chain whose status is being checked
   */
  function requireChainActiveOrSunset(VoterStorage storage _voterStorage, uint256 _chainId) internal view {
    if (
      !isChainInStatus(_voterStorage, _chainId, IVoterCommon.ChainStatus.Active)
        && !isChainInStatus(_voterStorage, _chainId, IVoterCommon.ChainStatus.Sunset)
    ) revert IVoter.ChainNotActiveOrSunset(_chainId);
  }

  /**
   * @notice Outbound-dispatch precondition: the chain must be registered and `Active` or `Sunset`, and a
   *         non-root destination must carry a gas budget.
   * @param _voterStorage Voter allocation state the registration and status are read from
   * @param _chainId Destination chain being dispatched to
   * @param _gasLimit Destination `handle()` gas budget; must be non-zero for a non-root chain
   */
  function requireDispatchableChain(
    VoterStorage storage _voterStorage,
    uint256 _chainId,
    uint256 _gasLimit
  ) internal view {
    requireChainActiveOrSunset(_voterStorage, _chainId);
    requireDestinationGas(_chainId, _gasLimit);
  }

  /**
   * @notice Reverts `MissingDestinationGasLimit` when a non-root chain carries no gas budget.
   * @dev The root-colocated leaf (`block.chainid`) is exempt: the `RootLocalAdapter` delivers it synchronously
   *      with no gas budget.
   * @param _chainId Destination chain being dispatched to
   * @param _gasLimit Destination `handle()` gas budget; must be non-zero for a non-root chain
   */
  function requireDestinationGas(uint256 _chainId, uint256 _gasLimit) internal view {
    if (_gasLimit == 0 && _chainId != block.chainid) revert IVoter.MissingDestinationGasLimit(_chainId);
  }

  /*//////////////////////////////////////////////////////////////
                            CHAIN0 LEDGER
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Re-anchors a token's whole allocated position onto `(_stakeEnd, _isPermanent)` and stores the shape.
   * @dev Local and dispatch-free. Leaves `lastAllocated` alone and leaves the scalar resample to the caller.
   * @param _voterStorage Voter allocation state the re-anchor is applied to
   * @param _tokenId veNFT id being re-anchored
   * @param _stakeEnd Live shape to re-anchor onto
   * @param _isPermanent True when the live shape is permanent
   */
  function _reanchorToLiveShape(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    uint48 _stakeEnd,
    bool _isPermanent
  ) private {
    // slither-disable-next-line uninitialized-local
    IVoter.AllocationContext memory _context;
    _context.oldStakeEnd = _voterStorage.tokenStates[_tokenId].lastStakeEnd;
    _context.oldIsPermanent = _voterStorage.tokenStates[_tokenId].isPermanent;
    _context.veStakeEnd = _stakeEnd;
    _context.veIsPermanent = _isPermanent;
    _reanchor(_voterStorage, _tokenId, _context);
    _voterStorage.tokenStates[_tokenId].lastStakeEnd = _stakeEnd;
    _voterStorage.tokenStates[_tokenId].isPermanent = _isPermanent;
  }

  /**
   * @notice Settles `CHAIN0`'s ceiling and resolves its point plus `totalPoint` to the current timestamp.
   * @dev Runs first in the chain0-mutating paths (`applyBurn`, `rebalanceChain0`, `parkOnChain0`,
   *      `creditDeallocation`). Always pair it with a global emissions-scalar resample against the
   *      post-mutation weights: settling advances the index at the outgoing scalar before the new one lands.
   * @param _voterStorage Voter allocation state the settle is applied to
   */
  function _settleChain0AndTotal(VoterStorage storage _voterStorage) private {
    _settleChain(_voterStorage, _CHAIN0);
    _resolveWeight(_voterStorage.totalPoint, _voterStorage.totalSlopeChanges);
  }

  /**
   * @notice Applies a signed contribution to both the chain0 point and `totalPoint` in one step.
   * @param _voterStorage Voter allocation state the contribution is applied to
   * @param _bias Signed bias delta, ignored on the permanent path
   * @param _slope Signed slope delta, ignored on the permanent path
   * @param _permanent Signed permanent-balance delta, ignored on the decay path
   * @param _stakeEnd Boundary the slope reduction is scheduled at on the decay path
   * @param _isPermanent True selects the permanent path
   */
  function _applyChain0AndTotal(
    VoterStorage storage _voterStorage,
    int128 _bias,
    int128 _slope,
    int128 _permanent,
    uint48 _stakeEnd,
    bool _isPermanent
  ) private {
    _applyContribution({
      _point: _voterStorage.chainStates[_CHAIN0].point,
      _slopeChanges: _voterStorage.chainSlopeChanges[_CHAIN0],
      _bias: _bias,
      _slope: _slope,
      _perm: _permanent,
      _stakeEnd: _stakeEnd,
      _isPermanent: _isPermanent
    });
    _applyContribution({
      _point: _voterStorage.totalPoint,
      _slopeChanges: _voterStorage.totalSlopeChanges,
      _bias: _bias,
      _slope: _slope,
      _perm: _permanent,
      _stakeEnd: _stakeEnd,
      _isPermanent: _isPermanent
    });
  }

  /**
   * @notice Removes a source leg from the chain0 ledger during a `rebalanceChain0` batch.
   * @dev Swaps the whole CHAIN0 position to `old - _amount` at the recorded `lastStakeEnd`: slope flooring
   *      makes per-leg triples non-additive, so the points must hold `contribution(total)` to unwind exactly.
   *      Reverts `InsufficientChain0Allocation` when the position books less.
   * @dev An expired stakeEnd gives a zero contribution, so the points do not move while the ledger still does.
   *      Zero-amount legs are skipped: VE allows them and they change nothing.
   * @param _voterStorage Voter allocation state the leg is applied to
   * @param _source Source tokenId losing chain0 allocation
   * @param _amount AERO amount drained from the source
   */
  function _removeChain0Contribution(VoterStorage storage _voterStorage, uint256 _source, uint128 _amount) private {
    if (_amount == 0) return;
    uint128 _oldAllocated = _voterStorage.allocationChainAmounts[_source][_CHAIN0];
    if (_oldAllocated < _amount) revert IVoter.InsufficientChain0Allocation();

    // Same-shape swap: both legs carry the recorded shape, so only the amount changes.
    IVoter.TokenState memory _sourceState = _voterStorage.tokenStates[_source];
    IVoter.AllocationContext memory _context = _sameShapeContext(_sourceState.lastStakeEnd, _sourceState.isPermanent);
    _applyChainAllocation(_voterStorage, _source, _CHAIN0, _oldAllocated - _amount, _context);

    _voterStorage.tokenStates[_source].committed -= _amount;
  }

  /**
   * @notice Adds a destination leg to the chain0 ledger during a `rebalanceChain0` batch and on every park.
   * @dev A destination that already holds chain0 allocation must have a stored shape matching the live stake,
   *      else `DstShapeStale`: its existing entries and the new one would otherwise span two stakeEnds.
   * @dev Swaps the whole CHAIN0 position to `old + _amount` at the live shape: slope flooring makes per-leg
   *      triples non-additive, so the points must hold `contribution(total)` to unwind exactly.
   * @dev First-time recipients seed `lastStakeEnd`. `lastAllocated` stays untouched so a VPM-driven rebalance
   *      does not move the cooldown anchor. Zero-amount legs are skipped.
   * @param _voterStorage Voter allocation state the leg is applied to
   * @param _votingEscrow VotingEscrow the destination's live stake shape is read from
   * @param _destination Destination tokenId receiving chain0 allocation, already resolved by VotingEscrow
   * @param _amount AERO amount credited to the destination
   */
  function _addChain0Contribution(
    VoterStorage storage _voterStorage,
    IVotingEscrow _votingEscrow,
    uint256 _destination,
    uint128 _amount
  ) private {
    if (_amount == 0) return;

    bool _destinationHasAllocated = _voterStorage.allocationChainIds[_destination].length() > 0;
    IVotingEscrow.StakedBalance memory _stake = _votingEscrow.staked(_destination);
    IVoter.TokenState memory _destinationState = _voterStorage.tokenStates[_destination];
    if (
      _destinationHasAllocated
        && _shapeDiffers(_destinationState.lastStakeEnd, _destinationState.isPermanent, _stake.end, _stake.isPermanent)
    ) revert IVoter.DstShapeStale();

    // Same-shape swap: the check above pins any existing booking to the live shape, so only the amount changes.
    IVoter.AllocationContext memory _context = _sameShapeContext(_stake.end, _stake.isPermanent);
    uint128 _chain0Allocated = _voterStorage.allocationChainAmounts[_destination][_CHAIN0];
    _applyChainAllocation(_voterStorage, _destination, _CHAIN0, _chain0Allocated + _amount, _context);

    _voterStorage.tokenStates[_destination].committed += _amount;

    if (!_destinationHasAllocated) {
      _voterStorage.tokenStates[_destination].lastStakeEnd = _stake.end;
      _voterStorage.tokenStates[_destination].isPermanent = _stake.isPermanent;
    }
  }

  /*//////////////////////////////////////////////////////////////
                          CHAIN ALLOCATION
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Adds each listed chain's `delta`, re-anchors the token's
   *         shape when it changed, and builds the messages for the listed leaves.
   * @dev Additive and partial: only listed chains are touched. Allocations draw only from CHAIN0-parked VP, so
   *      `Σ delta ≤ chain0Parked` (else `InsufficientChain0Allocation`) and `committed` never changes. Unbooked
   *      VP must go through `parkOnChain0` first.
   * @dev One shape per token. On a change `_reanchor` moves every allocated chain up front, else the per-chain
   *      points drift from `totalPoint`. Every swap mirrors onto `totalPoint`, keeping `Σ per-chain == total`.
   * @param _voterStorage Voter allocation state the allocation is applied to
   * @param _tokenId veNFT id being allocated
   * @param _allocations Caller chain allocations, strictly ascending by chainId and free of `CHAIN0`
   * @param _totalDelta Σ `delta` across `_allocations`, bounded by `chain0Parked`
   * @param _context Per-tokenId context built by `prepareChainAllocations`
   * @param _emissionRate Emission rate read once by the entrypoint
   * @return _dispatches Built `AllocateChain` entries; the caller sends them
   */
  function _applyAllocation(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.ChainAllocationDispatch[] calldata _allocations,
    uint128 _totalDelta,
    IVoter.AllocationContext memory _context,
    uint256 _emissionRate
  ) private returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    uint128 _chain0Parked = _voterStorage.allocationChainAmounts[_tokenId][_CHAIN0];
    if (_totalDelta > _chain0Parked) revert IVoter.InsufficientChain0Allocation();
    uint128 _fromChain0 = _totalDelta;

    bool _shapeChanged =
      _shapeDiffers(_context.oldStakeEnd, _context.oldIsPermanent, _context.veStakeEnd, _context.veIsPermanent);

    // Resolve `totalPoint` once; every per-chain swap below mirrors onto it.
    _resolveWeight(_voterStorage.totalPoint, _voterStorage.totalSlopeChanges);

    // Re-anchor first (local, no dispatch), then collapse the old shape onto the live one so the pass below is
    // a pure `+delta`. Both shape fields collapse together, so a later swap unwinds at the re-anchored shape.
    // Unlisted chains stay unmessaged: `stakeEnd` only extends, so their leaves lag lower.
    if (_shapeChanged) {
      _reanchor(_voterStorage, _tokenId, _context);
      _context.oldStakeEnd = _context.veStakeEnd;
      _context.oldIsPermanent = _context.veIsPermanent;
    }

    _applyChainDeltas(_voterStorage, _tokenId, _allocations, _context);

    // CHAIN0 gives up the whole delta, redeployed onto the listed chains. Root-only: CHAIN0 has no leaf.
    if (_fromChain0 > 0) {
      _settleChain(_voterStorage, _CHAIN0);
      _applyChainAllocation(_voterStorage, _tokenId, _CHAIN0, _chain0Parked - _fromChain0, _context);
    }

    // Every touched chain settled its ceiling before its weight moved; the shared index carries the change.
    _refreshEmissionsPerVP(_voterStorage, _emissionRate);

    // `committed` is unchanged: the VP only shifted from CHAIN0 onto the listed chains.
    _voterStorage.tokenStates[_tokenId] = IVoter.TokenState({
      committed: _context.prevCommitted,
      lastStakeEnd: _context.veStakeEnd,
      lastAllocated: uint48(block.timestamp),
      isPermanent: _context.veIsPermanent
    });

    // Build but do not send: the caller owns the send order. An empty list ships nothing.
    _dispatches = _buildChainAllocations(_voterStorage, _tokenId, _context, _allocations);
  }

  /**
   * @notice Re-anchors the token's whole allocated position to its new stake shape. Local only, no dispatch.
   *         Runs once, before any delta is applied, when the shape changed.
   * @dev Re-anchors each chain with a same-amount swap `(amount, oldStakeEnd) → (amount, veStakeEnd)` mirrored
   *      onto `totalPoint`, `CHAIN0` included. The caller resamples the emissions scalar once all swaps land.
   * @param _voterStorage Voter allocation state the re-anchor is applied to
   * @param _tokenId veNFT id being re-anchored
   * @param _context Per-tokenId context supplying `oldStakeEnd` / `veStakeEnd`
   */
  function _reanchor(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.AllocationContext memory _context
  ) private {
    EnumerableSet.UintSet storage _allocatedSet = _voterStorage.allocationChainIds[_tokenId];
    uint256[] memory _allocatedChains = _allocatedSet.values();
    uint256 _allocatedChainsLength = _allocatedChains.length;
    for (uint256 _i; _i < _allocatedChainsLength; ++_i) {
      uint256 _chainId = _allocatedChains[_i];
      _settleChain(_voterStorage, _chainId);
      // Same amount, new shape.
      _applyChainAllocation(
        _voterStorage, _tokenId, _chainId, _voterStorage.allocationChainAmounts[_tokenId][_chainId], _context
      );
    }
  }

  /**
   * @notice Adds each listed chain's `delta` at the token's live shape and stores the per-chain allocation.
   * @dev Runs after `_reanchor` collapsed the position onto the live shape, so this is a pure additive pass:
   *      settle each chain, then swap `(old, veStakeEnd) → (old + delta, veStakeEnd)`. Reductions never happen
   *      here (delta ≥ 0); they route leaf-first through `deallocate`.
   * @dev A `delta == 0` entry is a refresh poke: it ships a delta-0 message so a quiet leaf re-reads
   *      `emissionsPerVP`. It needs no position on the chain and writes nothing for the token.
   * @param _voterStorage Voter allocation state the deltas are applied to
   * @param _tokenId veNFT id being allocated
   * @param _allocations Caller chain allocations, strictly ascending and `CHAIN0`-free
   * @param _context Per-tokenId snapshot of token / VE state, read once when the allocation starts
   */
  function _applyChainDeltas(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.ChainAllocationDispatch[] calldata _allocations,
    IVoter.AllocationContext memory _context
  ) private {
    uint256 _length = _allocations.length;
    for (uint256 _i; _i < _length; ++_i) {
      IVoter.ChainAllocationDispatch calldata _allocation = _allocations[_i];
      uint256 _chainId = _allocation.chainId;
      uint128 _delta = _allocation.delta;
      uint128 _old = _voterStorage.allocationChainAmounts[_tokenId][_chainId];

      _settleChain(_voterStorage, _chainId);

      // The leaf applies `delta` additively too, so a reordered or in-flight message cannot revive a
      // deallocated budget.
      _applyChainAllocation(_voterStorage, _tokenId, _chainId, _old + _delta, _context);
    }
  }

  /*//////////////////////////////////////////////////////////////
                           GAUGE ALLOCATION
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Validates, settles, and builds the `AllocateGauge` dispatch entry for one chain, flagging the
   *         deallocation return charge when the list carries the sentinel. Sends nothing.
   * @dev Shared by `prepareGaugeAllocation` and each `prepareGaugeBatch` entry, so both run the same checks.
   * @dev Sending is the caller's job: a send hands control to the refund address, so `allocate` must finish
   *      reading first. The stake is passed in, not read here, for the same reason.
   * @param _voterStorage Voter allocation state the allocation is validated and settled against
   * @param _input Everything the leg needs besides the gauge list
   * @param _gauges Per-gauge allocations, strictly ascending; may carry the `DEALLOC_GAUGE` sentinel
   * @return _dispatch Built `AllocateGauge` entry for this chain; the caller sends it
   */
  function _prepareGaugeAllocation(
    VoterStorage storage _voterStorage,
    GaugeAllocationInput memory _input,
    IVoterCommon.GaugeAllocation[] calldata _gauges
  ) private returns (IRootMessageOrchestrator.ChainDispatch memory _dispatch) {
    uint256 _chainId = _input.chainId;
    // Read-only alias: in a batch this buffer is shared by every leg, so mutating it here would change the
    // payload of every following chain.
    IVoter.AllocationSnapshot memory _snapshot = _input.snapshot;
    requireDispatchableChain(_voterStorage, _chainId, _input.gasLimit);

    // A withdrawn token (`staked == 0`) would ship a `{0, 0}` shape the leaf reads as permanent. It holds no
    // allocation anywhere, so this rejects it outright. The composed `allocate` path already reads a live
    // stake, so this only gates the standalone `allocateGauges`.
    if (_snapshot.staked == 0) revert IVoter.StakeWithdrawn();

    // Mirrors the leaf's budget check, so an over-allocated vote is rejected before dispatch.
    bool _hasDeallocSentinel =
      _validateGauges(_gauges, _voterStorage.allocationChainAmounts[_input.tokenId][_chainId], _chainId);

    // An expired stake can no longer back weight — the leaf books its entries at zero — and a sunset chain
    // takes no new placement, so in either case the only vote worth shipping is the lone sentinel return.
    // A live dispatch that expires in transit still lands as a zero-weight no-op on the leaf.
    bool _deallocOnly = _gauges.length == 1 && _hasDeallocSentinel;
    if (!_deallocOnly) {
      if (!_snapshot.isPermanent && _snapshot.stakeEnd <= block.timestamp) revert IVoterCommon.StakeExpired();
      if (isChainInStatus(_voterStorage, _chainId, IVoterCommon.ChainStatus.Sunset)) {
        revert IVoterCommon.SunsetDeallocOnly();
      }
    }

    // This path never re-anchors root's chain point, so a changed shape would desync leaf accrual from the
    // ceiling. Reconcile it first with an empty `allocateChains(_tokenId, [], _)`.
    {
      IVoter.TokenState memory _stored = _voterStorage.tokenStates[_input.tokenId];
      if (_shapeDiffers(_snapshot.stakeEnd, _snapshot.isPermanent, _stored.lastStakeEnd, _stored.isPermanent)) {
        revert IVoter.StaleShape();
      }
    }

    // Close the ceiling interval at the outgoing scalar before resampling the one the message ships.
    _settleChain(_voterStorage, _chainId);

    _dispatch = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _input.gasLimit,
      nativeValue: _input.value,
      chargeDeallocationReturn: _hasDeallocSentinel,
      payload: _buildGaugeMessage({
        _input: _input, _gauges: _gauges, _emissionsPerVP: _refreshEmissionsPerVP(_voterStorage, _snapshot.emissionRate)
      })
    });

    emit IVoter.GaugesAllocated(_input.tokenId, _chainId, _gauges);
  }

  /*//////////////////////////////////////////////////////////////
                        SETTLE / POINT MATH
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Swaps a chain's stored contribution to `(_newAllocated, _context.veStakeEnd)` and writes the new
   *         amount. A `_newAllocated` of 0 deletes the slot and drops the chain from the set.
   * @dev The only writer of chain bookings, the chain0 legs included. Keeps the invariant `chainId ∈
   *      _allocatedSet ⇔ allocationChainAmounts[_tokenId][chainId] > 0`, which the short-circuit below relies
   *      on; `burn` keeps that pairing by hand at its call site.
   * @param _voterStorage Voter allocation state the swap is applied to
   * @param _tokenId Token whose allocation is being mutated
   * @param _chainId Chain being swapped, `CHAIN0` included
   * @param _newAllocated New allocation amount; zero means removal
   * @param _context Per-tokenId snapshot supplying `oldStakeEnd` / `veStakeEnd`
   */
  function _applyChainAllocation(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    uint256 _chainId,
    uint128 _newAllocated,
    IVoter.AllocationContext memory _context
  ) private {
    EnumerableSet.UintSet storage _allocatedSet = _voterStorage.allocationChainIds[_tokenId];
    uint128 _prevAllocated = _voterStorage.allocationChainAmounts[_tokenId][_chainId];

    // Both legs swap at the same timestamp, so an unchanged `(allocated, shape)` yields triples that cancel and
    // a write that changes nothing.
    if (
      _prevAllocated == _newAllocated && _context.oldStakeEnd == _context.veStakeEnd
        && _context.oldIsPermanent == _context.veIsPermanent
    ) return;

    _swapContribution({
      _point: _voterStorage.chainStates[_chainId].point,
      _slopeChanges: _voterStorage.chainSlopeChanges[_chainId],
      _prev: _prevAllocated,
      _new: _newAllocated,
      _oldStakeEnd: _context.oldStakeEnd,
      _veStakeEnd: _context.veStakeEnd,
      _oldIsPermanent: _context.oldIsPermanent,
      _veIsPermanent: _context.veIsPermanent
    });

    // Mirror onto `totalPoint` so `Σ per-chain == totalPoint` holds by construction. An intra-token move
    // (origin −X here, `CHAIN0` +X in the sibling call) nets to zero up to `_contribution`'s slope-floor dust
    // (≤ 1 slope-unit, non-compounding, the same dust the leaf sees).
    _swapContribution({
      _point: _voterStorage.totalPoint,
      _slopeChanges: _voterStorage.totalSlopeChanges,
      _prev: _prevAllocated,
      _new: _newAllocated,
      _oldStakeEnd: _context.oldStakeEnd,
      _veStakeEnd: _context.veStakeEnd,
      _oldIsPermanent: _context.oldIsPermanent,
      _veIsPermanent: _context.veIsPermanent
    });

    if (_newAllocated == 0) {
      delete _voterStorage.allocationChainAmounts[_tokenId][_chainId];
      // slither-disable-next-line unused-return
      _allocatedSet.remove(_chainId);
    } else {
      _voterStorage.allocationChainAmounts[_tokenId][_chainId] = _newAllocated;
      // slither-disable-next-line unused-return
      _allocatedSet.add(_chainId);
    }
  }

  /**
   * @notice Brings a chain fully current: accrues its ceiling for the elapsed global-index delta and resolves
   *         its point to now.
   * @dev Run before mutating or reading a chain's weight. Every allocation entry calls it once per touched
   *      chain.
   * @dev With `Σ chainWeight == totalWeight`, `Σ ceilings` tracks the minter's schedule and bounds redeemable
   *      supply. Exact for permanent stakes. Under decay it lands under the schedule: segments accrue the exact
   *      integral of the weight, while `emissionsPerVP` holds the value sampled at the last resample and the
   *      true `emissionRate / totalWeight` climbs as the total decays away from it.
   * @dev `Suspended` and `Sunset` chains freeze the ceiling and route the accrual to
   *      `cumulativeSuspendedSurplus`; `Paused` chains accrue normally (the entrypoints reject them upstream).
   * @param _voterStorage Voter allocation state the settle is applied to
   * @param _chainId Chain to settle and resolve
   */
  function _settleChain(VoterStorage storage _voterStorage, uint256 _chainId) private {
    _settleGlobalIndex(_voterStorage);

    uint256 _index = _voterStorage.index;
    IVoter.ChainState storage _chainState = _voterStorage.chainStates[_chainId];
    uint256 _indexCursor = _chainState.lastIndex;
    if (_index == _indexCursor) {
      // Nothing to accrue, but the point still owes its decay. `timeIndex` moves in lockstep with `index`, so an
      // unchanged `index` means an unchanged `timeIndex` too.
      _resolveWeight(_chainState.point, _voterStorage.chainSlopeChanges[_chainId]);
      return;
    }

    uint256 _timeIndex = _voterStorage.timeIndex;
    uint256 _accrual = _walkCeiling({
      _voterStorage: _voterStorage,
      _chainId: _chainId,
      _chainState: _chainState,
      _index: _index,
      _indexCursor: _indexCursor,
      _timeIndex: _timeIndex,
      _timeIndexCursor: _chainState.lastTimeIndex
    });

    IVoterCommon.ChainStatus _status = _chainState.status;
    if (_status == IVoterCommon.ChainStatus.Suspended || _status == IVoterCommon.ChainStatus.Sunset) {
      // Would-be emissions go to surplus so they stay tracked rather than lost.
      _chainState.cumulativeSuspendedSurplus += _accrual;
    } else {
      _chainState.ceiling += _accrual;
    }
    _chainState.lastIndex = _index;
    _chainState.lastTimeIndex = _timeIndex;
  }

  /**
   * @notice Accrue a chain one segment per week boundary, decaying its point as it goes, and resolve the point.
   * @dev Root splits time at week boundaries like the leaf's gauge walk and prices each segment the same way
   *      (see `_segmentAccrual`), so the two agree however often either side is touched. A chain that accrues less
   *      than its leaf hands out cannot be reconciled: `LeafVoter.redeem` burns the receipt before dispatch.
   * @param _voterStorage Voter allocation state the boundary marks are read from.
   * @param _chainId Chain being settled.
   * @param _chainState Storage handle whose point this resolves to now.
   * @param _index Global `index` value to settle up to.
   * @param _indexCursor The chain's `index` cursor before this settle.
   * @param _timeIndex Global `timeIndex` value to settle up to.
   * @param _timeIndexCursor The chain's `timeIndex` cursor before this settle.
   * @return _accrual Emissions the chain earned over the walked segments.
   */
  function _walkCeiling(
    VoterStorage storage _voterStorage,
    uint256 _chainId,
    IVoter.ChainState storage _chainState,
    uint256 _index,
    uint256 _indexCursor,
    uint256 _timeIndex,
    uint256 _timeIndexCursor
  ) private returns (uint256 _accrual) {
    uint48 _now = uint48(block.timestamp);
    IVoterCommon.Point memory _point = _chainState.point;
    uint48 _cursor = _point.ts;

    uint48 _boundary = _nextWeekBoundary(_cursor);
    while (_boundary <= _now) {
      uint256 _boundaryIndex = _voterStorage.indexAtBoundary[_boundary];
      uint256 _boundaryTimeIndex = _voterStorage.timeIndexAtBoundary[_boundary];

      // Decay to the boundary, then price the segment: `_point.slope` is still the segment slope here, since its
      // reduction for the next segment applies only after.
      _point.bias = _max(_point.bias - _point.slope * int128(uint128(_boundary - _cursor)), 0);
      _accrual += _segmentAccrual({
        _endWeight: _weightOf(_point),
        _slope: _point.slope,
        _segmentEnd: _boundary,
        _indexDelta: _boundaryIndex - _indexCursor,
        _timeIndexDelta: _boundaryTimeIndex - _timeIndexCursor
      });

      _point.slope = _max(_point.slope - _voterStorage.chainSlopeChanges[_chainId][_boundary], 0);
      _indexCursor = _boundaryIndex;
      _timeIndexCursor = _boundaryTimeIndex;
      _cursor = _boundary;
      _boundary += WEEK;
    }

    // Trailing partial segment: the target is not a boundary, so no slope change applies.
    _point.bias = _max(_point.bias - _point.slope * int128(uint128(_now - _cursor)), 0);
    _accrual += _segmentAccrual({
      _endWeight: _weightOf(_point),
      _slope: _point.slope,
      _segmentEnd: _now,
      _indexDelta: _index - _indexCursor,
      _timeIndexDelta: _timeIndex - _timeIndexCursor
    });
    _point.ts = _now;

    _chainState.point = _point;
  }

  /**
   * @notice Advances the global emissions accumulators (`index`, `timeIndex`) to now at the scalar in effect
   *         over the elapsed interval.
   * @dev Does nothing when already advanced this block. Must run before `emissionsPerVP` is resampled or
   *      `totalWeight` changes, so the interval just closed integrates the scalar that governed it.
   * @param _voterStorage Voter allocation state the accumulators live in
   */
  function _settleGlobalIndex(VoterStorage storage _voterStorage) private {
    uint48 _now = uint48(block.timestamp);
    uint48 _cursor = _voterStorage.lastGlobalSettlement;
    if (_now <= _cursor) return;

    uint256 _index = _voterStorage.index;
    uint256 _timeIndex = _voterStorage.timeIndex;
    // `emissionsPerVP` is `PRECISION`-scaled; the scale is divided back out per chain in `_segmentAccrual`.
    uint256 _emissionsPerVP = _voterStorage.emissionsPerVP;

    // Bank both accumulators at every week boundary crossed. `index` sums the scalar; `timeIndex` sums it weighted
    // by the timestamp, doubled (∫2t·dt = t^2) so the halving defers to a single divide at accrual. Root and the
    // leaf weight by the same absolute time, so their rounded shares stay consistent. `_walkCeiling` reads the
    // marks to price each chain one segment per week.
    uint48 _boundary = _nextWeekBoundary(_cursor);
    while (_boundary <= _now) {
      _index += _emissionsPerVP * (_boundary - _cursor);
      _timeIndex += _emissionsPerVP * (_timestampSquared(_boundary) - _timestampSquared(_cursor));
      _voterStorage.indexAtBoundary[_boundary] = _index;
      _voterStorage.timeIndexAtBoundary[_boundary] = _timeIndex;
      _cursor = _boundary;
      _boundary += WEEK;
    }
    if (_now > _cursor) {
      _index += _emissionsPerVP * (_now - _cursor);
      _timeIndex += _emissionsPerVP * (_timestampSquared(_now) - _timestampSquared(_cursor));
    }

    _voterStorage.index = _index;
    _voterStorage.timeIndex = _timeIndex;
    _voterStorage.lastGlobalSettlement = _now;
  }

  /**
   * @notice Advances a `Point` to now by walking week boundaries.
   * @dev A caller that resolves a chain point must resolve `totalPoint` at the same timestamp before reading
   *      any chain's emissions scalar.
   * @param _point Storage reference to the point being resolved
   * @param _slopeChanges Slope schedule keyed by expiry that applies to `_point`
   */
  function _resolveWeight(
    IVoterCommon.Point storage _point,
    mapping(uint48 _expiry => int128 _slopeChange) storage _slopeChanges
  ) private {
    uint48 _ts = uint48(block.timestamp);
    // A `_ts` at or behind the stored timestamp must not walk `_point.ts` backwards.
    if (_point.ts >= _ts) return;
    IVoterCommon.Point memory _walked = _walkPoint(_point, _slopeChanges, _ts);
    _point.bias = _walked.bias;
    _point.slope = _walked.slope;
    _point.ts = _walked.ts;
    _point.permanentStakeBalance = _walked.permanentStakeBalance;
  }

  /**
   * @notice Negates the old `(_prev, _oldStakeEnd)` contribution and applies the new `(_new, _veStakeEnd)` one.
   * @dev Removing at `_oldStakeEnd` is what clears that expiry's scheduled slope change; the new contribution
   *      then schedules its own at `_veStakeEnd`. Applied by `_applyChainAllocation` to chain and total points.
   * @param _point Storage reference to the point being mutated
   * @param _slopeChanges Slope schedule keyed by expiry that applies to `_point`
   * @param _prev Prior amount tied to `_oldStakeEnd`
   * @param _new New amount tied to `_veStakeEnd`
   * @param _oldStakeEnd Stake expiry tied to the prior contribution
   * @param _veStakeEnd Stake expiry tied to the new contribution
   * @param _oldIsPermanent True when the prior contribution was permanent
   * @param _veIsPermanent True when the new contribution is permanent
   */
  function _swapContribution(
    IVoterCommon.Point storage _point,
    mapping(uint48 _expiry => int128 _slopeChange) storage _slopeChanges,
    uint128 _prev,
    uint128 _new,
    uint48 _oldStakeEnd,
    uint48 _veStakeEnd,
    bool _oldIsPermanent,
    bool _veIsPermanent
  ) private {
    // Clamp `_now` up to `_point.ts` so the swap cannot land before the resolved point.
    uint48 _now = uint48(block.timestamp);
    if (_now < _point.ts) _now = _point.ts;

    // 1. Remove the old contribution at its own expiry, clearing that expiry's slope change.
    {
      (int128 _bias, int128 _slope, int128 _permanent) = _contribution(_prev, _oldStakeEnd, _now, _oldIsPermanent);
      _applyContribution(_point, _slopeChanges, -_bias, -_slope, -_permanent, _oldStakeEnd, _oldIsPermanent);
    }
    // 2. Add the new contribution at the current expiry.
    {
      (int128 _bias, int128 _slope, int128 _permanent) = _contribution(_new, _veStakeEnd, _now, _veIsPermanent);
      _applyContribution(_point, _slopeChanges, _bias, _slope, _permanent, _veStakeEnd, _veIsPermanent);
    }
  }

  /**
   * @notice Applies a signed `(bias, slope, perm)` triple to a point and its slope schedule.
   * @dev Callers must build triples through `_contribution`: `_isPermanent` takes the permanent path (only
   *      `_perm` non-zero), otherwise the decay path (only `_bias`/`_slope`). The two are exclusive.
   * @dev `permanentStakeBalance` is uint128, so a negative `_perm` past the stored balance reverts on the
   *      checked subtraction.
   * @param _point Storage reference to the point being mutated
   * @param _slopeChanges Slope schedule keyed by expiry that applies to `_point`
   * @param _bias Signed bias delta, ignored on the permanent path
   * @param _slope Signed slope delta, ignored on the permanent path
   * @param _perm Signed permanent-balance delta, ignored on the decay path
   * @param _stakeEnd Boundary the slope reduction is scheduled at on the decay path
   * @param _isPermanent True selects the permanent path
   */
  function _applyContribution(
    IVoterCommon.Point storage _point,
    mapping(uint48 _expiry => int128 _slopeChange) storage _slopeChanges,
    int128 _bias,
    int128 _slope,
    int128 _perm,
    uint48 _stakeEnd,
    bool _isPermanent
  ) private {
    if (_isPermanent) {
      if (_perm > 0) _point.permanentStakeBalance += uint128(_perm);
      else if (_perm < 0) _point.permanentStakeBalance -= uint128(-_perm);
    } else {
      _point.bias += _bias;
      _point.slope += _slope;
      _slopeChanges[_stakeEnd] += _slope;
    }
  }

  /**
   * @notice `_refreshEmissionsPerVP` against a rate read from the Minter here, at the resample itself.
   * @dev For the chain0 paths that carry no allocation snapshot. Reading here rather than at the entrypoint
   *      keeps the call off the paths that return before resampling, which therefore reach no external code.
   * @dev Every path that moves `totalWeight` calls this or the `uint256` overload after its mutations, so the
   *      stored scalar governs the next interval and no chain accrues at a stale rate.
   * @param _voterStorage Voter allocation state the scalar is stored in
   * @param _minter Minter the emission rate is read from
   * @return _emissionsPerVP Global emissions per unit voting power at now
   */
  function _refreshEmissionsPerVP(
    VoterStorage storage _voterStorage,
    IMinter _minter
  ) private returns (uint256 _emissionsPerVP) {
    _emissionsPerVP = _refreshEmissionsPerVP(_voterStorage, _minter.emissionRate());
  }

  /**
   * @notice Advances both global accumulators at the outgoing scalar, then resamples and stores
   *         `emissionsPerVP` against the current total weight.
   * @dev `PRECISION`-scaled `minterRate * PRECISION / totalWeight`, or `0` when the total weight is zero. The
   *      allocation entrypoints read `MINTER.emissionRate()` once in the Voter and thread it through, so one
   *      call prices every payload with the same rate.
   * @dev Snapshot-carrying legs must keep passing that pre-read rate here instead of calling the `IMinter`
   *      overload: re-reading per leg would let a reentrant caller split it across two rates.
   * @param _voterStorage Voter allocation state the scalar is stored in
   * @param _emissionRate Emission rate read once by the caller
   * @return _emissionsPerVP Global emissions per unit voting power at now
   */
  function _refreshEmissionsPerVP(
    VoterStorage storage _voterStorage,
    uint256 _emissionRate
  ) private returns (uint256 _emissionsPerVP) {
    _settleGlobalIndex(_voterStorage);
    _resolveWeight(_voterStorage.totalPoint, _voterStorage.totalSlopeChanges);
    uint128 _totalWeight = _weightOf(_voterStorage.totalPoint);
    _emissionsPerVP = _totalWeight == 0 ? 0 : Math.mulDiv(_emissionRate, PRECISION, _totalWeight);
    _voterStorage.emissionsPerVP = _emissionsPerVP;
  }

  /*//////////////////////////////////////////////////////////////
                        VIEW / PURE HELPERS
  //////////////////////////////////////////////////////////////*/

  // Helpers are ordered view before pure, so the sub-headers below mark where each theme falls.

  /* ---------- Validation and dispatch builders ---------- */

  /**
   * @notice Validates caller-supplied chain allocations in one pass and returns the total delta.
   * @dev Reverts `AllocationsNotStrictlyAscending` on duplicate, unsorted or `CHAIN0` entries,
   *      `ChainNotActive` unless the chain is registered and `Active`, and
   *      `MissingDestinationGasLimit` when a non-root entry carries no gas budget.
   * @param _voterStorage Voter allocation state the chains are validated against
   * @param _allocations Caller-supplied per-chain allocations
   * @return _totalDelta Σ `delta` across all chains, later bounded by `chain0Parked`
   */
  function _validateAllocations(
    VoterStorage storage _voterStorage,
    IVoter.ChainAllocationDispatch[] calldata _allocations
  ) private view returns (uint128 _totalDelta) {
    // slither-disable-next-line uninitialized-local
    uint256 _prevChainId;
    uint256 _length = _allocations.length;
    for (uint256 _i; _i < _length; ++_i) {
      IVoter.ChainAllocationDispatch calldata _allocation = _allocations[_i];

      // Strict ascending also rejects CHAIN0 (id 0) and duplicates.
      uint256 _chainId = _allocation.chainId;
      if (_chainId <= _prevChainId) revert IVoter.AllocationsNotStrictlyAscending();

      requireChainActive(_voterStorage, _chainId);
      requireDestinationGas(_chainId, _allocation.gasLimit);

      // `delta == 0` is an allowed shape refresh.
      _totalDelta += _allocation.delta;

      _prevChainId = _chainId;
    }
  }

  /**
   * @notice Builds the per-chain dispatches with their `AllocateChainMessage` payloads. Sends nothing.
   * @dev Payloads come from the snapshot and the already-written local state, so nothing is read after the
   *      first send. Ships each chain's `delta`, not the absolute; the leaf applies it additively.
   * @param _voterStorage Voter allocation state the payload scalar is read from
   * @param _tokenId Originating tokenId
   * @param _context Per-tokenId snapshot supplying the shape shipped to every leaf
   * @param _allocations Caller chain allocations, strictly ascending by `chainId` and `CHAIN0`-free
   * @return _dispatches One entry per listed chain, ready to hand to the orchestrator
   */
  function _buildChainAllocations(
    VoterStorage storage _voterStorage,
    uint256 _tokenId,
    IVoter.AllocationContext memory _context,
    IVoter.ChainAllocationDispatch[] calldata _allocations
  ) private view returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    uint256 _length = _allocations.length;

    uint256 _emissionsPerVP = _voterStorage.emissionsPerVP;

    // Live VE shape, the same for every chain. A leaf seeds `tokenSnapshot` from it only before its first gauge
    // distribution, so a local `allocateGauges` distributes against the true shape.
    IVoterCommon.TokenSnapshot memory _snapshot = IVoterCommon.TokenSnapshot({
      staked: _context.veStaked, stakeEnd: _context.veStakeEnd, isPermanent: _context.veIsPermanent
    });

    _dispatches = new IRootMessageOrchestrator.ChainDispatch[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      IVoter.ChainAllocationDispatch calldata _allocation = _allocations[_i];
      // The orchestrator stamps `chainNonce` and wraps this in the typed envelope.
      _dispatches[_i] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _allocation.chainId,
        gasLimit: _allocation.gasLimit,
        nativeValue: _allocation.value,
        chargeDeallocationReturn: false,
        payload: abi.encode(
          IVoterCommon.AllocateChainMessage({
            tokenId: _tokenId, allocationDelta: _allocation.delta, emissionsPerVP: _emissionsPerVP, snapshot: _snapshot
          })
        )
      });
    }
  }

  /**
   * @notice Builds the `AllocateGauge` message body for a tokenId's gauge list on one chain.
   * @dev Carries the stake snapshot (the leaf reshapes each gauge locally), an absolute expiry for the leaf's
   *      max-age gate, and the global scalar. The snapshot is passed in so the caller reads the stake once.
   * @param _input Leg inputs supplying the tokenId, the message lifetime and the stake snapshot
   * @param _gauges Per-gauge allocations on the destination chain
   * @param _emissionsPerVP Global emissions-per-VP scalar at dispatch
   * @return _payload Abi-encoded `AllocateGaugeMessage` body
   */
  function _buildGaugeMessage(
    GaugeAllocationInput memory _input,
    IVoterCommon.GaugeAllocation[] calldata _gauges,
    uint256 _emissionsPerVP
  ) private view returns (bytes memory _payload) {
    _payload = abi.encode(
      IVoterCommon.AllocateGaugeMessage({
        tokenId: _input.tokenId,
        expiry: uint48(block.timestamp) + _input.allocationLifetime,
        emissionsPerVP: _emissionsPerVP,
        tokenSnapshot: IVoterCommon.TokenSnapshot({
          staked: _input.snapshot.staked, stakeEnd: _input.snapshot.stakeEnd, isPermanent: _input.snapshot.isPermanent
        }),
        allocations: _gauges
      })
    );
  }

  /* ---------- Point walk ---------- */

  /**
   * @notice Walks a point forward to `_ts`, decaying bias and firing scheduled slope reductions at each week
   *         boundary in `(point.ts, _ts]`.
   * @dev Slope changes fire at Unix-epoch-aligned week boundaries, matching the keys VE uses for `stakeEnd`.
   * @param _point Snapshot to walk
   * @param _slopeChanges Slope schedule keyed by expiry
   * @param _ts Timestamp to walk the point to
   * @return _walked Point resolved to `_ts`
   */
  function _walkPoint(
    IVoterCommon.Point memory _point,
    mapping(uint48 _expiry => int128 _slopeChange) storage _slopeChanges,
    uint48 _ts
  ) private view returns (IVoterCommon.Point memory _walked) {
    int128 _bias = _point.bias;
    int128 _slope = _point.slope;
    uint48 _cursor = _point.ts;
    uint48 _nextExpiry = _nextWeekBoundary(_cursor);

    while (_nextExpiry <= _ts) {
      int128 _decay = _slope * int128(uint128(_nextExpiry - _cursor));
      _bias = _max(_bias - _decay, 0);
      _slope = _max(_slope - _slopeChanges[_nextExpiry], 0);
      _cursor = _nextExpiry;
      _nextExpiry += WEEK;
    }

    if (_ts > _cursor) _bias = _max(_bias - _slope * int128(uint128(_ts - _cursor)), 0);

    _walked =
      IVoterCommon.Point({bias: _bias, slope: _slope, ts: _ts, permanentStakeBalance: _point.permanentStakeBalance});
  }

  /* ---------- Shape and gauge validation ---------- */

  /**
   * @notice Build a same-shape `AllocationContext`: both the old and live stake shape are `(_stakeEnd,
   *         _isPermanent)`.
   * @dev Used where a position is repriced at its recorded shape so only the amount moves (the chain0 swap
   *      helpers and `creditDeallocation`). `veStaked`/`prevCommitted` are zero: `_applyChainAllocation` reads
   *      only the shape fields on these same-shape paths.
   * @param _stakeEnd Stake expiry shared by both legs; `0` for a permanent stake.
   * @param _isPermanent Permanence flag shared by both legs.
   * @return _context Context carrying the shape as both the old and live shape.
   */
  function _sameShapeContext(
    uint48 _stakeEnd,
    bool _isPermanent
  ) private pure returns (IVoter.AllocationContext memory _context) {
    _context = IVoter.AllocationContext({
      veStaked: 0,
      prevCommitted: 0,
      veStakeEnd: _stakeEnd,
      oldStakeEnd: _stakeEnd,
      veIsPermanent: _isPermanent,
      oldIsPermanent: _isPermanent
    });
  }

  /**
   * @notice Validates a gauge list in one pass and requires its total to equal the tokenId's booked chain
   *         allocation.
   * @dev Reverts `GaugesNotStrictlyAscending` on out-of-order or duplicate gauges, `ZeroAllocation` on a zero
   *      amount, and `ChainAllocationMismatch` unless Σ `allocated` equals `_chainAllocation`, mirroring the
   *      leaf's budget check. An empty list is valid and clears the tokenId's gauge weight.
   * @dev `data` is unbounded: it goes to the leaf's reward hook, so an oversized payload only costs the caller
   *      more transport.
   * @param _gauges Caller-supplied per-gauge allocations for one chain
   * @param _chainAllocation AERO amount the tokenId has booked on the destination chain
   * @param _chainId Destination chain, carried into the revert for context
   * @return _hasDeallocSentinel True when the list carries the `DEALLOC_GAUGE` sentinel
   */
  function _validateGauges(
    IVoterCommon.GaugeAllocation[] calldata _gauges,
    uint128 _chainAllocation,
    uint256 _chainId
  ) private pure returns (bool _hasDeallocSentinel) {
    // slither-disable-next-line uninitialized-local
    address _prevGauge;
    // slither-disable-next-line uninitialized-local
    uint128 _total;
    uint256 _gaugesLen = _gauges.length;
    for (uint256 _i; _i < _gaugesLen; ++_i) {
      IVoterCommon.GaugeAllocation calldata _gaugeAlloc = _gauges[_i];
      address _gauge = _gaugeAlloc.gauge;
      // `ZERO_GAUGE` (address(0)), the idle-park sink, is allowed as the first entry: still the lowest
      // address, so the list stays sorted for the leaf's binary search.
      if (_i != 0 && _gauge <= _prevGauge) revert IVoterCommon.GaugesNotStrictlyAscending();
      if (_gaugeAlloc.allocated == 0) revert IVoterCommon.ZeroAllocation();
      if (_gauge == DEALLOC_GAUGE) _hasDeallocSentinel = true;
      _total += _gaugeAlloc.allocated;
      _prevGauge = _gauge;
    }
    // Exact match: idle VP must be an explicit `ZERO_GAUGE` entry, never an automatic backfill.
    if (_total != _chainAllocation) revert IVoter.ChainAllocationMismatch(_chainId);
  }

  /* ---------- Point, time and shape math ---------- */

  /**
   * @notice Emissions a segment earns, exact (to rounding) for a linear weight against a piecewise-constant
   *         scalar.
   * @dev Prices the end weight against the plain accumulator and adds back the weight the segment held before
   *      decaying, from the time-weighted accumulator: `accrual = (endWeight * indexDelta + slope * addBack / 2)
   *      / PRECISION`, with `addBack = 2 * segmentEnd * indexDelta - timeIndexDelta = 2 * ∫(segmentEnd - t) *
   *      scalar dt >= 0` (`timeIndexDelta` is doubled, folding its halving into the divide). Exact for any
   *      intra-segment scalar path, so root and leaf agree however often each settles. Both terms are floored and
   *      summed with no clamp, so `Σ` per-gauge leaf shares never rounds above the chain segment (floor is
   *      sub-additive). `mulDiv` keeps both overflow-safe.
   * @param _endWeight Chain weight at the segment end.
   * @param _slope Decay slope in effect over the segment; `0` for a permanent stake.
   * @param _segmentEnd Segment end timestamp.
   * @param _indexDelta Growth of `index` over the segment.
   * @param _timeIndexDelta Growth of `timeIndex` (doubled, time-weighted) over the segment.
   * @return _accrual Emissions earned, with the scale divided back out.
   */
  function _segmentAccrual(
    uint128 _endWeight,
    int128 _slope,
    uint48 _segmentEnd,
    uint256 _indexDelta,
    uint256 _timeIndexDelta
  ) private pure returns (uint256 _accrual) {
    // A negative slope would be a desynced point; treat it as no decay rather than a huge magnitude.
    uint256 _slopeMagnitude = _slope > 0 ? uint256(uint128(_slope)) : 0;
    // End weight against the plain accumulator, plus the decay add-back when the segment decays; a permanent
    // stake (`slope == 0`) skips the second term.
    _accrual = Math.mulDiv(_endWeight, _indexDelta, PRECISION);
    if (_slopeMagnitude != 0) {
      // 2 * ∫(segmentEnd - t) * scalar dt >= 0.
      uint256 _addBack = 2 * uint256(_segmentEnd) * _indexDelta - _timeIndexDelta;
      _accrual += Math.mulDiv(_slopeMagnitude, _addBack, 2 * PRECISION);
    }
  }

  /**
   * @notice The timestamp squared, widened first. The absolute (unix-epoch) origin is shared by root and leaf, so
   *         their rounded accruals stay consistent.
   * @param _timestamp Timestamp to square.
   * @return _squared `_timestamp^2`.
   */
  function _timestampSquared(uint48 _timestamp) private pure returns (uint256 _squared) {
    _squared = uint256(_timestamp) * _timestamp;
  }

  /**
   * @notice First week boundary strictly after `_timestamp`.
   * @param _timestamp Cursor to advance from.
   * @return _boundary Week-aligned timestamp.
   */
  function _nextWeekBoundary(uint48 _timestamp) private pure returns (uint48 _boundary) {
    _boundary = (_timestamp / WEEK + 1) * WEEK;
  }

  /**
   * @notice Absolute weight of a resolved point: `permanentStakeBalance + max(0, bias)`.
   * @dev Negative bias clamps to zero, so a fully decayed point contributes only its permanent balance. Both
   *      summands are bounded by AERO supply; a sum over `uint128.max` reverts on the checked addition.
   * @param _point Point read as-is; the caller must `_resolveWeight` first, this does no slope walk
   * @return _weight Absolute weight
   */
  function _weightOf(IVoterCommon.Point memory _point) private pure returns (uint128 _weight) {
    _weight = _point.permanentStakeBalance;
    if (_point.bias > 0) _weight += uint128(_point.bias);
  }

  /**
   * @notice Derives the signed `(bias, slope, perm)` contribution of an AERO allocation.
   * @dev `_isPermanent` takes the permanent path. Otherwise `_stakeEnd <= _timestamp` returns the zero triple:
   *      the resolve walk already fired the scheduled slope reduction, so a removal cannot over-subtract.
   * @dev `_slope = _allocated / MAXTIME` truncates, so allocations below `MAXTIME` wei (≈1.26e-10 AERO) round
   *      to zero weight while still using storage and a dispatch. The floor matches Curve VE math.
   * @param _allocated AERO amount allocated to a chain
   * @param _stakeEnd Stake expiry; `0` for a permanent stake
   * @param _timestamp Time the contribution is evaluated at
   * @param _isPermanent True for a permanent stake
   * @return _bias Time-decaying contribution
   * @return _slope Decay rate contribution
   * @return _perm Non-decaying contribution from permanent stakes
   */
  function _contribution(
    uint128 _allocated,
    uint48 _stakeEnd,
    uint48 _timestamp,
    bool _isPermanent
  ) private pure returns (int128 _bias, int128 _slope, int128 _perm) {
    if (_isPermanent) {
      _perm = SafeCastLibrary.toInt128(_allocated);
      return (_bias, _slope, _perm);
    }
    if (_stakeEnd <= _timestamp) return (_bias, _slope, _perm);

    _slope = SafeCastLibrary.toInt128(_allocated / MAXTIME);
    _bias = _slope * int128(uint128(_stakeEnd - _timestamp));
  }

  /**
   * @notice Whether two stake shapes differ. A shape is the `(stakeEnd, isPermanent)` pair, and any allocation
   *         that spans two shapes must re-anchor or reject; keeping the comparison here stops the two-field
   *         check from drifting across its call sites.
   * @param _stakeEndA First shape's stake expiry.
   * @param _isPermanentA First shape's permanence flag.
   * @param _stakeEndB Second shape's stake expiry.
   * @param _isPermanentB Second shape's permanence flag.
   * @return _differs True when the two shapes are not identical.
   */
  function _shapeDiffers(
    uint48 _stakeEndA,
    bool _isPermanentA,
    uint48 _stakeEndB,
    bool _isPermanentB
  ) private pure returns (bool _differs) {
    _differs = _stakeEndA != _stakeEndB || _isPermanentA != _isPermanentB;
  }

  /**
   * @notice Signed `int128` max, used to floor decayed bias and slope at zero.
   * @param _a First operand
   * @param _b Second operand
   * @return _greater Larger of the two values
   */
  function _max(int128 _a, int128 _b) private pure returns (int128 _greater) {
    _greater = _a > _b ? _a : _b;
  }
}
