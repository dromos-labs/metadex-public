/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IMessageAdapter
 * @notice Interface for transport adapters that carry payloads between `MessageOrchestrator` instances without
 * inspecting their content.
 */
interface IMessageAdapter {
  /// @notice Thrown when `sendMessage` is invoked by a caller that is not a registered orchestrator.
  error CallerNotOrchestrator();

  /// @notice Thrown when the adapter is constructed with a zero chain id.
  error InvalidChainId();

  /// @notice Thrown when a required address argument is the zero address.
  error ZeroAddress();

  /**
   * @notice Sends the payload through the transport.
   * @dev Callable only by the registered orchestrator. Forwards `msg.value` to the underlying transport as the fee.
   * Any excess over the actual fee is expected to be refunded by the transport directly to `_refundRecipient`.
   * @param _message The wrapped message body forwarded to the underlying transport.
   * @param _gasLimit Execution gas reserved for the destination handler.
   * @param _refundRecipient Address that receives native ETH refunds from the transport.
   */
  function sendMessage(bytes calldata _message, uint256 _gasLimit, address _refundRecipient) external payable;

  /**
   * @notice Transport entrypoint invoked by the underlying transport to deliver an inbound payload to the local
   * orchestrator.
   * @dev Implementations that carry an underlying transport validate the transport caller, the origin, and the
   * sender against their configured remote counterpart, then call the orchestrator with `REMOTE_CHAIN_ID` as the
   * source chain id. Implementations without a transport (e.g., `RootLocalAdapter`) may revert.
   * @dev Payable: the transport forwards the relayer's delivery value (Hyperlane's `Mailbox.process` attaches
   * `msg.value` to `handle`), and the adapter passes it through to `route`, where it lands in the orchestrator's
   * pre-funding pool.
   * @param _origin Transport-level identifier of the source chain.
   * @param _sender Trusted counterpart address as reported by the transport.
   * @param _message The wrapped message body delivered to the orchestrator's `route`.
   */
  function handle(uint32 _origin, bytes32 _sender, bytes calldata _message) external payable;

  /**
   * @notice Quotes the transport fee `sendMessage` would charge for the same inputs.
   * @dev Takes the identical arguments to `sendMessage` on purpose: the underlying transport prices the wrapped
   * message and the destination gas budget together, so a quote taken with different arguments is not the fee
   * the send will cost. Callers that quote-then-send in the same transaction get an exact figure; the
   * fee-less local adapter quotes zero.
   * @param _message The wrapped message body that would be forwarded to the underlying transport.
   * @param _gasLimit Execution gas that would be reserved for the destination handler.
   * @param _refundRecipient Address that would receive native ETH refunds from the transport.
   * @return _fee Native amount `sendMessage` requires for these inputs.
   */
  function quoteMessage(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external view returns (uint256 _fee);

  /**
   * @notice Updates the stored remote adapter address.
   * @dev Implementations that carry a remote counterpart gate this entrypoint behind the adapter authority and reject
   * the zero value. Implementations without a remote counterpart (e.g., `RootLocalAdapter`) may revert.
   * @param _remoteAdapter The new counterpart adapter on the remote chain.
   */
  function setRemoteAdapter(bytes32 _remoteAdapter) external;

  /**
   * @notice Chain id this adapter is bound to. Read by the orchestrator at registration time to verify the
   * adapter is wired to the chain it is being registered for.
   * @return _chainId Chain id of the counterpart chain (or the local chain id for the local adapter on root).
   */
  function REMOTE_CHAIN_ID() external view returns (uint256 _chainId);
}
