// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @notice Unit tests for `MultiEntrypoint.addTargetToken`: the L2-admin-gated add of a convert target,
///         enforcing the non-zero and target/excluded-mutex invariants and the no-duplicate rule.
contract UnitMultiEntrypointAddTargetToken is BaseMultiEntrypoint {
  /// @notice The config is gated by the bound Relay's L2 admin.
  function test_WhenTheCallerIsNotTheConfigAdmin(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, false);

    // it should revert with NotConfigAdmin
    vm.expectRevert(IMultiEntrypoint.NotConfigAdmin.selector);
    vm.prank(_caller);
    _multi.addTargetToken(_token);
  }

  /// @notice A zero target is rejected.
  function test_WhenTheTokenIsTheZeroAddress(address _caller) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, true);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    vm.prank(_caller);
    _multi.addTargetToken(address(0));
  }

  /// @notice A token already on the excluded set cannot become a target (mutex).
  function test_WhenTheTokenIsAlreadyExcluded(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    vm.assume(_token != address(0));
    MultiEntrypointHarness _instance = _deployMulti(_empty(), _single(_token));
    _mockConfigAdmin(_caller, true);

    // it should revert with TargetExcludedOverlap
    vm.expectRevert(IMultiEntrypoint.TargetExcludedOverlap.selector);
    vm.prank(_caller);
    _instance.addTargetToken(_token);
  }

  /// @notice Re-adding an existing target is rejected.
  function test_WhenTheTokenIsAlreadyATarget(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    vm.assume(_token != address(0));
    MultiEntrypointHarness _instance = _deployMulti(_single(_token), _empty());
    _mockConfigAdmin(_caller, true);

    // it should revert with TokenAlreadyConfigured
    vm.expectRevert(IMultiEntrypoint.TokenAlreadyConfigured.selector);
    vm.prank(_caller);
    _instance.addTargetToken(_token);
  }

  /// @notice A new target is added and announced.
  function test_WhenTheTokenIsNew(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    vm.assume(_token != address(0));
    _mockConfigAdmin(_caller, true);

    // it should emit a TargetTokenAdded event
    _expectEmit(address(_multi));
    emit IMultiEntrypoint.TargetTokenAdded(_token);

    vm.prank(_caller);
    _multi.addTargetToken(_token);

    // it should add the token to the target set
    assertTrue(_multi.isTargetToken(_token));
  }
}
