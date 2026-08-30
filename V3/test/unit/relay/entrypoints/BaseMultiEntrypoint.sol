// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';

/**
 * @title BaseMultiEntrypoint
 * @notice Base for the MultiEntrypoint config/guard suites: deploys a harness bound to the mocked
 *         Relay and provides helpers to deploy scenario-specific instances, mock the L2 config gate,
 *         and build one-element token arrays.
 */
abstract contract BaseMultiEntrypoint is BaseEntrypoints {
  MultiEntrypointHarness internal _multi;

  function setUp() public virtual override {
    super.setUp();
    _multi = _deployMulti(_empty(), _empty());
  }

  /// @dev Deploy a fresh harness bound to the mocked Relay with the given initial sets.
  function _deployMulti(
    address[] memory _targets,
    address[] memory _excluded
  ) internal returns (MultiEntrypointHarness _instance) {
    _instance = new MultiEntrypointHarness(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _targets, _excluded
    );
  }

  /// @dev Mock the bound Relay's owner gate for `_caller`: report the caller itself as the owner
  ///      when it passes, and an address derived to differ from it when it does not.
  function _mockConfigAdmin(address _caller, bool _ok) internal {
    address _owner = _ok ? _caller : address(uint160(_caller) ^ 1);
    vm.mockCall(_relayAddr, abi.encodeCall(IRelayEntrypoint.owner, ()), abi.encode(_owner));
  }

  /// @dev An empty address array.
  function _empty() internal pure returns (address[] memory _arr) {
    _arr = new address[](0);
  }

  /// @dev A one-element address array.
  function _single(address _token) internal pure returns (address[] memory _arr) {
    _arr = new address[](1);
    _arr[0] = _token;
  }
}
