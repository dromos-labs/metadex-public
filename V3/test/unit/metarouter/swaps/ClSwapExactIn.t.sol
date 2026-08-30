// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ICLPool} from 'V3/interfaces/pools/ICLPool.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {ClSwapProbe} from 'V3-test/unit/metarouter/harnesses/ClSwapProbe.sol';
import {BaseSwaps} from 'V3-test/unit/metarouter/swaps/BaseSwaps.sol';

contract UnitSwapsClSwapExactIn is BaseSwaps {
  uint256 internal constant _AMOUNT_IN = 1000;
  uint256 internal constant _AMOUNT_OUT = 900;
  uint160 internal constant _MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
  uint160 internal constant _MAX_SQRT_RATIO_MINUS_ONE =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

  ClSwapProbe internal _probe;

  constructor() {
    _probe = new ClSwapProbe(_CL_FACTORY, _TOKEN_A, _TOKEN_B);
  }

  function test_WhenAUserPayerSelectsAProportionalSpend() external {
    IMetarouter.BalanceSpend memory _spend =
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: 1_000_000});
    bytes memory _input = _exactInputWithSpend(_singlePool(address(_probe)), _TOKEN_A, _spend, true, 0, address(0));

    // it should revert with InvalidSpendMode
    vm.expectRevert(IMetarouter.InvalidSpendMode.selector);
    _execute(Commands.CL_SWAP_EXACT_IN, _input);
  }

  function test_WhenTheRecipientIsTheZeroAddress() external {
    // it should revert with InvalidRecipient
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(new address[](0), _TOKEN_A, 0, 0, address(0)));
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_WhenThePoolPathIsEmpty() external givenTheRecipientIsValid {
    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(new address[](0), _TOKEN_A, 0, 0, _RECIPIENT));
  }

  function test_WhenAPoolIsNotRegistered() external givenTheRecipientIsValid {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(address(0)));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenAFactoryDoesNotRecognizeThePool() external givenTheRecipientIsValid {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_POOL)), abi.encode(false));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
  }

  function test_WhenAPoolReportsAnUnsupportedPoolType() external givenTheRecipientIsValid {
    // The pool-type check reverts before the token resolution, so the validated-pool mocks are set inline.
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_probe))), abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_probe))), abi.encode(true));
    _mockAndExpect(address(_probe), abi.encodeCall(ICLPool.POOL_TYPE, ()), abi.encode(bytes32('V2_VOLATILE')));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, address(_probe)));
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
  }

  modifier givenEveryPoolIsValidated() {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_probe))), abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_probe))), abi.encode(true));
    _mockAndExpect(address(_probe), abi.encodeCall(ICLPool.token0, ()), abi.encode(_TOKEN_A));
    _mockAndExpect(address(_probe), abi.encodeCall(ICLPool.token1, ()), abi.encode(_TOKEN_B));
    _;
  }

  function test_WhenTheInputTokenDoesNotBelongToThePool() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    address _unrelatedToken = makeAddr('unrelatedToken');

    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _unrelatedToken, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
  }

  function test_WhenTheResolvedInputExceedsTheSignedIntegerMaximum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    uint256 _amount = uint256(type(int256).max) + 1;
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), _amount);

    // it should revert with AmountOverflow
    vm.expectRevert(IMetarouter.AmountOverflow.selector);
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_singlePool(address(_probe)), _TOKEN_A, _amount, 0, _RECIPIENT));
  }

  function test_WhenAnotherCallbackCallerIsAlreadyArmed() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    address _armedCaller = makeAddr('armedCaller');
    _metarouter.seedExpectedCallbackCaller(_armedCaller);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), _AMOUNT_IN);

    // it should revert with CallbackNotCleared for the armed caller
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CallbackNotCleared.selector, _armedCaller));
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
  }

  function test_WhenThePoolReturnsWithoutConsumingItsCallback()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    _probe.configure(false, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), _AMOUNT_IN);

    // it should revert with CallbackNotCleared for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CallbackNotCleared.selector, address(_probe)));
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );
  }

  function test_WhenThePoolReportsAPositiveOutputDelta() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _probe.configure(true, _AMOUNT_IN, 1);
    _probe.setPositiveReturnedOutput(true);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should revert with InvalidSwapDeltas
    vm.expectRevert(IMetarouter.InvalidSwapDeltas.selector);
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, 0, _RECIPIENT));
  }

  function test_WhenTheFinalOutputIsBelowTheMinimum(
    uint256 _amountOut,
    uint256 _minimumOut
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _minimumOut = bound(_minimumOut, 1, uint256(type(int256).max));
    _amountOut = bound(_amountOut, 0, _minimumOut - 1);
    _probe.configure(true, _AMOUNT_IN, _amountOut);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should revert with TooLittleReceived
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.TooLittleReceived.selector, _minimumOut, _amountOut));
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _minimumOut, _RECIPIENT)
    );
  }

  modifier givenTheFinalOutputMeetsTheMinimum() {
    _;
  }

  function test_WhenThePayerIsTheExecutionOwner()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    // it should pay the first pool directly from the execution owner
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInputFromUser(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT - 1, _RECIPIENT)
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
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [_custodyBalance, _residual]);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should track the input token for the closure sweep
    _mockAndExpectTokenTransfer(_TOKEN_A, address(this), _residual);

    // it should pay the first pool from custody
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT - 1, _RECIPIENT)
    );
  }

  function test_WhenTheInputTokenIsTokenOne()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenBalancesTwice(_TOKEN_B, address(_metarouter), [uint256(_AMOUNT_IN), uint256(0)]);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_probe), _AMOUNT_IN);

    // it should swap toward token zero using the upper price boundary
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_B, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );

    assertFalse(_probe.lastZeroForOne());
    assertEq(_probe.lastSqrtPriceLimitX96(), _MAX_SQRT_RATIO_MINUS_ONE);
  }

  function test_WhenThePathContainsMultiplePools()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    uint256 _intermediateAmount = 950;
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _TOKEN_B, _tokenC);
    _probe.configure(true, _AMOUNT_IN, _intermediateAmount);
    _secondPool.configure(true, _intermediateAmount, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_tokenC));

    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [uint256(_AMOUNT_IN), uint256(0)]);
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_secondPool), _intermediateAmount);

    address[] memory _pools = new address[](2);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);

    // it should forward each returned output amount through custody
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_pools, _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));

    assertEq(_probe.lastRecipient(), address(_metarouter));
    assertEq(_secondPool.lastAmountSpecified(), int256(_intermediateAmount));
    assertEq(_secondPool.lastRecipient(), _RECIPIENT);
  }

  function test_WhenAUserPayerRoutesThroughMultiplePools()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    uint256 _intermediateAmount = 950;
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _TOKEN_B, _tokenC);
    _probe.configure(true, _AMOUNT_IN, _intermediateAmount);
    _secondPool.configure(true, _intermediateAmount, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_tokenC));

    // The execution owner settles only the first invoice; the second hop pays from custody with a direct transfer.
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_secondPool), _intermediateAmount);

    address[] memory _pools = new address[](2);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);

    // it should pay only the first pool from the execution owner
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInputFromUser(_pools, _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));

    assertEq(_probe.lastRecipient(), address(_metarouter));
    assertEq(_secondPool.lastAmountSpecified(), int256(_intermediateAmount));
    assertEq(_secondPool.lastRecipient(), _RECIPIENT);
  }

  function test_WhenTheHopDirectionsDiffer()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    uint256 _intermediateAmount = 950;
    // The intermediate token is the second pool's token one, so the second hop swaps one for zero.
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _tokenC, _TOKEN_B);
    _probe.configure(true, _AMOUNT_IN, _intermediateAmount);
    _secondPool.configure(true, _intermediateAmount, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_TOKEN_B));

    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [uint256(_AMOUNT_IN), uint256(0)]);
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_secondPool), _intermediateAmount);

    address[] memory _pools = new address[](2);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);

    // it should swap each hop toward its own output token
    _execute(Commands.CL_SWAP_EXACT_IN, _exactInput(_pools, _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));

    assertTrue(_probe.lastZeroForOne());
    assertEq(_probe.lastSqrtPriceLimitX96(), _MIN_SQRT_RATIO_PLUS_ONE);
    assertFalse(_secondPool.lastZeroForOne());
    assertEq(_secondPool.lastSqrtPriceLimitX96(), _MAX_SQRT_RATIO_MINUS_ONE);
    assertEq(_secondPool.lastAmountSpecified(), int256(_intermediateAmount));
    assertEq(_secondPool.lastRecipient(), _RECIPIENT);
  }

  function test_WhenTheRecipientIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [uint256(_AMOUNT_IN), uint256(0)]);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(this), _AMOUNT_OUT);

    // it should track and return the output at batch closure
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, address(_metarouter))
    );
  }

  function test_WhenTheOutputEqualsTheMinimum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenBalancesTwice(_TOKEN_A, address(_metarouter), [uint256(_AMOUNT_IN), uint256(0)]);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should complete at the exact bound
    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT)
    );

    assertEq(_probe.swapCalls(), 1);
    assertEq(_probe.lastRecipient(), _RECIPIENT);
    assertTrue(_probe.lastZeroForOne());
    assertEq(_probe.lastAmountSpecified(), int256(_AMOUNT_IN));
    assertEq(_probe.lastSqrtPriceLimitX96(), _MIN_SQRT_RATIO_PLUS_ONE);
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_clSwapExactInSingleHop()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    _execute(
      Commands.CL_SWAP_EXACT_IN,
      _exactInputFromUser(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT - 1, _RECIPIENT)
    );
    vm.snapshotGasLastCall('Metarouter_clSwapExactIn_singleHop');
  }

  function testGas_clSwapExactInTwoHops()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenTheFinalOutputMeetsTheMinimum
  {
    address _tokenC = _mockContract('tokenC');
    uint256 _intermediateAmount = 950;
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _TOKEN_B, _tokenC);
    _probe.configure(true, _AMOUNT_IN, _intermediateAmount);
    _secondPool.configure(true, _intermediateAmount, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_tokenC));
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_secondPool), _intermediateAmount);

    address[] memory _pools = new address[](2);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);

    _execute(Commands.CL_SWAP_EXACT_IN, _exactInputFromUser(_pools, _TOKEN_A, _AMOUNT_IN, _AMOUNT_OUT, _RECIPIENT));
    vm.snapshotGasLastCall('Metarouter_clSwapExactIn_twoHops');
  }
}
