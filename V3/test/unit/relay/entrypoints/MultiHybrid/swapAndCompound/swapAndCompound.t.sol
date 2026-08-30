// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';
import {MultiHybrid} from 'V3/relay/entrypoints/MultiHybrid.sol';

/// @notice Unit tests for the `MultiHybrid` compound side: it guards the bound Relay and a non-excluded
///         input, then reads the Relay's TOKEN as output, runs the shared pull-swap skeleton and
///         compounds the landed delta.
contract UnitMultiHybridSwapAndCompound is BaseMultiEntrypoint {
  MultiHybrid internal _hybrid;

  function setUp() public override {
    super.setUp();
    _hybrid =
      new MultiHybrid(IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _empty(), 500_000);
  }

  /// @notice A swap addressing a Relay other than the bound one is refused.
  function test_WhenTheRelayIsNotTheBoundRelay(address _caller, address _other, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    vm.assume(_other != _relayAddr);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_other, _tokenIn, _amountIn, 1, _DEFAULT_DEADLINE);

    // it should revert with WrongRelay
    vm.expectRevert(IMultiEntrypoint.WrongRelay.selector);
    vm.prank(_caller);
    _hybrid.swapAndCompound(_params);
  }

  /// @notice An excluded input cannot be compounded.
  function test_WhenTheInputTokenIsExcluded(address _caller, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    MultiHybrid _instance = new MultiHybrid(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _empty(), _single(_tokenIn), 500_000
    );
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, 1, _DEFAULT_DEADLINE);

    // it should revert with TokenExcluded
    vm.expectRevert(IMultiEntrypoint.TokenExcluded.selector);
    vm.prank(_caller);
    _instance.swapAndCompound(_params);
  }

  /// @notice A valid compound swaps into TOKEN and compounds the landed delta.
  function test_WhenAKeeperCompoundsAReward(
    address _caller,
    uint256 _amountIn,
    uint256 _minOut,
    uint256 _delta,
    uint256 _balanceBefore,
    uint256 _deadlineSeed
  ) external {
    _assumeFuzzable(_caller);
    _amountIn = bound(_amountIn, 1, type(uint128).max);
    _minOut = bound(_minOut, 1, type(uint128).max);
    _delta = bound(_delta, _minOut, type(uint128).max);
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _delta);
    uint256 _deadline = _boundDeadline(_deadlineSeed);
    _mockKeeper(_relayAddr, _caller, true);
    // it should swap the reward into the relay TOKEN
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenOut));
    _mockPullSwapFlow(address(_hybrid), _relayAddr, _tokenIn, _tokenOut, _amountIn, _balanceBefore, _delta, _deadline);
    // it should compound the landed delta
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.compound, (_delta)), bytes(''));
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    vm.prank(_caller);
    _hybrid.swapAndCompound(_params);
  }
}
