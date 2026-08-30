/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IToken} from 'V3/interfaces/minter/IToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {Roles} from 'V3/libraries/Roles.sol';

/**
 * @title Minter
 * @notice Root side minter that stores the emission rate and mints TOKEN on redeem settlement.
 */
contract Minter is IMinter {
  using SafeCast for uint256;

  /// @inheritdoc IMinter
  uint256 public constant MIN_MINT_AMOUNT = MAX_PIPS;
  /// @inheritdoc IMinter
  uint256 public constant MAXIMUM_TEAM_RATE = 50_000;
  /// @inheritdoc IMinter
  uint24 public constant MAX_WEEKLY_RATE_CHANGE_PIPS = 50_000;
  /// @inheritdoc IMinter
  uint24 public constant WEEKLY_LOG_BUDGET_PIPS = 48_790;
  /// @inheritdoc IMinter
  uint232 public constant MAX_BASE_RATE = 730_750_818_665_456_651_398_700_951_213;

  /// @inheritdoc IMinter
  address public immutable TOKEN;
  /// @inheritdoc IMinter
  address public immutable VOTER;
  /// @inheritdoc IMinter
  address public immutable SPLITTER;
  /// @inheritdoc IMinter
  uint48 public immutable ACTIVATION_TIMESTAMP;
  /// @inheritdoc IMinter
  uint24 public immutable MAX_BASE_RATE_CHANGE_PIPS_CAP;
  /// @inheritdoc IMinter
  uint48 public immutable MIN_BASE_RATE_UPDATE_COOLDOWN;
  /// @inheritdoc IMinter
  uint48 public immutable MAX_BASE_RATE_UPDATE_COOLDOWN;
  /// @inheritdoc IMinter
  uint24 public immutable MAX_BAND_FLOOR_PIPS;
  /// @inheritdoc IMinter
  uint24 public immutable MAX_BAND_CEILING_PIPS;

  /// @inheritdoc IMinter
  address public operator;
  /// @inheritdoc IMinter
  uint48 public nextBaseRateUpdate;
  /// @inheritdoc IMinter
  uint24 public maxBaseRateChangePips;

  /// @inheritdoc IMinter
  address public fed;
  /// @inheritdoc IMinter
  uint48 public baseRateUpdateCooldown;
  /// @inheritdoc IMinter
  uint24 public teamRate;

  /// @inheritdoc IMinter
  uint232 public baseRate;
  /// @inheritdoc IMinter
  uint24 public bandFloorPips;

  /// @inheritdoc IMinter
  uint24 public bandCeilingPips;
  /// @inheritdoc IMinter
  address public dynamicRateModule;
  /// @inheritdoc IMinter
  uint48 public lastCapUpdate;

  /// @inheritdoc IMinter
  uint256 public dynamicRate;
  /// @inheritdoc IMinter
  uint256 public emissionsCap;
  /// @inheritdoc IMinter
  uint256 public emissionsMinted;

  /**
   * @notice Auth check for governor only functions.
   */
  modifier onlyGovernor() {
    if (!IVoter(VOTER).hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) revert CallerNotGovernor();
    _;
  }

  /**
   * @notice Initializes the minter with immutable dependencies and bounded mutable configuration.
   * @param _params Constructor parameters.
   */
  constructor(ConstructorParams memory _params) {
    // Non zero checks.
    if (_params.token == address(0)) revert ZeroAddress();
    if (_params.voter == address(0)) revert ZeroAddress();
    if (_params.splitter == address(0)) revert ZeroAddress();
    if (_params.operator == address(0)) revert ZeroAddress();
    if (_params.initialBaseRate == 0) revert InvalidBaseRate();

    // Migration must open on a future epoch start. Emissions activate one epoch later.
    if (
      _params.migrationOpen <= block.timestamp
        || ProtocolTimeLibrary.epochStart(_params.migrationOpen) != _params.migrationOpen
    ) revert InvalidActivationTimestamp();

    // Rate cap checks.
    if (_params.initialBaseRate > MAX_BASE_RATE) revert BaseRateTooHigh();
    if (_params.maxBaseRateChangePipsCap == 0) revert MaxBaseRateChangeCapTooLow();
    if (_params.maxBaseRateChangePipsCap > MAX_WEEKLY_RATE_CHANGE_PIPS) revert MaxBaseRateChangeCapTooHigh();
    if (_params.maxBaseRateChangePips > _params.maxBaseRateChangePipsCap) revert MaxBaseRateChangeTooHigh();
    // Cooldown checks.
    if (_params.minBaseRateUpdateCooldown == 0) revert MinCooldownTooLow();
    if (_params.minBaseRateUpdateCooldown > _params.maxBaseRateUpdateCooldown) revert InvalidCooldownRange();
    if (_params.baseRateUpdateCooldown < _params.minBaseRateUpdateCooldown) revert CooldownTooLow();
    if (_params.baseRateUpdateCooldown > _params.maxBaseRateUpdateCooldown) revert CooldownTooHigh();
    _validateRateControls(_params.maxBaseRateChangePips, _params.baseRateUpdateCooldown);
    // Dynamic rate band range cap checks. Floor must stay below MAX_PIPS so the clamped rate can never reach zero.
    if (_params.maxBandFloorPips == 0) revert BandFloorCapTooLow();
    if (_params.maxBandFloorPips >= MAX_PIPS) revert BandFloorCapTooWide();
    if (_params.maxBandCeilingPips == 0) revert BandCeilingCapTooLow();
    if (_params.maxBandCeilingPips > MAX_PIPS) revert BandCeilingCapTooWide();
    // Splitter and team rate checks.
    if (_params.splitter == address(this)) revert InvalidSplitter();
    if (_params.teamRate > MAXIMUM_TEAM_RATE) revert TeamRateTooHigh();

    TOKEN = _params.token;
    VOTER = _params.voter;
    SPLITTER = _params.splitter;
    ACTIVATION_TIMESTAMP = _params.migrationOpen + WEEK;
    MAX_BASE_RATE_CHANGE_PIPS_CAP = _params.maxBaseRateChangePipsCap;
    MIN_BASE_RATE_UPDATE_COOLDOWN = _params.minBaseRateUpdateCooldown;
    MAX_BASE_RATE_UPDATE_COOLDOWN = _params.maxBaseRateUpdateCooldown;
    MAX_BAND_FLOOR_PIPS = _params.maxBandFloorPips;
    MAX_BAND_CEILING_PIPS = _params.maxBandCeilingPips;

    operator = _params.operator;
    baseRate = _params.initialBaseRate;
    nextBaseRateUpdate = (block.timestamp + _params.baseRateUpdateCooldown).toUint48();
    maxBaseRateChangePips = _params.maxBaseRateChangePips;
    baseRateUpdateCooldown = _params.baseRateUpdateCooldown;
    teamRate = _params.teamRate;
    // Start the cap clock at activation so nothing accrues early.
    lastCapUpdate = ACTIVATION_TIMESTAMP;
  }

  /// @inheritdoc IMinter
  function mint(uint256 _amount, address _recipient) external {
    if (msg.sender != VOTER) revert CallerNotVoter();
    if (_amount < MIN_MINT_AMOUNT) revert AmountTooLow();

    // Accrue the cap up to now so the check runs against the current total.
    _accrueEmissionsCap();

    uint256 _emissionsMinted = emissionsMinted + _amount;
    if (_emissionsMinted > emissionsCap) revert CapExceeded();
    emissionsMinted = _emissionsMinted;

    uint256 _splitterShare = Math.mulDiv(_amount, teamRate, MAX_PIPS, Math.Rounding.Floor);

    IToken(TOKEN).mint(_recipient, _amount);
    if (_splitterShare != 0) {
      IToken(TOKEN).mint(SPLITTER, _splitterShare);
    }

    emit Minted(_recipient, _amount, _splitterShare);
  }

  /// @inheritdoc IMinter
  function setOperator(address _operator) external onlyGovernor {
    if (_operator == address(0)) revert ZeroAddress();
    if (_operator == fed) revert OperatorFEDCollision();

    operator = _operator;

    emit OperatorSet(_operator);
  }

  /// @inheritdoc IMinter
  function setFED(address _fed) external onlyGovernor {
    if (_fed == operator) revert OperatorFEDCollision();

    fed = _fed;

    emit FEDSet(_fed);
  }

  /// @inheritdoc IMinter
  function setMaxBaseRateChangePips(uint24 _maxBaseRateChangePips) external onlyGovernor {
    if (_maxBaseRateChangePips > MAX_BASE_RATE_CHANGE_PIPS_CAP) revert MaxBaseRateChangeTooHigh();
    _validateRateControls(_maxBaseRateChangePips, baseRateUpdateCooldown);

    _extendNextBaseRateUpdate();
    maxBaseRateChangePips = _maxBaseRateChangePips;

    emit MaxBaseRateChangePipsSet(_maxBaseRateChangePips);
  }

  /// @inheritdoc IMinter
  function setBaseRateUpdateCooldown(uint48 _baseRateUpdateCooldown) external onlyGovernor {
    if (_baseRateUpdateCooldown < MIN_BASE_RATE_UPDATE_COOLDOWN) revert CooldownTooLow();
    if (_baseRateUpdateCooldown > MAX_BASE_RATE_UPDATE_COOLDOWN) revert CooldownTooHigh();
    _validateRateControls(maxBaseRateChangePips, _baseRateUpdateCooldown);

    _extendNextBaseRateUpdate();
    baseRateUpdateCooldown = _baseRateUpdateCooldown;

    emit BaseRateUpdateCooldownSet(_baseRateUpdateCooldown);
  }

  /// @inheritdoc IMinter
  function setTeamRate(uint24 _teamRate) external onlyGovernor {
    if (_teamRate > MAXIMUM_TEAM_RATE) revert TeamRateTooHigh();

    teamRate = _teamRate;

    emit TeamRateSet(_teamRate);
  }

  /// @inheritdoc IMinter
  function setRateBand(uint24 _floorPips, uint24 _ceilingPips) external onlyGovernor {
    if (_floorPips > MAX_BAND_FLOOR_PIPS) revert BandFloorTooWide();
    if (_ceilingPips > MAX_BAND_CEILING_PIPS) revert BandCeilingTooWide();

    // Accrue the cap at the outgoing effective rate before the band moves the read-time clamp.
    _accrueEmissionsCap();

    bandFloorPips = _floorPips;
    bandCeilingPips = _ceilingPips;

    emit RateBandSet(_floorPips, _ceilingPips);
  }

  /// @inheritdoc IMinter
  function setBaseRate(uint232 _newRate) external {
    if (msg.sender != operator) revert CallerNotOperator();
    if (_newRate == 0) revert InvalidBaseRate();
    if (_newRate > MAX_BASE_RATE) revert BaseRateTooHigh();
    if (block.timestamp < nextBaseRateUpdate) revert CooldownActive();

    uint232 _oldRate = baseRate;
    if (_newRate == _oldRate) revert SameRate();
    uint256 _delta = _newRate > _oldRate ? _newRate - _oldRate : _oldRate - _newRate;
    // Round the allowed change up so a non zero max change never floors to a zero bound, which would freeze updates.
    if (_delta > Math.mulDiv(_oldRate, maxBaseRateChangePips, MAX_PIPS, Math.Rounding.Ceil)) {
      revert RateChangeExceedsMax();
    }

    // Accrue the cap at the outgoing effective rate before the base rate moves the read-time clamp.
    _accrueEmissionsCap();

    baseRate = _newRate;
    nextBaseRateUpdate = (block.timestamp + baseRateUpdateCooldown).toUint48();

    emit BaseRateSet(_newRate);
  }

  /// @inheritdoc IMinter
  function setDynamicRateModule(address _module) external {
    if (msg.sender != fed) revert CallerNotFED();

    // Disabling the module also disables its last target. Bank the outgoing segment first so the reset cannot
    // retroactively price it at the base rate. A non-zero replacement inherits the target until its first push.
    if (_module == address(0) && dynamicRate != 0) {
      _accrueEmissionsCap();
      dynamicRate = 0;
      emit DynamicRateSet(0);
    }

    dynamicRateModule = _module;

    emit DynamicRateModuleSet(_module);
  }

  /// @inheritdoc IMinter
  function setDynamicRate(uint256 _rate) external {
    if (msg.sender != dynamicRateModule) revert CallerNotDynamicRateModule();

    // Accrue the cap at the outgoing effective rate before the new target takes effect.
    _accrueEmissionsCap();

    dynamicRate = _rate;

    emit DynamicRateSet(_rate);
  }

  /// @inheritdoc IMinter
  function emissionRate() external view returns (uint256 _rate) {
    if (block.timestamp < ACTIVATION_TIMESTAMP) return 0;

    _rate = _effectiveRate();
  }

  /**
   * @notice Accrues the emissions cap at the effective rate over the elapsed segment.
   * @dev No-op until `block.timestamp` passes `lastCapUpdate`, which starts at `ACTIVATION_TIMESTAMP`. Called on
   * every mint and base rate, dynamic rate, or band change so the cap always integrates the rate actually
   * in effect. `MAX_BASE_RATE` bounds the rate so neither a segment nor the accumulated cap can overflow.
   */
  function _accrueEmissionsCap() internal {
    uint256 _lastCapUpdate = lastCapUpdate;
    if (block.timestamp > _lastCapUpdate) {
      emissionsCap += _effectiveRate() * (block.timestamp - _lastCapUpdate);
      lastCapUpdate = block.timestamp.toUint48();
    }
  }

  /**
   * @notice Extends the next base rate update deadline after rate control changes.
   * @dev Sets `nextBaseRateUpdate` to `max(nextBaseRateUpdate, block.timestamp + 1 weeks)` with checked
   * conversion. Never shortens a later deadline. Overflow of the one-week timestamp reverts atomically.
   */
  function _extendNextBaseRateUpdate() internal {
    uint48 _minimumNextBaseRateUpdate = (block.timestamp + 1 weeks).toUint48();
    if (_minimumNextBaseRateUpdate > nextBaseRateUpdate) {
      nextBaseRateUpdate = _minimumNextBaseRateUpdate;
    }
  }

  /**
   * @notice Returns the effective emission rate: the stored dynamic rate clamped to the band around the base rate.
   * @dev A zero target means no module push is in effect, so the emission is the base rate regardless of the band.
   * Clamping happens here, at read time, so a base rate change immediately re-limits the emission.
   * @return _rate Effective emission rate after band clamping.
   */
  function _effectiveRate() internal view returns (uint256 _rate) {
    uint232 _baseRate = baseRate;
    uint256 _dynamicRate = dynamicRate;
    if (_dynamicRate == 0) return _baseRate;
    if (_dynamicRate < _baseRate) {
      // Below base rates are clamped by the floor band.
      uint256 _floor = _baseRate - Math.mulDiv(_baseRate, bandFloorPips, MAX_PIPS, Math.Rounding.Floor);
      _rate = Math.max(_dynamicRate, _floor);
    } else {
      // At or above base rates are clamped by the ceiling band.
      uint256 _ceiling = _baseRate + Math.mulDiv(_baseRate, bandCeilingPips, MAX_PIPS, Math.Rounding.Floor);
      _rate = Math.min(_dynamicRate, _ceiling);
    }
  }

  /**
   * @notice Validates that paired rate controls fit within the cooldown-derived max change.
   * @param _maxBaseRateChangePips Maximum base rate change in pips.
   * @param _baseRateUpdateCooldown Cooldown paired with the max base rate change.
   */
  function _validateRateControls(uint24 _maxBaseRateChangePips, uint48 _baseRateUpdateCooldown) internal pure {
    uint256 _updatesPerWeek = (1 weeks - 1) / _baseRateUpdateCooldown + 1;
    uint24 _maxBaseRateChangePipsForCooldown =
      _updatesPerWeek == 1 ? MAX_WEEKLY_RATE_CHANGE_PIPS : uint24(uint256(WEEKLY_LOG_BUDGET_PIPS) / _updatesPerWeek);
    if (_maxBaseRateChangePips > _maxBaseRateChangePipsForCooldown) {
      revert RateControlsTooAggressive();
    }
  }
}
