/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IRootLocalAdapter} from 'V3/interfaces/bridge/IRootLocalAdapter.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';

/**
 * @title RootLocalAdapter
 * @notice Local adapter deployed only on root that connects the `RootMessageOrchestrator` and the on-root
 * `LeafMessageOrchestrator` in the same transaction.
 * @dev Has no underlying transport and no remote counterpart, so only `sendMessage` carries logic; `handle` and
 * `setRemoteAdapter` revert, they exist solely to satisfy the `IMessageAdapter` interface.
 */
contract RootLocalAdapter is IRootLocalAdapter {
  /// @inheritdoc IMessageAdapter
  uint256 public immutable REMOTE_CHAIN_ID = block.chainid;
  /// @inheritdoc IRootLocalAdapter
  address public immutable ROOT_MESSAGE_ORCHESTRATOR;
  /// @inheritdoc IRootLocalAdapter
  address public immutable LEAF_MESSAGE_ORCHESTRATOR;

  /**
   * @notice Binds the adapter to the root chain and its two orchestrators at deployment.
   * @param _rootMessageOrchestrator Address of the `RootMessageOrchestrator` to bind this adapter to.
   * @param _leafMessageOrchestrator Address of the on-root `LeafMessageOrchestrator` to bind this adapter to.
   */
  constructor(address _rootMessageOrchestrator, address _leafMessageOrchestrator) {
    if (_rootMessageOrchestrator == address(0)) revert ZeroAddress();
    if (_leafMessageOrchestrator == address(0)) revert ZeroAddress();
    if (_rootMessageOrchestrator == _leafMessageOrchestrator) revert IdenticalOrchestrators();
    ROOT_MESSAGE_ORCHESTRATOR = _rootMessageOrchestrator;
    LEAF_MESSAGE_ORCHESTRATOR = _leafMessageOrchestrator;
  }

  // slither-disable-start locked-ether
  /// @inheritdoc IMessageAdapter
  function sendMessage(bytes calldata _message, uint256, address) external payable {
    if (msg.value != 0) revert NoFeeRequired();

    // The caller determines the local target: root orchestrator routes to leaf, leaf orchestrator routes to root.
    if (msg.sender == ROOT_MESSAGE_ORCHESTRATOR) {
      ILeafMessageOrchestrator(LEAF_MESSAGE_ORCHESTRATOR).route(REMOTE_CHAIN_ID, _message);
    } else if (msg.sender == LEAF_MESSAGE_ORCHESTRATOR) {
      IRootMessageOrchestrator(ROOT_MESSAGE_ORCHESTRATOR).route(REMOTE_CHAIN_ID, _message);
    } else {
      revert CallerNotOrchestrator();
    }
  }

  // slither-disable-end locked-ether
  /// @inheritdoc IMessageAdapter
  function handle(uint32, bytes32, bytes calldata) external payable {
    revert NotSupported();
  }

  /// @inheritdoc IMessageAdapter
  function quoteMessage(bytes calldata, uint256, address) external pure returns (uint256 _fee) {
    // In-process delivery, no transport to pay: `sendMessage` rejects any value, so the matching quote is zero.
    _fee = 0;
  }

  /// @inheritdoc IMessageAdapter
  function setRemoteAdapter(bytes32) external pure {
    revert NotSupported();
  }
}
