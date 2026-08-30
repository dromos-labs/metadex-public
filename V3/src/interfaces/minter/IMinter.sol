/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IMinter
 * @notice Root side minter interface for emission rate configuration and redeem triggered TOKEN minting.
 */
interface IMinter {
  /**
   * @notice Constructor parameters for `Minter`.
   * @dev There is no minimum base rate. Rate-change limits round up to one unit when the calculated limit is below
   * one unit. Deployments must use a base rate large enough that this rounding does not weaken the intended
   * percentage limit.
   * @param token Root token minted on redemption.
   * @param voter Root voter authorized to call `mint` and expose the current governor.
   * @param splitter Destination for the team rate mint share.
   * @param operator Address authorized to update the base emission rate.
   * @param migrationOpen Timestamp when migration opens. Must be a future epoch start.
   * @param initialBaseRate Initial non zero base emission rate, at most `MAX_BASE_RATE`.
   * @param maxBaseRateChangePips Initial maximum base rate change in pips. Zero pauses base rate updates.
   * @param baseRateUpdateCooldown Initial cooldown between accepted base rate updates.
   * @param teamRate Initial team mint share in pips.
   * @param maxBaseRateChangePipsCap Immutable cap for `maxBaseRateChangePips`.
   * @param minBaseRateUpdateCooldown Immutable lower bound for `baseRateUpdateCooldown`.
   * @param maxBaseRateUpdateCooldown Immutable upper bound for `baseRateUpdateCooldown`.
   * @param maxBandFloorPips Immutable cap for `bandFloorPips`.
   * @param maxBandCeilingPips Immutable cap for `bandCeilingPips`.
   */
  struct ConstructorParams {
    address token;
    address voter;
    address splitter;
    address operator;
    uint48 migrationOpen;
    uint232 initialBaseRate;
    uint24 maxBaseRateChangePips;
    uint48 baseRateUpdateCooldown;
    uint24 teamRate;
    uint24 maxBaseRateChangePipsCap;
    uint48 minBaseRateUpdateCooldown;
    uint48 maxBaseRateUpdateCooldown;
    uint24 maxBandFloorPips;
    uint24 maxBandCeilingPips;
  }

  /**
   * @notice Emitted when the operator updates the base emission rate.
   * @param _baseRate New base emission rate.
   */
  event BaseRateSet(uint232 _baseRate);

  /**
   * @notice Emitted when the dynamic emission rate target changes.
   * @dev Emitted by the dynamic rate module when it pushes a target and by the FED when disabling the module
   * clears the target.
   * @param _rate New dynamic emission rate target, stored raw and clamped to the band on read.
   */
  event DynamicRateSet(uint256 _rate);

  /**
   * @notice Emitted when governance updates the operator address.
   * @param _operator New operator address.
   */
  event OperatorSet(address indexed _operator);

  /**
   * @notice Emitted when governance updates the FED address.
   * @param _fed New FED address.
   */
  event FEDSet(address indexed _fed);

  /**
   * @notice Emitted when governance updates the maximum base rate change.
   * @param _maxBaseRateChangePips New maximum base rate change in pips.
   */
  event MaxBaseRateChangePipsSet(uint24 _maxBaseRateChangePips);

  /**
   * @notice Emitted when governance updates the base rate update cooldown.
   * @param _baseRateUpdateCooldown New cooldown in seconds.
   */
  event BaseRateUpdateCooldownSet(uint48 _baseRateUpdateCooldown);

  /**
   * @notice Emitted when governance updates the team mint share.
   * @param _teamRate New team mint share in pips.
   */
  event TeamRateSet(uint24 _teamRate);

  /**
   * @notice Emitted when governance updates the dynamic rate band.
   * @param _floorPips Maximum downward movement from base rate in pips.
   * @param _ceilingPips Maximum upward movement from base rate in pips.
   */
  event RateBandSet(uint24 _floorPips, uint24 _ceilingPips);

  /**
   * @notice Emitted when the FED updates the dynamic rate module authorized to push the dynamic rate.
   * @param _module New dynamic rate module, or zero address when unassigned.
   */
  event DynamicRateModuleSet(address _module);

  /**
   * @notice Emitted after a successful redeem triggered mint.
   * @param _recipient Recipient of the redeemed amount.
   * @param _amount Redeemed amount minted to `_recipient`.
   * @param _splitterShare Team share minted to `SPLITTER`.
   */
  event Minted(address indexed _recipient, uint256 _amount, uint256 _splitterShare);

  /// @notice Reverts when an address parameter that cannot be zero is zero.
  error ZeroAddress();

  /// @notice Reverts when the configured splitter is the minter contract itself.
  error InvalidSplitter();

  /// @notice Reverts when a base rate is zero.
  error InvalidBaseRate();

  /// @notice Reverts when a base rate exceeds `MAX_BASE_RATE`.
  error BaseRateTooHigh();

  /// @notice Reverts when the configured migration open is not a future epoch start.
  error InvalidActivationTimestamp();

  /// @notice Reverts when `teamRate` exceeds `MAXIMUM_TEAM_RATE`.
  error TeamRateTooHigh();

  /// @notice Reverts when the immutable max change cap exceeds the weekly maximum rate change.
  error MaxBaseRateChangeCapTooHigh();

  /// @notice Reverts when the immutable max change cap is zero.
  error MaxBaseRateChangeCapTooLow();

  /// @notice Reverts when `maxBaseRateChangePips` exceeds its immutable cap.
  error MaxBaseRateChangeTooHigh();

  /// @notice Reverts when the paired max change and cooldown allow excessive compounded rate movement.
  error RateControlsTooAggressive();

  /// @notice Reverts when the immutable minimum cooldown is zero.
  error MinCooldownTooLow();

  /// @notice Reverts when the minimum cooldown exceeds the maximum cooldown.
  error InvalidCooldownRange();

  /// @notice Reverts when `baseRateUpdateCooldown` is below its immutable minimum.
  error CooldownTooLow();

  /// @notice Reverts when `baseRateUpdateCooldown` exceeds its immutable maximum.
  error CooldownTooHigh();

  /// @notice Reverts when the immutable floor band cap is zero.
  error BandFloorCapTooLow();

  /// @notice Reverts when the immutable floor band cap reaches or exceeds `MAX_PIPS`, which would
  ///         allow a zero rate.
  error BandFloorCapTooWide();

  /// @notice Reverts when the immutable ceiling band cap is zero.
  error BandCeilingCapTooLow();

  /// @notice Reverts when the immutable ceiling band cap exceeds `MAX_PIPS`.
  error BandCeilingCapTooWide();

  /// @notice Reverts when `mint` is called by any address other than `VOTER`.
  error CallerNotVoter();

  /// @notice Reverts when a mint amount is below `MIN_MINT_AMOUNT`.
  error AmountTooLow();

  /// @notice Reverts when a mint would push `emissionsMinted` above `emissionsCap`.
  error CapExceeded();

  /// @notice Reverts when a governance gated setter is called by an address without `VOTER.GOVERNANCE_ROLE`.
  error CallerNotGovernor();

  /// @notice Reverts when `operator` and `fed` would become the same address.
  error OperatorFEDCollision();

  /// @notice Reverts when the floor band exceeds `MAX_BAND_FLOOR_PIPS`.
  error BandFloorTooWide();

  /// @notice Reverts when the ceiling band exceeds `MAX_BAND_CEILING_PIPS`.
  error BandCeilingTooWide();

  /// @notice Reverts when `setBaseRate` is called by any address other than `operator`.
  error CallerNotOperator();

  /// @notice Reverts when a base rate update is attempted before `nextBaseRateUpdate`.
  error CooldownActive();

  /// @notice Reverts when a base rate update would not change the rate.
  error SameRate();

  /**
   * @notice Reverts when a base rate update exceeds the allowed change.
   * @dev The allowed change is `baseRate * maxBaseRateChangePips / MAX_PIPS` rounded up, so it is
   * never zero for a non zero `maxBaseRateChangePips` and can exceed the nominal fraction at small base rates.
   */
  error RateChangeExceedsMax();

  /// @notice Reverts when `setDynamicRateModule` is called by any address other than `fed`.
  error CallerNotFED();

  /// @notice Reverts when `setDynamicRate` is called by any address other than `dynamicRateModule`.
  error CallerNotDynamicRateModule();

  /**
   * @notice Mints TOKEN for a redeem recipient and optionally mints the team share to `SPLITTER`.
   * @dev Amounts below `MIN_MINT_AMOUNT` revert so a non zero team rate share cannot round down to zero. The
   * leaf redeem entrypoint must enforce the same floor so a leaf side redeem can never be refused at settlement.
   * @dev The recipient amount counts against the accrued emissions cap. The team share does not count against
   * the cap because it is derived from the recipient amount and bounded separately by `MAXIMUM_TEAM_RATE`.
   * @param _amount Amount of TOKEN to mint to the recipient.
   * @param _recipient Recipient of the redeemed amount.
   */
  function mint(uint256 _amount, address _recipient) external;

  /**
   * @notice Updates the operator address. Governance only.
   * @param _operator New operator address.
   */
  function setOperator(address _operator) external;

  /**
   * @notice Updates the FED address. Governance only.
   * @param _fed New FED address, or zero address to leave the role unassigned.
   */
  function setFED(address _fed) external;

  /**
   * @notice Updates the maximum allowed base rate change. Governance only.
   * @dev A zero value pauses base rate updates until governance raises it. Successful calls delay
   * `nextBaseRateUpdate` to at least one week from the call without shortening a later deadline.
   * @param _maxBaseRateChangePips New maximum base rate change in pips.
   */
  function setMaxBaseRateChangePips(uint24 _maxBaseRateChangePips) external;

  /**
   * @notice Updates the base rate update cooldown. Governance only.
   * @dev Successful calls delay `nextBaseRateUpdate` to at least one week from the call without shortening a later
   * deadline.
   * @param _baseRateUpdateCooldown New cooldown in seconds.
   */
  function setBaseRateUpdateCooldown(uint48 _baseRateUpdateCooldown) external;

  /**
   * @notice Updates the team mint share. Governance only.
   * @param _teamRate New team mint share in pips.
   */
  function setTeamRate(uint24 _teamRate) external;

  /**
   * @notice Updates the dynamic module rate band. Governance only.
   * @dev The band is the current limit on the module's authority, not a snapshot taken at push time. Because
   * `setDynamicRate` stores its target raw, widening the band raises the effective rate of a target already pushed
   * and narrowing it lowers that rate, in both directions without a new module push. The cap accrues at the
   * outgoing effective rate first, so a band change only ever applies forward.
   * @param _floorPips Maximum downward movement from base rate in pips.
   * @param _ceilingPips Maximum upward movement from base rate in pips.
   */
  function setRateBand(uint24 _floorPips, uint24 _ceilingPips) external;

  /**
   * @notice Updates the base emission rate. Operator only.
   * @dev There is no minimum base rate. The allowed change rounds up to one unit, so a small base rate can change
   * by more than the configured percentage.
   * @param _newRate New non zero base emission rate, at most `MAX_BASE_RATE`.
   */
  function setBaseRate(uint232 _newRate) external;

  /**
   * @notice Updates the dynamic rate module authorized to push the dynamic rate. FED only.
   * @dev Setting the module to zero accrues the cap at the outgoing effective rate, then clears `dynamicRate` so
   * emissions fall back to `baseRate`. Replacing one non-zero module with another preserves the current target
   * until the replacement pushes a new one.
   * @param _module New dynamic rate module, or zero address to leave the push role unassigned.
   */
  function setDynamicRateModule(address _module) external;

  /**
   * @notice Accrues the emissions cap and stores a new dynamic emission rate target. Dynamic rate module only.
   * @dev Stores `_rate` raw; the band clamp is applied on read by `emissionRate`, so a later `baseRate` or band
   * change re-scopes the emission without another push. Setting the target to zero neutralizes the dynamic
   * override. The cap accrues only from `ACTIVATION_TIMESTAMP`.
   * @param _rate New dynamic emission rate target, stored raw and clamped to the band on read.
   */
  function setDynamicRate(uint256 _rate) external;

  /**
   * @notice Returns the emission rate read by the root voter.
   * @dev Returns zero while `block.timestamp < ACTIVATION_TIMESTAMP`; otherwise returns the stored `dynamicRate`
   * clamped to the band around the current `baseRate`. An unset band pins the effective rate to `baseRate`.
   * @return _rate Zero before activation; otherwise the effective rate after band clamping.
   */
  function emissionRate() external view returns (uint256 _rate);

  /**
   * @notice Minimum mintable amount. Matches `MAX_PIPS` so a non zero team rate share cannot
   *         round down to zero.
   * @return _minMintAmount Minimum mintable amount.
   */
  function MIN_MINT_AMOUNT() external view returns (uint256 _minMintAmount);

  /**
   * @notice Maximum allowed team rate.
   * @return _maximumTeamRate Maximum allowed team rate in pips.
   */
  function MAXIMUM_TEAM_RATE() external view returns (uint256 _maximumTeamRate);

  /**
   * @notice Maximum weekly base rate change budget.
   * @return _maxWeeklyRateChangePips Maximum weekly base rate change in pips.
   */
  function MAX_WEEKLY_RATE_CHANGE_PIPS() external view returns (uint24 _maxWeeklyRateChangePips);

  /**
   * @notice Weekly natural log budget used to scale shorter cooldowns.
   * @return _weeklyLogBudgetPips Weekly natural log budget in pips.
   */
  function WEEKLY_LOG_BUDGET_PIPS() external view returns (uint24 _weeklyLogBudgetPips);

  /**
   * @notice Maximum accepted base emission rate.
   * @dev Bounds rate-dependent Minter and Voter arithmetic over the full `uint48` timestamp horizon. The effective
   * rate is at most twice the base rate. At the minimum non-zero voting weight of one, the Voter scales that rate
   * by `1e18`, and its time-weighted accumulator grows by at most `type(uint48).max ** 2`. The bound is therefore
   * `floor(type(uint256).max / (2 * 1e18 * type(uint48).max ** 2))`, equal to
   * `730750818665456651398700951213`. This remains far above any viable emission rate.
   * @return _maxBaseRate Maximum accepted base emission rate.
   */
  function MAX_BASE_RATE() external view returns (uint232 _maxBaseRate);

  /**
   * @notice Root token minted on redemption.
   * @return _token Root token address.
   */
  function TOKEN() external view returns (address _token);

  /**
   * @notice Root voter authorized to call `mint`.
   * @return _voter Root voter address.
   */
  function VOTER() external view returns (address _voter);

  /**
   * @notice Team share splitter.
   * @return _splitter Splitter address.
   */
  function SPLITTER() external view returns (address _splitter);

  /**
   * @notice Timestamp at which emissions become active.
   * @return _activationTimestamp Emission activation timestamp.
   */
  function ACTIVATION_TIMESTAMP() external view returns (uint48 _activationTimestamp);

  /**
   * @notice Immutable cap for `maxBaseRateChangePips`.
   * @return _maxBaseRateChangePipsCap Immutable max change cap.
   */
  function MAX_BASE_RATE_CHANGE_PIPS_CAP() external view returns (uint24 _maxBaseRateChangePipsCap);

  /**
   * @notice Immutable minimum cooldown.
   * @return _minBaseRateUpdateCooldown Minimum base rate update cooldown.
   */
  function MIN_BASE_RATE_UPDATE_COOLDOWN() external view returns (uint48 _minBaseRateUpdateCooldown);

  /**
   * @notice Immutable maximum cooldown.
   * @return _maxBaseRateUpdateCooldown Maximum base rate update cooldown.
   */
  function MAX_BASE_RATE_UPDATE_COOLDOWN() external view returns (uint48 _maxBaseRateUpdateCooldown);

  /**
   * @notice Immutable floor band cap.
   * @return _maxBandFloorPips Maximum floor band in pips.
   */
  function MAX_BAND_FLOOR_PIPS() external view returns (uint24 _maxBandFloorPips);

  /**
   * @notice Immutable ceiling band cap.
   * @return _maxBandCeilingPips Maximum ceiling band in pips.
   */
  function MAX_BAND_CEILING_PIPS() external view returns (uint24 _maxBandCeilingPips);

  /**
   * @notice Current base emission rate.
   * @return _baseRate Base emission rate.
   */
  function baseRate() external view returns (uint232 _baseRate);

  /**
   * @notice Current operator address.
   * @return _operator Operator address.
   */
  function operator() external view returns (address _operator);

  /**
   * @notice Timestamp at which the next base rate update can execute.
   * @return _nextBaseRateUpdate Next accepted base rate update timestamp.
   */
  function nextBaseRateUpdate() external view returns (uint48 _nextBaseRateUpdate);

  /**
   * @notice Current FED address.
   * @return _fed FED address.
   */
  function fed() external view returns (address _fed);

  /**
   * @notice Current base rate update cooldown.
   * @return _baseRateUpdateCooldown Base rate update cooldown.
   */
  function baseRateUpdateCooldown() external view returns (uint48 _baseRateUpdateCooldown);

  /**
   * @notice Current maximum base rate change.
   * @return _maxBaseRateChangePips Maximum base rate change in pips.
   */
  function maxBaseRateChangePips() external view returns (uint24 _maxBaseRateChangePips);

  /**
   * @notice Current team mint share.
   * @return _teamRate Team mint share in pips.
   */
  function teamRate() external view returns (uint24 _teamRate);

  /**
   * @notice Current floor band.
   * @return _bandFloorPips Floor band in pips.
   */
  function bandFloorPips() external view returns (uint24 _bandFloorPips);

  /**
   * @notice Current ceiling band.
   * @return _bandCeilingPips Ceiling band in pips.
   */
  function bandCeilingPips() external view returns (uint24 _bandCeilingPips);

  /**
   * @notice Current dynamic rate module authorized to push the dynamic rate.
   * @return _dynamicRateModule Dynamic rate module address.
   */
  function dynamicRateModule() external view returns (address _dynamicRateModule);

  /**
   * @notice Current dynamic emission rate target, stored raw before band clamping. Zero means no target is in
   * effect and the emission rate is the base rate.
   * @return _dynamicRate Stored dynamic emission rate target.
   */
  function dynamicRate() external view returns (uint256 _dynamicRate);

  /**
   * @notice Cumulative recipient emissions cap accrued as of `lastCapUpdate`.
   * @dev Not re-accrued on read, so it lags the live value by the segment since `lastCapUpdate`; `mint` accrues the
   * elapsed segment before checking `emissionsMinted` against it, so the cap is exact at mint time.
   * @return _emissionsCap Accrued emissions cap.
   */
  function emissionsCap() external view returns (uint256 _emissionsCap);

  /**
   * @notice Timestamp the emissions cap was last accrued. Initialized to `ACTIVATION_TIMESTAMP`.
   * @return _lastCapUpdate Last cap accrual timestamp.
   */
  function lastCapUpdate() external view returns (uint48 _lastCapUpdate);

  /**
   * @notice Total TOKEN minted to redeem recipients, excluding team shares.
   * @return _emissionsMinted Cumulative recipient minting.
   */
  function emissionsMinted() external view returns (uint256 _emissionsMinted);
}
