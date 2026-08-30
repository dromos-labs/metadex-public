// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title IPoolTape
/// @notice Records and exposes per-swap cumulative metrics for V2 pools.
interface IPoolTape {
  /*////////////////////////////////////////////////////////////
                            STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Per-pool running cumulatives updated on every swap.
  /// @param cumulativeFee0 Cumulative token0 fees.
  /// @param cumulativeFee1 Cumulative token1 fees.
  /// @param cumulativeVolume0 Cumulative token0 input volume.
  /// @param cumulativeVolume1 Cumulative token1 input volume.
  /// @param cumulativeMevVolume0 Cumulative token0 toxic volume.
  /// @param cumulativeMevVolume1 Cumulative token1 toxic volume.
  /// @param cumulativeMevFee0 Cumulative token0 MEV fees.
  /// @param cumulativeMevFee1 Cumulative token1 MEV fees.
  /// @param lastSwapTimestamp Timestamp of the most recent recorded swap.
  /// @param swapCount Cumulative swap count.
  struct Accumulator {
    // Slot 1
    uint128 cumulativeFee0;
    uint128 cumulativeFee1;
    // Slot 2
    uint128 cumulativeVolume0;
    uint128 cumulativeVolume1;
    // Slot 3
    uint128 cumulativeMevVolume0;
    uint128 cumulativeMevVolume1;
    // Slot 4
    uint128 cumulativeMevFee0;
    uint128 cumulativeMevFee1;
    // Slot 5
    uint48 lastSwapTimestamp;
    uint48 swapCount;
  }

  /// @notice A committed snapshot of the accumulator at a cadence boundary.
  /// @param cumulativeFee0 Cumulative token0 fees.
  /// @param cumulativeFee1 Cumulative token1 fees.
  /// @param cumulativeVolume0 Cumulative token0 input volume.
  /// @param cumulativeVolume1 Cumulative token1 input volume.
  /// @param cumulativeMevVolume0 Cumulative token0 toxic volume.
  /// @param cumulativeMevVolume1 Cumulative token1 toxic volume.
  /// @param cumulativeMevFee0 Cumulative token0 MEV fees.
  /// @param cumulativeMevFee1 Cumulative token1 MEV fees.
  /// @param blockTimestamp Timestamp the observation was committed.
  /// @param swapCount Cumulative swap count at commit.
  struct Observation {
    // Slot 1
    uint128 cumulativeFee0;
    uint128 cumulativeFee1;
    // Slot 2
    uint128 cumulativeVolume0;
    uint128 cumulativeVolume1;
    // Slot 3
    uint128 cumulativeMevVolume0;
    uint128 cumulativeMevVolume1;
    // Slot 4
    uint128 cumulativeMevFee0;
    uint128 cumulativeMevFee1;
    // Slot 5
    uint48 blockTimestamp;
    uint48 swapCount;
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

  /// @notice Per-swap deltas passed into `record`.
  /// @param fee0 token0 fee for this swap.
  /// @param fee1 token1 fee for this swap.
  /// @param volume0 token0 volume for this swap.
  /// @param volume1 token1 volume for this swap.
  /// @param mevVolume0 token0 toxic volume for this swap.
  /// @param mevVolume1 token1 toxic volume for this swap.
  /// @param mevFee0 token0 MEV fee for this swap.
  /// @param mevFee1 token1 MEV fee for this swap.
  struct PoolTapeData {
    uint128 fee0;
    uint128 fee1;
    uint128 volume0;
    uint128 volume1;
    uint128 mevVolume0;
    uint128 mevVolume1;
    uint128 mevFee0;
    uint128 mevFee1;
  }

  /*////////////////////////////////////////////////////////////
                    EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Records a swap's metrics, accumulating and committing at the cadence boundary.
  /// @param _pool The pool the swap occurred in.
  /// @param _data The per-swap deltas.
  function record(address _pool, PoolTapeData calldata _data) external;

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
  /// @dev A timestamp at or after the latest swap returns the current accumulator with the requested timestamp,
  ///      because the cumulatives have not moved since the last swap. A timestamp at or before the oldest stored
  ///      observation returns the oldest available observation with its own timestamp. An unregistered pool returns zeroed observations.
  /// @dev A timestamp newer than the newest committed observation is derived from live state, so its value moves
  ///      as swaps land and a single transaction can shift it. Timestamps at or before the newest committed
  ///      observation are settled and read the same on every call.
  /// @param _pool The pool to read.
  /// @param _secondsAgo The past timestamps to read. A zero timestamp returns the current accumulator.
  /// @return _observations One observation per timestamp, in the same order as `_secondsAgo`.
  function observe(
    address _pool,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice The per-pool current accumulator values getter.
  /// @param _pool The pool to read.
  /// @return cumulativeFee0 Cumulative token0 fees.
  /// @return cumulativeFee1 Cumulative token1 fees.
  /// @return cumulativeVolume0 Cumulative token0 input volume.
  /// @return cumulativeVolume1 Cumulative token1 input volume.
  /// @return cumulativeMevVolume0 Cumulative token0 toxic volume.
  /// @return cumulativeMevVolume1 Cumulative token1 toxic volume.
  /// @return cumulativeMevFee0 Cumulative token0 MEV fees.
  /// @return cumulativeMevFee1 Cumulative token1 MEV fees.
  /// @return lastSwapTimestamp Timestamp of the most recent recorded swap.
  /// @return swapCount Cumulative swap count.
  function accumulators(address _pool)
    external
    view
    returns (
      uint128 cumulativeFee0,
      uint128 cumulativeFee1,
      uint128 cumulativeVolume0,
      uint128 cumulativeVolume1,
      uint128 cumulativeMevVolume0,
      uint128 cumulativeMevVolume1,
      uint128 cumulativeMevFee0,
      uint128 cumulativeMevFee1,
      uint48 lastSwapTimestamp,
      uint48 swapCount
    );
}
