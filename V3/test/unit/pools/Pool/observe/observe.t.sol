// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

contract UnitPoolObserve is UnitPool {
  modifier whenGettingObservationsForAnArrayOfSecondsAgo() {
    _;
  }

  function test_WhenTheArrayIsEmpty(uint32 _time) external whenGettingObservationsForAnArrayOfSecondsAgo {
    vm.warp(uint256(_time));
    uint32[] memory _secondsAgos = new uint32[](0);
    (uint256[] memory _reserve0Cumulatives, uint256[] memory _reserve1Cumulatives) = _pool.observe(_secondsAgos);

    // it should return two empty arrays
    assertEq(_reserve0Cumulatives.length, 0);
    assertEq(_reserve1Cumulatives.length, 0);
  }

  function test_WhenTheArrayIsNotEmpty(
    uint32 _time,
    uint32 _targetA,
    uint32 _targetB,
    uint32 _beforeTimestamp,
    uint32 _afterTimestamp,
    uint256 _beforeReserve0Cumulative,
    uint256 _beforeReserve1Cumulative,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative
  ) external whenGettingObservationsForAnArrayOfSecondsAgo {
    _beforeTimestamp = uint32(bound(_beforeTimestamp, 0, type(uint32).max - 1));
    _afterTimestamp = uint32(bound(_afterTimestamp, _beforeTimestamp + 1, type(uint32).max));
    _time = uint32(bound(_time, _afterTimestamp, type(uint32).max));
    _targetA = uint32(bound(_targetA, _beforeTimestamp, _afterTimestamp - 1));
    _targetB = uint32(bound(_targetB, _beforeTimestamp, _afterTimestamp - 1));
    _afterReserve0Cumulative = bound(_afterReserve0Cumulative, _beforeReserve0Cumulative, type(uint256).max);
    _afterReserve1Cumulative = bound(_afterReserve1Cumulative, _beforeReserve1Cumulative, type(uint256).max);

    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _writeObservation({
      _index: 0, _timestamp: _beforeTimestamp, _r0c: _beforeReserve0Cumulative, _r1c: _beforeReserve1Cumulative
    });
    _writeObservation({
      _index: 1, _timestamp: _afterTimestamp, _r0c: _afterReserve0Cumulative, _r1c: _afterReserve1Cumulative
    });

    vm.warp(uint256(_time));

    uint32[] memory _secondsAgos = new uint32[](2);
    _secondsAgos[0] = _time - _targetA;
    _secondsAgos[1] = _time - _targetB;

    (uint256[] memory _reserve0Cumulatives, uint256[] memory _reserve1Cumulatives) = _pool.observe(_secondsAgos);

    // it should return the cumulatives at each secondsAgo
    assertEq(_reserve0Cumulatives.length, _secondsAgos.length);
    assertEq(_reserve1Cumulatives.length, _secondsAgos.length);
    {
      (uint256 _expectedReserve0Cumulative, uint256 _expectedReserve1Cumulative) =
        MockPool(address(_pool)).externalObserveSingle(_time, _secondsAgos[0]);
      assertEq(_reserve0Cumulatives[0], _expectedReserve0Cumulative);
      assertEq(_reserve1Cumulatives[0], _expectedReserve1Cumulative);
    }
    {
      (uint256 _expectedReserve0Cumulative, uint256 _expectedReserve1Cumulative) =
        MockPool(address(_pool)).externalObserveSingle(_time, _secondsAgos[1]);
      assertEq(_reserve0Cumulatives[1], _expectedReserve0Cumulative);
      assertEq(_reserve1Cumulatives[1], _expectedReserve1Cumulative);
    }
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
