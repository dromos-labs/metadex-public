// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';

import {UnitClPoolTapeBase} from 'V3-test/unit/pools/tape/CLPoolTape/CLPoolTapeBase.t.sol';

contract UnitClPoolTapeIncreaseObservationCardinalityNext is UnitClPoolTapeBase {
  uint256 private constant _TARGET_MAX_FUZZ = 1000;

  modifier whenTheBufferCardinalityEqZero() {
    _;
  }

  function test_WhenTheNewCardinalityNextIsLtOrEqToOne(
    uint40 _blockTimestamp,
    uint16 _target
  ) external whenTheBufferCardinalityEqZero {
    _blockTimestamp = uint40(bound(_blockTimestamp, 1, type(uint40).max));
    _target = uint16(bound(_target, 0, 1));
    _setObservationInformationSlot({_index: 0, _cardinality: 0, _cardinalityNext: 0});
    vm.warp(_blockTimestamp);

    // it emits PoolObservationBufferInitialized
    vm.expectEmit();
    emit IBasePoolTape.PoolObservationBufferInitialized(_pool, uint48(_blockTimestamp));
    _tape.increaseObservationCardinalityNext(_pool, _target);

    (, uint16 _cardinality, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    // it sets cardinality to one
    assertEq(_cardinality, 1);
    // it sets cardinalityNext to one
    assertEq(_cardinalityNext, 1);
  }

  function test_WhenTheNewCardinalityNextIsGtOne(
    uint40 _blockTimestamp,
    uint16 _target
  ) external whenTheBufferCardinalityEqZero {
    _blockTimestamp = uint40(bound(_blockTimestamp, 1, type(uint40).max));
    _target = uint16(bound(_target, 2, _TARGET_MAX_FUZZ));
    _setObservationInformationSlot({_index: 0, _cardinality: 0, _cardinalityNext: 0});
    vm.warp(_blockTimestamp);

    // it emits PoolObservationBufferInitialized
    vm.expectEmit();
    emit IBasePoolTape.PoolObservationBufferInitialized(_pool, uint48(_blockTimestamp));
    // it emits ObservationCardinalityIncreased
    vm.expectEmit();
    emit IBasePoolTape.ObservationCardinalityIncreased(_pool, 1, _target);
    vm.record();
    _tape.increaseObservationCardinalityNext(_pool, _target);
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    (, uint16 _cardinality, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    // it sets cardinality to one
    assertEq(_cardinality, 1);
    // it raises cardinalityNext to the new target
    assertEq(_cardinalityNext, _target);
    // it pre warms every storage slot of each new entry
    assertTrue(_isPopulated(_target - 1));
    // it writes the new entry slots and the initialization and cardinalityNext slots
    assertEq(_writes.length, uint256(_target - 1) * _SLOTS_PER_OBSERVATION + 2);
  }

  modifier whenTheBufferCardinalityGtZero() {
    _;
  }

  function test_WhenTheNewCardinalityNextIsLtOrEqToTheCurrentCardinalityNext(
    uint16 _cardinality,
    uint16 _currentCardinalityNext,
    uint16 _target
  ) external whenTheBufferCardinalityGtZero {
    _currentCardinalityNext = uint16(bound(_currentCardinalityNext, 1, type(uint16).max));
    _cardinality = uint16(bound(_cardinality, 1, _currentCardinalityNext));
    _target = uint16(bound(_target, 0, _currentCardinalityNext));
    _setObservationInformationSlot({_index: 0, _cardinality: _cardinality, _cardinalityNext: _currentCardinalityNext});

    _tape.increaseObservationCardinalityNext(_pool, _target);

    (,, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    // it leaves cardinalityNext unchanged
    assertEq(_cardinalityNext, _currentCardinalityNext);
  }

  function test_WhenTheNewCardinalityNextIsGtTheCurrentCardinalityNext(
    uint16 _cardinality,
    uint16 _currentCardinalityNext,
    uint16 _target
  ) external whenTheBufferCardinalityGtZero {
    _currentCardinalityNext = uint16(
      bound(_currentCardinalityNext, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 5500, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE - 1)
    );
    _cardinality = uint16(bound(_cardinality, 1, _currentCardinalityNext));
    _target = uint16(bound(_target, _currentCardinalityNext + 1, _OBSERVATIONS_CIRCULAR_BUFFER_SIZE));
    _setObservationInformationSlot({_index: 0, _cardinality: _cardinality, _cardinalityNext: _currentCardinalityNext});

    // it emits ObservationCardinalityIncreased
    vm.expectEmit();
    emit IBasePoolTape.ObservationCardinalityIncreased(_pool, _currentCardinalityNext, _target);
    vm.record();
    _tape.increaseObservationCardinalityNext(_pool, _target);
    (, bytes32[] memory _writes) = vm.accesses(address(_tape));

    (,, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    // it raises cardinalityNext to the new target
    assertEq(_cardinalityNext, _target);
    // it pre warms every storage slot of each new entry
    assertTrue(_isPopulated(_target - 1));
    // it writes only the new entry slots and the cardinalityNext slot
    assertEq(_writes.length, uint256(_target - _currentCardinalityNext) * _SLOTS_PER_OBSERVATION + 1);
  }
}
