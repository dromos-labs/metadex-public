// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolSync is UnitPool {
  function test_WhenThePoolTotalSupplyEqZero() external {
    // it should revert with InsufficientLiquidity
    vm.expectRevert(IPool.InsufficientLiquidity.selector);
    _pool.sync();
  }

  function test_WhenThePoolTotalSupplyIsGtZero(
    uint256 _totalSupply,
    uint256 _timestamp,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    _totalSupply = bound(_totalSupply, 1, type(uint256).max);
    _timestamp = bound(_timestamp, 1, type(uint32).max);
    vm.warp(_timestamp);

    _setTotalSupply(_totalSupply);
    _mockAndExpectTokenBalance(_token0, address(_pool), _balance0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _balance1);

    // it should emit the Sync event
    vm.expectEmit();
    emit IPool.Sync(_balance0, _balance1);

    _pool.sync();

    // it should set the reserves to the current token balances
    assertEq(_pool.reserve0(), _balance0);
    assertEq(_pool.reserve1(), _balance1);
    // it should set the last block timestamp
    assertEq(_pool.blockTimestampLast(), _timestamp);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
