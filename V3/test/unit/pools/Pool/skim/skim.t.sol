// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolSkim is UnitPool {
  function test_WhenTheTokenBalancesAreGteTheReserves(
    address _to,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _balance0,
    uint256 _balance1
  ) external {
    _balance0 = bound(_balance0, _reserve0, type(uint256).max);
    _balance1 = bound(_balance1, _reserve1, type(uint256).max);

    _setReserves(_reserve0, _reserve1);
    _mockAndExpectTokenBalance(_token0, address(_pool), _balance0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _balance1);
    // it should transfer the token zero excess to the recipient
    _mockAndExpectTokenTransfer(_token0, _to, _balance0 - _reserve0);
    // it should transfer the token one excess to the recipient
    _mockAndExpectTokenTransfer(_token1, _to, _balance1 - _reserve1);

    _pool.skim(_to);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
