// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolGetReserves is UnitPool {
  function test_ShouldReturnTheStoredReservesAndTheLastBlockTimestamp(
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _blockTimestampLast
  ) external {
    _setReserves(_reserve0, _reserve1);
    _set(address(_pool), _blockTimestampLast, _pool.blockTimestampLast.selector);

    (uint256 _returnedReserve0, uint256 _returnedReserve1, uint256 _returnedTimestamp) = _pool.getReserves();

    // it should return the stored reserves and the last block timestamp
    assertEq(_returnedReserve0, _reserve0);
    assertEq(_returnedReserve1, _reserve1);
    assertEq(_returnedTimestamp, _blockTimestampLast);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
