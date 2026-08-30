// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';
import {BaseEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/BaseEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelayEntrypoint} from 'V3/interfaces/relay/IRelayEntrypoint.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @notice Unit tests for `BaseEntrypoint._pullSwapAndValidate` (through the harness): the shared
///         skeleton that gates on KEEPER, refuses a zero minimum and a same-token swap, then pulls
///         the input, approves and runs the router, resets the allowance, validates the delta that
///         landed on the entrypoint against `minAmountOut` and forwards it to the Relay.
contract UnitBaseEntrypointPullSwapAndValidate is BaseEntrypoints {
  BaseEntrypointHarness internal _harness;

  function setUp() public override {
    super.setUp();
    _harness = new BaseEntrypointHarness(IFactoryRegistry(_factoryRegistry));
  }

  /// @notice Only a KEEPER on the target Relay may drive a swap.
  function test_WhenTheCallerIsNotTheKeeper(address _caller, uint256 _amountIn, uint256 _minOut) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, false);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert with NotKeeper
    vm.expectRevert(IBaseEntrypoint.NotKeeper.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice A zero minimum would let a misrouted swap pass with a zero delta, so it is refused.
  function test_WhenTheMinimumOutputIsZero(address _caller, uint256 _amountIn) external {
    _assumeFuzzable(_caller);
    _mockKeeper(_relayAddr, _caller, true);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, 0, _DEFAULT_DEADLINE);

    // it should revert with ZeroMinOut
    vm.expectRevert(IBaseEntrypoint.ZeroMinOut.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice The keeper names the router, so the protocol's approval set is what bounds the choice.
  ///         Governance revoking a router stops the next swap on it, with no entrypoint redeploy.
  function test_WhenTheProtocolHasNotApprovedTheRouter(
    address _caller,
    address _router,
    uint256 _amountIn,
    uint256 _minOut
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_router);
    _minOut = bound(_minOut, 1, type(uint256).max);
    _mockKeeper(_relayAddr, _caller, true);
    _mockRouterApproval(_router, false);
    IBaseEntrypoint.SwapParams memory _params =
      _swapParamsOn(_router, _relayAddr, _tokenIn, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert with RouterNotApproved
    vm.expectRevert(IBaseEntrypoint.RouterNotApproved.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice Swapping the input into the same token would skew the balance-delta measurement.
  function test_WhenTheInputTokenEqualsTheOutputToken(address _caller, uint256 _amountIn, uint256 _minOut) external {
    _assumeFuzzable(_caller);
    _minOut = bound(_minOut, 1, type(uint256).max);
    _mockKeeper(_relayAddr, _caller, true);
    // tokenIn == tokenOut.
    IBaseEntrypoint.SwapParams memory _params =
      _swapParams(_relayAddr, _tokenOut, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert with SameToken
    vm.expectRevert(IBaseEntrypoint.SameToken.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice A token whose `balanceOf` returns no data reverts the swap instead of reading as zero.
  function test_RevertWhen_TheOutputBalanceReadReturnsNoData(
    address _caller,
    uint256 _amountIn,
    uint256 _minOut
  ) external {
    _assumeFuzzable(_caller);
    _amountIn = bound(_amountIn, 1, type(uint128).max);
    _minOut = bound(_minOut, 1, type(uint128).max);
    _mockKeeper(_relayAddr, _caller, true);
    vm.mockCall(_tokenOut, abi.encodeCall(IERC20.balanceOf, (address(_harness))), bytes(''));
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _DEFAULT_DEADLINE);

    // it should revert
    vm.expectRevert();
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice Output below the minimum reverts after the whole swap runs (untrusted-router check).
  function test_WhenTheLandedOutputIsBelowTheMinimum(
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
    _delta = bound(_delta, 0, _minOut - 1);
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _delta);
    uint256 _deadline = _boundDeadline(_deadlineSeed);
    _mockKeeper(_relayAddr, _caller, true);
    _mockPullSwapFlow(address(_harness), _relayAddr, _tokenIn, _tokenOut, _amountIn, _balanceBefore, _delta, _deadline);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    // it should revert with InsufficientOutput
    vm.expectRevert(IBaseEntrypoint.InsufficientOutput.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice Tokens crediting the Relay mid-swap are not swap output: the delta is measured on the
  ///         entrypoint, so a Relay-side inflow cannot satisfy `minAmountOut`.
  function test_WhenTokensLandOnTheRelayButTheOutputStaysBelowTheMinimum(
    address _caller,
    uint256 _amountIn,
    uint256 _minOut,
    uint256 _delta,
    uint256 _relayInflow,
    uint256 _deadlineSeed
  ) external {
    _assumeFuzzable(_caller);
    _amountIn = bound(_amountIn, 1, type(uint128).max);
    _minOut = bound(_minOut, 1, type(uint128).max);
    _delta = bound(_delta, 0, _minOut - 1);
    _relayInflow = bound(_relayInflow, _minOut, type(uint128).max);
    uint256 _deadline = _boundDeadline(_deadlineSeed);
    _mockKeeper(_relayAddr, _caller, true);
    // The swap leg: the entrypoint's own output balance grows by less than the minimum.
    _mockPullSwapFlow(address(_harness), _relayAddr, _tokenIn, _tokenOut, _amountIn, 0, _delta, _deadline);
    // The manipulation leg: the Relay's balance grows past the minimum during the router call.
    bytes[] memory _relayBalances = new bytes[](2);
    _relayBalances[0] = abi.encode(uint256(0));
    _relayBalances[1] = abi.encode(_relayInflow);
    vm.mockCalls(_tokenOut, abi.encodeCall(IERC20.balanceOf, (_relayAddr)), _relayBalances);
    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    // it should revert with InsufficientOutput
    vm.expectRevert(IBaseEntrypoint.InsufficientOutput.selector);
    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }

  /// @notice A sufficient swap runs the full custody sequence and returns the measured delta.
  function test_WhenTheSwapLandsEnoughOutput(
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

    // Stage the before/after output-balance reads the landed delta is measured from.
    _mockAndExpectTokenBalancesTwice(_tokenOut, address(_harness), [_balanceBefore, _balanceBefore + _delta]);
    // it should pull the input from the relay
    _mockAndExpect(_relayAddr, abi.encodeCall(IRelayEntrypoint.pull, (_tokenIn, _amountIn)), bytes(''));
    // it should approve the router for the input
    _mockAndExpect(_tokenIn, abi.encodeCall(IERC20.approve, (_metaRouter, _amountIn)), abi.encode(true));
    // it should execute the swap on the router
    _mockAndExpect(_metaRouter, abi.encodeCall(IMetarouter.execute, (bytes(''), new bytes[](0), _deadline)), bytes(''));
    // it should reset the router allowance
    _mockAndExpect(_tokenIn, abi.encodeCall(IERC20.approve, (_metaRouter, uint256(0))), abi.encode(true));
    // it should forward the landed delta to the relay
    _mockAndExpectTokenTransfer(_tokenOut, _relayAddr, _delta);
    // it should read the input it still holds
    _mockAndExpect(_tokenIn, abi.encodeCall(IERC20.balanceOf, (address(_harness))), abi.encode(uint256(0)));

    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    vm.prank(_caller);
    uint256 _returned = _harness.pullSwapAndValidate(_params, _tokenOut);

    // it should return the landed delta
    assertEq(_returned, _delta);
  }

  /// @notice A router that consumes only part of the input leaves the rest on the entrypoint, which
  ///         has no sweep of its own. The swap returns it to the Relay instead of stranding it.
  function test_WhenTheRouterSpendsLessThanThePulledInput(
    address _caller,
    uint256 _amountIn,
    uint256 _minOut,
    uint256 _delta,
    uint256 _leftover,
    uint256 _deadlineSeed
  ) external {
    _assumeFuzzable(_caller);
    _amountIn = bound(_amountIn, 2, type(uint128).max);
    _minOut = bound(_minOut, 1, type(uint128).max);
    _delta = bound(_delta, _minOut, type(uint128).max);
    _leftover = bound(_leftover, 1, _amountIn - 1);
    uint256 _deadline = _boundDeadline(_deadlineSeed);
    _mockKeeper(_relayAddr, _caller, true);
    _mockPullSwapFlow(address(_harness), _relayAddr, _tokenIn, _tokenOut, _amountIn, 0, _delta, _deadline);
    // The unspent part of the input is sitting on the entrypoint when the router returns.
    vm.mockCall(_tokenIn, abi.encodeCall(IERC20.balanceOf, (address(_harness))), abi.encode(_leftover));

    // it should return the unspent input to the relay
    _mockAndExpect(_tokenIn, abi.encodeCall(IERC20.transfer, (_relayAddr, _leftover)), abi.encode(true));

    IBaseEntrypoint.SwapParams memory _params = _swapParams(_relayAddr, _tokenIn, _amountIn, _minOut, _deadline);

    vm.prank(_caller);
    _harness.pullSwapAndValidate(_params, _tokenOut);
  }
}
