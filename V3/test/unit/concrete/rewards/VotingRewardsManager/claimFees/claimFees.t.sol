// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerClaimFees is UnitVotingRewardsManager {
  uint256 internal _expectedFees0;
  uint256 internal _expectedFees1;

  function setUp() public override {
    super.setUp();
    // @dev Deploy real ERC20 code at the fee token addresses so claims move and assert actual balances
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 0', 'FEE0', uint8(18)), _TOKEN0);
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 1', 'FEE1', uint8(18)), _TOKEN1);
  }

  function test_WhenTheRecipientIsTheZeroAddress(uint256 _tokenId, address _caller) external {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IIncentiveStreaming.ZeroAddress.selector);
    vm.prank(_caller);
    votingRewardsManager.claimFees(_tokenId, address(0), type(uint256).max);
  }

  modifier whenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenTheCheckpointLimitIsZero(
    uint256 _tokenId,
    address _recipient
  ) external whenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_recipient);

    // it should revert with ZeroCheckpoints
    vm.expectRevert(IVotingRewardsManager.ZeroCheckpoints.selector);
    votingRewardsManager.claimFees(_tokenId, _recipient, 0);
  }

  modifier whenTheCheckpointLimitIsNotZero() {
    _;
  }

  function test_WhenTheCallerIsNotTheVoterOrTheRegisteredOperator(
    uint256 _tokenId,
    address _caller,
    address _operator,
    address _recipient
  ) external whenTheRecipientIsNotTheZeroAddress whenTheCheckpointLimitIsNotZero {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    vm.assume(_caller != _VOTER && _caller != _operator);
    vm.mockCall(_VOTER, abi.encodeCall(ILeafVoter.operator, (_tokenId)), abi.encode(_operator));

    // it should revert with NotAuthorized
    vm.expectRevert(IVotingRewardsManager.NotAuthorized.selector);
    vm.prank(_caller);
    votingRewardsManager.claimFees(_tokenId, _recipient, type(uint256).max);
  }

  modifier whenTheCallerIsAuthorized() {
    _;
  }

  modifier whenThereAreNoPendingFees() {
    _;
  }

  modifier whenTheClaimDoesNotReachTheLatestCheckpoint() {
    _;
  }

  function test_GivenNoFeeTokenIsTheWrappedNative(
    uint128 _weight,
    uint256 _fee0,
    uint256 _fee1,
    address _recipient
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimDoesNotReachTheLatestCheckpoint
  {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != address(votingRewardsManager) && _recipient != _TOKEN0 && _recipient != _TOKEN1);

    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev Require enough fees for each credited token to produce a nonzero claim
    uint256 _minClaimableFees = _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION) + 1;
    _fee0 = bound(_fee0, _minClaimableFees, 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the accrued fees, creating user checkpoint 2
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A prior flush collects the gauge fees, clearing `lastPendingFees` without claiming rewards
    _mockGaugeCollectFees(_fee0, _fee1);
    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // @dev The second checkpoint credited the fees against the permanent supply
    uint256 _reward0 = uint256(_weight) * (_fee0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_fee1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;

    // it should not collect the gauge fees
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), '');

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, _TOKEN1, _reward1);

    // @dev A limit of one user checkpoint stops the claim before the latest user checkpoint
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, _recipient, 1);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all credited fees, except accumulator rounding dust
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(_recipient), _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(_recipient), _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    // @dev The claimed fees never exceed the fees collected from the gauge
    assertLe(IERC20(_TOKEN0).balanceOf(_recipient), _fee0);
    assertLe(IERC20(_TOKEN1).balanceOf(_recipient), _fee1);

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, 2);
  }

  modifier givenAFeeTokenIsTheWrappedNative() {
    _;
  }

  function test_GivenUnwrappingIsSupported()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimDoesNotReachTheLatestCheckpoint
    givenAFeeTokenIsTheWrappedNative
  {
    address _recipient = makeAddr('feeRecipient');
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _fee0 = 2000 * TOKEN_1;
    uint256 _fee1 = 2000 * TOKEN_1;

    // @dev token0 is the wrapped native and auto unwrapping is enabled
    VotingRewardsManager _manager = _setupWrappedNativeFeeToken(address(_weth));

    // @dev Record a permanent stake, then a second checkpoint that credits the accrued fees
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    _manager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    _manager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A prior flush collects the gauge fees, funding the manager with real wrapped native and the ERC20 leg
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_fee0, _fee1));
    // @dev Simulate the gauge fees being collected into the manager
    vm.deal(address(this), _fee0);
    _weth.deposit{value: _fee0}();
    _weth.transfer(address(_manager), _fee0);
    TestERC20(_TOKEN1).mint(address(_manager), _fee1);
    vm.prank(_GAUGE_FACTORY);
    _manager.flushFees();

    // @dev A single permanent staker owns all credited fees with no rounding carry for these values
    uint256 _reward0 = uint256(_weight) * (_fee0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_fee1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;

    // it should not collect the gauge fees again on the claim
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), '');
    uint256 _nativeBalanceBefore = _recipient.balance;

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(_manager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, address(_weth), _reward0);
    _expectEmit(address(_manager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    _manager.claimFees(_TOKEN_ID_A, _recipient, 1);

    // it should unwrap the wrapped native fee token
    assertEq(_weth.balanceOf(_recipient), 0);
    assertEq(_weth.balanceOf(address(_manager)), 0);
    // it should send the native token to the recipient
    assertEq(_recipient.balance - _nativeBalanceBefore, _reward0);
    // it should transfer the other owed token to the recipient
    assertEq(IERC20(_TOKEN1).balanceOf(_recipient), _reward1);
  }

  function test_GivenUnwrappingIsNotSupported()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimDoesNotReachTheLatestCheckpoint
    givenAFeeTokenIsTheWrappedNative
  {
    address _recipient = makeAddr('feeRecipient');
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _fee0 = 2000 * TOKEN_1;
    uint256 _fee1 = 2000 * TOKEN_1;

    // @dev token0 is the wrapped native but auto unwrapping is disabled
    VotingRewardsManager _manager = _setupWrappedNativeFeeToken(address(0));

    // @dev Record a permanent stake, then a second checkpoint that credits the accrued fees
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    _manager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    _manager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A prior flush collects the gauge fees, funding the manager with the wrapped native and the ERC20 leg
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_fee0, _fee1));
    // @dev Simulate the gauge fees being collected into the manager
    vm.deal(address(this), _fee0);
    _weth.deposit{value: _fee0}();
    _weth.transfer(address(_manager), _fee0);
    TestERC20(_TOKEN1).mint(address(_manager), _fee1);
    vm.prank(_GAUGE_FACTORY);
    _manager.flushFees();

    // @dev A single permanent staker owns all credited fees with no rounding carry for these values
    uint256 _reward0 = uint256(_weight) * (_fee0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_fee1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;

    // it should not collect the gauge fees again on the claim
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), '');
    uint256 _nativeBalanceBefore = _recipient.balance;

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(_manager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, address(_weth), _reward0);
    _expectEmit(address(_manager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, _recipient, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    _manager.claimFees(_TOKEN_ID_A, _recipient, 1);

    // it should transfer the wrapped native fee token as an ERC20 token
    assertEq(_weth.balanceOf(_recipient), _reward0);
    assertEq(_weth.balanceOf(address(_manager)), 0);
    // it should not send native token to the recipient
    assertEq(_recipient.balance, _nativeBalanceBefore);
    // @dev The non-native leg is delivered as a standard ERC20 transfer
    assertEq(IERC20(_TOKEN1).balanceOf(_recipient), _reward1);
  }

  modifier whenTheClaimReachesTheLatestCheckpoint() {
    _;
  }

  function test_WhenTheStakeHasNoActiveVotingPower(
    uint128 _weight,
    uint8 _multiplier0,
    uint8 _multiplier1
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimReachesTheLatestCheckpoint
  {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    _multiplier0 = uint8(bound(_multiplier0, 1, type(uint8).max));
    _multiplier1 = uint8(bound(_multiplier1, 1, type(uint8).max));
    // @dev Make each fee amount a whole multiple of the supply so no fees remain after rounding
    uint256 _fee0 = uint256(_weight) * _multiplier0;
    uint256 _fee1 = uint256(_weight) * _multiplier1;

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the accrued fees, creating user checkpoint 2
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A prior flush collects the gauge fees, clearing `lastPendingFees` without claiming rewards
    _mockGaugeCollectFees(_fee0, _fee1);
    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    // @dev Resetting the allocation drops the stake's weight to zero while its earned rewards remain
    vm.warp(3 weeks);
    _mockGaugePendingFees(0, 0);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);

    // @dev The second checkpoint credited the fees against the permanent supply
    uint256 _reward0 = uint256(_weight) * (_fee0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_fee1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;

    // it should not collect the gauge fees
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), '');

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all credited fees, except accumulator rounding dust
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.alice), _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.alice), _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    // @dev The claimed fees never exceed the fees collected from the gauge
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _fee0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _fee1);

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  modifier whenTheStakeHasActiveVotingPower() {
    _;
  }

  function test_WhenTheCreditedFeesVary(
    uint128 _weight,
    uint256 _collected0,
    uint256 _collected1,
    uint48 _stakeTs,
    uint48 _claimTs
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimReachesTheLatestCheckpoint
    whenTheStakeHasActiveVotingPower
  {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev Require enough fees for each credited token to produce a nonzero claim
    uint256 _minClaimableFees = _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION) + 1;
    _collected0 = bound(_collected0, _minClaimableFees, 1_000_000 * TOKEN_1);
    _collected1 = bound(_collected1, _minClaimableFees, 1_000_000 * TOKEN_1);
    _stakeTs = uint48(bound(_stakeTs, 1 weeks, type(uint48).max - MAX_TIME));
    _claimTs = uint48(bound(_claimTs, _stakeTs + 1, _stakeTs + MAX_TIME));

    // @dev Record a permanent stake so voting power stays active and the reward is a single accumulator delta
    vm.warp(_stakeTs);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Claim later, when the gauge yields fees that the claim collects and credits
    vm.warp(_claimTs);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_collected0, _collected1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);

    // @dev Crediting the collected fees against the permanent supply yields the accumulator deltas
    uint256 _acc0 = _collected0 * FEE_ACCUMULATOR_PRECISION / _weight;
    uint256 _acc1 = _collected1 * FEE_ACCUMULATOR_PRECISION / _weight;
    // @dev The permanent stake reclaims the full accumulator delta back as its reward
    uint256 _reward0 = uint256(_weight) * _acc0 / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * _acc1 / FEE_ACCUMULATOR_PRECISION;

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all collected fees, except accumulator rounding dust
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.alice), _collected0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.alice), _collected1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    // @dev The claimed fees never exceed the fees collected from the gauge
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _collected0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _collected1);

    // it should credit the collected fees to the accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(_acc0, _acc1, _acc0 * (_claimTs - _origin), _acc1 * (_claimTs - _origin));

    // it should persist the updated fee claim state
    uint256 _globalCheckpointIndex = votingRewardsManager.globalCheckpointIndex();
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, _globalCheckpointIndex);
    assertEq(_claimState.lastUserCp, 1);
  }

  function test_WhenTheCreditedFeesAreKnown()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereAreNoPendingFees
    whenTheClaimReachesTheLatestCheckpoint
    whenTheStakeHasActiveVotingPower
  {
    // @dev A 4_000_000 token weight exceeds the fee accumulator precision and divides the round fee amounts exactly
    uint128 _weight = uint128(4_000_000 * TOKEN_1);
    // @dev Each fee carries one spare wei too small to register in the accumulator, left behind as dust
    uint256 _collected0 = 10_000 * TOKEN_1 + 1;
    uint256 _collected1 = 6000 * TOKEN_1 + 1;
    // @dev reward = weight * acc / FEE_ACCUMULATOR_PRECISION, trailing each collected fee by one wei
    uint256 _reward0 = 10_000 * TOKEN_1;
    uint256 _reward1 = 6000 * TOKEN_1;

    // @dev Record a permanent stake so voting power stays active and the reward is a single accumulator delta
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    vm.warp(2 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_collected0, _collected1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _collected0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _collected1);

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // @dev acc = fee * FEE_ACCUMULATOR_PRECISION / weight, discarding the spare wei
    uint256 _acc0 = 2.5e21;
    uint256 _acc1 = 1.5e21;
    // it should credit the collected fees to the accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(_acc0, _acc1, _acc0 * (2 weeks - _origin), _acc1 * (2 weeks - _origin));

    // it should transfer the owed token rewards to the recipient
    // @dev The recipient receives the reward rounded down, leaving one wei of dust in the manager
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), 1);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), 1);

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, 1);
  }

  modifier whenThereArePendingFees() {
    _;
  }

  modifier whenTheAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp() {
    _;
  }

  function test_WhenTheAccruedFeesVary(
    uint128 _weight,
    uint256 _credited0,
    uint256 _credited1,
    uint256 _accrued0,
    uint256 _accrued1
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    // @dev Voting supply must exceed the fee accumulator precision for rounding to leave nonzero buffered fees
    _weight = uint128(bound(_weight, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));
    _credited0 = bound(_credited0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _credited1 = bound(_credited1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0, 1, 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1, 1, 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the fees, advancing the accumulator and leaving them pending in this timestamp
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge accrued more fees since the credit, so the claim collects the pending amount plus the new accrual
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    uint256 _reward0 = uint256(_weight) * (_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    // @dev Compute the rounding remainder retained after the initial accumulator increase
    uint256 _buffered0 =
      _credited0 - _ceilDiv((_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
    uint256 _buffered1 =
      _credited1 - _ceilDiv((_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should buffer the fees accrued since the last update
    assertEq(votingRewardsManager.bufferedFees0(), _accrued0 + _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _accrued1 + _buffered1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all credited fees, except accumulator rounding dust
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.alice), _credited0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.alice), _credited1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    // @dev The claimed fees never exceed the fees collected from the gauge
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _credited0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _credited1);
    // @dev The manager retains the buffered accrual plus the reward rounding dust
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _accrued0 + (_credited0 - _reward0));
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _accrued1 + (_credited1 - _reward1));

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  function test_WhenTheAccruedFeesAreKnown()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasAlreadyUpdatedInTheCurrentTimestamp
  {
    // @dev A 4_000_000 token weight exceeds the fee accumulator precision and divides the round credited amounts exactly
    uint128 _weight = uint128(4_000_000 * TOKEN_1);
    // @dev Each credited fee carries one spare wei too small to register in the accumulator
    uint256 _credited0 = 10_000 * TOKEN_1 + 1;
    uint256 _credited1 = 6000 * TOKEN_1 + 1;
    // @dev The round accrual is buffered together with the one wei retained from each initial credit
    uint256 _accrued0 = 5000 * TOKEN_1;
    uint256 _accrued1 = 3000 * TOKEN_1;
    // @dev reward = weight * acc / FEE_ACCUMULATOR_PRECISION, trailing each credited fee by one wei
    uint256 _reward0 = 10_000 * TOKEN_1;
    uint256 _reward1 = 6000 * TOKEN_1;

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the fees, advancing the accumulator and leaving them pending in this timestamp
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The same timestamp claim collects the pending credit plus the new accrual
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should buffer the fees accrued since the last update
    assertEq(votingRewardsManager.bufferedFees0(), _accrued0 + 1);
    assertEq(votingRewardsManager.bufferedFees1(), _accrued1 + 1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The recipient receives the reward rounded down, the manager retains the buffered accrual plus one wei of dust
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _accrued0 + 1);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _accrued1 + 1);

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  modifier whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp() {
    _;
  }

  function test_WhenTheCreditDoesNotAdvanceTheAccumulator(
    uint128 _weight,
    uint256 _fee0,
    uint256 _fee1
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp
  {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev Require enough fees for each credited token to produce a nonzero claim
    uint256 _minClaimableFees = _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION) + 1;
    _fee0 = bound(_fee0, _minClaimableFees, 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A later claim collects only the pending fees with no newly accrued fees
    vm.warp(3 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_fee0, _fee1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _fee0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _fee1);

    uint256 _reward0 = uint256(_weight) * (_fee0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = uint256(_weight) * (_fee1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
    uint256 _globalCpBefore = votingRewardsManager.globalCheckpointIndex();

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should not create a new global reward point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalCpBefore);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all credited fees, except accumulator rounding dust
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.alice), _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.alice), _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    // @dev The claimed fees never exceed the fees collected from the gauge
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _fee0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _fee1);

    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  modifier whenTheCreditAdvancesTheAccumulator() {
    _;
  }

  function test_WhenTheClaimDoesNotReachTheLatestUserCheckpoint(
    uint128 _weight,
    uint256 _credited0,
    uint256 _credited1,
    uint256 _accrued0,
    uint256 _accrued1
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheCreditAdvancesTheAccumulator
  {
    // @dev Voting supply must exceed the fee accumulator precision for rounding to leave nonzero buffered fees
    _weight = uint128(bound(_weight, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));
    _credited0 = bound(_credited0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _credited1 = bound(_credited1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    uint256 _globalCpBefore = votingRewardsManager.globalCheckpointIndex();

    {
      // it should emit the ClaimFees event for each owed token
      // @dev The bounded range prices only the credited fees, leaving the newly accrued credit unclaimed
      uint256 _reward0 =
        uint256(_weight) * (_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
      uint256 _reward1 =
        uint256(_weight) * (_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) / FEE_ACCUMULATOR_PRECISION;
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);
    }

    // @dev A limit of one user checkpoint stops the claim before the latest user checkpoint
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, 1);

    // it should credit the collected fees to the accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    // @dev Include the rounding remainder retained from the first accumulator increase in the next credit
    uint256 _fees0 = _accrued0 + _credited0
      - _ceilDiv((_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
    uint256 _fees1 = _accrued1 + _credited1
      - _ceilDiv((_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
    _assertFeeAccumulator(
      _credited0 * FEE_ACCUMULATOR_PRECISION / _weight + _fees0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _credited1 * FEE_ACCUMULATOR_PRECISION / _weight + _fees1 * FEE_ACCUMULATOR_PRECISION / _weight,
      (_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) * (2 weeks - _origin)
        + (_fees0 * FEE_ACCUMULATOR_PRECISION / _weight) * (3 weeks - _origin),
      (_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) * (2 weeks - _origin)
        + (_fees1 * FEE_ACCUMULATOR_PRECISION / _weight) * (3 weeks - _origin)
    );

    // it should create a new global reward point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalCpBefore + 1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker earns only the credited fees since the accrued credit lies past the claim range
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.alice), _credited0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.alice), _credited1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _credited0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _credited1);
    // @dev The newly accrued fees stay in the manager for a later claim
    assertApproxEqAbs(
      IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _accrued0, _weight / FEE_ACCUMULATOR_PRECISION + 1
    );
    assertApproxEqAbs(
      IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _accrued1, _weight / FEE_ACCUMULATOR_PRECISION + 1
    );
    assertGe(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _accrued0);
    assertGe(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _accrued1);

    // it should not extend the claim range to the new global checkpoint
    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, _globalCpBefore);
    assertEq(_claimState.lastUserCp, 2);
  }

  modifier whenTheClaimReachesTheLatestUserCheckpoint() {
    _;
  }

  modifier whenTheStakeIsOwedRewards() {
    _;
  }

  function test_WhenTheRewardsVary(
    uint128 _weight,
    uint256 _credited0,
    uint256 _credited1,
    uint256 _accrued0,
    uint256 _accrued1
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheCreditAdvancesTheAccumulator
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheStakeIsOwedRewards
  {
    // @dev Voting supply must exceed the fee accumulator precision for rounding to leave nonzero buffered fees
    _weight = uint128(bound(_weight, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));
    _credited0 = bound(_credited0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _credited1 = bound(_credited1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    uint256 _globalCpBefore = votingRewardsManager.globalCheckpointIndex();

    // @dev Include the rounding remainder retained from the first accumulator increase in the next credit
    uint256 _fees0 = _accrued0 + _credited0
      - _ceilDiv((_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);
    uint256 _fees1 = _accrued1 + _credited1
      - _ceilDiv((_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) * _weight, FEE_ACCUMULATOR_PRECISION);

    {
      // it should emit the ClaimFees event for each owed token
      uint256 _reward0 = uint256(_weight)
        * (_credited0 * FEE_ACCUMULATOR_PRECISION / _weight + _fees0 * FEE_ACCUMULATOR_PRECISION / _weight)
        / FEE_ACCUMULATOR_PRECISION;
      uint256 _reward1 = uint256(_weight)
        * (_credited1 * FEE_ACCUMULATOR_PRECISION / _weight + _fees1 * FEE_ACCUMULATOR_PRECISION / _weight)
        / FEE_ACCUMULATOR_PRECISION;
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);
    }

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should credit the collected fees to the accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(
      _credited0 * FEE_ACCUMULATOR_PRECISION / _weight + _fees0 * FEE_ACCUMULATOR_PRECISION / _weight,
      _credited1 * FEE_ACCUMULATOR_PRECISION / _weight + _fees1 * FEE_ACCUMULATOR_PRECISION / _weight,
      (_credited0 * FEE_ACCUMULATOR_PRECISION / _weight) * (2 weeks - _origin)
        + (_fees0 * FEE_ACCUMULATOR_PRECISION / _weight) * (3 weeks - _origin),
      (_credited1 * FEE_ACCUMULATOR_PRECISION / _weight) * (2 weeks - _origin)
        + (_fees1 * FEE_ACCUMULATOR_PRECISION / _weight) * (3 weeks - _origin)
    );

    // it should create a new global reward point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalCpBefore + 1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The staker owns all collected fees, except accumulator rounding dust from each credit
    assertApproxEqAbs(
      IERC20(_TOKEN0).balanceOf(users.alice), _credited0 + _accrued0, 2 * (_weight / FEE_ACCUMULATOR_PRECISION + 1)
    );
    assertApproxEqAbs(
      IERC20(_TOKEN1).balanceOf(users.alice), _credited1 + _accrued1, 2 * (_weight / FEE_ACCUMULATOR_PRECISION + 1)
    );
    assertLe(IERC20(_TOKEN0).balanceOf(users.alice), _credited0 + _accrued0);
    assertLe(IERC20(_TOKEN1).balanceOf(users.alice), _credited1 + _accrued1);

    // it should extend the claim range to the new global checkpoint
    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  function test_WhenTheRewardsAreKnown()
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheCreditAdvancesTheAccumulator
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheStakeIsOwedRewards
  {
    // @dev A 4_000_000 token weight exceeds the fee accumulator precision and divides the round fee amounts exactly
    uint128 _weight = uint128(4_000_000 * TOKEN_1);
    // @dev Each credited fee carries one spare wei too small to register in the accumulator
    uint256 _credited0 = 10_000 * TOKEN_1 + 1;
    uint256 _credited1 = 6000 * TOKEN_1 + 1;
    // @dev The round accrual collected at claim time advances the accumulator a second time
    uint256 _accrued0 = 5000 * TOKEN_1;
    uint256 _accrued1 = 3000 * TOKEN_1;
    // @dev reward = weight * acc / FEE_ACCUMULATOR_PRECISION, trailing each credited fee by one wei
    uint256 _reward0 = 15_000 * TOKEN_1;
    uint256 _reward1 = 9000 * TOKEN_1;

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    uint256 _globalCpBefore = votingRewardsManager.globalCheckpointIndex();

    // it should emit the ClaimFees event for each owed token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should credit the collected fees to the accumulator
    // @dev Each credit advances acc by fee * FEE_ACCUMULATOR_PRECISION / supply
    // @dev token0 gains _credited0 * FEE_ACCUMULATOR_PRECISION / _weight = 2.5e21 at 2 weeks then 1.25e21 at 3 weeks
    // @dev token1 gains _credited1 * FEE_ACCUMULATOR_PRECISION / _weight = 1.5e21 at 2 weeks then 0.75e21 at 3 weeks
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(
      2.5e21 + 1.25e21,
      1.5e21 + 0.75e21,
      2.5e21 * (2 weeks - _origin) + 1.25e21 * (3 weeks - _origin),
      1.5e21 * (2 weeks - _origin) + 0.75e21 * (3 weeks - _origin)
    );

    // it should create a new global reward point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalCpBefore + 1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should transfer the owed token rewards to the recipient
    // @dev The recipient receives the reward rounded down, leaving one wei of dust in the manager
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), 1);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), 1);

    // it should extend the claim range to the new global checkpoint
    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  function test_WhenTheStakeIsNotOwedRewards(
    uint256 _credited0,
    uint256 _credited1,
    uint256 _accrued0,
    uint256 _accrued1,
    address _operator
  )
    external
    whenTheRecipientIsNotTheZeroAddress
    whenTheCheckpointLimitIsNotZero
    whenTheCallerIsAuthorized
    whenThereArePendingFees
    whenTheAccumulatorWasNotUpdatedInTheCurrentTimestamp
    whenTheCreditAdvancesTheAccumulator
    whenTheClaimReachesTheLatestUserCheckpoint
  {
    // @dev Claim through a registered operator, exercising the operator authorization path
    _assumeFuzzable(_operator);
    vm.assume(_operator != _VOTER);
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.operator, (_TOKEN_ID_A)), abi.encode(_operator));

    // @dev A dust stake claims alongside a large stake that holds nearly all the weight, so its reward rounds to zero
    uint128 _supplyWeight = uint128(1_000_000 * TOKEN_1);
    uint256 _supply = 1 + uint256(_supplyWeight);
    // @dev Capping each fee at supply / 4 keeps credited + accrued below the supply, so dust rewards floor to zero
    _credited0 = bound(_credited0, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), _supply / 4);
    _credited1 = bound(_credited1, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), _supply / 4);
    _accrued0 = bound(_accrued0, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), _supply / 4);
    _accrued1 = bound(_accrued1, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), _supply / 4);

    // @dev Record a dust stake to claim for and a large stake to absorb the fees
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _supplyWeight, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev A later checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _supplyWeight, _stakeEnd: 0, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    // it should collect the gauge fees
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    // it should emit the FeesCollected event for each collected token
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN0, _credited0 + _accrued0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.FeesCollected(_GAUGE, _TOKEN1, _credited1 + _accrued1);

    uint256 _globalCpBefore = votingRewardsManager.globalCheckpointIndex();

    // @dev Include the rounding remainder retained from the first accumulator increase in the next credit
    _expectedFees0 = _accrued0 + _credited0
      - _ceilDiv((_credited0 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);
    _expectedFees1 = _accrued1 + _credited1
      - _ceilDiv((_credited1 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);

    vm.prank(_operator);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should credit the collected fees to the accumulator
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeAccumulator(
      _credited0 * FEE_ACCUMULATOR_PRECISION / _supply + _expectedFees0 * FEE_ACCUMULATOR_PRECISION / _supply,
      _credited1 * FEE_ACCUMULATOR_PRECISION / _supply + _expectedFees1 * FEE_ACCUMULATOR_PRECISION / _supply,
      (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply) * (2 weeks - _origin)
        + (_expectedFees0 * FEE_ACCUMULATOR_PRECISION / _supply) * (3 weeks - _origin),
      (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply) * (2 weeks - _origin)
        + (_expectedFees1 * FEE_ACCUMULATOR_PRECISION / _supply) * (3 weeks - _origin)
    );

    // it should create a new global reward point
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalCpBefore + 1);

    // it should clear the last pending fees
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // it should not transfer any token rewards
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), 0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), 0);

    // it should extend the claim range to the new global checkpoint
    // it should persist the updated fee claim state
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  function testGas_claimFees_permanent() external {
    uint128 _weight = uint128(4000 * TOKEN_1);
    uint256 _credited0 = 10_000 * TOKEN_1 + 1;
    uint256 _credited1 = 6000 * TOKEN_1 + 1;
    uint256 _accrued0 = 5000 * TOKEN_1;
    uint256 _accrued1 = 3000 * TOKEN_1;

    // @dev Record a permanent stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev A second checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);
    vm.snapshotGasLastCall('VotingRewardsManager_claimFees_permanent');
  }

  function testGas_claimFees_nonPermanent() external {
    uint128 _weight = uint128(4000 * TOKEN_1);
    uint256 _credited0 = 10_000 * TOKEN_1 + 1;
    uint256 _credited1 = 6000 * TOKEN_1 + 1;
    uint256 _accrued0 = 5000 * TOKEN_1;
    uint256 _accrued1 = 3000 * TOKEN_1;

    // @dev The stake stays active and decaying through the claim so the closed form settles over the full range
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(1 weeks + MAX_TIME));

    // @dev Record a decaying stake, creating user checkpoint 1 against a zero accumulator
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // @dev A second checkpoint credits the first fees, advancing the accumulator and leaving them pending
    vm.warp(2 weeks);
    _mockGaugePendingFees(_credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // @dev In a later timestamp the gauge yields more fees, which the claim collects and credits
    vm.warp(3 weeks);
    _mockGaugeCollectFees(_credited0 + _accrued0, _credited1 + _accrued1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);
    vm.snapshotGasLastCall('VotingRewardsManager_claimFees_nonPermanent');
  }

  /**
   * @notice Deploys a manager whose token0 is the wrapped native
   * @dev Configures the reward tokens so the first fee leg exercises the auto unwrap branch
   * @param _wrappedNative The wrapped native address to configure on the manager
   * @return _manager The deployed manager under test
   */
  function _setupWrappedNativeFeeToken(address _wrappedNative) internal returns (VotingRewardsManager _manager) {
    address[] memory _rewards = new address[](2);
    _rewards[0] = address(_weth);
    _rewards[1] = _TOKEN1;
    _manager = new VotingRewardsManager(_VOTER, _GAUGE, _GAUGE_FACTORY, _wrappedNative, _rewards);
  }

  /**
   * @notice Mock a call to `IGauge.collectFees()` and deliver the reported fees to the manager
   * @param _amount0 Collected token0 fees
   * @param _amount1 Collected token1 fees
   */
  function _mockGaugeCollectFees(uint256 _amount0, uint256 _amount1) internal {
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_amount0, _amount1));
    TestERC20(_TOKEN0).mint(address(votingRewardsManager), _amount0);
    TestERC20(_TOKEN1).mint(address(votingRewardsManager), _amount1);
  }
}
