// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/**
 * @title  IRelayState
 * @notice The part of the Relay's own external interface that the closing gate and the allocation
 *         reserve read back through self-calls (cheaper on the contract side than passing the
 *         values as call parameters).
 */
interface IRelayState {
  /// @notice The VotingEscrow holding the Relay's stake, whose amount caps what the queue can be
  ///         owed once every pending donation is recognized.
  /// @return The escrow.
  function VOTING_ESCROW() external view returns (IVotingEscrow);

  /// @notice The Relay's configuration block.
  /// @return _config The full configuration struct.
  function relayConfig() external view returns (IRelay.RelayConfig memory _config);

  /// @notice The Relay's backing counter.
  /// @return The current backing.
  function totalBacking() external view returns (uint256);

  /// @notice Shares escrowed across the queued, undrained withdrawals.
  /// @return The escrowed-share total.
  function pendingWithdrawalShares() external view returns (uint256);

  /// @notice Weight parked for queued, undrained deposits, which the stake holds but the shares do
  ///         not own yet.
  /// @return The pending-deposit weight.
  function pendingDepositWeight() external view returns (uint256);

  /// @notice The Relay's principal token, whose supply prices the escrowed shares.
  /// @return The principal token.
  function principalToken() external view returns (IRelayToken);

  /// @notice The Relay's yield token, banned from the reward registry along with the principal.
  /// @return The yield token.
  function yieldToken() external view returns (IRelayToken);
}
