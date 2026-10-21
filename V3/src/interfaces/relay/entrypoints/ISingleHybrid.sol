// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';

/// @title  ISingleHybrid
/// @notice Entrypoint holding both COMPOUNDER and CONVERTER, where the keeper picks a side per call.
///         The target token and the compound weight are both set at deploy.
interface ISingleHybrid is ICompounder, ISingleConverter {
  /// @notice Intended share (pips) of rewards routed to the compound side. Data-availability only:
  ///         the split is applied off-chain by how the keeper sizes each `amountIn`.
  /// @return _weight The compound weight in pips.
  function COMPOUND_WEIGHT() external view returns (uint256 _weight);
}
