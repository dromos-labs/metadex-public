// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/**
 * @title  IRelayState
 * @notice The part of the Relay's own external interface that its libraries read back through
 *         self-calls.
 */
interface IRelayState {
  /// @notice The VotingEscrow holding the Relay's stake, whose staked amount is the upper bound of
  ///         what the queue can be owed.
  /// @return The escrow.
  function VOTING_ESCROW() external view returns (IVotingEscrow);

  /// @notice The protocol TOKEN staked behind the Relay's sAERO.
  /// @return The protocol TOKEN address.
  function TOKEN() external view returns (address);

  /// @notice Checkpointed RelayToken implementation cloned as the principal token.
  /// @return The principal-token implementation address.
  function PRINCIPAL_TOKEN_IMPLEMENTATION() external view returns (address);

  /// @notice Plain RelayToken implementation cloned as the yield token.
  /// @return The yield-token implementation address.
  function YIELD_TOKEN_IMPLEMENTATION() external view returns (address);

  /// @notice The Relay's configuration block.
  /// @return _config The full configuration struct.
  function relayConfig() external view returns (IRelay.RelayConfig memory _config);

  /// @notice The Relay's backing counter.
  /// @return The current backing.
  function totalBacking() external view returns (uint256);

  /// @notice Shares escrowed across the queued, undrained withdrawals.
  /// @return The escrowed-share total.
  function pendingWithdrawalShares() external view returns (uint256);

  /// @notice The Relay's principal token, whose supply prices the escrowed shares.
  /// @return The principal token.
  function principalToken() external view returns (IRelayToken);

  /// @notice The Relay's yield token, banned from the reward registry along with the principal.
  /// @return The yield token.
  function yieldToken() external view returns (IRelayToken);

  /// @notice Ceiling of each rake rate, in pips.
  /// @return The rake ceiling.
  function MAX_RAKE_PIPS() external view returns (uint256);

  /// @notice Factory that initialized the Relay; it names the rake treasury.
  /// @return The factory address.
  function factory() external view returns (address);
}
