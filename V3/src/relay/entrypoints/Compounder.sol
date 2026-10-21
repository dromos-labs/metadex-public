// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';

import {BaseEntrypoint} from 'V3/relay/entrypoints/BaseEntrypoint.sol';

/**
 * @title  Compounder
 * @notice Entrypoint that swaps a reward token into the Relay's TOKEN and compounds the result into
 *         the Relay. This grows the stake that backs the shares, so each sAERO share is worth more.
 *         Holds the COMPOUNDER role on the Relay. Available on every tier. The target token is
 *         always TOKEN, so the bound Relay is its only configuration.
 */
contract Compounder is BaseEntrypoint, ICompounder {
  /// @notice Sets the router registry and the Relay this entrypoint serves.
  /// @param _factoryRegistry Registry that approves the routers swaps may run on.
  /// @param _relay The only Relay this entrypoint serves.
  constructor(IFactoryRegistry _factoryRegistry, IRelayEntrypoint _relay) BaseEntrypoint(_factoryRegistry, _relay) {}

  /// @inheritdoc ICompounder
  function swapAndCompound(SwapParams calldata _params) external nonReentrant {
    _swapAndCompound(_params);
  }

  /// @inheritdoc ICompounder
  /// @dev The swap path measures its own delta and deliberately ignores whatever sat on the Relay
  ///      before it, so TOKEN that arrived by other means (a direct transfer, a reward already
  ///      denominated in TOKEN, a balance predating this entrypoint) has no other way out.
  function compoundIdleBalance() external nonReentrant {
    _compoundIdleBalance();
  }
}
