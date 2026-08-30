// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitVolatilePoolMint is UnitPool {
  modifier givenThePoolCurrentTotalSupplyIsZero() {
    _;
  }

  function test_WhenTheLiquidityToMintIsBelowMINIMUM_LIQUIDITY(uint256 _amount)
    external
    givenThePoolCurrentTotalSupplyIsZero
  {
    _amount = bound(_amount, MINIMUM_LIQUIDITY, 2 * MINIMUM_LIQUIDITY - 1);
    _mockAndExpectTokenBalance(_token0, address(_pool), _amount);
    _mockAndExpectTokenBalance(_token1, address(_pool), _amount);

    // it should revert with InsufficientLiquidityMinted
    vm.expectRevert(IPool.InsufficientLiquidityMinted.selector);
    _pool.mint(_recipient);
  }

  function test_WhenTheLiquidityToMintIsAboveMINIMUM_LIQUIDITY(
    uint256 _amount0,
    uint256 _amount1
  ) external givenThePoolCurrentTotalSupplyIsZero {
    _amount0 = bound(_amount0, 2 * MINIMUM_LIQUIDITY, type(uint256).max);
    _amount1 = type(uint256).max / _amount0;
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
    return IPool(address(new VolatilePool()));
  }
}
