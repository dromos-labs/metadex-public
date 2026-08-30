// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {RelayBase} from 'V3/relay/RelayBase.sol';

/**
 * @title  MaxiRelay
 * @notice Public Relay tier: deposits are permissionless. It inherits the authorization hooks from
 *         RelayBase and leaves them open (no whitelist). It keeps a single fixed reward token: the
 *         registry locks after the first token is added. There is no sweep and no L2 promotion, so
 *         the SWEEPER role does not exist on this tier.
 */
contract MaxiRelay is RelayBase {
  /// @notice Store the protocol-wide dependencies in the implementation. Per-Relay state is set in
  ///         `initialize` on each clone. All logic lives in RelayBase.
  /// @param _votingEscrow VotingEscrow address.
  /// @param _voter Voter address.
  /// @param _principalTokenImplementation Checkpointed RelayToken implementation cloned as the PT.
  /// @param _yieldTokenImplementation Plain RelayToken implementation cloned as the YT.
  /// @param _wrappedNative Wrapped native token every native inflow is wrapped into.
  constructor(
    IVotingEscrow _votingEscrow,
    IVoter _voter,
    address _principalTokenImplementation,
    address _yieldTokenImplementation,
    address _wrappedNative
  ) RelayBase(_votingEscrow, _voter, _principalTokenImplementation, _yieldTokenImplementation, _wrappedNative) {}

  /// @inheritdoc RelayBase
  function relayType() external pure override returns (RelayType _relayType) {
    _relayType = RelayType.Maxi;
  }
}
