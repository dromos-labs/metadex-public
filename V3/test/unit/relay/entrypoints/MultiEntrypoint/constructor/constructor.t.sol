// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @notice Unit tests for the `MultiEntrypoint` constructor (through the harness): it binds the Relay,
///         seeds the target and excluded sets, and enforces the non-zero and target/excluded-mutex
///         invariants at genesis.
contract UnitMultiEntrypointConstructor is BaseMultiEntrypoint {
  /// @notice The base constructor still guards the router.
  function test_WhenTheFactoryRegistryIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new MultiEntrypointHarness(IFactoryRegistry(address(0)), IRelayEntrypoint(_relayAddr), _empty(), _empty());
  }

  /// @notice A Multi entrypoint is bound to exactly one Relay, which cannot be zero.
  function test_WhenTheRelayIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new MultiEntrypointHarness(IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(address(0)), _empty(), _empty());
  }

  /// @notice A zero initial target is rejected by the set-add guard.
  function test_WhenAnInitialTargetIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new MultiEntrypointHarness(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(address(0)), _empty()
    );
  }

  /// @notice A zero initial excluded token is rejected by the set-add guard.
  function test_WhenAnInitialExcludedTokenIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new MultiEntrypointHarness(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _single(address(0))
    );
  }

  /// @notice A token cannot be seeded into both sets.
  function test_WhenAnInitialTokenIsATargetAndExcluded(address _token) external {
    vm.assume(_token != address(0));

    // it should revert with TargetExcludedOverlap
    vm.expectRevert(IMultiEntrypoint.TargetExcludedOverlap.selector);
    new MultiEntrypointHarness(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(_token), _single(_token)
    );
  }

  /// @notice A duplicate in the initial targets is rejected by the set-add guard.
  function test_WhenTheInitialTargetsContainADuplicate(address _token) external {
    vm.assume(_token != address(0));
    address[] memory _dupes = new address[](2);
    _dupes[0] = _token;
    _dupes[1] = _token;

    // it should revert with TokenAlreadyConfigured
    vm.expectRevert(IMultiEntrypoint.TokenAlreadyConfigured.selector);
    new MultiEntrypointHarness(IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _dupes, _empty());
  }

  /// @notice A duplicate in the initial exclusions is rejected by the set-add guard.
  function test_WhenTheInitialExclusionsContainADuplicate(address _token) external {
    vm.assume(_token != address(0));
    address[] memory _dupes = new address[](2);
    _dupes[0] = _token;
    _dupes[1] = _token;

    // it should revert with TokenAlreadyConfigured
    vm.expectRevert(IMultiEntrypoint.TokenAlreadyConfigured.selector);
    new MultiEntrypointHarness(IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _dupes);
  }

  /// @notice Valid sets bind the Relay and are queryable after construction.
  function test_WhenTheInitialSetsAreValid(address _target, address _excluded) external {
    vm.assume(_target != address(0) && _excluded != address(0) && _target != _excluded);
    MultiEntrypointHarness _instance = _deployMulti(_single(_target), _single(_excluded));

    // it should bind the relay
    assertEq(address(_instance.RELAY()), _relayAddr);
    // it should seed the target set
    assertTrue(_instance.isTargetToken(_target));
    // it should seed the excluded set
    assertTrue(_instance.isExcludedToken(_excluded));
  }
}
