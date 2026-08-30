// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleHybrid} from 'V3/relay/entrypoints/SingleHybrid.sol';

/// @notice Unit tests for the `SingleHybrid` constructor: it binds the immutable target token and the
///         (data-only) compound weight, rejecting a zero target and an out-of-range weight.
contract UnitSingleHybridConstructor is BaseEntrypoints {
  /// @notice A hybrid still needs a convert target for its convert side.
  function test_WhenTheTargetTokenIsTheZeroAddress(uint256 _compoundWeight) external {
    _compoundWeight = bound(_compoundWeight, 0, MAX_PIPS);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseEntrypoint.ZeroAddress.selector);
    new SingleHybrid(IFactoryRegistry(_factoryRegistry), address(0), _compoundWeight);
  }

  /// @notice The compound weight is a share in pips, so it cannot exceed MAX_PIPS.
  function test_WhenTheCompoundWeightExceedsTheMaximum(address _target, uint256 _compoundWeight) external {
    _assumeFuzzable(_target);
    _compoundWeight = bound(_compoundWeight, MAX_PIPS + 1, type(uint256).max);

    // it should revert with InvalidCompoundWeight
    vm.expectRevert(IBaseEntrypoint.InvalidCompoundWeight.selector);
    new SingleHybrid(IFactoryRegistry(_factoryRegistry), _target, _compoundWeight);
  }

  /// @notice Valid parameters bind both immutables.
  function test_WhenTheParametersAreValid(address _target, uint256 _compoundWeight) external {
    _assumeFuzzable(_target);
    _compoundWeight = bound(_compoundWeight, 0, MAX_PIPS);
    SingleHybrid _hybrid = new SingleHybrid(IFactoryRegistry(_factoryRegistry), _target, _compoundWeight);

    // it should set the target token immutable
    assertEq(_hybrid.TARGET_TOKEN(), _target);
    // it should set the compound weight immutable
    assertEq(_hybrid.COMPOUND_WEIGHT(), _compoundWeight);
  }
}
