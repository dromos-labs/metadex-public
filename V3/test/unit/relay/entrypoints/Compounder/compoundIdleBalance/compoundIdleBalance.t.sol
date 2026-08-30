// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';

/// @notice Unit tests for `Compounder.compoundIdleBalance`: the swap-free path for TOKEN that
///         reached the Relay outside the swap flow. The swap path measures its own delta and cannot
///         see such a balance, and it refuses `tokenIn == TOKEN` outright.
contract UnitCompounderCompoundIdleBalance is BaseEntrypoints {
  Compounder internal _compounder;

  function setUp() public override {
    super.setUp();
    _compounder = new Compounder(IFactoryRegistry(_factoryRegistry));
  }

  /// @notice The swap-free path is keeper-gated like the swap path.
  function test_WhenTheCallerIsNotTheKeeper(address _caller) external {
    _assumeFuzzable(_caller);
    vm.mockCall(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenOut));
    _mockKeeper(_relayAddr, _caller, false);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _compounder.compoundIdleBalance(_relayAddr);
  }

  /// @notice The idle TOKEN is compounded without a swap, bounded by what claimants are not owed.
  function test_WhenAKeeperDrainsTheIdleBalance(address _caller, uint256 _balance, uint256 _accounted) external {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, 1, type(uint128).max);
    _accounted = bound(_accounted, 0, _balance - 1);
    _mockKeeper(_relayAddr, _caller, true);
    // it should read the relay TOKEN
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenOut));
    _mockIdleBalance(_relayAddr, _tokenOut, _balance, _accounted);
    // it should compound the unaccounted balance
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.compound, (_balance - _accounted)), bytes(''));

    vm.prank(_caller);
    _compounder.compoundIdleBalance(_relayAddr);
  }
}
