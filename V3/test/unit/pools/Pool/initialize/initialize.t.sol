// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

contract UnitPoolOracleInitialize is UnitPool {
  function test_WhenInitializingTheBuffer(uint32 _time) external {
    vm.warp(_time);
    MockPool(address(_pool)).externalInitialize();

    (uint32 _ts, uint256 _r0c, uint256 _r1c) = _pool.observations(0);
    // it should set the timestamp to the given timestamp
    assertEq(_ts, _time);
    // it should set the reserve0 cumulative to zero
    assertEq(_r0c, 0);
    // it should set the reserve1 cumulative to zero
    assertEq(_r1c, 0);
    (, uint16 _cardinality, uint16 _cardinalityNext) = _pool.observationBuffer();
    // it should set the cardinality to one
    assertEq(_cardinality, 1);
    // it should set the cardinalityNext to one
    assertEq(_cardinalityNext, 1);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
