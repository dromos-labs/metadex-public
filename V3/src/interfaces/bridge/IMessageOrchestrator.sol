/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IMessageOrchestrator
 * @notice Shared inbound entrypoint of every orchestrator. Registered adapters call `route`, which checks the caller
 * and the nonce, then hands the body to a typed handler.
 */
interface IMessageOrchestrator {
  /**
   * @notice Routing identifier stamped into the message header and read to pick the typed handler.
   * @param None Zero-default guard, rejected at decode so an empty payload cannot pass as the first real type.
   * @param AllocateChain Root to leaf — sets a tokenId's chain-level VP budget and the chain emissions scalar.
   * @param AllocateGauge Root to leaf — distributes a chain budget across gauges; cooldown-gated on the leaf.
   * @param ClaimRewards Root to leaf — claims fee and incentive rewards.
   * @param Redeem Leaf to root — Redeem.
   * @param SetOperator Root to leaf — propagates the per-tokenId operator assignment.
   * @param Deallocate Leaf to root — confirms a tokenId's deallocation so root credits `CHAIN0`.
   * @param ReduceCooldown Root to leaf — accrues a tokenId's pending cooldown reduction.
   * @param EmergencyDeallocate Root to leaf — clears a tokenId's gauges and cuts its chain budget by the drained
   * amount, so a Suspended chain re-syncs when it is next reachable.
   */
  enum MessageType {
    None,
    AllocateChain,
    AllocateGauge,
    ClaimRewards,
    Redeem,
    SetOperator,
    Deallocate,
    ReduceCooldown,
    EmergencyDeallocate
  }

  /// @notice Emitted when an outbound message is handed to a transport adapter and its nonce is stamped.
  /// @param _chainId Destination chain id.
  /// @param _chainNonce Outbound nonce stamped on this message.
  /// @param _msgType Routing identifier carried by the message.
  event MessageDispatched(uint256 indexed _chainId, uint256 _chainNonce, MessageType _msgType);

  /// @notice Emitted when an inbound message is accepted and its nonce is consumed.
  /// @param _chainId Source chain id.
  /// @param _chainNonce Nonce stamped by the source orchestrator.
  /// @param _msgType Routing identifier carried by the message.
  event MessageReceived(uint256 indexed _chainId, uint256 _chainNonce, MessageType _msgType);

  /// @notice Reverts when the inbound payload is too short to contain the wrapped header.
  error InvalidPayload();

  /// @notice Reverts when the inbound message type byte is above the `MessageType` enum range.
  error InvalidMessageType();

  /// @notice Reverts when the inbound message type byte is the `None` zero value, never a routable type.
  error NoneMessageType();

  /// @notice Reverts when a supplied address parameter is the zero address.
  error ZeroAddress();

  /// @notice Reverts when `dispatch` is called and no adapter is registered for the destination.
  error AdapterNotRegistered();

  /// @notice Reverts when `dispatch` is called by anyone other than the local voter contract.
  error CallerNotAuthorized();

  /// @notice Reverts when a `MessageType` is not routable in the current direction.
  error UnsupportedMessageType();

  /// @notice Reverts when `route` is called by anyone other than the registered adapter.
  error CallerNotAdapter();

  /// @notice Reverts when the inbound `chainNonce` has already been consumed.
  error NonceAlreadyUsed();

  /// @notice Reverts while the local clock trails the message's `dispatchedAt`; the transport redelivers once it
  ///         catches up, so a chain resuming from an outage cannot start accrual before the sender booked it.
  error ClockBehindDispatch();

  /// @notice Reverts when an adapter setter is called without `ADAPTER_CONFIG_ROLE` on the local voter.
  error CallerNotAdapterAuthority();

  /// @notice Reverts when `setAdapter` is invoked with the zero address.
  error InvalidAdapter();

  /**
   * @notice Routes a message delivered by a registered adapter to the orchestrator's typed handler.
   * @dev Registered adapter only. Nonces are single-use. Root rejects a `Redeem` from a suspended origin but still
   *      takes a `Deallocate`; the leaf routes while suspended so held root messages keep applying.
   * @dev `payable` so a relayer can send a deallocation return fee: on the leaf it lands in the pre-funding pool
   *      that pays the return. Root has no use for inbound value.
   * @param _originChainId Source chain id, supplied by the adapter from its `REMOTE_CHAIN_ID`.
   * @param _payload The wrapped message to decode and route.
   */
  function route(uint256 _originChainId, bytes calldata _payload) external payable;
}
