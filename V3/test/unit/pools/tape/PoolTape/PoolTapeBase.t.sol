// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitPoolTapeBase is TestHelpers {
  uint32 internal constant _DEFAULT_CADENCE = 60;
  uint256 internal constant _ACCUMULATORS_SLOT = 3;
  uint256 internal constant _BUFFERS_SLOT = 4;
  uint16 internal constant _OBSERVATIONS_CIRCULAR_BUFFER_SIZE = 65_535;
  uint256 internal constant _SLOTS_PER_OBSERVATION = 5;

  PoolTape internal _tape;
  address internal _owner = makeAddr('owner');
  address internal _caller = makeAddr('caller');
  address internal _pool = makeAddr('pool');

  function setUp() public {
    _tape = _deployTape(_owner, _DEFAULT_CADENCE);
    vm.prank(_owner);
    _tape.setAllowedCallerAndInitializePool(_pool, _caller);
  }

  function _observationBufferBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _BUFFERS_SLOT)));
  }

  function _setObservationInformationSlot(uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) internal {
    uint256 _slot = _observationBufferBase() + 65_535 * _SLOTS_PER_OBSERVATION;
    uint256 _packed = uint256(_index) | (uint256(_cardinality) << 16) | (uint256(_cardinalityNext) << 32);
    vm.store(address(_tape), bytes32(_slot), bytes32(_packed));
  }

  function _setObservationTimestamp(uint16 _index, uint48 _blockTimestamp) internal {
    uint256 _slot = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION + 4;
    vm.store(address(_tape), bytes32(_slot), bytes32(uint256(_blockTimestamp)));
  }

  /// @dev Writes every field of `observations[_index]` directly to storage.
  function _setObservation(uint16 _index, IPoolTape.Observation memory _observation) internal {
    uint256 _base = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION;
    vm.store(
      address(_tape),
      bytes32(_base),
      bytes32(uint256(_observation.cumulativeFee0) | (uint256(_observation.cumulativeFee1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 1),
      bytes32(uint256(_observation.cumulativeVolume0) | (uint256(_observation.cumulativeVolume1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 2),
      bytes32(uint256(_observation.cumulativeMevVolume0) | (uint256(_observation.cumulativeMevVolume1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 3),
      bytes32(uint256(_observation.cumulativeMevFee0) | (uint256(_observation.cumulativeMevFee1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 4),
      bytes32(uint256(_observation.blockTimestamp) | (uint256(_observation.swapCount) << 48))
    );
  }

  function _accumulatorBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _ACCUMULATORS_SLOT)));
  }

  /// @dev Writes every field of `accumulators[_pool]` directly to storage.
  function _setAccumulator(IPoolTape.Accumulator memory _accumulator) internal {
    uint256 _base = _accumulatorBase();
    vm.store(
      address(_tape),
      bytes32(_base),
      bytes32(uint256(_accumulator.cumulativeFee0) | (uint256(_accumulator.cumulativeFee1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 1),
      bytes32(uint256(_accumulator.cumulativeVolume0) | (uint256(_accumulator.cumulativeVolume1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 2),
      bytes32(uint256(_accumulator.cumulativeMevVolume0) | (uint256(_accumulator.cumulativeMevVolume1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 3),
      bytes32(uint256(_accumulator.cumulativeMevFee0) | (uint256(_accumulator.cumulativeMevFee1) << 128))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 4),
      bytes32(uint256(_accumulator.lastSwapTimestamp) | (uint256(_accumulator.swapCount) << 48))
    );
  }

  /// @dev Reads `accumulators[_pool]` into a struct, mirroring `_setAccumulator`'s packing to prevent stack too deep errors.
  function _currentAccumulator() internal view returns (IPoolTape.Accumulator memory _accumulator) {
    uint256 _base = _accumulatorBase();
    uint256 _slot = uint256(vm.load(address(_tape), bytes32(_base)));
    _accumulator.cumulativeFee0 = uint128(_slot);
    _accumulator.cumulativeFee1 = uint128(_slot >> 128);
    _slot = uint256(vm.load(address(_tape), bytes32(_base + 1)));
    _accumulator.cumulativeVolume0 = uint128(_slot);
    _accumulator.cumulativeVolume1 = uint128(_slot >> 128);
    _slot = uint256(vm.load(address(_tape), bytes32(_base + 2)));
    _accumulator.cumulativeMevVolume0 = uint128(_slot);
    _accumulator.cumulativeMevVolume1 = uint128(_slot >> 128);
    _slot = uint256(vm.load(address(_tape), bytes32(_base + 3)));
    _accumulator.cumulativeMevFee0 = uint128(_slot);
    _accumulator.cumulativeMevFee1 = uint128(_slot >> 128);
    _slot = uint256(vm.load(address(_tape), bytes32(_base + 4)));
    _accumulator.lastSwapTimestamp = uint48(_slot);
    _accumulator.swapCount = uint48(_slot >> 48);
  }

  /// @dev True when every storage slot of `observations[_index]` is non-zero.
  function _isPopulated(uint16 _index) internal view returns (bool) {
    uint256 _slot = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION;
    for (uint256 _i; _i < _SLOTS_PER_OBSERVATION; ++_i) {
      if (uint256(vm.load(address(_tape), bytes32(_slot + _i))) == 0) return false;
    }
    return true;
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal virtual returns (PoolTape) {
    return new PoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
