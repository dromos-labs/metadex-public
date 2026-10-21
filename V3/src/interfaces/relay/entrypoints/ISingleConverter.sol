// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @title  ISingleConverter
/// @notice Entrypoint that converts a reward into one fixed target token and notifies the Relay's
///         idle balance of it to the accumulator. Holds CONVERTER on the Relay; the target is set at deploy, so a
///         different target means a fresh deployment.
interface ISingleConverter is IBaseEntrypoint {
  /// @notice Pull a reward token, swap it to `TARGET_TOKEN`, then notify the Relay's idle
  ///         `TARGET_TOKEN` to the accumulator.
  /// @param _params Keeper-supplied swap request; `tokenIn` is the reward, the output is TARGET_TOKEN.
  function swapAndConvert(SwapParams calldata _params) external;

  /// @notice Notify the Relay's idle `TARGET_TOKEN` to the accumulator, with no swap.
  function convertIdleBalance() external;

  /// @notice The single fixed token that all rewards are converted into and then distributed.
  /// @return _token The target token address.
  function TARGET_TOKEN() external view returns (address _token);
}
