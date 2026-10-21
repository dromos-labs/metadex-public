// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title  IRelayTokenVotes
 * @notice The checkpointed surface of a principal-token (PT) satellite deployed by a voting Relay:
 *         the historical voting reads the Relay's Flexible Voting lane sizes a holder's cast
 *         against, plus the delegate getter that proves self-delegation happened.
 * @dev    Includes only the duplicated `ERC20Votes` slice the Relay consumes — duplicated-slice
 *         interfaces are accepted repo precedent, see IRelayEntrypoint's dev note. The PT is
 *         soulbound, so every checkpoint in this history was written by a Relay mint or burn: the
 *         history is a deposit/withdraw history, never a trading history.
 */
interface IRelayTokenVotes {
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    FUNCTIONS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice The voting units `_account` controlled at or before `_timepoint`.
  /// @param _account Delegate whose checkpoint history is read.
  /// @param _timepoint Timestamp to read at; must be strictly in the past.
  /// @return _votes The checkpointed voting units at `_timepoint`.
  /// @dev The clock is timestamps (ERC-6372 `mode=timestamp`), matching VotingEscrow, so one
  ///      Governor proposal snapshot is a valid input to both contracts.
  function getPastVotes(address _account, uint256 _timepoint) external view returns (uint256 _votes);

  /// @notice The total voting units at or before `_timepoint`: the checkpointed PT supply.
  /// @param _timepoint Timestamp to read at; must be strictly in the past.
  /// @return _totalVotes The checkpointed total voting units at `_timepoint`.
  function getPastVotesTotalSupply(uint256 _timepoint) external view returns (uint256 _totalVotes);

  /// @notice The current voting delegate of `_delegator`.
  /// @param _delegator Holder whose delegate is read.
  /// @return _delegatee The delegate, or the zero address when the holder never held PT.
  /// @dev Every first-time PT recipient is self-delegated on receipt, so a depositor never reads
  ///      zero voting power for lack of a manual `delegate` call.
  function delegates(address _delegator) external view returns (address _delegatee);
}
