// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeInterpolate is UnitClPoolTapeBase {
  function test_LinearlyInterpolatesEveryCumulativeFieldAtTheTarget(
    uint40 _beforeTimestamp,
    uint40 _afterTimestamp,
    uint40 _target,
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after
  ) external view {
    _beforeTimestamp = uint40(bound(_beforeTimestamp, 0, type(uint40).max - 2));
    _afterTimestamp = uint40(bound(_afterTimestamp, uint256(_beforeTimestamp) + 2, type(uint40).max));
    _target = uint40(bound(_target, uint256(_beforeTimestamp) + 1, uint256(_afterTimestamp) - 1));
    _before.blockTimestamp = _beforeTimestamp;
    _after.blockTimestamp = _afterTimestamp;
    _after.cumulativeFee0 = uint120(bound(_after.cumulativeFee0, _before.cumulativeFee0, type(uint120).max));
    _after.cumulativeFee1 = uint120(bound(_after.cumulativeFee1, _before.cumulativeFee1, type(uint120).max));
    _after.cumulativeVolume0 = uint120(bound(_after.cumulativeVolume0, _before.cumulativeVolume0, type(uint120).max));
    _after.cumulativeVolume1 = uint120(bound(_after.cumulativeVolume1, _before.cumulativeVolume1, type(uint120).max));
    _after.cumulativeMevVolume0 =
      uint120(bound(_after.cumulativeMevVolume0, _before.cumulativeMevVolume0, type(uint120).max));
    _after.cumulativeMevVolume1 =
      uint120(bound(_after.cumulativeMevVolume1, _before.cumulativeMevVolume1, type(uint120).max));
    _after.cumulativeMevFee0 = uint120(bound(_after.cumulativeMevFee0, _before.cumulativeMevFee0, type(uint120).max));
    _after.cumulativeMevFee1 = uint120(bound(_after.cumulativeMevFee1, _before.cumulativeMevFee1, type(uint120).max));
    _after.secondsPerStakedLiquidityCumulativeX128 = uint160(
      bound(
        _after.secondsPerStakedLiquidityCumulativeX128,
        _before.secondsPerStakedLiquidityCumulativeX128,
        type(uint160).max
      )
    );
    _after.secondsPerLiquidityCumulativeX128 = uint160(
      bound(_after.secondsPerLiquidityCumulativeX128, _before.secondsPerLiquidityCumulativeX128, type(uint160).max)
    );
    _after.swapCount = uint32(bound(_after.swapCount, _before.swapCount, type(uint32).max));

    ICLPoolTape.Observation memory _result =
      MockCLPoolTape(address(_tape)).externalInterpolate(_before, _after, _target);

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
      _result.secondsPerStakedLiquidityCumulativeX128,
      _expectedUint160Field(
        _before.secondsPerStakedLiquidityCumulativeX128,
        _after.secondsPerStakedLiquidityCumulativeX128,
        _targetDelta,
        _timeDelta
      )
    );
    assertEq(
      _result.secondsPerLiquidityCumulativeX128,
      _expectedUint160Field(
        _before.secondsPerLiquidityCumulativeX128, _after.secondsPerLiquidityCumulativeX128, _targetDelta, _timeDelta
      )
    );
    assertEq(
      _result.swapCount,
      uint32(uint256(_before.swapCount) + (uint256(_after.swapCount - _before.swapCount) * _targetDelta) / _timeDelta)
    );
    assertEq(_result.blockTimestamp, _target);
  }

  function test_CarriesCloseTickAndVolatilityValuesFromTheLowerBound(
    uint40 _beforeTimestamp,
    uint40 _afterTimestamp,
    uint40 _target,
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after
  ) external view {
    _beforeTimestamp = uint40(bound(_beforeTimestamp, 0, type(uint40).max - 2));
    _afterTimestamp = uint40(bound(_afterTimestamp, uint256(_beforeTimestamp) + 2, type(uint40).max));
    _target = uint40(bound(_target, uint256(_beforeTimestamp) + 1, uint256(_afterTimestamp) - 1));
    _before.blockTimestamp = _beforeTimestamp;
    _after.blockTimestamp = _afterTimestamp;
    _after.swapCount = uint32(bound(_after.swapCount, _before.swapCount, type(uint32).max));

    ICLPoolTape.Observation memory _result =
      MockCLPoolTape(address(_tape)).externalInterpolate(_before, _after, _target);

    // it carries closeTick and volatility values from the lower bound
    assertEq(_result.closeTick, _before.closeTick);
    assertEq(_result.volatilityCorrob, _before.volatilityCorrob);
  }

  function test_WhenGivenAConcreteExample() external view {
    // fee0:                    100 + (130 - 100) / 3 = 110
    // fee1:                    200 + (211 - 200) / 3 = 203        (11 / 3 truncates to 3)
    // volume0:                 500 + (510 - 500) / 3 = 503        (10 / 3 truncates to 3)
    // volume1:                1000 + (1042 - 1000) / 3 = 1014
    // mevVolume0:                7 + (20 - 7) / 3 = 11            (13 / 3 truncates to 4)
    // mevVolume1:               50 + (53 - 50) / 3 = 51
    // mevFee0:                   9 + (10 - 9) / 3 = 9             (1 / 3 truncates to 0)
    // mevFee1:                 300 + (336 - 300) / 3 = 312
    // secondsPerStaked:       9000 + (9030 - 9000) / 3 = 9010
    // secondsPerLiquidity:    4000 + (4012 - 4000) / 3 = 4004
    // swapCount:               700 + (720 - 700) / 3 = 706        (20 / 3 truncates to 6)
    // closeTick / volatilityCorrob: lower bound values, not interpolated
    ICLPoolTape.Observation memory _before;
    _before.blockTimestamp = 1000;
    _before.cumulativeFee0 = 100;
    _before.cumulativeFee1 = 200;
    _before.cumulativeVolume0 = 500;
    _before.cumulativeVolume1 = 1000;
    _before.cumulativeMevVolume0 = 7;
    _before.cumulativeMevVolume1 = 50;
    _before.cumulativeMevFee0 = 9;
    _before.cumulativeMevFee1 = 300;
    _before.secondsPerStakedLiquidityCumulativeX128 = 9000;
    _before.secondsPerLiquidityCumulativeX128 = 4000;
    _before.swapCount = 700;
    _before.closeTick = 111;
    _before.volatilityCorrob = 5;

    ICLPoolTape.Observation memory _after;
    _after.blockTimestamp = 1003;
    _after.cumulativeFee0 = 130;
    _after.cumulativeFee1 = 211;
    _after.cumulativeVolume0 = 510;
    _after.cumulativeVolume1 = 1042;
    _after.cumulativeMevVolume0 = 20;
    _after.cumulativeMevVolume1 = 53;
    _after.cumulativeMevFee0 = 10;
    _after.cumulativeMevFee1 = 336;
    _after.secondsPerStakedLiquidityCumulativeX128 = 9030;
    _after.secondsPerLiquidityCumulativeX128 = 4012;
    _after.swapCount = 720;
    _after.closeTick = 222;
    _after.volatilityCorrob = 9;

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalInterpolate(_before, _after, 1001);

    // it matches the hand computed interpolation at a truncation boundary
    assertEq(_result.cumulativeFee0, 110);
    assertEq(_result.cumulativeFee1, 203);
    assertEq(_result.cumulativeVolume0, 503);
    assertEq(_result.cumulativeVolume1, 1014);
    assertEq(_result.cumulativeMevVolume0, 11);
    assertEq(_result.cumulativeMevVolume1, 51);
    assertEq(_result.cumulativeMevFee0, 9);
    assertEq(_result.cumulativeMevFee1, 312);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, 9010);
    assertEq(_result.secondsPerLiquidityCumulativeX128, 4004);
    assertEq(_result.swapCount, 706);
    assertEq(_result.closeTick, 111);
    assertEq(_result.volatilityCorrob, 5);
    assertEq(_result.blockTimestamp, 1001);
  }

  function test_WhenGivenAConcreteExampleThatWraps() external view {
    // fee0:               max + (1 + 1) / 2     -> 0
    // fee1:               max + (3 + 1) / 2     -> 1
    // volume0:            max + (5 + 1) / 2     -> 2
    // volume1:            max + (7 + 1) / 2     -> 3
    // mevVolume0:         max + (9 + 1) / 2     -> 4
    // mevVolume1:         max + (11 + 1) / 2    -> 5
    // mevFee0:            max + (13 + 1) / 2    -> 6
    // mevFee1:            max + (15 + 1) / 2    -> 7
    // secondsPerStaked:   max160 + (17 + 1) / 2 -> 8
    // secondsPerLiquidity:max160 + (19 + 1) / 2 -> 9
    // swapCount:          max32 + (21 + 1) / 2  -> 10
    // closeTick / volatilityCorrob: lower bound values, not interpolated
    uint120 _max = type(uint120).max;
    uint160 _max160 = type(uint160).max;
    ICLPoolTape.Observation memory _before;
    _before.blockTimestamp = 1000;
    _before.cumulativeFee0 = _max;
    _before.cumulativeFee1 = _max;
    _before.cumulativeVolume0 = _max;
    _before.cumulativeVolume1 = _max;
    _before.cumulativeMevVolume0 = _max;
    _before.cumulativeMevVolume1 = _max;
    _before.cumulativeMevFee0 = _max;
    _before.cumulativeMevFee1 = _max;
    _before.secondsPerStakedLiquidityCumulativeX128 = _max160;
    _before.secondsPerLiquidityCumulativeX128 = _max160;
    _before.swapCount = type(uint32).max;
    _before.closeTick = 111;
    _before.volatilityCorrob = 5;

    ICLPoolTape.Observation memory _after;
    _after.blockTimestamp = 1002;
    _after.cumulativeFee0 = 1;
    _after.cumulativeFee1 = 3;
    _after.cumulativeVolume0 = 5;
    _after.cumulativeVolume1 = 7;
    _after.cumulativeMevVolume0 = 9;
    _after.cumulativeMevVolume1 = 11;
    _after.cumulativeMevFee0 = 13;
    _after.cumulativeMevFee1 = 15;
    _after.secondsPerStakedLiquidityCumulativeX128 = 17;
    _after.secondsPerLiquidityCumulativeX128 = 19;
    _after.swapCount = 21;
    _after.closeTick = 222;
    _after.volatilityCorrob = 9;

    ICLPoolTape.Observation memory _result = MockCLPoolTape(address(_tape)).externalInterpolate(_before, _after, 1001);

    // it matches the hand computed interpolation across a cumulative wrap
    assertEq(_result.cumulativeFee0, 0);
    assertEq(_result.cumulativeFee1, 1);
    assertEq(_result.cumulativeVolume0, 2);
    assertEq(_result.cumulativeVolume1, 3);
    assertEq(_result.cumulativeMevVolume0, 4);
    assertEq(_result.cumulativeMevVolume1, 5);
    assertEq(_result.cumulativeMevFee0, 6);
    assertEq(_result.cumulativeMevFee1, 7);
    assertEq(_result.secondsPerStakedLiquidityCumulativeX128, 8);
    assertEq(_result.secondsPerLiquidityCumulativeX128, 9);
    assertEq(_result.swapCount, 10);
    assertEq(_result.closeTick, 111);
    assertEq(_result.volatilityCorrob, 5);
    assertEq(_result.blockTimestamp, 1001);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (CLPoolTape) {
    return new MockCLPoolTape(_initialOwner, _defaultCadenceInterval);
  }

  function _expectedField(
    uint120 _beforeValue,
    uint120 _afterValue,
    uint256 _targetDelta,
    uint256 _timeDelta
  ) internal pure returns (uint120) {
    return uint120(uint256(_beforeValue) + (uint256(_afterValue - _beforeValue) * _targetDelta) / _timeDelta);
  }

  function _expectedUint160Field(
    uint160 _beforeValue,
    uint160 _afterValue,
    uint256 _targetDelta,
    uint256 _timeDelta
  ) internal pure returns (uint160) {
    return uint160(uint256(_beforeValue) + (uint256(_afterValue - _beforeValue) * _targetDelta) / _timeDelta);
  }
}
