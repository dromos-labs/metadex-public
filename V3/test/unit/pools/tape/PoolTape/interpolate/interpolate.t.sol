// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract UnitPoolTapeInterpolate is UnitPoolTapeBase {
  function test_LinearlyInterpolatesEveryCumulativeFieldAtTheTarget(
    uint48 _beforeTimestamp,
    uint48 _afterTimestamp,
    uint48 _target,
    IPoolTape.Observation memory _before,
    IPoolTape.Observation memory _after
  ) external view {
    _beforeTimestamp = uint48(bound(_beforeTimestamp, 0, type(uint48).max - 1));
    _afterTimestamp = uint48(bound(_afterTimestamp, uint256(_beforeTimestamp) + 1, type(uint48).max));
    _target = uint48(bound(_target, _beforeTimestamp, _afterTimestamp));
    _before.blockTimestamp = _beforeTimestamp;
    _after.blockTimestamp = _afterTimestamp;
    _after.cumulativeFee0 = uint128(bound(_after.cumulativeFee0, _before.cumulativeFee0, type(uint128).max));
    _after.cumulativeFee1 = uint128(bound(_after.cumulativeFee1, _before.cumulativeFee1, type(uint128).max));
    _after.cumulativeVolume0 = uint128(bound(_after.cumulativeVolume0, _before.cumulativeVolume0, type(uint128).max));
    _after.cumulativeVolume1 = uint128(bound(_after.cumulativeVolume1, _before.cumulativeVolume1, type(uint128).max));
    _after.cumulativeMevVolume0 =
      uint128(bound(_after.cumulativeMevVolume0, _before.cumulativeMevVolume0, type(uint128).max));
    _after.cumulativeMevVolume1 =
      uint128(bound(_after.cumulativeMevVolume1, _before.cumulativeMevVolume1, type(uint128).max));
    _after.cumulativeMevFee0 = uint128(bound(_after.cumulativeMevFee0, _before.cumulativeMevFee0, type(uint128).max));
    _after.cumulativeMevFee1 = uint128(bound(_after.cumulativeMevFee1, _before.cumulativeMevFee1, type(uint128).max));
    _after.swapCount = uint48(bound(_after.swapCount, _before.swapCount, type(uint48).max));

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalInterpolate(_before, _after, _target);

    uint256 _timeDelta = uint256(_afterTimestamp) - uint256(_beforeTimestamp);
    uint256 _targetDelta = uint256(_target) - uint256(_beforeTimestamp);

    // it linearly interpolates every cumulative field at the target
    assertEq(
      _result.cumulativeFee0, _expectedField(_before.cumulativeFee0, _after.cumulativeFee0, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeFee1, _expectedField(_before.cumulativeFee1, _after.cumulativeFee1, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeVolume0,
      _expectedField(_before.cumulativeVolume0, _after.cumulativeVolume0, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeVolume1,
      _expectedField(_before.cumulativeVolume1, _after.cumulativeVolume1, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeMevVolume0,
      _expectedField(_before.cumulativeMevVolume0, _after.cumulativeMevVolume0, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeMevVolume1,
      _expectedField(_before.cumulativeMevVolume1, _after.cumulativeMevVolume1, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeMevFee0,
      _expectedField(_before.cumulativeMevFee0, _after.cumulativeMevFee0, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.cumulativeMevFee1,
      _expectedField(_before.cumulativeMevFee1, _after.cumulativeMevFee1, _targetDelta, _timeDelta)
    );
    assertEq(
      _result.swapCount,
      uint48(uint256(_before.swapCount) + (uint256(_after.swapCount - _before.swapCount) * _targetDelta) / _timeDelta)
    );
    assertEq(_result.blockTimestamp, _target);
  }

  function test_WhenGivenAConcreteExample() external view {
    // The target sits one second into a three second gap, so every field advances by (after - before) / 3, truncated.
    // fee0:        100 + (130 - 100) / 3 = 110
    // fee1:        200 + (211 - 200) / 3 = 203   (11 / 3 truncates to 3)
    // volume0:     500 + (510 - 500) / 3 = 503   (10 / 3 truncates to 3)
    // volume1:    1000 + (1042 - 1000) / 3 = 1014
    // mevVolume0:    7 + (20 - 7) / 3 = 11       (13 / 3 truncates to 4)
    // mevVolume1:   50 + (53 - 50) / 3 = 51
    // mevFee0:       9 + (10 - 9) / 3 = 9        (1 / 3 truncates to 0)
    // mevFee1:     300 + (336 - 300) / 3 = 312
    // swapCount:   700 + (720 - 700) / 3 = 706   (20 / 3 truncates to 6)
    IPoolTape.Observation memory _before;
    _before.blockTimestamp = 1000;
    _before.cumulativeFee0 = 100;
    _before.cumulativeFee1 = 200;
    _before.cumulativeVolume0 = 500;
    _before.cumulativeVolume1 = 1000;
    _before.cumulativeMevVolume0 = 7;
    _before.cumulativeMevVolume1 = 50;
    _before.cumulativeMevFee0 = 9;
    _before.cumulativeMevFee1 = 300;
    _before.swapCount = 700;

    IPoolTape.Observation memory _after;
    _after.blockTimestamp = 1003;
    _after.cumulativeFee0 = 130;
    _after.cumulativeFee1 = 211;
    _after.cumulativeVolume0 = 510;
    _after.cumulativeVolume1 = 1042;
    _after.cumulativeMevVolume0 = 20;
    _after.cumulativeMevVolume1 = 53;
    _after.cumulativeMevFee0 = 10;
    _after.cumulativeMevFee1 = 336;
    _after.swapCount = 720;

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalInterpolate(_before, _after, 1001);

    // it matches the hand computed interpolation at a truncation boundary
    assertEq(_result.cumulativeFee0, 110);
    assertEq(_result.cumulativeFee1, 203);
    assertEq(_result.cumulativeVolume0, 503);
    assertEq(_result.cumulativeVolume1, 1014);
    assertEq(_result.cumulativeMevVolume0, 11);
    assertEq(_result.cumulativeMevVolume1, 51);
    assertEq(_result.cumulativeMevFee0, 9);
    assertEq(_result.cumulativeMevFee1, 312);
    assertEq(_result.swapCount, 706);
    assertEq(_result.blockTimestamp, 1001);
  }

  function test_WhenGivenAConcreteExampleThatWraps() external view {
    // fee0:       max + (1 + 1) / 2  -> 0
    // fee1:       max + (3 + 1) / 2  -> 1
    // volume0:    max + (5 + 1) / 2  -> 2
    // volume1:    max + (7 + 1) / 2  -> 3
    // mevVolume0: max + (9 + 1) / 2  -> 4
    // mevVolume1: max + (11 + 1) / 2 -> 5
    // mevFee0:    max + (13 + 1) / 2 -> 6
    // mevFee1:    max + (15 + 1) / 2 -> 7
    // swapCount:  max48 + (21 + 1) / 2 -> 10
    uint128 _max = type(uint128).max;
    IPoolTape.Observation memory _before;
    _before.blockTimestamp = 1000;
    _before.cumulativeFee0 = _max;
    _before.cumulativeFee1 = _max;
    _before.cumulativeVolume0 = _max;
    _before.cumulativeVolume1 = _max;
    _before.cumulativeMevVolume0 = _max;
    _before.cumulativeMevVolume1 = _max;
    _before.cumulativeMevFee0 = _max;
    _before.cumulativeMevFee1 = _max;
    _before.swapCount = type(uint48).max;

    IPoolTape.Observation memory _after;
    _after.blockTimestamp = 1002;
    _after.cumulativeFee0 = 1;
    _after.cumulativeFee1 = 3;
    _after.cumulativeVolume0 = 5;
    _after.cumulativeVolume1 = 7;
    _after.cumulativeMevVolume0 = 9;
    _after.cumulativeMevVolume1 = 11;
    _after.cumulativeMevFee0 = 13;
    _after.cumulativeMevFee1 = 15;
    _after.swapCount = 21;

    IPoolTape.Observation memory _result = MockPoolTape(address(_tape)).externalInterpolate(_before, _after, 1001);

    // it matches the hand computed interpolation across a cumulative wrap
    assertEq(_result.cumulativeFee0, 0);
    assertEq(_result.cumulativeFee1, 1);
    assertEq(_result.cumulativeVolume0, 2);
    assertEq(_result.cumulativeVolume1, 3);
    assertEq(_result.cumulativeMevVolume0, 4);
    assertEq(_result.cumulativeMevVolume1, 5);
    assertEq(_result.cumulativeMevFee0, 6);
    assertEq(_result.cumulativeMevFee1, 7);
    assertEq(_result.swapCount, 10);
    assertEq(_result.blockTimestamp, 1001);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (PoolTape) {
    return new MockPoolTape(_initialOwner, _defaultCadenceInterval);
  }

  function _expectedField(
    uint128 _beforeValue,
    uint128 _afterValue,
    uint256 _targetDelta,
    uint256 _timeDelta
  ) internal pure returns (uint128) {
    return uint128(uint256(_beforeValue) + (uint256(_afterValue - _beforeValue) * _targetDelta) / _timeDelta);
  }
}
