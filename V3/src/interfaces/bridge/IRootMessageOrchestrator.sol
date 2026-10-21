/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title IRootMessageOrchestrator
 * @notice Root-side orchestrator: sends outbound messages from the local `Voter` to many leaves and routes inbound
 * `Redeem` and `Deallocate` messages back to it.
 */
interface IRootMessageOrchestrator is IMessageOrchestrator {
  /**
   * @notice One destination's share of a dispatch sent by the `Voter`.
   * @param chainId Destination chain id.
   * @param gasLimit Execution gas reserved for the destination handler.
   * @param nativeValue Transport fee, plus the kept `deallocationReturnCost` when `chargeDeallocationReturn` is set.
   * @param chargeDeallocationReturn Whether to keep this chain's `deallocationReturnCost` out of `nativeValue`.
   * @param payload Message body; the header is added before sending.
   */
  struct ChainDispatch {
    uint256 chainId;
    uint256 gasLimit;
    uint256 nativeValue;
    bool chargeDeallocationReturn;
    bytes payload;
  }

  /// @notice Emitted when the registered adapter for a destination chain is updated.
  /// @param _chainId Destination chain id whose adapter slot was updated.
  /// @param _current The newly registered adapter.
  event AdapterUpdated(uint256 _chainId, IMessageAdapter _current);

  /// @notice Emitted when the deallocation return cost for a destination chain is set.
  /// @param _chainId Destination chain id whose cost was set.
  /// @param _cost The newly configured cost.
  event DeallocationReturnCostSet(uint256 indexed _chainId, uint256 _cost);

  /// @notice Emitted when the kept native ETH is withdrawn.
  /// @param _destination Address that received the withdrawal.
  /// @param _amount Native amount withdrawn.
  event NativeWithdrawn(address indexed _destination, uint256 _amount);

  /// @notice Reverts when `dispatch` gets a `msg.value` that does not equal the sum of every `nativeValue`.
  error InvalidDispatchValue();

  /// @notice Reverts when `setAdapter` is invoked with a chain id of zero, a value reserved as a sentinel.
  error InvalidChainId();

  /// @notice Reverts when `setAdapter` gets an adapter whose `REMOTE_CHAIN_ID` is not the registered chain id.
  error AdapterChainIdMismatch();

  /// @notice Reverts when a charging dispatch supplies a `nativeValue` below the chain's `deallocationReturnCost`.
  error InsufficientDeallocationReturnCost();

  /// @notice Reverts when a non-zero cost is set on the root-colocated leaf, whose adapter takes no transport value.
  error DeallocationReturnCostNotAllowed();

  /// @notice Reverts when a configuration call targets a chain the `Voter` has not registered.
  /// @param _chainId The unregistered chain id.
  error ChainNotRegistered(uint256 _chainId);

  /// @notice Reverts when `setDeallocationReturnCost` is called by an address without `VOTER_CONFIG_ROLE`.
  error CallerNotVoterConfigAuthority();

  /// @notice Reverts when `withdrawNative` is called by an address without `NATIVE_WITHDRAWER_ROLE`.
  error CallerNotNativeWithdrawer();

  /// @notice Reverts when the native transfer in `withdrawNative` fails.
  error WithdrawFailed();

  /// @notice Sets the registered adapter for a destination chain. `ADAPTER_CONFIG_ROLE` on the `Voter` only.
  /// @dev Reverts if `_chainId` is zero, `_adapter` is zero, or `_adapter.REMOTE_CHAIN_ID()` is not `_chainId`.
  /// @param _chainId Destination chain id to register the adapter for.
  /// @param _adapter The adapter to register. Must report `REMOTE_CHAIN_ID == _chainId`.
  function setAdapter(uint256 _chainId, IMessageAdapter _adapter) external;

  /**
   * @notice Sends one outbound message per destination through the matching adapter. Local `Voter` only.
   * @dev Reverts `InvalidDispatchValue` unless `msg.value` equals the sum of every `nativeValue`. Every adapter,
   *      cost and fee is resolved before the first send, since a send hands control to `_refundRecipient`.
   * @dev A destination with `chargeDeallocationReturn` keeps its chain's `deallocationReturnCost` here, withdrawable
   *      to top the leaf up; only the rest is forwarded as the transport fee, which the caller quotes off-chain.
   * @param _msgType Routing identifier shared by every dispatch.
   * @param _dispatches Per-destination dispatches.
   * @param _refundRecipient Address the transport refunds any excess fee to.
   */
  function dispatch(
    MessageType _msgType,
    ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external payable;

  /// @notice Sets the native amount kept per dispatch that carries a deallocation return. `VOTER_CONFIG_ROLE` only.
  /// @dev Reverts unless the chain is registered on the `Voter`. Must be zero for the root-colocated leaf, whose
  ///      `RootLocalAdapter` takes no transport value.
  /// @param _chainId Destination chain the cost applies to.
  /// @param _cost Native amount kept on each charging dispatch to `_chainId`.
  function setDeallocationReturnCost(uint256 _chainId, uint256 _cost) external;

  /// @notice Withdraws the collected deallocation return costs. `NATIVE_WITHDRAWER_ROLE` on the `Voter` only.
  /// @dev Pays for the manual leaf top-up that keeps each leaf able to front its return messages.
  /// @param _amount Native amount to withdraw.
  /// @param _destination Address that receives the withdrawal.
  function withdrawNative(uint256 _amount, address _destination) external;

  /// @notice Local `Voter` bound to this orchestrator at deployment.
  /// @dev The only caller allowed to `dispatch`. It owns the chain registry and the roles checked here; the
  ///      orchestrator holds none.
  /// @return Local `Voter`.
  function VOTER() external view returns (IVoter);

  /// @notice Registered transport adapter for a destination chain, or zero if none.
  /// @param _chainId Destination chain id.
  /// @return Registered adapter for `_chainId`.
  function adapters(uint256 _chainId) external view returns (IMessageAdapter);

  /// @notice Native amount kept per dispatch that carries a deallocation return, covering the gas the leaf fronts.
  /// @param _chainId Destination chain id.
  /// @return _cost Configured cost for `_chainId`.
  function deallocationReturnCost(uint256 _chainId) external view returns (uint256 _cost);

  /// @notice Last outbound nonce stamped on a dispatch to a destination chain.
  /// @param _chainId Destination chain id.
  /// @return _lastNonce Last outbound nonce for `_chainId`.
  function nonceOut(uint256 _chainId) external view returns (uint256 _lastNonce);

  /// @notice Whether an inbound nonce has already been consumed for a source chain.
  /// @dev Single-use replay gate: a nonce that reads true makes `route` revert `NonceAlreadyUsed`.
  /// @param _chainId Source chain id.
  /// @param _nonce Inbound nonce to check.
  /// @return _isUsed Whether `_nonce` has been consumed for `_chainId`.
  function noncesUsed(uint256 _chainId, uint256 _nonce) external view returns (bool _isUsed);
}
