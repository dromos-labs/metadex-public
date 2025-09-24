// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Create2} from '@openzeppelin/contracts/utils/Create2.sol';

import {IRelayLeafModuleDeployer} from 'V3/interfaces/relay/leaf/IRelayLeafModuleDeployer.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {RelayLeafModule} from 'V3/relay/leaf/RelayLeafModule.sol';

/**
 * @title  RelayLeafModuleDeployer
 * @notice Deploys one leaf module per Relay on this chain, at an address anyone can compute in advance.
 * @dev    Holds the settings that are the same for every Relay on this chain, so a deploy only names what actually
 *         differs. CREATE2 rather than a clone: the module's bindings are immutables that live in its own bytecode,
 *         and clones of one template would all answer to the same Relay, which is the shared-custody case the
 *         binding exists to prevent.
 */
contract RelayLeafModuleDeployer is IRelayLeafModuleDeployer {
  /// @inheritdoc IRelayLeafModuleDeployer
  ILeafVoter public immutable LEAF_VOTER;

  /// @inheritdoc IRelayLeafModuleDeployer
  address public immutable OUT_TOKEN;

  /// @inheritdoc IRelayLeafModuleDeployer
  address public immutable BRIDGE;

  /// @inheritdoc IRelayLeafModuleDeployer
  uint32 public immutable ROOT_DOMAIN;

  /// @inheritdoc IRelayLeafModuleDeployer
  uint256 public immutable MIN_BRIDGE_AMOUNT;

  /// @notice Binds the deployer to this chain's settings.
  /// @param _leafVoter The LeafVoter every module claims through.
  /// @param _outToken The output token every module bridges.
  /// @param _bridge The warp route carrying `_outToken` to root.
  /// @param _rootDomain The Hyperlane domain of the root chain.
  /// @param _minBridgeAmount The open-bridge floor every module gets, in `_outToken` units; zero means none.
  constructor(ILeafVoter _leafVoter, address _outToken, address _bridge, uint32 _rootDomain, uint256 _minBridgeAmount) {
    if (address(_leafVoter) == address(0) || _outToken == address(0) || _bridge == address(0)) {
      revert ZeroAddress();
    }
    if (_rootDomain == 0) revert ZeroDomain();

    LEAF_VOTER = _leafVoter;
    OUT_TOKEN = _outToken;
    BRIDGE = _bridge;
    ROOT_DOMAIN = _rootDomain;
    MIN_BRIDGE_AMOUNT = _minBridgeAmount;
  }

  /// @inheritdoc IRelayLeafModuleDeployer
  function deploy(address _relay, uint256 _tokenId, address _owner) external returns (address _module) {
    _module = _predict(_relay, _tokenId, _owner);
    // Idempotent rather than reverting: the address is public and permissionless, so two callers racing for the
    // same Relay both get the module instead of one of them getting a revert.
    if (_module.code.length != 0) return _module;

    _module = address(
      new RelayLeafModule{salt: _salt(_relay, _tokenId, _owner)}(
        _relay, LEAF_VOTER, _tokenId, OUT_TOKEN, BRIDGE, ROOT_DOMAIN, _owner, MIN_BRIDGE_AMOUNT
      )
    );
    emit ModuleDeployed(_relay, _tokenId, _module);
  }

  /// @inheritdoc IRelayLeafModuleDeployer
  function moduleFor(address _relay, uint256 _tokenId, address _owner) external view returns (address _module) {
    _module = _predict(_relay, _tokenId, _owner);
  }

  /// @notice The address a Relay's module resolves to.
  /// @dev The encoded arguments must match `RelayLeafModule`'s constructor exactly. Solidity does not type-check
  ///      this blob against it, so a stale argument list computes an address the `new` expression never produces.
  /// @param _relay Relay the module serves.
  /// @param _tokenId The Relay's sAERO.
  /// @param _owner Address the module is born owned by.
  /// @return _module The deterministic module address.
  function _predict(address _relay, uint256 _tokenId, address _owner) internal view returns (address _module) {
    bytes32 _initCodeHash = keccak256(
      abi.encodePacked(
        type(RelayLeafModule).creationCode,
        abi.encode(_relay, LEAF_VOTER, _tokenId, OUT_TOKEN, BRIDGE, ROOT_DOMAIN, _owner, MIN_BRIDGE_AMOUNT)
      )
    );
    _module = Create2.computeAddress(_salt(_relay, _tokenId, _owner), _initCodeHash, address(this));
  }

  /// @notice The CREATE2 salt for a Relay's module.
  /// @dev All three inputs are already in the init code; naming them here keeps the derivation readable and holds
  ///      if the constructor arguments ever move.
  /// @param _relay Relay the module serves.
  /// @param _tokenId The Relay's sAERO.
  /// @param _owner Address the module is born owned by.
  /// @return _saltValue The salt.
  function _salt(address _relay, uint256 _tokenId, address _owner) internal pure returns (bytes32 _saltValue) {
    _saltValue = keccak256(abi.encode(_relay, _tokenId, _owner));
  }
}
