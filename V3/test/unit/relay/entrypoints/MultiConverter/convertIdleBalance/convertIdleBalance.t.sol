// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';
import {MultiConverter} from 'V3/relay/entrypoints/MultiConverter.sol';

/// @notice Unit tests for `MultiConverter.convertIdleBalance`: the swap-free path for a reward the
///         bound Relay already holds in a configured target token. The exclusion list does not apply
///         here, since it guards the input side and this path pulls no input.
contract UnitMultiConverterConvertIdleBalance is BaseMultiEntrypoint {
  MultiConverter internal _converter;

  function setUp() public override {
    super.setUp();
    _converter = new MultiConverter(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(_tokenOut), _empty()
    );
  }

  /// @notice The config policy applies to the bound Relay only.
  function test_WhenTheRelayIsNotTheBoundRelay(address _caller, address _other) external {
    _assumeFuzzable(_caller);
    vm.assume(_other != _relayAddr);

    // it should revert with WrongRelay
    vm.expectRevert(IMultiEntrypoint.WrongRelay.selector);
    vm.prank(_caller);
    _converter.convertIdleBalance(_other, _tokenOut);
  }

  /// @notice A target outside the allow list cannot be distributed, swap or no swap.
  function test_WhenTheTargetTokenIsNotConfigured(address _caller, address _target) external {
    _assumeFuzzable(_caller);
    vm.assume(_target != _tokenOut);

    // it should revert with NotTargetToken
    vm.expectRevert(IMultiEntrypoint.NotTargetToken.selector);
    vm.prank(_caller);
    _converter.convertIdleBalance(_relayAddr, _target);
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
    _converter.convertIdleBalance(_relayAddr, _tokenOut);
  }
}
