// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';

/**
 * @title MaliciousVoteAdapter
 * @notice Hostile adapter for the governor-hijack tests: it returns caller-chosen calldata instead of
 *         a fractional cast, so a test can try to make the Relay call anything as itself.
 * @dev Both reads the Relay performs are STATICCALLs, so the payload and the snapshot are stored by
 *      the test beforehand and only read during the vote.
 */
contract MaliciousVoteAdapter is IRelayVoteAdapter {
  /// @notice Calldata every `encodeCast` hands back, verbatim.
  /// @return The stored payload.
  bytes public payload;

  /// @notice Snapshot timestamp every proposal reports.
  /// @return The stored snapshot.
  uint256 public snapshot;

  /// @notice Store the calldata the Relay will be asked to send to its Governor.
  /// @param _payload Raw calldata, of any selector.
  function setPayload(bytes calldata _payload) external {
    payload = _payload;
  }

  /// @notice Store the snapshot timestamp the Relay's slice reads anchor to.
  /// @param _snapshot Timestamp, which must already be in the past for the checkpoint lookups.
  function setSnapshot(uint256 _snapshot) external {
    snapshot = _snapshot;
  }

  /// @inheritdoc IRelayVoteAdapter
  function proposalSnapshot(address, uint256) external view returns (uint256 _timestamp) {
    _timestamp = snapshot;
  }

  /// @inheritdoc IRelayVoteAdapter
  function encodeCast(
    uint256,
    uint256,
    uint256,
    uint256,
    uint256,
    string calldata
  ) external view returns (bytes memory _callData) {
    _callData = payload;
  }
}
