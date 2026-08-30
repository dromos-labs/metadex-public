// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolTokens is UnitPool {
  function test_ShouldReturnThePoolTokensInOrder(address _expectedToken0, address _expectedToken1) external {
    _set(address(_pool), uint256(uint160(_expectedToken0)), _pool.token0.selector);
    _set(address(_pool), uint256(uint160(_expectedToken1)), _pool.token1.selector);

    (address _returnedToken0, address _returnedToken1) = _pool.tokens();

    // it should return the pool tokens in order
    assertEq(_returnedToken0, _expectedToken0);
    assertEq(_returnedToken1, _expectedToken1);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
