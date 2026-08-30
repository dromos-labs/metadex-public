// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title PartialRelayTokenImplementation
 * @notice Stand-in for a satellite token implementation that binds the Relay but drops the
 *         transferability argument, the half-wired case the Relay's postcondition must still catch:
 *         a Protocol tier depends on its yield side being soulbound, and a Maxi on it not being.
 */
contract PartialRelayTokenImplementation {
  /// @notice Relay the token answers to.
  /// @return The caller of `initialize`.
  address public relay;

  /// @notice Transferability switch the token answers with.
  /// @return Always false: `initialize` ignores its argument.
  bool public transferable;

  /// @notice Binds the Relay and ignores the transferability the Relay asked for.
  function initialize(string calldata, string calldata, bool) external {
    relay = msg.sender;
  }
}
