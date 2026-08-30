// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {StablePool} from 'V3/pools/StablePool.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Shared fixture for the stable pool quote suites
abstract contract StableGetAmountBase is TestHelpers {
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

    _pool = _deployPool(18, 18);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployPool(uint256 _decimals0, uint256 _decimals1) internal returns (IPool _newPool) {
    vm.mockCall(_token0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(_decimals0)));
    vm.mockCall(_token1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(uint8(_decimals1)));
    vm.mockCall(_token0, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK0'));
    vm.mockCall(_token1, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK1'));

    _newPool = IPool(address(new StablePool()));
    vm.prank(_mockFactory);
    _newPool.initialize(_token0, _token1);
    vm.clearMockedCalls();
  }

  function _seedReserves(address _target, uint256 _reserve0, uint256 _reserve1) internal {
    _set(_target, _reserve0, IPool.reserve0.selector);
    _set(_target, _reserve1, IPool.reserve1.selector);
  }

  /// @dev Mocks total fee call
  function _mockTotalFee(
    address _target,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _r0,
    uint256 _r1,
    uint256 _fee
  ) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getFee, (_target, address(this), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee, uint256(0), false)
    );
  }

  /// @dev Mocks the exact output fee call at the after fee input
  function _mockFeeForAmountIn(
    address _target,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _r0,
    uint256 _r1,
    uint256 _fee
  ) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getFeeForAmountIn, (_target, address(this), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee)
    );
  }

  /// @dev Mocks base fee call
  function _mockBaseFee(
    address _target,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _r0,
    uint256 _r1,
    uint256 _fee
  ) internal {
    _mockAndExpect(
      _mockFactory,
      abi.encodeCall(IPoolFactory.getBaseFee, (_target, address(0), _amount0In, _amount1In, _r0, _r1)),
      abi.encode(_fee)
    );
  }

  /// @dev Stable curve invariant on normalized eighteen decimal reserves
  function _stableK(uint256 _x, uint256 _y) internal pure returns (uint256) {
    uint256 _product = (_x * _y) / 1e18;
    uint256 _squares = (_x * _x) / 1e18 + (_y * _y) / 1e18;
    return (_product * _squares) / 1e18;
  }

  /// @dev Applies the quoted output to the supplied reserves and checks the invariant does not
  ///      drop
  function _assertSwapPreservesK(
    uint256 _amountIn,
    address _tokenIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _amountOut,
    uint256 _fee
  ) internal view {
    uint256 _amountInAfterFee = _amountIn - (_amountIn * _fee) / _MAX_BPS;
    (uint256 _reserve0Post, uint256 _reserve1Post) = _tokenIn == _token0
      ? (_reserve0 + _amountInAfterFee, _reserve1 - _amountOut)
      : (_reserve0 - _amountOut, _reserve1 + _amountInAfterFee);
    assertGe(_stableK(_reserve0Post, _reserve1Post), _stableK(_reserve0, _reserve1));
  }

  /// @dev Smallest input whose fee still leaves `_afterFee`
  function _grossUp(uint256 _afterFee, uint256 _fee) internal pure returns (uint256) {
    return Math.mulDiv(_MAX_BPS, _afterFee - 1, _MAX_BPS - _fee) + 1;
  }

  /// @dev Bounds the exact input domain below the point where the quartic invariant overflows
  function _boundInputs(
    uint256 _amountIn,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _fee
  ) internal pure returns (uint256, uint256, uint256, uint256) {
    _fee = bound(_fee, 0, _MAX_BPS);
    uint256 _halfRMax = Math.sqrt(Math.sqrt(type(uint256).max / 2) * 1e18) / 2;
    _reserve0 = bound(_reserve0, 1e18, _halfRMax);
    _reserve1 = bound(_reserve1, 1e18, _halfRMax);
    uint256 _minReserve = _reserve0 < _reserve1 ? _reserve0 : _reserve1;
    _amountIn = bound(_amountIn, 0, _minReserve);
    return (_amountIn, _reserve0, _reserve1, _fee);
  }
}
