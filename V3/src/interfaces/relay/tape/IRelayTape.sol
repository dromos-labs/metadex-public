// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/// @title IRelayTape
/// @notice Records what each Relay pays its holders in two families of observation rings, and serves
///         the reads a Relay APR needs: the far-edge search, the daily series and the running totals.
/// @dev The reward family is one series per (relay, reward token): the relay's own per-share
///      `rewardIndex` is snapshotted, and the amounts each `notifyReward` distributes are summed here,
///      because the relay does not keep that total. The backing family is one series per relay: the
///      backing each share redeems is computed at the snapshot, and the amounts each `compound` stakes
///      are summed here. Indexes are copied, so they saturate; totals are summed, so they wrap and the
///      reader subtracts unchecked across the wrap, as the pool tape's cumulatives do.
interface IRelayTape {
  /*////////////////////////////////////////////////////////////
                              ENUMS
  ////////////////////////////////////////////////////////////*/

  /// @notice The two observation rings a series writes into.
  /// @dev `Hourly` is throttled to one write per hour and serves the 24h window. `Daily` writes on a
  ///      day-boundary change and serves the 7D and 30D windows.
  /// @param Hourly The ring throttled to one write per hour.
  /// @param Daily The ring written once per day boundary.
  enum Ring {
    Hourly,
    Daily
  }

  /// @notice The two series families a relay writes.
  /// @param Reward A (relay, token) series: converted rewards.
  /// @param Backing A relay series: compounded backing.
  enum Series {
    Reward,
    Backing
  }

  /*////////////////////////////////////////////////////////////
                             STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice A committed reading of one series, two slots.
  /// @dev What the tape sums wraps, what it copies saturates.
  /// @param cumulative The series' running total at the write: distributed amounts for a reward
  ///        series, compounded amounts for a backing series. Wraps; compare unchecked.
  /// @param blockTimestamp The time the reading was taken.
  /// @param valuePerShare The per-share reading: the relay's `rewardIndex` for a reward series, the
  ///        PER_SHARE_SCALE-scaled backing per principal share for a backing series. Saturates.
  struct Observation {
    // Slot 1
    uint128 cumulative;
    uint48 blockTimestamp;
    // Slot 2
    uint224 valuePerShare;
  }

  /// @notice A series' ring heads and write gates, one slot.
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

  /// @notice Emitted when a factory is allowed or disallowed as a record caller.
  /// @param _factory The relay factory the permission applies to.
  /// @param _allowed True when the factory may record.
  event AllowedFactorySet(address indexed _factory, bool _allowed);

  /// @notice Emitted when an observation is written into a ring.
  /// @dev The stored values are not emitted, matching the other tapes' `ObservationRecorded`: the
  ///      series, ring and slot point at them in storage.
  /// @param _relay The relay the observation belongs to.
  /// @param _token The reward token of a reward series, the zero address for a backing series.
  /// @param _series The family written.
  /// @param _ring The ring written.
  /// @param _index The slot the observation was written to.
  /// @param _blockTimestamp The stored timestamp.
  event ObservationRecorded(
    address indexed _relay, address indexed _token, Series _series, Ring _ring, uint8 _index, uint48 _blockTimestamp
  );

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a record entry is called by a factory that is not allowlisted.
  error Unauthorized();

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Feeds a reward series with what a `notifyReward` just distributed, writing each ring
  ///         whose gate has passed.
  /// @dev Called by an allowlisted factory relaying its relay's report, values included, so the tape
  ///      reads nothing back on a write. The amount lands on the running total before the gates, so a
  ///      feed between boundaries is never lost.
  /// @param _relay The relay the series belongs to, vouched by the calling factory.
  /// @param _token The reward token distributed.
  /// @param _distributed The amount the notify distributed to holders, post rake.
  /// @param _index The relay's per-share index after the advance.
  function recordReward(address _relay, address _token, uint256 _distributed, uint256 _index) external;

  /// @notice Feeds a relay's backing series with what a `compound` just staked, writing each ring
  ///         whose gate has passed.
  /// @dev Same shape as `recordReward`. The per-share value is computed here against the principal
  ///      supply, the denominator because only the principal redeems backing. A zero supply skips
  ///      the snapshot and keeps the total.
  /// @param _relay The relay the series belongs to, vouched by the calling factory.
  /// @param _net The amount the compound staked into backing, post rake.
  /// @param _backing The relay's backing after the compound lands.
  /// @param _supply The principal supply that backing prices against.
  function recordBacking(address _relay, uint256 _net, uint256 _backing, uint256 _supply) external;

  /// @notice Allows or disallows a relay factory as a record caller.
  /// @param _factory The relay factory to configure.
  /// @param _allowed True to allow, false to disallow.
  function setAllowedFactory(address _factory, bool _allowed) external;

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the reward series' stored far edge for each requested past timestamp
  ///         (`block.timestamp - secondsAgo`).
  /// @dev No interpolation: each entry is the newest observation at or before its target. A zero
  ///      lookback returns the live reading, the running total and the relay's current `rewardIndex`.
  ///      Lookbacks up to the hourly ring's span read the hourly ring, longer ones the daily ring. A
  ///      target older than the oldest stored observation returns the oldest one, so the window
  ///      shrinks instead of failing. A series with no observations returns zeroed entries.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @param _secondsAgo The lookbacks to read, each from now.
  /// @return _observations One observation per lookback, in the same order as `_secondsAgo`.
  function observeReward(
    address _relay,
    address _token,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice Returns the backing series' stored far edge for each requested past timestamp.
  /// @dev Same semantics as `observeReward`. The zero lookback computes the live backing per share;
  ///      a relay whose principal supply has fully exited returns the newest stored observation
  ///      instead, whichever ring holds it, so one drained relay cannot revert a batched read.
  /// @param _relay The relay to read.
  /// @param _secondsAgo The lookbacks to read, each from now.
  /// @return _observations One observation per lookback, in the same order as `_secondsAgo`.
  function observeBacking(
    address _relay,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations);

  /// @notice The daily observations of a reward series, oldest first.
  /// @dev At most `DAILY_RING_SIZE` entries: the ring recycles, each new day overwrites the oldest
  ///      slot, so the series never grows past one lap.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @return _observations The stored daily observations in write order.
  function dailyRewardObservations(
    address _relay,
    address _token
  ) external view returns (Observation[] memory _observations);

  /// @notice The daily observations of a relay's backing series, oldest first.
  /// @param _relay The relay to read.
  /// @return _observations The stored daily observations in write order.
  function dailyBackingObservations(address _relay) external view returns (Observation[] memory _observations);

  /// @notice A reward series' running total of distributed amounts.
  /// @dev Wraps at uint128; readers compare totals unchecked across the wrap.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @return _cumulative The running total.
  function rewardCumulative(address _relay, address _token) external view returns (uint128 _cumulative);

  /// @notice A relay's running total of compounded amounts.
  /// @dev Wraps at uint128; readers compare totals unchecked across the wrap.
  /// @param _relay The relay to read.
  /// @return _cumulative The running total.
  function backingCumulative(address _relay) external view returns (uint128 _cumulative);

  /// @notice Whether a factory may call the record entries.
  /// @param _factory The factory to read.
  /// @return _allowed True when the factory may record.
  function isAllowedFactory(address _factory) external view returns (bool _allowed);

  /// @notice One slot of a reward series' hourly ring.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @param _index The slot to read.
  /// @return _cumulative The stored running total.
  /// @return _blockTimestamp The stored timestamp.
  /// @return _valuePerShare The stored per-share value.
  function rewardHourlyRing(
    address _relay,
    address _token,
    uint256 _index
  ) external view returns (uint128 _cumulative, uint48 _blockTimestamp, uint224 _valuePerShare);

  /// @notice One slot of a reward series' daily ring.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @param _index The slot to read.
  /// @return _cumulative The stored running total.
  /// @return _blockTimestamp The stored timestamp.
  /// @return _valuePerShare The stored per-share value.
  function rewardDailyRing(
    address _relay,
    address _token,
    uint256 _index
  ) external view returns (uint128 _cumulative, uint48 _blockTimestamp, uint224 _valuePerShare);

  /// @notice One slot of a backing series' hourly ring.
  /// @param _relay The relay to read.
  /// @param _index The slot to read.
  /// @return _cumulative The stored running total.
  /// @return _blockTimestamp The stored timestamp.
  /// @return _valuePerShare The stored per-share value.
  function backingHourlyRing(
    address _relay,
    uint256 _index
  ) external view returns (uint128 _cumulative, uint48 _blockTimestamp, uint224 _valuePerShare);

  /// @notice One slot of a backing series' daily ring.
  /// @param _relay The relay to read.
  /// @param _index The slot to read.
  /// @return _cumulative The stored running total.
  /// @return _blockTimestamp The stored timestamp.
  /// @return _valuePerShare The stored per-share value.
  function backingDailyRing(
    address _relay,
    uint256 _index
  ) external view returns (uint128 _cumulative, uint48 _blockTimestamp, uint224 _valuePerShare);

  /// @notice A reward series' ring heads and write gates.
  /// @param _relay The relay to read.
  /// @param _token The reward token to read.
  /// @return _lastHourlyTimestamp The hourly ring gate.
  /// @return _lastDailyDay The daily ring gate.
  /// @return _hourlyHead The next hourly slot to write.
  /// @return _hourlyCount Written hourly observations.
  /// @return _dailyHead The next daily slot to write.
  /// @return _dailyCount Written daily observations.
  function rewardMeta(
    address _relay,
    address _token
  )
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

  /// @notice A backing series' ring heads and write gates.
  /// @param _relay The relay to read.
  /// @return _lastHourlyTimestamp The hourly ring gate.
  /// @return _lastDailyDay The daily ring gate.
  /// @return _hourlyHead The next hourly slot to write.
  /// @return _hourlyCount Written hourly observations.
  /// @return _dailyHead The next daily slot to write.
  /// @return _dailyCount Written daily observations.
  function backingMeta(address _relay)
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

  /*////////////////////////////////////////////////////////////
                             CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Slots in each hourly ring.
  /// @return _size The hourly ring size.
  function HOURLY_RING_SIZE() external view returns (uint256 _size);

  /// @notice Slots in each daily ring.
  /// @return _size The daily ring size.
  function DAILY_RING_SIZE() external view returns (uint256 _size);

  /// @notice Minimum seconds between two hourly writes of one series.
  /// @return _cadence The hourly cadence in seconds.
  function HOURLY_CADENCE() external view returns (uint32 _cadence);

  /// @notice The hourly ring's span: lookbacks at or under it read the hourly ring.
  /// @return _span The hourly span, `HOURLY_RING_SIZE * HOURLY_CADENCE`.
  function HOURLY_SPAN() external view returns (uint256 _span);

  /// @notice The scale backing per share is stored at.
  /// @dev Chosen to mirror the relays' `ACC_SCALE`, so both families read at the same scale; a
  ///      presentation choice of the tape, not a value read from the relay.
  /// @return _scale The per-share scale, 1e27.
  function PER_SHARE_SCALE() external view returns (uint256 _scale);
}
