// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IBasePoolTape
interface IBasePoolTape {
  /*////////////////////////////////////////////////////////////
                            STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice A pool's authorized caller and cadence.
  /// @param caller The caller authorized to record for the pool.
  /// @param cadence The pool's cadence in seconds.
  struct PoolConfig {
    address caller;
    uint32 cadence;
  }

  /*////////////////////////////////////////////////////////////
                            EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the chain-wide default cadence interval is set.
  /// @param _cadenceInterval The new default cadence interval in seconds.
  event DefaultCadenceIntervalSet(uint32 _cadenceInterval);

  /// @notice Emitted when a per-pool cadence is set or cleared.
  /// @param _pool The pool whose cadence changed.
  /// @param _cadence The new per-pool cadence in seconds.
  event PoolCadenceSet(address indexed _pool, uint32 _cadence);

  /// @notice Emitted when a pool's authorized caller is set or cleared.
  /// @param _pool The pool the authorization applies to.
  /// @param _caller The caller authorized to record for the pool. The zero address means no caller is authorized.
  event AllowedCallerSet(address indexed _pool, address indexed _caller);

  /// @notice Emitted the first time a pool's observation buffer is initialized.
  /// @param _pool The pool whose observation buffer was initialized.
  /// @param _blockTimestamp The timestamp the buffer was initialized at.
  event PoolObservationBufferInitialized(address indexed _pool, uint48 _blockTimestamp);

  /// @notice Emitted when an observation is committed to the buffer.
  /// @param _pool The pool the observation was committed for.
  /// @param _index The slot the observation was written to.
  /// @param _blockTimestamp The observation timestamp.
  event ObservationRecorded(address indexed _pool, uint16 _index, uint48 _blockTimestamp);

  /// @notice Emitted when a pool's observation cardinality is increased.
  /// @param _pool The pool whose cardinality was increased.
  /// @param _cardinalityNextOld The previous cardinality.
  /// @param _cardinalityNextNew The new cardinality.
  event ObservationCardinalityIncreased(address indexed _pool, uint16 _cardinalityNextOld, uint16 _cardinalityNextNew);

  /*////////////////////////////////////////////////////////////
                            ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a caller records for a pool it is not authorized for.
  error Unauthorized();

  /// @notice Thrown when a cadence interval of zero is set as the chain default.
  error ZeroCadenceInterval();

  /*////////////////////////////////////////////////////////////
                    EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Sets the chain-wide default cadence interval.
  /// @dev Reverts if the cadence interval is zero.
  /// @param _cadenceInterval The new default cadence interval in seconds.
  function setDefaultCadenceInterval(uint32 _cadenceInterval) external;

  /// @notice Sets or clears a per-pool cadence override.
  /// @param _pool The pool to configure.
  /// @param _cadence The per-pool cadence in seconds. A zero value stores the current default cadence interval.
  function setPoolCadence(address _pool, uint32 _cadence) external;

  /// @notice Sets or clears the caller authorized to record for a pool and initializes the accumulator and pool buffer.
  /// @param _pool The pool the authorization applies to.
  /// @param _caller The caller to authorize. The zero address clears the authorization.
  function setAllowedCallerAndInitializePool(address _pool, address _caller) external;

  /// @notice Pre-allocates buffer slots increasing the buffer capacity
  /// @param _pool The pool whose cardinality is being increased.
  /// @param _observationCardinalityNext The new target cardinality.
  function increaseObservationCardinalityNext(address _pool, uint16 _observationCardinalityNext) external;

  /*////////////////////////////////////////////////////////////
                    EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice The chain-wide default cadence interval in seconds.
  /// @return _defaultCadenceInterval The default cadence interval.
  function defaultCadenceInterval() external view returns (uint32 _defaultCadenceInterval);

  /// @notice The pool's cadence override in seconds. A zero value means the pool was never configured.
  /// @param _pool The pool to read.
  /// @return _cadence The pool's cadence.
  function poolCadence(address _pool) external view returns (uint32 _cadence);

  /// @notice The caller authorized to record data for a pool.
  /// @param _pool The pool to read.
  /// @return _caller The authorized caller, or the zero address when none is set.
  function allowedCaller(address _pool) external view returns (address _caller);

  /// @notice The pool's buffer metadata.
  /// @dev Implemented by each child's `observationBuffers` mapping.
  /// @param _pool The pool to read.
  /// @return index Index of the most recently committed observation.
  /// @return cardinality Number of populated slots.
  /// @return cardinalityNext Number of slots pre-warmed and available.
  function observationBuffers(address _pool)
    external
    view
    returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);
}
