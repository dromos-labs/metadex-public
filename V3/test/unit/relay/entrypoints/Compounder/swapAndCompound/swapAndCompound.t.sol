// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';
import {Compounder} from 'V3/relay/entrypoints/Compounder.sol';

/// @notice Unit tests for `Compounder.swapAndCompound`: it reads the Relay's TOKEN as the swap output,
///         runs the shared pull-swap skeleton and compounds the landed delta. The skeleton's own
///         guards are covered by the BaseEntrypoint suite; here the compound wiring is asserted.
contract UnitCompounderSwapAndCompound is BaseEntrypoints {
  Compounder internal _compounder;

  function setUp() public override {
    super.setUp();
    _compounder = new Compounder(IFactoryRegistry(_factoryRegistry));
  }

  /// @notice The compound path delegates its gate to the skeleton: a non-keeper is refused.
  function test_WhenTheCallerIsNotTheKeeper(address _caller, uint256 _amountIn, uint256 _minOut) external {
    _assumeFuzzable(_caller);
    // TOKEN is read before the skeleton's keeper check, so it must be mocked even on the revert path.
    vm.mockCall(_relayAddr, abi.encodeCall(IRelayEntrypoint.TOKEN, ()), abi.encode(_tokenOut));
    _mockKeeper(_relayAddr, _caller, false);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _compounder.swapAndCompound(_params);
  }

  /// @notice A keeper swap routes the reward into TOKEN and compounds the measured delta.
  function test_WhenAKeeperSwapsAReward(
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
    _mockPullSwapFlow(
      address(_compounder), _relayAddr, _tokenIn, _tokenOut, _amountIn, _balanceBefore, _delta, _deadline
    );
    // it should compound the landed delta
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.compound, (_delta)), bytes(''));
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    vm.prank(_caller);
    _compounder.swapAndCompound(_params);
  }
}
