// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';

/// @notice Unit tests for `SingleConverter.convertIdleBalance`: the swap-free path for a reward the
///         Relay already holds in `TARGET_TOKEN`, which the swap path refuses as a same-token swap.
contract UnitSingleConverterConvertIdleBalance is BaseEntrypoints {
  SingleConverter internal _converter;

  function setUp() public override {
    super.setUp();
    _converter = new SingleConverter(IFactoryRegistry(_factoryRegistry), _tokenOut);
  }

  /// @notice The swap-free path is keeper-gated like the swap path.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, false);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _converter.convertIdleBalance(_relayAddr);
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
    _converter.convertIdleBalance(_relayAddr);
  }
}
