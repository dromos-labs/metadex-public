// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

/**
 * @notice The Voter's whole storage section, grouped in one struct so a library entry takes a single storage
 *         reference. `VoterStorageBase` declares the only instance; `AllocationLogicLibrary` operates on it.
 * @dev Field order matches the V3 Voter's original variable layout; reordering fields moves deployed state.
 * @param allocationChainIds Chains each token has allocated on; paired with `allocationChainAmounts`.
 * @param allocationChainAmounts Allocated AERO per `(tokenId, chainId)`.
 * @param tokenStates Per-tokenId record captured on every `allocateChains`.
 * @param chainStates Per-chain state: point, ceiling, redeem and surplus accounting, cursors, buffer, status.
 * @param chainSlopeChanges Scheduled slope reductions keyed by stake expiry, per chain.
 * @param emergencyDeallocationAllowed Voter-gated emergency-deallocation flags; the library never reads it.
 * @param totalPoint Aggregate voting power across all chains.
 * @param totalSlopeChanges Scheduled slope reductions keyed by stake expiry, aggregated across chains.
 * @param index Global emissions accumulator (`∫ emissionsPerVP·dt`, `PRECISION`-scaled).
 * @param timeIndex Global time-weighted emissions accumulator (doubled, `PRECISION`-scaled).
 * @param emissionsPerVP Global emissions per unit voting power, `PRECISION`-scaled.
 * @param lastGlobalSettlement Timestamp the global accumulators were last advanced to.
 * @param indexAtBoundary Value of `index` at each week boundary the global settle has crossed.
 * @param timeIndexAtBoundary Value of `timeIndex` at each week boundary the global settle has crossed.
 * @param chains All chains registered in the protocol.
 * @param allocationLifetime Voter-gated gauge-dispatch lifetime; the library takes the value as a parameter instead.
 * @param messageLifetime Voter-gated claim/operator-dispatch lifetime; threaded the same way.
 */
struct VoterStorage {
  mapping(uint256 _tokenId => EnumerableSet.UintSet _chainIds) allocationChainIds;
  mapping(uint256 _tokenId => mapping(uint256 _chainId => uint128 _allocated)) allocationChainAmounts;
  mapping(uint256 _tokenId => IVoter.TokenState _state) tokenStates;
  mapping(uint256 _chainId => IVoter.ChainState _state) chainStates;
  mapping(uint256 _chainId => mapping(uint48 _expiry => int128 _slopeChange)) chainSlopeChanges;
  mapping(uint256 _chainId => bool _allowed) emergencyDeallocationAllowed;
  IVoterCommon.Point totalPoint;
  mapping(uint48 _expiry => int128 _slopeChange) totalSlopeChanges;
  uint256 index;
  uint256 timeIndex;
  uint256 emissionsPerVP;
  uint48 lastGlobalSettlement;
  mapping(uint48 _boundary => uint256 _index) indexAtBoundary;
  mapping(uint48 _boundary => uint256 _timeIndex) timeIndexAtBoundary;
  EnumerableSet.UintSet chains;
  uint48 allocationLifetime;
  uint48 messageLifetime;
}
