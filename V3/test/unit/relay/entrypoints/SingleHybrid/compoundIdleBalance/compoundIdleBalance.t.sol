// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleHybrid} from 'V3/relay/entrypoints/SingleHybrid.sol';

/// @notice Unit tests for `SingleHybrid.compoundIdleBalance`: the compound half's swap-free path.
contract UnitSingleHybridCompoundIdleBalance is BaseEntrypoints {
  uint256 internal constant _COMPOUND_WEIGHT = 500_000;

  SingleHybrid internal _hybrid;

  function setUp() public override {
    super.setUp();
    _hybrid = new SingleHybrid(IFactoryRegistry(_factoryRegistry), _tokenOut, _COMPOUND_WEIGHT);
  }

  /// @notice The swap-free path is keeper-gated like the swap path.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    vm.mockCall(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenIn));
    _mockKeeper(_relayAddr, _caller, false);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _hybrid.compoundIdleBalance(_relayAddr);
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
