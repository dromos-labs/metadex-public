// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';
import {MultiEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/MultiEntrypointHarness.sol';

/// @notice Unit tests for the `MultiEntrypoint` config views: `targetTokens`/`excludedTokens` list the
///         configured sets and `isTargetToken`/`isExcludedToken` report membership.
contract UnitMultiEntrypointViews is BaseMultiEntrypoint {
  /// @notice The target views reflect the configured target set.
  function test_WhenReadingTheTargetViews(address _target, address _other) external {
    vm.assume(_target != address(0) && _target != _other);
    MultiEntrypointHarness _instance = _deployMulti(_single(_target), _empty());

    // it should list the configured targets
    address[] memory _targets = _instance.targetTokens();
    assertEq(_targets.length, 1);
    assertEq(_targets[0], _target);
    // it should report target membership
    assertTrue(_instance.isTargetToken(_target));
    assertFalse(_instance.isTargetToken(_other));
  }

  /// @notice The excluded views reflect the configured excluded set.
  function test_WhenReadingTheExcludedViews(address _excluded, address _other) external {
    vm.assume(_excluded != address(0) && _excluded != _other);
    MultiEntrypointHarness _instance = _deployMulti(_empty(), _single(_excluded));

    // it should list the configured exclusions
    address[] memory _exclusions = _instance.excludedTokens();
    assertEq(_exclusions.length, 1);
    assertEq(_exclusions[0], _excluded);
    // it should report exclusion membership
    assertTrue(_instance.isExcludedToken(_excluded));
    assertFalse(_instance.isExcludedToken(_other));
  }
}
