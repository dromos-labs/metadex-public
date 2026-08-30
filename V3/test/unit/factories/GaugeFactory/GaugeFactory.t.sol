// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {Errors} from '@openzeppelin/contracts/utils/Errors.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {ParamsLib} from 'V3/libraries/ParamsLib.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IVotingRewardsFactory} from 'V3/interfaces/rewards/IVotingRewardsFactory.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {GaugeFactory} from 'V3/factories/GaugeFactory.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitGaugeFactory is TestHelpers {
  uint128 internal constant _DEFAULT_CAP = 1000 ether;
  uint128 internal constant _OPERATOR_MIN_CAP = 10 ether;
  uint128 internal constant _OPERATOR_MAX_CAP = 100 ether;
  uint256 internal constant _MAX_MIN_STAKE_BLOCKS = 100;
  string internal constant _V2_GAUGE_TYPE = 'v2';

  address internal _leafVoter = _mockContract('_leafVoter');
  address internal _factoryRegistry = _mockContract('_factoryRegistry');
  address internal _gaugeManager = makeAddr('_gaugeManager');
  address internal _votingRewardsFactory = makeAddr('_votingRewardsFactory');
  address internal _capAdmin = makeAddr('_capAdmin');
  address internal _referralAdmin = makeAddr('_referralAdmin');
  address internal _penaltyAdmin = makeAddr('_penaltyAdmin');
  address internal _capOperator = makeAddr('_capOperator');
  address internal _emergencyCouncil = makeAddr('_emergencyCouncil');
  address internal _pool = makeAddr('_pool');
  address internal _votingRewardsManager = makeAddr('_votingRewardsManager');
  address internal _token0 = makeAddr('_token0');
  address internal _token1 = makeAddr('_token1');
  address internal _gauge = makeAddr('_gauge');

  GaugeFactoryHarness internal _gaugeFactory;

  function setUp() public virtual {
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(_gaugeManager));
    _gaugeFactory = _deployGaugeFactory();
  }

  function test_ConstructorWhenLeafVoterIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.leafVoter = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenLeafVoterReportsAZeroGaugeManager() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    vm.mockCall(_leafVoter, abi.encodeCall(ILeafVoter.GAUGE_MANAGER, ()), abi.encode(address(0)));

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenVotingRewardsFactoryIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.votingRewardsFactory = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenCapAdminIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.capAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenReferralAdminIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.referralAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenPenaltyAdminIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.penaltyAdmin = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenCapOperatorIsTheZeroAddress() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.capOperator = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IGaugeFactory.ZeroAddress.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenDefaultCapIsZero() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.defaultCap = 0;

    // it should revert with ZeroDefaultCap
    vm.expectRevert(IGaugeFactory.ZeroDefaultCap.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenOperatorMinCapIsZero() external {
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.operatorMinCap = 0;

    // it should revert with InvalidCapRange
    vm.expectRevert(IGaugeFactory.InvalidCapRange.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenOperatorMinCapExceedsOperatorMaxCap(
    uint128 _operatorMinCap,
    uint128 _operatorMaxCap
  ) external {
    _operatorMaxCap = uint128(bound(_operatorMaxCap, 0, type(uint128).max - 1));
    _operatorMinCap = uint128(bound(_operatorMinCap, _operatorMaxCap + 1, type(uint128).max));

    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.operatorMinCap = _operatorMinCap;
    _params.operatorMaxCap = _operatorMaxCap;

    // it should revert with InvalidCapRange
    vm.expectRevert(IGaugeFactory.InvalidCapRange.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenMaxMinStakeBlocksIsLessThanTheDefault(uint256 _invalidMaxMinStakeBlocks) external {
    _invalidMaxMinStakeBlocks = bound(_invalidMaxMinStakeBlocks, 0, _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS() - 1);

    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.maxMinStakeBlocks = _invalidMaxMinStakeBlocks;

    // it should revert with InvalidMinStakeBlocks
    vm.expectRevert(IGaugeFactory.InvalidMinStakeBlocks.selector);
    new GaugeFactoryHarness(_params);
  }

  function test_ConstructorWhenConstructorArgumentsAreValid(
    uint128 _defaultCap,
    uint128 _operatorMinCap,
    uint128 _operatorMaxCap,
    uint256 _maxMinStakeBlocks,
    bool _isStable
  ) external {
    _defaultCap = uint128(bound(_defaultCap, 1, type(uint128).max));
    _operatorMinCap = uint128(bound(_operatorMinCap, 1, type(uint128).max));
    _operatorMaxCap = uint128(bound(_operatorMaxCap, _operatorMinCap, type(uint128).max));
    _maxMinStakeBlocks = bound(_maxMinStakeBlocks, _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS(), type(uint256).max);

    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.isStable = _isStable;
    _params.defaultCap = _defaultCap;
    _params.operatorMinCap = _operatorMinCap;
    _params.operatorMaxCap = _operatorMaxCap;
    _params.maxMinStakeBlocks = _maxMinStakeBlocks;

    GaugeFactoryHarness gaugeFactory = new GaugeFactoryHarness(_params);

    // it should set immutable views
    assertEq(gaugeFactory.LEAF_VOTER(), _leafVoter);
    assertEq(gaugeFactory.GAUGE_MANAGER(), _gaugeManager);
    assertEq(gaugeFactory.VOTING_REWARDS_FACTORY(), _votingRewardsFactory);
    assertGt(gaugeFactory.IMPLEMENTATION().code.length, 0);
    assertEq(gaugeFactory.IS_STABLE(), _isStable);
    assertEq(gaugeFactory.MAX_MIN_STAKE_BLOCKS(), _maxMinStakeBlocks);

    // it should set default cap views
    assertEq(gaugeFactory.defaultCap(), _defaultCap);
    assertEq(gaugeFactory.operatorMinCap(), _operatorMinCap);
    assertEq(gaugeFactory.operatorMaxCap(), _operatorMaxCap);

    // it should set referral and penalty defaults
    assertEq(gaugeFactory.DEFAULT_MAX_SHARE_CAP(), 50_000);
    assertEq(gaugeFactory.maxShareCap(), gaugeFactory.DEFAULT_MAX_SHARE_CAP());
    IGaugeFactory.PenaltyConfig memory config = gaugeFactory.penaltyConfig();
    assertEq(config.minStakeBlocks, gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS());
    assertEq(config.penaltyRate, gaugeFactory.DEFAULT_PENALTY_RATE());
    assertEq(gaugeFactory.minStakeBlocks(_gauge), gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS());

    // it should grant initial roles
    assertTrue(gaugeFactory.hasRole(gaugeFactory.CAP_ADMIN_ROLE(), _capAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.REFERRAL_ADMIN_ROLE(), _referralAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.PENALTY_ADMIN_ROLE(), _penaltyAdmin));
    assertTrue(gaugeFactory.hasRole(gaugeFactory.CAP_OPERATOR_ROLE(), _capOperator));

    // it should set role admin relationships
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.CAP_ADMIN_ROLE()), gaugeFactory.CAP_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.REFERRAL_ADMIN_ROLE()), gaugeFactory.REFERRAL_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.PENALTY_ADMIN_ROLE()), gaugeFactory.PENALTY_ADMIN_ROLE());
    assertEq(gaugeFactory.getRoleAdmin(gaugeFactory.CAP_OPERATOR_ROLE()), gaugeFactory.CAP_ADMIN_ROLE());

    // it should expose the gauge type
    assertEq(gaugeFactory.GAUGE_TYPE(), _V2_GAUGE_TYPE);

    // it should disable the implementation
    address implementation = gaugeFactory.IMPLEMENTATION();
    vm.expectRevert(IV2Gauge.AlreadyInitialized.selector);
    IV2Gauge(implementation).initialize(_pool, _votingRewardsManager, true);
  }

  function test_CreateGaugeWhenTheCallerIsNotTheGaugeManager(address _caller) external {
    _caller = _boundNotEq(_caller, _gaugeManager);
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.createGauge(_pool, '');
  }

  modifier whenTheCallerIsTheGaugeManager() {
    vm.startPrank(_gaugeManager);
    _;
    vm.stopPrank();
  }

  function test_CreateGaugeWhenParamsAreEmpty() external whenTheCallerIsTheGaugeManager {
    address expectedGauge = _mockCreateGaugeInputs();

    // it should emit GaugeCreated
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.GaugeCreated({_gauge: expectedGauge, _pool: _pool, _isPool: true});
    (address createdGauge, address createdRewards) = _gaugeFactory.createGauge(_pool, '');

    // it should deploy the voting rewards manager against the predicted gauge
    assertEq(createdRewards, _votingRewardsManager);

    // it should deploy a gauge
    assertEq(createdGauge, expectedGauge);
    _assertGaugeFields(createdGauge, address(_gaugeFactory), true);

    // it should mark the gauge
    assertTrue(_gaugeFactory.isGauge(createdGauge));

    // it should initialize the emission cap to the current default cap
    assertEq(_gaugeFactory.emissionCap(createdGauge), _DEFAULT_CAP);

    // it should leave referral config empty
    _assertReferralConfig(createdGauge, address(0), 0);
  }

  function test_CreateGaugeWhenParamsAreUnknown(uint8 _unknownParamsType) external whenTheCallerIsTheGaugeManager {
    vm.assume(_unknownParamsType != 0x01);
    _mockCreateGaugeInputs();
    bytes memory params = abi.encodePacked(_unknownParamsType, abi.encode(makeAddr('referral'), uint256(1)));

    (address createdGauge,) = _gaugeFactory.createGauge(_pool, params);

    // it should deploy a gauge
    _assertGaugeFields(createdGauge, address(_gaugeFactory), true);

    // it should leave referral config empty
    _assertReferralConfig(createdGauge, address(0), 0);
  }

  function test_CreateGaugeWhenParamsAreReferral(
    address _referral,
    uint256 _share
  ) external whenTheCallerIsTheGaugeManager {
    _assumeFuzzable(_referral);
    _share = bound(_share, 0, _gaugeFactory.maxShareCap());
    address expectedGauge = _mockCreateGaugeInputs();
    bytes memory params = abi.encodePacked(uint8(0x01), abi.encode(_referral, _share));

    // it should emit ReferralConfigSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.ReferralConfigSet({_gauge: expectedGauge, _referral: _referral, _share: _share});
    (address createdGauge,) = _gaugeFactory.createGauge(_pool, params);

    // it should deploy a gauge
    _assertGaugeFields(createdGauge, address(_gaugeFactory), true);

    // it should set referral config
    _assertReferralConfig(createdGauge, _referral, _share);
  }

  function test_CreateGaugeWhenParamsAreATruncatedReferralPayload(uint256 _paramsLength)
    external
    whenTheCallerIsTheGaugeManager
  {
    _paramsLength = bound(_paramsLength, 1, 64);
    _mockCreateGaugeInputsWithoutExpectations();
    bytes memory params = new bytes(_paramsLength);
    params[0] = bytes1(uint8(0x01));

    // it should revert with MalformedReferral
    vm.expectRevert(ParamsLib.MalformedReferral.selector);
    _gaugeFactory.createGauge(_pool, params);
  }

  function test_CreateGaugeWhenParamsAreAnOversizedReferralPayload(uint256 _paramsLength)
    external
    whenTheCallerIsTheGaugeManager
  {
    _paramsLength = bound(_paramsLength, 66, 256);
    _mockCreateGaugeInputsWithoutExpectations();
    bytes memory params = new bytes(_paramsLength);
    params[0] = bytes1(uint8(0x01));

    // it should revert with MalformedReferral
    vm.expectRevert(ParamsLib.MalformedReferral.selector);
    _gaugeFactory.createGauge(_pool, params);
  }

  function test_CreateGaugeWhenAGaugeWasAlreadyDeployedOverTheTarget() external whenTheCallerIsTheGaugeManager {
    _mockCreateGaugeInputs();
    _gaugeFactory.createGauge(_pool, '');

    // it should revert on the clone collision
    vm.expectRevert(Errors.FailedDeployment.selector);
    _gaugeFactory.createGauge(_pool, '');
  }

  function test_ComputeGaugeAddressWhenCalledWithAPool(bool _isStable) external {
    GaugeFactoryHarness gaugeFactory = _deployGaugeFactoryHarness(_isStable);
    address expectedGauge = _mockCreateGaugeInputs(address(gaugeFactory), gaugeFactory.IMPLEMENTATION(), _isStable);

    // it should return the deterministic clone address
    assertEq(gaugeFactory.computeGaugeAddress(_pool), expectedGauge);
  }

  function test_SetDefaultCapWhenTheCallerDoesNotHaveTheCapAdminRole(address _caller, uint128 _cap) external {
    _caller = _boundNotEq(_caller, _capAdmin);
    _assumeFuzzable(_caller);
    bytes32 capAdminRole = _gaugeFactory.CAP_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, capAdminRole));
    _gaugeFactory.setDefaultCap(_cap);
  }

  modifier whenTheCallerHasTheCapAdminRole() {
    vm.startPrank(_capAdmin);
    _;
    vm.stopPrank();
  }

  function test_SetDefaultCapWhenTheCapIsZero() external whenTheCallerHasTheCapAdminRole {
    // it should revert with ZeroDefaultCap
    vm.expectRevert(IGaugeFactory.ZeroDefaultCap.selector);
    _gaugeFactory.setDefaultCap(0);
  }

  function test_SetDefaultCapWhenTheCapIsNonzero(uint128 _newDefaultCap) external whenTheCallerHasTheCapAdminRole {
    _newDefaultCap = uint128(bound(_newDefaultCap, 1, type(uint128).max));
    vm.assume(_newDefaultCap != _DEFAULT_CAP);
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _gaugeFactory.exposedSetStoredEmissionCap(_gauge, _DEFAULT_CAP);

    // it should emit DefaultCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.DefaultCapSet(_newDefaultCap);
    _gaugeFactory.setDefaultCap(_newDefaultCap);

    // it should update defaultCap
    assertEq(_gaugeFactory.defaultCap(), _newDefaultCap);

    // it should preserve the existing gauge cap
    assertEq(_gaugeFactory.emissionCap(_gauge), _DEFAULT_CAP);
  }

  function test_SetOperatorCapRangeWhenTheCallerDoesNotHaveTheCapAdminRole(
    address _caller,
    uint128 _minCap,
    uint128 _maxCap
  ) external {
    _caller = _boundNotEq(_caller, _capAdmin);
    _assumeFuzzable(_caller);
    bytes32 capAdminRole = _gaugeFactory.CAP_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, capAdminRole));
    _gaugeFactory.setOperatorCapRange(_minCap, _maxCap);
  }

  function test_SetOperatorCapRangeWhenMinCapIsZero(uint128 _maxCap) external whenTheCallerHasTheCapAdminRole {
    // it should revert with InvalidCapRange
    vm.expectRevert(IGaugeFactory.InvalidCapRange.selector);
    _gaugeFactory.setOperatorCapRange(0, _maxCap);
  }

  function test_SetOperatorCapRangeWhenMinCapExceedsMaxCap(
    uint128 _minCap,
    uint128 _maxCap
  ) external whenTheCallerHasTheCapAdminRole {
    _maxCap = uint128(bound(_maxCap, 0, type(uint128).max - 1));
    _minCap = uint128(bound(_minCap, _maxCap + 1, type(uint128).max));

    // it should revert with InvalidCapRange
    vm.expectRevert(IGaugeFactory.InvalidCapRange.selector);
    _gaugeFactory.setOperatorCapRange(_minCap, _maxCap);
  }

  function test_SetOperatorCapRangeWhenTheRangeIsValid(
    uint128 _newMinCap,
    uint128 _newMaxCap
  ) external whenTheCallerHasTheCapAdminRole {
    _newMinCap = uint128(bound(_newMinCap, 1, type(uint128).max));
    _newMaxCap = uint128(bound(_newMaxCap, _newMinCap, type(uint128).max));

    // it should emit OperatorCapRangeSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.OperatorCapRangeSet({_minCap: _newMinCap, _maxCap: _newMaxCap});
    _gaugeFactory.setOperatorCapRange(_newMinCap, _newMaxCap);

    // it should update operator cap range
    assertEq(_gaugeFactory.operatorMinCap(), _newMinCap);
    assertEq(_gaugeFactory.operatorMaxCap(), _newMaxCap);
  }

  function test_SetEmissionCapWhenTheGaugeIsInvalid(address _caller, address _invalidGauge, uint128 _cap) external {
    _assumeFuzzable(_caller);
    vm.prank(_caller);
    // it should revert with InvalidGauge
    vm.expectRevert(IGaugeFactory.InvalidGauge.selector);
    _gaugeFactory.setEmissionCap(_invalidGauge, _cap);
  }

  modifier whenTheGaugeIsValid() {
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _gaugeFactory.exposedSetStoredEmissionCap(_gauge, _DEFAULT_CAP);
    vm.etch(_gauge, hex'69');
    _mockEmergencyCouncil();
    _;
  }

  modifier whenTheCapIsZeroForCapAdmin() {
    _;
  }

  function test_SetEmissionCapWhenFeeFlushingReverts()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
    whenTheCapIsZeroForCapAdmin
  {
    _expectSettleGauge();
    _expectFlushFeesRevert();

    // it should revert with FeeCollectionFailed
    vm.expectRevert(abi.encodeWithSelector(IVotingRewardsManager.FeeCollectionFailed.selector, _gauge));
    _gaugeFactory.setEmissionCap(_gauge, 0);
  }

  function test_SetEmissionCapWhenFeeFlushingSucceeds()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
    whenTheCapIsZeroForCapAdmin
  {
    _expectSettleGauge();
    _expectFlushFees();

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.EmissionCapSet({_gauge: _gauge, _cap: 0, _caller: _capAdmin});
    _gaugeFactory.setEmissionCap(_gauge, 0);

    // it should settle the gauge
    // it should flush fees

    // it should write the zero cap
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);
  }

  function test_SetEmissionCapWhenTheCapIsTheMaximumValueForCapAdmin()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
  {
    uint128 _maximumCap = type(uint128).max;
    _expectSettleGauge();

    _gaugeFactory.setEmissionCap(_gauge, _maximumCap);

    // it should settle the gauge

    // it should write the maximum cap
    assertEq(_gaugeFactory.emissionCap(_gauge), _maximumCap);
  }

  function test_SetEmissionCapWhenTheCapIsNonzeroForCapAdmin(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole
  {
    _newCap = uint128(bound(_newCap, 1, type(uint128).max - 1));
    _expectSettleGauge();

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.EmissionCapSet({_gauge: _gauge, _cap: _newCap, _caller: _capAdmin});
    _gaugeFactory.setEmissionCap(_gauge, _newCap);

    // it should settle the gauge

    // it should write the cap
    assertEq(_gaugeFactory.emissionCap(_gauge), _newCap);
  }

  modifier whenTheCallerHasTheCapOperatorRole() {
    vm.startPrank(_capOperator);
    _;
    vm.stopPrank();
  }

  function test_SetEmissionCapWhenTheCurrentCapIsZero(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
  {
    _gaugeFactory.exposedSetStoredEmissionCap(_gauge, 0);

    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.setEmissionCap(_gauge, _newCap);
  }

  modifier whenTheCurrentCapIsNonzero() {
    _gaugeFactory.exposedSetStoredEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    _;
  }

  function test_SetEmissionCapWhenTheNewCapIsBelowTheOperatorRange(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _newCap = uint128(bound(_newCap, 1, _OPERATOR_MIN_CAP - 1));

    // it should revert with CapOutOfOperatorRange
    vm.expectRevert(IGaugeFactory.CapOutOfOperatorRange.selector);
    _gaugeFactory.setEmissionCap(_gauge, _newCap);
  }

  function test_SetEmissionCapWhenTheNewCapIsAboveTheOperatorRange(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _newCap = uint128(bound(_newCap, _OPERATOR_MAX_CAP + 1, type(uint128).max));

    // it should revert with CapOutOfOperatorRange
    vm.expectRevert(IGaugeFactory.CapOutOfOperatorRange.selector);
    _gaugeFactory.setEmissionCap(_gauge, _newCap);
  }

  function test_SetEmissionCapWhenTheNewCapIsInTheOperatorRange(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapOperatorRole
    whenTheCurrentCapIsNonzero
  {
    _newCap = uint128(bound(_newCap, _OPERATOR_MIN_CAP, _OPERATOR_MAX_CAP));
    _expectSettleGauge();

    _gaugeFactory.setEmissionCap(_gauge, _newCap);

    // it should settle the gauge

    // it should write the cap
    assertEq(_gaugeFactory.emissionCap(_gauge), _newCap);
  }

  modifier whenTheCallerIsTheEmergencyCouncil() {
    vm.startPrank(_emergencyCouncil);
    _;
    vm.stopPrank();
  }

  function test_SetEmissionCapWhenTheCapIsNonzeroForEmergencyCouncil(uint128 _newCap)
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    _newCap = uint128(bound(_newCap, 1, type(uint128).max));

    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.setEmissionCap(_gauge, _newCap);
  }

  modifier whenTheCapIsZeroForEmergencyCouncil() {
    _;
  }

  function test_SetEmissionCapWhenFeeFlushingReverts_()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
    whenTheCapIsZeroForEmergencyCouncil
  {
    _expectSettleGauge();
    _expectFlushFeesRevert();

    // it should revert with FeeCollectionFailed
    vm.expectRevert(abi.encodeWithSelector(IVotingRewardsManager.FeeCollectionFailed.selector, _gauge));
    _gaugeFactory.setEmissionCap(_gauge, 0);
  }

  function test_SetEmissionCapWhenFeeFlushingSucceeds_()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
    whenTheCapIsZeroForEmergencyCouncil
  {
    _expectSettleGauge();
    _expectFlushFees();

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.EmissionCapSet({_gauge: _gauge, _cap: 0, _caller: _emergencyCouncil});
    _gaugeFactory.setEmissionCap(_gauge, 0);

    // it should settle the gauge
    // it should flush fees

    // it should write the zero cap
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);
  }

  function test_SetEmissionCapWhenTheCallerIsNotAuthorized(
    address _caller,
    uint128 _newCap
  ) external whenTheGaugeIsValid {
    _caller = _boundUnauthorized(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.setEmissionCap(_gauge, _newCap);
  }

  /// @notice Verifies a caller with all cap roles can set every supported cap category.
  function test_SetEmissionCapRolesWhenTheCallerHasAllRoles() external whenTheGaugeIsValid {
    _grantFactoryRole(_gaugeFactory.CAP_ADMIN_ROLE(), _emergencyCouncil);
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _emergencyCouncil);
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_emergencyCouncil);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MIN_CAP);

    _expectSettleGauge();

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);
    assertEq(_gaugeFactory.emissionCap(_gauge), _otherCap);

    vm.stopPrank();
  }

  modifier whenTheCallerHasTheEmergencyCouncilRole() {
    _;
  }

  /// @notice Verifies emergency council and cap admin permissions are additive.
  function test_SetEmissionCapRolesWhenTheCallerHasTheCapAdminRole()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheEmergencyCouncilRole
  {
    _grantFactoryRole(_gaugeFactory.CAP_ADMIN_ROLE(), _emergencyCouncil);
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_emergencyCouncil);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MIN_CAP);

    _expectSettleGauge();

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);
    assertEq(_gaugeFactory.emissionCap(_gauge), _otherCap);

    vm.stopPrank();
  }

  /// @notice Verifies emergency council and cap operator permissions are additive.
  function test_SetEmissionCapRolesWhenTheCallerHasTheCapOperatorRole()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheEmergencyCouncilRole
  {
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _emergencyCouncil);
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_emergencyCouncil);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    /// @dev Restores a nonzero cap because cap operators cannot update a zero-capped gauge.
    _gaugeFactory.exposedSetStoredEmissionCap(_gauge, _DEFAULT_CAP);
    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MAX_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MAX_CAP);

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(IGaugeFactory.CapOutOfOperatorRange.selector);
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);

    vm.stopPrank();
  }

  /// @notice Verifies emergency council permissions remain limited to zero caps.
  function test_SetEmissionCapRolesWhenTheCallerHasNoOtherRole()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheEmergencyCouncilRole
  {
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_emergencyCouncil);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    // it should not allow setting the emission cap within the operator range
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);

    vm.stopPrank();
  }

  modifier whenTheCallerHasTheCapAdminRole_() {
    _;
  }

  /// @notice Verifies cap admin and cap operator permissions are additive.
  function test_SetEmissionCapRolesWhenTheCallerHasTheCapOperatorRole_()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole_
  {
    _grantFactoryRole(_gaugeFactory.CAP_OPERATOR_ROLE(), _capAdmin);
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_capAdmin);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MIN_CAP);

    _expectSettleGauge();

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);
    assertEq(_gaugeFactory.emissionCap(_gauge), _otherCap);

    vm.stopPrank();
  }

  /// @notice Verifies cap admin permissions remain unrestricted without another role.
  function test_SetEmissionCapRolesWhenTheCallerHasNoOtherRole_()
    external
    whenTheGaugeIsValid
    whenTheCallerHasTheCapAdminRole_
  {
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_capAdmin);

    _expectSettleGauge();
    _expectFlushFees();

    // it should allow setting the emission cap to zero
    _gaugeFactory.setEmissionCap(_gauge, 0);
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);

    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MIN_CAP);

    _expectSettleGauge();

    // it should allow setting the emission cap to another nonzero value
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);
    assertEq(_gaugeFactory.emissionCap(_gauge), _otherCap);

    vm.stopPrank();
  }

  /// @notice Verifies cap operator permissions remain limited to the configured range.
  function test_SetEmissionCapRolesWhenTheCallerHasOnlyTheCapOperatorRole() external whenTheGaugeIsValid {
    uint128 _otherCap = _OPERATOR_MAX_CAP + 1;

    vm.startPrank(_capOperator);

    // it should not allow setting the emission cap to zero
    vm.expectRevert(IGaugeFactory.CapOutOfOperatorRange.selector);
    _gaugeFactory.setEmissionCap(_gauge, 0);

    _expectSettleGauge();

    // it should allow setting the emission cap within the operator range
    _gaugeFactory.setEmissionCap(_gauge, _OPERATOR_MIN_CAP);
    assertEq(_gaugeFactory.emissionCap(_gauge), _OPERATOR_MIN_CAP);

    // it should not allow setting the emission cap to another nonzero value
    vm.expectRevert(IGaugeFactory.CapOutOfOperatorRange.selector);
    _gaugeFactory.setEmissionCap(_gauge, _otherCap);

    vm.stopPrank();
  }

  function test_ClearEmissionCapWhenTheGaugeIsInvalid(address _caller, address _invalidGauge) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with InvalidGauge
    vm.expectRevert(IGaugeFactory.InvalidGauge.selector);
    _gaugeFactory.clearEmissionCap(_invalidGauge);
  }

  function test_ClearEmissionCapWhenTheCallerIsNotTheEmergencyCouncil(address _caller) external whenTheGaugeIsValid {
    _caller = _boundNotEq(_caller, _emergencyCouncil);
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(IGaugeFactory.NotAuthorized.selector);
    _gaugeFactory.clearEmissionCap(_gauge);
  }

  function test_ClearEmissionCapWhenFeeFlushingReverts()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    // it should settle the gauge
    _expectSettleGauge();

    // it should attempt to flush fees
    _expectFlushFeesRevert();

    // it should emit FeeFlushFailed
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.FeeFlushFailed({_gauge: _gauge});

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.EmissionCapSet({_gauge: _gauge, _cap: 0, _caller: _emergencyCouncil});
    _gaugeFactory.clearEmissionCap(_gauge);

    // it should write the zero cap
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);
  }

  function test_ClearEmissionCapWhenFeeFlushingSucceeds()
    external
    whenTheGaugeIsValid
    whenTheCallerIsTheEmergencyCouncil
  {
    // it should settle the gauge
    _expectSettleGauge();

    // it should flush fees
    _expectFlushFees();

    // it should emit EmissionCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.EmissionCapSet({_gauge: _gauge, _cap: 0, _caller: _emergencyCouncil});
    _gaugeFactory.clearEmissionCap(_gauge);

    // it should write the zero cap
    assertEq(_gaugeFactory.emissionCap(_gauge), 0);
  }

  function test_SetMaxShareCapWhenTheCallerDoesNotHaveTheReferralAdminRole(address _caller, uint256 _cap) external {
    _caller = _boundNotEq(_caller, _referralAdmin);
    _assumeFuzzable(_caller);
    bytes32 referralAdminRole = _gaugeFactory.REFERRAL_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, referralAdminRole));
    _gaugeFactory.setMaxShareCap(_cap);
  }

  modifier whenTheCallerHasTheReferralAdminRole() {
    vm.startPrank(_referralAdmin);
    _;
    vm.stopPrank();
  }

  function test_SetMaxShareCapWhenTheCapExceedsMaxPips(uint256 _cap) external whenTheCallerHasTheReferralAdminRole {
    _cap = bound(_cap, MAX_PIPS + 1, type(uint256).max);

    // it should revert with InvalidMaxShareCap
    vm.expectRevert(IGaugeFactory.InvalidMaxShareCap.selector);
    _gaugeFactory.setMaxShareCap(_cap);
  }

  function test_SetMaxShareCapWhenTheCapIsValid(uint256 _newMaxShareCap) external whenTheCallerHasTheReferralAdminRole {
    _newMaxShareCap = bound(_newMaxShareCap, 0, MAX_PIPS);

    // it should emit MaxShareCapSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.MaxShareCapSet(_newMaxShareCap);
    _gaugeFactory.setMaxShareCap(_newMaxShareCap);

    // it should update maxShareCap
    assertEq(_gaugeFactory.maxShareCap(), _newMaxShareCap);
  }

  function test_SetReferralConfigWhenTheCallerDoesNotHaveTheReferralAdminRole(
    address _caller,
    address _gaugeAddress,
    address _referral,
    uint256 _share
  ) external {
    _caller = _boundNotEq(_caller, _referralAdmin);
    _assumeFuzzable(_caller);
    bytes32 referralAdminRole = _gaugeFactory.REFERRAL_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, referralAdminRole));
    _gaugeFactory.setReferralConfig(_gaugeAddress, _referral, _share);
  }

  function test_SetReferralConfigWhenTheGaugeIsInvalid(
    address _invalidGauge,
    address _referral,
    uint256 _share
  ) external whenTheCallerHasTheReferralAdminRole {
    // it should revert with InvalidGauge
    vm.expectRevert(IGaugeFactory.InvalidGauge.selector);
    _gaugeFactory.setReferralConfig(_invalidGauge, _referral, _share);
  }

  function test_SetReferralConfigWhenTheShareExceedsMaxShareCap(
    address _referral,
    uint256 _share
  ) external whenTheCallerHasTheReferralAdminRole {
    _assumeFuzzable(_referral);
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _share = bound(_share, _gaugeFactory.maxShareCap() + 1, type(uint256).max);

    // it should revert with ShareExceedsMax
    vm.expectRevert(IGaugeFactory.ShareExceedsMax.selector);
    _gaugeFactory.setReferralConfig(_gauge, _referral, _share);
  }

  function test_SetReferralConfigWhenShareIsNonzeroAndReferralIsTheZeroAddress(uint256 _share)
    external
    whenTheCallerHasTheReferralAdminRole
  {
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _share = bound(_share, 1, _gaugeFactory.maxShareCap());

    // it should revert with InvalidReferral
    vm.expectRevert(IGaugeFactory.InvalidReferral.selector);
    _gaugeFactory.setReferralConfig(_gauge, address(0), _share);
  }

  function test_SetReferralConfigWhenTheConfigIsValid(
    address _referral,
    uint256 _share
  ) external whenTheCallerHasTheReferralAdminRole {
    _assumeFuzzable(_referral);
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _share = bound(_share, 0, _gaugeFactory.maxShareCap());

    // it should emit ReferralConfigSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.ReferralConfigSet({_gauge: _gauge, _referral: _referral, _share: _share});
    _gaugeFactory.setReferralConfig(_gauge, _referral, _share);

    // it should update referral config
    _assertReferralConfig(_gauge, _referral, _share);
  }

  function test_SetReferralConfigWhenClearingTheConfig(
    address _referral,
    uint256 _share
  ) external whenTheCallerHasTheReferralAdminRole {
    _assumeFuzzable(_referral);
    _gaugeFactory.exposedSetGauge(_gauge, true);
    _share = bound(_share, 0, _gaugeFactory.maxShareCap());
    _gaugeFactory.setReferralConfig(_gauge, _referral, _share);

    // it should emit ReferralConfigSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.ReferralConfigSet({_gauge: _gauge, _referral: address(0), _share: 0});
    _gaugeFactory.setReferralConfig(_gauge, address(0), 0);

    // it should clear referral config
    _assertReferralConfig(_gauge, address(0), 0);
  }

  function test_SetPenaltyConfigWhenTheCallerDoesNotHaveThePenaltyAdminRole(
    address _caller,
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external {
    _caller = _boundNotEq(_caller, _penaltyAdmin);
    _assumeFuzzable(_caller);
    bytes32 penaltyAdminRole = _gaugeFactory.PENALTY_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, penaltyAdminRole));
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, _penaltyRate);
  }

  modifier whenTheCallerHasThePenaltyAdminRole() {
    vm.startPrank(_penaltyAdmin);
    _;
    vm.stopPrank();
  }

  function test_SetPenaltyConfigWhenPenaltyRateExceedsMaxPips(uint256 _penaltyRate)
    external
    whenTheCallerHasThePenaltyAdminRole
  {
    _penaltyRate = bound(_penaltyRate, MAX_PIPS + 1, type(uint256).max);

    // it should revert with InvalidPenaltyRate
    vm.expectRevert(IGaugeFactory.InvalidPenaltyRate.selector);
    _gaugeFactory.setPenaltyConfig(0, _penaltyRate);
  }

  function test_SetPenaltyConfigWhenMinStakeBlocksExceedsMaxMinStakeBlocks(
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external whenTheCallerHasThePenaltyAdminRole {
    _minStakeBlocks = bound(_minStakeBlocks, _gaugeFactory.MAX_MIN_STAKE_BLOCKS() + 1, type(uint256).max);
    _penaltyRate = bound(_penaltyRate, 0, MAX_PIPS);

    // it should revert with InvalidMinStakeBlocks
    vm.expectRevert(IGaugeFactory.InvalidMinStakeBlocks.selector);
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, _penaltyRate);
  }

  function test_SetPenaltyConfigWhenTheConfigIsValid(
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external whenTheCallerHasThePenaltyAdminRole {
    _minStakeBlocks = bound(_minStakeBlocks, 0, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());
    _penaltyRate = bound(_penaltyRate, 0, MAX_PIPS);

    // it should emit PenaltyConfigSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.PenaltyConfigSet({_minStakeBlocks: _minStakeBlocks, _penaltyRate: _penaltyRate});
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, _penaltyRate);

    // it should update penaltyConfig
    IGaugeFactory.PenaltyConfig memory config = _gaugeFactory.penaltyConfig();
    assertEq(config.minStakeBlocks, _minStakeBlocks);
    assertEq(config.penaltyRate, _penaltyRate);
    assertEq(_gaugeFactory.minStakeBlocks(_gauge), _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenTheCallerDoesNotHaveThePenaltyAdminRole(
    address _caller,
    address _gaugeAddress,
    uint256 _minStakeBlocks
  ) external {
    _caller = _boundNotEq(_caller, _penaltyAdmin);
    _assumeFuzzable(_caller);
    bytes32 penaltyAdminRole = _gaugeFactory.PENALTY_ADMIN_ROLE();

    vm.prank(_caller);
    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(_accessControlError(_caller, penaltyAdminRole));
    _gaugeFactory.setMinStakeBlocks(_gaugeAddress, _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenTheGaugeIsInvalid(
    address _invalidGauge,
    uint256 _minStakeBlocks
  ) external whenTheCallerHasThePenaltyAdminRole {
    _minStakeBlocks = bound(_minStakeBlocks, 0, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());

    // it should revert with InvalidGauge
    vm.expectRevert(IGaugeFactory.InvalidGauge.selector);
    _gaugeFactory.setMinStakeBlocks(_invalidGauge, _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenMinStakeBlocksExceedsMaxMinStakeBlocks(
    address _gaugeAddress,
    uint256 _minStakeBlocks
  ) external whenTheCallerHasThePenaltyAdminRole {
    _gaugeFactory.exposedSetGauge(_gaugeAddress, true);
    _minStakeBlocks = bound(_minStakeBlocks, _gaugeFactory.MAX_MIN_STAKE_BLOCKS() + 1, type(uint256).max);

    // it should revert with InvalidMinStakeBlocks
    vm.expectRevert(IGaugeFactory.InvalidMinStakeBlocks.selector);
    _gaugeFactory.setMinStakeBlocks(_gaugeAddress, _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenTheOverrideIsNonzero(
    address _gaugeAddress,
    uint256 _minStakeBlocks
  ) external whenTheCallerHasThePenaltyAdminRole {
    _gaugeFactory.exposedSetGauge(_gaugeAddress, true);
    _minStakeBlocks = bound(_minStakeBlocks, 1, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());

    // it should emit MinStakeBlocksSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.MinStakeBlocksSet({_gauge: _gaugeAddress, _minStakeBlocks: _minStakeBlocks});
    _gaugeFactory.setMinStakeBlocks(_gaugeAddress, _minStakeBlocks);

    // it should update minStakeBlocks
    assertEq(_gaugeFactory.minStakeBlocks(_gaugeAddress), _minStakeBlocks);
  }

  function test_SetMinStakeBlocksWhenClearingTheOverride(
    address _gaugeAddress,
    uint256 _minStakeBlocks
  ) external whenTheCallerHasThePenaltyAdminRole {
    _gaugeFactory.exposedSetGauge(_gaugeAddress, true);
    _minStakeBlocks = bound(_minStakeBlocks, 1, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());
    _gaugeFactory.setMinStakeBlocks(_gaugeAddress, _minStakeBlocks);
    uint256 defaultMinStakeBlocks = _gaugeFactory.DEFAULT_MIN_STAKE_BLOCKS();

    // it should emit MinStakeBlocksSet
    vm.expectEmit(address(_gaugeFactory));
    emit IGaugeFactory.MinStakeBlocksSet({_gauge: _gaugeAddress, _minStakeBlocks: 0});
    _gaugeFactory.setMinStakeBlocks(_gaugeAddress, 0);

    // it should set minStakeBlocks to the minimum value
    assertEq(_gaugeFactory.minStakeBlocks(_gaugeAddress), defaultMinStakeBlocks);
  }

  function test_EffectivePenaltyConfigWhenTheGaugeHasNoMinStakeBlocksOverride(
    uint256 _minStakeBlocks,
    uint256 _penaltyRate
  ) external {
    _minStakeBlocks = bound(_minStakeBlocks, 0, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());
    _penaltyRate = bound(_penaltyRate, 0, MAX_PIPS);

    vm.prank(_penaltyAdmin);
    _gaugeFactory.setPenaltyConfig(_minStakeBlocks, _penaltyRate);

    IGaugeFactory.PenaltyConfig memory config = _gaugeFactory.effectivePenaltyConfig(_gauge);

    // it should return the default min stake blocks
    assertEq(config.minStakeBlocks, _minStakeBlocks);
    // it should return the factory penalty rate
    assertEq(config.penaltyRate, _penaltyRate);
  }

  function test_EffectivePenaltyConfigWhenTheGaugeHasAMinStakeBlocksOverride(
    uint256 _defaultMinStakeBlocks,
    uint256 _overrideMinStakeBlocks,
    uint256 _penaltyRate
  ) external {
    _defaultMinStakeBlocks = bound(_defaultMinStakeBlocks, 0, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());
    _overrideMinStakeBlocks = bound(_overrideMinStakeBlocks, 1, _gaugeFactory.MAX_MIN_STAKE_BLOCKS());
    _penaltyRate = bound(_penaltyRate, 0, MAX_PIPS);

    _gaugeFactory.exposedSetGauge(_gauge, true);
    vm.startPrank(_penaltyAdmin);
    _gaugeFactory.setPenaltyConfig(_defaultMinStakeBlocks, _penaltyRate);
    _gaugeFactory.setMinStakeBlocks(_gauge, _overrideMinStakeBlocks);
    vm.stopPrank();

    IGaugeFactory.PenaltyConfig memory config = _gaugeFactory.effectivePenaltyConfig(_gauge);

    // it should return the override min stake blocks
    assertEq(config.minStakeBlocks, _overrideMinStakeBlocks);
    // it should return the factory penalty rate
    assertEq(config.penaltyRate, _penaltyRate);
  }

  function _deployGaugeFactory() internal returns (GaugeFactoryHarness _deployedGaugeFactory) {
    _deployedGaugeFactory = _deployGaugeFactoryHarness(false);
  }

  function _deployGaugeFactoryHarness(bool _isStable) internal returns (GaugeFactoryHarness _deployedGaugeFactory) {
    _mockAndExpect(_leafVoter, abi.encodeCall(ILeafVoter.FACTORY_REGISTRY, ()), abi.encode(_factoryRegistry));
    IGaugeFactory.InitParams memory _params = _defaultParams();
    _params.isStable = _isStable;
    _deployedGaugeFactory = new GaugeFactoryHarness(_params);
  }

  function _defaultParams() internal view returns (IGaugeFactory.InitParams memory _params) {
    _params = IGaugeFactory.InitParams({
      leafVoter: _leafVoter,
      votingRewardsFactory: _votingRewardsFactory,
      isStable: false,
      capAdmin: _capAdmin,
      referralAdmin: _referralAdmin,
      penaltyAdmin: _penaltyAdmin,
      capOperator: _capOperator,
      defaultCap: _DEFAULT_CAP,
      operatorMinCap: _OPERATOR_MIN_CAP,
      operatorMaxCap: _OPERATOR_MAX_CAP,
      maxMinStakeBlocks: _MAX_MIN_STAKE_BLOCKS
    });
  }

  function _mockCreateGaugeInputs() internal returns (address _expectedGauge) {
    _expectedGauge =
      _mockCreateGaugeInputs(address(_gaugeFactory), _gaugeFactory.IMPLEMENTATION(), _gaugeFactory.IS_STABLE());
    _mockAndExpect(
      _votingRewardsFactory,
      abi.encodeCall(IVotingRewardsFactory.createRewards, (_expectedGauge, _rewardTokens())),
      abi.encode(_votingRewardsManager)
    );
  }

  /// @dev Mocks the createGauge collaborators without registering call expectations, for revert paths.
  function _mockCreateGaugeInputsWithoutExpectations() internal {
    _mockPoolTokens();
    vm.mockCall(
      _votingRewardsFactory,
      abi.encodeWithSelector(IVotingRewardsFactory.createRewards.selector),
      abi.encode(_votingRewardsManager)
    );
  }

  function _rewardTokens() internal view returns (address[] memory _tokens) {
    _tokens = new address[](2);
    _tokens[0] = _token0;
    _tokens[1] = _token1;
  }

  function _mockCreateGaugeInputs(
    address _factory,
    address _implementation,
    bool
  ) internal returns (address _expectedGauge) {
    _mockPoolTokens();

    bytes32 salt = keccak256(abi.encodePacked(_pool));
    _expectedGauge =
      Clones.predictDeterministicAddress({implementation: _implementation, salt: salt, deployer: _factory});
  }

  function _assertGaugeFields(address _gaugeAddress, address _factory, bool _isPool) internal view {
    assertEq(IV2Gauge(_gaugeAddress).stakingToken(), _pool);
    assertEq(IGauge(_gaugeAddress).votingRewardsManager(), _votingRewardsManager);
    assertEq(IGauge(_gaugeAddress).voter(), _leafVoter);
    assertEq(IGauge(_gaugeAddress).gaugeFactory(), _factory);
    assertEq(IGauge(_gaugeAddress).isPool(), _isPool);
  }

  function _assertReferralConfig(address _gaugeAddress, address _referral, uint256 _share) internal view {
    (address actualReferral, uint256 actualShare) = _gaugeFactory.referralConfig(_gaugeAddress);
    assertEq(actualReferral, _referral);
    assertEq(actualShare, _share);
  }

  function _mockEmergencyCouncil() internal {
    // Default any (role, account) lookup on the leaf voter to false, then flag the emergency council.
    vm.mockCall(_leafVoter, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    vm.mockCall(
      _leafVoter,
      abi.encodeCall(IAccessControl.hasRole, (Roles.EMERGENCY_COUNCIL_ROLE, _emergencyCouncil)),
      abi.encode(true)
    );
  }

  function _grantFactoryRole(bytes32 _role, address _account) internal {
    vm.prank(_capAdmin);
    _gaugeFactory.grantRole(_role, _account);
  }

  function _mockPoolTokens() internal {
    vm.mockCall(_pool, abi.encodeCall(IPool.token0, ()), abi.encode(_token0));
    vm.mockCall(_pool, abi.encodeCall(IPool.token1, ()), abi.encode(_token1));
  }

  /// @dev Expects the gauge settlement call to return an empty window.
  function _expectSettleGauge() internal {
    _mockAndExpect(
      _leafVoter, abi.encodeCall(ILeafVoter.settleGauge, (_gauge)), abi.encode(uint128(0), uint48(0), uint48(0))
    );
  }

  function _expectFlushFees() internal {
    _mockAndExpect(_gauge, abi.encodeCall(IGauge.votingRewardsManager, ()), abi.encode(_votingRewardsManager));
    _mockAndExpect(_votingRewardsManager, abi.encodeCall(IVotingRewardsManager.flushFees, ()), '');
  }

  function _expectFlushFeesRevert() internal {
    _mockAndExpect(_gauge, abi.encodeCall(IGauge.votingRewardsManager, ()), abi.encode(_votingRewardsManager));
    bytes memory _calldata = abi.encodeCall(IVotingRewardsManager.flushFees, ());
    vm.mockCallRevert(
      _votingRewardsManager,
      _calldata,
      abi.encodeWithSelector(IVotingRewardsManager.FeeCollectionFailed.selector, _gauge)
    );
    vm.expectCall(_votingRewardsManager, _calldata);
  }

  function _boundUnauthorized(address _caller) internal returns (address _boundedCaller) {
    _boundedCaller = _excludingAddressZero(_caller);

    while (_boundedCaller == _capAdmin || _boundedCaller == _capOperator || _boundedCaller == _emergencyCouncil) {
      _boundedCaller = _excludingAddressZero(
        address(
          uint160(uint256(keccak256(abi.encodePacked(_boundedCaller, _capAdmin, _capOperator, _emergencyCouncil))))
        )
      );
    }

    _assumeFuzzable(_boundedCaller);
  }

  function _accessControlError(address _account, bytes32 _role) internal pure returns (bytes memory _error) {
    _error = abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _account, _role);
  }
}

contract GaugeFactoryHarness is GaugeFactory {
  constructor(IGaugeFactory.InitParams memory _params) GaugeFactory(_params) {}

  function exposedSetGauge(address _gauge, bool _isGauge) external {
    isGauge[_gauge] = _isGauge;
  }

  function exposedSetStoredEmissionCap(address _gauge, uint128 _cap) external {
    emissionCap[_gauge] = _cap;
  }
}
