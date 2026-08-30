// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';

/// @notice Unit tests for `MultiEntrypoint.removeExcludedToken`: the L2-admin-gated removal of an
///         excluded input, which reverts when the token is not currently excluded.
contract UnitMultiEntrypointRemoveExcludedToken is BaseMultiEntrypoint {
  /// @notice The config is gated by the bound Relay's L2 admin.
  function test_WhenTheCallerIsNotTheConfigAdmin(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, false);

    // it should revert with NotConfigAdmin
    vm.expectRevert(IMultiEntrypoint.NotConfigAdmin.selector);
    vm.prank(_caller);
    _multi.removeExcludedToken(_token);
  }

  /// @notice Removing a token that is not excluded reverts.
  function test_WhenTheTokenIsNotExcluded(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, true);

    // it should revert with TokenNotConfigured
    vm.expectRevert(IMultiEntrypoint.TokenNotConfigured.selector);
    vm.prank(_caller);
    _multi.removeExcludedToken(_token);
  }

  /// @notice An existing exclusion is removed and announced.
  function test_WhenTheTokenIsExcluded(address _caller, address _token) external {
    _assumeFuzzable(_caller);
    vm.assume(_token != address(0));
    MultiEntrypointHarness _instance = _deployMulti(_empty(), _single(_token));
    _mockConfigAdmin(_caller, true);

    // it should emit an ExcludedTokenRemoved event
    _expectEmit(address(_instance));
    emit IMultiEntrypoint.ExcludedTokenRemoved(_token);

    vm.prank(_caller);
    _instance.removeExcludedToken(_token);

    // it should remove the token from the excluded set
    assertFalse(_instance.isExcludedToken(_token));
  }
}
