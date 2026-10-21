// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title  IRelayVoteAdapter
 * @notice Translates the Relay's canonical cast — an (against, for, abstain) split — into the
 *         Governor's ABI, so a Governor upgrade is an adapter swap instead of a Relay redeploy.
 * @dev    Consulted by STATICCALL only and MUST hold no storage (immutables are fine): the EVM then
 *         guarantees an adapter cannot write, log or reenter. The adapter never names the call
 *         target — the Relay sends the returned calldata to its own stored Governor, and only when
 *         its selector is the fractional cast — so a hostile adapter can miscode a vote but never
 *         make the Relay call anything else as itself. `proposalSnapshot`
 *         MUST return a timestamp (the PT and VE checkpoint clock); an adapter for a block-number
 *         Governor must convert.
 */
interface IRelayVoteAdapter {
  /// @notice Thrown when a split component does not fit the width the Governor dialect encodes.
  error UnrepresentableWeight();

  /// @notice The timepoint `_governor` snapshots voting power at for `_proposalId`.
  /// @param _governor Governor the proposal lives on.
  /// @param _proposalId Proposal being queried.
  /// @return _timestamp The proposal's snapshot timestamp.
  function proposalSnapshot(address _governor, uint256 _proposalId) external view returns (uint256 _timestamp);

  /// @notice Encode one partial cast into the Governor dialect.
  /// @param _proposalId Proposal being voted on.
  /// @param _tokenId The Relay's sAERO whose weight backs the cast.
  /// @param _against Weight cast against.
  /// @param _for Weight cast in favor.
  /// @param _abstain Weight cast as abstention.
  /// @param _reason Free-form reason string to attach.
  /// @return _callData Calldata the Relay sends to its stored Governor, verbatim.
  function encodeCast(
    uint256 _proposalId,
    uint256 _tokenId,
    uint256 _against,
    uint256 _for,
    uint256 _abstain,
    string calldata _reason
  ) external view returns (bytes memory _callData);
}
