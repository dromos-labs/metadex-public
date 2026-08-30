// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleHybrid} from 'V3/relay/entrypoints/SingleHybrid.sol';

/// @notice Unit tests for `SingleHybrid.convertIdleBalance`: the convert half's swap-free path.
contract UnitSingleHybridConvertIdleBalance is BaseEntrypoints {
  uint256 internal constant _COMPOUND_WEIGHT = 500_000;

  SingleHybrid internal _hybrid;

  function setUp() public override {
    super.setUp();
    _hybrid = new SingleHybrid(IFactoryRegistry(_factoryRegistry), _tokenOut, _COMPOUND_WEIGHT);
  }

  /// @notice The swap-free path is keeper-gated like the swap path.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, false);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _hybrid.convertIdleBalance(_relayAddr);
  }

  /// @notice The idle target token is notified to the accumulator without a swap.
  function test_WhenAKeeperDistributesTheIdleBalance(address _caller, uint256 _balance, uint256 _accounted) external {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 1, type(uint128).max);
    _accounted = bound(_accounted, 0, _balance - 1);
    _mockKeeper(_relayAddr, _caller, true);
    _mockIdleBalance(_relayAddr, _tokenOut, _balance, _accounted);
    // it should notify the unaccounted target token balance
    _mockAndExpect(
      _relayAddr, abi.encodeCall(IRelayEntrypoint.notifyReward, (_tokenOut, _balance - _accounted)), bytes('')
    );

    vm.prank(_caller);
    _hybrid.convertIdleBalance(_relayAddr);
  }
}
