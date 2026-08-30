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

contract UnitSwapsClSwapExactOut is BaseSwaps {
  uint256 internal constant _AMOUNT_IN = 1000;
  uint256 internal constant _AMOUNT_OUT = 900;
  uint160 internal constant _MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
  uint160 internal constant _MAX_SQRT_RATIO_MINUS_ONE =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

  ClSwapProbe internal _probe;

  constructor() {
    _probe = new ClSwapProbe(_CL_FACTORY, _TOKEN_A, _TOKEN_B);
  }

  function test_WhenTheRecipientIsTheZeroAddress() external {
    // it should revert with InvalidRecipient
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _execute(Commands.CL_SWAP_EXACT_OUT, _exactOutput(new address[](0), _TOKEN_A, 0, 0, address(0)));
  }

  modifier givenTheRecipientIsValid() {
    _;
  }

  function test_WhenThePoolPathIsEmpty() external givenTheRecipientIsValid {
    // it should revert with InvalidPath
    vm.expectRevert(IMetarouter.InvalidPath.selector);
    _execute(Commands.CL_SWAP_EXACT_OUT, _exactOutput(new address[](0), _TOKEN_A, 0, 0, _RECIPIENT));
  }

  function test_WhenAPoolIsNotRegistered() external givenTheRecipientIsValid {
    _mockAndExpect(_FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(address(0)));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(
      Commands.CL_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenAFactoryDoesNotRecognizeThePool() external givenTheRecipientIsValid {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.targetToFactory, (_POOL)), abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (_POOL)), abi.encode(false));

    // it should revert with InvalidPool for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPool.selector, _POOL));
    _execute(
      Commands.CL_SWAP_EXACT_OUT, _exactOutput(_singlePool(_POOL), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
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
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
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
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _unrelatedToken, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenTheRequestedOutputExceedsTheSignedIntegerMaximum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    uint256 _amount = uint256(type(int256).max) + 1;

    // it should revert with AmountOverflow
    vm.expectRevert(IMetarouter.AmountOverflow.selector);
    _execute(
      Commands.CL_SWAP_EXACT_OUT, _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _amount, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenAnotherCallbackCallerIsAlreadyArmed() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    address _armedCaller = makeAddr('armedCaller');
    _metarouter.seedExpectedCallbackCaller(_armedCaller);

    // it should revert with CallbackNotCleared for the armed caller
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CallbackNotCleared.selector, _armedCaller));
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenThePoolReturnsWithoutConsumingItsCallback()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
  {
    _probe.configure(false, _AMOUNT_IN, _AMOUNT_OUT);

    // it should revert with CallbackNotCleared for the pool
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CallbackNotCleared.selector, address(_probe)));
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenThePoolRequestsMoreThanTheMaximumInput(
    uint256 _requested,
    uint256 _maximum
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _requested = bound(_requested, 1, uint256(type(int256).max));
    _maximum = bound(_maximum, 0, _requested - 1);
    _probe.configure(true, _requested, _AMOUNT_OUT);

    // it should revert with TooMuchRequested
    vm.expectRevert(IMetarouter.TooMuchRequested.selector);
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _maximum, _RECIPIENT)
    );
  }

  function test_WhenThePoolDeliversLessThanTheRequestedOutput(
    uint256 _requested,
    uint256 _delivered
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _requested = bound(_requested, 1, uint256(type(int256).max));
    _delivered = bound(_delivered, 0, _requested - 1);
    _probe.configure(true, _AMOUNT_IN, _delivered);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should revert with InvalidAmountOut
    vm.expectRevert(IMetarouter.InvalidAmountOut.selector);
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _requested, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenThePoolDeliversMoreThanTheRequestedOutput(
    uint256 _requested,
    uint256 _delivered
  ) external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _requested = bound(_requested, 0, uint256(type(int256).max) - 1);
    _delivered = bound(_delivered, _requested + 1, uint256(type(int256).max));
    _probe.configure(true, _AMOUNT_IN, _delivered);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should revert with InvalidAmountOut
    vm.expectRevert(IMetarouter.InvalidAmountOut.selector);
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _requested, _AMOUNT_IN, _RECIPIENT)
    );
  }

  function test_WhenThePoolReportsAPositiveOutputDelta() external givenTheRecipientIsValid givenEveryPoolIsValidated {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _probe.setPositiveReturnedOutput(true);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);

    // it should revert with InvalidAmountOut
    vm.expectRevert(IMetarouter.InvalidAmountOut.selector);
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );
  }

  modifier givenThePoolDeliversTheRequestedOutput() {
    _;
  }

  function test_WhenThePayerIsTheExecutionOwner()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    // it should pay the first pool invoice directly from the execution owner
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN + 1, _RECIPIENT)
    );
  }

  function test_WhenThePayerIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    // it should track the input token for the closure sweep
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    // it should pay the first pool invoice from custody
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN + 1, _RECIPIENT)
    );
  }

  function test_WhenTheInputTokenIsTokenOne()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), 0);

    // it should swap toward token zero using the upper price boundary
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_B, _AMOUNT_OUT, _AMOUNT_IN + 1, _RECIPIENT)
    );

    assertFalse(_probe.lastZeroForOne());
    assertEq(_probe.lastSqrtPriceLimitX96(), _MAX_SQRT_RATIO_MINUS_ONE);
  }

  function test_WhenThePathContainsMultiplePools()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
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

    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    address[] memory _pools = new address[](2);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);

    // it should settle each invoice by recursing through the callbacks
    _execute(Commands.CL_SWAP_EXACT_OUT, _exactOutput(_pools, _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT));

    assertEq(_secondPool.lastRecipient(), _RECIPIENT);
    assertEq(_secondPool.lastAmountSpecified(), -int256(_AMOUNT_OUT));
    assertEq(_probe.lastRecipient(), address(_secondPool));
    assertEq(_probe.lastAmountSpecified(), -int256(_intermediateAmount));
    assertEq(_probe.swapCalls(), 1);
    assertEq(_secondPool.swapCalls(), 1);
  }

  function test_WhenAUserPayerRoutesThroughThreePoolsWithMixedDirections()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    address _tokenC = _mockContract('tokenC');
    address _tokenD = _mockContract('tokenD');
    uint256 _secondInvoice = 950;
    uint256 _thirdInvoice = 970;
    // The intermediate token is the second pool's token one, so the second hop swaps one for zero.
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _tokenC, _TOKEN_B);
    ClSwapProbe _thirdPool = new ClSwapProbe(_CL_FACTORY, _tokenC, _tokenD);
    _probe.configure(true, _AMOUNT_IN, _secondInvoice);
    _secondPool.configure(true, _secondInvoice, _thirdInvoice);
    _thirdPool.configure(true, _thirdInvoice, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_thirdPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_thirdPool))), abi.encode(true));
    _mockAndExpect(address(_thirdPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(address(_thirdPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_tokenD));

    // it should pay the first pool invoice directly from the execution owner
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    address[] memory _pools = new address[](3);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);
    _pools[2] = address(_thirdPool);

    _execute(Commands.CL_SWAP_EXACT_OUT, _exactOutputFromUser(_pools, _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT));

    // it should index each hop pool and direction from the route
    assertEq(_thirdPool.swapCalls(), 1);
    assertEq(_thirdPool.lastRecipient(), _RECIPIENT);
    assertEq(_thirdPool.lastAmountSpecified(), -int256(_AMOUNT_OUT));
    assertTrue(_thirdPool.lastZeroForOne());
    assertEq(_thirdPool.lastSqrtPriceLimitX96(), _MIN_SQRT_RATIO_PLUS_ONE);
    assertEq(_secondPool.swapCalls(), 1);
    assertEq(_secondPool.lastRecipient(), address(_thirdPool));
    assertEq(_secondPool.lastAmountSpecified(), -int256(_thirdInvoice));
    assertFalse(_secondPool.lastZeroForOne());
    assertEq(_secondPool.lastSqrtPriceLimitX96(), _MAX_SQRT_RATIO_MINUS_ONE);
    assertEq(_probe.swapCalls(), 1);
    assertEq(_probe.lastRecipient(), address(_secondPool));
    assertEq(_probe.lastAmountSpecified(), -int256(_secondInvoice));
    assertTrue(_probe.lastZeroForOne());
  }

  function test_WhenTheRecipientIsTheExecutionAddress()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);
    _mockAndExpectTokenBalance(_TOKEN_B, address(_metarouter), _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_B, address(this), _AMOUNT_OUT);

    // it should track and return the output at batch closure
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, address(_metarouter))
    );
  }

  function test_WhenTheRequestedInputEqualsTheMaximum()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpectTokenTransfer(_TOKEN_A, address(_probe), _AMOUNT_IN);
    _mockAndExpectTokenBalance(_TOKEN_A, address(_metarouter), 0);

    // it should complete at the exact bound
    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutput(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT)
    );

    assertEq(_probe.swapCalls(), 1);
    assertEq(_probe.lastRecipient(), _RECIPIENT);
    assertTrue(_probe.lastZeroForOne());
    assertEq(_probe.lastAmountSpecified(), -int256(_AMOUNT_OUT));
    assertEq(_probe.lastSqrtPriceLimitX96(), _MIN_SQRT_RATIO_PLUS_ONE);
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_clSwapExactOutSingleHop()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    _probe.configure(true, _AMOUNT_IN, _AMOUNT_OUT);
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    _execute(
      Commands.CL_SWAP_EXACT_OUT,
      _exactOutputFromUser(_singlePool(address(_probe)), _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN + 1, _RECIPIENT)
    );
    vm.snapshotGasLastCall('Metarouter_clSwapExactOut_singleHop');
  }

  function testGas_clSwapExactOutThreeHops()
    external
    givenTheRecipientIsValid
    givenEveryPoolIsValidated
    givenThePoolDeliversTheRequestedOutput
  {
    address _tokenC = _mockContract('tokenC');
    address _tokenD = _mockContract('tokenD');
    uint256 _secondInvoice = 950;
    uint256 _thirdInvoice = 970;
    ClSwapProbe _secondPool = new ClSwapProbe(_CL_FACTORY, _tokenC, _TOKEN_B);
    ClSwapProbe _thirdPool = new ClSwapProbe(_CL_FACTORY, _tokenC, _tokenD);
    _probe.configure(true, _AMOUNT_IN, _secondInvoice);
    _secondPool.configure(true, _secondInvoice, _thirdInvoice);
    _thirdPool.configure(true, _thirdInvoice, _AMOUNT_OUT);

    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_secondPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_secondPool))), abi.encode(true));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(address(_secondPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_TOKEN_B));
    _mockAndExpect(
      _FACTORY_REGISTRY,
      abi.encodeCall(IFactoryRegistry.targetToFactory, (address(_thirdPool))),
      abi.encode(_CL_FACTORY)
    );
    _mockAndExpect(_CL_FACTORY, abi.encodeCall(IPoolFactory.isPool, (address(_thirdPool))), abi.encode(true));
    _mockAndExpect(address(_thirdPool), abi.encodeCall(ICLPool.token0, ()), abi.encode(_tokenC));
    _mockAndExpect(address(_thirdPool), abi.encodeCall(ICLPool.token1, ()), abi.encode(_tokenD));
    _mockAndExpect(
      _TOKEN_A, abi.encodeCall(IERC20.transferFrom, (address(this), address(_probe), _AMOUNT_IN)), abi.encode(true)
    );

    address[] memory _pools = new address[](3);
    _pools[0] = address(_probe);
    _pools[1] = address(_secondPool);
    _pools[2] = address(_thirdPool);

    _execute(Commands.CL_SWAP_EXACT_OUT, _exactOutputFromUser(_pools, _TOKEN_A, _AMOUNT_OUT, _AMOUNT_IN, _RECIPIENT));
    vm.snapshotGasLastCall('Metarouter_clSwapExactOut_threeHops');
  }
}
