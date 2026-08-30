// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseMultiEntrypoint} from 'V3-test/unit/relay/entrypoints/BaseMultiEntrypoint.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {IMultiEntrypoint} from 'V3/interfaces/relay/entrypoints/IMultiEntrypoint.sol';
import {MultiConverter} from 'V3/relay/entrypoints/MultiConverter.sol';

/// @notice Unit tests for `MultiConverter.swapAndConvert`: it guards the swap (bound Relay, input not
///         excluded, target configured) then runs the shared pull-swap skeleton to the chosen target
///         and notifies the landed delta. The target set holds the output token; the input is not
///         excluded unless a branch says so.
contract UnitMultiConverterSwapAndConvert is BaseMultiEntrypoint {
  MultiConverter internal _converter;

  function setUp() public override {
    super.setUp();
    _converter = new MultiConverter(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(_tokenOut), _empty()
    );
  }

  /// @notice A swap addressing a Relay other than the bound one is refused.
  function test_WhenTheRelayIsNotTheBoundRelay(address _caller, address _other, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    vm.assume(_other != _relayAddr);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_other, _tokenIn, _amountIn, 1, _DEFAULT_DEADLINE);

    // it should revert with WrongRelay
    vm.expectRevert(IMultiEntrypoint.WrongRelay.selector);
    vm.prank(_caller);
    _converter.swapAndConvert(_params, _tokenOut);
  }

  /// @notice An excluded input token cannot be swapped.
  function test_WhenTheInputTokenIsExcluded(address _caller, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    // A fresh instance that excludes the input token.
    MultiConverter _instance = new MultiConverter(
      IFactoryRegistry(_factoryRegistry), IRelayEntrypoint(_relayAddr), _single(_tokenOut), _single(_tokenIn)
    );
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, 1, _DEFAULT_DEADLINE);

    // it should revert with TokenExcluded
    vm.expectRevert(IMultiEntrypoint.TokenExcluded.selector);
    vm.prank(_caller);
    _instance.swapAndConvert(_params, _tokenIn);
  }

  /// @notice A convert target outside the configured set is rejected.
  function test_WhenTheTargetTokenIsNotConfigured(address _caller, address _nonTarget, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    vm.assume(_nonTarget != _tokenOut);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, 1, _DEFAULT_DEADLINE);

    // it should revert with NotTargetToken
    vm.expectRevert(IMultiEntrypoint.NotTargetToken.selector);
    vm.prank(_caller);
    _converter.swapAndConvert(_params, _nonTarget);
  }

  /// @notice A valid convert swaps into the configured target and notifies the landed delta.
  function test_WhenAKeeperConvertsAReward(
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
    // it should swap the reward into the target token
    _mockPullSwapFlow(
      address(_converter), _relayAddr, _tokenIn, _tokenOut, _amountIn, _balanceBefore, _delta, _deadline
    );
    // it should notify the landed delta
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.notifyReward, (_tokenOut, _delta)), bytes(''));
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    vm.prank(_caller);
    _converter.swapAndConvert(_params, _tokenOut);
  }
}
