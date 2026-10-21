// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';

import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IGaugeTape} from 'V3/interfaces/gauges/tape/IGaugeTape.sol';

/**
 * @title GaugeTape
 * @notice Records each V2 gauge's `rewardPerTokenStored` in two fixed rings of observations and
 *         serves the reads an emissions APR needs: the far-edge search and the daily series.
 * @dev Written through the gauge factories' fail-open relay, so a revert here is a silent no-op
 *      for the gauge action that triggered it. Ring sizes and the hourly cadence are constants;
 *      the only configuration is the factory allowlist.
 */
contract GaugeTape is Ownable2Step, IGaugeTape {
  /// @inheritdoc IGaugeTape
  uint256 public constant HOURLY_RING_SIZE = 48;

  /// @inheritdoc IGaugeTape
  uint256 public constant DAILY_RING_SIZE = 32;

  /// @inheritdoc IGaugeTape
  uint32 public constant HOURLY_CADENCE = 1 hours;

  /// @inheritdoc IGaugeTape
  uint256 public constant HOURLY_SPAN = HOURLY_RING_SIZE * HOURLY_CADENCE;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeTape
  /// @dev Logically a fixed ring: writes only touch indices in `[0, HOURLY_RING_SIZE)`.
  mapping(address _gauge => mapping(uint256 _index => Observation _observation)) public hourlyRing;

  /// @inheritdoc IGaugeTape
  /// @dev Logically a fixed ring: writes only touch indices in `[0, DAILY_RING_SIZE)`.
  mapping(address _gauge => mapping(uint256 _index => Observation _observation)) public dailyRing;

  /// @inheritdoc IGaugeTape
  mapping(address _gauge => Meta _meta) public meta;

  /// @inheritdoc IGaugeTape
  mapping(address _factory => bool _allowed) public isAllowedFactory;

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the tape with an owner and the initial factory allowlist.
   * @dev Seeding the allowlist at construction lets gauges record from their first settle without
   *      a config transaction: the owner is final from deployment and never the deployer.
   * @param _initialOwner The initial owner.
   * @param _allowedFactories The gauge factories allowed to record from deployment.
   */
  constructor(address _initialOwner, address[] memory _allowedFactories) Ownable(_initialOwner) {
    for (uint256 _i; _i < _allowedFactories.length; ++_i) {
      isAllowedFactory[_allowedFactories[_i]] = true;
      emit AllowedFactorySet(_allowedFactories[_i], true);
    }
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeTape
  function record(address _gauge, uint256 _rewardPerToken) external {
    if (!isAllowedFactory[msg.sender]) revert Unauthorized();

    Meta memory _gaugeMeta = meta[_gauge];

    /// @dev Gates widen to uint256, so the comparisons cannot underflow, and a zeroed gate (no
    ///      observations yet) passes on any timestamp past the epoch's first hour and day.
    bool _writeHourly = uint256(_gaugeMeta.lastHourlyTimestamp) + HOURLY_CADENCE <= block.timestamp;
    // forge-lint: disable-next-line(unsafe-typecast)
    uint16 _day = uint16(block.timestamp / 1 days);
    bool _writeDaily = _day > _gaugeMeta.lastDailyDay;
    if (!_writeHourly && !_writeDaily) return;

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 _blockTimestamp = uint32(block.timestamp);
    Observation memory _observation =
      Observation({rewardPerToken: _saturate(_rewardPerToken), blockTimestamp: _blockTimestamp});

    if (_writeHourly) {
      uint8 _head = _gaugeMeta.hourlyHead;
      hourlyRing[_gauge][_head] = _observation;
      emit ObservationRecorded(_gauge, Ring.Hourly, _head, _blockTimestamp);

      // slither-disable-start weak-prng
      // forge-lint: disable-next-line(unsafe-typecast)
      _gaugeMeta.hourlyHead = uint8((_head + 1) % HOURLY_RING_SIZE);
      // slither-disable-end weak-prng
      if (_gaugeMeta.hourlyCount < HOURLY_RING_SIZE) ++_gaugeMeta.hourlyCount;
      _gaugeMeta.lastHourlyTimestamp = _blockTimestamp;
    }

    if (_writeDaily) {
      uint8 _head = _gaugeMeta.dailyHead;
      dailyRing[_gauge][_head] = _observation;
      emit ObservationRecorded(_gauge, Ring.Daily, _head, _blockTimestamp);

      // slither-disable-start weak-prng
      // forge-lint: disable-next-line(unsafe-typecast)
      _gaugeMeta.dailyHead = uint8((_head + 1) % DAILY_RING_SIZE);
      // slither-disable-end weak-prng
      if (_gaugeMeta.dailyCount < DAILY_RING_SIZE) ++_gaugeMeta.dailyCount;
      _gaugeMeta.lastDailyDay = _day;
    }

    meta[_gauge] = _gaugeMeta;
  }

  /// @inheritdoc IGaugeTape
  function setAllowedFactory(address _factory, bool _allowed) external onlyOwner {
    isAllowedFactory[_factory] = _allowed;

    emit AllowedFactorySet(_factory, _allowed);
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IGaugeTape
  function observe(
    address _gauge,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations) {
    Meta memory _gaugeMeta = meta[_gauge];
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);

    for (uint256 _i; _i < _length; ++_i) {
      uint256 _lookback = _secondsAgo[_i];
      if (_lookback == 0) {
        _observations[_i] = _live(_gauge, _gaugeMeta.hourlyCount);
        continue;
      }
      uint256 _target = _lookback >= block.timestamp ? 0 : block.timestamp - _lookback;

      if (_lookback <= HOURLY_SPAN) {
        _observations[_i] =
          _observeSingle(hourlyRing[_gauge], _gaugeMeta.hourlyHead, _gaugeMeta.hourlyCount, HOURLY_RING_SIZE, _target);
      } else {
        _observations[_i] =
          _observeSingle(dailyRing[_gauge], _gaugeMeta.dailyHead, _gaugeMeta.dailyCount, DAILY_RING_SIZE, _target);
      }
    }
  }

  /// @inheritdoc IGaugeTape
  function dailyObservations(address _gauge) external view returns (Observation[] memory _observations) {
    Meta memory _gaugeMeta = meta[_gauge];
    uint256 _count = _gaugeMeta.dailyCount;
    _observations = new Observation[](_count);

    uint256 _oldestIdx = _oldestIndex(_gaugeMeta.dailyHead, _count, DAILY_RING_SIZE);
    mapping(uint256 _index => Observation _observation) storage _ring = dailyRing[_gauge];
    for (uint256 _i; _i < _count; ++_i) {
      // slither-disable-next-line weak-prng
      _observations[_i] = _ring[(_oldestIdx + _i) % DAILY_RING_SIZE];
    }
  }

  /*////////////////////////////////////////////////////////////
                      INTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Resolves the newest observation at or before `_target` by binary search.
   * @dev Searches logical order over `[0, count)`, oldest first. A target older than the oldest
   *      observation returns the oldest one; an empty ring returns a zeroed observation.
   * @param _ring The ring to search.
   * @param _head The ring's next write slot.
   * @param _count The ring's written observations.
   * @param _size The ring's size in slots.
   * @param _target The timestamp to search for.
   * @return _observation The far-edge observation.
   */
  function _observeSingle(
    mapping(uint256 _index => Observation _observation) storage _ring,
    uint256 _head,
    uint256 _count,
    uint256 _size,
    uint256 _target
  ) internal view returns (Observation memory _observation) {
    if (_count == 0) return _observation;

    uint256 _oldestIdx = _oldestIndex(_head, _count, _size);
    Observation memory _oldest = _ring[_oldestIdx];
    if (_oldest.blockTimestamp >= _target) return _oldest;

    _observation = _binarySearch(_ring, _oldestIdx, _count, _size, _target);
  }

  /**
   * @notice Binary searches the ring for the newest observation at or before `_target`.
   * @dev The caller rules out an empty ring and a target before the oldest observation, so logical
   *      index zero is at or before the target and the search keeps that invariant on `_left`.
   * @param _ring The ring to search.
   * @param _oldestIdx The ring's oldest physical slot.
   * @param _count The ring's written observations.
   * @param _size The ring's size in slots.
   * @param _target The timestamp to search for.
   * @return _observation The far-edge observation.
   */
  function _binarySearch(
    mapping(uint256 _index => Observation _observation) storage _ring,
    uint256 _oldestIdx,
    uint256 _count,
    uint256 _size,
    uint256 _target
  ) internal view returns (Observation memory _observation) {
    // slither-disable-next-line uninitialized-local
    uint256 _left;
    uint256 _right = _count - 1;
    // slither-disable-start weak-prng
    while (_left < _right) {
      uint256 _mid = (_left + _right + 1) / 2;
      if (_ring[(_oldestIdx + _mid) % _size].blockTimestamp <= _target) {
        _left = _mid;
      } else {
        _right = _mid - 1;
      }
    }
    _observation = _ring[(_oldestIdx + _left) % _size];
    // slither-disable-end weak-prng
  }

  /**
   * @notice The gauge's accumulator projected to this block, stamped now.
   * @dev The near edge a window's delta is read against, matching `IPoolTape.observe`, whose zero
   *      lookback returns live state. A gauge with no observations returns a zeroed observation
   *      rather than reaching into an address the tape never recorded for.
   * @param _gauge The gauge to read.
   * @param _count The gauge's written hourly observations.
   * @return _observation The live observation.
   */
  function _live(address _gauge, uint256 _count) internal view returns (Observation memory _observation) {
    if (_count == 0) return _observation;

    // forge-lint: disable-next-line(unsafe-typecast)
    uint32 _blockTimestamp = uint32(block.timestamp);
    _observation = Observation({
      rewardPerToken: _saturate(IV2Gauge(_gauge).projectedRewardPerToken()), blockTimestamp: _blockTimestamp
    });
  }

  /**
   * @notice The ring's oldest physical slot, where its logical order starts.
   * @dev Before the first lap the oldest observation sits at slot zero; once the ring is full the
   *      head points at the oldest slot.
   * @param _head The ring's next write slot.
   * @param _count The ring's written observations.
   * @param _size The ring's size in slots.
   * @return _oldest The oldest physical slot.
   */
  function _oldestIndex(uint256 _head, uint256 _count, uint256 _size) internal pure returns (uint256 _oldest) {
    _oldest = _count == _size ? _head : 0;
  }

  /**
   * @notice Saturating downcast of a reported accumulator to the observation's width.
   * @param _rewardPerToken The reported accumulator.
   * @return _value The stored value, capped at the observation's maximum.
   */
  function _saturate(uint256 _rewardPerToken) internal pure returns (uint224 _value) {
    // forge-lint: disable-next-line(unsafe-typecast)
    _value = _rewardPerToken > type(uint224).max ? type(uint224).max : uint224(_rewardPerToken);
  }
}
