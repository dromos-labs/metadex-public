// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {ICompounder} from 'V3/interfaces/relay/entrypoints/ICompounder.sol';
import {IMultiConverter} from 'V3/interfaces/relay/entrypoints/IMultiConverter.sol';
import {IMultiHybrid} from 'V3/interfaces/relay/entrypoints/IMultiHybrid.sol';
import {ISingleConverter} from 'V3/interfaces/relay/entrypoints/ISingleConverter.sol';
import {ISingleHybrid} from 'V3/interfaces/relay/entrypoints/ISingleHybrid.sol';

import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';
import {MultiConverter} from 'V3/relay/entrypoints/MultiConverter.sol';
import {MultiHybrid} from 'V3/relay/entrypoints/MultiHybrid.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';
import {SingleHybrid} from 'V3/relay/entrypoints/SingleHybrid.sol';

/// @notice Each concrete entrypoint declares its own external surface in its own interface, so a
///         consumer can drive one without importing the implementation.
/// @dev    Most of this is enforced at compile time rather than here: each contract inherits its
///         interface, so a signature that drifts leaves the contract abstract and the build fails.
///         What these cases add is the ABI side, that every declared view actually answers through
///         the interface handle, and the deploy-time bindings each one reports.
contract UnitEntrypointInterfaces is BaseEntrypoints {
  uint256 internal constant _COMPOUND_WEIGHT = 500_000;

  function test_WhenReadingAnEntrypointThroughItsInterface() external {
    IFactoryRegistry _registry = IFactoryRegistry(_factoryRegistry);
    address[] memory _targets = new address[](1);
    _targets[0] = _tokenOut;
    address[] memory _excluded = new address[](0);

    // it should answer the compounder surface
    ICompounder _compounder = ICompounder(address(new Compounder(_registry)));
    assertEq(address(_compounder.FACTORY_REGISTRY()), _factoryRegistry);

    // it should answer the single converter surface
    ISingleConverter _converter = ISingleConverter(address(new SingleConverter(_registry, _tokenOut)));
    assertEq(address(_converter.FACTORY_REGISTRY()), _factoryRegistry);
    assertEq(_converter.TARGET_TOKEN(), _tokenOut);

    // it should answer the single hybrid surface
    ISingleHybrid _hybrid = ISingleHybrid(address(new SingleHybrid(_registry, _tokenOut, _COMPOUND_WEIGHT)));
    assertEq(_hybrid.TARGET_TOKEN(), _tokenOut);
    assertEq(_hybrid.COMPOUND_WEIGHT(), _COMPOUND_WEIGHT);

    // it should answer the multi converter surface
    IMultiConverter _multiConverter =
      IMultiConverter(address(new MultiConverter(_registry, IRelayEntrypoint(_relayAddr), _targets, _excluded)));
    assertEq(address(_multiConverter.RELAY()), _relayAddr);
    assertTrue(_multiConverter.isTargetToken(_tokenOut));

    // it should answer the multi hybrid surface
    IMultiHybrid _multiHybrid = IMultiHybrid(
      address(new MultiHybrid(_registry, IRelayEntrypoint(_relayAddr), _targets, _excluded, _COMPOUND_WEIGHT))
    );
    assertEq(_multiHybrid.compoundWeight(), _COMPOUND_WEIGHT);
    assertTrue(_multiHybrid.isTargetToken(_tokenOut));
  }
}
