// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';

/// @notice Unit tests for the `Compounder` constructor: it forwards the MetaRouter to BaseEntrypoint,
///         inheriting the zero-address guard and the immutable binding.
contract UnitCompounderConstructor is BaseEntrypoints {
  /// @notice The inherited guard rejects a zero MetaRouter.
  function test_WhenTheFactoryRegistryIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new Compounder(IFactoryRegistry(address(0)));
  }

  /// @notice A non-zero MetaRouter is stored as the immutable.
  function test_WhenTheFactoryRegistryIsValid(address _registry) external {
    _assumeFuzzable(_registry);
    Compounder _compounder = new Compounder(IFactoryRegistry(_registry));

    // it should set the factory registry immutable
    assertEq(address(_compounder.FACTORY_REGISTRY()), _registry);
  }
}
