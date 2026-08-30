// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {MockPoolTape} from 'V3-test/mocks/MockPoolTape.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitPoolTapeInitializePool is TestHelpers {
  uint32 internal constant _DEFAULT_CADENCE = 60;
  uint16 internal constant _OBSERVATIONS_CIRCULAR_BUFFER_SIZE = 65_535;
  uint256 internal constant _SLOTS_PER_OBSERVATION = 5;
  uint256 internal constant _SLOTS_PER_ACCUMULATOR = 5;
  uint256 internal constant _ACCUMULATORS_SLOT = 3;
  uint256 internal constant _BUFFERS_SLOT = 4;
  uint256 internal constant _LAST_SWAP_TIMESTAMP_SLOT = 4;

  MockPoolTape internal _tape;
  address internal _pool = makeAddr('pool');

  function setUp() public {
    _tape = new MockPoolTape(makeAddr('owner'), _DEFAULT_CADENCE);
  }

  modifier whenTheAccumulatorHasNotBeenInitialized() {
    _;
  }

  function test_WhenTheAccumulatorHasNotBeenInitialized() external whenTheAccumulatorHasNotBeenInitialized {
    uint256 _base = _accumulatorBase();

    _tape.externalInitializePool(_pool);

    // it pre populates the accumulator slots
    for (uint256 _i; _i < _SLOTS_PER_ACCUMULATOR; ++_i) {
      assertNotEq(uint256(vm.load(address(_tape), bytes32(_base + _i))), 0);
    }

    // it does not set lastSwapTimestamp
    assertEq(uint48(uint256(vm.load(address(_tape), bytes32(_base + _LAST_SWAP_TIMESTAMP_SLOT)))), 0);
  }

  function test_WhenThePoolBufferHasNotBeenInitialized(uint48 _now) external whenTheAccumulatorHasNotBeenInitialized {
    _now = uint48(bound(_now, 1, type(uint48).max));
    vm.warp(_now);

    _tape.externalInitializePool(_pool);

    // it initializes the pool buffer
    (uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) = _tape.observationBuffers(_pool);
    assertEq(_index, 0);
    assertEq(_cardinality, 1);
    assertEq(_cardinalityNext, 1);
    assertEq(_tape.getObservation(_pool, 0).blockTimestamp, _now);
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
    assertEq(_tape.getObservation(_pool, 0).blockTimestamp, 0);
  }

  function test_WhenTheAccumulatorHasBeenInitialized(uint96 _guard) external {
    _guard = uint96(bound(_guard, 1, type(uint96).max));
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
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _accumulatorBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _ACCUMULATORS_SLOT)));
  }

  function _setBufferInformationSlot(uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) internal {
    uint256 _slot = uint256(keccak256(abi.encode(_pool, _BUFFERS_SLOT))) + _OBSERVATIONS_CIRCULAR_BUFFER_SIZE
      * _SLOTS_PER_OBSERVATION;
    uint256 _packed = uint256(_index) | (uint256(_cardinality) << 16) | (uint256(_cardinalityNext) << 32);
    vm.store(address(_tape), bytes32(_slot), bytes32(_packed));
  }
}
