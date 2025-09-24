/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MessageOrchestrator} from 'V3/bridge/MessageOrchestrator.sol';
import {
  ILeafMessageOrchestrator,
  ILeafVoter,
  IMessageAdapter,
  IMessageOrchestrator
} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {Roles} from 'V3/libraries/Roles.sol';

/**
 * @title LeafMessageOrchestrator
 * @notice Leaf-side orchestrator, deployed on every chain. Sends outbound messages from the local `LeafVoter` to
 * root and routes inbound root messages back to it.
 * @dev Holds the pre-funding pool that pays root-triggered deallocation returns.
 */
contract LeafMessageOrchestrator is MessageOrchestrator, ILeafMessageOrchestrator {
  /// @inheritdoc ILeafMessageOrchestrator
  ILeafVoter public immutable LEAF_VOTER;

  /// @inheritdoc ILeafMessageOrchestrator
  uint256 public immutable ROOT_CHAIN_ID;

  /// @inheritdoc ILeafMessageOrchestrator
  IMessageAdapter public adapter;
  /// @inheritdoc ILeafMessageOrchestrator
  uint256 public nonceOut;

  /// @inheritdoc ILeafMessageOrchestrator
  mapping(uint256 _nonce => bool _used) public noncesUsed;

  /// @inheritdoc ILeafMessageOrchestrator
  uint256 public deallocationGasLimit;

  /// @inheritdoc ILeafMessageOrchestrator
  uint256 public lastChainVoteNonce;
  /// @inheritdoc ILeafMessageOrchestrator
  mapping(uint256 _tokenId => uint256 _nonce) public lastTokenIdVoteNonce;
  /// @inheritdoc ILeafMessageOrchestrator
  mapping(uint256 _tokenId => uint256 _nonce) public lastOperatorNonce;

  /// @inheritdoc ILeafMessageOrchestrator
  mapping(uint256 _tokenId => uint256 _nonce) public lastEmergencyDeallocNonce;

  /// @inheritdoc ILeafMessageOrchestrator
  mapping(uint256 _tokenId => uint256 _nonce) public lastShapeNonce;

  /**
   * @notice Binds the orchestrator to its local `LeafVoter` and root chain id at deployment.
   * @param _leafVoter Local `LeafVoter`: the only `dispatch` caller, the inbound routing target, and role source.
   * @param _rootChainId Chain id of root; the registered adapter's `REMOTE_CHAIN_ID` must match it.
   */
  constructor(address _leafVoter, uint256 _rootChainId) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (_rootChainId == 0) revert InvalidRootChainId();

    LEAF_VOTER = ILeafVoter(_leafVoter);
    ROOT_CHAIN_ID = _rootChainId;
  }

  /// @notice Accepts the pre-funding that pays root-triggered deallocation returns, plus the transport's refunds.
  receive() external payable {}

  /// @inheritdoc ILeafMessageOrchestrator
  function dispatch(
    MessageType _msgType,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    bool _fundFromPool
  ) external payable {
    if (msg.sender != address(LEAF_VOTER)) revert CallerNotAuthorized();
    if (_msgType != MessageType.Redeem && _msgType != MessageType.Deallocate) revert UnsupportedMessageType();
    IMessageAdapter _adapter = adapter;
    if (address(_adapter) == address(0)) revert AdapterNotRegistered();
    // The `LeafVoter` gates the status: `redeem` is `chainIsActiveOrSunset`, open only while Active or Sunset. A
    // `Deallocate` goes out while Suspended.

    uint256 _nonce = ++nonceOut;
    bytes memory _message = _encodeMessage(_msgType, _nonce, _payload);

    // A pool-funded return refunds back into the pool it drew from; everything else refunds the caller's recipient.
    address _refund = _fundFromPool ? address(this) : _refundRecipient;
    uint256 _budget = _resolveGasLimit(_msgType, _gasLimit);
    uint256 _value = msg.value;

    if (_msgType == MessageType.Deallocate) {
      // Live quote instead of a configured cost, so the fee charged never drifts from the real one.
      uint256 _fee = _adapter.quoteMessage(_message, _budget, _refund);
      if (_fundFromPool) {
        // Checked here so an unfunded draw reverts with this error, not the transport's raw balance failure.
        if (address(this).balance < _fee) revert InsufficientDeallocationMessageValue();
        _value = _fee;
      } else if (_value < _fee) {
        // Caller-funded: the whole value goes out, so the transport refunds the excess to `_refundRecipient`.
        revert InsufficientDeallocationMessageValue();
      }
    }

    _adapter.sendMessage{value: _value}(_message, _budget, _refund);

    emit MessageDispatched(_adapter.REMOTE_CHAIN_ID(), _nonce, _msgType);
  }

  /// @inheritdoc IMessageOrchestrator
  function route(uint256 _originChainId, bytes calldata _payload) external payable {
    if (msg.sender != address(adapter)) revert CallerNotAdapter();

    // No suspension gate: root messages keep applying while Suspended so the leaf repairs itself. The `LeafVoter`
    // masks the applied rate to zero for that window, so no unfunded emissions accrue.
    (MessageType _msgType, uint256 _chainNonce, bytes calldata _body) = _decodeMessage(_payload);

    // Single-use replay gate. No try/catch below: a reverting handler must roll the nonce back so the transport
    // redelivers and the additive `AllocateChain` delta still applies exactly once.
    if (noncesUsed[_chainNonce]) revert NonceAlreadyUsed();
    noncesUsed[_chainNonce] = true;

    // `payable` so a relayer can fund the deallocation return an `AllocateGauge` triggers: the value lands in the
    // pre-funding pool. Value on any other type just tops the pool up, recoverable with `withdrawNative`.

    if (_msgType == MessageType.AllocateChain) {
      _handleAllocateChain(_chainNonce, _body);
    } else if (_msgType == MessageType.AllocateGauge) {
      _handleAllocateGauge(_chainNonce, _body);
    } else if (_msgType == MessageType.ClaimRewards) {
      _handleClaimRewards(_body);
    } else if (_msgType == MessageType.SetOperator) {
      _handleSetOperator(_chainNonce, _body);
    } else if (_msgType == MessageType.ReduceCooldown) {
      _handleReduceCooldown(_body);
    } else if (_msgType == MessageType.EmergencyDeallocate) {
      _handleEmergencyDeallocate(_chainNonce, _body);
    } else {
      revert UnsupportedMessageType();
    }

    emit MessageReceived(_originChainId, _chainNonce, _msgType);
  }

  /// @inheritdoc ILeafMessageOrchestrator
  function setAdapter(IMessageAdapter _adapter) external {
    if (!LEAF_VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, msg.sender)) revert CallerNotAdapterAuthority();
    if (address(_adapter) == address(0)) revert InvalidAdapter();
    // The only authenticated route must point at root, or another chain could authenticate root-only messages.
    if (_adapter.REMOTE_CHAIN_ID() != ROOT_CHAIN_ID) revert AdapterChainIdMismatch();

    adapter = _adapter;

    emit AdapterUpdated(_adapter);
  }

  /// @inheritdoc ILeafMessageOrchestrator
  function setDeallocationGasLimit(uint256 _gasLimit) external {
    if (!LEAF_VOTER.hasRole(Roles.GAS_CONFIGURER_ROLE, msg.sender)) revert CallerNotGasConfigurer();
    if (_gasLimit == 0) revert ZeroGasLimit();

    deallocationGasLimit = _gasLimit;

    emit DeallocationGasLimitSet(_gasLimit);
  }

  /// @inheritdoc ILeafMessageOrchestrator
  function withdrawNative(uint256 _amount, address _destination) external {
    if (!LEAF_VOTER.hasRole(Roles.NATIVE_WITHDRAWER_ROLE, msg.sender)) revert CallerNotNativeWithdrawer();
    if (_destination == address(0)) revert ZeroAddress();
    // slither-disable-next-line arbitrary-send-eth
    (bool _ok,) = _destination.call{value: _amount}('');
    if (!_ok) revert WithdrawFailed();

    emit NativeWithdrawn(_destination, _amount);
  }

  /// @inheritdoc ILeafMessageOrchestrator
  function quoteDispatch(
    MessageType _msgType,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient
  ) external view returns (uint256 _fee) {
    IMessageAdapter _adapter = adapter;
    if (address(_adapter) == address(0)) revert AdapterNotRegistered();

    // Price the wrapped envelope, not the bare payload. The header is fixed-width, so the nonce cannot move the
    // quote and a dispatch landing in between cannot invalidate it.
    _fee = _adapter.quoteMessage(
      _encodeMessage(_msgType, nonceOut + 1, _payload), _resolveGasLimit(_msgType, _gasLimit), _refundRecipient
    );
  }

  /**
   * @notice Applies an inbound `AllocateChain`: adds the tokenId's chain VP delta and, when newest, refreshes the
   *         emissions scalar.
   * @dev The delta is additive and applies once per message, so message order does not matter and an in-flight
   *      message can never bring back a budget the leaf-first `deallocate` already cleared.
   * @dev `lastChainVoteNonce` is the newest nonce seen, and it gates the `emissionsPerVP` scalar only.
   * @param _chainNonce Inbound nonce carried by the message.
   * @param _body Encoded `AllocateChainMessage` body.
   */
  function _handleAllocateChain(uint256 _chainNonce, bytes calldata _body) internal {
    IVoterCommon.AllocateChainMessage memory _message = abi.decode(_body, (IVoterCommon.AllocateChainMessage));

    // A message sent at or before the token's last emergency deallocation carries pre-drain state, so it must
    // bring back neither the cleared budget nor the stale scalar.
    bool _preEmergency = _chainNonce <= lastEmergencyDeallocNonce[_message.tokenId];
    uint128 _allocationDelta = _preEmergency ? 0 : _message.allocationDelta;

    // A pre-emergency nonce can sit above the newest seen, so exclude it here too.
    bool _isNewestChainVote = !_preEmergency && _chainNonce > lastChainVoteNonce;
    if (_isNewestChainVote) lastChainVoteNonce = _chainNonce;

    // Newest across chain and gauge only, so a delayed gauge vote cannot bring back an older shape.
    bool _refreshShape = !_preEmergency && _chainNonce > lastShapeNonce[_message.tokenId];
    if (_refreshShape) lastShapeNonce[_message.tokenId] = _chainNonce;

    LEAF_VOTER.applyChainAllocation({
      _tokenId: _message.tokenId,
      _allocationDelta: _allocationDelta,
      _emissionsPerVP: _message.emissionsPerVP,
      _refreshEmissionsPerVP: _isNewestChainVote,
      _refreshShape: _refreshShape,
      _snapshot: _message.snapshot
    });
  }

  /**
   * @notice Applies an inbound `AllocateGauge`: distributes the tokenId's chain budget across gauges.
   * @dev Gated by the tokenId's allocation nonce; a stale message returns without distributing.
   * @dev The leaf reverts `CooldownActive` while the cooldown runs, and a failing per-gauge checkpoint reverts too.
   *      Either way the whole message reverts, so the reduction is not spent and the transport redelivers it —
   *      safe because the message carries no voting power.
   * @dev After an emergency deallocation only the token's newest-seen nonce moves, so a vote in that gap
   *      loses its scalar refresh. Bounded: the chain is Suspended and the next message refreshes it.
   * @param _chainNonce Inbound nonce carried by the message.
   * @param _body Encoded `AllocateGaugeMessage` body.
   */
  function _handleAllocateGauge(uint256 _chainNonce, bytes calldata _body) internal {
    IVoterCommon.AllocateGaugeMessage memory _message = abi.decode(_body, (IVoterCommon.AllocateGaugeMessage));
    uint256 _tokenId = _message.tokenId;

    // Newest wins: a newer allocation already set this token's gauges, so a stale one is dropped.
    if (_chainNonce <= lastTokenIdVoteNonce[_tokenId]) {
      return;
    }
    lastTokenIdVoteNonce[_tokenId] = _chainNonce;

    bool _isNewestChainVote = _chainNonce > lastChainVoteNonce;
    if (_isNewestChainVote) lastChainVoteNonce = _chainNonce;

    // A gauge vote older than a later chain reallocation books at the current shape, not its own stale one.
    bool _refreshShape = _chainNonce > lastShapeNonce[_tokenId];
    if (_refreshShape) lastShapeNonce[_tokenId] = _chainNonce;

    // No value rides into the leaf: inbound value stays here as the pre-funding a triggered return draws from.
    // The reward checkpoints below are `LeafVoter` bookkeeping, not calls into the gauges.
    // slither-disable-next-line unused-return
    LEAF_VOTER.applyGaugeAllocations({
      _tokenId: _tokenId,
      _expiry: _message.expiry,
      _emissionsPerVP: _message.emissionsPerVP,
      _refreshEmissionsPerVP: _isNewestChainVote,
      _refreshShape: _refreshShape,
      _newSnapshot: _message.tokenSnapshot,
      _gauges: _message.allocations
    });
  }

  /**
   * @notice Claims fees and incentives from an inbound `ClaimRewards` message.
   * @dev Past the root-stamped expiry the claim is dropped with `ExpiredMessageDropped` instead of reverting:
   *      an expired message never becomes executable, so the transport nonce `route` consumed must stay spent.
   *      The recipient was fixed at dispatch, so a claim stalled past a root-side token transfer must not still
   *      pay the previous owner.
   * @param _body Encoded reward claim body.
   */
  function _handleClaimRewards(bytes calldata _body) internal {
    (
      uint256 _tokenId,
      uint48 _expiry,
      address _recipient,
      ILeafVoter.FeeClaim[] memory _feeClaims,
      ILeafVoter.IncentiveClaim[] memory _incentiveClaims
    ) = abi.decode(_body, (uint256, uint48, address, ILeafVoter.FeeClaim[], ILeafVoter.IncentiveClaim[]));

    if (_expiry < block.timestamp) {
      emit ExpiredMessageDropped(MessageType.ClaimRewards, _tokenId);
      return;
    }

    LEAF_VOTER.claimRewards(_tokenId, _recipient, _feeClaims, _incentiveClaims);
  }

  /**
   * @notice Propagates a per-tokenId operator assignment into the LeafVoter's mirror.
   * @dev Gated by the tokenId's operator nonce (`lastOperatorNonce`); a stale message returns without applying.
   * @dev Past the root-stamped expiry the assignment is dropped with `ExpiredMessageDropped` instead of reverting,
   *      but only after advancing the operator nonce: an expired message never becomes executable, and committing
   *      its nonce keeps older in-flight assignments from applying after it. A stalled assignment must not install
   *      an operator chosen before the token changed hands on root.
   * @param _chainNonce Inbound nonce carried by the message.
   * @param _body Encoded `OperatorMessage` body.
   */
  function _handleSetOperator(uint256 _chainNonce, bytes calldata _body) internal {
    IVoterCommon.OperatorMessage memory _operatorMessage = abi.decode(_body, (IVoterCommon.OperatorMessage));
    uint256 _tokenId = _operatorMessage.tokenId;

    if (_chainNonce <= lastOperatorNonce[_tokenId]) return;
    lastOperatorNonce[_tokenId] = _chainNonce;

    if (_operatorMessage.expiry < block.timestamp) {
      emit ExpiredMessageDropped(MessageType.SetOperator, _tokenId);
      return;
    }

    LEAF_VOTER.setOperator(_tokenId, _operatorMessage.operator);
  }

  /**
   * @notice Accrues a tokenId's pending cooldown reduction from an inbound `ReduceCooldown`.
   * @dev No nonce gate: reductions add up, so order does not matter and `route` already applies each message once.
   * @param _body Encoded `ReduceCooldownMessage` body.
   */
  function _handleReduceCooldown(bytes calldata _body) internal {
    IVoterCommon.ReduceCooldownMessage memory _message = abi.decode(_body, (IVoterCommon.ReduceCooldownMessage));
    LEAF_VOTER.applyCooldownReduction(_message.tokenId, _message.reduction);
  }

  /**
   * @notice Applies an inbound `EmergencyDeallocate`: clears the token's gauges and cuts its chain budget by the
   *         drained amount. Runs while the chain is Suspended.
   * @dev No ordering gate: a fixed amount is subtracted once. A post-resume delta applied after it over-subtracts,
   *      so governance must not resume until this lands — see the precondition on `IVoter.setChainStatus`.
   * @dev Advances both newest-seen nonces: the gauge one blocks a stale re-distribution, the emergency one makes
   *      `_handleAllocateChain` drop pre-drain deltas.
   * @param _chainNonce Inbound nonce carried by the message.
   * @param _body Encoded `EmergencyDeallocateMessage` body.
   */
  function _handleEmergencyDeallocate(uint256 _chainNonce, bytes calldata _body) internal {
    IVoterCommon.EmergencyDeallocateMessage memory _message =
      abi.decode(_body, (IVoterCommon.EmergencyDeallocateMessage));
    uint256 _tokenId = _message.tokenId;

    if (_chainNonce > lastTokenIdVoteNonce[_tokenId]) lastTokenIdVoteNonce[_tokenId] = _chainNonce;
    // Keep the HIGHEST emergency nonce: a late older one must not un-guard a delta a newer one already drained.
    if (_chainNonce > lastEmergencyDeallocNonce[_tokenId]) lastEmergencyDeallocNonce[_tokenId] = _chainNonce;

    LEAF_VOTER.applyEmergencyDeallocation(_tokenId, _message.amount);
  }

  /**
   * @notice Destination gas budget: the configured `deallocationGasLimit` for a `Deallocate`, `_supplied` otherwise.
   * @dev A `Deallocate` is quoted against this budget, so reading it from config keeps quote and send in sync.
   * @param _msgType Message type being dispatched or quoted.
   * @param _supplied Gas limit the caller passed.
   * @return _budget Gas limit to stamp on the message.
   */
  function _resolveGasLimit(MessageType _msgType, uint256 _supplied) internal view returns (uint256 _budget) {
    _budget = _msgType == MessageType.Deallocate ? deallocationGasLimit : _supplied;
  }
}
