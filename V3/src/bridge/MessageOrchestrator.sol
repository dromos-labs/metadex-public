/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';

/**
 * @title MessageOrchestrator
 * @notice Abstract base for the cross-chain orchestrators between the voters and the transport adapters.
 * @dev Holds only the shared header encode/decode; root and leaf add their own storage and routing.
 */
abstract contract MessageOrchestrator is IMessageOrchestrator {
  /**
   * @notice Wraps a body with the 39-byte header (`uint8 msgType` + `uint256 chainNonce` + `uint48 dispatchedAt`).
   * @dev Stamps `dispatchedAt` from the sender's clock here, so no dispatch site can omit it.
   * @param _msgType Message type to encode.
   * @param _chainNonce Chain nonce to encode.
   * @param _payload Message body to append after the header.
   * @return _message Wrapped message payload.
   */
  function _encodeMessage(
    MessageType _msgType,
    uint256 _chainNonce,
    bytes calldata _payload
  ) internal view returns (bytes memory _message) {
    _message = abi.encodePacked(uint8(_msgType), _chainNonce, uint48(block.timestamp), _payload);
  }

  /**
   * @notice Splits a wrapped payload into its header fields and body.
   * @dev Reverts `InvalidPayload` below 39 bytes, `NoneMessageType` on a zero type byte, `InvalidMessageType`
   *      above the enum max.
   * @dev Reverts `ClockBehindDispatch` while the local clock trails `dispatchedAt`, so the transport redelivers
   *      once it catches up. A chain resuming from an outage produces blocks stamped behind wall time; applying
   *      a message there would start its accrual before the sender booked it, minting claims the sender never
   *      backs.
   * @param _payload Wrapped message payload delivered by the adapter.
   * @return _msgType Decoded message type.
   * @return _chainNonce Decoded chain nonce.
   * @return _body Unwrapped body, a calldata slice.
   */
  function _decodeMessage(bytes calldata _payload)
    internal
    view
    returns (MessageType _msgType, uint256 _chainNonce, bytes calldata _body)
  {
    if (_payload.length < 39) revert InvalidPayload();
    uint8 _msgTypeByte;
    uint48 _dispatchedAt;
    assembly {
      _msgTypeByte := shr(248, calldataload(_payload.offset))
      _chainNonce := calldataload(add(_payload.offset, 1))
      _dispatchedAt := shr(208, calldataload(add(_payload.offset, 33)))
      _body.offset := add(_payload.offset, 39)
      _body.length := sub(_payload.length, 39)
    }
    if (_msgTypeByte == 0) revert NoneMessageType();
    if (_msgTypeByte > uint8(type(MessageType).max)) revert InvalidMessageType();
    if (_dispatchedAt > block.timestamp) revert ClockBehindDispatch();
    _msgType = MessageType(_msgTypeByte);
  }
}
