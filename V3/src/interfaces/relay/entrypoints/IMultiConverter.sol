// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @title  IMultiConverter
/// @notice Converter bound to one Relay, converting rewards into any token in its mutable target set.
///         Protocol L2 only: mutable configuration would break what Maxi and L1 promise depositors.
interface IMultiConverter is IBaseEntrypoint, IMultiEntrypoint {
  /// @notice Pull a reward token, swap it to a configured `_targetToken`, then notify the accumulator.
  /// @param _params Keeper-supplied swap request; `tokenIn` is the reward and must not be excluded.
  /// @param _targetToken Conversion target, from the configured target set.
  function swapAndConvert(SwapParams calldata _params, address _targetToken) external;

  /// @notice Notify the bound Relay's idle balance of a configured target token, with no swap.
  /// @param _relay Relay whose idle target-token balance is distributed.
  /// @param _targetToken Token to distribute, from the configured target set.
  function convertIdleBalance(address _relay, address _targetToken) external;
}
