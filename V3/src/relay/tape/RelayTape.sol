// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayTape} from 'V3/interfaces/relay/tape/IRelayTape.sol';

/**
 * @title RelayTape
 * @notice Records what each Relay pays its holders in two families of observation rings, and serves
 *         the reads a Relay APR needs: the far-edge search, the daily series and the running totals.
 * @dev Written through the relay factory, which calls in fail-open: a revert here is a silent no-op
 *      for the operation that triggered it, while too little gas to call at all fails that operation.
 *      Ring sizes and the hourly cadence are constants; the only configuration is the factory allowlist.
 */
contract RelayTape is Ownable2Step, IRelayTape {
  /// @notice The identity a ring write stamps on its event, one memory pointer on the stack.
  /// @param relay The relay the series belongs to.
  /// @param token The reward token of a reward series, the zero address for a backing series.
  /// @param series The family written.
  struct SeriesId {
    address relay;
    address token;
    Series series;
  }

  /// @inheritdoc IRelayTape
  uint256 public constant HOURLY_RING_SIZE = 48;

  /// @inheritdoc IRelayTape
  uint256 public constant DAILY_RING_SIZE = 32;

  /// @inheritdoc IRelayTape
  uint32 public constant HOURLY_CADENCE = 1 hours;

  /// @inheritdoc IRelayTape
  uint256 public constant HOURLY_SPAN = HOURLY_RING_SIZE * HOURLY_CADENCE;

  /// @inheritdoc IRelayTape
  uint256 public constant PER_SHARE_SCALE = 1e27;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRelayTape
  /// @dev Logically a fixed ring: writes only touch indices in `[0, HOURLY_RING_SIZE)`.
  mapping(address _relay => mapping(address _token => mapping(uint256 _index => Observation _observation))) public
    rewardHourlyRing;

  /// @inheritdoc IRelayTape
  /// @dev Logically a fixed ring: writes only touch indices in `[0, DAILY_RING_SIZE)`.
  mapping(address _relay => mapping(address _token => mapping(uint256 _index => Observation _observation))) public
    rewardDailyRing;

  /// @inheritdoc IRelayTape
  mapping(address _relay => mapping(uint256 _index => Observation _observation)) public backingHourlyRing;

  /// @inheritdoc IRelayTape
  mapping(address _relay => mapping(uint256 _index => Observation _observation)) public backingDailyRing;

  /// @inheritdoc IRelayTape
  mapping(address _relay => mapping(address _token => Meta _meta)) public rewardMeta;

  /// @inheritdoc IRelayTape
  mapping(address _relay => Meta _meta) public backingMeta;

  /// @inheritdoc IRelayTape
  /// @dev Summed on every feed, before the cadence gates: a feed between boundaries lands here even
  ///      when no ring is written. Wraps deliberately; readers subtract unchecked across the wrap.
  mapping(address _relay => mapping(address _token => uint128 _cumulative)) public rewardCumulative;

  /// @inheritdoc IRelayTape
  mapping(address _relay => uint128 _cumulative) public backingCumulative;

  /// @inheritdoc IRelayTape
  mapping(address _factory => bool _allowed) public isAllowedFactory;

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Deploys the tape with an owner and the initial factory allowlist.
   * @dev Seeding the allowlist at construction lets relays record from their first compound without
   *      a config transaction: the owner is final from deployment and never the deployer. The
   *      allowlist is a mapping rather than a single slot so a next factory generation joins without
   *      a tape redeploy.
   * @param _initialOwner The initial owner.
   * @param _allowedFactories The relay factories allowed to record from deployment.
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

  /// @inheritdoc IRelayTape
  function recordReward(address _relay, address _token, uint256 _distributed, uint256 _index) external {
    if (!isAllowedFactory[msg.sender]) revert Unauthorized();

    // The total first, before any gate can return: a feed lost here would understate every window
    // read across it. The truncating cast is the wrap readers undo by subtracting unchecked.
    uint128 _cumulative;
    unchecked {
      // forge-lint: disable-next-line(unsafe-typecast)
      _cumulative = rewardCumulative[_relay][_token] + uint128(_distributed);
    }
    rewardCumulative[_relay][_token] = _cumulative;

    _record(
      rewardHourlyRing[_relay][_token],
      rewardDailyRing[_relay][_token],
      rewardMeta[_relay][_token],
      _cumulative,
      _saturate(_index),
      SeriesId({relay: _relay, token: _token, series: Series.Reward})
    );
  }

  /// @inheritdoc IRelayTape
  function recordBacking(address _relay, uint256 _net, uint256 _backing, uint256 _supply) external {
    if (!isAllowedFactory[msg.sender]) revert Unauthorized();

    uint128 _cumulative;
    unchecked {
      // forge-lint: disable-next-line(unsafe-typecast)
      _cumulative = backingCumulative[_relay] + uint128(_net);
    }
    backingCumulative[_relay] = _cumulative;

    // Defensive: a compound only runs against a live principal supply. The feed's total is kept
    // either way.
    if (_supply == 0) return;

    _record(
      backingHourlyRing[_relay],
      backingDailyRing[_relay],
      backingMeta[_relay],
      _cumulative,
      _saturate((_backing * PER_SHARE_SCALE) / _supply),
      SeriesId({relay: _relay, token: address(0), series: Series.Backing})
    );
  }

  /// @inheritdoc IRelayTape
  function setAllowedFactory(address _factory, bool _allowed) external onlyOwner {
    isAllowedFactory[_factory] = _allowed;

    emit AllowedFactorySet(_factory, _allowed);
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IRelayTape
  function observeReward(
    address _relay,
    address _token,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations) {
    Meta memory _seriesMeta = rewardMeta[_relay][_token];
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);

    for (uint256 _i; _i < _length; ++_i) {
      uint256 _lookback = _secondsAgo[_i];
      if (_lookback == 0) {
        _observations[_i] = _liveReward(_relay, _token, _seriesMeta.hourlyCount);
        continue;
      }
      _observations[_i] =
        _observeStored(rewardHourlyRing[_relay][_token], rewardDailyRing[_relay][_token], _seriesMeta, _lookback);
    }
  }

  /// @inheritdoc IRelayTape
  function observeBacking(
    address _relay,
    uint48[] calldata _secondsAgo
  ) external view returns (Observation[] memory _observations) {
    Meta memory _seriesMeta = backingMeta[_relay];
    uint256 _length = _secondsAgo.length;
    _observations = new Observation[](_length);

    for (uint256 _i; _i < _length; ++_i) {
      uint256 _lookback = _secondsAgo[_i];
      if (_lookback == 0) {
        _observations[_i] = _liveBacking(_relay, _seriesMeta);
        continue;
      }
      _observations[_i] = _observeStored(backingHourlyRing[_relay], backingDailyRing[_relay], _seriesMeta, _lookback);
    }
  }

  /// @inheritdoc IRelayTape
  function dailyRewardObservations(
    address _relay,
    address _token
  ) external view returns (Observation[] memory _observations) {
    _observations = _dailySeries(rewardDailyRing[_relay][_token], rewardMeta[_relay][_token]);
  }

  /// @inheritdoc IRelayTape
  function dailyBackingObservations(address _relay) external view returns (Observation[] memory _observations) {
    _observations = _dailySeries(backingDailyRing[_relay], backingMeta[_relay]);
  }

  /*////////////////////////////////////////////////////////////
                      INTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Writes one observation into each ring whose cadence gate has passed.
   * @dev Owns the series' meta: reads it once, decides both gates from that slot, and writes it back
   *      once. A zeroed meta passes both gates, so a series' first feed always writes.
   * @param _hourlyRing The series' hourly ring.
   * @param _dailyRing The series' daily ring.
   * @param _meta The series' meta slot.
   * @param _cumulative The series' running total at this feed.
   * @param _value The per-share value at this feed, already saturated.
   * @param _id The series identity the events carry.
   */
  function _record(
    mapping(uint256 _index => Observation _observation) storage _hourlyRing,
    mapping(uint256 _index => Observation _observation) storage _dailyRing,
    Meta storage _meta,
    uint128 _cumulative,
    uint224 _value,
    SeriesId memory _id
  ) internal {
    Meta memory _seriesMeta = _meta;

    bool _writeHourly = uint256(_seriesMeta.lastHourlyTimestamp) + HOURLY_CADENCE <= block.timestamp;
    // forge-lint: disable-next-line(unsafe-typecast)
    uint16 _day = uint16(block.timestamp / 1 days);
    bool _writeDaily = _day > _seriesMeta.lastDailyDay;
    if (!_writeHourly && !_writeDaily) return;

    Observation memory _observation = Observation({
      cumulative: _cumulative,
      // forge-lint: disable-next-line(unsafe-typecast)
      blockTimestamp: uint48(block.timestamp),
      valuePerShare: _value
    });

    if (_writeHourly) {
      uint8 _head = _seriesMeta.hourlyHead;
      _hourlyRing[_head] = _observation;
      emit ObservationRecorded(_id.relay, _id.token, _id.series, Ring.Hourly, _head, _observation.blockTimestamp);

      // slither-disable-start weak-prng
      // forge-lint: disable-next-line(unsafe-typecast)
      _seriesMeta.hourlyHead = uint8((_head + 1) % HOURLY_RING_SIZE);
      // slither-disable-end weak-prng
      if (_seriesMeta.hourlyCount < HOURLY_RING_SIZE) ++_seriesMeta.hourlyCount;
      // forge-lint: disable-next-line(unsafe-typecast)
      _seriesMeta.lastHourlyTimestamp = uint32(block.timestamp);
    }

    if (_writeDaily) {
      uint8 _head = _seriesMeta.dailyHead;
      _dailyRing[_head] = _observation;
      emit ObservationRecorded(_id.relay, _id.token, _id.series, Ring.Daily, _head, _observation.blockTimestamp);

      // slither-disable-start weak-prng
      // forge-lint: disable-next-line(unsafe-typecast)
      _seriesMeta.dailyHead = uint8((_head + 1) % DAILY_RING_SIZE);
      // slither-disable-end weak-prng
      if (_seriesMeta.dailyCount < DAILY_RING_SIZE) ++_seriesMeta.dailyCount;
      _seriesMeta.lastDailyDay = _day;
    }

    _storeMeta(_meta, _seriesMeta);
  }

  /*////////////////////////////////////////////////////////////
                      INTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Resolves a stored far edge: the newest observation at or before the lookback's target.
   * @dev Lookbacks within the hourly span read the hourly ring, longer ones the daily ring.
   * @param _hourlyRing The series' hourly ring.
   * @param _dailyRing The series' daily ring.
   * @param _seriesMeta The series' meta.
   * @param _lookback Seconds before now to resolve at.
   * @return _observation The far-edge observation.
   */
  function _observeStored(
    mapping(uint256 _index => Observation _observation) storage _hourlyRing,
    mapping(uint256 _index => Observation _observation) storage _dailyRing,
    Meta memory _seriesMeta,
    uint256 _lookback
  ) internal view returns (Observation memory _observation) {
    uint256 _target = _lookback >= block.timestamp ? 0 : block.timestamp - _lookback;

    if (_lookback <= HOURLY_SPAN) {
      _observation =
        _observeSingle(_hourlyRing, _seriesMeta.hourlyHead, _seriesMeta.hourlyCount, HOURLY_RING_SIZE, _target);
    } else {
      _observation = _observeSingle(_dailyRing, _seriesMeta.dailyHead, _seriesMeta.dailyCount, DAILY_RING_SIZE, _target);
    }
  }

  /**
   * @notice The reward series projected to this block, stamped now.
   * @dev The near edge a window's delta is read against. The index only moves on a notify, so this
   *      reads the relay's storage exactly rather than projecting it.
   * @param _relay The relay to read.
   * @param _token The reward token to read.
   * @param _count The series' written hourly observations.
   * @return _observation The live observation.
   */
  function _liveReward(
    address _relay,
    address _token,
    uint256 _count
  ) internal view returns (Observation memory _observation) {
    if (_count == 0) return _observation;

    _observation = Observation({
      cumulative: rewardCumulative[_relay][_token],
      // forge-lint: disable-next-line(unsafe-typecast)
      blockTimestamp: uint48(block.timestamp),
      valuePerShare: _saturate(IRelay(_relay).rewardIndex(_token))
    });
  }

  /**
   * @notice The backing series projected to this block, stamped now.
   * @dev A drained principal supply cannot price a share, so the newest stored observation answers
   *      instead, from whichever ring holds it, as of its own write rather than now.
   * @param _relay The relay to read.
   * @param _seriesMeta The series' meta.
   * @return _observation The live observation.
   */
  function _liveBacking(
    address _relay,
    Meta memory _seriesMeta
  ) internal view returns (Observation memory _observation) {
    uint256 _count = _seriesMeta.hourlyCount;
    if (_count == 0) return _observation;

    uint256 _supply = IRelay(_relay).principalToken().totalSupply();
    if (_supply == 0) {
      uint256 _newestHourly = (uint256(_seriesMeta.hourlyHead) + HOURLY_RING_SIZE - 1) % HOURLY_RING_SIZE;
      Observation memory _hourly = backingHourlyRing[_relay][_newestHourly];
      if (_seriesMeta.dailyCount == 0) return _hourly;

      // The newest write can sit in either ring: a feed inside the hourly cadence but across a day
      // boundary writes the daily ring only, so the fresher of the two newest slots answers.
      uint256 _newestDaily = (uint256(_seriesMeta.dailyHead) + DAILY_RING_SIZE - 1) % DAILY_RING_SIZE;
      Observation memory _daily = backingDailyRing[_relay][_newestDaily];
      return _daily.blockTimestamp > _hourly.blockTimestamp ? _daily : _hourly;
    }

    _observation = Observation({
      cumulative: backingCumulative[_relay],
      // forge-lint: disable-next-line(unsafe-typecast)
      blockTimestamp: uint48(block.timestamp),
      valuePerShare: _saturate((IRelay(_relay).totalBacking() * PER_SHARE_SCALE) / _supply)
    });
  }

  /**
   * @notice A series' daily observations, oldest first.
   * @param _dailyRing The series' daily ring.
   * @param _seriesMeta The series' meta.
   * @return _observations The stored daily observations in write order.
   */
  function _dailySeries(
    mapping(uint256 _index => Observation _observation) storage _dailyRing,
    Meta memory _seriesMeta
  ) internal view returns (Observation[] memory _observations) {
    uint256 _count = _seriesMeta.dailyCount;
    _observations = new Observation[](_count);

    uint256 _oldestIdx = _oldestIndex(_seriesMeta.dailyHead, _count, DAILY_RING_SIZE);
    for (uint256 _i; _i < _count; ++_i) {
      // slither-disable-next-line weak-prng
      _observations[_i] = _dailyRing[(_oldestIdx + _i) % DAILY_RING_SIZE];
    }
  }

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
   * @notice Saturating downcast of a copied per-share value to the observation's width.
   * @dev Copies saturate where totals wrap: a wrapped copy would read as a plunge, a saturated one
   *      freezes at the ceiling, which only an already-broken relay can reach.
   * @param _value The reported per-share value.
   * @return _stored The stored value, capped at the observation's maximum.
   */
  function _saturate(uint256 _value) internal pure returns (uint224 _stored) {
    // forge-lint: disable-next-line(unsafe-typecast)
    _stored = _value > type(uint224).max ? type(uint224).max : uint224(_value);
  }

  /**
   * @notice Stores an advanced meta back into its slot.
   * @dev Memory cannot assign through a storage pointer parameter, so the copy is field by field.
   *      All six share one slot, so only the first store is cold.
   * @param _meta The series' meta slot.
   * @param _seriesMeta The advanced meta.
   */
  function _storeMeta(Meta storage _meta, Meta memory _seriesMeta) private {
    _meta.lastHourlyTimestamp = _seriesMeta.lastHourlyTimestamp;
    _meta.lastDailyDay = _seriesMeta.lastDailyDay;
    _meta.hourlyHead = _seriesMeta.hourlyHead;
    _meta.hourlyCount = _seriesMeta.hourlyCount;
    _meta.dailyHead = _seriesMeta.dailyHead;
    _meta.dailyCount = _seriesMeta.dailyCount;
  }
}
