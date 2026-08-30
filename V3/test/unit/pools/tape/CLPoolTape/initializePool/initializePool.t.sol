// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockCLPoolTape} from 'V3-test/mocks/MockCLPoolTape.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

contract UnitClPoolTapeInitializePool is TestHelpers {
  uint32 internal constant _DEFAULT_CADENCE = 60;
  uint16 internal constant _OBSERVATIONS_CIRCULAR_BUFFER_SIZE = 65_535;
  uint256 internal constant _SLOTS_PER_OBSERVATION = 6;
  uint256 internal constant _SLOTS_PER_ACCUMULATOR = 5;
  uint256 internal constant _ACCUMULATORS_SLOT = 5;
  uint256 internal constant _BUFFERS_SLOT = 4;
  uint256 internal constant _LAST_SWAP_TIMESTAMP_SLOT = 0;

  MockCLPoolTape internal _tape;
  address internal _pool = makeAddr('pool');

  function setUp() public {
    _tape = new MockCLPoolTape(makeAddr('owner'), _DEFAULT_CADENCE);
  }

  modifier whenTheAccumulatorHasNotBeenInitialized() {
    _;
  }

  function test_WhenTheAccumulatorHasNotBeenInitialized(
    uint48 _volatilityCorrob,
    uint8 _nOver
  ) external whenTheAccumulatorHasNotBeenInitialized {
    uint256 _base = _accumulatorBase();
    vm.store(address(_tape), bytes32(_base), bytes32(uint256(_volatilityCorrob) << 208));
    vm.store(address(_tape), bytes32(_base + 3), bytes32(uint256(_nOver) << 240));

    _tape.externalInitializePool(_pool);

    // it pre populates the accumulator slots
    for (uint256 _i; _i < _SLOTS_PER_ACCUMULATOR; ++_i) {
      assertNotEq(uint256(vm.load(address(_tape), bytes32(_base + _i))), 0);
    }
    ICLPoolTape.Accumulator memory _accumulator = _tape.accumulators(_pool);
    assertEq(_accumulator.lastObservationTimestamp, 1);
    assertEq(_accumulator.cumulativeMevVolume0, 1);

    // it pre warms the observation zero slots written by the first swap
    assertNotEq(uint256(vm.load(address(_tape), bytes32(_observationZeroSlot(0)))), 0);
    assertNotEq(uint256(vm.load(address(_tape), bytes32(_observationZeroSlot(1)))), 0);
    for (uint256 _i = 2; _i < _SLOTS_PER_OBSERVATION; ++_i) {
      assertEq(uint256(vm.load(address(_tape), bytes32(_observationZeroSlot(_i)))), 0);
    }

    // it does not set lastSwapTimestamp
    assertEq(uint40(uint256(vm.load(address(_tape), bytes32(_base + _LAST_SWAP_TIMESTAMP_SLOT)))), 0);

    // it preserves the volatility values written before registration
    assertEq(_accumulator.volatilityCorrob, _volatilityCorrob);
    assertEq(_accumulator.nOver, _nOver);
  }

  function test_WhenThePoolBufferHasNotBeenInitialized() external whenTheAccumulatorHasNotBeenInitialized {
    _tape.externalInitializePool(_pool);

    // it initializes the pool buffer
    (uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    assertEq(_index, 0);
    assertEq(_cardinality, 1);
    assertEq(_cardinalityNext, 1);
  }

  function test_WhenThePoolBufferHasBeenInitialized(uint16 _cardinalityNext)
    external
    whenTheAccumulatorHasNotBeenInitialized
  {
    _cardinalityNext = uint16(bound(_cardinalityNext, 1, type(uint16).max));
    _setBufferInformationSlot({_index: 0, _cardinality: 1, _cardinalityNext: _cardinalityNext});

    _tape.externalInitializePool(_pool);

    // it does not update the pool buffer
    (uint16 _index, uint16 _cardinality, uint16 _newCardinalityNext) = _tape.observationBuffers(_pool);
    assertEq(_index, 0);
    assertEq(_cardinality, 1);
    assertEq(_newCardinalityNext, _cardinalityNext);
  }

  function test_WhenTheAccumulatorHasBeenInitialized(uint80 _guard) external {
    _guard = uint80(bound(_guard, 1, type(uint80).max));
    uint256 _base = _accumulatorBase();
    bytes32 _slotValue = bytes32(uint256(_guard));
    vm.store(address(_tape), bytes32(_base + _LAST_SWAP_TIMESTAMP_SLOT), _slotValue);

    _tape.externalInitializePool(_pool);

    // it does not update the accumulator
    assertEq(vm.load(address(_tape), bytes32(_base + _LAST_SWAP_TIMESTAMP_SLOT)), _slotValue);
    for (uint256 _i; _i < _SLOTS_PER_ACCUMULATOR; ++_i) {
      if (_i == _LAST_SWAP_TIMESTAMP_SLOT) continue;
      assertEq(uint256(vm.load(address(_tape), bytes32(_base + _i))), 0);
    }

    // it does not update the pool buffer
    (uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    assertEq(_index, 0);
    assertEq(_cardinality, 0);
    assertEq(_cardinalityNext, 0);
    for (uint256 _i; _i < _SLOTS_PER_OBSERVATION; ++_i) {
      assertEq(uint256(vm.load(address(_tape), bytes32(_observationZeroSlot(_i)))), 0);
    }
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _accumulatorBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _ACCUMULATORS_SLOT)));
  }

  function _observationZeroSlot(uint256 _offset) internal view returns (uint256 _slot) {
    _slot = uint256(keccak256(abi.encode(_pool, _BUFFERS_SLOT))) + _offset;
  }

  function _setBufferInformationSlot(uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) internal {
    uint256 _slot = uint256(keccak256(abi.encode(_pool, _BUFFERS_SLOT))) + _OBSERVATIONS_CIRCULAR_BUFFER_SIZE
      * _SLOTS_PER_OBSERVATION;
    uint256 _packed = uint256(_index) | (uint256(_cardinality) << 16) | (uint256(_cardinalityNext) << 32);
    vm.store(address(_tape), bytes32(_slot), bytes32(_packed));
  }
}
