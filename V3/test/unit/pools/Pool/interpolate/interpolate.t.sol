// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {PoolOracle} from 'V3/libraries/PoolOracle.sol';

contract UnitPoolOracleInterpolate is UnitPool {
  function test_ShouldLinearlyInterpolateTheReserveCumulativesAtTheTarget(
    uint32 _beforeTimestamp,
    uint32 _afterTimestamp,
    uint32 _target,
    uint256 _beforeReserve0Cumulative,
    uint256 _beforeReserve1Cumulative,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative
  ) external view {
    _beforeTimestamp = uint32(bound(_beforeTimestamp, 0, type(uint32).max - 1));
    _afterTimestamp = uint32(bound(_afterTimestamp, uint256(_beforeTimestamp) + 1, type(uint32).max));
    _target = uint32(bound(_target, _beforeTimestamp, _afterTimestamp));
    _afterReserve0Cumulative = bound(_afterReserve0Cumulative, _beforeReserve0Cumulative, type(uint256).max);
    _afterReserve1Cumulative = bound(_afterReserve1Cumulative, _beforeReserve1Cumulative, type(uint256).max);

    PoolOracle.Observation memory _beforeOrAt = PoolOracle.Observation({
      timestamp: _beforeTimestamp,
      reserve0Cumulative: _beforeReserve0Cumulative,
      reserve1Cumulative: _beforeReserve1Cumulative
    });

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) = MockPool(address(_pool))
      .externalInterpolate(_beforeOrAt, _afterTimestamp, _afterReserve0Cumulative, _afterReserve1Cumulative, _target);

    uint256 _timeDelta = uint256(_afterTimestamp) - uint256(_beforeTimestamp);
    uint256 _targetDelta = uint256(_target) - uint256(_beforeTimestamp);
    uint256 _expectedReserve0Cumulative = _beforeReserve0Cumulative
      + Math.mulDiv(_afterReserve0Cumulative - _beforeReserve0Cumulative, _targetDelta, _timeDelta);
    uint256 _expectedReserve1Cumulative = _beforeReserve1Cumulative
      + Math.mulDiv(_afterReserve1Cumulative - _beforeReserve1Cumulative, _targetDelta, _timeDelta);

    // it should linearly interpolate the reserve cumulatives at the target
    assertEq(_actualReserve0Cumulative, _expectedReserve0Cumulative);
    assertEq(_actualReserve1Cumulative, _expectedReserve1Cumulative);
  }

  function test_WhenGivenAConcreteExample() external view {
    // before = (t=1000, r0c=500, r1c=700), after = (t=1003, r0c=510, r1c=720), target t=1001.
    // r0: 500 + (510 - 500) * (1001 - 1000) / (1003 - 1000) = 500 + 10 / 3 = 500 + 3 = 503  (10/3 truncates)
    // r1: 700 + (720 - 700) * (1001 - 1000) / (1003 - 1000) = 700 + 20 / 3 = 700 + 6 = 706  (20/3 truncates)
    PoolOracle.Observation memory _beforeOrAt =
      PoolOracle.Observation({timestamp: 1000, reserve0Cumulative: 500, reserve1Cumulative: 700});

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) =
      MockPool(address(_pool)).externalInterpolate(_beforeOrAt, 1003, 510, 720, 1001);

    // it should match the hand-computed interpolation at a truncation boundary
    assertEq(_actualReserve0Cumulative, 503);
    assertEq(_actualReserve1Cumulative, 706);
  }

  function test_WhenGivenAConcreteExampleWithAnOverflowingIntermediateProduct() external view {
    // before = (t=1000, r0c=0, r1c=1), after = (t=1004, r0c=2^255, r1c=2^255 + 1), target t=1002.
    // The naive product delta * targetDelta = 2^255 * 2 overflows uint256 while the exact result fits.
    // r0: 0 + 2^255 * (1002 - 1000) / (1004 - 1000) = 2^254
    // r1: 1 + 2^255 * (1002 - 1000) / (1004 - 1000) = 2^254 + 1
    PoolOracle.Observation memory _beforeOrAt =
      PoolOracle.Observation({timestamp: 1000, reserve0Cumulative: 0, reserve1Cumulative: 1});

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) =
      MockPool(address(_pool)).externalInterpolate(_beforeOrAt, 1004, 2 ** 255, 2 ** 255 + 1, 1002);

    // it should match the hand computed interpolation
    assertEq(_actualReserve0Cumulative, 2 ** 254);
    assertEq(_actualReserve1Cumulative, 2 ** 254 + 1);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
