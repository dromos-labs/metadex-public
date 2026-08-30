// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title V2 Epoch Governor Interface
 * @notice Minimal V2 epoch governor interface used by Migration
 */
interface IV2EpochGovernor {
  /**
   * @notice State of a v2 epoch governor proposal
   */
  enum ProposalState {
    Pending,
    Active,
    Canceled,
    Defeated,
    Succeeded,
    Queued,
    Expired,
    Executed
  }

  /**
   * @notice Returns the most recent voting result
   * @dev Stores most recent voting result. Will be either Defeated, Succeeded or Expired.
   *      Any contracts that wish to use this governor must read from this to determine results.
   * @return The most recent voting result
   */
  function result() external returns (ProposalState);
}
