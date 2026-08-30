// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IStablePool} from 'V3/interfaces/pools/IStablePool.sol';
import {StablePool} from 'V3/pools/StablePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitStablePoolMint is UnitPool {
  modifier givenThePoolCurrentTotalSupplyIsZero() {
    _;
  }

  function test_WhenTheDepositedAmountsAreNotEqual(
    uint256 _amount0,
    uint256 _amount1
  ) external givenThePoolCurrentTotalSupplyIsZero {
    // Bounds keeps normalized amounts within uint256 and Math.sqrt(_amount0 * _amount1) > MINIMUM_LIQUIDITY
    _amount0 = bound(_amount0, MINIMUM_LIQUIDITY, type(uint256).max / 1e18);
    _amount1 = bound(_amount1, MINIMUM_LIQUIDITY, Math.min(type(uint256).max / 1e18, type(uint256).max / _amount0));
    vm.assume((_amount0 * 1e18) / _decimals0 != (_amount1 * 1e18) / _decimals1);
    _mockAndExpectTokenBalance(_token0, address(_pool), _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _amount1);

    // it should revert with DepositsNotEqual
    vm.expectRevert(IStablePool.DepositsNotEqual.selector);
    _pool.mint(_recipient);
  }

  modifier whenTheDepositedAmountsAreEqual() {
    _;
  }

  function test_WhenTheKOfDepositedAmountsIsBelowOrEqualToMINIMUM_K(uint256 _amount)
    external
    givenThePoolCurrentTotalSupplyIsZero
    whenTheDepositedAmountsAreEqual
  {
    IPool _poolB = _deployPoolWithDecimals(18);

    // Stable pool with 18 decimals and cubic formula x=y=8_408_964_152_747_411 results in MINIMUM_K
    _amount = bound(_amount, MINIMUM_LIQUIDITY, 8_408_964_152_747_411);
    _mockAndExpectTokenBalance(_poolB.token0(), address(_poolB), _amount);
    _mockAndExpectTokenBalance(_poolB.token1(), address(_poolB), _amount);

    // it should revert with BelowMinimumK
    vm.expectRevert(IStablePool.BelowMinimumK.selector);
    _poolB.mint(_recipient);
  }

  modifier whenTheKOfDepositedAmountsIsAboveMINIMUM_K() {
    _;
  }

  function test_WhenTheLiquidityToMintIsBelowMINIMUM_LIQUIDITY(uint256 _amount)
    external
    givenThePoolCurrentTotalSupplyIsZero
    whenTheDepositedAmountsAreEqual
    whenTheKOfDepositedAmountsIsAboveMINIMUM_K
  {
    IPool _poolB = _deployPoolWithDecimals(0);

    // Any amount for pools with 0 decimals between [MINIMUM_LIQUIDITY, 2 * MINIMUM_LIQUIDITY - 1] will raise InsufficientLiquidityMinted error
    _amount = bound(_amount, MINIMUM_LIQUIDITY, 2 * MINIMUM_LIQUIDITY - 1);
    _mockAndExpectTokenBalance(_poolB.token0(), address(_poolB), _amount);
    _mockAndExpectTokenBalance(_poolB.token1(), address(_poolB), _amount);

    // it should revert with InsufficientLiquidityMinted
    vm.expectRevert(IPool.InsufficientLiquidityMinted.selector);
    _poolB.mint(_recipient);
  }

  function test_WhenTheLiquidityToMintIsAboveMINIMUM_LIQUIDITY(uint256 _tokens)
    external
    givenThePoolCurrentTotalSupplyIsZero
    whenTheDepositedAmountsAreEqual
    whenTheKOfDepositedAmountsIsAboveMINIMUM_K
  {
    // Bound avoids overflow in stable curve formula with current token decimals
    _tokens = bound(_tokens, 1, 1e10);
    uint256 _amount0 = _tokens * _decimals0;
    uint256 _amount1 = _tokens * _decimals1;

    _mockAndExpectTokenBalance(_token0, address(_pool), _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _amount1);

    uint256 _expectedLiquidity = Math.sqrt(_amount0 * _amount1) - MINIMUM_LIQUIDITY;

    // it should emit the Mint event
    vm.expectEmit(true, true, false, true, address(_pool));
    emit IPool.Mint(address(this), _recipient, _amount0, _amount1);
    _pool.mint(_recipient);

    // it should mint the minimum liquidity to address one
    assertEq(IERC20(address(_pool)).balanceOf(address(1)), MINIMUM_LIQUIDITY);
    // it should mint the remaining liquidity to the recipient
    assertEq(IERC20(address(_pool)).balanceOf(_recipient), _expectedLiquidity);
  }

  modifier givenThePoolCurrentTotalSupplyIsPositive() {
    _;
  }

  function test_WhenTheLiquidityToMintIsZero(
    uint256 _totalSupply,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _amount0,
    uint256 _amount1
  ) external givenThePoolCurrentTotalSupplyIsPositive {
    _totalSupply = bound(_totalSupply, 1, type(uint128).max);
    _setTotalSupply(_totalSupply);

    uint256 _ceil = type(uint128).max - 1;
    _amount0 = bound(_amount0, 0, _ceil / _totalSupply);
    _amount1 = bound(_amount1, 0, _ceil / _totalSupply);

    _reserve0 = bound(_reserve0, _amount0 * _totalSupply + 1, type(uint128).max);
    _reserve1 = bound(_reserve1, _amount1 * _totalSupply + 1, type(uint128).max);
    _setReserves(_reserve0, _reserve1);
    _mockAndExpectTokenBalance(_token0, address(_pool), _reserve0 + _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _reserve1 + _amount1);

    // it should revert with InsufficientLiquidityMinted
    vm.expectRevert(IPool.InsufficientLiquidityMinted.selector);
    _pool.mint(_recipient);
  }

  function test_WhenTheLiquidityToMintIsPositive(
    uint256 _totalSupply,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _amount0,
    uint256 _amount1
  ) external givenThePoolCurrentTotalSupplyIsPositive {
    _totalSupply = bound(_totalSupply, 1, type(uint128).max);
    _setTotalSupply(_totalSupply);

    _amount0 = bound(_amount0, 1, type(uint128).max / _totalSupply);
    _amount1 = bound(_amount1, 1, type(uint128).max / _totalSupply);

    _reserve0 = bound(_reserve0, 1, _amount0 * _totalSupply);
    _reserve1 = bound(_reserve1, 1, _amount1 * _totalSupply);
    _setReserves(_reserve0, _reserve1);

    _mockAndExpectTokenBalance(_token0, address(_pool), _reserve0 + _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _reserve1 + _amount1);

    uint256 _expectedLiquidity = Math.min((_amount0 * _totalSupply) / _reserve0, (_amount1 * _totalSupply) / _reserve1);

    // it should emit the Mint event
    vm.expectEmit(true, true, false, true, address(_pool));
    emit IPool.Mint(address(this), _recipient, _amount0, _amount1);
    _pool.mint(_recipient);

    // it should mint the proportional liquidity to the recipient
    assertEq(IERC20(address(_pool)).balanceOf(_recipient), _expectedLiquidity);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new StablePool()));
  }

  function _deployPoolWithDecimals(uint8 _decimals) internal returns (IPool _poolB) {
    address _tokenA = _mockContract('tokenStableA');
    address _tokenB = _mockContract('tokenStableB');
    (address _t0, address _t1) = _tokenA < _tokenB ? (_tokenA, _tokenB) : (_tokenB, _tokenA);
    _mockAndExpect(_t0, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(_decimals));
    _mockAndExpect(_t1, abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(_decimals));
    _mockAndExpect(_t0, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK0'));
    _mockAndExpect(_t1, abi.encodeWithSelector(IERC20Metadata.symbol.selector), abi.encode('TK1'));

    _poolB = _deployPool();
    vm.prank(_mockFactory);
    _poolB.initialize(_t0, _t1);
  }
}
