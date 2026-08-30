// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitVolatilePoolBurn is UnitPool {
  function test_WhenTheAmountsToBurnAreZero(
    uint256 _totalSupply,
    uint256 _liquidity,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);
    _liquidity = bound(_liquidity, 1, _totalSupply);
    _setTotalSupply(_totalSupply);
    _setLiquidity(_liquidity);

    _balance0 = bound(_balance0, 0, (_totalSupply - 1) / _liquidity);
    _balance1 = bound(_balance1, 0, (_totalSupply - 1) / _liquidity);
    _mockAndExpectTokenBalance(_token0, address(_pool), _balance0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _balance1);

    // it should revert with InsufficientLiquidityBurned
    vm.expectRevert(IPool.InsufficientLiquidityBurned.selector);
    vm.prank(_recipient);
    _pool.burn(_recipient);
  }

  function test_WhenTheAmountsToBurnArePositive(
    uint256 _totalSupply,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _liquidity
  ) external {
    _totalSupply = bound(_totalSupply, 2, type(uint128).max);
    _reserve0 = bound(_reserve0, 1, type(uint128).max);
    _reserve1 = bound(_reserve1, 1, type(uint128).max);
    // Liquidity must produce nonzero shares on both sides: `_liquidity >= ceil(_totalSupply / _reserve)` for each
    uint256 _minLiquidity = Math.max(_ceilDiv(_totalSupply, _reserve0), _ceilDiv(_totalSupply, _reserve1));
    _liquidity = bound(_liquidity, _minLiquidity, _totalSupply);
    _setTotalSupply(_totalSupply);
    _setReserves(_reserve0, _reserve1);
    _setLiquidity(_liquidity);

    uint256 _expectedAmount0 = (_liquidity * _reserve0) / _totalSupply;
    uint256 _expectedAmount1 = (_liquidity * _reserve1) / _totalSupply;

    _mockAndExpectTokenBalancesTwice(_token0, address(_pool), [_reserve0, _reserve0 - _expectedAmount0]);
    _mockAndExpectTokenBalancesTwice(_token1, address(_pool), [_reserve1, _reserve1 - _expectedAmount1]);
    // it should transfer token zero to the recipient
    _mockAndExpectTokenTransfer(_token0, _recipient, _expectedAmount0);
    // it should transfer token one to the recipient
    _mockAndExpectTokenTransfer(_token1, _recipient, _expectedAmount1);

    // it should emit the Burn event
    vm.expectEmit(true, true, false, true, address(_pool));
    emit IPool.Burn(_recipient, _recipient, _expectedAmount0, _expectedAmount1);
    vm.prank(_recipient);
    _pool.burn(_recipient);

    // it should burn the liquidity from the pool
    assertEq(IERC20(address(_pool)).balanceOf(address(_pool)), 0);
    assertEq(IERC20(address(_pool)).totalSupply(), _totalSupply - _liquidity);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
