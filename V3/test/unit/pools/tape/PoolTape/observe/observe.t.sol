// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract UnitPoolTapeObserve is UnitPoolTapeBase {
  modifier whenThePoolIsRegistered() {
    _;
  }

  function test_WhenTheArrayIsEmpty() external view whenThePoolIsRegistered {
    uint48[] memory _secondsAgos = new uint48[](0);
    IPoolTape.Observation[] memory _result = _tape.observe(_pool, _secondsAgos);
    // it returns an empty array
    assertEq(_result.length, 0);
  }

  function test_WhenTheArrayIsNotEmpty(
    IPoolTape.Observation memory _before,
    IPoolTape.Observation memory _after,
    IPoolTape.Accumulator memory _accumulator,
    uint48 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB
  ) external whenThePoolIsRegistered {
    // before < after < lastSwap <= now
    _before.blockTimestamp = uint48(bound(_before.blockTimestamp, 1, type(uint48).max - 2));
    _after.blockTimestamp =
      uint48(bound(_after.blockTimestamp, uint256(_before.blockTimestamp) + 1, type(uint48).max - 1));
    _accumulator.lastSwapTimestamp =
      uint48(bound(_accumulator.lastSwapTimestamp, uint256(_after.blockTimestamp) + 1, type(uint48).max));
    _now = uint48(bound(_now, _accumulator.lastSwapTimestamp, type(uint48).max));

    // values are before <= after <= accumulator.
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
    _accumulator.cumulativeFee0 = uint128(bound(_accumulator.cumulativeFee0, _after.cumulativeFee0, type(uint128).max));
    _accumulator.cumulativeFee1 = uint128(bound(_accumulator.cumulativeFee1, _after.cumulativeFee1, type(uint128).max));
    _accumulator.cumulativeVolume0 =
      uint128(bound(_accumulator.cumulativeVolume0, _after.cumulativeVolume0, type(uint128).max));
    _accumulator.cumulativeVolume1 =
      uint128(bound(_accumulator.cumulativeVolume1, _after.cumulativeVolume1, type(uint128).max));
    _accumulator.cumulativeMevVolume0 =
      uint128(bound(_accumulator.cumulativeMevVolume0, _after.cumulativeMevVolume0, type(uint128).max));
    _accumulator.cumulativeMevVolume1 =
      uint128(bound(_accumulator.cumulativeMevVolume1, _after.cumulativeMevVolume1, type(uint128).max));
    _accumulator.cumulativeMevFee0 =
      uint128(bound(_accumulator.cumulativeMevFee0, _after.cumulativeMevFee0, type(uint128).max));
    _accumulator.cumulativeMevFee1 =
      uint128(bound(_accumulator.cumulativeMevFee1, _after.cumulativeMevFee1, type(uint128).max));
    _accumulator.swapCount = uint48(bound(_accumulator.swapCount, _after.swapCount, type(uint48).max));

    _setObservationInformationSlot({_index: 1, _cardinality: 2, _cardinalityNext: 2});
    _setObservation(0, _before);
    _setObservation(1, _after);
    _setAccumulator(_accumulator);

    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](2);
    _secondsAgos[0] = uint48(bound(_secondsAgoA, 0, _now));
    _secondsAgos[1] = uint48(bound(_secondsAgoB, 0, _now));

    IPoolTape.Observation[] memory _result = _tape.observe(_pool, _secondsAgos);

    // it returns the observation at each secondsAgo
    assertEq(_result.length, _secondsAgos.length);
    _assertObservationEq(_result[0], MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgos[0]));
    _assertObservationEq(_result[1], MockPoolTape(address(_tape)).externalObserveSingle(_pool, _secondsAgos[1]));
  }

  function test_WhenThePoolIsUnregistered(
    uint48 _now,
    uint48 _secondsAgoA,
    uint48 _secondsAgoB,
    address _unregistered
  ) external {
    _now = uint48(bound(_now, 1, type(uint48).max));
    vm.warp(_now);

    uint48[] memory _secondsAgos = new uint48[](2);
    _secondsAgos[0] = uint48(bound(_secondsAgoA, 0, _now));
    _secondsAgos[1] = uint48(bound(_secondsAgoB, 0, _now));

    IPoolTape.Observation[] memory _result = _tape.observe(_unregistered, _secondsAgos);

    // it returns zeroed observations
    assertEq(_result.length, _secondsAgos.length);
    for (uint256 _i; _i < _result.length; ++_i) {
      assertEq(_result[_i].cumulativeFee0, 0);
      assertEq(_result[_i].cumulativeFee1, 0);
      assertEq(_result[_i].cumulativeVolume0, 0);
      assertEq(_result[_i].cumulativeVolume1, 0);
      assertEq(_result[_i].cumulativeMevVolume0, 0);
      assertEq(_result[_i].cumulativeMevVolume1, 0);
      assertEq(_result[_i].cumulativeMevFee0, 0);
      assertEq(_result[_i].cumulativeMevFee1, 0);
      assertEq(_result[_i].swapCount, 0);
      assertEq(_result[_i].blockTimestamp, 0);
    }
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _assertObservationEq(
    IPoolTape.Observation memory _actual,
    IPoolTape.Observation memory _expected
  ) internal pure {
    assertEq(_actual.cumulativeFee0, _expected.cumulativeFee0);
    assertEq(_actual.cumulativeFee1, _expected.cumulativeFee1);
    assertEq(_actual.cumulativeVolume0, _expected.cumulativeVolume0);
    assertEq(_actual.cumulativeVolume1, _expected.cumulativeVolume1);
    assertEq(_actual.cumulativeMevVolume0, _expected.cumulativeMevVolume0);
    assertEq(_actual.cumulativeMevVolume1, _expected.cumulativeMevVolume1);
    assertEq(_actual.cumulativeMevFee0, _expected.cumulativeMevFee0);
    assertEq(_actual.cumulativeMevFee1, _expected.cumulativeMevFee1);
    assertEq(_actual.blockTimestamp, _expected.blockTimestamp);
    assertEq(_actual.swapCount, _expected.swapCount);
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (PoolTape) {
    return new MockPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
