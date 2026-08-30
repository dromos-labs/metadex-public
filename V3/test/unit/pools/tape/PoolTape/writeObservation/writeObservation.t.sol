// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';
import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {UnitPoolTapeBase} from 'V3-test/unit/pools/tape/PoolTape/PoolTapeBase.t.sol';

contract UnitPoolTapeWriteObservation is UnitPoolTapeBase {
  function test_WhenItIsTheFirstSwap(uint48 _blockTimestamp) external {
    _blockTimestamp = uint48(bound(_blockTimestamp, 2, type(uint48).max));
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setObservationTimestamp({_index: 0, _blockTimestamp: 1});
    vm.warp(_blockTimestamp);

    MockPoolTape(address(_tape))
      .externalWriteObservation(
        _pool, _accumulator({_value: 1, _lastSwapTimestamp: 0}), _blockTimestamp, _DEFAULT_CADENCE
      );

    IPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    // it updates the block timestamp of slot zero to the swap timestamp
    assertEq(_obs.blockTimestamp, _blockTimestamp);
    // it does not commit a new observation
    assertEq(_obs.cumulativeFee0, 0);

    (uint16 _index, uint16 _cardinality,) = _tape.observationBuffers(_pool);
    // it does not increase cardinality
    assertEq(_cardinality, 1);
    // it does not increase index
    assertEq(_index, 0);
  }

  modifier whenItIsNotTheFirstSwap() {
    _;
  }

  function test_WhenTheElapsedTimeSinceTheLastObservationIsLtOrEqToTheCadenceInterval(uint48 _elapsedTime)
    external
    whenItIsNotTheFirstSwap
  {
    _elapsedTime = uint48(bound(_elapsedTime, 0, _DEFAULT_CADENCE));
    _setObservationInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: 1});
    _setObservationTimestamp({_index: 0, _blockTimestamp: 0});
    vm.warp(_elapsedTime);
    vm.record();
    MockPoolTape(address(_tape))
      .externalWriteObservation(_pool, _accumulator({_value: 1, _lastSwapTimestamp: 1}), _elapsedTime, _DEFAULT_CADENCE);
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    // it does not commit a new observation
    IPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    assertEq(_obs.cumulativeFee0, 0);

    (uint16 _index, uint16 _cardinality,) = _tape.observationBuffers(_pool);
    // it does not increase index
    assertEq(_index, 0);
    // it does not increase cardinality
    assertEq(_cardinality, 1);
    // it does not write to storage
    assertEq(_writes.length, 0);
  }

  modifier whenTheElapsedTimeSinceTheLastObservationIsGtTheCadenceInterval() {
    _;
  }

  function test_WhenTheBufferIsNotFull(
    uint128 _value,
    uint48 _elapsedTime,
    uint16 _currentCardinality,
    uint16 _currentCardinalityNext
  ) external whenItIsNotTheFirstSwap whenTheElapsedTimeSinceTheLastObservationIsGtTheCadenceInterval {
    _elapsedTime = uint48(bound(_elapsedTime, _DEFAULT_CADENCE + 1, type(uint48).max));
    _currentCardinality = uint16(bound(_currentCardinality, 1, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1));
    _currentCardinalityNext =
      uint16(bound(_currentCardinalityNext, _currentCardinality + 1, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    uint16 _currentIndex = _currentCardinality - 1;
    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinalityNext
    });
    _setObservationTimestamp({_index: _currentIndex, _blockTimestamp: 0});
    vm.warp(_elapsedTime);
    uint16 _expectedIndex = (_currentIndex + 1) % (_currentCardinality + 1);

    // it emits ObservationRecorded
    vm.expectEmit();
    emit IBasePoolTape.ObservationRecorded(_pool, _expectedIndex, _elapsedTime);
    MockPoolTape(address(_tape))
      .externalWriteObservation(
        _pool, _accumulator({_value: _value, _lastSwapTimestamp: 1}), _elapsedTime, _DEFAULT_CADENCE
      );

    (uint16 _index, uint16 _cardinality,) = _tape.observationBuffers(_pool);
    // it should increase cardinality by one
    assertEq(_cardinality, _currentCardinality + 1);
    // it should increase index by one modulo cardinality
    assertEq(_index, _expectedIndex);
    // it should write the new observation at the newly grown slot
    IPoolTape.Observation memory _obs = _tape.getObservation(_pool, _currentIndex + 1);
    assertEq(_obs.cumulativeFee0, _value);
    assertEq(_obs.cumulativeFee1, _value);
    assertEq(_obs.cumulativeVolume0, _value);
    assertEq(_obs.cumulativeVolume1, _value);
    assertEq(_obs.cumulativeMevVolume0, _value);
    assertEq(_obs.cumulativeMevVolume1, _value);
    assertEq(_obs.cumulativeMevFee0, _value);
    assertEq(_obs.cumulativeMevFee1, _value);
    assertEq(_obs.blockTimestamp, _elapsedTime);
    assertEq(_obs.swapCount, 1);
  }

  function test_WhenTheBufferIsFull(
    uint128 _value,
    uint48 _elapsedTime,
    uint16 _currentCardinality
  ) external whenItIsNotTheFirstSwap whenTheElapsedTimeSinceTheLastObservationIsGtTheCadenceInterval {
    _elapsedTime = uint48(bound(_elapsedTime, _DEFAULT_CADENCE + 1, type(uint48).max));
    // a full buffer has cardinalityNext equal to cardinality, so the commit wraps instead of growing
    _currentCardinality = uint16(bound(_currentCardinality, 2, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    uint16 _currentIndex = _currentCardinality - 1;
    _setObservationInformationSlot({
      _index: _currentIndex, _cardinality: _currentCardinality, _cardinalityNext: _currentCardinality
    });
    _setObservationTimestamp({_index: _currentIndex, _blockTimestamp: 0});
    vm.warp(_elapsedTime);

    // it emits ObservationRecorded
    vm.expectEmit();
    emit IBasePoolTape.ObservationRecorded(_pool, 0, _elapsedTime);
    MockPoolTape(address(_tape))
      .externalWriteObservation(
        _pool, _accumulator({_value: _value, _lastSwapTimestamp: 1}), _elapsedTime, _DEFAULT_CADENCE
      );

    (uint16 _index, uint16 _cardinality,) = _tape.observationBuffers(_pool);
    // it keeps the cardinality unchanged
    assertEq(_cardinality, _currentCardinality);
    // it wraps the index to zero
    assertEq(_index, 0);
    // it overwrites the first slot
    IPoolTape.Observation memory _obs = _tape.getObservation(_pool, 0);
    assertEq(_obs.cumulativeFee0, _value);
    assertEq(_obs.cumulativeFee1, _value);
    assertEq(_obs.cumulativeVolume0, _value);
    assertEq(_obs.cumulativeVolume1, _value);
    assertEq(_obs.cumulativeMevVolume0, _value);
    assertEq(_obs.cumulativeMevVolume1, _value);
    assertEq(_obs.cumulativeMevFee0, _value);
    assertEq(_obs.cumulativeMevFee1, _value);
    assertEq(_obs.blockTimestamp, _elapsedTime);
    assertEq(_obs.swapCount, 1);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Deploys `MockPoolTape` so the internal `_writeObservation` can be exercised directly.
  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (PoolTape) {
    return new MockPoolTape(_initialOwner, _defaultCadenceInterval);
  }

  function _accumulator(
    uint128 _value,
    uint48 _lastSwapTimestamp
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
      lastSwapTimestamp: _lastSwapTimestamp,
      swapCount: 1
    });
  }
}
