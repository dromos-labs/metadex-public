// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';
import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolState} from 'V3/interfaces/pools/ICLPoolState.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

contract UnitClPoolTapeObserveWithSlotRequest is UnitClPoolTapeBase {
  modifier whenThePoolIsRegistered() {
    _;
  }

  function test_WhenTheArrayIsEmpty() external whenThePoolIsRegistered {
    uint48[] memory _secondsAgos = new uint48[](0);

    // thirty one is the all true mask, the slots do not matter for an empty array
    ICLPoolTape.Observation[] memory _result = _tape.observe(_pool, _secondsAgos, _slotsFromMask(31));

    // it returns an empty array
    assertEq(_result.length, 0);
  }

  function test_WhenTheArrayIsNotEmpty(
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB,
    uint8 _mask
  ) external whenThePoolIsRegistered {
    ICLPoolTape.ObservationSlots memory _slots = _slotsFromMask(uint8(bound(_mask, 0, 31)));
    uint48[] memory _secondsAgos =
      _seedBracketedScenario(_before, _after, _accumulator, _now, _secondsAgoA, _secondsAgoB);

    ICLPoolTape.Observation[] memory _masked = _tape.observe(_pool, _secondsAgos, _slots);
    ICLPoolTape.Observation[] memory _unmasked = _tape.observe(_pool, _secondsAgos);

    // it returns the observation at each secondsAgo
    assertEq(_masked.length, _secondsAgos.length);
    for (uint256 _i; _i < _masked.length; ++_i) {
      // it always populates the staked cumulative the swap count the block timestamp and the close tick
      assertEq(
        _masked[_i].secondsPerStakedLiquidityCumulativeX128, _unmasked[_i].secondsPerStakedLiquidityCumulativeX128
      );
      assertEq(_masked[_i].swapCount, _unmasked[_i].swapCount);
      assertEq(_masked[_i].blockTimestamp, _unmasked[_i].blockTimestamp);
      assertEq(_masked[_i].closeTick, _unmasked[_i].closeTick);
      // it populates requested slots equal to the observe function without slots param
      // it zeroes unrequested slots
      _assertMaskedObservation(_masked[_i], _unmasked[_i], _slots);
    }
  }

  function test_WhenTheRequestIsEmpty(
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB
  ) external whenThePoolIsRegistered {
    uint48[] memory _secondsAgos =
      _seedBracketedScenario(_before, _after, _accumulator, _now, _secondsAgoA, _secondsAgoB);

    ICLPoolTape.ObservationSlots memory _empty;
    ICLPoolTape.Observation[] memory _masked = _tape.observe(_pool, _secondsAgos, _empty);
    ICLPoolTape.Observation[] memory _unmasked = _tape.observe(_pool, _secondsAgos);

    // it returns only the always loaded fields
    for (uint256 _i; _i < _masked.length; ++_i) {
      assertEq(
        _masked[_i].secondsPerStakedLiquidityCumulativeX128, _unmasked[_i].secondsPerStakedLiquidityCumulativeX128
      );
      assertEq(_masked[_i].swapCount, _unmasked[_i].swapCount);
      assertEq(_masked[_i].blockTimestamp, _unmasked[_i].blockTimestamp);
      assertEq(_masked[_i].closeTick, _unmasked[_i].closeTick);
      _assertMaskedObservation(_masked[_i], _unmasked[_i], _empty);
    }
  }

  function test_WhenTheRequestExcludesSlotTwo(
    uint40 _lastSwapTimestamp,
    uint40 _now,
    uint48 _secondsAgo,
    uint8 _mask
  ) external whenThePoolIsRegistered {
    // bit zero is slot two, shifting the fuzzed bits left keeps it unset
    ICLPoolTape.ObservationSlots memory _slots = _slotsFromMask(uint8(bound(_mask, 0, 15)) << 1);

    _lastSwapTimestamp = uint40(bound(_lastSwapTimestamp, 1, type(uint40).max));
    _now = uint40(bound(_now, _lastSwapTimestamp, type(uint40).max));
    _setAccumulatorSlot1({
      _lastSwapTimestamp: _lastSwapTimestamp,
      _lastObservationTimestamp: 0,
      _swapCount: 0,
      _lastTick: 0,
      _intervalMaxTick: 0,
      _intervalMinTick: 0,
      _intervalOpenTick: 0,
      _volatilityCorrob: 0
    });
    _mockStakedCumulativeReads();
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](2);
    _secondsAgos[0] = 0;
    _secondsAgos[1] = uint48(bound(_secondsAgo, 0, _now - _lastSwapTimestamp));

    // it does not read the pool oracle for targets past the last swap
    vm.expectCall(_pool, abi.encodeWithSelector(ICLPoolDerivedState.observe.selector), 0);
    ICLPoolTape.Observation[] memory _result = _tape.observe(_pool, _secondsAgos, _slots);

    for (uint256 _i; _i < _result.length; ++_i) {
      assertEq(_result[_i].secondsPerLiquidityCumulativeX128, 0);
    }
  }

  modifier whenTheRequestExcludesAtLeastOneSlot() {
    _;
  }

  function test_WhenTheRequestExcludesAtLeastOneSlot(
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB,
    uint8 _mask
  ) external whenThePoolIsRegistered {
    // 29 drops the all true mask and the one excluding only slot two
    ICLPoolTape.ObservationSlots memory _slots = _slotsFromMask(uint8(bound(_mask, 0, 29)));
    uint48[] memory _secondsAgos =
      _seedBracketedScenario(_before, _after, _accumulator, _now, _secondsAgoA, _secondsAgoB);

    vm.record();
    _tape.observe(_pool, _secondsAgos, _slots);
    (bytes32[] memory _maskedReads,) = vm.accesses(address(_tape));

    vm.record();
    _tape.observe(_pool, _secondsAgos);
    (bytes32[] memory _unmaskedReads,) = vm.accesses(address(_tape));

    // it performs fewer storage reads than the observe function without slots param
    assertLt(_maskedReads.length, _unmaskedReads.length);
  }

  function test_WhenRequestingASingleSlotWithoutBinarySearch(
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now
  ) external whenThePoolIsRegistered whenTheRequestExcludesAtLeastOneSlot {
    _accumulator.lastSwapTimestamp = uint40(bound(_accumulator.lastSwapTimestamp, 1, type(uint40).max));
    _now = uint40(bound(_now, _accumulator.lastSwapTimestamp, type(uint40).max));
    _setAccumulator(_accumulator);
    _mockPoolOracle();
    _mockStakedCumulativeReads();
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](1);

    // Every flag has a base of 1 SLOAD from loading the whole accumulator slot 1, then adds the single SLOAD
    // of its own slot. The slot two flag adds none, its volatilityCorrob is already on slot 1 and its
    // cumulative comes from the pool oracle rather than storage.
    uint256[5] memory _expectedReads = [uint256(1), 2, 2, 2, 2];

    for (uint256 _i; _i < 5; ++_i) {
      vm.record();
      _tape.observe(_pool, _secondsAgos, _slotsFromMask(uint8(1 << _i)));
      (bytes32[] memory _reads,) = vm.accesses(address(_tape));

      // it performs exactly the expected storage reads for the requested slot
      assertEq(_reads.length, _expectedReads[_i]);
    }
  }

  function test_WhenRequestingASingleSlotWithBinarySearch(
    uint40 _beforeTimestamp,
    uint40 _afterTimestamp,
    uint40 _now
  ) external whenThePoolIsRegistered whenTheRequestExcludesAtLeastOneSlot {
    // before < target < after < lastSwap so the search brackets the target strictly
    _beforeTimestamp = uint40(bound(_beforeTimestamp, 1, type(uint40).max - 3));
    _afterTimestamp = uint40(bound(_afterTimestamp, uint256(_beforeTimestamp) + 2, type(uint40).max - 1));
    _now = uint40(bound(_now, uint256(_afterTimestamp) + 1, type(uint40).max));

    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _setObservationTimestamp(0, _beforeTimestamp);
    _setObservationTimestamp(1, _afterTimestamp);
    _setAccumulatorSlot1({
      _lastSwapTimestamp: _now,
      _lastObservationTimestamp: 0,
      _swapCount: 0,
      _lastTick: 0,
      _intervalMaxTick: 0,
      _intervalMinTick: 0,
      _intervalOpenTick: 0,
      _volatilityCorrob: 0
    });
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](1);
    _secondsAgos[0] = uint48(_now - (_beforeTimestamp + 1));

    // Every flag has a base of 10 SLOAD, the accumulator slot 1, the information slot, the timestamps the
    // search compares and the slot 1 of each bracketing observation. Each flag then adds its own slot on the
    // accumulator, which the slot two flag does not have.
    uint256[5] memory _expectedReads = [uint256(10), 11, 11, 11, 11];

    for (uint256 _i; _i < 5; ++_i) {
      vm.record();
      _tape.observe(_pool, _secondsAgos, _slotsFromMask(uint8(1 << _i)));
      (bytes32[] memory _reads,) = vm.accesses(address(_tape));

      // it performs exactly the expected storage reads for the requested slot
      assertEq(_reads.length, _expectedReads[_i]);
    }
  }

  function test_WhenRequestingIncrementallyMoreSlots(
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now
  ) external whenThePoolIsRegistered {
    _accumulator.lastSwapTimestamp = uint40(bound(_accumulator.lastSwapTimestamp, 1, type(uint40).max));
    _now = uint40(bound(_now, _accumulator.lastSwapTimestamp, type(uint40).max));
    _setAccumulator(_accumulator);
    _mockPoolOracle();
    _mockStakedCumulativeReads();
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](1);

    // Each step adds the next flag to the request starting from the slot 2 base, so the count grows
    // by exactly one per newly requested slot.
    // Each step adds the next flag to the request starting from the slot 2 base, so the count grows
    // by exactly one per newly requested slot.
    uint256[5] memory _expectedReads = [uint256(1), 2, 3, 4, 5];

    for (uint256 _i; _i < 5; ++_i) {
      vm.record();
      // the mask keeps the lowest flag bits set, slot 2 first then one more slot per step
      _tape.observe(_pool, _secondsAgos, _slotsFromMask(uint8((2 << _i) - 1)));
      (bytes32[] memory _reads,) = vm.accesses(address(_tape));

      // it performs exactly the expected storage reads for each cumulative request
      assertEq(_reads.length, _expectedReads[_i]);
    }
  }

  function test_WhenThePoolIsUnregistered(
    uint40 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB,
    address _unregistered,
    uint8 _mask
  ) external {
    vm.assume(_unregistered != _pool);
    ICLPoolTape.ObservationSlots memory _slots = _slotsFromMask(uint8(bound(_mask, 0, 31)));
    _now = uint40(bound(_now, 1, type(uint40).max));
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](2);
    _secondsAgos[0] = uint48(bound(_secondsAgoA, 0, _now));
    _secondsAgos[1] = uint48(bound(_secondsAgoB, 0, _now));

    ICLPoolTape.Observation[] memory _result = _tape.observe(_unregistered, _secondsAgos, _slots);

    // it returns zeroed observations
    assertEq(_result.length, _secondsAgos.length);
    ICLPoolTape.Observation memory _zeroed;
    for (uint256 _i; _i < _result.length; ++_i) {
      _assertObservationEq(_result[_i], _zeroed);
    }
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Builds an ObservationSlots from a five bit mask, one bit per flag.
  function _slotsFromMask(uint8 _mask) internal pure returns (ICLPoolTape.ObservationSlots memory _slots) {
    _slots.slot2 = _mask & 1 != 0;
    _slots.slot3 = _mask & 2 != 0;
    _slots.slot4 = _mask & 4 != 0;
    _slots.slot5 = _mask & 8 != 0;
    _slots.slot6 = _mask & 16 != 0;
  }

  /// @dev Mocks the pool obseve call
  function _mockPoolOracle() internal {
    int56[] memory _ticks = new int56[](1);
    uint160[] memory _spl = new uint160[](1);
    vm.mockCall(_pool, abi.encodeWithSelector(ICLPoolDerivedState.observe.selector), abi.encode(_ticks, _spl));
  }

  /// @dev Mocks the live and settled staked cumulative values from the pool
  function _mockStakedCumulativeReads() internal {
    vm.mockCall(
      _pool,
      abi.encodeWithSelector(ICLPoolDerivedState.getSecondsPerStakedLiquidityCumulativeX128.selector),
      abi.encode(uint160(0))
    );
    vm.mockCall(_pool, abi.encodeWithSelector(ICLPoolState.lastUpdated.selector), abi.encode(uint48(0)));
    vm.mockCall(
      _pool,
      abi.encodeWithSelector(ICLPoolState.secondsPerStakedLiquidityCumulativeX128.selector),
      abi.encode(uint160(0))
    );
  }

  /// @dev Seeds two committed observations bracketing the fuzzed window plus an accumulator newer than both,
  ///      warps to `_now` and returns two bounded secondsAgos. Mirrors the fixture of the unmasked observe suite.
  function _seedBracketedScenario(
    ICLPoolTape.Observation memory _before,
    ICLPoolTape.Observation memory _after,
    ICLPoolTape.Accumulator memory _accumulator,
    uint40 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB
  ) internal returns (uint48[] memory _secondsAgos) {
    // before < after < lastSwap <= now
    _before.blockTimestamp = uint40(bound(_before.blockTimestamp, 1, type(uint40).max - 2));
    _after.blockTimestamp =
      uint40(bound(_after.blockTimestamp, uint256(_before.blockTimestamp) + 1, type(uint40).max - 1));
    _accumulator.lastSwapTimestamp =
      uint40(bound(_accumulator.lastSwapTimestamp, uint256(_after.blockTimestamp) + 1, type(uint40).max));
    _now = uint40(bound(_now, _accumulator.lastSwapTimestamp, type(uint40).max));

    // before <= after <= accumulator for every interpolated field
    _after.cumulativeVolume0 = uint120(bound(_after.cumulativeVolume0, _before.cumulativeVolume0, type(uint120).max));
    _after.cumulativeVolume1 = uint120(bound(_after.cumulativeVolume1, _before.cumulativeVolume1, type(uint120).max));
    _after.cumulativeFee0 = uint120(bound(_after.cumulativeFee0, _before.cumulativeFee0, type(uint120).max));
    _after.cumulativeFee1 = uint120(bound(_after.cumulativeFee1, _before.cumulativeFee1, type(uint120).max));
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
    _accumulator.cumulativeVolume0 =
      uint120(bound(_accumulator.cumulativeVolume0, _after.cumulativeVolume0, type(uint120).max));
    _accumulator.cumulativeVolume1 =
      uint120(bound(_accumulator.cumulativeVolume1, _after.cumulativeVolume1, type(uint120).max));
    _accumulator.cumulativeFee0 = uint120(bound(_accumulator.cumulativeFee0, _after.cumulativeFee0, type(uint120).max));
    _accumulator.cumulativeFee1 = uint120(bound(_accumulator.cumulativeFee1, _after.cumulativeFee1, type(uint120).max));
    _accumulator.cumulativeMevVolume0 =
      uint120(bound(_accumulator.cumulativeMevVolume0, _after.cumulativeMevVolume0, type(uint120).max));
    _accumulator.cumulativeMevVolume1 =
      uint120(bound(_accumulator.cumulativeMevVolume1, _after.cumulativeMevVolume1, type(uint120).max));
    _accumulator.cumulativeMevFee0 =
      uint120(bound(_accumulator.cumulativeMevFee0, _after.cumulativeMevFee0, type(uint120).max));
    _accumulator.cumulativeMevFee1 =
      uint120(bound(_accumulator.cumulativeMevFee1, _after.cumulativeMevFee1, type(uint120).max));
    _accumulator.swapCount = uint32(bound(_accumulator.swapCount, _after.swapCount, type(uint32).max));

    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _setObservation(0, _before);
    _setObservation(1, _after);
    _setAccumulator(_accumulator);

    // Targets past the last swap trigger the external pool fetches, mock them like the unmasked observe suite does.
    _mockPoolOracle();
    _mockStakedCumulativeReads();

    vm.warp(_now);

    _secondsAgos = new uint48[](2);
    _secondsAgos[0] = uint48(bound(_secondsAgoA, 0, _now));
    _secondsAgos[1] = uint48(bound(_secondsAgoB, 0, _now));
  }

  /// @dev Requested slots must equal the unmasked result and unrequested slots must be zero.
  function _assertMaskedObservation(
    ICLPoolTape.Observation memory _masked,
    ICLPoolTape.Observation memory _unmasked,
    ICLPoolTape.ObservationSlots memory _slots
  ) internal pure {
    assertEq(_masked.secondsPerLiquidityCumulativeX128, _slots.slot2 ? _unmasked.secondsPerLiquidityCumulativeX128 : 0);
    assertEq(_masked.volatilityCorrob, _slots.slot2 ? _unmasked.volatilityCorrob : 0);
    assertEq(_masked.cumulativeVolume0, _slots.slot3 ? _unmasked.cumulativeVolume0 : 0);
    assertEq(_masked.cumulativeVolume1, _slots.slot3 ? _unmasked.cumulativeVolume1 : 0);
    assertEq(_masked.cumulativeFee0, _slots.slot4 ? _unmasked.cumulativeFee0 : 0);
    assertEq(_masked.cumulativeFee1, _slots.slot4 ? _unmasked.cumulativeFee1 : 0);
    assertEq(_masked.cumulativeMevVolume0, _slots.slot5 ? _unmasked.cumulativeMevVolume0 : 0);
    assertEq(_masked.cumulativeMevVolume1, _slots.slot5 ? _unmasked.cumulativeMevVolume1 : 0);
    assertEq(_masked.cumulativeMevFee0, _slots.slot6 ? _unmasked.cumulativeMevFee0 : 0);
    assertEq(_masked.cumulativeMevFee1, _slots.slot6 ? _unmasked.cumulativeMevFee1 : 0);
  }

  /// @dev Validates each field to the expected observation.
  function _assertObservationEq(
    ICLPoolTape.Observation memory _actual,
    ICLPoolTape.Observation memory _expected
  ) internal pure {
    assertEq(_actual.secondsPerStakedLiquidityCumulativeX128, _expected.secondsPerStakedLiquidityCumulativeX128);
    assertEq(_actual.blockTimestamp, _expected.blockTimestamp);
    assertEq(_actual.swapCount, _expected.swapCount);
    assertEq(_actual.secondsPerLiquidityCumulativeX128, _expected.secondsPerLiquidityCumulativeX128);
    assertEq(_actual.closeTick, _expected.closeTick);
    assertEq(_actual.volatilityCorrob, _expected.volatilityCorrob);
    assertEq(_actual.cumulativeVolume0, _expected.cumulativeVolume0);
    assertEq(_actual.cumulativeVolume1, _expected.cumulativeVolume1);
    assertEq(_actual.cumulativeFee0, _expected.cumulativeFee0);
    assertEq(_actual.cumulativeFee1, _expected.cumulativeFee1);
    assertEq(_actual.cumulativeMevVolume0, _expected.cumulativeMevVolume0);
    assertEq(_actual.cumulativeMevVolume1, _expected.cumulativeMevVolume1);
    assertEq(_actual.cumulativeMevFee0, _expected.cumulativeMevFee0);
    assertEq(_actual.cumulativeMevFee1, _expected.cumulativeMevFee1);
  }
}
