// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';

/**
 * @title  IRelayGovernanceHost
 * @notice The slice of a Relay that `RelayGovernanceLib`'s view helpers read from the outside when
 *         they price a holder's governance slice: the satellite and the sAERO the slice is carved
 *         from, the Governor the proposal snapshot comes from, and the per-proposal consumption
 *         ledger.
 * @dev A duplicated-slice interface, the accepted repo pattern (see `IRelayEntrypoint`'s dev note).
 *      The vote path never uses this: the library runs inside the Relay by delegatecall, so it reads
 *      the same values from the Relay's own immutables and storage.
 */
interface IRelayGovernanceHost {
  /// @notice The Relay's principal token (PT), whose checkpoints size every slice.
  /// @return _principalToken The principal-token clone address.
  function principalToken() external view returns (address _principalToken);

  /// @notice The Relay's configuration block, read for its sAERO tokenId.
  /// @return _config The full configuration struct.
  function relayConfig() external view returns (IRelay.RelayConfig memory _config);

  /// @notice Voting weight `_holder` has already consumed on `_proposalId` under `_governor`.
  /// @param _governor Governor the spend was booked against.
  /// @param _proposalId Proposal being queried.
  /// @param _holder Principal-token holder being queried.
  /// @return _used Weight already spent from the holder's snapshot slice.
  function usedGovernanceWeight(
    address _governor,
    uint256 _proposalId,
    address _holder
  ) external view returns (uint256 _used);

  /// @notice VotingEscrow the Relay's snapshot governance weight is read from.
  /// @return _votingEscrow The VotingEscrow contract.
  function VOTING_ESCROW() external view returns (IVotingEscrow _votingEscrow);

  /// @notice Governor the Relay casts its fractional votes into.
  /// @return _governor The Governor contract.
  function governor() external view returns (IGovernor _governor);

  /// @notice Adapter translating casts into the current Governor's dialect.
  /// @return _voteAdapter The vote adapter.
  function voteAdapter() external view returns (IRelayVoteAdapter _voteAdapter);
}
