// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IRelayIcaModuleDeployer} from 'V3/interfaces/relay/IRelayIcaModuleDeployer.sol';

import {RelayIcaModule} from 'V3/relay/RelayIcaModule.sol';

/**
 * @title  RelayIcaModuleDeployer
 * @notice Deploys a Relay's `RelayIcaModule` at a deterministic address, so the module a Relay uses can be derived
 *         rather than looked up.
 * @dev    Kept out of `RelayFactory` on purpose. A module needs no authorization from the factory — it holds no Relay
 *         role and appears nowhere in the Relay's init — so putting it there would charge the deploy to every Relay,
 *         including the ones that never leave root, and would leave already-created Relays without one.
 * @dev    The module cannot be a clone the way a Relay is: its bindings are `immutable`, which live in the deployed
 *         bytecode, so every clone of one template would answer to the same Relay. CREATE2 gives the determinism a
 *         clone would have given without collapsing the bindings.
 */
contract RelayIcaModuleDeployer is IRelayIcaModuleDeployer {
  /// @inheritdoc IRelayIcaModuleDeployer
  IMetarouter public immutable METAROUTER;

  /// @inheritdoc IRelayIcaModuleDeployer
  uint32 public immutable ROOT_DOMAIN;

  /// @notice Bind the Metarouter every module from this deployer runs through.
  /// @dev A lite Metarouter reports no interchain account router. Every module's constructor would refuse it, so the
  ///      deployer refuses it first rather than predicting modules that can never exist.
  /// @param _metarouter Metarouter the deployed modules are bound to.
  /// @param _rootDomain Hyperlane domain of the root chain, the same for every module from this deployer.
  constructor(IMetarouter _metarouter, uint32 _rootDomain) {
    if (address(_metarouter) == address(0)) revert ZeroAddress();
    if (address(_metarouter.ICA_ROUTER()) == address(0)) revert ZeroAddress();
    if (_rootDomain == 0) revert ZeroDomain();
    METAROUTER = _metarouter;
    ROOT_DOMAIN = _rootDomain;
  }

  /// @inheritdoc IRelayIcaModuleDeployer
  function deploy(IRelayEntrypoint _relay) external returns (address _module) {
    _module = _predict(_relay);
    // Idempotent rather than reverting: the address is public and permissionless, so two callers racing for the same
    // Relay both get the module instead of one of them getting a revert.
    if (_module.code.length != 0) return _module;

    _module = address(new RelayIcaModule{salt: _salt(_relay)}(_relay, METAROUTER, ROOT_DOMAIN));
    emit ModuleDeployed(address(_relay), _module);
  }

  /// @inheritdoc IRelayIcaModuleDeployer
  function moduleFor(IRelayEntrypoint _relay) external view returns (address _module) {
    _module = _predict(_relay);
  }

  /// @notice The address `_relay`'s module resolves to.
  /// @param _relay Relay whose module address is computed.
  /// @return _module The deterministic module address.
  function _predict(IRelayEntrypoint _relay) internal view returns (address _module) {
    bytes32 _initCodeHash =
      keccak256(abi.encodePacked(type(RelayIcaModule).creationCode, abi.encode(_relay, METAROUTER, ROOT_DOMAIN)));
    _module = Create2.computeAddress(_salt(_relay), _initCodeHash, address(this));
  }

  /// @notice The CREATE2 salt for `_relay`'s module.
  /// @dev The Relay is already in the init code through the constructor argument; naming it here too keeps the
  ///      derivation readable and holds if that argument ever moves.
  /// @param _relay Relay the module serves.
  /// @return _computed The salt.
  function _salt(IRelayEntrypoint _relay) internal pure returns (bytes32 _computed) {
    _computed = bytes32(uint256(uint160(address(_relay))));
  }
}
