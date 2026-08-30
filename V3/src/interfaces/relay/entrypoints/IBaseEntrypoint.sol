// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';

/// @title  IBaseEntrypoint
/// @notice Shared surface for every entrypoint: the keeper-supplied swap parameters, the errors the
///         common skeleton can revert with, and the factory registry getter.
interface IBaseEntrypoint {
  /// @notice One swap request from the keeper. The output recipient is encoded inside `commands`
  ///         (always the entrypoint); it is not a field here.
  /// @param relay The Relay to pull from and forward the output to.
  /// @param router MetaRouter to run the swap on; must be approved on the factory registry.
  /// @param tokenIn Reward token pulled from the Relay and swapped.
  /// @param amountIn Amount of `tokenIn` to pull and swap.
  /// @param minAmountOut Minimum output that must land on the entrypoint; must be non-zero.
  /// @param deadline Timestamp after which the MetaRouter rejects the batch.
  /// @param commands Packed MetaRouter opcodes.
  /// @param inputs ABI-encoded MetaRouter arguments, one per command.
  struct SwapParams {
    address relay;
    address router;
    address tokenIn;
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 deadline;
    bytes commands;
    bytes[] inputs;
  }

  /// @notice Thrown when the caller does not hold KEEPER on the target Relay.
  error NotKeeper();

  /// @notice Thrown when `minAmountOut` is zero (a misrouted swap could otherwise pass with delta 0).
  error ZeroMinOut();

  /// @notice Thrown when the output that landed on the entrypoint is below `minAmountOut`.
  error InsufficientOutput();

  /// @notice Thrown when a zero address is supplied where a non-zero one is required (e.g. constructor).
  error ZeroAddress();

  /// @notice Thrown when `tokenIn` equals the swap's output token, which would skew the delta measure.
  error SameToken();

  /// @notice Thrown when a Hybrid's compound weight exceeds MAX_PIPS (1_000_000).
  error InvalidCompoundWeight();

  /// @notice Thrown when an idle-balance path finds nothing unaccounted to process.
  error NoIdleBalance();

  /// @notice Thrown when the supplied router is not in the registry's approval set.
  error RouterNotApproved();

  /// @notice The protocol registry that says which MetaRouters a swap may run on.
  /// @return The factory registry contract.
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry);
}
