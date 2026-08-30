// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {ProtocolRelay} from 'V3/relay/ProtocolRelay.sol';

/// @notice Exposes the ProtocolRelay seams no deployable configuration can reach, so their guards
///         stay covered: the allow-list transfer gate (the tier's YT is always soulbound, so the
///         token's own gate reverts before the hook consults this seam) and sweep's defensive
///         level check (SWEEPER is grantable only once L2, so production never sees L1 + SWEEPER).
contract ProtocolRelaySeamsHarness is ProtocolRelay {
  constructor(
    IVotingEscrow _votingEscrow,
    IVoter _voter,
    address _principalTokenImplementation,
    address _yieldTokenImplementation,
    address _wrappedNative
  ) ProtocolRelay(_votingEscrow, _voter, _principalTokenImplementation, _yieldTokenImplementation, _wrappedNative) {}

  /// @notice Run the tier transfer seam directly.
  function exposed_authorizeTransfer(address _from, address _to) external view {
    _authorizeTransfer(_from, _to);
  }

  /// @notice Flip an account's allow-list flag without the ADMIN gate.
  function exposed_setAllowed(address _account, bool _allowed) external {
    allowList[_account] = _allowed;
  }

  /// @notice Grant role bits bypassing the owner gate, to stage unreachable role/tier combos.
  function exposed_grantRoles(address _account, uint256 _roles) external {
    _grantRoles(_account, _roles);
  }
}
