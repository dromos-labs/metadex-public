// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title  IGovernor
 * @notice Minimal surface of the tokenId-keyed Governor the Relay forwards fractional votes to. The
 *         real Governor (GovernorSimple + fractional counting) exposes far more; the Relay only needs
 *         the proposal snapshot and the parameterized cast.
 */
interface IGovernor {
  /**
   * @notice Cast a vote for `_tokenId` with a reason and counting-module params (fractional support).
   * @param _proposalId Proposal being voted on.
   * @param _tokenId sAERO whose voting power backs the cast; the caller must be its owner or approved.
   * @param _support Counting-module support: 0 Against, 1 For, 2 Abstain, 255 fractional.
   * @param _reason Free-form reason string attached to the cast.
   * @param _params Counting-module params; for fractional support, three packed `uint128` weights
   *        (against, for, abstain).
   * @return _weight Voting weight the Governor consumed for this cast.
   */
  function castVoteWithReasonAndParams(
    uint256 _proposalId,
    uint256 _tokenId,
    uint8 _support,
    string calldata _reason,
    bytes memory _params
  ) external returns (uint256 _weight);

  /**
   * @notice Timepoint (EIP-6372 timestamp mode) at which voting power for a proposal is snapshotted.
   * @param _proposalId Proposal being queried.
   * @return _snapshot The proposal's snapshot timestamp.
   */
  function proposalSnapshot(uint256 _proposalId) external view returns (uint256 _snapshot);
}
