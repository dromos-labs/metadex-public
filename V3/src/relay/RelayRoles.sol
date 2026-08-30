// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title  RelayRoles
 * @notice Single source of truth for the Relay's OwnableRoles role bits. The Relay base inherits
 *         this contract, so every tier shares the same bits and exposes them as public getters.
 *         Role management is the owner's: the owner grants and revokes every bit and holds the
 *         admin gates itself, so no admin role exists.
 * @dev Pure constants, no storage or logic. Each role is one bit of solady's OwnableRoles mask, so
 *      a combined check is a single OR. The L2-only SWEEPER bit lives here too so every identifier
 *      sits in one place; only ProtocolRelay grants and uses it.
 */
abstract contract RelayRoles {
  /// @notice Operator role present on every tier. It triggers entrypoint operations, deposit
  ///         processing and the Relay-side cross-chain functions. The account allow list is managed
  ///         by the owner, not by KEEPER.
  /// @return The KEEPER role bit.
  uint256 public constant KEEPER = 1 << 0;

  /// @notice Operator role that sets the allocation intent. Casting the vote itself is permissionless.
  /// @return The VOTER_ROLE bit.
  uint256 public constant VOTER_ROLE = 1 << 1;

  /// @notice Held by Compounder/Hybrid entrypoints. Authorizes calling `pull` to collect the input
  ///         tokens, and calling `compound`.
  /// @return The COMPOUNDER role bit.
  uint256 public constant COMPOUNDER = 1 << 2;

  /// @notice Held by Converter/Hybrid entrypoints. Authorizes calling `pull` to collect the input
  ///         tokens, and calling `notifyReward`.
  /// @return The CONVERTER role bit.
  uint256 public constant CONVERTER = 1 << 3;

  /// @notice L2-only operator role that authorizes the external `sweep` flow. The bit only has an
  ///         effect once the Relay is L2: `sweep` itself refuses to run before then.
  /// @return The SWEEPER role bit.
  uint256 public constant SWEEPER = 1 << 4;

  /// @notice Cancels a pending entrypoint proposal during its timelock. Seated at creation only:
  ///         the public grant and revoke paths refuse the bit, so the owner can neither install
  ///         nor remove the vetoer, and the seat moves only through `transferVetoer`.
  /// @return The ENTRYPOINT_VETOER role bit.
  uint256 public constant ENTRYPOINT_VETOER = 1 << 5;
}
