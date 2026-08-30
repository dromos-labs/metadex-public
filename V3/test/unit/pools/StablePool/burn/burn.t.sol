// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IStablePool} from 'V3/interfaces/pools/IStablePool.sol';
import {StablePool} from 'V3/pools/StablePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitStablePoolBurn is UnitPool {
  function test_WhenTheAmountsToBurnAreZero(
    uint256 _totalSupply,
    uint256 _liquidity,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    _liquidity = bound(_liquidity, 1, type(uint256).max);
    _setLiquidity(_liquidity);

    _balance0 = bound(_balance0, 0, (type(uint256).max - 1) / _liquidity);
    _balance1 = bound(_balance1, 0, (type(uint256).max - 1) / _liquidity);

    uint256 _floor = _liquidity * (_balance0 > _balance1 ? _balance0 : _balance1);
    _totalSupply = bound(_totalSupply, _floor + 1, type(uint256).max);
    _setTotalSupply(_totalSupply);
    _mockAndExpectTokenBalance(_token0, address(_pool), _balance0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _balance1);

    // it should revert with InsufficientLiquidityBurned
    vm.expectRevert(IPool.InsufficientLiquidityBurned.selector);
    vm.prank(_recipient);
    _pool.burn(_recipient);
  }

  modifier whenTheAmountsToBurnArePositive() {
    _;
  }

  function test_WhenTheRemainingKIsZero() external whenTheAmountsToBurnArePositive {
    _setTotalSupply(1);
    _setLiquidity(1);

    // Both post-burn balances zero so `_k(0, 0) == 0`
    _mockAndExpectTokenBalancesTwice(_token0, address(_pool), [uint256(1), uint256(0)]);
    _mockAndExpectTokenBalancesTwice(_token1, address(_pool), [uint256(1), uint256(0)]);
    _mockAndExpectTokenTransfer(_token0, _recipient, 1);
    _mockAndExpectTokenTransfer(_token1, _recipient, 1);

    // it should revert with KIsZero
    vm.expectRevert(IStablePool.KIsZero.selector);
    _pool.burn(_recipient);
  }

  function test_WhenTheRemainingKIsPositive(
    uint256 _tokens,
    uint256 _liquidity
  ) external whenTheAmountsToBurnArePositive {
    // 1e10 is an approximate maximum value to avoid overflow in stable curve formula with current token decimals
    _tokens = bound(_tokens, 1, 1e10);
    // 1e12 is the liquidity minted when one token is deposited in the current decimal pair. Equal to `sqrt(decimals0 * decimals1)`
    _setTotalSupply(_tokens * 1e12);
    _setReserves(_tokens * _decimals0, _tokens * _decimals1);

    uint256 _reserve0Before = _tokens * _decimals0;
    uint256 _reserve1Before = _tokens * _decimals1;
    uint256 _totalSupplyBefore = _tokens * 1e12;

    // Lower bound forces both positive amounts to be burned
    // upper bound keeps post-burn `_k` above zero
    uint256 _minLiquidity = Math.max(_totalSupplyBefore / _reserve0Before, _totalSupplyBefore / _reserve1Before) + 1;
    _liquidity = bound(_liquidity, _minLiquidity, (_totalSupplyBefore * 90) / 100);
    _setLiquidity(_liquidity);

    uint256 _expectedAmount0 = (_liquidity * _reserve0Before) / _totalSupplyBefore;
    uint256 _expectedAmount1 = (_liquidity * _reserve1Before) / _totalSupplyBefore;

    _mockAndExpectTokenBalancesTwice(_token0, address(_pool), [_reserve0Before, _reserve0Before - _expectedAmount0]);
    _mockAndExpectTokenBalancesTwice(_token1, address(_pool), [_reserve1Before, _reserve1Before - _expectedAmount1]);
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
    assertEq(IERC20(address(_pool)).totalSupply(), _totalSupplyBefore - _liquidity);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new StablePool()));
  }
}
