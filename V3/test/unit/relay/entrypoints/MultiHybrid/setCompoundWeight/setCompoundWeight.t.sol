// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';
import {IMultiHybrid} from 'V3/interfaces/relay/entrypoints/IMultiHybrid.sol';
import {MultiHybrid} from 'V3/relay/entrypoints/MultiHybrid.sol';

/// @notice Unit tests for `MultiHybrid.setCompoundWeight`: the L2-admin-gated update of the mutable
///         (data-only) compound weight, bounded to pips. The write is guarded against
///         no-ops — a weight equal to the stored one returns without emitting.
contract UnitMultiHybridSetCompoundWeight is BaseMultiEntrypoint {
  using stdStorage for StdStorage;

  MultiHybrid internal _hybrid;

  function setUp() public override {
    super.setUp();
    _hybrid = new MultiHybrid(IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _empty(), 0);
  }

  /// @dev stdstore write for the stored `compoundWeight`, seeding the pre-state directly.
  function _setCompoundWeight(uint256 _weight) internal {
    stdstore.target(address(_hybrid)).sig('compoundWeight()').checked_write(_weight);
  }

  /// @notice The weight is gated by the bound Relay's L2 admin.
  function test_WhenTheCallerIsNotTheConfigAdmin(address _caller, uint256 _weight) external {
    _assumeFuzzable(_caller);
    _mockConfigAdmin(_caller, false);

    // it should revert with NotConfigAdmin
    vm.expectRevert(IMultiEntrypoint.NotConfigAdmin.selector);
    vm.prank(_caller);
    _hybrid.setCompoundWeight(_weight);
  }

  /// @notice The new weight cannot exceed MAX_PIPS.
  function test_WhenTheNewWeightExceedsTheMaximum(address _caller, uint256 _weight) external {
    _assumeFuzzable(_caller);
    _weight = bound(_weight, MAX_PIPS + 1, type(uint256).max);
    _mockConfigAdmin(_caller, true);

    // it should revert with InvalidCompoundWeight
    vm.expectRevert(IBaseEntrypoint.InvalidCompoundWeight.selector);
    vm.prank(_caller);
    _hybrid.setCompoundWeight(_weight);
  }

  /// @notice Re-setting the weight to the value it already holds is a no-op: no write, no event.
  function test_WhenTheNewWeightEqualsTheCurrentWeight(address _caller, uint256 _weight) external {
    _assumeFuzzable(_caller);
    _weight = bound(_weight, 0, MAX_PIPS);
    _setCompoundWeight(_weight);
    _mockConfigAdmin(_caller, true);

    vm.recordLogs();
    vm.prank(_caller);
    _hybrid.setCompoundWeight(_weight);

    // it should not emit a CompoundWeightSet event
    assertEq(vm.getRecordedLogs().length, 0);
    // it should leave the compound weight unchanged
    assertEq(_hybrid.compoundWeight(), _weight);
  }

  /// @notice A valid weight that changes is stored and announced.
  function test_WhenTheNewWeightIsValidAndChanges(address _caller, uint256 _previous, uint256 _weight) external {
    _assumeFuzzable(_caller);
    _previous = bound(_previous, 0, MAX_PIPS);
    _weight = bound(_weight, 0, MAX_PIPS);
    vm.assume(_weight != _previous);
    _setCompoundWeight(_previous);
    _mockConfigAdmin(_caller, true);

    // it should emit a CompoundWeightSet event
    _expectEmit(address(_hybrid));
    emit IMultiHybrid.CompoundWeightSet(_weight);

    vm.prank(_caller);
    _hybrid.setCompoundWeight(_weight);

    // it should update the compound weight
    assertEq(_hybrid.compoundWeight(), _weight);
  }
}
