// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';
import {Vm} from 'forge-std/Vm.sol';

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IToken} from 'V3/interfaces/minter/IToken.sol';
import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {Minter} from 'V3/minter/Minter.sol';

contract UnitMinter is TestHelpers {
  address internal immutable _TOKEN = makeAddr('Token');
  address internal immutable _VOTER = makeAddr('Voter');
  address internal immutable _SPLITTER = makeAddr('Splitter');
  address internal immutable _OPERATOR = makeAddr('Operator');
  address internal immutable _GOVERNOR = makeAddr('Governor');
  address internal immutable _FED = makeAddr('FED');
  address internal immutable _MODULE = makeAddr('Module');

  bytes32 internal constant _OPERATOR_SLOT = bytes32(uint256(0));
  bytes32 internal constant _RATE_CONFIG_SLOT = bytes32(uint256(1));
  bytes32 internal constant _BASE_RATE_SLOT = bytes32(uint256(2));
  bytes32 internal constant _DYNAMIC_RATE_MODULE_SLOT = bytes32(uint256(3));
  bytes32 internal constant _DYNAMIC_RATE_SLOT = bytes32(uint256(4));
  bytes32 internal constant _EMISSIONS_CAP_SLOT = bytes32(uint256(5));
  uint256 internal constant _NEXT_BASE_RATE_UPDATE_OFFSET = 20;
  uint256 internal constant _MAX_BASE_RATE_CHANGE_PIPS_OFFSET = 26;
  uint256 internal constant _FED_OFFSET = 0;
  uint256 internal constant _BASE_RATE_UPDATE_COOLDOWN_OFFSET = 20;
  uint256 internal constant _TEAM_RATE_OFFSET = 26;
  uint256 internal constant _BAND_FLOOR_PIPS_OFFSET = 29;
  uint256 internal constant _BAND_CEILING_PIPS_OFFSET = 0;
  uint256 internal constant _DYNAMIC_RATE_MODULE_OFFSET = 3;
  uint256 internal constant _LAST_CAP_UPDATE_OFFSET = 23;
  uint232 internal constant _INITIAL_BASE_RATE = 100 ether;
  // Rounded up to mirror the contract's Ceil bound on base rate changes.
  uint232 internal constant _MAX_BASE_RATE_CHANGE =
    uint232((uint256(_INITIAL_BASE_RATE) * uint256(_MAX_BASE_RATE_CHANGE_PIPS) + _PIPS - 1) / _PIPS);
  uint256 internal constant _PIPS = 1_000_000;
  uint24 internal constant _MAX_BASE_RATE_CHANGE_PIPS = 50_000;
  uint24 internal constant _RATE_BAND_PIPS = 100_000;
  uint256 internal constant _RATE_BAND_WIDTH = uint256(_INITIAL_BASE_RATE) * uint256(_RATE_BAND_PIPS) / _PIPS;
  // Live accrual fixture. The seeded target sits below the band floor, so the outgoing effective rate is the floor:
  // a value distinct from both the base rate and the raw target. An accrual that reads the wrong rate, or runs after
  // the incoming write instead of before it, therefore changes the result.
  uint256 internal constant _CLAMPED_TARGET = 1 ether;
  uint256 internal constant _ACCRUAL_RATE = _INITIAL_BASE_RATE - _RATE_BAND_WIDTH;
  uint256 internal constant _ACCRUAL_CEILING_RATE = _INITIAL_BASE_RATE + _RATE_BAND_WIDTH;
  uint256 internal constant _ACCRUAL_ELAPSED = 3 days;
  uint256 internal constant _ACCRUAL_ALLOWANCE = _ACCRUAL_RATE * _ACCRUAL_ELAPSED;
  uint48 internal constant _BASE_RATE_UPDATE_COOLDOWN = 7 days;
  uint24 internal constant _TEAM_RATE = 50_000;
  uint24 internal constant _MAX_BASE_RATE_CHANGE_PIPS_CAP = 50_000;
  uint48 internal constant _MIN_BASE_RATE_UPDATE_COOLDOWN = 1 hours;
  uint48 internal constant _MAX_BASE_RATE_UPDATE_COOLDOWN = 7 days;
  uint24 internal constant _MAX_BAND_FLOOR_PIPS = 250_000;
  uint24 internal constant _MAX_BAND_CEILING_PIPS = 250_000;
  uint48 internal constant _MIGRATION_OPEN = 1 weeks;
  uint48 internal constant _ACTIVATION_TIMESTAMP = _MIGRATION_OPEN + 1 weeks;
  uint48 internal constant _DEPLOYMENT_TIMESTAMP = _MIGRATION_OPEN - 1 hours;
  uint48 internal constant _FUTURE_MIGRATION_OPEN = _ACTIVATION_TIMESTAMP + 1 weeks;
  uint48 internal constant _FUTURE_ACTIVATION_TIMESTAMP = _FUTURE_MIGRATION_OPEN + 1 weeks;

  IMinter.ConstructorParams internal _defaultParams;
  Minter internal _minter;

  /*////////////////////////////////////////////////////////////
                            SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    // The constructor requires a future migration epoch, so deploy pre-migration and run tests post-activation.
    vm.warp(_DEPLOYMENT_TIMESTAMP);
    _defaultParams = IMinter.ConstructorParams({
      token: _TOKEN,
      voter: _VOTER,
      splitter: _SPLITTER,
      operator: _OPERATOR,
      migrationOpen: _MIGRATION_OPEN,
      initialBaseRate: _INITIAL_BASE_RATE,
      maxBaseRateChangePips: _MAX_BASE_RATE_CHANGE_PIPS,
      baseRateUpdateCooldown: _BASE_RATE_UPDATE_COOLDOWN,
      teamRate: _TEAM_RATE,
      maxBaseRateChangePipsCap: _MAX_BASE_RATE_CHANGE_PIPS_CAP,
      minBaseRateUpdateCooldown: _MIN_BASE_RATE_UPDATE_COOLDOWN,
      maxBaseRateUpdateCooldown: _MAX_BASE_RATE_UPDATE_COOLDOWN,
      maxBandFloorPips: _MAX_BAND_FLOOR_PIPS,
      maxBandCeilingPips: _MAX_BAND_CEILING_PIPS
    });
    _minter = new Minter(_defaultParams);
    vm.warp(_ACTIVATION_TIMESTAMP + 1);
    // Fresh constructions run post-activation, so default params carry the next future migration epoch.
    _defaultParams.migrationOpen = _FUTURE_MIGRATION_OPEN;
    // Default: any unauthorized caller fails the role check.
    vm.mockCall(_VOTER, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    // Override: `_GOVERNOR` holds `GOVERNANCE_ROLE`.
    vm.mockCall(_VOTER, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _GOVERNOR)), abi.encode(true));
  }

  /*////////////////////////////////////////////////////////////
                          CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenTheTokenIsTheZeroAddress() external {
    _defaultParams.token = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IMinter.ZeroAddress.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheVoterIsTheZeroAddress() external {
    _defaultParams.voter = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IMinter.ZeroAddress.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheSplitterIsTheZeroAddress() external {
    _defaultParams.splitter = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IMinter.ZeroAddress.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheOperatorIsTheZeroAddress() external {
    _defaultParams.operator = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IMinter.ZeroAddress.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheInitialBaseRateIsZero() external {
    _defaultParams.initialBaseRate = 0;

    // it should revert with InvalidBaseRate
    vm.expectRevert(IMinter.InvalidBaseRate.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheInitialBaseRateExceedsTheMaximumBaseRate(uint232 _initialBaseRate) external {
    _defaultParams.initialBaseRate = uint232(bound(_initialBaseRate, _minter.MAX_BASE_RATE() + 1, type(uint232).max));

    // it should revert with BaseRateTooHigh
    vm.expectRevert(IMinter.BaseRateTooHigh.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBaseRateChangeCapIsZero() external {
    _defaultParams.maxBaseRateChangePipsCap = 0;

    // it should revert with MaxBaseRateChangeCapTooLow
    vm.expectRevert(IMinter.MaxBaseRateChangeCapTooLow.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBaseRateChangeCapExceedsTheWeeklyMaximumRateChange() external {
    _defaultParams.maxBaseRateChangePipsCap = _minter.MAX_WEEKLY_RATE_CHANGE_PIPS() + 1;

    // it should revert with MaxBaseRateChangeCapTooHigh
    vm.expectRevert(IMinter.MaxBaseRateChangeCapTooHigh.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBaseRateChangeExceedsItsCap() external {
    _defaultParams.maxBaseRateChangePips = _defaultParams.maxBaseRateChangePipsCap + 1;

    // it should revert with MaxBaseRateChangeTooHigh
    vm.expectRevert(IMinter.MaxBaseRateChangeTooHigh.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMinCooldownIsZero() external {
    _defaultParams.minBaseRateUpdateCooldown = 0;

    // it should revert with MinCooldownTooLow
    vm.expectRevert(IMinter.MinCooldownTooLow.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMinCooldownExceedsTheMaxCooldown() external {
    _defaultParams.minBaseRateUpdateCooldown = _defaultParams.maxBaseRateUpdateCooldown + 1;

    // it should revert with InvalidCooldownRange
    vm.expectRevert(IMinter.InvalidCooldownRange.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheBaseRateUpdateCooldownIsBelowTheMinimumCooldown() external {
    _defaultParams.baseRateUpdateCooldown = _defaultParams.minBaseRateUpdateCooldown - 1;

    // it should revert with CooldownTooLow
    vm.expectRevert(IMinter.CooldownTooLow.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheBaseRateUpdateCooldownExceedsTheMaximumCooldown() external {
    _defaultParams.baseRateUpdateCooldown = _defaultParams.maxBaseRateUpdateCooldown + 1;

    // it should revert with CooldownTooHigh
    vm.expectRevert(IMinter.CooldownTooHigh.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheRateControlsExceedTheDiscreteCooldownDerivedMaximum() external {
    _defaultParams.baseRateUpdateCooldown = 6 days;
    // Linear proration allowed 41_820 pips for six days even though two updates fit within a week.
    _defaultParams.maxBaseRateChangePips = 41_820;

    // it should revert with RateControlsTooAggressive
    vm.expectRevert(IMinter.RateControlsTooAggressive.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBandFloorCapIsZero() external {
    _defaultParams.maxBandFloorPips = 0;

    // it should revert with BandFloorCapTooLow
    vm.expectRevert(IMinter.BandFloorCapTooLow.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBandFloorCapReachesTheMaximumPips() external {
    _defaultParams.maxBandFloorPips = uint24(MAX_PIPS);

    // it should revert with BandFloorCapTooWide
    vm.expectRevert(IMinter.BandFloorCapTooWide.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBandCeilingCapIsZero() external {
    _defaultParams.maxBandCeilingPips = 0;

    // it should revert with BandCeilingCapTooLow
    vm.expectRevert(IMinter.BandCeilingCapTooLow.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheMaxBandCeilingExceedsTheMaximumPips() external {
    _defaultParams.maxBandCeilingPips = uint24(MAX_PIPS + 1);

    // it should revert with BandCeilingCapTooWide
    vm.expectRevert(IMinter.BandCeilingCapTooWide.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheSplitterIsTheMinterAddress() external {
    _defaultParams.splitter = _computeCreate(address(this), vm.getNonce(address(this)));

    // it should revert with InvalidSplitter
    vm.expectRevert(IMinter.InvalidSplitter.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheTeamRateExceedsTheMaximumTeamRate() external {
    _defaultParams.teamRate = uint24(_minter.MAXIMUM_TEAM_RATE() + 1);

    // it should revert with TeamRateTooHigh
    vm.expectRevert(IMinter.TeamRateTooHigh.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenTheInitialNextBaseRateUpdateOverflows() external {
    vm.warp(1);
    _defaultParams.minBaseRateUpdateCooldown = type(uint48).max;
    _defaultParams.maxBaseRateUpdateCooldown = type(uint48).max;
    _defaultParams.baseRateUpdateCooldown = type(uint48).max;

    // it should revert with SafeCastOverflowedUintDowncast
    vm.expectRevert(
      abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), uint256(type(uint48).max) + 1)
    );
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenMigrationOpenIsZero() external {
    _defaultParams.migrationOpen = 0;

    // it should revert with InvalidActivationTimestamp
    vm.expectRevert(IMinter.InvalidActivationTimestamp.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenMigrationOpenIsInThePast() external {
    // Epoch aligned but already passed, isolating the future requirement.
    _defaultParams.migrationOpen = _MIGRATION_OPEN;

    // it should revert with InvalidActivationTimestamp
    vm.expectRevert(IMinter.InvalidActivationTimestamp.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenMigrationOpenEqualsCurrentTimestamp() external {
    vm.warp(_FUTURE_MIGRATION_OPEN);
    _defaultParams.migrationOpen = uint48(block.timestamp);

    // it should revert with InvalidActivationTimestamp
    vm.expectRevert(IMinter.InvalidActivationTimestamp.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenMigrationOpenIsNotEpochAligned(uint48 _misalignment) external {
    // In the future but off the epoch boundary, isolating the alignment requirement.
    _misalignment = uint48(bound(_misalignment, 1, 1 weeks - 1));
    _defaultParams.migrationOpen = _FUTURE_MIGRATION_OPEN + _misalignment;

    // it should revert with InvalidActivationTimestamp
    vm.expectRevert(IMinter.InvalidActivationTimestamp.selector);
    new Minter(_defaultParams);
  }

  function test_ConstructorWhenAllInputsAreValid() external {
    uint48 _expectedNextUpdate = uint48(block.timestamp + _BASE_RATE_UPDATE_COOLDOWN);

    _minter = new Minter(_defaultParams);

    // it should set the immutable dependencies
    assertEq(_minter.TOKEN(), _TOKEN);
    assertEq(_minter.VOTER(), _VOTER);
    assertEq(_minter.SPLITTER(), _SPLITTER);

    // it should set ACTIVATION_TIMESTAMP to one week after migrationOpen
    assertEq(_minter.ACTIVATION_TIMESTAMP(), _FUTURE_ACTIVATION_TIMESTAMP);

    // it should set the immutable configuration caps
    assertEq(_minter.MAX_BASE_RATE_CHANGE_PIPS_CAP(), _MAX_BASE_RATE_CHANGE_PIPS_CAP);
    assertEq(_minter.MIN_BASE_RATE_UPDATE_COOLDOWN(), _MIN_BASE_RATE_UPDATE_COOLDOWN);
    assertEq(_minter.MAX_BASE_RATE_UPDATE_COOLDOWN(), _MAX_BASE_RATE_UPDATE_COOLDOWN);
    assertEq(_minter.MAX_BAND_FLOOR_PIPS(), _MAX_BAND_FLOOR_PIPS);
    assertEq(_minter.MAX_BAND_CEILING_PIPS(), _MAX_BAND_CEILING_PIPS);
    assertEq(_minter.MAX_WEEKLY_RATE_CHANGE_PIPS(), _MAX_BASE_RATE_CHANGE_PIPS_CAP);
    assertEq(_minter.WEEKLY_LOG_BUDGET_PIPS(), 48_790);

    // it should leave dynamicRate at zero
    assertEq(_minter.dynamicRate(), 0);

    // it should set lastCapUpdate to ACTIVATION TIMESTAMP
    assertEq(_minter.lastCapUpdate(), _FUTURE_ACTIVATION_TIMESTAMP);

    // it should set the mutable configuration
    assertEq(_minter.operator(), _OPERATOR);
    assertEq(_minter.baseRate(), _INITIAL_BASE_RATE);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextUpdate);
    assertEq(_minter.maxBaseRateChangePips(), _MAX_BASE_RATE_CHANGE_PIPS);
    assertEq(_minter.baseRateUpdateCooldown(), _BASE_RATE_UPDATE_COOLDOWN);
    assertEq(_minter.teamRate(), _TEAM_RATE);

    // it should leave fed unset
    assertEq(_minter.fed(), address(0));

    // it should leave the rate band unset
    assertEq(_minter.bandFloorPips(), 0);
    assertEq(_minter.bandCeilingPips(), 0);

    // it should leave the dynamic rate module unset
    assertEq(_minter.dynamicRateModule(), address(0));
  }

  /*////////////////////////////////////////////////////////////
                          MAX BASE RATE
  ////////////////////////////////////////////////////////////*/

  function test_MAX_BASE_RATEShouldExposeTheExactMaximumBaseRateThatKeepsVoterArithmeticWithinUint256() external view {
    uint256 _maxBaseRate = _minter.MAX_BASE_RATE();
    uint256 _maxTimestamp = type(uint48).max;
    uint256 _voterArithmeticDenominator = 2 * 1e18 * _maxTimestamp * _maxTimestamp;

    // it should expose the exact maximum base rate that keeps Voter arithmetic within uint256
    assertEq(_maxBaseRate, 730_750_818_665_456_651_398_700_951_213);
    assertEq(_maxBaseRate, type(uint256).max / _voterArithmeticDenominator);
    (uint256 _safeHigh,) = Math.mul512(_maxBaseRate, _voterArithmeticDenominator);
    (uint256 _unsafeHigh,) = Math.mul512(_maxBaseRate + 1, _voterArithmeticDenominator);
    assertEq(_safeHigh, 0);
    assertEq(_unsafeHigh, 1);
  }

  /*////////////////////////////////////////////////////////////
                              MINT
  ////////////////////////////////////////////////////////////*/

  function test_MintWhenTheCallerIsNotTheVoter(address _caller, uint256 _amount, address _recipient) external {
    _caller = _boundNotEq(_caller, _VOTER);

    // it should revert with CallerNotVoter
    vm.expectRevert(IMinter.CallerNotVoter.selector);
    vm.prank(_caller);
    _minter.mint(_amount, _recipient);
  }

  function test_MintWhenTheAmountIsBelowTheMinimumMintAmount(uint256 _amount, address _recipient) external {
    _amount = bound(_amount, 0, _minter.MIN_MINT_AMOUNT() - 1);

    // it should revert with AmountTooLow
    vm.expectRevert(IMinter.AmountTooLow.selector);
    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);
  }

  function test_MintWhenTheMintWouldExceedTheEmissionsCap(uint256 _amount, address _recipient, uint256 _cap) external {
    _amount = bound(_amount, _minter.MIN_MINT_AMOUNT(), type(uint256).max);
    // Freeze accrual so the cap equals the stored value, then store it strictly below the recipient amount.
    _setLastCapUpdate(uint48(block.timestamp));
    _cap = bound(_cap, 0, _amount - 1);
    _setEmissionsCap(_cap);

    // it should revert with CapExceeded
    vm.expectRevert(IMinter.CapExceeded.selector);
    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);
  }

  function test_MintWhenTheRecipientAmountFitsButTheRecipientAndTeamTotalExceedsTheEmissionsCap(
    uint256 _amount,
    address _recipient
  ) external {
    _amount = bound(_amount, _minter.MIN_MINT_AMOUNT(), type(uint256).max);
    uint256 _splitterShare = Math.mulDiv(_amount, _TEAM_RATE, MAX_PIPS, Math.Rounding.Floor);
    _setLastCapUpdate(uint48(block.timestamp));
    _setEmissionsCap(_amount);

    // it should mint _amount to _recipient
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_recipient, _amount)), '', 1);
    // it should mint _splitterShare to SPLITTER
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_SPLITTER, _splitterShare)), '', 1);

    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);

    // it should increase emissionsMinted by _amount
    assertEq(_minter.emissionsMinted(), _amount);
  }

  function test_MintWhenTheCumulativeTotalExceedsTheEmissionsCapAndTheAmountAloneFits(
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _cap,
    address _recipient
  ) external {
    // Freeze accrual so the cap stays at the stored value across both mints.
    _setLastCapUpdate(uint48(block.timestamp));
    uint256 _minimum = _minter.MIN_MINT_AMOUNT();
    // Halve the range so the two amounts summed cannot overflow.
    _cap = bound(_cap, 2 * _minimum, type(uint256).max / 2);
    _setEmissionsCap(_cap);
    _firstAmount = bound(_firstAmount, _minimum, _cap - _minimum);
    // The second amount clears the cap on its own and breaches it only once the first mint is counted.
    _secondAmount = bound(_secondAmount, Math.max(_minimum, _cap - _firstAmount + 1), _cap);
    // Expecting the first mint's legs proves it settled, so the revert below can only come from the running total.
    // The minimum mint amount keeps the team share non zero, so the two legs never share calldata.
    _mockAndExpect(_TOKEN, abi.encodeCall(IToken.mint, (_recipient, _firstAmount)), '');
    _mockAndExpect(
      _TOKEN,
      abi.encodeCall(IToken.mint, (_SPLITTER, Math.mulDiv(_firstAmount, _TEAM_RATE, MAX_PIPS, Math.Rounding.Floor))),
      ''
    );

    vm.startPrank(_VOTER);
    _minter.mint(_firstAmount, _recipient);

    // it should revert with CapExceeded
    vm.expectRevert(IMinter.CapExceeded.selector);
    _minter.mint(_secondAmount, _recipient);
    vm.stopPrank();
  }

  function test_MintWhenASecondMintFollowsAnEarlierMint(
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _cap,
    address _firstRecipient,
    address _secondRecipient
  ) external {
    _setLastCapUpdate(uint48(block.timestamp));
    uint256 _minimum = _minter.MIN_MINT_AMOUNT();
    _cap = bound(_cap, 2 * _minimum, type(uint256).max / 2);
    _setEmissionsCap(_cap);
    // Half the cap each, so both mints clear the cumulative check.
    _firstAmount = bound(_firstAmount, _minimum, _cap / 2);
    _secondAmount = bound(_secondAmount, _minimum, _cap / 2);
    // Distinct recipients keep the two legs on distinct calldata even when the fuzzed amounts coincide. The team
    // share is orthogonal to the running total and covered by the team rate cases, so it stays out of the way.
    _secondRecipient = _boundNotEq(_secondRecipient, _firstRecipient);
    _setTeamRate(0);
    _mockAndExpect(_TOKEN, abi.encodeCall(IToken.mint, (_firstRecipient, _firstAmount)), '');
    _mockAndExpect(_TOKEN, abi.encodeCall(IToken.mint, (_secondRecipient, _secondAmount)), '');

    vm.startPrank(_VOTER);
    _minter.mint(_firstAmount, _firstRecipient);
    _minter.mint(_secondAmount, _secondRecipient);
    vm.stopPrank();

    // it should increase emissionsMinted by both amounts
    assertEq(_minter.emissionsMinted(), _firstAmount + _secondAmount);
  }

  /**
   * @dev Seeds a live band, a target the band clamps and an elapsed segment past activation, leaving the stored cap
   * at zero. The accrual then integrates the band floor: a rate distinct from both the base rate and the raw target,
   * so an accrual that reads the wrong one, or that runs after the incoming write instead of before it, changes the
   * result. For `mint` it also makes the accrual the only source of allowance. The warp clears the rate cooldown.
   */
  modifier givenTheAccrualSegmentIsLive() {
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(_CLAMPED_TARGET);
    vm.warp(_ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
    _;
  }

  function test_MintWhenTheTeamRateIsZero(uint256 _amount, address _recipient) external givenTheAccrualSegmentIsLive {
    _amount = bound(_amount, _minter.MIN_MINT_AMOUNT(), _ACCRUAL_ALLOWANCE);
    _setTeamRate(0);

    // it should mint _amount to _recipient
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_recipient, _amount)), '', 1);

    // it should not mint zero _splitterShare to SPLITTER
    vm.expectCall(_TOKEN, abi.encodeCall(IToken.mint, (_SPLITTER, uint256(0))), 0);

    // it should emit Minted with _recipient, _amount and zero _splitterShare
    _expectEmit(address(_minter));
    emit IMinter.Minted(_recipient, _amount, 0);

    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);

    // it should increase emissionsMinted by _amount
    assertEq(_minter.emissionsMinted(), _amount);
    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);
  }

  function test_MintWhenTheTeamRateIsNotZero(
    uint256 _amount,
    address _recipient
  ) external givenTheAccrualSegmentIsLive {
    _amount = bound(_amount, _minter.MIN_MINT_AMOUNT(), _ACCRUAL_ALLOWANCE);
    uint256 _splitterShare = Math.mulDiv(_amount, _TEAM_RATE, MAX_PIPS, Math.Rounding.Floor);

    // it should mint _amount to _recipient
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_recipient, _amount)), '', 1);

    // it should mint _splitterShare to SPLITTER
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_SPLITTER, _splitterShare)), '', 1);

    // it should emit Minted with _recipient, _amount and _splitterShare
    _expectEmit(address(_minter));
    emit IMinter.Minted(_recipient, _amount, _splitterShare);

    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);

    // it should increase emissionsMinted by _amount
    assertEq(_minter.emissionsMinted(), _amount);
    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);
  }

  function test_MintWhenTheTeamRateIsNotZeroAndTheSplitterShareHasARemainder(address _recipient)
    external
    givenTheAccrualSegmentIsLive
  {
    // 5% of 1_000_001 = 50_000.05, rounded down to 50_000.
    uint256 _amount = 1_000_001;
    uint256 _splitterShare = 50_000;

    // it should mint _amount to _recipient
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_recipient, _amount)), '', 1);

    // it should mint the rounded down _splitterShare to SPLITTER
    _mockAndExpectWithTimes(_TOKEN, abi.encodeCall(IToken.mint, (_SPLITTER, _splitterShare)), '', 1);

    // it should emit Minted with _recipient, _amount and the rounded down _splitterShare
    _expectEmit(address(_minter));
    emit IMinter.Minted(_recipient, _amount, _splitterShare);

    vm.prank(_VOTER);
    _minter.mint(_amount, _recipient);

    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);
  }

  /*////////////////////////////////////////////////////////////
                          SET OPERATOR
  ////////////////////////////////////////////////////////////*/

  function test_SetOperatorWhenTheCallerIsNotTheGovernor(address _caller, address _operator) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setOperator(_operator);
  }

  function test_SetOperatorWhenTheOperatorIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMinter.ZeroAddress.selector);
    vm.prank(_GOVERNOR);
    _minter.setOperator(address(0));
  }

  function test_SetOperatorWhenTheOperatorEqualsFed() external {
    _setFED(_FED);

    // it should revert with OperatorFEDCollision
    vm.expectRevert(IMinter.OperatorFEDCollision.selector);
    vm.prank(_GOVERNOR);
    _minter.setOperator(_FED);
  }

  function test_SetOperatorWhenTheOperatorIsValid(address _operator) external {
    _assumeFuzzable(_operator);

    // it should emit OperatorSet with _operator
    _expectEmit(address(_minter));
    emit IMinter.OperatorSet(_operator);

    vm.prank(_GOVERNOR);
    _minter.setOperator(_operator);

    // it should update operator with _operator
    assertEq(_minter.operator(), _operator);
  }

  /*////////////////////////////////////////////////////////////
                            SET FED
  ////////////////////////////////////////////////////////////*/

  function test_SetFEDWhenTheCallerIsNotTheGovernor(address _caller, address _fed) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setFED(_fed);
  }

  function test_SetFEDWhenFedEqualsOperator() external {
    // it should revert with OperatorFEDCollision
    vm.expectRevert(IMinter.OperatorFEDCollision.selector);
    vm.prank(_GOVERNOR);
    _minter.setFED(_OPERATOR);
  }

  function test_SetFEDWhenFedIsValid(address _fed) external {
    vm.assume(_fed != _OPERATOR);

    // it should emit FEDSet with _fed
    _expectEmit(address(_minter));
    emit IMinter.FEDSet(_fed);

    vm.prank(_GOVERNOR);
    _minter.setFED(_fed);

    // it should update fed with _fed
    assertEq(_minter.fed(), _fed);
  }

  /*////////////////////////////////////////////////////////////
                    SET MAX BASE RATE CHANGE
  ////////////////////////////////////////////////////////////*/

  function test_SetMaxBaseRateChangePipsWhenTheCallerIsNotTheGovernor(address _caller, uint24 _value) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setMaxBaseRateChangePips(_value);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheMaxBaseRateChangePipsExceedsTheImmutableCap() external {
    uint24 _maxBaseRateChangePips = _minter.MAX_BASE_RATE_CHANGE_PIPS_CAP() + 1;
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with MaxBaseRateChangeTooHigh
    vm.expectRevert(IMinter.MaxBaseRateChangeTooHigh.selector);
    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheMaxBaseRateChangePipsExceedsTheDiscreteCooldownDerivedMaximum()
    external
  {
    _setBaseRateUpdateCooldown(6 days);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // Two weekly updates split the 48_790 pips log budget into a 24_395 pips maximum.
    // it should revert with RateControlsTooAggressive
    vm.expectRevert(IMinter.RateControlsTooAggressive.selector);
    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(24_396);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheTransitionDelayOverflows() external {
    uint24 _maxBaseRateChangePips = _MAX_BASE_RATE_CHANGE_PIPS;
    uint24 _oldMaxBaseRateChangePips = _minter.maxBaseRateChangePips();
    uint48 _oldNextBaseRateUpdate = _minter.nextBaseRateUpdate();

    vm.warp(uint256(type(uint48).max) - 1 weeks + 1);
    uint256 _overflowingNextBaseRateUpdate = block.timestamp + 1 weeks;

    // it should revert with SafeCastOverflowedUintDowncast
    vm.expectRevert(
      abi.encodeWithSelector(
        SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), _overflowingNextBaseRateUpdate
      )
    );
    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    // it should leave maxBaseRateChangePips unchanged
    assertEq(_minter.maxBaseRateChangePips(), _oldMaxBaseRateChangePips);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _oldNextBaseRateUpdate);
  }

  modifier whenTheMaxBaseRateChangePipsIsValid() {
    _;
  }

  function test_SetMaxBaseRateChangePipsWhenTheMinimumTransitionDeadlineIsLaterThanNextBaseRateUpdate(uint24 _maxBaseRateChangePips)
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    _maxBaseRateChangePips = uint24(bound(_maxBaseRateChangePips, 0, _minter.MAX_BASE_RATE_CHANGE_PIPS_CAP()));

    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    // it should emit MaxBaseRateChangePipsSet with _maxBaseRateChangePips
    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_maxBaseRateChangePips);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    // it should update maxBaseRateChangePips with _maxBaseRateChangePips
    assertEq(_minter.maxBaseRateChangePips(), _maxBaseRateChangePips);

    // it should update nextBaseRateUpdate with block.timestamp plus one week
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheMinimumTransitionDeadlineIsNotLaterThanNextBaseRateUpdate(uint24 _maxBaseRateChangePips)
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    _maxBaseRateChangePips = uint24(bound(_maxBaseRateChangePips, 0, _minter.MAX_BASE_RATE_CHANGE_PIPS_CAP()));
    uint48 _nextBaseRateUpdate = uint48(block.timestamp + 1 weeks + 1 days);
    _setNextBaseRateUpdate(_nextBaseRateUpdate);

    // it should emit MaxBaseRateChangePipsSet with _maxBaseRateChangePips
    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_maxBaseRateChangePips);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    // it should update maxBaseRateChangePips with _maxBaseRateChangePips
    assertEq(_minter.maxBaseRateChangePips(), _maxBaseRateChangePips);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenUsingASixDayCooldownAtTheDiscreteDerivedMaximum()
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    uint24 _maxBaseRateChangePips = 24_395;
    _setBaseRateUpdateCooldown(6 days);
    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_maxBaseRateChangePips);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    assertEq(_minter.maxBaseRateChangePips(), _maxBaseRateChangePips);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheCooldownDividesTheWeekAtTheDiscreteDerivedMaximum()
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    uint24 _maxBaseRateChangePips = 290;
    _setBaseRateUpdateCooldown(1 hours);
    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_maxBaseRateChangePips);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_maxBaseRateChangePips);

    assertEq(_minter.maxBaseRateChangePips(), _maxBaseRateChangePips);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheOneHourCooldownValueExceedsTheDiscreteDerivedMaximum() external {
    _setBaseRateUpdateCooldown(1 hours);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with RateControlsTooAggressive
    vm.expectRevert(IMinter.RateControlsTooAggressive.selector);
    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(291);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenTheValueEqualsTheCurrentValue()
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_MAX_BASE_RATE_CHANGE_PIPS);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_MAX_BASE_RATE_CHANGE_PIPS);

    assertEq(_minter.maxBaseRateChangePips(), _MAX_BASE_RATE_CHANGE_PIPS);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetMaxBaseRateChangePipsWhenNextBaseRateUpdateEqualsTheTransitionDelay()
    external
    whenTheMaxBaseRateChangePipsIsValid
  {
    uint48 _nextBaseRateUpdate = uint48(block.timestamp + 1 weeks);
    _setNextBaseRateUpdate(_nextBaseRateUpdate);

    _expectEmit(address(_minter));
    emit IMinter.MaxBaseRateChangePipsSet(_MAX_BASE_RATE_CHANGE_PIPS);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_MAX_BASE_RATE_CHANGE_PIPS);

    assertEq(_minter.maxBaseRateChangePips(), _MAX_BASE_RATE_CHANGE_PIPS);
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  /*////////////////////////////////////////////////////////////
                  SET BASE RATE UPDATE COOLDOWN
  ////////////////////////////////////////////////////////////*/

  function test_SetBaseRateUpdateCooldownWhenTheCallerIsNotTheGovernor(address _caller, uint48 _cooldown) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setBaseRateUpdateCooldown(_cooldown);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheBaseRateUpdateCooldownIsBelowTheMinimumCooldown() external {
    uint48 _baseRateUpdateCooldown = _minter.MIN_BASE_RATE_UPDATE_COOLDOWN() - 1;
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with CooldownTooLow
    vm.expectRevert(IMinter.CooldownTooLow.selector);
    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_baseRateUpdateCooldown);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheBaseRateUpdateCooldownExceedsTheMaximumCooldown() external {
    uint48 _baseRateUpdateCooldown = _minter.MAX_BASE_RATE_UPDATE_COOLDOWN() + 1;
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with CooldownTooHigh
    vm.expectRevert(IMinter.CooldownTooHigh.selector);
    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_baseRateUpdateCooldown);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheCurrentMaxBaseRateChangeExceedsTheDiscreteCooldownDerivedMaximum()
    external
  {
    _setMaxBaseRateChangePips(41_820);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();

    // it should revert with RateControlsTooAggressive
    vm.expectRevert(IMinter.RateControlsTooAggressive.selector);
    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(6 days);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheTransitionDelayOverflows() external {
    uint48 _baseRateUpdateCooldown = _BASE_RATE_UPDATE_COOLDOWN;
    uint48 _oldBaseRateUpdateCooldown = _minter.baseRateUpdateCooldown();
    uint48 _oldNextBaseRateUpdate = _minter.nextBaseRateUpdate();

    vm.warp(uint256(type(uint48).max) - 1 weeks + 1);
    uint256 _overflowingNextBaseRateUpdate = block.timestamp + 1 weeks;

    // it should revert with SafeCastOverflowedUintDowncast
    vm.expectRevert(
      abi.encodeWithSelector(
        SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), _overflowingNextBaseRateUpdate
      )
    );
    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_baseRateUpdateCooldown);

    // it should leave baseRateUpdateCooldown unchanged
    assertEq(_minter.baseRateUpdateCooldown(), _oldBaseRateUpdateCooldown);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _oldNextBaseRateUpdate);
  }

  modifier whenTheBaseRateUpdateCooldownIsValid() {
    _;
  }

  function test_SetBaseRateUpdateCooldownWhenTheMinimumTransitionDeadlineIsLaterThanNextBaseRateUpdate(uint48 _baseRateUpdateCooldown)
    external
    whenTheBaseRateUpdateCooldownIsValid
  {
    _baseRateUpdateCooldown = uint48(
      bound(_baseRateUpdateCooldown, _minter.MIN_BASE_RATE_UPDATE_COOLDOWN(), _minter.MAX_BASE_RATE_UPDATE_COOLDOWN())
    );
    // Zero max change so any cooldown in the immutable range is valid under the discrete weekly budget.
    _setMaxBaseRateChangePips(0);

    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    // it should emit BaseRateUpdateCooldownSet with _baseRateUpdateCooldown
    _expectEmit(address(_minter));
    emit IMinter.BaseRateUpdateCooldownSet(_baseRateUpdateCooldown);

    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_baseRateUpdateCooldown);

    // it should update baseRateUpdateCooldown with _baseRateUpdateCooldown
    assertEq(_minter.baseRateUpdateCooldown(), _baseRateUpdateCooldown);

    // it should update nextBaseRateUpdate with block.timestamp plus one week
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheMinimumTransitionDeadlineIsNotLaterThanNextBaseRateUpdate(uint48 _baseRateUpdateCooldown)
    external
    whenTheBaseRateUpdateCooldownIsValid
  {
    _baseRateUpdateCooldown = uint48(
      bound(_baseRateUpdateCooldown, _minter.MIN_BASE_RATE_UPDATE_COOLDOWN(), _minter.MAX_BASE_RATE_UPDATE_COOLDOWN())
    );
    _setMaxBaseRateChangePips(0);
    uint48 _nextBaseRateUpdate = uint48(block.timestamp + 1 weeks + 1 days);
    _setNextBaseRateUpdate(_nextBaseRateUpdate);

    // it should emit BaseRateUpdateCooldownSet with _baseRateUpdateCooldown
    _expectEmit(address(_minter));
    emit IMinter.BaseRateUpdateCooldownSet(_baseRateUpdateCooldown);

    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_baseRateUpdateCooldown);

    // it should update baseRateUpdateCooldown with _baseRateUpdateCooldown
    assertEq(_minter.baseRateUpdateCooldown(), _baseRateUpdateCooldown);

    // it should leave nextBaseRateUpdate unchanged
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenTheValueEqualsTheCurrentValue()
    external
    whenTheBaseRateUpdateCooldownIsValid
  {
    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    _expectEmit(address(_minter));
    emit IMinter.BaseRateUpdateCooldownSet(_BASE_RATE_UPDATE_COOLDOWN);

    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_BASE_RATE_UPDATE_COOLDOWN);

    assertEq(_minter.baseRateUpdateCooldown(), _BASE_RATE_UPDATE_COOLDOWN);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_SetBaseRateUpdateCooldownWhenNextBaseRateUpdateIsAfterTheTransitionDelay()
    external
    whenTheBaseRateUpdateCooldownIsValid
  {
    _defaultParams.baseRateUpdateCooldown = 8 days;
    _defaultParams.maxBaseRateUpdateCooldown = 8 days;
    _minter = new Minter(_defaultParams);
    uint48 _nextBaseRateUpdate = _minter.nextBaseRateUpdate();
    assertEq(_nextBaseRateUpdate, uint48(block.timestamp + 8 days));
    assertGt(_nextBaseRateUpdate, uint48(block.timestamp + 1 weeks));

    _expectEmit(address(_minter));
    emit IMinter.BaseRateUpdateCooldownSet(8 days);

    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(8 days);

    assertEq(_minter.baseRateUpdateCooldown(), 8 days);
    assertEq(_minter.nextBaseRateUpdate(), _nextBaseRateUpdate);
  }

  /*////////////////////////////////////////////////////////////
                       RATE CONTROL SETTERS
  ////////////////////////////////////////////////////////////*/

  function test_RateControlSettersWhenBothSettersAreCalledInTheSameBlock() external {
    _setNextBaseRateUpdate(uint48(block.timestamp));
    uint48 _expectedNextBaseRateUpdate = uint48(block.timestamp + 1 weeks);

    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(_BASE_RATE_UPDATE_COOLDOWN);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(_MAX_BASE_RATE_CHANGE_PIPS);

    assertEq(_minter.baseRateUpdateCooldown(), _BASE_RATE_UPDATE_COOLDOWN);
    assertEq(_minter.maxBaseRateChangePips(), _MAX_BASE_RATE_CHANGE_PIPS);
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextBaseRateUpdate);
  }

  function test_RateControlSettersWhenChangingFromSixDayControlsToSevenDayControls() external {
    uint256 _transitionTime = 10 days;
    vm.warp(_transitionTime);

    // Seed old six-day controls and the stale operator deadline scheduled under those controls.
    _setBaseRateUpdateCooldown(6 days);
    _setMaxBaseRateChangePips(24_395);
    _setNextBaseRateUpdate(uint48(_transitionTime + 6 days));

    // Transition cooldown first (still valid under 24_395), then raise max under seven-day controls.
    vm.prank(_GOVERNOR);
    _minter.setBaseRateUpdateCooldown(7 days);

    vm.prank(_GOVERNOR);
    _minter.setMaxBaseRateChangePips(50_000);

    assertEq(_minter.baseRateUpdateCooldown(), 7 days);
    assertEq(_minter.maxBaseRateChangePips(), 50_000);
    assertEq(_minter.nextBaseRateUpdate(), uint48(_transitionTime + 7 days));

    // Operator remains blocked at the stale six-day deadline.
    vm.warp(_transitionTime + 6 days);
    vm.expectRevert(IMinter.CooldownActive.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_INITIAL_BASE_RATE + 1);

    // Operator can update at the extended one-week deadline.
    vm.warp(_transitionTime + 7 days);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_INITIAL_BASE_RATE + 1);
    assertEq(_minter.baseRate(), _INITIAL_BASE_RATE + 1);
  }

  /*////////////////////////////////////////////////////////////
                          SET TEAM RATE
  ////////////////////////////////////////////////////////////*/

  function test_SetTeamRateWhenTheCallerIsNotTheGovernor(address _caller, uint24 _teamRate) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setTeamRate(_teamRate);
  }

  function test_SetTeamRateWhenTheTeamRateExceedsTheMaximumTeamRate() external {
    uint24 _teamRate = uint24(_minter.MAXIMUM_TEAM_RATE() + 1);

    // it should revert with TeamRateTooHigh
    vm.expectRevert(IMinter.TeamRateTooHigh.selector);
    vm.prank(_GOVERNOR);
    _minter.setTeamRate(_teamRate);
  }

  function test_SetTeamRateWhenTheTeamRateIsValid(uint24 _teamRate) external {
    _teamRate = uint24(bound(_teamRate, 0, _minter.MAXIMUM_TEAM_RATE()));

    // it should emit TeamRateSet with _teamRate
    _expectEmit(address(_minter));
    emit IMinter.TeamRateSet(_teamRate);

    vm.prank(_GOVERNOR);
    _minter.setTeamRate(_teamRate);

    // it should update teamRate with _teamRate
    assertEq(_minter.teamRate(), _teamRate);
  }

  /*////////////////////////////////////////////////////////////
                          SET RATE BAND
  ////////////////////////////////////////////////////////////*/

  function test_SetRateBandWhenTheCallerIsNotTheGovernor(
    address _caller,
    uint24 _floorPips,
    uint24 _ceilingPips
  ) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);

    // it should revert with CallerNotGovernor
    vm.expectRevert(IMinter.CallerNotGovernor.selector);
    vm.prank(_caller);
    _minter.setRateBand(_floorPips, _ceilingPips);
  }

  function test_SetRateBandWhenTheFloorPipsExceedsTheImmutableCap(uint24 _floorPips, uint24 _ceilingPips) external {
    _floorPips = uint24(bound(_floorPips, _minter.MAX_BAND_FLOOR_PIPS() + 1, type(uint24).max));

    // it should revert with BandFloorTooWide
    vm.expectRevert(IMinter.BandFloorTooWide.selector);
    vm.prank(_GOVERNOR);
    _minter.setRateBand(_floorPips, _ceilingPips);
  }

  function test_SetRateBandWhenTheCeilingPipsExceedsTheImmutableCap(uint24 _floorPips, uint24 _ceilingPips) external {
    _floorPips = uint24(bound(_floorPips, 0, _minter.MAX_BAND_FLOOR_PIPS()));
    _ceilingPips = uint24(bound(_ceilingPips, _minter.MAX_BAND_CEILING_PIPS() + 1, type(uint24).max));

    // it should revert with BandCeilingTooWide
    vm.expectRevert(IMinter.BandCeilingTooWide.selector);
    vm.prank(_GOVERNOR);
    _minter.setRateBand(_floorPips, _ceilingPips);
  }

  function test_SetRateBandWhenTheRateBandIsSetBeforeActivation(uint24 _floorPips, uint24 _ceilingPips) external {
    _floorPips = uint24(bound(_floorPips, 0, _minter.MAX_BAND_FLOOR_PIPS()));
    _ceilingPips = uint24(bound(_ceilingPips, 0, _minter.MAX_BAND_CEILING_PIPS()));
    vm.warp(_ACTIVATION_TIMESTAMP - 100);

    // it should emit RateBandSet with _floorPips and _ceilingPips
    _expectEmit(address(_minter));
    emit IMinter.RateBandSet(_floorPips, _ceilingPips);

    vm.prank(_GOVERNOR);
    _minter.setRateBand(_floorPips, _ceilingPips);

    // it should update bandFloorPips with _floorPips
    assertEq(_minter.bandFloorPips(), _floorPips);
    // it should update bandCeilingPips with _ceilingPips
    assertEq(_minter.bandCeilingPips(), _ceilingPips);
    // it should leave the emissions cap at zero
    assertEq(_minter.emissionsCap(), 0);
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP);
  }

  function test_SetRateBandWhenTheRateBandIsSetAfterActivation(uint24 _floorPips, uint24 _ceilingPips) external {
    _floorPips = uint24(bound(_floorPips, 0, _minter.MAX_BAND_FLOOR_PIPS()));
    _ceilingPips = uint24(bound(_ceilingPips, 0, _minter.MAX_BAND_CEILING_PIPS()));
    uint256 _elapsed = 3 days;
    vm.warp(_ACTIVATION_TIMESTAMP + _elapsed);
    // A raw target above the base rate: with no band yet, the outgoing effective rate clamps to the base rate,
    // so accruing at the incoming band instead would over-credit the elapsed segment.
    _setDynamicRate(_INITIAL_BASE_RATE + 5 ether);
    uint256 _expectedCap = uint256(_INITIAL_BASE_RATE) * _elapsed;

    // it should emit RateBandSet with _floorPips and _ceilingPips
    _expectEmit(address(_minter));
    emit IMinter.RateBandSet(_floorPips, _ceilingPips);

    vm.prank(_GOVERNOR);
    _minter.setRateBand(_floorPips, _ceilingPips);

    // it should update bandFloorPips with _floorPips
    assertEq(_minter.bandFloorPips(), _floorPips);
    // it should update bandCeilingPips with _ceilingPips
    assertEq(_minter.bandCeilingPips(), _ceilingPips);
    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _expectedCap);
    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP + _elapsed);
  }

  function test_SetRateBandWhenAccruingAtTheMaximumBaseRateAndTheWidestBandOverTheFullTimestampHorizon() external {
    // Worst case for the accrual: the largest accepted base rate, a ceiling band that doubles it, and the longest
    // interval a uint48 lastCapUpdate can span.
    uint232 _maxBaseRate = _minter.MAX_BASE_RATE();
    uint24 _widestCeilingPips = uint24(MAX_PIPS);
    _defaultParams.initialBaseRate = _maxBaseRate;
    _defaultParams.maxBandCeilingPips = _widestCeilingPips;
    _minter = new Minter(_defaultParams);
    _setRateBand(0, _widestCeilingPips);
    _setDynamicRate(type(uint256).max);
    uint256 _elapsed = type(uint48).max - _FUTURE_ACTIVATION_TIMESTAMP;
    vm.warp(type(uint48).max);
    // A 100% ceiling band puts the effective rate at twice the base rate, the widest the band can ever open.
    uint256 _expectedCap = 2 * uint256(_maxBaseRate) * _elapsed;

    vm.prank(_GOVERNOR);
    _minter.setRateBand(0, _widestCeilingPips);

    // it should expose twice the maximum base rate as the effective rate
    assertEq(_minter.emissionRate(), 2 * uint256(_maxBaseRate));
    // it should accrue the emissions cap without overflowing
    assertEq(_minter.emissionsCap(), _expectedCap);
  }

  /*////////////////////////////////////////////////////////////
                          SET BASE RATE
  ////////////////////////////////////////////////////////////*/

  function test_SetBaseRateWhenTheCallerIsNotTheOperator(address _caller, uint232 _newRate) external {
    _caller = _boundNotEq(_caller, _OPERATOR);

    // it should revert with CallerNotOperator
    vm.expectRevert(IMinter.CallerNotOperator.selector);
    vm.prank(_caller);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenTheNewRateIsZero() external {
    // it should revert with InvalidBaseRate
    vm.expectRevert(IMinter.InvalidBaseRate.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(0);
  }

  function test_SetBaseRateWhenTheNewRateExceedsTheMaximumBaseRate(uint232 _newRate) external {
    _newRate = uint232(bound(_newRate, _minter.MAX_BASE_RATE() + 1, type(uint232).max));

    // it should revert with BaseRateTooHigh
    vm.expectRevert(IMinter.BaseRateTooHigh.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenTheCooldownIsActive() external {
    vm.warp(_minter.nextBaseRateUpdate() - 1);
    // it should revert with CooldownActive
    vm.expectRevert(IMinter.CooldownActive.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_INITIAL_BASE_RATE + 1);
  }

  function test_SetBaseRateWhenTheNewRateEqualsTheCurrentBaseRate() external {
    vm.warp(_minter.nextBaseRateUpdate());

    // it should revert with SameRate
    vm.expectRevert(IMinter.SameRate.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_INITIAL_BASE_RATE);
  }

  function test_SetBaseRateWhenTheRateChangeAboveBaseExceedsTheMaxChange(uint232 _newRate) external {
    vm.warp(_minter.nextBaseRateUpdate());
    uint256 _allowedDelta = Math.mulDiv(_INITIAL_BASE_RATE, _MAX_BASE_RATE_CHANGE_PIPS, MAX_PIPS, Math.Rounding.Ceil);
    _newRate = uint232(bound(_newRate, _INITIAL_BASE_RATE + _allowedDelta + 1, _minter.MAX_BASE_RATE()));

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenUsingAConcreteRateAboveTheMaximumChange() external {
    vm.warp(_minter.nextBaseRateUpdate());
    // 100 ether with a 5% max change allows rates up to 105 ether.
    uint232 _newRate = 106 ether;

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenUsingAConcreteActiveMaxBaseRateChange() external {
    _setMaxBaseRateChangePips(290);
    vm.warp(_minter.nextBaseRateUpdate());
    // 100 ether with an active 290 pips max change allows rates up to 100.029 ether.
    uint232 _newRate = _INITIAL_BASE_RATE + 29_000_000_000_000_001;

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenTheRateChangeBelowBaseExceedsTheMaxChange(uint232 _newRate) external {
    vm.warp(_minter.nextBaseRateUpdate());
    uint256 _allowedDelta = Math.mulDiv(_INITIAL_BASE_RATE, _MAX_BASE_RATE_CHANGE_PIPS, MAX_PIPS, Math.Rounding.Ceil);
    _newRate = uint232(bound(_newRate, 1, _INITIAL_BASE_RATE - _allowedDelta - 1));

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenUsingAConcreteRateBelowTheMaximumChange() external {
    vm.warp(_minter.nextBaseRateUpdate());
    // 100 ether with a 5% max change allows rates down to 95 ether.
    uint232 _newRate = 94 ether;

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenTheRateChangeEqualsTheRoundedUpMaxChangeWithARemainder() external {
    uint232 _baseRate = 101;
    uint232 _roundedUpRateChange = 6;
    _setBaseRate(_baseRate);
    vm.warp(_minter.nextBaseRateUpdate());

    // 101 * 5% = 5.05, rounded up to 6.
    uint232 _newRate = _baseRate + _roundedUpRateChange;
    uint48 _expectedNextUpdate = uint48(block.timestamp + _BASE_RATE_UPDATE_COOLDOWN);

    // it should emit BaseRateSet with _newRate
    _expectEmit(address(_minter));
    emit IMinter.BaseRateSet(_newRate);

    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);

    // it should update baseRate with _newRate
    assertEq(_minter.baseRate(), _newRate);

    // it should update nextBaseRateUpdate with block.timestamp + baseRateUpdateCooldown
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextUpdate);
  }

  function test_SetBaseRateWhenTheRateChangeExceedsTheRoundedUpMaxChangeWithARemainder() external {
    uint232 _baseRate = 101;
    uint232 _roundedUpRateChange = 6;
    _setBaseRate(_baseRate);
    vm.warp(_minter.nextBaseRateUpdate());

    // 101 * 5% = 5.05, rounded up to 6.
    uint232 _newRate = _baseRate + _roundedUpRateChange + 1;

    // it should revert with RateChangeExceedsMax
    vm.expectRevert(IMinter.RateChangeExceedsMax.selector);
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);
  }

  function test_SetBaseRateWhenTheRateChangeBoundIsAtTheLowestPossibleValues() external {
    // The lowest reachable base rate is one (setBaseRate forbids zero) and the lowest nonzero change cap is one pips.
    // The rounded up bound is ceil(1 * 1 / 1_000_000) = 1, so the operator can always move the rate by at least one.
    _setBaseRate(1);
    _setMaxBaseRateChangePips(1);
    vm.warp(_minter.nextBaseRateUpdate());

    // it should allow a minimum rate change of one
    _expectEmit(address(_minter));
    emit IMinter.BaseRateSet(2);

    vm.prank(_OPERATOR);
    _minter.setBaseRate(2);

    assertEq(_minter.baseRate(), 2);
  }

  function test_SetBaseRateWhenTheNextBaseRateUpdateOverflows() external {
    _defaultParams.maxBaseRateUpdateCooldown = type(uint48).max;
    _minter = new Minter(_defaultParams);

    _setBaseRateUpdateCooldown(type(uint48).max);

    vm.warp(_minter.nextBaseRateUpdate());
    uint256 _expectedOverflowingUpdate = block.timestamp + uint256(type(uint48).max);

    // it should revert with SafeCastOverflowedUintDowncast
    vm.expectRevert(
      abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, uint8(48), _expectedOverflowingUpdate)
    );
    vm.prank(_OPERATOR);
    _minter.setBaseRate(_INITIAL_BASE_RATE + 1);
  }

  function test_SetBaseRateWhenTimestampIsBeforeActivationAndRateChangeIsValid() external {
    vm.warp(1);
    _minter = new Minter(_defaultParams);
    vm.warp(_minter.nextBaseRateUpdate());
    assertLt(block.timestamp, _minter.ACTIVATION_TIMESTAMP());

    uint232 _newRate = _INITIAL_BASE_RATE + 1;
    uint48 _expectedNextUpdate = uint48(block.timestamp + _BASE_RATE_UPDATE_COOLDOWN);

    // it should emit BaseRateSet with _newRate
    _expectEmit(address(_minter));
    emit IMinter.BaseRateSet(_newRate);

    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);

    // it should update baseRate with _newRate
    assertEq(_minter.baseRate(), _newRate);
    // it should update nextBaseRateUpdate with block.timestamp + baseRateUpdateCooldown
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextUpdate);
  }

  function test_SetBaseRateWhenTheRateChangeAboveBaseIsValid(uint232 _newRate) external givenTheAccrualSegmentIsLive {
    _newRate = uint232(bound(_newRate, _INITIAL_BASE_RATE + 1, _INITIAL_BASE_RATE + _MAX_BASE_RATE_CHANGE));
    uint48 _expectedNextUpdate = uint48(block.timestamp + _BASE_RATE_UPDATE_COOLDOWN);

    // it should emit BaseRateSet with _newRate
    _expectEmit(address(_minter));
    emit IMinter.BaseRateSet(_newRate);

    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);

    // it should update baseRate with _newRate
    assertEq(_minter.baseRate(), _newRate);

    // it should update nextBaseRateUpdate with block.timestamp + baseRateUpdateCooldown
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextUpdate);

    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);

    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
  }

  function test_SetBaseRateWhenTheRateChangeBelowBaseIsValid(uint232 _newRate) external givenTheAccrualSegmentIsLive {
    _newRate = uint232(bound(_newRate, _INITIAL_BASE_RATE - _MAX_BASE_RATE_CHANGE, _INITIAL_BASE_RATE - 1));
    uint48 _expectedNextUpdate = uint48(block.timestamp + _BASE_RATE_UPDATE_COOLDOWN);

    // it should emit BaseRateSet with _newRate
    _expectEmit(address(_minter));
    emit IMinter.BaseRateSet(_newRate);

    vm.prank(_OPERATOR);
    _minter.setBaseRate(_newRate);

    // it should update baseRate with _newRate
    assertEq(_minter.baseRate(), _newRate);

    // it should update nextBaseRateUpdate with block.timestamp + baseRateUpdateCooldown
    assertEq(_minter.nextBaseRateUpdate(), _expectedNextUpdate);

    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);

    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
  }

  /*////////////////////////////////////////////////////////////
                    SET DYNAMIC RATE MODULE
  ////////////////////////////////////////////////////////////*/

  function test_SetDynamicRateModuleWhenTheCallerIsNotFed(address _caller, address _module) external {
    _caller = _boundNotEq(_caller, _FED);
    _setFED(_FED);

    // it should revert with CallerNotFED
    vm.expectRevert(IMinter.CallerNotFED.selector);
    vm.prank(_caller);
    _minter.setDynamicRateModule(_module);
  }

  function test_SetDynamicRateModuleWhenTheCallerIsFedAndTheNewModuleIsNonzero(address _module) external {
    _module = _excludingAddressZero(_module);
    _setFED(_FED);
    _setDynamicRateModule(_MODULE);
    _setDynamicRate(_CLAMPED_TARGET);

    // it should emit DynamicRateModuleSet with _module
    _expectEmit(address(_minter));
    emit IMinter.DynamicRateModuleSet(_module);

    vm.prank(_FED);
    _minter.setDynamicRateModule(_module);

    // it should update dynamicRateModule with _module
    assertEq(_minter.dynamicRateModule(), _module);
    // it should preserve the current dynamic rate target
    assertEq(_minter.dynamicRate(), _CLAMPED_TARGET);
  }

  function test_SetDynamicRateModuleWhenTheCallerIsFedAndTheNewModuleIsZeroAndADynamicTargetExists()
    external
    givenTheAccrualSegmentIsLive
  {
    _setFED(_FED);
    _setDynamicRateModule(_MODULE);

    // it should emit DynamicRateSet with zero
    _expectEmit(address(_minter));
    emit IMinter.DynamicRateSet(0);
    // it should emit DynamicRateModuleSet with zero
    _expectEmit(address(_minter));
    emit IMinter.DynamicRateModuleSet(address(0));

    vm.prank(_FED);
    _minter.setDynamicRateModule(address(0));

    // it should accrue the emissions cap at the outgoing effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);
    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
    // it should clear the dynamic rate target
    assertEq(_minter.dynamicRate(), 0);
    // it should return the base rate
    assertEq(_minter.emissionRate(), _INITIAL_BASE_RATE);
    // it should clear the dynamic rate module
    assertEq(_minter.dynamicRateModule(), address(0));
  }

  function test_SetDynamicRateModuleWhenTheCallerIsFedAndTheNewModuleIsZeroAndNoDynamicTargetExists() external {
    // Elapsed live time makes a spurious accrual observable: pricing this segment would move the cap off zero.
    vm.warp(_ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
    _setFED(_FED);
    _setDynamicRateModule(_MODULE);

    vm.recordLogs();
    vm.prank(_FED);
    _minter.setDynamicRateModule(address(0));

    // it should not accrue the emissions cap
    assertEq(_minter.emissionsCap(), 0);
    // it should leave lastCapUpdate at ACTIVATION TIMESTAMP
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP);
    // it should not emit DynamicRateSet
    // it should emit DynamicRateModuleSet with zero
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 1);
    assertEq(_logs[0].topics[0], IMinter.DynamicRateModuleSet.selector);
    assertEq(abi.decode(_logs[0].data, (address)), address(0));
    // it should clear the dynamic rate module
    assertEq(_minter.dynamicRateModule(), address(0));
  }

  /*////////////////////////////////////////////////////////////
                          SET DYNAMIC RATE
  ////////////////////////////////////////////////////////////*/

  function test_SetDynamicRateWhenTheCallerIsNotTheDynamicRateModule(address _caller) external {
    _setDynamicRateModule(_MODULE);
    _caller = _boundNotEq(_caller, _MODULE);

    // it should revert with CallerNotDynamicRateModule
    vm.expectRevert(IMinter.CallerNotDynamicRateModule.selector);
    vm.prank(_caller);
    _minter.setDynamicRate(_INITIAL_BASE_RATE);
  }

  /// @dev Sets the dynamic rate module and pranks as it, so the pushed target is the subject under test.
  modifier givenTheCallerIsTheDynamicRateModule() {
    _setDynamicRateModule(_MODULE);
    vm.startPrank(_MODULE);
    _;
    vm.stopPrank();
  }

  function test_SetDynamicRateWhenSetBeforeActivation(uint256 _rate) external givenTheCallerIsTheDynamicRateModule {
    vm.warp(_ACTIVATION_TIMESTAMP - 100);

    // it should emit DynamicRateSet with the rate
    _expectEmit(address(_minter));
    emit IMinter.DynamicRateSet(_rate);

    _minter.setDynamicRate(_rate);

    // it should store the rate
    assertEq(_minter.dynamicRate(), _rate);
    // it should leave the emissions cap at zero
    assertEq(_minter.emissionsCap(), 0);
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP);
  }

  function test_SetDynamicRateWhenSetAtExactlyActivation(uint256 _rate) external givenTheCallerIsTheDynamicRateModule {
    // The cap clock starts at activation, so the first live second has not elapsed yet and nothing can accrue. This
    // pins the constructor seeding the clock to activation, which is what makes the accrual guard a no-op here.
    vm.warp(_ACTIVATION_TIMESTAMP);

    _minter.setDynamicRate(_rate);

    // it should store the rate
    assertEq(_minter.dynamicRate(), _rate);
    // it should leave the emissions cap at zero
    assertEq(_minter.emissionsCap(), 0);
    // it should leave lastCapUpdate at ACTIVATION TIMESTAMP
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP);
  }

  function test_SetDynamicRateWhenSetAfterActivation(uint256 _rate)
    external
    givenTheCallerIsTheDynamicRateModule
    givenTheAccrualSegmentIsLive
  {
    // The incoming target is stored raw and cannot reach the accrual, which runs first at the outgoing rate. That
    // outgoing rate is the band floor, so the expected cap holds for any pushed value and would change if the
    // accrual read the incoming one.

    // it should emit DynamicRateSet with the rate
    _expectEmit(address(_minter));
    emit IMinter.DynamicRateSet(_rate);

    _minter.setDynamicRate(_rate);

    // it should store the rate
    assertEq(_minter.dynamicRate(), _rate);
    // it should accrue the emissions cap at the effective rate
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE);
    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED);
  }

  function test_SetDynamicRateWhenASecondPushFollowsAnEarlierSegment(uint256 _secondElapsed)
    external
    givenTheCallerIsTheDynamicRateModule
    givenTheAccrualSegmentIsLive
  {
    uint256 _firstSegmentEnd = _ACTIVATION_TIMESTAMP + _ACCRUAL_ELAPSED;
    // Cap the second segment at the remaining uint48 headroom, which lastCapUpdate has to hold.
    _secondElapsed = bound(_secondElapsed, 1, uint256(type(uint48).max) - _firstSegmentEnd);

    // The first push banks the floor rate over the seeded segment, then lifts the target above the ceiling so the
    // second segment accrues at the ceiling instead. Two distinct rates make a plain assignment observable.
    _minter.setDynamicRate(_INITIAL_BASE_RATE + 2 * _RATE_BAND_WIDTH);
    vm.warp(_firstSegmentEnd + _secondElapsed);

    _minter.setDynamicRate(_CLAMPED_TARGET);

    // it should accrue the sum of both segments at their own rates
    assertEq(_minter.emissionsCap(), _ACCRUAL_ALLOWANCE + _ACCRUAL_CEILING_RATE * _secondElapsed);

    // it should advance lastCapUpdate to the current timestamp
    assertEq(_minter.lastCapUpdate(), _firstSegmentEnd + _secondElapsed);
  }

  /*////////////////////////////////////////////////////////////
                          EMISSION RATE
  ////////////////////////////////////////////////////////////*/

  function test_EmissionRateWhenTheTimestampIsBeforeActivation() external {
    vm.warp(1);
    _minter = new Minter(_defaultParams);
    vm.warp(_FUTURE_ACTIVATION_TIMESTAMP - 1);

    // it should return zero
    assertEq(_minter.emissionRate(), 0);
  }

  function test_EmissionRateWhenTheTimestampEqualsActivation(uint232 _baseRate) external {
    // Emissions are live from the activation timestamp itself, not from the second after it.
    _baseRate = uint232(bound(_baseRate, 1, _minter.MAX_BASE_RATE()));
    _setBaseRate(_baseRate);
    vm.warp(_ACTIVATION_TIMESTAMP);

    // it should return the base rate
    assertEq(_minter.emissionRate(), _baseRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsZeroAndTheRateBandIsSet() external {
    // The zero sentinel means no target is in effect, so a floor band must not drag the rate down.
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);

    // it should return the base rate
    assertEq(_minter.emissionRate(), _INITIAL_BASE_RATE);
  }

  function test_EmissionRateWhenTheRateBandIsUnset() external {
    // With no band the clamp pins any stored target to the base rate.
    _setDynamicRate(_INITIAL_BASE_RATE + 5 ether);

    // it should return the base rate
    assertEq(_minter.emissionRate(), _INITIAL_BASE_RATE);
  }

  function test_EmissionRateWhenTheDynamicRateIsBelowTheFloor(uint256 _rate) external {
    uint256 _floorRate = _INITIAL_BASE_RATE - _RATE_BAND_WIDTH;
    // Zero is excluded: it is the unset sentinel, not a rate below the floor.
    _rate = bound(_rate, 1, _floorRate - 1);
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(_rate);

    // it should return the floor rate
    assertEq(_minter.emissionRate(), _floorRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsAboveTheCeiling(uint256 _rate) external {
    uint256 _ceilingRate = _INITIAL_BASE_RATE + _RATE_BAND_WIDTH;
    _rate = bound(_rate, _ceilingRate + 1, type(uint256).max);
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(_rate);

    // it should return the ceiling rate
    assertEq(_minter.emissionRate(), _ceilingRate);
  }

  function test_EmissionRateWhenWideningTheCeilingBandWithAnUnchangedTarget() external {
    // Clamping at read time is deliberate: the stored target is the module's intent and the band is the current
    // governance limit, so widening the band re-scopes an already pushed target without a new push. Hand computed
    // from a 100 ether base: a 10% ceiling admits 110 ether, a 20% ceiling admits 120 ether.
    _setBaseRate(100 ether);
    _setDynamicRate(200 ether);
    _setRateBand(0, 100_000);

    // it should return the narrow ceiling rate before the widening
    assertEq(_minter.emissionRate(), 110 ether);

    _setRateBand(0, 200_000);

    // it should return the wider ceiling rate after the widening
    assertEq(_minter.emissionRate(), 120 ether);
  }

  function test_EmissionRateWhenTheDynamicRateIsBelowTheBaseAndAboveTheFloor(uint256 _rate) external {
    _rate = bound(_rate, _INITIAL_BASE_RATE - _RATE_BAND_WIDTH + 1, _INITIAL_BASE_RATE - 1);
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(_rate);

    // it should return the dynamic rate
    assertEq(_minter.emissionRate(), _rate);
  }

  function test_EmissionRateWhenTheDynamicRateIsAboveTheBaseAndBelowTheCeiling(uint256 _rate) external {
    _rate = bound(_rate, _INITIAL_BASE_RATE + 1, _INITIAL_BASE_RATE + _RATE_BAND_WIDTH - 1);
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(_rate);

    // it should return the dynamic rate
    assertEq(_minter.emissionRate(), _rate);
  }

  function test_EmissionRateWhenUsingAConcreteRateBelowTheFloor() external {
    // 100 ether with a 10% floor gives a 90 ether floor, so 85 ether is below the floor.
    uint256 _floorRate = _INITIAL_BASE_RATE - _RATE_BAND_WIDTH;
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(85 ether);

    // it should return the floor rate
    assertEq(_minter.emissionRate(), _floorRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsBelowTheBaseAndTheFloorWidthRoundsDownToZero() external {
    uint232 _baseRate = 999_999;
    _setBaseRate(_baseRate);
    // 999_999 * 1 pip / 1_000_000 = 0.999999, rounded down to 0.
    // The floor is 999_999 - 0 = 999_999, so a target of 999_998 clamps back to the base rate.
    _setRateBand(1, 0);
    _setDynamicRate(_baseRate - 1);

    // it should return the base rate
    assertEq(_minter.emissionRate(), _baseRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsAboveTheBaseAndTheCeilingWidthRoundsDownToZero() external {
    uint232 _baseRate = 999_999;
    _setBaseRate(_baseRate);
    // 999_999 * 1 pip / 1_000_000 = 0.999999, rounded down to 0.
    // The ceiling is 999_999 + 0 = 999_999, so a target of 1_000_000 clamps back to the base rate.
    _setRateBand(0, 1);
    _setDynamicRate(_baseRate + 1);

    // it should return the base rate
    assertEq(_minter.emissionRate(), _baseRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsBelowTheFloorAndTheFloorWidthHasARemainder() external {
    uint232 _baseRate = 101;
    uint256 _roundedRateChange = 20;
    _setBaseRate(_baseRate);
    // 101 * 200_000 pips / 1_000_000 = 20.2, rounded down to 20.
    _setRateBand(200_000, 0);
    uint256 _floorRate = _baseRate - _roundedRateChange;
    _setDynamicRate(1);

    // it should return the floor rate
    assertEq(_minter.emissionRate(), _floorRate);
  }

  function test_EmissionRateWhenUsingAConcreteRateBelowTheBaseAndAboveTheFloor() external {
    // 100 ether with a 10% floor gives a 90 ether floor, so 95 ether is inside the band.
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(95 ether);

    // it should return the dynamic rate
    assertEq(_minter.emissionRate(), 95 ether);
  }

  function test_EmissionRateWhenUsingAConcreteRateAboveTheBaseAndBelowTheCeiling() external {
    // 100 ether with a 10% ceiling gives a 110 ether ceiling, so 105 ether is inside the band.
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(105 ether);

    // it should return the dynamic rate
    assertEq(_minter.emissionRate(), 105 ether);
  }

  function test_EmissionRateWhenUsingAConcreteRateAboveTheCeiling() external {
    // 100 ether with a 10% ceiling gives a 110 ether ceiling, so 115 ether is above the ceiling.
    uint256 _ceilingRate = _INITIAL_BASE_RATE + _RATE_BAND_WIDTH;
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);
    _setDynamicRate(115 ether);

    // it should return the ceiling rate
    assertEq(_minter.emissionRate(), _ceilingRate);
  }

  function test_EmissionRateWhenTheDynamicRateIsAboveTheCeilingAndTheCeilingWidthHasARemainder() external {
    uint232 _baseRate = 101;
    uint256 _roundedRateChange = 20;
    _setBaseRate(_baseRate);
    // 101 * 200_000 pips / 1_000_000 = 20.2, rounded down to 20.
    _setRateBand(0, 200_000);
    uint256 _ceilingRate = _baseRate + _roundedRateChange;
    _setDynamicRate(type(uint256).max);

    // it should return the ceiling rate
    assertEq(_minter.emissionRate(), _ceilingRate);
  }

  function test_StorageHelpersMatchLayout() external {
    _setBaseRate(777);
    _setNextBaseRateUpdate(888);
    _setMaxBaseRateChangePips(666);
    _setFED(_FED);
    _setBaseRateUpdateCooldown(111);
    _setTeamRate(222);
    _setRateBand(333, 444);
    _setDynamicRateModule(_MODULE);
    _setLastCapUpdate(555);
    _setDynamicRate(1234);
    _setEmissionsCap(4567);

    assertEq(_minter.baseRate(), 777);
    assertEq(_minter.operator(), _OPERATOR);
    assertEq(_minter.nextBaseRateUpdate(), 888);
    assertEq(_minter.maxBaseRateChangePips(), 666);
    assertEq(_minter.fed(), _FED);
    assertEq(_minter.baseRateUpdateCooldown(), 111);
    assertEq(_minter.teamRate(), 222);
    assertEq(_minter.bandFloorPips(), 333);
    assertEq(_minter.bandCeilingPips(), 444);
    assertEq(_minter.dynamicRateModule(), _MODULE);
    assertEq(_minter.lastCapUpdate(), 555);
    assertEq(_minter.dynamicRate(), 1234);
    assertEq(_minter.emissionsCap(), 4567);
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_constructor() external {
    new Minter(_defaultParams);
    vm.snapshotGasLastCall('Minter_constructor');
  }

  function testGas_emissionRate() external {
    _minter.emissionRate();
    vm.snapshotGasLastCall('Minter_emissionRate');
  }

  function testGas_setDynamicRate() external {
    _setDynamicRateModule(_MODULE);
    _setRateBand(_RATE_BAND_PIPS, _RATE_BAND_PIPS);

    vm.prank(_MODULE);
    _minter.setDynamicRate(85 ether);
    vm.snapshotGasLastCall('Minter_setDynamicRate');
  }

  /*////////////////////////////////////////////////////////////
                            HELPERS
  ////////////////////////////////////////////////////////////*/

  // Storage is written via vm.store with hardcoded slots and offsets instead of stdstore: stdstore's packed
  // slot discovery re-runs on every fuzz run (~3M gas, hundreds of times slower per write) because its find
  // cache reverts with the run snapshot. test_StorageHelpersMatchLayout pins the hardcoded layout instead.

  function _setBaseRate(uint232 _baseRate) internal {
    _setUintInSlot(_BASE_RATE_SLOT, 0, type(uint232).max, _baseRate);
  }

  function _setNextBaseRateUpdate(uint48 _nextBaseRateUpdate) internal {
    _setUint48InSlot(_OPERATOR_SLOT, _NEXT_BASE_RATE_UPDATE_OFFSET, _nextBaseRateUpdate);
  }

  function _setMaxBaseRateChangePips(uint24 _maxBaseRateChangePips) internal {
    _setUint24InSlot(_OPERATOR_SLOT, _MAX_BASE_RATE_CHANGE_PIPS_OFFSET, _maxBaseRateChangePips);
  }

  function _setFED(address _fed) internal {
    _setAddressInSlot(_RATE_CONFIG_SLOT, _FED_OFFSET, _fed);
  }

  function _setBaseRateUpdateCooldown(uint48 _baseRateUpdateCooldown) internal {
    _setUint48InSlot(_RATE_CONFIG_SLOT, _BASE_RATE_UPDATE_COOLDOWN_OFFSET, _baseRateUpdateCooldown);
  }

  function _setTeamRate(uint24 _teamRate) internal {
    _setUint24InSlot(_RATE_CONFIG_SLOT, _TEAM_RATE_OFFSET, _teamRate);
  }

  function _setRateBand(uint24 _floorPips, uint24 _ceilingPips) internal {
    _setUint24InSlot(_BASE_RATE_SLOT, _BAND_FLOOR_PIPS_OFFSET, _floorPips);
    _setUint24InSlot(_DYNAMIC_RATE_MODULE_SLOT, _BAND_CEILING_PIPS_OFFSET, _ceilingPips);
  }

  function _setDynamicRateModule(address _module) internal {
    _setAddressInSlot(_DYNAMIC_RATE_MODULE_SLOT, _DYNAMIC_RATE_MODULE_OFFSET, _module);
  }

  function _setLastCapUpdate(uint48 _lastCapUpdate) internal {
    _setUint48InSlot(_DYNAMIC_RATE_MODULE_SLOT, _LAST_CAP_UPDATE_OFFSET, _lastCapUpdate);
  }

  function _setDynamicRate(uint256 _dynamicRate) internal {
    vm.store(address(_minter), _DYNAMIC_RATE_SLOT, bytes32(_dynamicRate));
  }

  function _setEmissionsCap(uint256 _emissionsCap) internal {
    vm.store(address(_minter), _EMISSIONS_CAP_SLOT, bytes32(_emissionsCap));
  }

  function _setAddressInSlot(bytes32 _slot, uint256 _offset, address _value) internal {
    _setUintInSlot(_slot, _offset, type(uint160).max, uint160(_value));
  }

  function _setUint48InSlot(bytes32 _slot, uint256 _offset, uint48 _value) internal {
    _setUintInSlot(_slot, _offset, type(uint48).max, _value);
  }

  function _setUint24InSlot(bytes32 _slot, uint256 _offset, uint24 _value) internal {
    _setUintInSlot(_slot, _offset, type(uint24).max, _value);
  }

  function _setUintInSlot(bytes32 _slot, uint256 _offset, uint256 _maxValue, uint256 _value) internal {
    uint256 _shift = _offset * 8;
    uint256 _mask = _maxValue << _shift;
    bytes32 _current = vm.load(address(_minter), _slot);
    bytes32 _updated = bytes32((uint256(_current) & ~_mask) | (_value << _shift));
    vm.store(address(_minter), _slot, _updated);
  }
}
