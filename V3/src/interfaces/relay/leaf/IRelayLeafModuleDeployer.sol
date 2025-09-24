// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title  IRelayLeafModuleDeployer
 * @notice Deploys leaf modules at addresses that can be computed before they exist.
 */
interface IRelayLeafModuleDeployer {
  /*//////////////////////////////////////////////////////////////
                               EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted when a module is deployed.
  /// @param relay Relay the module serves.
  /// @param tokenId The Relay's sAERO the module claims for.
  /// @param module Address the module landed at.
  event ModuleDeployed(address indexed relay, uint256 indexed tokenId, address module);

  /*//////////////////////////////////////////////////////////////
                               ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a constructor argument is the zero address.
  error ZeroAddress();

  /// @notice Thrown when the deployer is bound to Hyperlane domain zero, which no warp route accepts.
  error ZeroDomain();

  /*//////////////////////////////////////////////////////////////
                              FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Deploys the module for a Relay, or returns the one already there.
  /// @dev Permissionless and idempotent: the address is fixed by the arguments, so a second call returns the first
  ///      result rather than reverting on two callers racing.
  /// @dev Anyone may pick the owner, so a Relay owner must read `owner()` off the module before pointing
  ///      `leafRecipient` at it. A module born with the wrong owner is abandoned rather than fixed: the fix is to
  ///      deploy the right one, at its own address.
  /// @param _relay Relay on root the module bridges to.
  /// @param _tokenId The Relay's sAERO.
  /// @param _owner Address the module is born owned by; it grants the keepers.
  /// @return _module The module.
  function deploy(address _relay, uint256 _tokenId, address _owner) external returns (address _module);

  /// @notice The address a module will resolve to, whether or not it exists yet.
  /// @dev Both flows that point a Relay at its module are timelocked, so the address has to be knowable before the
  ///      deploy: seating it as operator and pointing `leafRecipient` at it both start their delay on root, where
  ///      this chain's state cannot be read. Keepers are not an input, so granting one never moves the address.
  /// @param _relay Relay on root the module bridges to.
  /// @param _tokenId The Relay's sAERO.
  /// @param _owner Address the module is born owned by.
  /// @return _module The address.
  function moduleFor(address _relay, uint256 _tokenId, address _owner) external view returns (address _module);

  /*//////////////////////////////////////////////////////////////
                                VIEWS
  //////////////////////////////////////////////////////////////*/

  /// @notice The LeafVoter every module claims through.
  /// @return _leafVoter The LeafVoter.
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);

  /// @notice The output token every module bridges.
  /// @return _outToken The output token.
  function OUT_TOKEN() external view returns (address _outToken);

  /// @notice The warp route every module sends `OUT_TOKEN` through.
  /// @return _bridge The bridge.
  function BRIDGE() external view returns (address _bridge);

  /// @notice The Hyperlane domain of the root chain.
  /// @return _domain The domain.
  function ROOT_DOMAIN() external view returns (uint32 _domain);

  /// @notice The open-bridge floor every module deployed here is built with.
  /// @dev Lives next to `OUT_TOKEN` because it is sized in that token's units.
  /// @return _minBridgeAmount The floor, in `OUT_TOKEN` units; zero means none.
  function MIN_BRIDGE_AMOUNT() external view returns (uint256 _minBridgeAmount);
}
