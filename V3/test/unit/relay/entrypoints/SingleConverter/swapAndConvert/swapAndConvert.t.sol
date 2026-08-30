// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {SingleConverter} from 'V3/relay/entrypoints/SingleConverter.sol';

/// @notice Unit tests for `SingleConverter.swapAndConvert`: it runs the shared pull-swap skeleton with
///         the immutable target token as output and notifies the landed delta to the accumulator.
contract UnitSingleConverterSwapAndConvert is BaseEntrypoints {
  SingleConverter internal _converter;

  function setUp() public override {
    super.setUp();
    // The target token is the swap output; the input token is distinct.
    _converter = new SingleConverter(IFactoryRegistry(_factoryRegistry), _tokenOut);
  }

  /// @notice The convert path delegates its gate to the skeleton: a non-keeper is refused.
  function test_WhenTheCallerIsNotTheKeeper(address _caller, uint256 _amountIn, uint256 _minOut) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, false);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _converter.swapAndConvert(_params);
  }

  /// @notice A keeper swap routes the reward into the target token and notifies the measured delta.
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
    _converter.swapAndConvert(_params);
  }
}
