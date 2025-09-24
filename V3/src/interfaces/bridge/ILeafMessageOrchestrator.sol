/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title ILeafMessageOrchestrator
 * @notice Leaf-side orchestrator: sends outbound messages to root and routes inbound root messages to the
 * `LeafVoter`.
 * @dev Holds the pre-funding pool that pays root-triggered deallocation returns.
 */
interface ILeafMessageOrchestrator is IMessageOrchestrator {
  /// @notice Emitted when the registered adapter for the root pair is updated.
  /// @param _current The newly registered adapter.
  event AdapterUpdated(IMessageAdapter _current);

  /// @notice Emitted when the destination gas limit for a deallocation return is set.
  /// @param _gasLimit The gas reserved for root's handler of the return.
  event DeallocationGasLimitSet(uint256 _gasLimit);

  /// @notice Emitted when pre-funding is withdrawn from the orchestrator.
  /// @param _destination Address that received the withdrawal.
  /// @param _amount Native amount withdrawn.
  event NativeWithdrawn(address indexed _destination, uint256 _amount);

  /// @notice Emitted when an inbound claim or operator message arrives past its root-stamped expiry and is dropped.
  /// @dev The message's nonces stay committed: an expired message never becomes executable, and consuming its
  ///      nonces keeps older in-flight messages from applying after it.
  /// @param _msgType Type of the dropped message.
  /// @param _tokenId veNFT id the dropped message targeted.
  event ExpiredMessageDropped(MessageType indexed _msgType, uint256 indexed _tokenId);

  /// @notice Reverts when the orchestrator is deployed with a zero `ROOT_CHAIN_ID`, which no adapter could match.
  error InvalidRootChainId();

  /// @notice Reverts when `setAdapter` is given an adapter whose `REMOTE_CHAIN_ID` is not `ROOT_CHAIN_ID`.
  error AdapterChainIdMismatch();

  /// @notice Reverts when a `Deallocate` is underfunded: the caller's value or the pool is below the quoted fee.
  error InsufficientDeallocationMessageValue();

  /// @notice Reverts when a gas-limit setter is called by an address without `GAS_CONFIGURER_ROLE`.
  error CallerNotGasConfigurer();

  /// @notice Reverts when a gas-limit setter receives zero.
  error ZeroGasLimit();

  /// @notice Reverts when `withdrawNative` is called by an address without `NATIVE_WITHDRAWER_ROLE`.
  error CallerNotNativeWithdrawer();

  /// @notice Reverts when the native transfer in `withdrawNative` fails.
  error WithdrawFailed();

  /// @notice Sets the registered adapter for the root pair. `ADAPTER_CONFIG_ROLE` on the `LeafVoter` only.
  /// @dev Reverts unless `_adapter.REMOTE_CHAIN_ID()` is `ROOT_CHAIN_ID`, so the leaf's only authenticated route
  ///      points at root and no other chain can authenticate root-only messages.
  /// @param _adapter The adapter to register for the root pair.
  function setAdapter(IMessageAdapter _adapter) external;

  /**
   * @notice Sends an outbound `Redeem` or `Deallocate` to root through the registered adapter. `LeafVoter` only.
   * @dev No status check: the `LeafVoter` enforces the status (`redeem` is `chainIsActiveOrSunset`, open only while
   *      Active or Sunset), and a `Deallocate` goes out even while Suspended so root's booking stays right
   *      ahead of an emergency deallocation.
   * @dev A `Deallocate` must cover a live adapter quote, so no configured cost can drift from the real fee.
   *      Pool-funded draws the exact quote and refunds back into the pool; otherwise the whole `msg.value` goes out.
   * @param _msgType Routing identifier consumed by the destination handler.
   * @param _payload Message body; the header is added before sending.
   * @param _gasLimit Destination gas. Ignored for `Deallocate`, which uses the configured `deallocationGasLimit`.
   * @param _refundRecipient Transport refund recipient. Ignored when `_fundFromPool` refunds into the pool.
   * @param _fundFromPool Whether to draw the quoted fee from the pre-funding pool instead of `msg.value`.
   */
  function dispatch(
    MessageType _msgType,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    bool _fundFromPool
  ) external payable;

  /// @notice Sets the destination gas limit stamped on every deallocation return. `GAS_CONFIGURER_ROLE` only.
  /// @dev `dispatch` and `quoteDispatch` both read it for `Deallocate`, so a quote is never taken against a
  ///      different budget than the send uses.
  /// @param _gasLimit New destination gas limit for deallocation returns.
  function setDeallocationGasLimit(uint256 _gasLimit) external;

  /// @notice Withdraws the pre-funding held for root-triggered deallocation returns. `NATIVE_WITHDRAWER_ROLE` only.
  /// @dev Also the recovery path for inbound message value that arrived without a deallocation to spend it on.
  /// @param _amount Native amount to withdraw.
  /// @param _destination Address that receives the withdrawal.
  function withdrawNative(uint256 _amount, address _destination) external;

  /**
   * @notice Quotes the native fee a `dispatch` with the same arguments would need.
   * @dev Prices the wrapped envelope, not the bare payload. The header is fixed-width, so the nonce cannot move the
   *      quote and a dispatch landing in between cannot invalidate it.
   * @dev Reverts `AdapterNotRegistered` if no adapter is registered.
   * @param _msgType Routing identifier the dispatch would stamp.
   * @param _payload Message body the dispatch would wrap.
   * @param _gasLimit Destination gas. Ignored for `Deallocate`, priced against `deallocationGasLimit`.
   * @param _refundRecipient Address the dispatch would name as the transport's refund recipient.
   * @return _fee Native amount the matching `dispatch` requires.
   */
  function quoteDispatch(
    MessageType _msgType,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient
  ) external view returns (uint256 _fee);

  /// @notice Local `LeafVoter` bound to this orchestrator at deployment.
  /// @dev The only caller allowed to `dispatch`, and the source of the roles checked here.
  /// @return Local `LeafVoter`.
  function LEAF_VOTER() external view returns (ILeafVoter);

  /// @notice Chain id of root, the only chain this leaf orchestrator messages. Set at deployment.
  /// @dev `setAdapter` requires the registered adapter's `REMOTE_CHAIN_ID` to equal this.
  /// @return Root chain id.
  function ROOT_CHAIN_ID() external view returns (uint256);

  /// @notice Registered transport adapter for the root pair, or zero if none.
  /// @return Registered adapter.
  function adapter() external view returns (IMessageAdapter);

  /// @notice Destination gas limit stamped on every deallocation return, and the budget its fee is quoted against.
  /// @dev Defaults to zero at deployment. Every `Deallocate` dispatch reverts until governance configures a nonzero
  ///      limit. A root-triggered return keeps its inbound nonce and redelivers, but only until the allocation's
  ///      root-stamped expiry: configure within `allocationLifetime` of going live or in-flight votes are lost.
  /// @return _gasLimit Configured gas limit.
  function deallocationGasLimit() external view returns (uint256 _gasLimit);

  /// @notice Last outbound nonce stamped on a dispatch to root.
  /// @return _lastNonce Last outbound nonce.
  function nonceOut() external view returns (uint256 _lastNonce);

  /// @notice Whether an inbound nonce has already been consumed.
  /// @dev Single-use replay gate shared by every message type; the voting path adds its own ordering checks.
  /// @param _nonce Inbound nonce to check.
  /// @return _isUsed Whether `_nonce` has been consumed.
  function noncesUsed(uint256 _nonce) external view returns (bool _isUsed);

  /// @notice Highest inbound nonce applied to chain-level vote state.
  /// @dev Gated apart from token state, so an out-of-order message skips a stale chain update without blocking its
  ///      token allocation. Applies only when the inbound nonce is strictly greater.
  /// @return _nonce Highest nonce applied to chain-level vote state.
  function lastChainVoteNonce() external view returns (uint256 _nonce);

  /// @notice Highest inbound nonce applied to a tokenId's vote and allocation state.
  /// @dev Gated per tokenId, so a token still updates when its nonce is newer even after the chain nonce moved
  ///      past it. Applies only when the inbound nonce is strictly greater.
  /// @param _tokenId The tokenId to read.
  /// @return _nonce Highest nonce applied to the tokenId's vote state.
  function lastTokenIdVoteNonce(uint256 _tokenId) external view returns (uint256 _nonce);

  /// @notice Highest inbound nonce applied to a tokenId's operator mirror.
  /// @dev Kept apart from the vote nonce, or whichever message lands first would mark the other stale. A
  ///      `SetOperator` applies only when the inbound nonce is strictly greater.
  /// @param _tokenId The tokenId to read.
  /// @return _nonce Highest nonce applied to the tokenId's operator mirror.
  function lastOperatorNonce(uint256 _tokenId) external view returns (uint256 _nonce);

  /// @notice Inbound nonce of the tokenId's last applied `EmergencyDeallocate` message.
  /// @dev An `AllocateChain` at or below this ships a zero delta, so a message in flight when the emergency ran
  ///      cannot bring back the cleared position. Zero until the tokenId's first emergency deallocation.
  /// @param _tokenId The tokenId to read.
  /// @return _nonce Inbound nonce of the tokenId's last emergency deallocation.
  function lastEmergencyDeallocNonce(uint256 _tokenId) external view returns (uint256 _nonce);

  /// @notice Highest inbound nonce, across `AllocateChain` and `AllocateGauge`, allowed to refresh the token's shape.
  /// @dev Both types carry a shape and advance this, so a delayed gauge vote cannot bring back a shape older than a
  ///      chain reallocation that followed it; it books at the current shape instead.
  /// @param _tokenId The tokenId to read.
  /// @return _nonce Highest nonce that refreshed the tokenId's shape.
  function lastShapeNonce(uint256 _tokenId) external view returns (uint256 _nonce);
}
