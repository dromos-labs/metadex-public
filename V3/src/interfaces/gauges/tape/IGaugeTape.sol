// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IGaugeTape
/// @notice Records each gauge's reward accumulator in two fixed rings of observations and serves
///         the reads an emissions APR needs: the far-edge search and the daily series.
interface IGaugeTape {
  /*////////////////////////////////////////////////////////////
                              ENUMS
  ////////////////////////////////////////////////////////////*/

  /// @notice The two observation rings a gauge writes into.
  /// @dev `Hourly` is throttled to one write per hour and serves the 24h window. `Daily` writes on a
  ///      day-boundary change and serves the 7D and 30D windows.
  /// @param Hourly The ring throttled to one write per hour.
  /// @param Daily The ring written once per day boundary.
  enum Ring {
    Hourly,
    Daily
  }

  /*////////////////////////////////////////////////////////////
                             STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice A committed reading of a gauge's reward accumulator.
  /// @param rewardPerToken The gauge's `rewardPerTokenStored` at the write, PRECISION-scaled,
  ///        saturating downcast by the tape.
  /// @param blockTimestamp The time the reading was taken.
  struct Observation {
    uint224 rewardPerToken;
    uint32 blockTimestamp;
  }

  /// @notice A gauge's ring heads and write gates, one slot.
  /// @dev `lastHourlyTimestamp` duplicates the newest hourly observation's timestamp on purpose:
  ///      the skip path decides both gates from this single slot without touching the rings.
  /// @param lastHourlyTimestamp The hourly ring gate: the timestamp of the last hourly write.
  /// @param lastDailyDay The daily ring gate: the day number (days since epoch) of the last daily write.
  /// @param hourlyHead The next hourly slot to write.
  /// @param hourlyCount Written hourly observations, bounds the search.
  /// @param dailyHead The next daily slot to write.
  /// @param dailyCount Written daily observations, bounds the search.
  struct Meta {
    uint32 lastHourlyTimestamp;
    uint16 lastDailyDay;
    uint8 hourlyHead;
    uint8 hourlyCount;
    uint8 dailyHead;
    uint8 dailyCount;
  }

  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when a factory is allowed or disallowed as a `record` caller.
  /// @param _factory The gauge factory the permission applies to.
  /// @param _allowed True when the factory may record.
  event AllowedFactorySet(address indexed _factory, bool _allowed);

  /// @notice Emitted when an observation is written into a ring, refreshes included.
  /// @dev The stored value is not emitted, matching the pool tape's `ObservationRecorded`: the
  ///      ring and slot point at it in storage.
  /// @param _gauge The gauge the observation belongs to.
  /// @param _ring The ring written.
  /// @param _index The slot the observation was written to.
  /// @param _blockTimestamp The stored timestamp.
  event ObservationRecorded(address indexed _gauge, Ring _ring, uint8 _index, uint32 _blockTimestamp);

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when `record` is called by a factory that is not allowlisted.
  error Unauthorized();

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Records a gauge's accumulator reading, writing each ring whose gate has passed.
  /// @dev Called by an allowlisted gauge factory relaying its gauge's report. Both gates are
  ///      evaluated independently, so one call can write either ring, both or neither. A reading
  ///      equal to the last stored one writes a refresh: same value, new timestamp.
  /// @param _gauge The gauge the reading belongs to.
  /// @param _rewardPerToken The gauge's `rewardPerTokenStored` after the advance, saturating
  ///        downcast by the tape.
  function record(address _gauge, uint256 _rewardPerToken) external;

  /// @notice Allows or disallows a gauge factory as a `record` caller.
  /// @param _factory The gauge factory to configure.
  /// @param _allowed True to allow, false to disallow.
  function setAllowedFactory(address _factory, bool _allowed) external;

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the stored far edge for each requested past timestamp (`block.timestamp - secondsAgo`).
  /// @dev No interpolation: each entry is the newest observation at or before its target. A zero
  ///      lookback returns the gauge's accumulator projected to this block, matching
  ///      `IPoolTape.observe`. Lookbacks up to the hourly ring's span read the hourly ring, longer
  ///      ones the daily ring. A target older than the oldest stored observation returns the oldest
  ///      one, so the window shrinks instead of failing. An empty serving ring returns a zeroed
  ///      observation.
  /// @param _gauge The gauge to read.
  /// @param _secondsAgo The lookbacks to read, each from now.
  /// @return _observations One observation per lookback, in the same order as `_secondsAgo`.
  function observe(
    address _gauge,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice The daily observations of a gauge, oldest first.
  /// @dev At most `DAILY_RING_SIZE` entries: the ring recycles, each new day overwrites the oldest
  ///      slot, so the series never grows past one lap.
  /// @param _gauge The gauge to read.
  /// @return _observations The stored daily observations in write order.
  function dailyObservations(address _gauge) external view returns (Observation[] memory _observations);

  /// @notice True when the factory may call `record`.
  /// @param _factory The factory to read.
  /// @return _allowed The factory's allowlist state.
  function isAllowedFactory(address _factory) external view returns (bool _allowed);

  /// @notice A gauge's ring heads and gates.
  /// @param _gauge The gauge to read.
  /// @return _lastHourlyTimestamp The hourly ring gate.
  /// @return _lastDailyDay The daily ring gate, days since epoch.
  /// @return _hourlyHead The next hourly slot to write.
  /// @return _hourlyCount Written hourly observations.
  /// @return _dailyHead The next daily slot to write.
  /// @return _dailyCount Written daily observations.
  function meta(address _gauge)
    external
    view
    returns (
      uint32 _lastHourlyTimestamp,
      uint16 _lastDailyDay,
      uint8 _hourlyHead,
      uint8 _hourlyCount,
      uint8 _dailyHead,
      uint8 _dailyCount
    );

  /// @notice A stored hourly ring observation.
  /// @param _gauge The gauge to read.
  /// @param _index The slot to read, in `[0, hourlyCount)`.
  /// @return _rewardPerToken The stored accumulator value.
  /// @return _blockTimestamp The stored timestamp.
  function hourlyRing(
    address _gauge,
    uint256 _index
  ) external view returns (uint224 _rewardPerToken, uint32 _blockTimestamp);

  /// @notice A stored daily ring observation.
  /// @param _gauge The gauge to read.
  /// @param _index The slot to read, in `[0, dailyCount)`.
  /// @return _rewardPerToken The stored accumulator value.
  /// @return _blockTimestamp The stored timestamp.
  function dailyRing(
    address _gauge,
    uint256 _index
  ) external view returns (uint224 _rewardPerToken, uint32 _blockTimestamp);

  /// @notice The hourly ring size in slots.
  /// @return _size The hourly ring size.
  function HOURLY_RING_SIZE() external view returns (uint256 _size);

  /// @notice The daily ring size in slots.
  /// @return _size The daily ring size.
  function DAILY_RING_SIZE() external view returns (uint256 _size);

  /// @notice The hourly ring cadence: the minimum seconds between hourly writes.
  /// @return _cadence The hourly cadence in seconds.
  function HOURLY_CADENCE() external view returns (uint32 _cadence);

  /// @notice The hourly ring's coverage in seconds: lookbacks at or below it are served by the
  ///         hourly ring, longer ones by the daily ring.
  /// @return _span The hourly span, `HOURLY_RING_SIZE * HOURLY_CADENCE`.
  function HOURLY_SPAN() external view returns (uint256 _span);
}
