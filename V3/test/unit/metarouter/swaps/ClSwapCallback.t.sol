// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';

import {ClSwapProbe} from 'V3-test/unit/metarouter/harnesses/ClSwapProbe.sol';
import {BaseSwaps} from 'V3-test/unit/metarouter/swaps/BaseSwaps.sol';

contract UnitSwapsClSwapCallback is BaseSwaps {
  uint256 internal constant _AMOUNT_IN = 1000;
  int256 internal constant _AMOUNT_IN_DELTA = 1000;
  int256 internal constant _AMOUNT_OUT_DELTA = 900;

  function test_WhenReachedThroughDelegatecall() external {
    (bool _success, bytes memory _returnData) = address(_metarouter)
      .delegatecall(
        abi.encodeCall(
          IMetarouter.uniswapV3SwapCallback,
          (_AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN))
        )
      );

    // it should revert with DirectCallRequired
    assertFalse(_success);
    assertEq(bytes4(_returnData), IMetarouter.DirectCallRequired.selector);
  }

  function test_WhenNoCallbackCallerIsExpected() external {
    // it should revert with InvalidCallbackCaller for the caller
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidCallbackCaller.selector, address(this)));
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );
  }

  function test_WhenAnotherCallerInvokesTheCallback() external {
    address _otherCaller = makeAddr('otherCaller');
    _metarouter.seedExpectedCallbackCaller(_POOL);

    // it should revert with InvalidCallbackCaller for the caller
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidCallbackCaller.selector, _otherCaller));
    vm.prank(_otherCaller);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );
  }

  function test_WhenACompletedCallbackIsReplayed() external {
    _metarouter.setExecutionActive(uint256(uint160(address(this))));
    _metarouter.seedExpectedCallbackCaller(_POOL);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _AMOUNT_IN);

    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );

    // it should revert with InvalidCallbackCaller for the caller
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidCallbackCaller.selector, _POOL));
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );
  }

  modifier givenTheCallerIsTheExpectedPool() {
    _metarouter.setExecutionActive(uint256(uint160(address(this))));
    _metarouter.seedExpectedCallbackCaller(_POOL);
    _;
  }

  function test_WhenNeitherTokenDeltaIsPositive() external givenTheCallerIsTheExpectedPool {
    // it should revert with InvalidCallbackDeltas
    vm.expectRevert(IMetarouter.InvalidCallbackDeltas.selector);
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      -_AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );
  }

  function test_WhenBothTokenDeltasArePositive() external givenTheCallerIsTheExpectedPool {
    // it should revert with InvalidCallbackDeltas
    vm.expectRevert(IMetarouter.InvalidCallbackDeltas.selector);
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, _AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );
  }

  function test_WhenBothTokenDeltasAreZero() external givenTheCallerIsTheExpectedPool {
    // it should revert with InvalidCallbackDeltas
    vm.expectRevert(IMetarouter.InvalidCallbackDeltas.selector);
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(0, 0, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN));
  }

  modifier givenExactlyOneTokenDeltaIsPositive() {
    _;
  }

  function test_GivenUnexecutedRoutePoolsRemain()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
  {
    uint256 _previousInvoice = 800;
    ClSwapProbe _previousPool = new ClSwapProbe(_CL_FACTORY, _TOKEN_A, _TOKEN_B);
    _previousPool.configure(true, _previousInvoice, _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_previousPool), _previousInvoice);

    bool[] memory _zeroForOne = new bool[](1);
    _zeroForOne[0] = true;
    bytes memory _data = _callbackData(
      _singlePool(address(_previousPool)), _zeroForOne, 1, _TOKEN_A, address(_metarouter), _previousInvoice
    );

    // it should settle the invoice by swapping the previous pool to the caller
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(_AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _data);

    assertEq(_previousPool.swapCalls(), 1);
    assertEq(_previousPool.lastRecipient(), _POOL);
    assertTrue(_previousPool.lastZeroForOne());
    assertEq(_previousPool.lastAmountSpecified(), -_AMOUNT_IN_DELTA);
    assertEq(_metarouter.expectedCallbackCaller(), address(0));
  }

  modifier givenNoUnexecutedRoutePoolsRemain() {
    _;
  }

  function test_WhenTheAmountOwedExceedsTheEncodedMaximum()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
  {
    uint256 _maximum = _AMOUNT_IN - 1;

    // it should revert with TooMuchRequested
    vm.expectRevert(IMetarouter.TooMuchRequested.selector);
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _maximum)
    );
  }

  modifier givenTheAmountOwedIsWithinTheEncodedMaximum() {
    _;
  }

  function test_WhenThePayerIsInvalid()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
    givenTheAmountOwedIsWithinTheEncodedMaximum
  {
    address _invalidPayer = makeAddr('invalidPayer');

    // it should revert with InvalidPayer
    vm.expectRevert(IMetarouter.InvalidPayer.selector);
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, _invalidPayer, _AMOUNT_IN)
    );
  }

  function test_WhenThePayerIsTheExecutionAddress()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
    givenTheAmountOwedIsWithinTheEncodedMaximum
  {
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _AMOUNT_IN);

    // it should clear authorization and transfer the owed token
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(_metarouter), _AMOUNT_IN)
    );

    assertEq(_metarouter.expectedCallbackCaller(), address(0));
  }

  /// @notice A custody settlement's amount is the pool's invoice, not a resolved spend, so it is bounded by the
  ///         balance available to the batch: for the native ERC20 that excludes the pre-batch native, which no
  ///         command may spend.
  function test_WhenTheExecutionAddressOwesTheNativeMirrorTokenBeyondTheBatchNative()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
    givenTheAmountOwedIsWithinTheEncodedMaximum
  {
    // The suite bypasses `_beginExecution`, so seed the accounting an opening batch on a native ERC20 chain would write:
    // a pre-batch snapshot and the published native ERC20 token. The router's real native is dealt one unit short of the
    // snapshot plus the invoice, so the batch native available to the settlement misses the owed amount by one unit.
    uint256 _stranded = 500;
    vm.deal(address(_metarouter), _stranded + _AMOUNT_IN - 1);
    _metarouter.seedNativeAccounting(_stranded, _NATIVE_ERC20, 1);
    // No payment is attempted once the bound rejects the invoice.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no payment'));

    // it should revert with InsufficientBalance for the token
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_NATIVE_ERC20, address(_metarouter), _AMOUNT_IN)
    );
  }

  function test_WhenThePayerIsTheExecutionOwner()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
    givenTheAmountOwedIsWithinTheEncodedMaximum
  {
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _AMOUNT_IN)), abi.encode(true));

    // it should clear authorization and pull the owed token
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      _AMOUNT_IN_DELTA, -_AMOUNT_OUT_DELTA, _callbackData(_TOKEN_A, address(this), _AMOUNT_IN)
    );

    assertEq(_metarouter.expectedCallbackCaller(), address(0));
  }

  function test_WhenTokenOneIsOwed()
    external
    givenTheCallerIsTheExpectedPool
    givenExactlyOneTokenDeltaIsPositive
    givenNoUnexecutedRoutePoolsRemain
    givenTheAmountOwedIsWithinTheEncodedMaximum
  {
    _mockAndExpectTokenTransfer(_TOKEN_B, _POOL, _AMOUNT_IN);

    // it should transfer the encoded input token
    vm.prank(_POOL);
    _metarouter.uniswapV3SwapCallback(
      -_AMOUNT_OUT_DELTA, _AMOUNT_IN_DELTA, _callbackData(_TOKEN_B, address(_metarouter), _AMOUNT_IN)
    );
  }
}
