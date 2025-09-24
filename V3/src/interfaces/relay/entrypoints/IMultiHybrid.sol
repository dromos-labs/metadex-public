// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {IMultiConverter} from 'V3/interfaces/relay/entrypoints/IMultiConverter.sol';

/// @title  IMultiHybrid
/// @notice Hybrid bound to one Relay, holding both COMPOUNDER and CONVERTER, where the keeper picks a
///         side per call. The target set, the excluded set and the compound weight are all mutable and
///         gated by the bound Relay's L2 admin. Protocol L2 only.
interface IMultiHybrid is ICompounder, IMultiConverter {
  /// @notice Emitted when the intended compound weight changes.
  /// @param compoundWeight New compound weight in pips (data-availability only).
  event CompoundWeightSet(uint256 compoundWeight);

  /// @notice Updates the intended compound weight. Informational only, not enforced on-chain.
  /// @param _compoundWeight New compound share in pips.
  function setCompoundWeight(uint256 _compoundWeight) external;

  /// @notice Intended share (pips) of rewards routed to the compound side; off-chain enforced.
  /// @return _weight The compound weight in pips.
  function compoundWeight() external view returns (uint256 _weight);
}
