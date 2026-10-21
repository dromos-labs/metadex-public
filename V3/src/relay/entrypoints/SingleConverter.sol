// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';

import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/**
 * @title  SingleConverter
 * @notice Entrypoint that swaps a reward token into one fixed target token and notifies the Relay's
 *         idle balance of it into the accumulator, so every holder accrues a claimable share. Holds the
 *         CONVERTER role on the Relay. The target token is immutable and set at deploy; there is
 *         one deployment per Relay and target token (Maxi, L1 or L2).
 * @dev The converter itself notifies the Relay's idle balance, in the same way that the Compounder
 *      calls compound. As a result, the same actor that runs the swap also advances the per-share
 *      index.
 */
contract SingleConverter is BaseEntrypoint, ISingleConverter {
  /// @inheritdoc ISingleConverter
  address public immutable TARGET_TOKEN;

  /// @notice Sets the router registry, the Relay and the immutable target token.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay The only Relay this entrypoint serves.
  /// @param _targetToken The token that rewards are converted into. It must match the Relay's registered reward token.
  constructor(
    IFactoryRegistry _factoryRegistry,
    IRelayEntrypoint _relay,
    address _targetToken
  ) BaseEntrypoint(_factoryRegistry, _relay) {
    if (_targetToken == address(0)) revert ZeroAddress();
    TARGET_TOKEN = _targetToken;
  }

  /// @inheritdoc ISingleConverter
  function swapAndConvert(SwapParams calldata _params) external nonReentrant {
    _swapAndConvert(_params, TARGET_TOKEN);
  }

  /// @inheritdoc ISingleConverter
  /// @dev Without this a reward the Relay collects directly in `TARGET_TOKEN` would wait for a
  ///      swap to be distributed, since the swap path refuses `tokenIn == TARGET_TOKEN`.
  function convertIdleBalance() external nonReentrant {
    _convertIdleBalance(TARGET_TOKEN);
  }
}
