// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';

import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';

contract UnitPoolTapeRecord is UnitPoolTapeBase {
  function test_WhenCallerIsNotInAllowedCallerMap(address _invalidCaller) external {
    vm.assume(_invalidCaller != _caller);
    // it reverts with Unauthorized
    vm.expectRevert(IBasePoolTape.Unauthorized.selector);
    vm.prank(_invalidCaller);
    _tape.record(_pool, _poolTapeData(1));
  }

  modifier whenCallerIsInAllowedCallerMap() {
    _;
  }

  function test_WhenRecordingTheFirstSwap(
    uint128 _value,
    uint48 _blockTimestamp
  ) external whenCallerIsInAllowedCallerMap {
    _blockTimestamp = uint48(bound(_blockTimestamp, 1, type(uint48).max));
    vm.warp(_blockTimestamp);
    vm.prank(_caller);
    _tape.record(_pool, _poolTapeData(_value));

    IPoolTape.Accumulator memory _accumulator = _currentAccumulator();
    // it assigns every cumulative discarding the pre populated values
    assertEq(_accumulator.cumulativeFee0, _value);
    assertEq(_accumulator.cumulativeFee1, _value);
    assertEq(_accumulator.cumulativeVolume0, _value);
    assertEq(_accumulator.cumulativeVolume1, _value);
    assertEq(_accumulator.cumulativeMevVolume0, _value);
    assertEq(_accumulator.cumulativeMevVolume1, _value);
    assertEq(_accumulator.cumulativeMevFee0, _value);
    assertEq(_accumulator.cumulativeMevFee1, _value);
    // it sets swapCount to one
    assertEq(_accumulator.swapCount, 1);
    // it sets lastSwapTimestamp to the block timestamp
    assertEq(_accumulator.lastSwapTimestamp, _blockTimestamp);
  }

  function test_WhenRecordingASubsequentSwap(
    uint128 _existingValue,
    uint128 _value,
    uint48 _existingSwapCount,
    uint48 _blockTimestamp
  ) external whenCallerIsInAllowedCallerMap {
    _blockTimestamp = uint48(bound(_blockTimestamp, 1, _DEFAULT_CADENCE));
    // initializes the buffer so we can assert the exact number of accumulator writes
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setAccumulator(_buildAccumulator(_existingValue, _existingSwapCount));
    vm.warp(_blockTimestamp);
    vm.record();
    vm.prank(_caller);
    _tape.record(_pool, _poolTapeData(_value));
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    IPoolTape.Accumulator memory _accumulator = _currentAccumulator();
    uint128 _expectedCumulative;
    uint48 _expectedSwapCount;
    unchecked {
      _expectedCumulative = _existingValue + _value;
      _expectedSwapCount = _existingSwapCount + 1;
    }
    // it adds every cumulative delta to the accumulator
    assertEq(_accumulator.cumulativeFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeFee1, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevVolume1, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee0, _expectedCumulative);
    assertEq(_accumulator.cumulativeMevFee1, _expectedCumulative);
    // it increments swapCount by one
    assertEq(_accumulator.swapCount, _expectedSwapCount);
    // it sets lastSwapTimestamp to the block timestamp
    assertEq(_accumulator.lastSwapTimestamp, _blockTimestamp);
    // it writes only the five accumulator slots
    assertEq(_writes.length, 5);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _poolTapeData(uint128 _value) internal pure returns (IPoolTape.PoolTapeData memory _data) {
    _data = IPoolTape.PoolTapeData({
      fee0: _value,
      fee1: _value,
      volume0: _value,
      volume1: _value,
      mevVolume0: _value,
      mevVolume1: _value,
      mevFee0: _value,
      mevFee1: _value
    });
  }

  function _buildAccumulator(
    uint128 _value,
    uint48 _swapCount
  ) internal pure returns (IPoolTape.Accumulator memory _data) {
    _data = IPoolTape.Accumulator({
      cumulativeFee0: _value,
      cumulativeFee1: _value,
      cumulativeVolume0: _value,
      cumulativeVolume1: _value,
      cumulativeMevVolume0: _value,
      cumulativeMevVolume1: _value,
      cumulativeMevFee0: _value,
      cumulativeMevFee1: _value,
      // a non zero timestamp puts record on the subsequent swap branch
      lastSwapTimestamp: 1,
      swapCount: _swapCount
    });
  }
}
