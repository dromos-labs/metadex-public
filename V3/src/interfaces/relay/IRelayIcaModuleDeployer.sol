// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';

/// @title  IRelayIcaModuleDeployer
/// @notice Deploys one `RelayIcaModule` per Relay at an address anyone can compute in advance.
interface IRelayIcaModuleDeployer {
  /**
   * @notice Emitted when a Relay's module is deployed.
   * @param _relay Relay the module serves.
   * @param _module Module that was deployed.
   */
  event ModuleDeployed(address indexed _relay, address indexed _module);

  /// @notice Thrown when a constructor dependency is the zero address, or the Metarouter reports no interchain
  ///         account router.
  error ZeroAddress();

  /// @notice Thrown when the deployer is bound to Hyperlane domain zero, which no warp route accepts.
  error ZeroDomain();

  /// @notice Deploy the module for `_relay`, or return the existing one.
  /// @dev Permissionless and idempotent. Deploying a module grants nobody anything: it starts with an empty owner
  ///      seat that only `_relay`'s admin can fill, and until that Relay registers the module's account as a
  ///      `leafRecipient` it has nothing to move.
  /// @param _relay Relay the module will serve.
  /// @return _module The Relay's module.
  function deploy(IRelayEntrypoint _relay) external returns (address _module);

  /// @notice Address the module for `_relay` resolves to, deployed or not.
  /// @dev Callable before deployment, so a Relay's owner can start the `leafRecipient` timelock while the module
  ///      does not exist yet.
  /// @dev This address is not the one to register as `leafRecipient`. That is the module's interchain account on the
  ///      leaf chain, which `RelayIcaModule.interchainAccount` reads once the module exists and which before that
  ///      has to be derived off-chain, as
  ///      `getRemoteInterchainAccount(domain, METAROUTER, bytes32(uint160(moduleFor(relay))))`. Registering this
  ///      address instead sends leaf claims to a root address with no account behind it, and correcting it costs
  ///      another full `entrypointTimelock` while what was already claimed stays out of reach.
  /// @param _relay Relay whose module address is computed.
  /// @return _module The deterministic module address.
  function moduleFor(IRelayEntrypoint _relay) external view returns (address _module);

  /// @notice Hyperlane domain of the root chain every module this deployer creates bridges to.
  /// @return _domain The root domain.
  function ROOT_DOMAIN() external view returns (uint32 _domain);

  /// @notice Metarouter every module this deployer creates is bound to.
  /// @dev It is part of the interchain account derivation, so modules for a different Metarouter need a different
  ///      deployer.
  /// @return _metarouter The bound Metarouter.
  function METAROUTER() external view returns (IMetarouter _metarouter);
}
