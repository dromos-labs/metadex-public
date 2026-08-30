// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';

/**
 * @title InertRelayImplementation
 * @notice Stand-in for a Relay implementation whose `initialize` runs but wires nothing, the state a
 *         clone of a codeless implementation ends up in: the call returns success and no satellite
 *         token exists.
 * @dev Only the two functions the factory's creation path touches after the clone exists.
 */
contract InertRelayImplementation {
  /// @notice Accepts the initialization inputs and does nothing with them.
  function initialize(IRelay.InitParams memory) external {}

  /// @notice Reports no principal token, the signature the factory's postcondition looks for.
  /// @return _principalToken Always the zero address.
  function principalToken() external pure returns (address _principalToken) {
    _principalToken = address(0);
  }
}
