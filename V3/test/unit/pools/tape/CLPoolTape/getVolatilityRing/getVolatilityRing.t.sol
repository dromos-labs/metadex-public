// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {VolatilityRingLibrary} from 'V3/libraries/VolatilityRingLibrary.sol';

contract UnitClPoolTapeGetVolatilityRing is UnitClPoolTapeBase {
  function test_ReturnsTheRingValues(uint256 _word, uint8 _slotIndex, uint8 _head, uint8 _count) external {
    _slotIndex = uint8(bound(_slotIndex, 0, 14));
    _head = uint8(bound(_head, 0, VolatilityRingLibrary._WINDOW - 1));
    _count = uint8(bound(_count, 0, VolatilityRingLibrary._WINDOW));
    _setVolatilityRingSlot(_slotIndex, _word);
    ICLPoolTape.Accumulator memory _accumulator;
    _accumulator.volatilityRingHead = _head;
    _accumulator.volatilityRingCount = _count;
    _setAccumulator(_accumulator);
    uint256[15] memory _expectedRing;
    _expectedRing[_slotIndex] = _word;
    (uint256[] memory _expectedTickRanges, uint256[] memory _expectedDists, uint256[] memory _expectedSwapCounts) =
      VolatilityRingLibrary.values(_expectedRing, _head, _count);

    ICLPoolTape.VolatilityRing memory _values = _tape.getVolatilityRing(_pool);

    // it returns the ring values
    assertEq(_values.tickRanges, _expectedTickRanges);
    assertEq(_values.dists, _expectedDists);
    assertEq(_values.swapCounts, _expectedSwapCounts);
  }
}
