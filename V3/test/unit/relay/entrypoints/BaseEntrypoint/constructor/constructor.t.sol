// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';
import {BaseEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/BaseEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @notice Unit tests for the `BaseEntrypoint` constructor (through the harness): it binds the
///         factory registry every swap validates routers against and rejects the zero address.
contract UnitBaseEntrypointConstructor is BaseEntrypoints {
  /// @notice An entrypoint cannot validate routers without the registry.
  function test_WhenTheFactoryRegistryIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new BaseEntrypointHarness(IFactoryRegistry(address(0)));
  }

  /// @notice A non-zero registry is stored as the immutable every swap reads.
  function test_WhenTheFactoryRegistryIsValid(address _registry) external {
    _assumeFuzzable(_registry);
    BaseEntrypointHarness _harness = new BaseEntrypointHarness(IFactoryRegistry(_registry));

    // it should set the factory registry immutable
    assertEq(address(_harness.FACTORY_REGISTRY()), _registry);
  }
}
