// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeGetObservation is UnitClPoolTapeBase {
  function test_ReturnsTheStoredObservation(uint16 _index, ICLPoolTape.Observation memory _observation) external {
    _index = uint16(bound(_index, 0, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _setObservation(_index, _observation);
    // it returns the stored observation
    ICLPoolTape.Observation memory _stored = _tape.getObservation(_pool, _index);
    assertEq(_stored.cumulativeFee0, _observation.cumulativeFee0);
    assertEq(_stored.cumulativeFee1, _observation.cumulativeFee1);
    assertEq(_stored.cumulativeVolume0, _observation.cumulativeVolume0);
    assertEq(_stored.cumulativeVolume1, _observation.cumulativeVolume1);
    assertEq(_stored.cumulativeMevVolume0, _observation.cumulativeMevVolume0);
    assertEq(_stored.cumulativeMevVolume1, _observation.cumulativeMevVolume1);
    assertEq(_stored.cumulativeMevFee0, _observation.cumulativeMevFee0);
    assertEq(_stored.cumulativeMevFee1, _observation.cumulativeMevFee1);
    assertEq(_stored.secondsPerStakedLiquidityCumulativeX128, _observation.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_stored.blockTimestamp, _observation.blockTimestamp);
    assertEq(_stored.volatilityCorrob, _observation.volatilityCorrob);
    assertEq(_stored.secondsPerLiquidityCumulativeX128, _observation.secondsPerLiquidityCumulativeX128);
    assertEq(_stored.swapCount, _observation.swapCount);
    assertEq(_stored.closeTick, _observation.closeTick);
  }
}
