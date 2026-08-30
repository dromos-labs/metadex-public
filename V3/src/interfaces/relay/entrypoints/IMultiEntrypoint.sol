// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';

/// @title  IMultiEntrypoint
/// @notice Config surface shared by the Multi entrypoint variants (MultiConverter, MultiHybrid):
///         a mutable set of allowed convert target tokens and a mutable input-side excluded set,
///         both gated by the bound Relay's owner (there is no separate
///         config role — the L2 admin is the single authority over the Relay and its entrypoint
///         config). A token can never be in both sets. Available on Protocol L2 only, since mutable
///         strategy on Maxi/L1 would break the predictability those tiers offer depositors.
interface IMultiEntrypoint {
  /// @notice Emitted when the L2 admin adds a convert target token.
  /// @param token Target token added.
  event TargetTokenAdded(address indexed token);

  /// @notice Emitted when the L2 admin removes a convert target token.
  /// @param token Target token removed.
  event TargetTokenRemoved(address indexed token);

  /// @notice Emitted when the L2 admin adds an input token to the excluded (non-swappable) set.
  /// @param token Excluded token added.
  event ExcludedTokenAdded(address indexed token);

  /// @notice Emitted when the L2 admin removes an input token from the excluded set.
  /// @param token Excluded token removed.
  event ExcludedTokenRemoved(address indexed token);

  /// @notice Thrown when a config call comes from an account without the bound Relay's
  ///         owner seat.
  error NotConfigAdmin();

  /// @notice Thrown when a swap targets a Relay other than the one this entrypoint is bound to.
  error WrongRelay();

  /// @notice Thrown when the input token being swapped is on the excluded set (sweep-only).
  error TokenExcluded();

  /// @notice Thrown when the chosen convert target is not in the configured target set.
  error NotTargetToken();

  /// @notice Thrown when adding a token to one set while it is already in the other (target/excluded
  ///         are mutually exclusive).
  error TargetExcludedOverlap();

  /// @notice Thrown when adding a token already present in the set it is being added to.
  error TokenAlreadyConfigured();

  /// @notice Thrown when removing a token that is not present in the set.
  error TokenNotConfigured();

  /// @notice Adds a convert target token. Reverts if already a target or excluded.
  /// @param _token Target token to allow.
  function addTargetToken(address _token) external;

  /// @notice Removes a convert target token.
  /// @param _token Target token to remove.
  function removeTargetToken(address _token) external;

  /// @notice Adds an input token to the excluded set (sweep becomes its only path out). Reverts if
  ///         already excluded or a target.
  /// @param _token Input token to exclude.
  function addExcludedToken(address _token) external;

  /// @notice Removes an input token from the excluded set.
  /// @param _token Input token to re-allow.
  function removeExcludedToken(address _token) external;

  /// @notice Whether `_token` is an allowed convert target.
  /// @param _token Token to query.
  /// @return _is True when `_token` is a configured target.
  function isTargetToken(address _token) external view returns (bool _is);

  /// @notice Whether `_token` is excluded from swapping (sweep-only).
  /// @param _token Token to query.
  /// @return _is True when `_token` is excluded.
  function isExcludedToken(address _token) external view returns (bool _is);

  /// @notice The configured convert target tokens.
  /// @return _tokens The target token set.
  function targetTokens() external view returns (address[] memory _tokens);

  /// @notice The excluded (non-swappable) input tokens.
  /// @return _tokens The excluded token set.
  function excludedTokens() external view returns (address[] memory _tokens);

  /// @notice The Relay this entrypoint is bound to: the source and target of its swaps, and the holder
  ///         of the owner that gates its config.
  /// @return _relay The bound Relay.
  function RELAY() external view returns (IRelayEntrypoint _relay);
}
