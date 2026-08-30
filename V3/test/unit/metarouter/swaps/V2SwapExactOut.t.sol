// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';
import {BaseSwaps} from 'V3-test/unit/metarouter/swaps/BaseSwaps.sol';

contract UnitSwapsV2SwapExactOut is BaseSwaps {
  uint256 internal constant _AMOUNT_OUT = 900;
  uint256 internal constant _QUOTED_IN = 992;

  function test_WhenTheRecipientIsTheZeroAddress() external {
    // it should revert with InvalidRecipient
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _execute(Commands.V2_SWAP_EXACT_OUT, _exactOutput(new address[](0), _TOKEN_A, 0, 0, address(0)));
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_WhenThePoolPathIsEmpty() external givenTheRecipientIsValid {
    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(Commands.V2_SWAP_EXACT_OUT, _exactOutput(new address[](0), _TOKEN_A, 0, 0, _RECIPIENT));
  }

  function test_WhenAPoolIsNotRegistered() external givenTheRecipientIsValid {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(address(0)));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenAFactoryDoesNotRecognizeThePool() external givenTheRecipientIsValid {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_POOL)), abi.encode(false));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenAPoolReportsAnUnsupportedPoolType() external givenTheRecipientIsValid {
    // The pool-type check reverts before the token resolution, so the validated-pool mocks are set inline.
    _mockValidatedPool();
    _mockAndExpect(_POOL, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('MOCK')));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  modifier givenEveryPoolIsValidated() {
    _mockValidatedPool();
    _mockAndExpect(_POOL, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_A));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.token1, ()), abi.encode(_TOKEN_B));
    _;
  }

  function test_WhenTheInputTokenDoesNotBelongToThePool() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    address _unrelatedToken = makeAddr('unrelatedToken');

    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _unrelatedToken, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenTheRouteContainsAStablePool() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    // Overrides the volatile pool type expected by the modifier.
    vm.mockCall(_POOL, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_STABLE')));
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _QUOTED_IN);
    _mockExactOutputBalance(_TOKEN_B, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    // it should execute the swap route
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenThePoolQuoteReverts() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    vm.mockCallRevert(
      _POOL,
      abi.encodeCall(IPool.getAmountInWithTotalFee, (_AMOUNT_OUT, _TOKEN_B)),
      abi.encodeWithSelector(IPool.InsufficientLiquidity.selector)
    );

    // it should bubble the pool revert
    vm.expectRevert(IPool.InsufficientLiquidity.selector);
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenTheQuotedInputExceedsTheMaximum(uint256 _maximumIn)
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    _maximumIn = bound(_maximumIn, 0, _QUOTED_IN - 1);
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);

    // it should revert with TooMuchRequested
    vm.expectRevert(IMetarouter.TooMuchRequested.selector);
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _maximumIn, _RECIPIENT)
    );
  }

  modifier givenTheQuotedInputIsWithinTheMaximum() {
    _;
  }

  function test_WhenThePayerIsTheExecutionOwner()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _QUOTED_IN)), abi.encode(true));
    _mockExactOutputBalance(_TOKEN_B, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should pay the first pool directly from the execution owner
    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT)
    );
  }

  function test_WhenThePayerIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _QUOTED_IN);
    _mockExactOutputBalance(_TOKEN_B, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');
    // it should track the input token for the closure sweep
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    // it should fund the quoted input from custody
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT)
    );
  }

  /// @notice A custody payment's amount is the pool's invoice, not a resolved spend, so it is bounded by the balance
  ///         available to the batch: for the native ERC20 input token that excludes the pre-batch native, which the
  ///         invoice must not spend even when the full balance covers it.
  function test_WhenTheExecutionAddressPaysTheNativeMirrorTokenBeyondTheBatchNative()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    address _nativeErc20Caller = makeAddr('nativeErc20Caller');
    // The batch introduces one unit less native than the invoice; the pre-batch stranded native covers the rest, so
    // only the availability bound stops the payment from spending it.
    uint256 _stranded = 1000;
    uint256 _batchNative = _QUOTED_IN - 1;
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_nativeErc20Caller, _batchNative);

    // The suite pool re-reports its token zero as the native ERC20 token for this route; a plain mock override keeps the
    // modifier's single expected `token0` read.
    vm.mockCall(_POOL, abi.encodeCall(IPool.token0, ()), abi.encode(_NATIVE_ERC20));
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    // The bound reads the router's real native, never the native ERC20's `balanceOf`.
    // No payment is attempted once the bound rejects the invoice.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no payment'));

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      _unflagged(Commands.V2_SWAP_EXACT_OUT),
      _exactOutput(_singlePool(_POOL), _NATIVE_ERC20, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT)
    );

    // it should revert with InsufficientBalance for the input token
    vm.prank(_nativeErc20Caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);
  }

  /// @notice A catchable native ERC20 custody failure must stay inside its child frame: the next command executes,
  ///         batch closure refunds the caller's native contribution, and the router's pre-batch native remains held.
  function test_WhenAFlaggedExecutionAddressPaymentExceedsTheBatchNative()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    address _nativeErc20Caller = makeAddr('nativeErc20Caller');
    address _passingToken = _mockContract('passingToken');
    uint256 _stranded = 1000;
    uint256 _batchNative = _QUOTED_IN - 1;
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_nativeErc20Caller, _batchNative);

    vm.mockCall(_POOL, abi.encodeCall(IPool.token0, ()), abi.encode(_NATIVE_ERC20));
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    // The bound reads the router's real native, never the native ERC20's `balanceOf`; no payment once it rejects the invoice.
    vm.mockCallRevert(_NATIVE_ERC20, abi.encodeWithSelector(IERC20.transfer.selector), bytes('no payment'));
    // The unflagged balance check after the catchable swap proves execution resumes in the outer batch.
    _mockAndExpectTokenBalance(_passingToken, _nativeErc20Caller, 1);

    bytes1[] memory _commandBytes = new bytes1[](2);
    _commandBytes[0] = _flagged(Commands.V2_SWAP_EXACT_OUT);
    _commandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _batchInputs = new bytes[](2);
    _batchInputs[0] = _exactOutput(_singlePool(_POOL), _NATIVE_ERC20, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT);
    _batchInputs[1] = _balanceCheckInput(_passingToken, _nativeErc20Caller, 1);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    // it should continue the batch with the next command
    // it should preserve the pre-batch native and refund the batch contribution
    _expectEmit(address(_nativeErc20Metarouter));
    emit IMetarouter.BatchExecuted(_nativeErc20Caller);
    vm.prank(_nativeErc20Caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);

    assertEq(_nativeErc20Caller.balance, _batchNative, 'batch native not refunded');
    assertEq(address(_nativeErc20Metarouter).balance, _stranded, 'pre-batch native spent');
    assertEq(_nativeErc20Metarouter.msgSender(), address(0), 'locker slot not cleared');
    assertEq(_nativeErc20Metarouter.nativeBalanceBefore(), 0, 'native-balance-before slot not cleared');
    assertEq(_nativeErc20Metarouter.trackedLength(), 0, 'tracked-array length not cleared');
  }

  function test_WhenTheInputTokenIsTokenOne()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_A, _QUOTED_IN);
    _mockAndExpectTokenTransfer(_TOKEN_B, _POOL, _QUOTED_IN);
    _mockExactOutputBalance(_TOKEN_A, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (_AMOUNT_OUT, 0, _RECIPIENT, '')), '');
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);

    // it should quote the token zero output and request it from the pool
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_B, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT)
    );
  }

  function test_WhenThePathContainsMultiplePools()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    uint256 _firstQuotedIn = 1105;
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_tokenC));

    // The route is quoted backwards: the last pool first, then the first pool for the input the last one needs.
    _mockQuote(_secondPool, _AMOUNT_OUT, _tokenC, _QUOTED_IN);
    _mockQuote(_POOL, _QUOTED_IN, _TOKEN_B, _firstQuotedIn);

    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _firstQuotedIn);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);
    _mockExactOutputBalance(_tokenC, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _QUOTED_IN, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    // it should quote backwards and route each output to the next pool
    _execute(Commands.V2_SWAP_EXACT_OUT, _exactOutput(_pools, _TOKEN_A, _AMOUNT_OUT, _firstQuotedIn, _RECIPIENT));
  }

  function test_WhenTheHopDirectionsDiffer()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    uint256 _firstQuotedIn = 1105;
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    // The intermediate token is the second pool's token one, so the second hop swaps one for zero.
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_TOKEN_B));

    // The route is quoted backwards: the last pool first, then the first pool for the input the last one needs.
    _mockQuote(_secondPool, _AMOUNT_OUT, _tokenC, _QUOTED_IN);
    _mockQuote(_POOL, _QUOTED_IN, _TOKEN_B, _firstQuotedIn);

    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _firstQuotedIn);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);
    _mockExactOutputBalance(_tokenC, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _QUOTED_IN, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (_AMOUNT_OUT, 0, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    // it should request each hop output on its own side
    _execute(Commands.V2_SWAP_EXACT_OUT, _exactOutput(_pools, _TOKEN_A, _AMOUNT_OUT, _firstQuotedIn, _RECIPIENT));
  }

  /// @notice Proves an intermediate inflow cannot mask under-delivery by the final hop when the output token recurs.
  function test_WhenTheOutputTokenIsRevisitedAndAnIntermediatePoolIsTheRecipient()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    address _tokenC = _mockContract('tokenC');
    address _intermediatePool = _mockContract('intermediatePool');
    address _finalPool = _mockContract('finalPool');
    uint256 _firstAmountIn = 1000;
    uint256 _intermediateAmountOut = 900;
    uint256 _finalAmountIn = 800;
    uint256 _finalAmountOut = 700;
    uint256 _finalAmountReceived = 600;
    uint256 _recipientBalance = 10_000;

    _mockValidatedRevisitedPool(_intermediatePool, _tokenC);
    _mockValidatedRevisitedPool(_finalPool, _tokenC);

    _mockQuote(_finalPool, _finalAmountOut, _TOKEN_B, _finalAmountIn);
    _mockQuote(_intermediatePool, _finalAmountIn, _tokenC, _intermediateAmountOut);
    _mockQuote(_POOL, _intermediateAmountOut, _TOKEN_B, _firstAmountIn);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _firstAmountIn)), abi.encode(true)
    );

    _installReceiptProbes(
      _intermediatePool, _finalPool, _recipientBalance, _intermediateAmountOut, _finalAmountReceived
    );

    vm.expectCall(_POOL, abi.encodeCall(IPool.swap, (0, _intermediateAmountOut, _intermediatePool, '')));
    vm.expectCall(_intermediatePool, abi.encodeCall(IPool.swap, (0, _finalAmountIn, _finalPool, '')));
    vm.expectCall(_finalPool, abi.encodeCall(IPool.swap, (_finalAmountOut, 0, _intermediatePool, '')));

    address[] memory _pools = new address[](3);
    _pools[0] = _POOL;
    _pools[1] = _intermediatePool;
    _pools[2] = _finalPool;

    // it should revert based on the final hop output
    vm.expectRevert(
      abi.encodeWithSelector(IMetarouter.TooLittleReceived.selector, _finalAmountOut, _finalAmountReceived)
    );
    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutputFromUser(_pools, _TOKEN_A, _finalAmountOut, _firstAmountIn, _intermediatePool)
    );
  }

  function test_WhenTheRecipientReceivesLessThanTheRequestedOutput(
    uint256 _balanceBefore,
    uint256 _received
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated givenTheQuotedInputIsWithinTheMaximum {
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _AMOUNT_OUT);
    _received = bound(_received, 0, _AMOUNT_OUT - 1);
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _QUOTED_IN)), abi.encode(true));
    _mockAndExpectTokenBalancesTwice(_TOKEN_B, _RECIPIENT, [_balanceBefore, _balanceBefore + _received]);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should revert with TooLittleReceived
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.TooLittleReceived.selector, _AMOUNT_OUT, _received));
    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenTheRecipientReceivesTheRequestedOutput(uint256 _balanceBefore)
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _balanceBefore = bound(_balanceBefore, 0, type(uint256).max - _AMOUNT_OUT);
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _QUOTED_IN)), abi.encode(true));
    _mockAndExpectTokenBalancesTwice(_TOKEN_B, _RECIPIENT, [_balanceBefore, _balanceBefore + _AMOUNT_OUT]);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should complete the swap
    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  function test_WhenTheRecipientIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _QUOTED_IN);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, address(_metarouter), '')), '');
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);
    uint256[] memory _outputBalances = new uint256[](3);
    _outputBalances[1] = _AMOUNT_OUT;
    _outputBalances[2] = _AMOUNT_OUT;
    _mockAndExpectTokenBalances(_TOKEN_B, address(_metarouter), _outputBalances);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(this), _AMOUNT_OUT);

    // it should track and return the output at batch closure
    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, address(_metarouter))
    );
  }

  function test_WhenTheQuotedInputEqualsTheMaximum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _QUOTED_IN);
    _mockExactOutputBalance(_TOKEN_B, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    // it should complete at the exact bound
    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN, _RECIPIENT)
    );
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_v2SwapExactOutSingleHop()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    _mockQuote(_POOL, _AMOUNT_OUT, _TOKEN_B, _QUOTED_IN);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _QUOTED_IN)), abi.encode(true));
    _mockExactOutputBalance(_TOKEN_B, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    _execute(
      Commands.V2_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _QUOTED_IN + 1, _RECIPIENT)
    );
    vm.snapshotGasLastCall('Metarouter_v2SwapExactOut_singleHop');
  }

  function testGas_v2SwapExactOutTwoHops()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheQuotedInputIsWithinTheMaximum
  {
    uint256 _firstQuotedIn = 1105;
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_tokenC));
    _mockQuote(_secondPool, _AMOUNT_OUT, _tokenC, _QUOTED_IN);
    _mockQuote(_POOL, _QUOTED_IN, _TOKEN_B, _firstQuotedIn);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _firstQuotedIn)), abi.encode(true)
    );
    _mockExactOutputBalance(_tokenC, _RECIPIENT);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _QUOTED_IN, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    _execute(
      Commands.V2_SWAP_EXACT_OUT, _exactOutputFromUser(_pools, _TOKEN_A, _AMOUNT_OUT, _firstQuotedIn, _RECIPIENT)
    );
    vm.snapshotGasLastCall('Metarouter_v2SwapExactOut_twoHops');
  }

  function _mockValidatedPool() private {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_POOL)), abi.encode(true));
  }

  /// @dev Authenticates a B/C pool used after the suite's primary A/B pool.
  function _mockValidatedRevisitedPool(address _pool, address _tokenC) private {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_pool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_pool)), abi.encode(true));
    _mockAndExpect(_pool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_pool, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(_pool, abi.encodeCall(IPool.token1, ()), abi.encode(_tokenC));
  }

  function _mockQuote(address _pool, uint256 _amountOut, address _tokenOut, uint256 _quotedIn) private {
    _mockAndExpect(_pool, abi.encodeCall(IPool.getAmountInWithTotalFee, (_amountOut, _tokenOut)), abi.encode(_quotedIn));
  }

  function _mockExactOutputBalance(address _tokenOut, address _recipient) private {
    _mockAndExpectTokenBalancesTwice(_tokenOut, _recipient, [uint256(0), _AMOUNT_OUT]);
  }
}
