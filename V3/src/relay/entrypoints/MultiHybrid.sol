// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {IMultiConverter} from 'V3/interfaces/relay/entrypoints/IMultiConverter.sol';
import {IMultiHybrid} from 'V3/interfaces/relay/entrypoints/IMultiHybrid.sol';

import {MultiEntrypoint} from 'V3/relay/entrypoints/MultiEntrypoint.sol';

/**
 * @title  MultiHybrid
 * @notice Hybrid entrypoint bound to one Relay. It holds both the COMPOUNDER and the CONVERTER
 *         roles on that Relay, and on each call the keeper picks one side: compound or convert.
 *         The set of allowed target tokens, the set of excluded input tokens and the compound
 *         weight are all mutable, and every change is gated by the bound Relay's
 *         owner (the L2 admin). For Protocol L2 Relays only.
 * @dev `compoundWeight` is stored for off-chain readers only. It is the share, in pips, that the
 *      keeper should compound instead of convert. The contract does not enforce the split: the
 *      keeper applies it off-chain by choosing how big each `amountIn` is. An on-chain check is
 *      impractical because every call is atomic and slippage moves the amounts (TD5).
 */
contract MultiHybrid is MultiEntrypoint, IMultiHybrid {
  /// @inheritdoc IMultiHybrid
  uint256 public compoundWeight;

  /// @notice Bind the factory registry and the Relay, seed the sets and set the compound weight.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay Relay this Hybrid serves; its owner gates the config.
  /// @param _initialTargets Convert target tokens to allow at deploy.
  /// @param _initialExcluded Input tokens to exclude at deploy.
  /// @param _compoundWeight Intended compound share in pips; informational only, not
  ///        enforced on-chain.
  constructor(
    IFactoryRegistry _factoryRegistry,
    IRelayEntrypoint _relay,
    address[] memory _initialTargets,
    address[] memory _initialExcluded,
    uint256 _compoundWeight
  ) MultiEntrypoint(_factoryRegistry, _relay, _initialTargets, _initialExcluded) {
    if (_compoundWeight > MAX_PIPS) revert InvalidCompoundWeight();
    compoundWeight = _compoundWeight;
  }

  /// @inheritdoc IMultiHybrid
  function setCompoundWeight(uint256 _compoundWeight) external onlyRelayOwner {
    if (_compoundWeight > MAX_PIPS) revert InvalidCompoundWeight();
    if (compoundWeight == _compoundWeight) return;
    compoundWeight = _compoundWeight;
    emit CompoundWeightSet(_compoundWeight);
  }

  /// @inheritdoc ICompounder
  function swapAndCompound(SwapParams calldata _params) external nonReentrant {
    _requireBoundRelay(_params.relay);
    _requireNotExcluded(_params.tokenIn);
    address _token = IRelayEntrypoint(_params.relay).TOKEN();
    uint256 _delta = _pullSwapAndValidate(_params, _token);
    IRelayEntrypoint(_params.relay).compound(_delta);
  }

  /// @inheritdoc IMultiConverter
  function swapAndConvert(SwapParams calldata _params, address _targetToken) external nonReentrant {
    _requireBoundRelay(_params.relay);
    _requireConvertible(_params.tokenIn, _targetToken);
    uint256 _delta = _pullSwapAndValidate(_params, _targetToken);
    IRelayEntrypoint(_params.relay).notifyReward(_targetToken, _delta);
  }

  /// @inheritdoc ICompounder
  function compoundIdleBalance(address _relay) external nonReentrant {
    _requireBoundRelay(_relay);
    _compoundIdleBalance(_relay);
  }

  /// @inheritdoc IMultiConverter
  function convertIdleBalance(address _relay, address _targetToken) external nonReentrant {
    _requireBoundRelay(_relay);
    _requireTarget(_targetToken);
    _convertIdleBalance(_relay, _targetToken);
  }
}
