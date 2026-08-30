// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolCurrentCumulativePrices is UnitPool {
  function test_WhenTheReservesWereLastUpdatedInTheCurrentBlock(
    uint256 _timestamp,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast,
    uint256 _reserve0,
    uint256 _reserve1
  ) external {
    vm.warp(_timestamp);

    _setReserves(_reserve0, _reserve1);
    _set(address(_pool), _timestamp, _pool.blockTimestampLast.selector);
    _set(address(_pool), _reserve0CumulativeLast, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _reserve1CumulativeLast, _pool.reserve1CumulativeLast.selector);

    (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative, uint256 _blockTimestamp) =
      _pool.currentCumulativePrices();

    // it should return the stored cumulative reserves
    assertEq(_reserve0Cumulative, _reserve0CumulativeLast);
    assertEq(_reserve1Cumulative, _reserve1CumulativeLast);
    // it should return the current block timestamp
    assertEq(_blockTimestamp, _timestamp);
  }

  modifier whenTimeHasElapsedSinceTheLastReserveUpdate() {
    _;
  }

  function test_WhenTimeHasElapsedSinceTheLastReserveUpdate(
    uint256 _lastTimestamp,
    uint256 _elapsed,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast,
    uint256 _reserve0,
    uint256 _reserve1
  ) external {
    _lastTimestamp = bound(_lastTimestamp, 1, type(uint256).max - 1);
    _elapsed = bound(_elapsed, 1, type(uint256).max - _lastTimestamp);
    _reserve0 = bound(_reserve0, 0, type(uint256).max / _elapsed);
    _reserve1 = bound(_reserve1, 0, type(uint256).max / _elapsed);
    _reserve0CumulativeLast = bound(_reserve0CumulativeLast, 0, type(uint256).max - _reserve0 * _elapsed);
    _reserve1CumulativeLast = bound(_reserve1CumulativeLast, 0, type(uint256).max - _reserve1 * _elapsed);

    _setReserves(_reserve0, _reserve1);
    _set(address(_pool), _lastTimestamp, _pool.blockTimestampLast.selector);
    _set(address(_pool), _reserve0CumulativeLast, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _reserve1CumulativeLast, _pool.reserve1CumulativeLast.selector);
    vm.warp(_lastTimestamp + _elapsed);

    (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative, uint256 _blockTimestamp) =
      _pool.currentCumulativePrices();

    // it should extrapolate each cumulative reserve by reserve times elapsed time
    assertEq(_reserve0Cumulative, _reserve0CumulativeLast + _reserve0 * _elapsed);
    assertEq(_reserve1Cumulative, _reserve1CumulativeLast + _reserve1 * _elapsed);
    // it should return the current block timestamp
    assertEq(_blockTimestamp, _lastTimestamp + _elapsed);
  }

  function test_WhenUsingAKnownExtrapolationExample() external whenTimeHasElapsedSinceTheLastReserveUpdate {
    _setReserves(5e18, 10e18);
    _set(address(_pool), 100, _pool.blockTimestampLast.selector);
    _set(address(_pool), 1000e18, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), 2000e18, _pool.reserve1CumulativeLast.selector);
    vm.warp(160); // 60 seconds elapsed

    (uint256 _reserve0Cumulative, uint256 _reserve1Cumulative,) = _pool.currentCumulativePrices();

    // it should match the hand computed cumulative reserves
    // 1_000e18 + 5e18 * 60 = 1_300e18
    assertEq(_reserve0Cumulative, 1300e18);
    // 2_000e18 + 10e18 * 60 = 2_600e18
    assertEq(_reserve1Cumulative, 2600e18);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
