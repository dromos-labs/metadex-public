// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IPoolCallee} from 'V3/interfaces/pools/IPoolCallee.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {StablePool} from 'V3/pools/StablePool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

abstract contract UnitPoolSwap is UnitPool {
  function test_WhenTheFactoryIsPaused() external {
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.isPaused, ()), abi.encode(true));

    // it should revert with IsPaused
    vm.expectRevert(IPool.IsPaused.selector);
    _pool.swap(0, 0, _recipient, '');
  }

  modifier whenTheFactoryIsNotPaused() {
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.isPaused, ()), abi.encode(false));
    _;
  }

  function test_WhenBothOutputAmountsEqZero() external whenTheFactoryIsNotPaused {
    // it should revert with InsufficientOutputAmount
    vm.expectRevert(IPool.InsufficientOutputAmount.selector);
    _pool.swap(0, 0, _recipient, '');
  }

  modifier whenAnOutputAmountIsGtZero() {
    _;
  }

  function test_WhenAnOutputAmountIsGteItsReserve(
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _amount0Out,
    uint256 _amount1Out,
    bool _amount0OutExceeds
  ) external whenTheFactoryIsNotPaused whenAnOutputAmountIsGtZero {
    _reserve0 = bound(_reserve0, 1, type(uint256).max);
    _reserve1 = bound(_reserve1, 1, type(uint256).max);
    (_amount0Out, _amount1Out) = _amount0OutExceeds
      ? (bound(_amount0Out, _reserve0, type(uint256).max), _amount1Out)
      : (_amount0Out, bound(_amount1Out, _reserve1, type(uint256).max));

    _setReserves(_reserve0, _reserve1);

    // it should revert with InsufficientLiquidity
    vm.expectRevert(IPool.InsufficientLiquidity.selector);
    _pool.swap(_amount0Out, _amount1Out, _recipient, '');
  }

  modifier whenTheOutputAmountsAreLtTheReserves() {
    _;
  }

  function test_WhenTheRecipientIsAPoolToken(bool _toIsToken0)
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
  {
    _setReserves(2, 2);

    // it should revert with InvalidTo
    vm.expectRevert(IPool.InvalidTo.selector);
    _pool.swap(1, 1, _toIsToken0 ? _token0 : _token1, '');
  }

  modifier whenTheRecipientIsNotAPoolToken() {
    _;
  }

  function test_WhenTheDataPayloadIsNotEmpty(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount0In,
    uint256 _fee,
    uint256 _mevFee,
    bytes calldata _data
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
  {
    vm.assume(_data.length > 0);
    address _callee = _mockContract('poolCallee');
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount0In,
      fee: _fee,
      mevFee: _mevFee,
      zeroForOne: true,
      toxic: false,
      to: _callee
    });
    (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData) = _arrangeSwap(_swapCase);
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.recordPoolTape, (_expectedPoolTapeData)), '');

    // it should call the hook on the recipient with the output amounts
    _mockAndExpect(_callee, abi.encodeCall(IPoolCallee.hook, (address(this), 0, _amountOut, _data)), '');
    _pool.swap(0, _amountOut, _callee, _data);
  }

  modifier whenTheDataPayloadIsEmpty() {
    _;
  }

  function test_WhenTheInputAmountsEqZero(bool _outputIsToken0)
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
  {
    (uint256 _amount0Out, uint256 _amount1Out) = (1, 1);
    (uint256 _reserve0, uint256 _reserve1) = (2, 2);

    _setReserves(_reserve0, _reserve0);
    _mockAndExpectTokenTransfer(
      _outputIsToken0 ? _token0 : _token1, _recipient, _outputIsToken0 ? _amount0Out : _amount1Out
    );
    _mockAndExpectTokenBalance(_token0, address(_pool), _reserve0 - _amount0Out);
    _mockAndExpectTokenBalance(_token1, address(_pool), _reserve1 - _amount1Out);

    // it should revert with InsufficientInputAmount
    vm.expectRevert(IPool.InsufficientInputAmount.selector);
    _pool.swap(_amount0Out, _amount1Out, _recipient, '');
  }

  modifier whenAnInputAmountIsGtZero() {
    _;
  }

  function test_WhenTheInvariantDecreasesAfterTheSwap(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount0In,
    uint256 _amount1Out,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount0In,
      fee: 0,
      mevFee: 0,
      zeroForOne: true,
      toxic: false,
      to: _to
    });
    uint256 _quotedAmountOut = _arrangeZeroFeeSwap(_swapCase);
    _amount1Out = bound(_amount1Out, _quotedAmountOut + 1, _reserve1 - 1);

    _mockAndExpectTokenBalancesTwice(
      _token0, address(_pool), [_reserve0 + _swapCase.amountIn, _reserve0 + _swapCase.amountIn]
    );
    _mockAndExpectTokenBalancesTwice(_token1, address(_pool), [_reserve1 - _amount1Out, _reserve1 - _amount1Out]);
    _mockAndExpectTokenTransfer(_token1, _to, _amount1Out);

    // it should revert with K
    vm.expectRevert(IPool.K.selector);
    _pool.swap(0, _amount1Out, _to, '');
  }

  modifier whenTheInvariantIsPreserved() {
    _;
  }

  modifier whenSwapIsZeroForOne() {
    _;
  }

  function test_WhenSwapIsZeroForOne(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount0In,
    uint256 _fee,
    uint256 _mevFee,
    uint256 _totalSupply,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsZeroForOne
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount0In,
      fee: _fee,
      mevFee: _mevFee,
      zeroForOne: true,
      toxic: false,
      to: _to
    });
    // it should transfer the token1 output to the recipient
    // it should transfer the token0 fee to the pool fees contract
    (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData) = _arrangeSwap(_swapCase);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);
    _setTotalSupply(_totalSupply);

    // it records the swap data to the pool tape via the factory
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.recordPoolTape, (_expectedPoolTapeData)), '');
    // it emits the Fees event
    vm.expectEmit();
    emit IPool.Fees(address(this), uint256(_expectedPoolTapeData.fee0), 0);
    // it emits the Swap event
    vm.expectEmit();
    emit IPool.Swap(address(this), _to, _swapCase.amountIn, 0, 0, _amountOut);
    _pool.swap(0, _amountOut, _to, '');

    // it accrues the fee ratio on the token0 fee index
    assertEq(_pool.index0(), (uint256(_expectedPoolTapeData.fee0) * 1e18) / _totalSupply);
    // it updates the reserves to the post swap balances
    assertEq(_pool.reserve0(), _swapCase.reserve0 + _swapCase.amountIn - uint256(_expectedPoolTapeData.fee0));
    assertEq(_pool.reserve1(), _swapCase.reserve1 - _amountOut);
  }

  function test_WhenTheFactoryReportsTheZeroForOneSwapAsToxic(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount0In,
    uint256 _fee,
    uint256 _mevFee,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsZeroForOne
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount0In,
      fee: _fee,
      mevFee: _mevFee,
      zeroForOne: true,
      toxic: true,
      to: _to
    });
    (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData) = _arrangeSwap(_swapCase);

    // it records the mev volumes on the pool tape
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.recordPoolTape, (_expectedPoolTapeData)), '');
    _pool.swap(0, _amountOut, _to, '');
  }

  function test_WhenTheZeroForOneSwapFeeEqZero(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount0In,
    uint256 _amount1Out,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsZeroForOne
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount0In,
      fee: 0,
      mevFee: 0,
      zeroForOne: true,
      toxic: false,
      to: _to
    });
    uint256 _fairAmountOut = _arrangeZeroFeeSwap(_swapCase);
    _amount1Out = bound(_amount1Out, 1, _fairAmountOut);

    _mockAndExpectTokenBalancesTwice(
      _token0, address(_pool), [_reserve0 + _swapCase.amountIn, _reserve0 + _swapCase.amountIn]
    );
    _mockAndExpectTokenBalancesTwice(_token1, address(_pool), [_reserve1 - _amount1Out, _reserve1 - _amount1Out]);
    _mockAndExpectTokenTransfer(_token1, _to, _amount1Out);
    vm.mockCall(_mockFactory, abi.encodeWithSelector(IPoolFactory.recordPoolTape.selector), '');

    // it should not transfer fees to the pool fees contract
    vm.expectCall(_token0, abi.encodeWithSelector(IERC20.transfer.selector), 0);
    _pool.swap(0, _amount1Out, _to, '');

    // it should not increase the token0 fee index
    assertEq(_pool.index0(), 0);
  }

  modifier whenSwapIsOneForZero() {
    _;
  }

  function test_WhenSwapIsOneForZero(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount1In,
    uint256 _fee,
    uint256 _mevFee,
    uint256 _totalSupply,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsOneForZero
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount1In,
      fee: _fee,
      mevFee: _mevFee,
      zeroForOne: false,
      toxic: false,
      to: _to
    });
    // it should transfer the token0 output to the recipient
    // it should transfer the token1 fee to the pool fees contract
    (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData) = _arrangeSwap(_swapCase);
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);
    _setTotalSupply(_totalSupply);

    // it records the swap data to the pool tape via the factory
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.recordPoolTape, (_expectedPoolTapeData)), '');
    // it emits the Fees event
    vm.expectEmit();
    emit IPool.Fees(address(this), 0, uint256(_expectedPoolTapeData.fee1));
    // it emits the Swap event
    vm.expectEmit();
    emit IPool.Swap(address(this), _to, 0, _swapCase.amountIn, _amountOut, 0);
    _pool.swap(_amountOut, 0, _to, '');

    // it accrues the fee ratio on the token1 fee index
    assertEq(_pool.index1(), (uint256(_expectedPoolTapeData.fee1) * 1e18) / _totalSupply);
    // it updates the reserves to the post swap balances
    assertEq(_pool.reserve0(), _swapCase.reserve0 - _amountOut);
    assertEq(_pool.reserve1(), _swapCase.reserve1 + _swapCase.amountIn - uint256(_expectedPoolTapeData.fee1));
  }

  function test_WhenTheFactoryReportsTheOneForZeroSwapAsToxic(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount1In,
    uint256 _fee,
    uint256 _mevFee,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsOneForZero
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount1In,
      fee: _fee,
      mevFee: _mevFee,
      zeroForOne: false,
      toxic: true,
      to: _to
    });
    (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData) = _arrangeSwap(_swapCase);

    // it records the mev volumes on the pool tape
    _mockAndExpect(_mockFactory, abi.encodeCall(IPoolFactory.recordPoolTape, (_expectedPoolTapeData)), '');
    _pool.swap(_amountOut, 0, _to, '');
  }

  function test_WhenTheOneForZeroSwapFeeEqZero(
    uint256 _normReserve0,
    uint256 _normReserve1,
    uint256 _amount1In,
    uint256 _amount0Out,
    address _to
  )
    external
    whenTheFactoryIsNotPaused
    whenAnOutputAmountIsGtZero
    whenTheOutputAmountsAreLtTheReserves
    whenTheRecipientIsNotAPoolToken
    whenTheDataPayloadIsEmpty
    whenAnInputAmountIsGtZero
    whenTheInvariantIsPreserved
    whenSwapIsOneForZero
  {
    (uint256 _reserve0, uint256 _reserve1) = _swapReserves(_normReserve0, _normReserve1);
    SwapCase memory _swapCase = SwapCase({
      reserve0: _reserve0,
      reserve1: _reserve1,
      amountIn: _amount1In,
      fee: 0,
      mevFee: 0,
      zeroForOne: false,
      toxic: false,
      to: _to
    });
    uint256 _fairAmountOut = _arrangeZeroFeeSwap(_swapCase);
    _amount0Out = bound(_amount0Out, 1, _fairAmountOut);

    _mockAndExpectTokenBalancesTwice(
      _token1, address(_pool), [_reserve1 + _swapCase.amountIn, _reserve1 + _swapCase.amountIn]
    );
    _mockAndExpectTokenBalancesTwice(_token0, address(_pool), [_reserve0 - _amount0Out, _reserve0 - _amount0Out]);
    _mockAndExpectTokenTransfer(_token0, _to, _amount0Out);
    vm.mockCall(_mockFactory, abi.encodeWithSelector(IPoolFactory.recordPoolTape.selector), '');

    // it should not transfer fees to the pool fees contract
    vm.expectCall(_token1, abi.encodeWithSelector(IERC20.transfer.selector), 0);
    _pool.swap(_amount0Out, 0, _to, '');

    // it should not increase the token1 fee index
    assertEq(_pool.index1(), 0);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  struct SwapCase {
    uint256 reserve0;
    uint256 reserve1;
    uint256 amountIn;
    uint256 fee;
    uint256 mevFee;
    bool zeroForOne;
    bool toxic;
    address to;
  }

  /// @notice Sets up a valid swap with bounded amountIn, fee and mevFee
  /// @dev Mocks calls to fee module, token balances and transfers
  /// @return _amountOut quoted amount out
  /// @return _expectedPoolTapeData data that will be recorded in the PoolTape. request is not mocked in this function
  function _arrangeSwap(SwapCase memory _swapCase)
    internal
    returns (uint256 _amountOut, IPoolTape.PoolTapeData memory _expectedPoolTapeData)
  {
    vm.assume(_swapCase.to != _token0 && _swapCase.to != _token1);
    bool _zeroForOne = _swapCase.zeroForOne;
    bool _toxic = _swapCase.toxic;
    (address _tokenIn, address _tokenOut) = _zeroForOne ? (_token0, _token1) : (_token1, _token0);
    (uint256 _reserveIn, uint256 _reserveOut) =
      _zeroForOne ? (_swapCase.reserve0, _swapCase.reserve1) : (_swapCase.reserve1, _swapCase.reserve0);
    _swapCase.amountIn = bound(_swapCase.amountIn, _reserveIn / 100, _reserveIn);
    _swapCase.fee = bound(_swapCase.fee, 1, 1000);
    _swapCase.mevFee = bound(_swapCase.mevFee, 0, _swapCase.fee);

    _setTotalSupply(1e18);
    _setReserves(_swapCase.reserve0, _swapCase.reserve1);

    _mockFeeCalls(_swapCase);

    uint256 _feeAmount = (_swapCase.amountIn * _swapCase.fee) / 10_000;
    _amountOut = _pool.getAmountOut(_swapCase.amountIn, _tokenIn);
    assertGe(_amountOut, 1);
    assertLt(_amountOut, _reserveOut);

    _mockAndExpectTokenBalancesTwice(
      _tokenIn, address(_pool), [_reserveIn + _swapCase.amountIn, _reserveIn + _swapCase.amountIn - _feeAmount]
    );
    _mockAndExpectTokenBalancesTwice(_tokenOut, address(_pool), [_reserveOut - _amountOut, _reserveOut - _amountOut]);

    _mockAndExpectTokenTransfer(_tokenOut, _swapCase.to, _amountOut);
    _mockAndExpectTokenTransfer(_tokenIn, _pool.poolFees(), _feeAmount);

    uint256 _mevFeeAmount = (_swapCase.amountIn * _swapCase.mevFee) / 10_000;
    (uint128 _volumeIn, uint128 _volumeOut) = (uint128(_swapCase.amountIn), uint128(_amountOut));
    _expectedPoolTapeData = IPoolTape.PoolTapeData({
      fee0: _zeroForOne ? uint128(_feeAmount) : 0,
      fee1: _zeroForOne ? 0 : uint128(_feeAmount),
      volume0: _zeroForOne ? _volumeIn : _volumeOut,
      volume1: _zeroForOne ? _volumeOut : _volumeIn,
      mevVolume0: _toxic ? (_zeroForOne ? _volumeIn : _volumeOut) : 0,
      mevVolume1: _toxic ? (_zeroForOne ? _volumeOut : _volumeIn) : 0,
      mevFee0: _zeroForOne ? uint128(_mevFeeAmount) : 0,
      mevFee1: _zeroForOne ? 0 : uint128(_mevFeeAmount)
    });
  }

  /// @dev Mocks the factory fee calls
  function _mockFeeCalls(SwapCase memory _swapCase) internal {
    (uint256 _amount0In, uint256 _amount1In) =
      _swapCase.zeroForOne ? (_swapCase.amountIn, uint256(0)) : (uint256(0), _swapCase.amountIn);
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(
        IPoolFactory.getBaseFee,
        (address(_pool), address(0), _amount0In, _amount1In, _swapCase.reserve0, _swapCase.reserve1)
      ),
      abi.encode(_swapCase.fee)
    );
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(
        IPoolFactory.getFee,
        (address(_pool), address(this), _amount0In, _amount1In, _swapCase.reserve0, _swapCase.reserve1)
      ),
      abi.encode(_swapCase.fee, _swapCase.mevFee, _swapCase.toxic)
    );
  }

  /// @notice Setup a valid swap with zero fees
  /// @return _quotedAmountOut quoted amountOut
  function _arrangeZeroFeeSwap(SwapCase memory _swapCase) internal returns (uint256 _quotedAmountOut) {
    vm.assume(_swapCase.to != _token0 && _swapCase.to != _token1);
    (address _tokenIn,) = _swapCase.zeroForOne ? (_token0, _token1) : (_token1, _token0);
    (uint256 _reserveIn, uint256 _reserveOut) =
      _swapCase.zeroForOne ? (_swapCase.reserve0, _swapCase.reserve1) : (_swapCase.reserve1, _swapCase.reserve0);
    _swapCase.amountIn = bound(_swapCase.amountIn, _reserveIn / 100, _reserveIn);
    _swapCase.fee = 0;
    _swapCase.mevFee = 0;

    _setTotalSupply(1e18);
    _setReserves(_swapCase.reserve0, _swapCase.reserve1);
    _mockFeeCalls(_swapCase);

    _quotedAmountOut = _pool.getAmountOut(_swapCase.amountIn, _tokenIn);
    assertGe(_quotedAmountOut, 1);
    assertLt(_quotedAmountOut, _reserveOut);
  }

  /// @dev Curve-specific reserve setup.
  function _swapReserves(
    uint256 _normReserve0,
    uint256 _normReserve1
  ) internal view virtual returns (uint256 _reserve0, uint256 _reserve1);
}

contract UnitVolatilePoolSwap is UnitPoolSwap {
  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }

  function _swapReserves(
    uint256 _normReserve0,
    uint256 _normReserve1
  ) internal view override returns (uint256 _reserve0, uint256 _reserve1) {
    _reserve0 = (bound(_normReserve0, 1e18, type(uint128).max) * _decimals0) / 1e18;
    _reserve1 = (bound(_normReserve1, 1e18, type(uint128).max) * _decimals1) / 1e18;
  }
}

contract UnitStablePoolSwap is UnitPoolSwap {
  function _deployPool() internal override returns (IPool) {
    return IPool(address(new StablePool()));
  }

  function _swapReserves(
    uint256 _normReserve0,
    uint256 _normReserve1
  ) internal view override returns (uint256 _reserve0, uint256 _reserve1) {
    _reserve0 = (bound(_normReserve0, 1e18, 1e28) * _decimals0) / 1e18;
    _reserve1 = (bound(_normReserve1, 1e18, 1e28) * _decimals1) / 1e18;
  }
}
