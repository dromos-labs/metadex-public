// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title InertRelayTokenImplementation
 * @notice Stand-in for a satellite token implementation that holds code but wires nothing, the state
 *         a clone of a codeless implementation reaches: `initialize` returns success and both fields
 *         the Relay reads back stay empty.
 * @dev The getters exist so the postcondition reads a value instead of reverting on empty returndata,
 *      which is what a clone of a codeless address would do.
 */
contract InertRelayTokenImplementation {
  /// @notice Relay the token would answer to.
  /// @return The zero address: `initialize` never writes it.
  address public relay;

  /// @notice Transferability switch the token would answer with.
  /// @return False: `initialize` never writes it.
  bool public transferable;

  /// @notice Accepts the initialization inputs and does nothing with them.
  function initialize(string calldata, string calldata, bool) external {}
}
