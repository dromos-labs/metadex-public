// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {stdError} from 'forge-std/StdError.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseSwaps} from 'V3-test/unit/metarouter/swaps/BaseSwaps.sol';

contract UnitSwapsV2SwapExactIn is BaseSwaps {
  uint256 internal constant _AMOUNT_IN = 1000;
  uint256 internal constant _AMOUNT_OUT = 900;
  uint256 internal constant _RESERVE = 10_000;

  function test_WhenAUserPayerSelectsAProportionalSpend() external {
    IMetarouter.BalanceSpend memory _spend =
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 1_000_000});
    bytes memory _input = _exactInputWithSpend(_singlePool(_POOL), _TOKEN_A, _spend, true, 0, address(0));

    // it should revert with InvalidSpendMode
    vm.expectRevert(IMetarouter.InvalidSpendMode.selector);
    _execute(Commands.V2_SWAP_EXACT_IN, _input);
  }

  function test_WhenTheRecipientIsTheZeroAddress() external {
    // it should revert with InvalidRecipient
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(new address[](0), _TOKEN_A, 0, 0, address(0)));
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_WhenThePoolPathIsEmpty() external givenTheRecipientIsValid {
    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(new address[](0), _TOKEN_A, 0, 0, _RECIPIENT));
  }

  function test_WhenAPoolIsNotRegistered() external givenTheRecipientIsValid {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(address(0)));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenAFactoryDoesNotRecognizeThePool() external givenTheRecipientIsValid {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_POOL)), abi.encode(false));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenAPoolReportsAnUnsupportedPoolType() external givenTheRecipientIsValid {
    // The pool-type check reverts before the token resolution, so the validated-pool mocks are set inline.
    _mockValidatedPool();
    _mockAndExpect(_POOL, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('MOCK')));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
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
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _unrelatedToken, 0, 0, _RECIPIENT));
  }

  function test_WhenTheRouteContainsAStablePool() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    // Overrides the volatile pool type expected by the modifier.
    vm.mockCall(_POOL, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_STABLE')));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should execute the swap route
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenThePoolBalanceIsBelowTheInputReserve() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(_AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE - 1));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));

    // it should revert with InvalidReserves for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidReserves.selector, _POOL));
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, 0, _RECIPIENT));
  }

  function test_WhenTheRecipientOutputBalanceDecreases(
    uint256 _balanceBefore,
    uint256 _balanceAfter
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _balanceBefore = bound(_balanceBefore, 1, type(uint256).max);
    _balanceAfter = bound(_balanceAfter, 0, _balanceBefore - 1);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(_AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(_balanceBefore);
    _recipientBalances[1] = abi.encode(_balanceAfter);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should revert with an arithmetic panic
    vm.expectRevert(stdError.arithmeticError);
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, 0, _RECIPIENT));
  }

  /// @notice Proves an intermediate inflow cannot mask under-delivery by the final hop when the output token recurs.
  function test_WhenTheOutputTokenIsRevisitedAndAnIntermediatePoolIsTheRecipient()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    address _tokenC = _mockContract('tokenC');
    address _intermediatePool = _mockContract('intermediatePool');
    address _finalPool = _mockContract('finalPool');
    uint256 _intermediateAmountOut = 900;
    uint256 _finalAmountIn = 800;
    uint256 _finalAmountOut = 700;
    uint256 _finalAmountReceived = 600;

    _mockValidatedRevisitedPool(_intermediatePool, _tokenC);
    _mockValidatedRevisitedPool(_finalPool, _tokenC);

    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_intermediateAmountOut)
    );
    _mockAndExpect(
      _intermediatePool, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp)
    );
    _mockAndExpect(
      _intermediatePool,
      abi.encodeCall(IPool.getAmountOutWithTotalFee, (_intermediateAmountOut, _TOKEN_B)),
      abi.encode(_finalAmountIn)
    );
    _mockAndExpect(_finalPool, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _finalPool, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_finalAmountIn, _tokenC)), abi.encode(_finalAmountOut)
    );

    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _AMOUNT_IN)), abi.encode(true));
    _mockAndExpectTokenBalance(_TOKEN_A, _POOL, _RESERVE + _AMOUNT_IN);
    _mockAndExpectTokenBalance(_tokenC, _finalPool, _RESERVE + _finalAmountIn);

    _installReceiptProbes(_intermediatePool, _finalPool, _RESERVE, _intermediateAmountOut, _finalAmountReceived);

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
      Commands.V2_SWAP_EXACT_IN, _exactInputFromUser(_pools, _TOKEN_A, _AMOUNT_IN, _finalAmountOut, _intermediatePool)
    );
  }

  function test_WhenTheFinalOutputIsBelowTheMinimum(
    uint256 _received,
    uint256 _minAmountOut
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _minAmountOut = bound(_minAmountOut, 1, type(uint256).max);
    _received = bound(_received, 0, _minAmountOut - 1);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_minAmountOut)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(_AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_received);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _minAmountOut, _RECIPIENT, '')), '');

    // it should revert with TooLittleReceived
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.TooLittleReceived.selector, _minAmountOut, _received));
    _execute(
      Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _minAmountOut, _RECIPIENT)
    );
  }

  /// @notice Proves the final-hop quote check reverts before the final swap and without reading the recipient balance.
  function test_WhenTheFinalHopQuoteIsBelowTheMinimum(
    uint256 _quotedOut,
    uint256 _minAmountOut
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _minAmountOut = bound(_minAmountOut, 1, type(uint256).max);
    _quotedOut = bound(_quotedOut, 0, _minAmountOut - 1);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_quotedOut)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(_AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    // it should not read the recipient balance
    vm.mockCallRevert(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), bytes('balance not read'));
    // it should not execute the final swap
    vm.mockCallRevert(_POOL, abi.encodeWithSelector(IPool.swap.selector), bytes('swap not executed'));

    // it should revert with TooLittleReceived from the quoted output
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.TooLittleReceived.selector, _minAmountOut, _quotedOut));
    _execute(
      Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _minAmountOut, _RECIPIENT)
    );
  }

  modifier givenTheFinalOutputMeetsTheMinimum() {
    _;
  }

  function test_GivenTheFinalOutputMeetsTheMinimum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should quote every hop with the total fee from the amount actually received by that pool
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenTheFirstPoolReceivesLessThanTheRequestedInput(uint256 _actualAmountIn)
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _actualAmountIn = bound(_actualAmountIn, 0, _AMOUNT_IN - 1);
    uint256 _actualAmountOut = 818;
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_actualAmountIn, _TOKEN_A)), abi.encode(_actualAmountOut)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _actualAmountIn));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_actualAmountOut);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _actualAmountOut, _RECIPIENT, '')), '');

    // it should quote from the received balance delta
    _execute(
      Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _actualAmountOut, _RECIPIENT)
    );
  }

  function test_WhenThePayerIsTheExecutionOwner()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should pay the first pool directly from the execution owner
    _execute(
      Commands.V2_SWAP_EXACT_IN, _exactInputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
  }

  function test_WhenThePayerIsTheExecutionAddress(uint256 _residual)
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _residual = bound(_residual, 1, type(uint256).max - _AMOUNT_IN);
    uint256 _custodyBalance = _AMOUNT_IN + _residual;
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [_custodyBalance, _residual]);
    _mockAndExpectTokenBalance(_TOKEN_A, _POOL, _RESERVE + _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, _POOL, _AMOUNT_IN);
    _mockAndExpectTokenBalancesTwice(_TOKEN_B, _RECIPIENT, [uint256(0), _AMOUNT_OUT]);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    // it should track the input token for the closure sweep
    _mockAndExpectTokenTransfer(_TOKEN_A, address(this), _residual);

    // it should pay the first pool from custody
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenTheRecipientIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    bytes[] memory _inputBalances = new bytes[](2);
    _inputBalances[0] = abi.encode(_AMOUNT_IN);
    _inputBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _inputBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.transfer, (address(this), _AMOUNT_OUT)), abi.encode(true));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, address(_metarouter), '')), '');

    bytes[] memory _outputBalances = new bytes[](3);
    _outputBalances[0] = abi.encode(uint256(0));
    _outputBalances[1] = abi.encode(_AMOUNT_OUT);
    _outputBalances[2] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _outputBalances);

    // it should track and return the output at batch closure
    _execute(
      Commands.V2_SWAP_EXACT_IN,
      _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, address(_metarouter))
    );
  }

  function test_WhenTheInputIsTokenOne()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_B)), abi.encode(_AMOUNT_OUT)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (_AMOUNT_OUT, 0, _RECIPIENT, '')), '');

    // it should request token zero output
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_B, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenThePathContainsMultiplePools()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    uint256 _secondAmountOut = 818;
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_tokenC));
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(
      _secondPool, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_OUT, _TOKEN_B)), abi.encode(_secondAmountOut)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_secondAmountOut);
    _mockAndExpectSequence(_tokenC, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);

    // The intermediate hop output is only read once, by the second hop's quote, after the first swap credited it.
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_secondPool)), abi.encode(_RESERVE + _AMOUNT_OUT));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (0, _secondAmountOut, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    // it should forward each actual pool output into the next hop
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_pools, _TOKEN_A, _AMOUNT_IN, _secondAmountOut, _RECIPIENT));
  }

  function test_WhenTheHopDirectionsDiffer()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    uint256 _secondAmountOut = 818;
    // The intermediate token is the second pool's token one, so the second hop swaps one for zero.
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(
      _secondPool, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_OUT, _TOKEN_B)), abi.encode(_secondAmountOut)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_secondAmountOut);
    _mockAndExpectSequence(_tokenC, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);

    // The second hop measures its input on the token one reserve side.
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_secondPool)), abi.encode(_RESERVE + _AMOUNT_OUT));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (_secondAmountOut, 0, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    // it should request each hop output on its own side
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_pools, _TOKEN_A, _AMOUNT_IN, _secondAmountOut, _RECIPIENT));
  }

  function test_WhenTheOutputEqualsTheMinimum(uint256 _amountOut)
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_amountOut)
    );
    bytes[] memory _routerBalances = new bytes[](2);
    _routerBalances[0] = abi.encode(_AMOUNT_IN);
    _routerBalances[1] = abi.encode(uint256(0));
    _mockAndExpectSequence(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), _routerBalances);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_amountOut);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _amountOut, _RECIPIENT, '')), '');

    // it should complete the swap at the exact bound
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _amountOut, _RECIPIENT));
  }

  function test_WhenThePoolReceivesZeroInput()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpectWithTimes(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(0), 2);
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transfer, (_POOL, 0)), abi.encode(true));
    _mockAndExpectWithTimes(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), abi.encode(0), 2);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (0, _TOKEN_A)), abi.encode(0));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, 0, _RECIPIENT, '')), '');

    // it should quote the zero received amount with the total fee
    _execute(Commands.V2_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, 0, 0, _RECIPIENT));
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_v2SwapExactInSingleHop()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_AMOUNT_OUT);
    _mockAndExpectSequence(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _RECIPIENT, '')), '');

    _execute(
      Commands.V2_SWAP_EXACT_IN, _exactInputFromUser(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
    vm.snapshotGasLastCall('Metarouter_v2SwapExactIn_singleHop');
  }

  function testGas_v2SwapExactInTwoHops()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    address _secondPool = _mockContract('secondPool');
    uint256 _secondAmountOut = 818;
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.token1, ()), abi.encode(_tokenC));
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_secondPool)), abi.encode(_V2_FACTORY)
    );
    _mockAndExpect(_V2_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_secondPool)), abi.encode(true));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.getReserves, ()), abi.encode(_RESERVE, _RESERVE, block.timestamp));
    _mockAndExpect(
      _POOL, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_IN, _TOKEN_A)), abi.encode(_AMOUNT_OUT)
    );
    _mockAndExpect(
      _secondPool, abi.encodeCall(IPool.getAmountOutWithTotalFee, (_AMOUNT_OUT, _TOKEN_B)), abi.encode(_secondAmountOut)
    );
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.balanceOf, (_POOL)), abi.encode(_RESERVE + _AMOUNT_IN));
    _mockAndExpect(_TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), _POOL, _AMOUNT_IN)), abi.encode(true));
    bytes[] memory _recipientBalances = new bytes[](2);
    _recipientBalances[0] = abi.encode(uint256(0));
    _recipientBalances[1] = abi.encode(_secondAmountOut);
    _mockAndExpectSequence(_tokenC, abi.encodeCall(IERC20.balanceOf, (_RECIPIENT)), _recipientBalances);
    _mockAndExpect(_TOKEN_B, abi.encodeCall(IERC20.balanceOf, (_secondPool)), abi.encode(_RESERVE + _AMOUNT_OUT));
    _mockAndExpect(_POOL, abi.encodeCall(IPool.swap, (0, _AMOUNT_OUT, _secondPool, '')), '');
    _mockAndExpect(_secondPool, abi.encodeCall(IPool.swap, (0, _secondAmountOut, _RECIPIENT, '')), '');

    address[] memory _pools = new address[](2);
    _pools[0] = _POOL;
    _pools[1] = _secondPool;

    _execute(Commands.V2_SWAP_EXACT_IN, _exactInputFromUser(_pools, _TOKEN_A, _AMOUNT_IN, _secondAmountOut, _RECIPIENT));
    vm.snapshotGasLastCall('Metarouter_v2SwapExactIn_twoHops');
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
}
