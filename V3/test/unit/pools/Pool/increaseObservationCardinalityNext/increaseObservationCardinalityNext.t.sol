// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolIncreaseObservationCardinalityNext is UnitPool {
  function test_WhenTheValueReturnedByGrowEqualsTheCurrentObservationCardinalityNext(
    uint16 _next,
    uint16 _currentCardinalityNext
  ) external {
    _currentCardinalityNext = uint16(bound(_currentCardinalityNext, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _next = uint16(bound(_next, 0, _currentCardinalityNext));

    _setObservationCardinalityNext(_currentCardinalityNext);

    _pool.increaseObservationCardinalityNext(_next);

    // it should leave observationCardinalityNext unchanged and emit nothing
    (,, uint16 _cardinalityNext) = _pool.observationBuffer();
    assertEq(_cardinalityNext, _currentCardinalityNext);
  }

  function test_WhenTheValueReturnedByGrowDiffersFromTheCurrentObservationCardinalityNext(
    uint16 _next,
    uint16 _currentCardinalityNext
  ) external {
    _currentCardinalityNext = uint16(bound(_currentCardinalityNext, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));

    uint256 _maxNext = uint256(_currentCardinalityNext) + 10_000;
    if (_maxNext > OBSERVATIONS_CIRCULAR_BUFFER_SIZE) _maxNext = OBSERVATIONS_CIRCULAR_BUFFER_SIZE;
    _next = uint16(bound(_next, uint256(_currentCardinalityNext) + 1, _maxNext));

    _setObservationCardinalityNext(_currentCardinalityNext);

    // it should emit IncreaseObservationCardinalityNext with the old and new values
    vm.expectEmit(true, false, false, true, address(_pool));
    emit IPool.IncreaseObservationCardinalityNext(address(this), _currentCardinalityNext, _next);
    _pool.increaseObservationCardinalityNext(_next);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
