// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {AllocationLib} from 'V3/relay/libraries/AllocationLib.sol';

/**
 * @title AllocationLibHarness
 * @notice Test harness driving AllocationLib. It serves the slice of the Relay surface `allocate`
 *         reads back through self-calls (`VOTING_ESCROW`, `principalToken`,
 *         `pendingWithdrawalShares`, `pendingDepositWeight`), with plain setters to preset the two
 *         counters.
 * @dev The library is delegatecalled from here, so `msg.value` inside it is the value sent to the
 *      wrapper and its self-calls land on this harness.
 */
contract AllocationLibHarness {
  /// @notice The escrow whose stake caps what the withdraw queue can end up owed.
  IVotingEscrow public immutable VOTING_ESCROW;

  /// @notice The principal token whose supply prices the escrowed shares.
  IRelayToken public principalToken;

  /// @notice Shares escrowed across the queued, undrained withdrawals.
  uint256 public pendingWithdrawalShares;

  /// @notice Weight parked for queued, undrained deposits.
  uint256 public pendingDepositWeight;

  constructor(IVotingEscrow _votingEscrow) {
    VOTING_ESCROW = _votingEscrow;
  }

  /// @notice Preset the principal token address.
  function setPrincipalToken(IRelayToken _principalToken) external {
    principalToken = _principalToken;
  }

  /// @notice Preset the two queue counters the reserve prices against.
  function setQueueCounters(uint256 _pendingWithdrawalShares, uint256 _pendingDepositWeight) external {
    pendingWithdrawalShares = _pendingWithdrawalShares;
    pendingDepositWeight = _pendingDepositWeight;
  }

  /// @notice Drive `AllocationLib.allocate`.
  function allocate(
    IVoter _voter,
    uint256 _tokenId,
    IVoter.ChainAllocationDispatch[] calldata _chainDispatches,
    IVoter.GaugeAllocationDispatch[] calldata _gaugeDispatches,
    address _refundRecipient
  ) external payable {
    AllocationLib.allocate(_voter, _tokenId, _chainDispatches, _gaugeDispatches, _refundRecipient);
  }

  /// @notice Drive `AllocationLib.evacuate`.
  function evacuate(
    IVoter _voter,
    uint256 _tokenId,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient
  ) external payable {
    AllocationLib.evacuate(_voter, _tokenId, _chainId, _gasLimit, _refundRecipient);
  }
}
