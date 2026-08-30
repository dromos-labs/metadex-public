// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @title  ICompounder
/// @notice Entrypoint that turns a reward into the Relay's TOKEN and stakes it, growing the backing
///         so every share appreciates. Holds COMPOUNDER on the Relay; available on every tier.
interface ICompounder is IBaseEntrypoint {
  /// @notice Pull a reward token, swap it to the Relay's TOKEN, then compound the output.
  /// @param _params Keeper-supplied swap request; `tokenIn` is the reward, the output is TOKEN.
  function swapAndCompound(SwapParams calldata _params) external;

  /// @notice Compound the Relay's idle TOKEN, with no swap.
  /// @param _relay Relay whose idle TOKEN is compounded.
  function compoundIdleBalance(address _relay) external;
}
