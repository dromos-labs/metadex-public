// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @notice Unit tests for `MultiEntrypoint.removeTargetToken`: the L2-admin-gated removal of a convert
///         target, which reverts when the token is not currently a target.
contract UnitMultiEntrypointRemoveTargetToken is BaseMultiEntrypoint {
  /// @notice The config is gated by the bound Relay's L2 admin.
  function test_WhenTheCallerIsNotTheConfigAdmin(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, false);

    // it should revert with NotConfigAdmin
    vm.expectRevert(IMultiEntrypoint.NotConfigAdmin.selector);
    vm.prank(_caller);
    _multi.removeTargetToken(_token);
  }

  /// @notice Removing a token that is not a target reverts.
  function test_WhenTheTokenIsNotATarget(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, true);

    // it should revert with TokenNotConfigured
    vm.expectRevert(IMultiEntrypoint.TokenNotConfigured.selector);
    vm.prank(_caller);
    _multi.removeTargetToken(_token);
  }

  /// @notice An existing target is removed and announced.
  function test_WhenTheTokenIsATarget(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    vm.assume(_token != address(0));
    MultiEntrypointHarness _instance = _deployMulti(_single(_token), _empty());
    _mockConfigAdmin(_caller, true);

    // it should emit a TargetTokenRemoved event
    _expectEmit(address(_instance));
    emit IMultiEntrypoint.TargetTokenRemoved(_token);

    vm.prank(_caller);
    _instance.removeTargetToken(_token);

    // it should remove the token from the target set
    assertFalse(_instance.isTargetToken(_token));
  }
}
