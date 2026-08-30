// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {PoolOracle} from 'V3/libraries/PoolOracle.sol';

contract UnitPoolOracleObserveSingle is UnitPool {
  function test_WhenSecondsAgoIsZero(
    uint32 _time,
    uint256 _reserve0CumulativeLast,
    uint256 _reserve1CumulativeLast
  ) external {
    _set(address(_pool), _reserve0CumulativeLast, _pool.reserve0CumulativeLast.selector);
    _set(address(_pool), _reserve1CumulativeLast, _pool.reserve1CumulativeLast.selector);

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) =
      MockPool(address(_pool)).externalObserveSingle(_time, 0);

    // it should return the current cumulative prices
    assertEq(_actualReserve0Cumulative, _reserve0CumulativeLast);
    assertEq(_actualReserve1Cumulative, _reserve1CumulativeLast);
  }

  modifier whenSecondsAgoIsPositive() {
    _;
  }

  function test_WhenTheTargetLandsOnTheAtOrAfterObservation(
    uint32 _time,
    uint32 _secondsAgo,
    uint256 _reserve0Cumulative,
    uint256 _reserve1Cumulative,
    uint16 _cardinality,
    uint16 _index
  ) external whenSecondsAgoIsPositive {
    _time = uint32(bound(_time, 1, type(uint32).max));
    _secondsAgo = uint32(bound(_secondsAgo, 1, _time));
    _cardinality = uint16(bound(_cardinality, 1, OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _index = uint16(bound(_index, 0, _cardinality - 1));

    uint32 _target = _time - _secondsAgo;

    // Newest observation sits exactly on the target, so observeSingle returns it without interpolating.
    _setObservationInformationSlot({_index: _index, _cardinality: _cardinality, _cardinalityNext: _cardinality});
    _writeObservation({_index: _index, _timestamp: _target, _r0c: _reserve0Cumulative, _r1c: _reserve1Cumulative});

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) =
      MockPool(address(_pool)).externalObserveSingle(_time, _secondsAgo);

    // it should return the at or after cumulatives
    assertEq(_actualReserve0Cumulative, _reserve0Cumulative);
    assertEq(_actualReserve1Cumulative, _reserve1Cumulative);
  }

  function test_WhenTheTargetFallsBetweenTheBeforeAndAfterObservations(
    uint32 _time,
    uint32 _secondsAgoBefore,
    uint32 _secondsAgoAfter,
    uint32 _secondsAgoTarget,
    uint256 _beforeReserve0Cumulative,
    uint256 _beforeReserve1Cumulative,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative
  ) external whenSecondsAgoIsPositive {
    // Bound seconds so we can test the different scenarios of the rollover logic.
    // secondsAgoAfter < secondsAgoTarget <= secondsAgoBefore
    _secondsAgoAfter = uint32(bound(_secondsAgoAfter, 0, type(uint32).max - 2));
    _secondsAgoTarget = uint32(bound(_secondsAgoTarget, _secondsAgoAfter + 1, type(uint32).max - 1));
    _secondsAgoBefore = uint32(bound(_secondsAgoBefore, _secondsAgoTarget, type(uint32).max));
    _afterReserve0Cumulative = bound(_afterReserve0Cumulative, _beforeReserve0Cumulative, type(uint256).max);
    _afterReserve1Cumulative = bound(_afterReserve1Cumulative, _beforeReserve1Cumulative, type(uint256).max);

    // Creates two observations to be able to test the interpolation logic.
    {
      uint32 _beforeTimestamp;
      uint32 _afterTimestamp;
      unchecked {
        _beforeTimestamp = _time - _secondsAgoBefore;
        _afterTimestamp = _time - _secondsAgoAfter;
      }
      _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
      _writeObservation({
        _index: 0, _timestamp: _beforeTimestamp, _r0c: _beforeReserve0Cumulative, _r1c: _beforeReserve1Cumulative
      });
      _writeObservation({
        _index: 1, _timestamp: _afterTimestamp, _r0c: _afterReserve0Cumulative, _r1c: _afterReserve1Cumulative
      });
    }

    (uint256 _actualReserve0Cumulative, uint256 _actualReserve1Cumulative) =
      MockPool(address(_pool)).externalObserveSingle(_time, _secondsAgoTarget);

    (uint256 _expectedReserve0Cumulative, uint256 _expectedReserve1Cumulative) = _expectedInterpolatedCumulatives(
      _time,
      _secondsAgoBefore,
      _secondsAgoAfter,
      _secondsAgoTarget,
      _beforeReserve0Cumulative,
      _beforeReserve1Cumulative,
      _afterReserve0Cumulative,
      _afterReserve1Cumulative
    );

    // it should return the interpolation
    assertEq(_actualReserve0Cumulative, _expectedReserve0Cumulative);
    assertEq(_actualReserve1Cumulative, _expectedReserve1Cumulative);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }

  function _expectedInterpolatedCumulatives(
    uint32 _time,
    uint32 _secondsAgoBefore,
    uint32 _secondsAgoAfter,
    uint32 _secondsAgoTarget,
    uint256 _beforeReserve0Cumulative,
    uint256 _beforeReserve1Cumulative,
    uint256 _afterReserve0Cumulative,
    uint256 _afterReserve1Cumulative
  ) internal view returns (uint256, uint256) {
    uint32 _beforeTimestamp;
    uint32 _afterTimestamp;
    uint32 _target;
    unchecked {
      _beforeTimestamp = _time - _secondsAgoBefore;
      _afterTimestamp = _time - _secondsAgoAfter;
      _target = _time - _secondsAgoTarget;
    }
    PoolOracle.Observation memory _beforeObservation = PoolOracle.Observation({
      timestamp: _beforeTimestamp,
      reserve0Cumulative: _beforeReserve0Cumulative,
      reserve1Cumulative: _beforeReserve1Cumulative
    });
    return MockPool(address(_pool))
      .externalInterpolate(
        _beforeObservation, _afterTimestamp, _afterReserve0Cumulative, _afterReserve1Cumulative, _target
      );
  }
}
