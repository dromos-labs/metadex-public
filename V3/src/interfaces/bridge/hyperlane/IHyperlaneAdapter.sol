/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';

/**
 * @title IHyperlaneAdapter
 * @notice Interface for the Hyperlane-backed transport adapter deployed on root and every leaf chain, bound to a
 * single remote pair at deployment.
 */
interface IHyperlaneAdapter is IMessageAdapter {
  /**
   * @notice Emitted on every outbound dispatch so off-chain monitoring can correlate the message with its delivery.
   * @param _messageId Hyperlane message id returned by `mailbox.dispatch`.
   * @param _remoteAdapter The counterpart adapter that will receive the message.
   */
  event MessageSent(bytes32 indexed _messageId, bytes32 _remoteAdapter);

  /**
   * @notice Emitted when an `ADAPTER_CONFIG_ROLE` holder updates the counterpart adapter address.
   * @param _current The new `remoteAdapter` value after the update.
   */
  event RemoteAdapterUpdated(bytes32 _current);

  /// @notice Thrown when `setRemoteAdapter` is invoked by a caller without `ADAPTER_CONFIG_ROLE` on `VOTER`.
  error CallerNotAdapterAuthority();

  /// @notice Thrown when `handle` is invoked by a caller that is not the Hyperlane mailbox.
  error CallerNotMailbox();

  /// @notice Thrown when the adapter is constructed with an invalid Hyperlane remote domain id: either zero, or equal
  /// to the mailbox's local domain (which would make outbound messages a same-chain transport self-loop).
  error InvalidDomain();

  /// @notice Thrown when `sendMessage` is invoked with `_gasLimit == 0`, which would cause delivery to fail downstream.
  error InvalidGasLimit();

  /// @notice Thrown when `setRemoteAdapter` is invoked with `bytes32(0)`, preventing half-configured state.
  error InvalidRemoteAdapter();

  /// @notice Thrown when `sendMessage` or `handle` is invoked while `remoteAdapter` is unset (`bytes32(0)`).
  error RemoteAdapterNotSet();

  /// @notice Thrown when `handle` is invoked with an `_origin` that does not match `REMOTE_DOMAIN_ID`.
  error UnauthorizedOrigin();

  /// @notice Thrown when `handle` is invoked with a `_sender` that does not match `remoteAdapter`.
  error UnauthorizedSender();

  /**
   * @notice Hyperlane domain id of the counterpart chain. Used for inbound origin validation and as the outbound
   * dispatch destination.
   * @return _remoteDomainId Hyperlane domain id of the counterpart chain.
   */
  function REMOTE_DOMAIN_ID() external view returns (uint32 _remoteDomainId);

  /**
   * @notice Address of the local `MessageOrchestrator` bound to this adapter at deployment.
   * @return _orchestrator The local orchestrator that calls `sendMessage` outbound and receives `route` inbound.
   */
  function ORCHESTRATOR() external view returns (IMessageOrchestrator _orchestrator);

  /**
   * @notice Address of the Hyperlane mailbox on this chain bound to this adapter at deployment.
   * @return _mailbox The Hyperlane mailbox that dispatches outbound messages and delivers inbound ones.
   */
  function MAILBOX() external view returns (IMailbox _mailbox);

  /**
   * @notice Local voter whose `ADAPTER_CONFIG_ROLE` gates `setRemoteAdapter`: the `Voter` on root, the `LeafVoter`
   * on each leaf. Typed by the role registry the adapter consumes. Set at deployment, immutable.
   * @return _voter The local voter's role registry.
   */
  function VOTER() external view returns (IAccessControl _voter);

  /**
   * @notice Address of the counterpart adapter on the remote chain. Mutable by `ADAPTER_CONFIG_ROLE` holders through
   * `setRemoteAdapter`.
   * @return _remoteAdapter The bytes32 encoded counterpart adapter address, or `bytes32(0)` if not yet configured.
   */
  function remoteAdapter() external view returns (bytes32 _remoteAdapter);
}
