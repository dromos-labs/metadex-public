// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';
import {BaseEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/BaseEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @notice Unit tests for `BaseEntrypoint._requireKeeper` (through the harness): the shared gate
///         every entrypoint path runs, checked against the Relay's own role set.
contract UnitBaseEntrypointRequireKeeper is BaseEntrypoints {
  BaseEntrypointHarness internal _harness;

  function setUp() public override {
    super.setUp();
    _harness = new BaseEntrypointHarness(IFactoryRegistry(_factoryRegistry));
  }

  /// @notice The gate rejects anyone the Relay does not list as its keeper.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, false);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _harness.requireKeeper(_relayAddr);
  }

  /// @notice The keeper passes; the gate returns nothing and the caller's path goes on.
  function test_WhenTheCallerIsTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, true);

    // it should not revert
    vm.prank(_caller);
    _harness.requireKeeper(_relayAddr);
  }
}
