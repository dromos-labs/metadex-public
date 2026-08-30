// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolState} from 'V3/interfaces/pools/ICLPoolState.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';
import {CLPoolTape} from 'V3/pools/tape/CLPoolTape.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitClPoolTapeBase is TestHelpers {
  uint32 internal constant _DEFAULT_CADENCE = 60;
  uint16 internal constant _OBSERVATIONS_CIRCULAR_BUFFER_SIZE = 65_535;
  uint256 internal constant _SLOTS_PER_OBSERVATION = 6;
  uint256 internal constant _BUFFERS_SLOT = 4;
  uint256 internal constant _ACCUMULATORS_SLOT = 5;
  uint256 internal constant _VOLATILITY_RINGS_SLOT = 6;
  int24 internal constant _MIN_TICK = -887_272;
  int24 internal constant _MAX_TICK = 887_272;

  CLPoolTape internal _tape;
  address internal _owner = makeAddr('owner');
  address internal _caller = makeAddr('caller');
  address internal _elasticFeeModule = makeAddr('elasticFeeModule');
  address internal _pool = makeAddr('pool');

  function setUp() public virtual {
    _tape = _deployTape(_owner, _DEFAULT_CADENCE);
    vm.startPrank(_owner);
    _tape.setAllowedCallerAndInitializePool(_pool, _caller);
    _tape.setElasticFeeModule(_elasticFeeModule);
    vm.stopPrank();
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _mockPoolSecondsPerLiquidityCumulativeX128(
    address _poolAddress,
    uint160 _secondsPerLiquidityCumulativeX128,
    uint32 _secondsAgo
  ) internal {
    int56[] memory _ticks = new int56[](1);
    uint160[] memory _spl = new uint160[](1);
    _spl[0] = _secondsPerLiquidityCumulativeX128;
    uint32[] memory _secondsAgos = new uint32[](1);
    _secondsAgos[0] = _secondsAgo;
    _mockAndExpect(
      _poolAddress, abi.encodeWithSelector(ICLPoolDerivedState.observe.selector, _secondsAgos), abi.encode(_ticks, _spl)
    );
  }

  /// @dev Mocks the pool oracle failing on an old timestamp it has dropped
  function _mockPoolObserveRevert(address _poolAddress, uint32 _secondsAgo, bytes memory _revertData) internal {
    uint32[] memory _secondsAgos = new uint32[](1);
    _secondsAgos[0] = _secondsAgo;
    vm.mockCallRevert(
      _poolAddress, abi.encodeWithSelector(ICLPoolDerivedState.observe.selector, _secondsAgos), _revertData
    );
  }

  function _mockPoolStakedCumulative(address _poolAddress, uint160 _cumulative) internal {
    _mockAndExpect(
      _poolAddress,
      abi.encodeWithSelector(ICLPoolDerivedState.getSecondsPerStakedLiquidityCumulativeX128.selector),
      abi.encode(_cumulative)
    );
  }

  /// @dev Mocks the secondsPerStakedLiquidityCumulativeX128 and lastUpdated values from the pool
  function _mockPoolSettlement(address _poolAddress, uint48 _lastUpdated, uint160 _stored) internal {
    _mockAndExpect(_poolAddress, abi.encodeWithSelector(ICLPoolState.lastUpdated.selector), abi.encode(_lastUpdated));
    _mockAndExpect(
      _poolAddress,
      abi.encodeWithSelector(ICLPoolState.secondsPerStakedLiquidityCumulativeX128.selector),
      abi.encode(_stored)
    );
  }

  function _observationBufferBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _BUFFERS_SLOT)));
  }

  function _accumulatorBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _ACCUMULATORS_SLOT)));
  }

  function _volatilityRingBase() internal view returns (uint256 _base) {
    _base = uint256(keccak256(abi.encode(_pool, _VOLATILITY_RINGS_SLOT)));
  }

  function _setObservationInformationSlot(uint16 _index, uint16 _cardinality, uint16 _cardinalityNext) internal {
    uint256 _slot = _observationBufferBase() + 65_535 * _SLOTS_PER_OBSERVATION;
    uint256 _packed = uint256(_index) | (uint256(_cardinality) << 16) | (uint256(_cardinalityNext) << 32);
    vm.store(address(_tape), bytes32(_slot), bytes32(_packed));
  }

  function _setObservationTimestamp(uint16 _index, uint40 _blockTimestamp) internal {
    uint256 _slot = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION;
    vm.store(address(_tape), bytes32(_slot), bytes32(uint256(_blockTimestamp) << 160));
  }

  function _setObservation(uint16 _index, ICLPoolTape.Observation memory _observation) internal {
    uint256 _base = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION;
    vm.store(
      address(_tape),
      bytes32(_base),
      bytes32(
        uint256(_observation.secondsPerStakedLiquidityCumulativeX128) | (uint256(_observation.blockTimestamp) << 160)
          | (uint256(_observation.swapCount) << 200) | (uint256(uint24(_observation.closeTick)) << 232)
      )
    );
    vm.store(
      address(_tape),
      bytes32(_base + 1),
      bytes32(uint256(_observation.secondsPerLiquidityCumulativeX128) | (uint256(_observation.volatilityCorrob) << 160))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 2),
      bytes32(uint256(_observation.cumulativeVolume0) | (uint256(_observation.cumulativeVolume1) << 120))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 3),
      bytes32(uint256(_observation.cumulativeFee0) | (uint256(_observation.cumulativeFee1) << 120))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 4),
      bytes32(uint256(_observation.cumulativeMevVolume0) | (uint256(_observation.cumulativeMevVolume1) << 120))
    );
    vm.store(
      address(_tape),
      bytes32(_base + 5),
      bytes32(uint256(_observation.cumulativeMevFee0) | (uint256(_observation.cumulativeMevFee1) << 120))
    );
  }

  /// @dev Seeds the four packed cumulative slots (volume, fee, mev volume, mev fee) with `_value`.
  function _setAccumulatorCumulatives(uint120 _value) internal {
    uint256 _base = _accumulatorBase();
    bytes32 _packed = bytes32(uint256(_value) | (uint256(_value) << 120));
    vm.store(address(_tape), bytes32(_base + 1), _packed);
    vm.store(address(_tape), bytes32(_base + 2), _packed);
    vm.store(address(_tape), bytes32(_base + 3), _packed);
    vm.store(address(_tape), bytes32(_base + 4), _packed);
  }

  /// @dev Writes every field of `_accumulators[_pool]` directly to storage.
  function _setAccumulator(ICLPoolTape.Accumulator memory _accumulator) internal {
    uint256 _base = _accumulatorBase();
    vm.store(
      address(_tape),
      bytes32(_base),
      bytes32(
        uint256(_accumulator.lastSwapTimestamp) | (uint256(_accumulator.lastObservationTimestamp) << 40)
          | (uint256(_accumulator.swapCount) << 80) | (uint256(uint24(_accumulator.lastTick)) << 112)
          | (uint256(uint24(_accumulator.intervalMaxTick)) << 136)
          | (uint256(uint24(_accumulator.intervalMinTick)) << 160)
          | (uint256(uint24(_accumulator.intervalOpenTick)) << 184) | (uint256(_accumulator.volatilityCorrob) << 208)
      )
    );
    vm.store(
      address(_tape),
      bytes32(_base + 1),
      bytes32(
        uint256(_accumulator.cumulativeVolume0) | (uint256(_accumulator.cumulativeVolume1) << 120)
          | (uint256(_accumulator.intervalSwapCount) << 240)
      )
    );
    vm.store(
      address(_tape),
      bytes32(_base + 2),
      bytes32(
        uint256(_accumulator.cumulativeFee0) | (uint256(_accumulator.cumulativeFee1) << 120)
          | (uint256(_accumulator.volatilityRingHead) << 240) | (uint256(_accumulator.volatilityRingCount) << 248)
      )
    );
    vm.store(
      address(_tape),
      bytes32(_base + 3),
      bytes32(
        uint256(_accumulator.cumulativeMevVolume0) | (uint256(_accumulator.cumulativeMevVolume1) << 120)
          | (uint256(_accumulator.nOver) << 240)
      )
    );
    vm.store(
      address(_tape),
      bytes32(_base + 4),
      bytes32(uint256(_accumulator.cumulativeMevFee0) | (uint256(_accumulator.cumulativeMevFee1) << 120))
    );
  }

  /// @dev Seeds accumulator slot 1: lastSwapTimestamp, lastObservationTimestamp, swapCount, lastTick,
  ///      intervalMaxTick, intervalMinTick, intervalOpenTick, volatilityCorrob
  ///      (bit offsets 0, 40, 80, 112, 136, 160, 184, 208).
  function _setAccumulatorSlot1(
    uint40 _lastSwapTimestamp,
    uint40 _lastObservationTimestamp,
    uint32 _swapCount,
    int24 _lastTick,
    int24 _intervalMaxTick,
    int24 _intervalMinTick,
    int24 _intervalOpenTick,
    uint48 _volatilityCorrob
  ) internal {
    uint256 _packed = uint256(_lastSwapTimestamp) | (uint256(_lastObservationTimestamp) << 40)
      | (uint256(_swapCount) << 80) | (uint256(uint24(_lastTick)) << 112) | (uint256(uint24(_intervalMaxTick)) << 136)
      | (uint256(uint24(_intervalMinTick)) << 160) | (uint256(uint24(_intervalOpenTick)) << 184)
      | (uint256(_volatilityCorrob) << 208);
    vm.store(address(_tape), bytes32(_accumulatorBase()), bytes32(_packed));
  }

  /// @dev Sets a whole slot of the volatility ring.
  function _setVolatilityRingSlot(uint256 _slotIndex, uint256 _value) internal {
    vm.store(address(_tape), bytes32(_volatilityRingBase() + _slotIndex), bytes32(_value));
  }

  /// @dev True when every storage slot of observations[_index] is non-zero (pre-warmed).
  function _isPopulated(uint16 _index) internal view returns (bool) {
    uint256 _slot = _observationBufferBase() + uint256(_index) * _SLOTS_PER_OBSERVATION;
    for (uint256 _i; _i < _SLOTS_PER_OBSERVATION; ++_i) {
      if (uint256(vm.load(address(_tape), bytes32(_slot + _i))) == 0) return false;
    }
    return true;
  }

  function _setPoolConfig(address _configCaller, uint32 _cadence) internal {
    uint256 _slot = uint256(keccak256(abi.encode(_pool, uint256(2))));
    vm.store(address(_tape), bytes32(_slot), bytes32(uint256(uint160(_configCaller)) | (uint256(_cadence) << 160)));
  }

  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal virtual returns (CLPoolTape) {
    return new CLPoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
