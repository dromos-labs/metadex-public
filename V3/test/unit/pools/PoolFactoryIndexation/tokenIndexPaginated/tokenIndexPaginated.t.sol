// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {stdError} from 'forge-std/StdError.sol';

import {
  IPoolFactoryIndexation,
  UnitPoolFactoryIndexation
} from 'V3-test/unit/pools/PoolFactoryIndexation/PoolFactoryIndexation.t.sol';

contract UnitPoolFactoryIndexationTokenIndexPaginated is UnitPoolFactoryIndexation {
  function test_WhenEndIsLtOrEqStart(uint256 _start, uint256 _end) external {
    _start = bound(_start, 0, type(uint256).max);
    _end = bound(_end, 0, _start);

    // it reverts with EndLeqStart
    vm.expectRevert(IPoolFactoryIndexation.EndLeqStart.selector);
    poolFactoryIndexation.tokenIndexPaginated(_start, _end);
  }

  modifier whenEndIsGtStart() {
    _;
  }

  function test_WhenEndIsGtArrayLength(uint256 _start, uint256 _end) external whenEndIsGtStart {
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    uint256 _length = _end - 1;
    _setTokenIndexLength(_length);
    assertEq(poolFactoryIndexation.tokenIndexLength(), _length);

    // it reverts with Panic(0x32)
    vm.expectRevert(stdError.indexOOBError);
    poolFactoryIndexation.tokenIndexPaginated(_start, _end);
  }

  function test_WhenEndIsLeqArrayLength(uint256 _start, uint256 _end, uint256 _length) external whenEndIsGtStart {
    _start = bound(_start, 0, LENGTH_CEIL - 1);
    _end = bound(_end, _start + 1, LENGTH_CEIL);

    _length = bound(_length, _end, LENGTH_CEIL > _end ? LENGTH_CEIL : _end);

    _tokenIndex_push({_numberOfElements: _length});

    address[] memory _paginatedTokens = poolFactoryIndexation.tokenIndexPaginated(_start, _end);
    uint256 _len = _end - _start;

    // it returns elements from tokenIndex set from start (inclusive) to end (exclusive)
    assertEq(_paginatedTokens.length, _len);
    for (uint256 _i = 0; _i < _len; ++_i) {
      assertEq(_paginatedTokens[_i], _tokenIndex_get(_i + _start));
    }
  }
}
