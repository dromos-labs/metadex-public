// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/**
 * @title  MultiEntrypoint (abstract)
 * @notice Config layer shared by the Multi entrypoint variants: a mutable set of allowed convert
 *         target tokens and a mutable set of excluded input tokens. A token can never be in both
 *         sets at the same time. Concrete variants add the swap entry functions on top.
 * @dev    Attached to Protocol L2 Relays only: a mutable strategy would break the predictability
 *         Maxi/L1 Relays need. Unlike the Single variants, each deployment stores per-instance
 *         config and is bound to one Relay at construction; the config is gated by that Relay's
 *         owner (the L2 admin).
 */
abstract contract MultiEntrypoint is BaseEntrypoint, IMultiEntrypoint {
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @inheritdoc IMultiEntrypoint
  IRelayEntrypoint public immutable RELAY;

  /// @notice Allowed convert target tokens; the convert side may only output to one of these.
  EnumerableSet.AddressSet private _targets;

  /// @notice Excluded input tokens; the entrypoint refuses to swap them (sweep is the only way to move them out).
  EnumerableSet.AddressSet private _excluded;

  /// @notice Restrict to the bound Relay's owner — the single config authority.
  /// @dev On a not-yet-promoted L1 Relay this is the L1 owner; the config it can touch stays inert
  ///      there because the attachment flow itself is L2-only.
  modifier onlyRelayOwner() {
    if (RELAY.owner() != msg.sender) revert NotConfigAdmin();
    _;
  }

  /// @notice Bind the factory registry and the Relay, then seed the target/excluded sets.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay Relay this entrypoint serves; its owner gates the config.
  /// @param _initialTargets Convert target tokens to allow at deploy.
  /// @param _initialExcluded Input tokens to exclude at deploy.
  constructor(
    IFactoryRegistry _factoryRegistry,
    IRelayEntrypoint _relay,
    address[] memory _initialTargets,
    address[] memory _initialExcluded
  ) BaseEntrypoint(_factoryRegistry) {
    if (address(_relay) == address(0)) revert ZeroAddress();
    RELAY = _relay;
    for (uint256 i; i < _initialTargets.length; ++i) {
      _addTarget(_initialTargets[i]);
    }
    for (uint256 i; i < _initialExcluded.length; ++i) {
      _addExcluded(_initialExcluded[i]);
    }
  }

  /// @inheritdoc IMultiEntrypoint
  function addTargetToken(address _token) external onlyRelayOwner {
    _addTarget(_token);
  }

  /// @inheritdoc IMultiEntrypoint
  function removeTargetToken(address _token) external onlyRelayOwner {
    if (!_targets.remove(_token)) revert TokenNotConfigured();
    emit TargetTokenRemoved(_token);
  }

  /// @inheritdoc IMultiEntrypoint
  function addExcludedToken(address _token) external onlyRelayOwner {
    _addExcluded(_token);
  }

  /// @inheritdoc IMultiEntrypoint
  function removeExcludedToken(address _token) external onlyRelayOwner {
    if (!_excluded.remove(_token)) revert TokenNotConfigured();
    emit ExcludedTokenRemoved(_token);
  }

  /// @inheritdoc IMultiEntrypoint
  function targetTokens() external view returns (address[] memory _tokens) {
    _tokens = _targets.values();
  }

  /// @inheritdoc IMultiEntrypoint
  function excludedTokens() external view returns (address[] memory _tokens) {
    _tokens = _excluded.values();
  }

  /// @inheritdoc IMultiEntrypoint
  function isTargetToken(address _token) public view returns (bool _is) {
    _is = _targets.contains(_token);
  }

  /// @inheritdoc IMultiEntrypoint
  function isExcludedToken(address _token) public view returns (bool _is) {
    _is = _excluded.contains(_token);
  }

  /// @notice Require a swap to target the bound Relay; the entrypoint's config policy applies only to it.
  /// @param _relay Relay the swap call addresses.
  function _requireBoundRelay(address _relay) internal view {
    if (_relay != address(RELAY)) revert WrongRelay();
  }

  /// @notice Validate a convert swap: the input token must not be excluded and the output token must
  ///         be in the target set.
  /// @param _tokenIn Reward token being swapped.
  /// @param _targetToken Chosen convert target.
  function _requireConvertible(address _tokenIn, address _targetToken) internal view {
    if (_excluded.contains(_tokenIn)) revert TokenExcluded();
    _requireTarget(_targetToken);
  }

  /// @notice Validate a convert output on its own, for the swap-free path where there is no input.
  /// @param _targetToken Chosen convert target.
  function _requireTarget(address _targetToken) internal view {
    if (!_targets.contains(_targetToken)) revert NotTargetToken();
  }

  /// @notice Validate a compound swap: the input token must not be excluded (the target is always TOKEN).
  /// @param _tokenIn Reward token being swapped.
  function _requireNotExcluded(address _tokenIn) internal view {
    if (_excluded.contains(_tokenIn)) revert TokenExcluded();
  }

  /// @notice Add `_token` to the target set. Reverts if the token is already in the excluded set, because a
  ///         token can never be in both sets.
  /// @param _token Target token to add.
  function _addTarget(address _token) private {
    if (_token == address(0)) revert ZeroAddress();
    if (_excluded.contains(_token)) revert TargetExcludedOverlap();
    if (!_targets.add(_token)) revert TokenAlreadyConfigured();
    emit TargetTokenAdded(_token);
  }

  /// @notice Add `_token` to the excluded set. Reverts if the token is already in the target set, because a
  ///         token can never be in both sets.
  /// @param _token Excluded token to add.
  function _addExcluded(address _token) private {
    if (_token == address(0)) revert ZeroAddress();
    if (_targets.contains(_token)) revert TargetExcludedOverlap();
    if (!_excluded.add(_token)) revert TokenAlreadyConfigured();
    emit ExcludedTokenAdded(_token);
  }
}
