// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {stdError} from 'forge-std/StdError.sol';

import {
  IPoolFactoryIndexation,
  UnitPoolFactoryIndexation
} from 'V3-test/unit/pools/PoolFactoryIndexation/PoolFactoryIndexation.t.sol';

contract UnitPoolFactoryIndexationPoolsIndexPaginated is UnitPoolFactoryIndexation {
  function test_WhenEndIsLtOrEqStart(uint256 _start, uint256 _end) external {
    _start = bound(_start, 0, type(uint256).max);
    _end = bound(_end, 0, _start);

    // it reverts with EndLeqStart
    vm.expectRevert(IPoolFactoryIndexation.EndLeqStart.selector);
    poolFactoryIndexation.poolsIndexPaginated(_start, _end);
  }

  modifier whenEndIsGtStart() {
    _;
  }

  function test_WhenEndIsGtArrayLength(uint256 _start, uint256 _end) external whenEndIsGtStart {
    /// @dev Bounding by LENGTH_CEIL avoid memory allocation Panic(0x41).
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    uint256 _length = _end - 1;
    _setPoolsIndexLength(_length);
    assertEq(poolFactoryIndexation.poolsIndexLength(), _length);

    // it reverts with Panic(0x32)
    vm.expectRevert(stdError.indexOOBError);
    poolFactoryIndexation.poolsIndexPaginated(_start, _end);
  }

  function test_WhenEndIsLeqArrayLength(uint256 _start, uint256 _end, uint256 _length) external whenEndIsGtStart {
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    _length = bound(_length, _end, LENGTH_CEIL > _end ? LENGTH_CEIL : _end);

    _poolsIndex_push({_numberOfElements: _length});

    (address _pool0, uint48 _t0) = poolFactoryIndexation.poolsIndex(0);
    // check push's correctness
    assertEq(_pool0, address(1));
    assertEq(_t0, 1);

    IPoolFactoryIndexation.PoolData[] memory _paginatedPoolData =
      poolFactoryIndexation.poolsIndexPaginated(_start, _end);
    uint256 _len = _end - _start;

    // it returns elements from poolsIndex array from start (inclusive) to end (exclusive)
    assertEq(_paginatedPoolData.length, _len);
    for (uint256 _i = 0; _i < _len; ++_i) {
      IPoolFactoryIndexation.PoolData memory _poolData = _paginatedPoolData[_i];

      (address _pool, uint48 _t) = poolFactoryIndexation.poolsIndex(_i + _start);

      assertEq(_poolData.pool, _pool);
      assertEq(uint256(_poolData.creationTimestamp), uint256(_t));
    }
  }
}
