// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICLPoolTape
/// @notice Records and exposes per-swap cumulative metrics, tick state, and volatility inputs for CL pools.
interface ICLPoolTape {
  /*////////////////////////////////////////////////////////////
                            STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Per-pool running state updated on every swap.
  /// @param lastSwapTimestamp Timestamp of the most recent recorded swap.
  /// @param lastObservationTimestamp Timestamp of the most recently committed observation. Mirrored here so
  ///        the cadence check needs no buffer read.
  /// @param swapCount Cumulative swap count.
  /// @param lastTick The most recent swap tick. This value is committed as closeTick in the observation.
  /// @param intervalMaxTick Highest tick per interval. Set to the first swap tick when the interval starts and reset to lastTick when the observation is committed.
  /// @param intervalMinTick Lowest tick per interval. Set to the first swap tick when the interval starts and reset to lastTick when the observation is committed.
  /// @param intervalOpenTick The tick the interval opened at. Set to lastTick when the observation is committed.
  /// @param volatilityCorrob Corroborated volatility set by the Elastic Fee Module. Returned on observations resolved from the accumulator.
  /// @param cumulativeVolume0 Cumulative token0 input volume.
  /// @param cumulativeVolume1 Cumulative token1 input volume.
  /// @param intervalSwapCount Per-interval swap count. Resets to 0 each time an observation is committed and saturates at its max value.
  /// @param cumulativeFee0 Cumulative token0 fees.
  /// @param cumulativeFee1 Cumulative token1 fees.
  /// @param volatilityRingHead Next write position in the volatility ring.
  /// @param volatilityRingCount Number of filled ring slots. Stops growing once it reaches the max ring length.
  /// @param cumulativeMevVolume0 Cumulative token0 toxic volume.
  /// @param cumulativeMevVolume1 Cumulative token1 toxic volume.
  /// @param nOver Count set by the Elastic Fee Module while setting the volatility results. This value is not committed as an observation.
  /// @param cumulativeMevFee0 Cumulative token0 MEV fees.
  /// @param cumulativeMevFee1 Cumulative token1 MEV fees.
  struct Accumulator {
    // Slot 1
    uint40 lastSwapTimestamp;
    uint40 lastObservationTimestamp;
    uint32 swapCount;
    int24 lastTick;
    int24 intervalMaxTick;
    int24 intervalMinTick;
    int24 intervalOpenTick;
    uint48 volatilityCorrob;
    // Slot 2
    uint120 cumulativeVolume0;
    uint120 cumulativeVolume1;
    uint16 intervalSwapCount;
    // Slot 3
    uint120 cumulativeFee0;
    uint120 cumulativeFee1;
    uint8 volatilityRingHead;
    uint8 volatilityRingCount;
    // Slot 4
    uint120 cumulativeMevVolume0;
    uint120 cumulativeMevVolume1;
    uint8 nOver;
    // Slot 5
    uint120 cumulativeMevFee0;
    uint120 cumulativeMevFee1;
  }

  /// @notice A committed snapshot of the accumulator at a cadence boundary.
  /// @param secondsPerStakedLiquidityCumulativeX128 Cumulative seconds per unit of staked liquidity (X128) at commit, read from the pool.
  /// @param blockTimestamp Timestamp the observation was committed.
  /// @param swapCount Cumulative swap count at commit.
  /// @param closeTick The interval last tick recorded in the accumulator.
  /// @param secondsPerLiquidityCumulativeX128 Cumulative seconds per unit of active liquidity (X128) at commit, read from the pool oracle.
  /// @param volatilityCorrob Corroborated volatility set by the Elastic Fee Module. This value is zero until written through {recordVolatility}.
  /// @param cumulativeVolume0 Cumulative token0 input volume.
  /// @param cumulativeVolume1 Cumulative token1 input volume.
  /// @param cumulativeFee0 Cumulative token0 fees.
  /// @param cumulativeFee1 Cumulative token1 fees.
  /// @param cumulativeMevVolume0 Cumulative token0 toxic volume.
  /// @param cumulativeMevVolume1 Cumulative token1 toxic volume.
  /// @param cumulativeMevFee0 Cumulative token0 MEV fees.
  /// @param cumulativeMevFee1 Cumulative token1 MEV fees.
  struct Observation {
    // Slot 1
    uint160 secondsPerStakedLiquidityCumulativeX128;
    uint40 blockTimestamp;
    uint32 swapCount;
    int24 closeTick;
    // Slot 2
    uint160 secondsPerLiquidityCumulativeX128;
    uint48 volatilityCorrob;
    // Slot 3
    uint120 cumulativeVolume0;
    uint120 cumulativeVolume1;
    // Slot 4
    uint120 cumulativeFee0;
    uint120 cumulativeFee1;
    // Slot 5
    uint120 cumulativeMevVolume0;
    uint120 cumulativeMevVolume1;
    // Slot 6
    uint120 cumulativeMevFee0;
    uint120 cumulativeMevFee1;
  }

  /// @notice Flags selecting which observation slots `observe` loads and returns.
  /// @dev The staked cumulative, `blockTimestamp`, `swapCount` and `closeTick` share the first slot and are
  ///      always loaded.
  /// @param slot2 Loads `secondsPerLiquidityCumulativeX128` and `volatilityCorrob`.
  /// @param slot3 Loads the cumulative volumes.
  /// @param slot4 Loads the cumulative fees.
  /// @param slot5 Loads the cumulative MEV volumes.
  /// @param slot6 Loads the cumulative MEV fees.
  struct ObservationSlots {
    bool slot2;
    bool slot3;
    bool slot4;
    bool slot5;
    bool slot6;
  }

  /// @notice The per-pool circular buffer of observations and its metadata.
  /// @param observations Fixed-size buffer of committed observations.
  /// @param index Index of the most recently committed observation.
  /// @param cardinality Number of populated slots in the buffer.
  /// @param cardinalityNext Number of observation slots that can be populated.
  struct ObservationBuffer {
    Observation[65_535] observations;
    uint16 index;
    uint16 cardinality;
    uint16 cardinalityNext;
  }

  /// @notice Per-swap deltas and pool state passed into `record`.
  /// @param fee0 token0 fee for this swap.
  /// @param fee1 token1 fee for this swap.
  /// @param volume0 token0 volume for this swap.
  /// @param volume1 token1 volume for this swap.
  /// @param mevVolume0 token0 toxic volume for this swap.
  /// @param mevVolume1 token1 toxic volume for this swap.
  /// @param mevFee0 token0 MEV fee for this swap.
  /// @param mevFee1 token1 MEV fee for this swap.
  /// @param tick The swap's ending tick.
  struct CLPoolTapeData {
    uint128 fee0;
    uint128 fee1;
    uint128 volume0;
    uint128 volume1;
    uint128 mevVolume0;
    uint128 mevVolume1;
    uint128 mevFee0;
    uint128 mevFee1;
    int24 tick;
  }

  /// @notice The ring content as three separate arrays.
  /// @param tickRanges The tick ranges.
  /// @param dists The tick distances.
  /// @param swapCounts The swap counts.
  struct VolatilityRing {
    uint256[] tickRanges;
    uint256[] dists;
    uint256[] swapCounts;
  }

  /*////////////////////////////////////////////////////////////
                            EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the elastic fee module writes volatility results.
  /// @param _pool The pool the results apply to.
  /// @param _volatilityCorrob The corroborated volatility written onto the latest observation and the accumulator.
  /// @param _nOver The count stored in the accumulator.
  event VolatilityRecorded(address indexed _pool, uint48 _volatilityCorrob, uint8 _nOver);

  /// @notice Emitted when the elastic fee module address is set.
  /// @param _elasticFeeModule The new elastic fee module address.
  event ElasticFeeModuleSet(address indexed _elasticFeeModule);

  /*////////////////////////////////////////////////////////////
                    EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Records a swap's metrics and tick state, committing at the cadence boundary.
  /// @param _pool The pool the swap occurred in.
  /// @param _data The per-swap deltas and tick state.
  /// @return _committed True when a new observation has been commited.
  function record(address _pool, CLPoolTapeData calldata _data) external returns (bool _committed);

  /// @notice Writes the volatility read results onto the latest committed observation.
  /// @notice Reverts if the caller is not the configured elastic fee module.
  /// @param _pool The pool the results apply to.
  /// @param _volatilityCorrob The corroborated volatility written onto the latest observation and the accumulator.
  /// @param _nOver The count stored in the accumulator.
  function recordVolatility(address _pool, uint48 _volatilityCorrob, uint8 _nOver) external;

  /// @notice Sets the elastic fee module authorized to call {recordVolatility}.
  /// @notice Reverts if the caller is not the owner.
  /// @param _elasticFeeModule The new module address.
  function setElasticFeeModule(address _elasticFeeModule) external;

  /*////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the stored observation at an index.
  /// @dev Callers can get the valid index range from `observationBuffers`. The index must be in
  ///      `[0, cardinality)` to read written observations.
  /// @param _pool The pool to read.
  /// @param _index The buffer index to read.
  /// @return _observation The stored observation.
  function getObservation(address _pool, uint16 _index) external view returns (Observation memory _observation);

  /// @notice Returns an interpolated observation for each requested past timestamp (`block.timestamp - secondsAgo`).
  /// @dev A timestamp newer than the newest committed observation is computed from current state, so its value
  ///      changes as swaps happen, even within a single transaction. A timestamp at or before that observation
  ///      is fixed and reads the same every time.
  /// @dev Each committed observation stores the staked liquidity cumulative read from the pool at commit time.
  ///      Every other timestamp is interpolated or projected, so read {getObservation} when a value has to be exact.
  /// @param _pool The pool to read.
  /// @param _secondsAgo The past timestamps to read. A zero timestamp returns the current accumulator.
  /// @return _observations One observation per timestamp, in the same order as `_secondsAgo`.
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice Returns an interpolated observation for each requested past timestamp, loading only requested slots.
  /// @dev Unrequested slots are returned as zero. So is every field of a pool with no recorded swap.
  /// @dev Each committed observation stores the staked liquidity cumulative read from the pool at commit time,
  ///      so those points are exact. Every other timestamp is interpolated or projected, so read
  ///      {getObservation} when a value has to be exact.
  /// @param _pool The pool to read.
  /// @param _secondsAgo The past timestamps to read. A zero timestamp returns the current accumulator.
  /// @param _slots The observation slots to load.
  /// @return _observations One observation per timestamp, in the same order as `_secondsAgo`.
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo,
    ObservationSlots calldata _slots
  ) external view returns (Observation[] memory _observations);

  /// @notice Returns the pool's volatility ring
  /// @param _pool The pool to read.
  /// @return _values The ring unpacked values.
  function getVolatilityRing(address _pool) external view returns (VolatilityRing memory _values);

  /// @notice The elastic fee module authorized for {recordVolatility}.
  /// @return _elasticFeeModule The module address.
  function elasticFeeModule() external view returns (address _elasticFeeModule);

  /// @notice The per-pool current accumulator state.
  /// @param _pool The pool to read.
  /// @return _accumulator The pool's current accumulator.
  function accumulators(address _pool) external view returns (Accumulator memory _accumulator);
}
