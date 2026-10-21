// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {SafeTransferLib} from '@solady/utils/SafeTransferLib.sol';

import {IRelayModule} from 'V3/interfaces/relay/IRelayModule.sol';

/**
 * @title  RelayModuleLib
 * @notice The two sweeps every Relay module runs to recover what a batch leaves behind: the whole
 *         native balance, or the whole balance of one token, to a recipient the caller names.
 * @dev    INTERNAL library, so every function inlines into its caller. That is the point: a sweep
 *         reads the module's own balance and emits as the module, and an internal library needs no
 *         linking, adds no deployed bytecode, and appears in none of the deployment or verification
 *         manifests an external relay library has to be registered in.
 * @dev    Who may sweep is the caller's policy. This library never checks the sender.
 */
library RelayModuleLib {
  using SafeTransferLib for address;

  /// @notice Send the calling module's whole native balance to `_to`.
  /// @dev An empty balance reverts rather than passing silently, so a recovery that moved nothing is
  ///      never mistaken for one that worked.
  /// @param _to Recipient of the balance.
  function sweepNative(address _to) internal {
    if (_to == address(0)) revert IRelayModule.ZeroAddress();

    uint256 _amount = address(this).balance;
    if (_amount == 0) revert IRelayModule.NothingToSweep();
    // This is a real increase over running a batch, not a repeat of it. A batch spends only the value
    // sent with the call, because the Metarouter snapshots its own balance rather than the module's,
    // and it can never pull the module's ERC20s, because `FundsLib.pull` transfers from the logical
    // sender and the module approves nobody. So a sweep is the only way out for what a batch leaves
    // behind, and the destination is the keeper's to name. That is the same trust the batch itself
    // already places in the keeper.
    // slither-disable-next-line arbitrary-send-eth
    (bool _ok,) = _to.call{value: _amount}('');
    if (!_ok) revert IRelayModule.NativeTransferFailed();

    emit IRelayModule.NativeSwept(_to, _amount);
  }

  /// @notice Send the calling module's whole balance of `_token` to `_to`.
  /// @dev An empty balance reverts, which also covers a token whose `balanceOf` reverts: Solady reads
  ///      that as zero instead of bubbling it up, so without this the sweep of a paused token would
  ///      report success and move nothing.
  /// @param _token Token to move out.
  /// @param _to Recipient of the balance.
  function sweepToken(address _token, address _to) internal {
    if (_to == address(0)) revert IRelayModule.ZeroAddress();

    uint256 _amount = _token.balanceOf(address(this));
    if (_amount == 0) revert IRelayModule.NothingToSweep();

    _token.safeTransfer(_to, _amount);
    emit IRelayModule.TokenSwept(_token, _to, _amount);
  }
}
