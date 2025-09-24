/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IHyperlaneAdapter, IMessageAdapter} from 'V3/interfaces/bridge/hyperlane/IHyperlaneAdapter.sol';
import {Roles} from 'V3/libraries/Roles.sol';

/**
 * @title HyperlaneAdapter
 * @notice Transport adapter backed by the Hyperlane mailbox, deployed on root and every leaf chain.
 * @dev Bound to a single remote pair at deployment via the `REMOTE_DOMAIN_ID` and `REMOTE_CHAIN_ID` immutables; only
 * the counterpart address (`remoteAdapter`) can be updated by holders of `ADAPTER_CONFIG_ROLE` on `VOTER`.
 */
contract HyperlaneAdapter is IHyperlaneAdapter {
  /// @inheritdoc IMessageAdapter
  uint256 public immutable REMOTE_CHAIN_ID;
  /// @inheritdoc IHyperlaneAdapter
  uint32 public immutable REMOTE_DOMAIN_ID;
  /// @inheritdoc IHyperlaneAdapter
  IMessageOrchestrator public immutable ORCHESTRATOR;
  /// @inheritdoc IHyperlaneAdapter
  IMailbox public immutable MAILBOX;
  /// @inheritdoc IHyperlaneAdapter
  IAccessControl public immutable VOTER;

  /// @inheritdoc IHyperlaneAdapter
  bytes32 public remoteAdapter;

  /**
   * @notice Binds the adapter to its counterpart chain at deployment.
   * @param _remoteChainId Chain id of the counterpart chain.
   * @param _remoteDomainId Hyperlane domain id of the counterpart chain.
   * @param _orchestrator Local `MessageOrchestrator` bound to this adapter.
   * @param _mailbox Hyperlane mailbox on this chain.
   * @param _voter Local voter (`Voter` on root, `LeafVoter` on leaves) whose `ADAPTER_CONFIG_ROLE` gates
   *               `setRemoteAdapter`.
   */
  constructor(uint256 _remoteChainId, uint32 _remoteDomainId, address _orchestrator, address _mailbox, address _voter) {
    if (_remoteChainId == 0) revert InvalidChainId();
    if (_remoteChainId == block.chainid) revert InvalidChainId();
    if (_remoteDomainId == 0) revert InvalidDomain();
    if (_orchestrator == address(0)) revert ZeroAddress();
    if (_mailbox == address(0)) revert ZeroAddress();
    if (_voter == address(0)) revert ZeroAddress();
    // Hyperlane routes by domain id, so a remote domain equal to the local one is a transport self-loop.
    if (_remoteDomainId == IMailbox(_mailbox).localDomain()) revert InvalidDomain();

    REMOTE_CHAIN_ID = _remoteChainId;
    REMOTE_DOMAIN_ID = _remoteDomainId;
    ORCHESTRATOR = IMessageOrchestrator(_orchestrator);
    MAILBOX = IMailbox(_mailbox);
    VOTER = IAccessControl(_voter);
  }

  /// @inheritdoc IMessageAdapter
  function sendMessage(bytes calldata _message, uint256 _gasLimit, address _refundRecipient) external payable {
    if (msg.sender != address(ORCHESTRATOR)) revert CallerNotOrchestrator();
    if (_gasLimit == 0) revert InvalidGasLimit();
    bytes32 _remoteAdapter = remoteAdapter;
    if (_remoteAdapter == bytes32(0)) revert RemoteAdapterNotSet();

    bytes32 _messageId = MAILBOX.dispatch{value: msg.value}(
      REMOTE_DOMAIN_ID, _remoteAdapter, _message, StandardHookMetadata.format(0, _gasLimit, _refundRecipient)
    );

    emit MessageSent(_messageId, _remoteAdapter);
  }

  /// @inheritdoc IMessageAdapter
  function handle(uint32 _origin, bytes32 _sender, bytes calldata _message) external payable {
    if (msg.sender != address(MAILBOX)) revert CallerNotMailbox();
    if (_origin != REMOTE_DOMAIN_ID) revert UnauthorizedOrigin();
    bytes32 _remoteAdapter = remoteAdapter;
    if (_remoteAdapter == bytes32(0)) revert RemoteAdapterNotSet();
    if (_sender != _remoteAdapter) revert UnauthorizedSender();

    ORCHESTRATOR.route{value: msg.value}(REMOTE_CHAIN_ID, _message);
  }

  /// @inheritdoc IMessageAdapter
  function setRemoteAdapter(bytes32 _remoteAdapter) external {
    if (!VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, msg.sender)) revert CallerNotAdapterAuthority();
    if (_remoteAdapter == bytes32(0)) revert InvalidRemoteAdapter();

    remoteAdapter = _remoteAdapter;

    emit RemoteAdapterUpdated(_remoteAdapter);
  }

  /// @inheritdoc IMessageAdapter
  function quoteMessage(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external view returns (uint256 _fee) {
    if (_gasLimit == 0) revert InvalidGasLimit();
    bytes32 _remoteAdapter = remoteAdapter;
    if (_remoteAdapter == bytes32(0)) revert RemoteAdapterNotSet();

    // Quote against the exact arguments `sendMessage` dispatches with: the interchain gas payment is priced off
    // the gas limit encoded in the hook metadata, so quoting without it would return the default-gas fee.
    _fee = MAILBOX.quoteDispatch(
      REMOTE_DOMAIN_ID, _remoteAdapter, _message, StandardHookMetadata.format(0, _gasLimit, _refundRecipient)
    );
  }
}
