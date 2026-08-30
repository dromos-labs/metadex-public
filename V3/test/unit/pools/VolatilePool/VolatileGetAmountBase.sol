// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Shared fixture for the volatile pool quote suites.
abstract contract VolatileGetAmountBase is TestHelpers {
  uint256 internal constant _MAX_BPS = 10_000;

  IPool internal _pool;
  address internal _token0;
  address internal _token1;
  address internal _mockFactory = _mockContract('factory');

  function setUp() public virtual {
    address _tokenA = _mockContract('tokenA');
    address _tokenB = _mockContract('tokenB');

    bool _aIsToken0 = _tokenA < _tokenB;
    _token0 = _aIsToken0 ? _tokenA : _tokenB;
    _token1 = _aIsToken0 ? _tokenB : _tokenA;

    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(18)));
    _mockAndExpect(_token0, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK0'));
    _mockAndExpect(_token1, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK1'));

    _pool = IPool(address(new VolatilePool()));
    vm.prank(_mockFactory);
    _pool.initialize(_token0, _token1);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _seedReserves(uint256 _reserve0, uint256 _reserve1) internal {
    _set(address(_pool), _reserve0, IPool.reserve0.selector);
    _set(address(_pool), _reserve1, IPool.reserve1.selector);
  }

  /// @dev Mocks total fee call
  function _mockTotalFee(uint256 _amount0In, uint256 _amount1In, uint256 _r0, uint256 _r1, uint256 _fee) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getFee, (address(_pool), address(this), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee, uint256(0), false)
    );
  }

  /// @dev Mocks the exact output fee call at the after fee input
  function _mockFeeForAmountIn(
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _r0,
    uint256 _r1,
    uint256 _fee
  ) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getFeeForAmountIn, (address(_pool), address(this), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee)
    );
  }

  /// @dev Mock base fee call
  function _mockBaseFee(uint256 _amount0In, uint256 _amount1In, uint256 _r0, uint256 _r1, uint256 _fee) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getBaseFee, (address(_pool), address(0), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee)
    );
  }

  /// @dev Constant product output for a gross input without the fees
  function _expectedOut(
    uint256 _amountIn,
    address _tokenIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee
  ) internal view returns (uint256) {
    uint256 _amountInAfterFee = _amountIn - (_amountIn * _fee) / _MAX_BPS;
    return _tokenIn == _token0
      ? (_amountInAfterFee * _reserve1) / (_reserve0 + _amountInAfterFee)
      : (_amountInAfterFee * _reserve0) / (_reserve1 + _amountInAfterFee);
  }

  /// @dev Constant product input for a requested output, before the fee
  function _expectedIn(uint256 _amountOut, uint256 _reserveIn, uint256 _reserveOut) internal pure returns (uint256) {
    return Math.mulDiv(_reserveIn, _amountOut, _reserveOut - _amountOut, Math.Rounding.Ceil);
  }

  /// @dev Smallest input whose fee still leaves `_afterFee`
  function _grossUp(uint256 _afterFee, uint256 _fee) internal pure returns (uint256) {
    return Math.mulDiv(_MAX_BPS, _afterFee - 1, _MAX_BPS - _fee) + 1;
  }

  /// @dev Bounds the exact input domain while avoiding overflows
  function _boundInputs(
    uint256 _amountIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee
  ) internal pure returns (uint256, uint256, uint256, uint256) {
    _fee = bound(_fee, 0, _MAX_BPS);
    _reserve0 = bound(_reserve0, 1, type(uint128).max);
    _reserve1 = bound(_reserve1, 1, type(uint128).max);
    uint256 _maxReserve = _reserve0 > _reserve1 ? _reserve0 : _reserve1;
    uint256 _maxByReserveMul = type(uint256).max / _maxReserve;
    uint256 _maxByFee = _fee == 0 ? type(uint256).max : type(uint256).max / _fee;
    uint256 _maxByReserveAdd = type(uint256).max - _maxReserve;
    uint256 _maxAmountIn = _maxByReserveMul < _maxByFee ? _maxByReserveMul : _maxByFee;
    if (_maxByReserveAdd < _maxAmountIn) _maxAmountIn = _maxByReserveAdd;
    _amountIn = bound(_amountIn, 0, _maxAmountIn);
    return (_amountIn, _reserve0, _reserve1, _fee);
  }
}
