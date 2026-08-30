// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

contract UnitPoolOracleGrow is UnitPool {
  function test_WhenTheRequestedNextIsLtOrEqToTheCurrent(uint16 _current, uint16 _next) external {
    _current = uint16(bound(_current, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _next = uint16(bound(_next, 0, _current));
    _setObservationCardinality(1);
    _setObservationCardinalityNext(_current);

    vm.record();
    uint16 _grown = MockPool(address(_pool)).externalGrow(_next);
    (, bytes32[] memory _writes) = vm.accesses(address(_pool));

    // it should not write any slots
    assertEq(_writes.length, 0);

    // it should return the current value
    assertEq(_grown, _current);
  }

  function test_WhenTheRequestedNextIsGreaterThanTheCurrent(uint16 _current, uint16 _next) external {
    // Limited lower bound that prevents running out of gas
    _current =
      uint16(bound(_current, OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 10_000, OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _next = uint16(bound(_next, _current + 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _setObservationCardinality(1);
    _setObservationCardinalityNext(_current);

    vm.record();
    uint16 _grown = MockPool(address(_pool)).externalGrow(_next);
    (, bytes32[] memory _writes) = vm.accesses(address(_pool));

    uint32 _ts;
    uint256 _r0c;
    uint256 _r1c;

    // it should write three placeholder slots per grown observation plus the observationCardinalityNext slot
    assertEq(_writes.length, (_next - _current) * OBSERVATION_SLOT_COUNT + 1);

    // it should write a placeholder of one into each field of each observation in the new range
    for (uint16 _i = _current; _i < _next; _i++) {
      (_ts, _r0c, _r1c) = _pool.observations(_i);
      assertEq(_ts, 1);
      assertEq(_r0c, 1);
      assertEq(_r1c, 1);
    }

    // it should set observationCardinalityNext to the requested next
    (,, uint16 _cardinalityNext) = _pool.observationBuffer();
    assertEq(_cardinalityNext, _next);

    // it should return the requested next
    assertEq(_grown, _next);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
