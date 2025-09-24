// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';
import {ISingleHybrid} from 'V3/interfaces/relay/entrypoints/ISingleHybrid.sol';

import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/**
 * @title  SingleHybrid
 * @notice Entrypoint that combines a Compounder and a SingleConverter in one contract. It holds
 *         both the COMPOUNDER and the CONVERTER roles. On each call, the keeper picks the compound
 *         side or the convert side. The target token and `COMPOUND_WEIGHT` are immutable, set at
 *         deploy; each deployment (Maxi, L1, L2) uses its own values.
 * @dev `COMPOUND_WEIGHT` exists only so off-chain readers can see it. It tells the keeper which
 *      share of rewards, in pips, to compound instead of convert. The keeper applies this split
 *      off-chain by sizing each `amountIn`. The contract does not check the split, since per-call
 *      atomicity and slippage make an on-chain check impractical (TD5).
 */
contract SingleHybrid is BaseEntrypoint, ISingleHybrid {
  /// @inheritdoc ISingleConverter
  address public immutable TARGET_TOKEN;

  /// @inheritdoc ISingleHybrid
  uint256 public immutable COMPOUND_WEIGHT;

  /// @notice Bind the MetaRouter, target token and compound weight.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _targetToken Token the convert side distributes.
  /// @param _compoundWeight Intended compound share in pips; informational only, not checked on-chain.
  constructor(
    IFactoryRegistry _factoryRegistry,
    address _targetToken,
    uint256 _compoundWeight
  ) BaseEntrypoint(_factoryRegistry) {
    if (_targetToken == address(0)) revert ZeroAddress();
    if (_compoundWeight > MAX_PIPS) revert InvalidCompoundWeight();
    TARGET_TOKEN = _targetToken;
    COMPOUND_WEIGHT = _compoundWeight;
  }

  /// @inheritdoc ICompounder
  function swapAndCompound(SwapParams calldata _params) external nonReentrant {
    address _token = IRelayEntrypoint(_params.relay).TOKEN();
    uint256 _delta = _pullSwapAndValidate(_params, _token);
    IRelayEntrypoint(_params.relay).compound(_delta);
  }

  /// @inheritdoc ISingleConverter
  function swapAndConvert(SwapParams calldata _params) external nonReentrant {
    uint256 _delta = _pullSwapAndValidate(_params, TARGET_TOKEN);
    IRelayEntrypoint(_params.relay).notifyReward(TARGET_TOKEN, _delta);
  }

  /// @inheritdoc ICompounder
  function compoundIdleBalance(address _relay) external nonReentrant {
    _compoundIdleBalance(_relay);
  }

  /// @inheritdoc ISingleConverter
  function convertIdleBalance(address _relay) external nonReentrant {
    _convertIdleBalance(_relay, TARGET_TOKEN);
  }
}
