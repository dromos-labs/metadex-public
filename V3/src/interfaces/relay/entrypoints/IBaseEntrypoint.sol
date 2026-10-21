// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';

/// @title  IBaseEntrypoint
/// @notice Shared surface for every entrypoint: the keeper-supplied swap parameters, the errors the
///         common skeleton can revert with, the sweep back to the Relay, and the factory registry and
///         Relay getters.
interface IBaseEntrypoint {
  /// @notice One swap request from the keeper. The output recipient is encoded inside `commands`
  ///         (always the entrypoint); it is not a field here.
  /// @param router MetaRouter to run the swap on; must be approved on the factory registry.
  /// @param tokenIn Reward token pulled from the Relay and swapped.
  /// @param amountIn Amount of `tokenIn` to pull and swap.
  /// @param minAmountOut Minimum output that must land on the entrypoint; must be non-zero.
  /// @param deadline Timestamp after which the MetaRouter rejects the batch.
  /// @param commands Packed MetaRouter opcodes.
  /// @param inputs ABI-encoded MetaRouter arguments, one per command.
  struct SwapParams {
    address router;
    address tokenIn;
    uint256 amountIn;
    uint256 minAmountOut;
    uint256 deadline;
    bytes commands;
    bytes[] inputs;
  }

  /// @notice Emitted when a keeper swap lands and its output is forwarded to the Relay.
  /// @param relay Relay the swap ran for.
  /// @param router MetaRouter the keeper named.
  /// @param tokenIn Token pulled from the Relay and sold.
  /// @param amountIn Amount of `tokenIn` pulled.
  /// @param tokenOut Token the output is measured in.
  /// @param minAmountOut Floor the keeper named.
  /// @param amountOut Output measured on the entrypoint and forwarded to the Relay.
  event Swapped(
    address indexed relay,
    address indexed router,
    address indexed tokenIn,
    uint256 amountIn,
    address tokenOut,
    uint256 minAmountOut,
    uint256 amountOut
  );

  /// @notice Emitted when a token balance held here is sent back to the Relay.
  /// @param token Token sent.
  /// @param amount Amount sent.
  event SweptToRelay(address indexed token, uint256 amount);

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

  /// @notice Sends this contract's whole balance of each token to the Relay. Keeper only.
  /// @dev A swap route can leave a token here, such as an intermediate hop token.
  /// @param _tokens Tokens to send back.
  function sweepToRelay(address[] calldata _tokens) external;

  /// @notice The protocol registry that says which MetaRouters a swap may run on.
  /// @return The factory registry contract.
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry);

  /// @notice The only Relay this entrypoint serves.
  /// @return _relay The bound Relay.
  function RELAY() external view returns (IRelayEntrypoint _relay);
}
