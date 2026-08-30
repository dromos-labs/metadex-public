// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VolatilityRingLibrary} from 'V3/libraries/VolatilityRingLibrary.sol';

import {VolatilityRingHandler} from 'V3-test/mocks/VolatilityRingHandler.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitVolatilityRingLibrary is TestHelpers {
  VolatilityRingHandler internal _handler;

  function setUp() external {
    _handler = new VolatilityRingHandler();
  }

  function test_PackPacksTheRangeDistAndMIntoTheFull64Bits(uint24 _range, uint24 _dist, uint16 _m) external view {
    uint64 _packed = _handler.pack(_range, _dist, _m);
    // it packs the range dist and m into the full 64 bits
    assertEq(_packed, (uint64(_range) << 40) | (uint64(_dist) << 16) | _m);
  }

  function test_UnpackReturnsThePackedRangeDistAndM(uint24 _range, uint24 _dist, uint16 _m) external view {
    (uint24 _readRange, uint24 _readDist, uint16 _readM) =
      _handler.unpack((uint64(_range) << 40) | (uint64(_dist) << 16) | _m);
    // it returns the packed range dist and m
    assertEq(_readRange, _range);
    assertEq(_readDist, _dist);
    assertEq(_readM, _m);
  }

  function test_PushWritesThePackedValueAtTheHeadPositionOverAnyPreviousValue(
    uint8 _head,
    uint24 _previousRange,
    uint24 _previousDist,
    uint16 _previousM,
    uint24 _range,
    uint24 _dist,
    uint16 _m
  ) external {
    _head = uint8(bound(_head, 0, VolatilityRingLibrary._WINDOW - 1));
    _handler.push(_head, 0, _previousRange, _previousDist, _previousM);

    _handler.push(_head, 0, _range, _dist, _m);

    uint256 _word = _handler.ringValue(uint256(_head) / 4);
    uint64 _packed = uint64(_word >> ((uint256(_head) % 4) * 64));
    // it writes the packed value at the head position over any previous value
    assertEq(_packed, _handler.pack(_range, _dist, _m));
  }

  function test_PushLeavesTheOtherValuesInTheWordUntouched(
    uint8 _head,
    uint24 _seedRange,
    uint24 _seedDist,
    uint16 _seedM,
    uint24 _range,
    uint24 _dist,
    uint16 _m
  ) external {
    _head = uint8(bound(_head, 0, VolatilityRingLibrary._WINDOW - 1));
    _seedRange = uint24(bound(_seedRange, 1, type(uint24).max - 3));
    _seedDist = uint24(bound(_seedDist, 1, type(uint24).max - 3));
    _seedM = uint16(bound(_seedM, 1, type(uint16).max - 3));
    // fills the four positions of the word with different values
    uint8 _wordStart = (_head / 4) * 4;
    for (uint8 _i; _i < 4; ++_i) {
      _handler.push(_wordStart + _i, 0, _seedRange + _i, _seedDist + _i, _seedM + _i);
    }
    uint256 _wordBefore = _handler.ringValue(uint256(_head) / 4);
    uint256 _headMask = uint256(type(uint64).max) << ((uint256(_head) % 4) * 64);

    _handler.push(_head, 0, _range, _dist, _m);

    // it leaves the other values in the word untouched
    assertEq(_handler.ringValue(uint256(_head) / 4) & ~_headMask, _wordBefore & ~_headMask);
  }

  function test_PushAdvancesTheHeadModuloTheWindow(uint8 _head, uint24 _range, uint24 _dist, uint16 _m) external {
    _head = uint8(bound(_head, 0, VolatilityRingLibrary._WINDOW - 1));
    (uint8 _newHead,) = _handler.push(_head, 0, _range, _dist, _m);
    // it advances the head modulo the window
    assertEq(_newHead, (_head + 1) % VolatilityRingLibrary._WINDOW);
  }

  function test_PushWhenPushingAtTheLastSlotOfAFullRing() external {
    (uint8 _newHead, uint8 _newCount) = _handler.push({_head: 59, _count: 60, _range: 1000, _dist: 500, _m: 7});

    assertEq(VolatilityRingLibrary._WINDOW, 60);
    // it leaves the count unchanged
    assertEq(_newCount, 60);
    // it wraps the head to zero
    assertEq(_newHead, 0);
  }

  function test_PushWhenTheCountLtTheWindow(uint8 _count) external {
    _count = uint8(bound(_count, 0, VolatilityRingLibrary._WINDOW - 1));
    (, uint8 _newCount) = _handler.push(0, _count, 0, 0, 0);
    // it increments the count
    assertEq(_newCount, _count + 1);
  }

  function test_PushWhenTheCountEqTheWindow() external {
    (, uint8 _newCount) = _handler.push(0, VolatilityRingLibrary._WINDOW, 0, 0, 0);
    // it leaves the count unchanged
    assertEq(_newCount, VolatilityRingLibrary._WINDOW);
  }

  function test_ValuesWhenTheRingHasNotWrapped(uint8 _count) external {
    _count = uint8(bound(_count, 0, VolatilityRingLibrary._WINDOW - 1));
    uint8 _head;
    uint8 _ringCount;
    for (uint8 _i; _i < _count; ++_i) {
      (_head, _ringCount) = _handler.push(_head, _ringCount, _i, _i, _i);
    }

    (uint256[] memory _tickRanges, uint256[] memory _dists, uint256[] memory _swapCounts) =
      _handler.values(_head, _ringCount);

    // it sizes the three arrays to the count
    assertEq(_tickRanges.length, _count);
    assertEq(_dists.length, _count);
    assertEq(_swapCounts.length, _count);
    // it returns the stored values ordered oldest to newest
    for (uint8 _i; _i < _count; ++_i) {
      assertEq(_tickRanges[_i], _i);
      assertEq(_dists[_i], _i);
      assertEq(_swapCounts[_i], _i);
    }
  }

  function test_ValuesWhenTheRingHasWrapped(uint8 _head) external {
    _head = uint8(bound(_head, 1, VolatilityRingLibrary._WINDOW - 1));
    for (uint8 _p; _p < VolatilityRingLibrary._WINDOW; ++_p) {
      _handler.push(_p, VolatilityRingLibrary._WINDOW, _p, _p, 0);
    }

    (uint256[] memory _tickRanges, uint256[] memory _dists,) = _handler.values(_head, VolatilityRingLibrary._WINDOW);

    // it returns the values ordered oldest to newest across the wrap
    assertEq(_tickRanges.length, VolatilityRingLibrary._WINDOW);
    for (uint8 _i; _i < VolatilityRingLibrary._WINDOW; ++_i) {
      // the oldest sits at the head position
      assertEq(_tickRanges[_i], (_head + _i) % VolatilityRingLibrary._WINDOW);
      assertEq(_dists[_i], (_head + _i) % VolatilityRingLibrary._WINDOW);
    }
  }
}
