// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @notice The LeafVoter's whole storage section, grouped in one struct so a library entry takes a single
 *         storage reference. `LeafVoterStorageBase` declares the only instance; `LeafAllocationLibrary` operates on it.
 * @dev Field order matches the V3 LeafVoter's original variable layout; reordering fields moves deployed state.
 * @param emissionsPerVP Emissions per unit voting power for this chain, `PRECISION`-scaled.
 * @param index Chain emissions accumulator (`∫ emissionsPerVP·dt`, `PRECISION`-scaled).
 * @param timeIndex Chain time-weighted emissions accumulator (doubled, `PRECISION`-scaled).
 * @param lastSettlement Timestamp the chain accumulators were last advanced to.
 * @param indexAtBoundary Value of `index` at each week boundary the chain settle has crossed.
 * @param timeIndexAtBoundary Value of `timeIndex` at each week boundary the chain settle has crossed.
 * @param gaugeStates Per-gauge settlement state.
 * @param gaugeSlopeChanges Scheduled slope reductions keyed by stake expiry, per gauge.
 * @param tokenStates Packed per-tokenId allocation state.
 * @param tokenSnapshot Shape the token's booked gauge weight is measured with.
 * @param accumulatedCooldownReduction Pending one-shot cooldown reduction per tokenId.
 * @param allocations Per-`(tokenId, effective gauge)` allocated weight.
 * @param allocatedGauges Gauges each tokenId has weight on, read through the `allocatedGauges` getter.
 *                        `ZERO_GAUGE` is never a member; weight redirected to the idle sink is tracked in
 *                        `allocations` alone.
 * @param surplusAccrued Cumulative AERO on this chain that will not be redeemed; only ever increases.
 * @param chainStatus Lifecycle status of this chain, mirrored from root.
 * @param localVotingEnabled Whether the local `allocateGauges` path is open.
 * @param allocationCooldown Minimum seconds between gauge allocations for a tokenId.
 * @param maxAccumulatedCooldownReduction Clamp on the reduction a tokenId can accumulate.
 * @param maxGauges Per-chain cap on the gauges a tokenId may allocate to.
 * @param latestTokenSnapshot Newest root-dispatched `TokenSnapshot` per tokenId, applied or not.
 */
struct LeafStorage {
  uint256 emissionsPerVP;
  uint256 index;
  uint256 timeIndex;
  uint48 lastSettlement;
  mapping(uint48 _boundary => uint256 _indexSnapshot) indexAtBoundary;
  mapping(uint48 _boundary => uint256 _timeIndexSnapshot) timeIndexAtBoundary;
  mapping(address _gauge => ILeafVoter.GaugeState _state) gaugeStates;
  mapping(address _gauge => mapping(uint48 _expiry => int128 _slopeDelta)) gaugeSlopeChanges;
  mapping(uint256 _tokenId => ILeafVoter.TokenState _state) tokenStates;
  mapping(uint256 _tokenId => IVoterCommon.TokenSnapshot _snapshot) tokenSnapshot;
  mapping(uint256 _tokenId => uint48 _reduction) accumulatedCooldownReduction;
  mapping(uint256 _tokenId => mapping(address _gauge => uint128 _allocated)) allocations;
  mapping(uint256 _tokenId => EnumerableSet.AddressSet _gauges) allocatedGauges;
  uint256 surplusAccrued;
  IVoterCommon.ChainStatus chainStatus;
  bool localVotingEnabled;
  uint48 allocationCooldown;
  uint48 maxAccumulatedCooldownReduction;
  uint256 maxGauges;
  mapping(uint256 _tokenId => IVoterCommon.TokenSnapshot _snapshot) latestTokenSnapshot;
}
