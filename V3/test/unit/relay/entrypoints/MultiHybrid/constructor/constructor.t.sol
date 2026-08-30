// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {MultiHybrid} from 'V3/relay/entrypoints/MultiHybrid.sol';

/// @notice Unit tests for the `MultiHybrid` constructor: on top of the MultiEntrypoint invariants it
///         bounds the (mutable, data-only) compound weight to pips. The zero/overlap set
///         invariants are covered by the MultiEntrypoint constructor suite.
contract UnitMultiHybridConstructor is BaseMultiEntrypoint {
  /// @notice The compound weight is a share in pips, so it cannot exceed MAX_PIPS.
  function test_WhenTheCompoundWeightExceedsTheMaximum(uint256 _compoundWeight) external {
    _compoundWeight = bound(_compoundWeight, MAX_PIPS + 1, type(uint256).max);

    // it should revert with InvalidCompoundWeight
    vm.expectRevert(IBaseEntrypoint.InvalidCompoundWeight.selector);
    new MultiHybrid(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _empty(), _compoundWeight
    );
  }

  /// @notice A valid weight is stored.
  function test_WhenTheParametersAreValid(uint256 _compoundWeight) external {
    _compoundWeight = bound(_compoundWeight, 0, MAX_PIPS);
    MultiHybrid _hybrid = new MultiHybrid(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _empty(), _compoundWeight
    );

    // it should set the compound weight
    assertEq(_hybrid.compoundWeight(), _compoundWeight);
  }
}
