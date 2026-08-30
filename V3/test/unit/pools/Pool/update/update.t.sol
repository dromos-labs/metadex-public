// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

contract UnitPoolUpdate is UnitPool {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();
    stdstore.target(address(_pool)).sig('blockTimestampLast()').checked_write(block.timestamp);
  }

  function test_WhenNoTimeHasElapsedSinceTheLastUpdate(
    uint256 _balance0,
    uint256 _balance1,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast
  ) external {
    _set(address(_pool), _reserve0CumulativeLast, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _reserve1CumulativeLast, _pool.reserve1CumulativeLast.selector);

    // it should emit the Sync event
    vm.expectEmit();
    emit IPool.Sync(_balance0, _balance1);
    MockPool(address(_pool)).externalUpdate(_balance0, _balance1, _reserve0, _reserve1);

    // it should not update the reserves cumulatives
    assertEq(_pool.reserve0CumulativeLast(), _reserve0CumulativeLast);
    assertEq(_pool.reserve1CumulativeLast(), _reserve1CumulativeLast);

    // it should update the reserves to the new balances
    assertEq(_pool.reserve0(), _balance0);
    assertEq(_pool.reserve1(), _balance1);
    // it should update blockTimestampLast
    assertEq(_pool.blockTimestampLast(), block.timestamp);
  }

  function test_WhenTimeHasElapsedSinceTheLastUpdateAndTheReservesArePositive(
    uint256 _balance0,
    uint256 _balance1,
    uint256 _reserve0,
    uint256 _reserve1,
    uint256 _elapsed,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast
  ) external {
    _elapsed = bound(_elapsed, 1, type(uint256).max - block.timestamp);
    _reserve0 = bound(_reserve0, 1, type(uint256).max / _elapsed);
    _reserve1 = bound(_reserve1, 1, type(uint256).max / _elapsed);
    _reserve0CumulativeLast = bound(_reserve0CumulativeLast, 0, type(uint256).max - _reserve0 * _elapsed);
    _reserve1CumulativeLast = bound(_reserve1CumulativeLast, 0, type(uint256).max - _reserve1 * _elapsed);
    _set(address(_pool), _reserve0CumulativeLast, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _reserve1CumulativeLast, _pool.reserve1CumulativeLast.selector);

    vm.warp(block.timestamp + _elapsed);

    // it should emit the Sync event
    vm.expectEmit();
    emit IPool.Sync(_balance0, _balance1);
    MockPool(address(_pool)).externalUpdate(_balance0, _balance1, _reserve0, _reserve1);

    // it should update the reserves cumulatives
    assertEq(_pool.reserve0CumulativeLast(), _reserve0CumulativeLast + _reserve0 * _elapsed);
    assertEq(_pool.reserve1CumulativeLast(), _reserve1CumulativeLast + _reserve1 * _elapsed);
    // it should update the reserves to the new balances
    assertEq(_pool.reserve0(), _balance0);
    assertEq(_pool.reserve1(), _balance1);
    // it should update blockTimestampLast
    assertEq(_pool.blockTimestampLast(), block.timestamp);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
