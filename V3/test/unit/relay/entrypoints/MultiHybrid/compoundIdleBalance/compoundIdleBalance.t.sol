// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';
import {MultiHybrid} from 'V3/relay/entrypoints/MultiHybrid.sol';

/// @notice Unit tests for `MultiHybrid.compoundIdleBalance`: the compound half's swap-free path,
///         restricted to the bound Relay like every other call on this entrypoint.
contract UnitMultiHybridCompoundIdleBalance is BaseMultiEntrypoint {
  uint256 internal constant _COMPOUND_WEIGHT = 500_000;

  MultiHybrid internal _hybrid;

  function setUp() public override {
    super.setUp();
    _hybrid = new MultiHybrid(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(_tokenOut), _empty(), _COMPOUND_WEIGHT
    );
  }

  /// @notice The config policy applies to the bound Relay only.
  function test_WhenTheRelayIsNotTheBoundRelay(address _caller, address _other) external {
    _assumeFuzzable(_caller);
    vm.assume(_other != _relayAddr);

    // it should revert with WrongRelay
    vm.expectRevert(IMultiEntrypoint.WrongRelay.selector);
    vm.prank(_caller);
    _hybrid.compoundIdleBalance(_other);
  }

  /// @notice The idle TOKEN is compounded without a swap, bounded by what claimants are not owed.
  function test_WhenAKeeperDrainsTheIdleBalance(address _caller, uint256 _balance, uint256 _accounted) external {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 1, type(uint128).max);
    _accounted = bound(_accounted, 0, _balance - 1);
    _mockKeeper(_relayAddr, _caller, true);
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenIn));
    _mockIdleBalance(_relayAddr, _tokenIn, _balance, _accounted);
    // it should compound the unaccounted relay token balance
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.compound, (_balance - _accounted)), bytes(''));

    vm.prank(_caller);
    _hybrid.compoundIdleBalance(_relayAddr);
  }
}
