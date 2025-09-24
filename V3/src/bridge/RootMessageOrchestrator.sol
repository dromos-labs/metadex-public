/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MessageOrchestrator} from 'V3/bridge/MessageOrchestrator.sol';
import {
  IMessageAdapter,
  IMessageOrchestrator,
  IRootMessageOrchestrator,
  IVoter
} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {Roles} from 'V3/libraries/Roles.sol';

/**
 * @title RootMessageOrchestrator
 * @notice Root-side orchestrator. Sends outbound messages from the `Voter` to many leaves, and routes inbound
 * `Redeem` and `Deallocate` messages from leaves back to the `Voter`.
 * @dev Adapter and nonce state is keyed per chain: each leaf has its own transport and nonce stream.
 */
contract RootMessageOrchestrator is MessageOrchestrator, IRootMessageOrchestrator {
  /// @inheritdoc IRootMessageOrchestrator
  IVoter public immutable VOTER;

  /// @inheritdoc IRootMessageOrchestrator
  mapping(uint256 _chainId => IMessageAdapter _adapter) public adapters;
  /// @inheritdoc IRootMessageOrchestrator
  mapping(uint256 _chainId => uint256 _nonce) public nonceOut;
  /// @inheritdoc IRootMessageOrchestrator
  mapping(uint256 _chainId => mapping(uint256 _nonce => bool _isUsed)) public noncesUsed;
  /// @inheritdoc IRootMessageOrchestrator
  mapping(uint256 _chainId => uint256 _cost) public deallocationReturnCost;

  /**
   * @notice Binds the orchestrator to its local `Voter` at deployment.
   * @param _voter Local `Voter`: the only `dispatch` caller, the inbound routing target, and the role source.
   */
  constructor(address _voter) {
    if (_voter == address(0)) revert ZeroAddress();

    VOTER = IVoter(_voter);
  }

  // slither-disable-start reentrancy-eth
  /// @inheritdoc IRootMessageOrchestrator
  function dispatch(
    MessageType _msgType,
    ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external payable {
    if (msg.sender != address(VOTER)) revert CallerNotAuthorized();
    // Root only receives Redeem and Deallocate, it never sends them.
    if (_msgType == MessageType.None || _msgType == MessageType.Redeem || _msgType == MessageType.Deallocate) {
      revert UnsupportedMessageType();
    }

    // Resolve every adapter, cost and fee before the first send: a send hands control to `_refundRecipient`.
    uint256 _dispatchesLength = _dispatches.length;
    IMessageAdapter[] memory _adapters = new IMessageAdapter[](_dispatchesLength);
    uint256[] memory _transportFees = new uint256[](_dispatchesLength);
    uint256 _totalValue = 0;
    for (uint256 _i; _i < _dispatchesLength; ++_i) {
      ChainDispatch calldata _dispatch = _dispatches[_i];
      _totalValue += _dispatch.nativeValue;

      // The leaf fronts the return's gas: keep that chain's cost here, forward only the rest as the transport fee.
      uint256 _cost = _dispatch.chargeDeallocationReturn ? deallocationReturnCost[_dispatch.chainId] : 0;
      if (_dispatch.nativeValue < _cost) revert InsufficientDeallocationReturnCost();
      _transportFees[_i] = _dispatch.nativeValue - _cost;

      IMessageAdapter _adapter = adapters[_dispatch.chainId];
      if (address(_adapter) == address(0)) revert AdapterNotRegistered();
      _adapters[_i] = _adapter;
    }
    if (msg.value != _totalValue) revert InvalidDispatchValue();

    for (uint256 _i; _i < _dispatchesLength; ++_i) {
      ChainDispatch calldata _dispatch = _dispatches[_i];
      uint256 _nonce = ++nonceOut[_dispatch.chainId];
      bytes memory _message = _encodeMessage(_msgType, _nonce, _dispatch.payload);
      _adapters[_i].sendMessage{value: _transportFees[_i]}(_message, _dispatch.gasLimit, _refundRecipient);

      emit MessageDispatched(_dispatch.chainId, _nonce, _msgType);
    }
  }

  // slither-disable-end reentrancy-eth
  /// @inheritdoc IMessageOrchestrator
  function route(uint256 _originChainId, bytes calldata _payload) external payable {
    if (msg.sender != address(adapters[_originChainId])) revert CallerNotAdapter();
    // `payable` only to match the shared interface: root has no use for inbound value, and only a registered
    // adapter can call this, so stray value is not guarded.

    (MessageType _msgType, uint256 _chainNonce, bytes calldata _body) = _decodeMessage(_payload);
    if (noncesUsed[_originChainId][_chainNonce]) revert NonceAlreadyUsed();
    noncesUsed[_originChainId][_chainNonce] = true;

    if (_msgType == MessageType.Redeem) {
      // `Voter.processRedeem` rejects a Suspended origin.
      IVoterCommon.RedeemMessageBody memory _redeemBody = abi.decode(_body, (IVoterCommon.RedeemMessageBody));
      VOTER.processRedeem(_originChainId, _redeemBody.amount, _redeemBody.recipient, _redeemBody.surplusAccrued);
    } else if (_msgType == MessageType.Deallocate) {
      // Accepted while the origin is Suspended: the credit clamps to the token's booking, so it only pulls the
      // token's own VP back to `CHAIN0`. Letting it land keeps root accurate ahead of an `emergencyDeallocate`
      // and stops a held return from subtracting twice against a later re-allocation.
      IVoterCommon.DeallocationMessageBody memory _deallocBody =
        abi.decode(_body, (IVoterCommon.DeallocationMessageBody));
      VOTER.processDeallocation(_originChainId, _deallocBody.tokenId, _deallocBody.amount);
    } else {
      revert UnsupportedMessageType();
    }

    emit MessageReceived(_originChainId, _chainNonce, _msgType);
  }

  /// @inheritdoc IRootMessageOrchestrator
  function setAdapter(uint256 _chainId, IMessageAdapter _adapter) external {
    if (!VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, msg.sender)) revert CallerNotAdapterAuthority();
    if (_chainId == 0) revert InvalidChainId();
    if (address(_adapter) == address(0)) revert InvalidAdapter();
    if (_adapter.REMOTE_CHAIN_ID() != _chainId) revert AdapterChainIdMismatch();

    adapters[_chainId] = _adapter;

    emit AdapterUpdated(_chainId, _adapter);
  }

  /// @inheritdoc IRootMessageOrchestrator
  function setDeallocationReturnCost(uint256 _chainId, uint256 _cost) external {
    if (!VOTER.hasRole(Roles.VOTER_CONFIG_ROLE, msg.sender)) revert CallerNotVoterConfigAuthority();
    // `None` is the default status, so an unregistered chain reads as `None`.
    // slither-disable-next-line unused-return
    (,,,,,,,,, IVoterCommon.ChainStatus _status) = VOTER.chainStates(_chainId);
    if (_status == IVoterCommon.ChainStatus.None) revert ChainNotRegistered(_chainId);
    // `RootLocalAdapter` takes no fee, so a non-zero cost would force senders to match `msg.value` exactly.
    if (_chainId == block.chainid && _cost != 0) revert DeallocationReturnCostNotAllowed();

    deallocationReturnCost[_chainId] = _cost;

    emit DeallocationReturnCostSet(_chainId, _cost);
  }

  /// @inheritdoc IRootMessageOrchestrator
  function withdrawNative(uint256 _amount, address _destination) external {
    if (!VOTER.hasRole(Roles.NATIVE_WITHDRAWER_ROLE, msg.sender)) revert CallerNotNativeWithdrawer();
    if (_destination == address(0)) revert ZeroAddress();
    // slither-disable-next-line arbitrary-send-eth
    (bool _ok,) = _destination.call{value: _amount}('');
    if (!_ok) revert WithdrawFailed();

    emit NativeWithdrawn(_destination, _amount);
  }
}
