// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerComputeFeeRewards is UnitVotingRewardsManager {
  // @dev Fee credited against the active stake at the first checkpoint
  uint256 internal _credited0;
  uint256 internal _credited1;
  // @dev Extra fee that accrues after the first credit and is collected at the claim
  uint256 internal _accrued0;
  uint256 internal _accrued1;
  // @dev Fee credited after the stake expires and excluded by the claim
  uint256 internal _expired0;
  uint256 internal _expired1;

  function setUp() public override {
    super.setUp();
    // @dev Deploy real ERC20 code at the fee token addresses so claims move and assert actual balances
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 0', 'FEE0', uint8(18)), _TOKEN0);
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 1', 'FEE1', uint8(18)), _TOKEN1);
  }

  function test_WhenThereAreNoUserCheckpointsToProcess(address _recipient) external {
    _assumeFuzzable(_recipient);

    // @dev Claim for a veNFT that never checkpointed, so it has no user checkpoints to iterate
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, _recipient, type(uint256).max);

    // it should claim no rewards
    assertEq(IERC20(_TOKEN0).balanceOf(_recipient), 0);
    assertEq(IERC20(_TOKEN1).balanceOf(_recipient), 0);

    // it should preserve the fee claim state
    // @dev No global checkpoint was settled, so the claimed global pointer stays at zero
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, 0);
    assertEq(_claimState.lastUserCp, 1);
  }

  modifier whenThereAreUserCheckpointsToProcess() {
    _;
  }

  function test_WhenTheCheckpointLimitIsZero(uint128 _weight) external whenThereAreUserCheckpointsToProcess {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));

    // @dev Record a permanent stake so a user checkpoint exists to iterate
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The bounded claimFees reverts on a zero limit, so _computeFeeRewards only sees a zero limit via earnedFees
    (uint256 _reward0, uint256 _reward1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, 0);

    // it should return no rewards
    assertEq(_reward0, 0);
    assertEq(_reward1, 0);
  }

  modifier whenTheCheckpointLimitIsNotZero() {
    _;
  }

  function test_WhenThereAreNoNewGlobalCheckpointsToClaim(uint128 _weight)
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
  {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));

    // @dev Record a permanent stake, creating user checkpoint 1 and global checkpoint 1 at the same timestamp
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge yields no fees, so the claim collects nothing and writes no new global checkpoint
    _mockGaugeCollectFeesAt(block.timestamp, 0, 0);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should claim no rewards
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), 0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), 0);

    // it should preserve the fee claim state
    // @dev The only global checkpoint coincides with the user checkpoint, so the claim range never opens
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, 0);
    assertEq(_claimState.lastUserCp, 1);
  }

  modifier whenThereAreNewGlobalCheckpointsToClaim() {
    _;
  }

  function test_WhenTheStakeHasNoVotingPowerInAnyCheckpoint(
    uint128 _weightA,
    uint128 _weightB,
    uint8 _multiplier0,
    uint8 _multiplier1
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));

    uint256 _supply = uint256(_weightA) + _weightB;
    _multiplier0 = uint8(bound(_multiplier0, 1, type(uint8).max));
    _multiplier1 = uint8(bound(_multiplier1, 1, type(uint8).max));
    // @dev Make each fee amount a whole multiple of the supply so no fees remain after rounding
    uint256 _fee0 = _supply * _multiplier0;
    uint256 _fee1 = _supply * _multiplier1;

    // @dev The vote records a user checkpoint with voting power alongside a permanent stake that holds the supply
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Reset the vote and credit the accrued fees, recording a user checkpoint with no voting power
    _checkpointWithPendingFeesAt(2 weeks, _TOKEN_ID_A, _fee0, _fee1, 0, 0);

    // @dev The first claim settles the vote checkpoint and advances the claim state past it
    _mockGaugeCollectFeesAt(3 weeks, _fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // @dev The collected fees drain the gauge so no further credit accrues to the reset checkpoint
    _mockGaugePendingFees(0, 0);

    // @dev Advance the global history so the reset checkpoint has a new range to claim over
    vm.warp(4 weeks);
    votingRewardsManager.advanceGlobalPoints();
    uint256 _globalCheckpointIndex = votingRewardsManager.globalCheckpointIndex();

    // @dev The second claim processes only the reset checkpoint which holds no voting power
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.bob, type(uint256).max);

    // it should claim no rewards
    assertEq(IERC20(_TOKEN0).balanceOf(users.bob), 0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.bob), 0);

    // @dev The collected fee stays in the contract aside from the reward paid on the first claim
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _fee0 - IERC20(_TOKEN0).balanceOf(users.alice));
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _fee1 - IERC20(_TOKEN1).balanceOf(users.alice));

    // it should advance the fee claim state
    // @dev The loop runs through the zero power reset checkpoint advancing the claimed pointers without crediting rewards
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastGlobalCp, _globalCheckpointIndex);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
  }

  modifier whenTheStakeHasVotingPowerInAtLeastOneCheckpoint() {
    _;
  }

  modifier whenTheClaimReachesTheLatestUserCheckpoint() {
    _;
  }

  modifier whenTheRangeStartsAtTheUserCheckpoint() {
    _;
  }

  modifier whenTheStakeHasVotingPowerInSomeUserCheckpoints() {
    _;
  }

  function test_WhenThePartialRangeRewardIsKnown()
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInSomeUserCheckpoints
  {
    // @dev Two permanent stakes split a supply above FEE_ACCUMULATOR_PRECISION so rounding leaves buffered fees
    //      Neither weight decays across the claim
    uint128 _weightA = uint128(1_000_000_000 * TOKEN_1);
    uint128 _weightB = uint128(2_000_000_000 * TOKEN_1);

    // @dev The active ranges credit 7000 and 11000 then 5000 and 13000, the skipped range 9000 and 6000
    _credited0 = 7000 * TOKEN_1;
    _credited1 = 11_000 * TOKEN_1;
    uint256 _skipped0 = 9000 * TOKEN_1;
    uint256 _skipped1 = 6000 * TOKEN_1;
    _accrued0 = 5000 * TOKEN_1;
    _accrued1 = 13_000 * TOKEN_1;

    // @dev A permanent stake holds weight throughout so the supply never collapses to the staker alone
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Credit the first fee against the staker weight then reset it so user checkpoint 2 holds no voting power
    _checkpointWithPendingFeesAt(2 weeks, _TOKEN_ID_A, _credited0, _credited1, 0, 0);

    // @dev Credit a fee while the staker is reset so this range accrues only to the permanent stake then re-vote
    _checkpointWithPendingFeesAt(3 weeks, _TOKEN_ID_A, _credited0 + _skipped0, _credited1 + _skipped1, _weightA, 0);

    // @dev The claim collects the cumulative fees crediting the accrued amount against the restored weight
    _mockGaugeCollectFeesAt(4 weeks, _credited0 + _skipped0 + _accrued0, _credited1 + _skipped1 + _accrued1);

    // @dev Each later credit includes the rounding remainder retained from the preceding accumulator increase
    //      inc_credited0 = floor(7000e18 * 1e18 / 3000e18)  = 2_333_333_333_333_333_333
    //      inc_accrued0  = floor((5000e18 + 1000) * 1e18 / 3000e18) = 1_666_666_666_666_666_667
    //      inc_credited1 = floor(11000e18 * 1e18 / 3000e18) = 3_666_666_666_666_666_666
    //      inc_accrued1  = floor(13000e18 * 1e18 / 3000e18) = 4_333_333_333_333_333_333
    //      The skipped range never enters the staker reward but carries each preceding remainder forward
    // @dev reward = weightA * (inc_credited + inc_accrued) / FEE_ACCUMULATOR_PRECISION
    //      reward0 = 1000 * (2_333_333_333_333_333_333 + 1_666_666_666_666_666_667) = 4_000e18
    //      reward1 = 1000 * (3_666_666_666_666_666_666 + 4_333_333_333_333_333_333) = 7_999_999_999_999_999_999_000
    uint256 _reward0 = 4000 * TOKEN_1;
    uint256 _reward1 = 7_999_999_999_999_999_999_000;

    // it should skip the user checkpoints without voting power
    // it should claim rewards for the user checkpoints with voting power
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder including the skipped fee stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _skipped0 + _accrued0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _skipped1 + _accrued1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  function test_WhenThePartialRangeRewardVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _credited0_,
    uint256 _credited1_,
    uint256 _skipped0,
    uint256 _skipped1,
    uint256 _accrued0_,
    uint256 _accrued1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInSomeUserCheckpoints
  {
    // @dev The claimed weight must be at least FEE_ACCUMULATOR_PRECISION so an increment of one does not round its reward to zero
    _weightA = uint128(bound(_weightA, FEE_ACCUMULATOR_PRECISION, 1_000_000_000 * TOKEN_1));
    // @dev The permanent weight must exceed FEE_ACCUMULATOR_PRECISION for rounding to leave buffered fees
    _weightB = uint128(bound(_weightB, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));

    // @dev Bound the active range fees against the combined supply and the skipped fee against the permanent stake
    uint256 _supply = uint256(_weightA) + _weightB;
    _credited0 = _boundFeeToCredit(_credited0_, _supply);
    _credited1 = _boundFeeToCredit(_credited1_, _supply);
    _skipped0 = _boundFeeToCredit(_skipped0, _weightB);
    _skipped1 = _boundFeeToCredit(_skipped1, _weightB);
    _accrued0 = _boundFeeToCredit(_accrued0_, _supply);
    _accrued1 = _boundFeeToCredit(_accrued1_, _supply);

    // @dev A permanent stake holds weight throughout so the supply never collapses to the staker alone
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Credit the first fee against the staker weight then reset it so user checkpoint 2 holds no voting power
    _checkpointWithPendingFeesAt(2 weeks, _TOKEN_ID_A, _credited0, _credited1, 0, 0);

    // @dev Credit a fee while the staker is reset so this range accrues only to the permanent stake then re-vote
    _checkpointWithPendingFeesAt(3 weeks, _TOKEN_ID_A, _credited0 + _skipped0, _credited1 + _skipped1, _weightA, 0);

    // @dev The claim collects the cumulative fees crediting the accrued amount against the restored weight
    _mockGaugeCollectFeesAt(4 weeks, _credited0 + _skipped0 + _accrued0, _credited1 + _skipped1 + _accrued1);

    // @dev Compute the rounding remainder carried through the skipped credit into the final credit
    uint256 _buffered0 = _computeRoundingRemainder(_credited0, _supply);
    uint256 _buffered1 = _computeRoundingRemainder(_credited1, _supply);
    _buffered0 = _computeRoundingRemainder(_skipped0 + _buffered0, _weightB);
    _buffered1 = _computeRoundingRemainder(_skipped1 + _buffered1, _weightB);

    // @dev The claimed stake earns its weight on the first and third ranges only and never the skipped fee
    uint256 _reward0 = _weightA
      * (_credited0
        * FEE_ACCUMULATOR_PRECISION
        / _supply
        + (_accrued0 + _buffered0)
        * FEE_ACCUMULATOR_PRECISION
        / _supply) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = _weightA
      * (_credited1
        * FEE_ACCUMULATOR_PRECISION
        / _supply
        + (_accrued1 + _buffered1)
        * FEE_ACCUMULATOR_PRECISION
        / _supply) / FEE_ACCUMULATOR_PRECISION;

    // it should skip the user checkpoints without voting power
    // it should claim rewards for the user checkpoints with voting power
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder including the skipped fee stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _skipped0 + _accrued0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _skipped1 + _accrued1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheStakeHasVotingPowerInEveryUserCheckpoint() {
    _;
  }

  function test_WhenTheStakeIsPermanent(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _credited0_,
    uint256 _credited1_,
    uint256 _accrued0_,
    uint256 _accrued1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev The permanent co-staker must exceed FEE_ACCUMULATOR_PRECISION for rounding to leave buffered fees
    _weightB = uint128(bound(_weightB, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));

    // @dev Two permanent stakes hold all the supply, so neither weight decays across the claim range
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    uint256 _supply = uint256(_weightA) + _weightB;
    // @dev Bound each fee so every credit pays the claimed stake at least one fee unit
    uint256 _minClaimableFees =
      _ceilDiv(_ceilDiv(FEE_ACCUMULATOR_PRECISION, _weightA) * _supply, FEE_ACCUMULATOR_PRECISION);
    _credited0 = bound(_credited0_, _minClaimableFees, 1_000_000 * TOKEN_1);
    _credited1 = bound(_credited1_, _minClaimableFees, 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0_, _minClaimableFees, 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1_, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev A second checkpoint credits the first fee and records user checkpoint 2 for the staker
    _checkpointWithPendingFeesAt(2 weeks, _TOKEN_ID_A, _credited0, _credited1, _weightA, 0);

    // @dev The claim collects the cumulative fees, crediting the accrued amount as a new accumulator delta
    _mockGaugeCollectFeesAt(3 weeks, _credited0 + _accrued0, _credited1 + _accrued1);

    // @dev Compute the rounding remainder retained after the first accumulator increase
    uint256 _buffered0 = _computeRoundingRemainder(_credited0, _supply);
    uint256 _buffered1 = _computeRoundingRemainder(_credited1, _supply);

    // @dev The permanent weight earns weightA times each increment and the two ranges telescope into one delta
    uint256 _reward0 = _weightA
      * (_credited0
        * FEE_ACCUMULATOR_PRECISION
        / _supply
        + (_accrued0 + _buffered0)
        * FEE_ACCUMULATOR_PRECISION
        / _supply) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = _weightA
      * (_credited1
        * FEE_ACCUMULATOR_PRECISION
        / _supply
        + (_accrued1 + _buffered1)
        * FEE_ACCUMULATOR_PRECISION
        / _supply) / FEE_ACCUMULATOR_PRECISION;

    // it should claim the reward as a single accumulator delta
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder stays in the contract for the co staker
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _accrued0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _accrued1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheStakeIsDecaying() {
    _;
  }

  function test_WhenTheStakeExpiredBeforeTheRangeStart(
    uint256 _slope,
    uint128 _weightB,
    uint256 _stakeEnd_,
    uint256 _creditTs_,
    uint256 _expired0_,
    uint256 _expired1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
    whenTheStakeIsDecaying
  {
    _slope = bound(_slope, 1, 1_000_000 * TOKEN_1 / MAX_TIME);
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));

    // @dev The lock ends on a fuzzed epoch boundary past the first week so the stake is recorded with live weight
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_stakeEnd_, 2 weeks, MAX_TIME)));
    uint128 _allocatedA = uint128(_slope * MAX_TIME);

    // @dev The fee credits on a fuzzed epoch boundary at or after the expiry so the decaying weight is already gone
    uint256 _creditTs = ProtocolTimeLibrary.epochStart(bound(_creditTs_, _stakeEnd, _stakeEnd + MAX_TIME));

    // @dev The fee credits against the permanent stake alone since the decaying weight has expired
    _expired0 = _boundFeeToCredit(_expired0_, _weightB);
    _expired1 = _boundFeeToCredit(_expired1_, _weightB);

    // @dev Record the decaying stake and the permanent stake in the same epoch with no fees yet
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocatedA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Advance the global history after expiry so every new global checkpoint sits at or past the stake end
    _advanceWithPendingFeesAt(_creditTs, _expired0, _expired1);

    // @dev The claim collects the post expiry fee where the decaying weight has already decayed to zero
    _mockGaugeCollectFeesAt(_creditTs + 1 weeks, _expired0, _expired1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // it should claim no rewards for the user checkpoint
    // @dev Every credited global checkpoint sits at or after the expiry so the decaying weight prices to zero
    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), 0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), 0);

    // @dev The whole credited fee stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _expired0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _expired1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheStakeIsActiveAtTheRangeStart() {
    _;
  }

  modifier whenTheStakeRemainsActiveThroughTheRange() {
    _;
  }

  function test_WhenTheFullRangeRewardIsKnown()
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
    whenTheStakeIsDecaying
    whenTheStakeIsActiveAtTheRangeStart
    whenTheStakeRemainsActiveThroughTheRange
  {
    // @dev Decaying stake A locks 1 billion TOKEN within MAX_TIME, so it mints near the full 1 billion TOKEN before decaying
    //      slope = 1_000_000_000 * TOKEN_1 / MAX_TIME (floored), bias = slope * (stakeEnd - ts)
    //      _vp1 = slope * 208 weeks at the mint, _vp2 = slope * 207 weeks at the first credit, _vp3 = slope * 206 weeks at the second credit
    uint128 _allocatedA = uint128(1_000_000_000 * TOKEN_1);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(1 weeks + MAX_TIME));
    uint256 _vp1 = 997_260_273_972_602_739_716_198_400;
    uint256 _vp2 = 992_465_753_424_657_534_236_793_600;
    uint256 _vp3 = 987_671_232_876_712_328_757_388_800;

    // @dev Permanent stake B holds _vp1 so both stakes start at the same weight, then the supply is _vp1 plus the decaying weight at each credit
    //      _supply2 = _vp1 + _vp2 = 1_989_726_027_397_260_273_952_992_000
    //      _supply3 = _vp1 + _vp3 = 1_984_931_506_849_315_068_473_587_200
    uint128 _weightB = uint128(_vp1);

    // @dev Credit a fee against the higher decaying weight at epoch 2 then the accrued amount against the lower at epoch 3
    _credited0 = 8000 * TOKEN_1;
    _credited1 = 12_000 * TOKEN_1;
    _accrued0 = 4000 * TOKEN_1;
    _accrued1 = 6000 * TOKEN_1;

    // @dev Record the decaying stake and the permanent stake in the same epoch
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocatedA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The permanent stake holds a flat _vp1 that never decays
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, block.timestamp), _vp1);

    // @dev The decaying stake mints at the same _vp1 as the permanent stake then keeps shrinking to _vp2 and _vp3
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _vp1);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 2 weeks), _vp2);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 3 weeks), _vp3);

    // @dev Credit the first fee against the higher decaying weight at epoch 2
    _advanceWithPendingFeesAt(2 weeks, _credited0, _credited1);

    // @dev The claim collects the cumulative fees, crediting the accrued amount against the lower weight at epoch 3
    _mockGaugeCollectFeesAt(3 weeks, _credited0 + _accrued0, _credited1 + _accrued1);

    // @dev The second credit includes the rounding remainder retained from the first accumulator increase
    //      reward0 = (_vp2 * (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply2) + _vp3 * ((_accrued0 + 1270) * FEE_ACCUMULATOR_PRECISION / _supply3)) / FEE_ACCUMULATOR_PRECISION
    //      reward1 = (_vp2 * (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply2) + _vp3 * ((_accrued1 + 1905) * FEE_ACCUMULATOR_PRECISION / _supply3)) / FEE_ACCUMULATOR_PRECISION
    //      total token0 fees = 12000 so half is 6000, total token1 fees = 18000 so half is 9000
    //      reward0 is ~5980.7 and reward1 is ~8971.0, both just below half
    uint256 _reward0 = 5_980_699_610_034_340_259_521;
    uint256 _reward1 = 8_971_049_415_051_510_389_282;

    // it should account for the decay at each global checkpoint
    // it should claim the rewards over the full range
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev Both stakes start at the same _vp1, yet the decaying stake earns less than half the fees as its weight decayed
    assertLt(_reward0, (_credited0 + _accrued0) / 2);
    assertLt(_reward1, (_credited1 + _accrued1) / 2);

    // @dev The unclaimed remainder stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _accrued0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _accrued1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  function test_WhenTheFullRangeRewardVaries(
    uint256 _slope,
    uint128 _weightB,
    uint256 _lockWeeks,
    uint256 _credited0_,
    uint256 _credited1_,
    uint256 _accrued0_,
    uint256 _accrued1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
    whenTheStakeIsDecaying
    whenTheStakeIsActiveAtTheRangeStart
    whenTheStakeRemainsActiveThroughTheRange
  {
    _slope = bound(_slope, 1, 1_000_000 * TOKEN_1 / MAX_TIME);
    // @dev The permanent weight must exceed FEE_ACCUMULATOR_PRECISION for rounding to leave buffered fees
    _weightB = uint128(bound(_weightB, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));
    // @dev The lock ends past the claim range so the decaying weight stays positive at every credit
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(bound(_lockWeeks, 4, 200) * 1 weeks));
    uint128 _allocatedA = uint128(_slope * MAX_TIME);

    // @dev Record the decaying stake and the permanent stake in the same epoch
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocatedA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The decaying weight shrinks each epoch while the permanent stake holds the supply up
    uint256 _supply2 = _weightB + _slope * (_stakeEnd - 2 weeks);
    uint256 _supply3 = _weightB + _slope * (_stakeEnd - 3 weeks);
    _credited0 = _boundFeeToCredit(_credited0_, _supply2);
    _credited1 = _boundFeeToCredit(_credited1_, _supply2);
    _accrued0 = _boundFeeToCredit(_accrued0_, _supply3);
    _accrued1 = _boundFeeToCredit(_accrued1_, _supply3);

    // @dev Advance the global history, crediting the first fee against the higher decaying weight
    _advanceWithPendingFeesAt(2 weeks, _credited0, _credited1);

    // @dev The claim collects the cumulative fees, crediting the accrued amount against the lower decaying weight
    _mockGaugeCollectFeesAt(3 weeks, _credited0 + _accrued0, _credited1 + _accrued1);

    // @dev The reward sums each increment weighted by the decaying balance at its credit, floored as the contract does
    uint256 _vp2 = _slope * (_stakeEnd - 2 weeks);
    uint256 _vp3 = _slope * (_stakeEnd - 3 weeks);
    uint256 _reward0 =
      (_vp2
          * (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply2)
          + _vp3
          * ((_accrued0 + _computeRoundingRemainder(_credited0, _supply2)) * FEE_ACCUMULATOR_PRECISION / _supply3))
        / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 =
      (_vp2
          * (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply2)
          + _vp3
          * ((_accrued1 + _computeRoundingRemainder(_credited1, _supply2)) * FEE_ACCUMULATOR_PRECISION / _supply3))
        / FEE_ACCUMULATOR_PRECISION;

    // it should account for the decay at each global checkpoint
    // it should claim the rewards over the full range
    // @dev A small decaying share against a large supply can floor the reward to zero, which emits no event
    if (_reward0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    }
    if (_reward1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);
    }

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _accrued0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _accrued1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheStakeExpiresWithinTheRange() {
    _;
  }

  function test_WhenTheCappedRewardIsKnown()
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
    whenTheStakeIsDecaying
    whenTheStakeIsActiveAtTheRangeStart
    whenTheStakeExpiresWithinTheRange
  {
    // @dev Decaying stake A locks 1000 TOKEN until epoch 4, so it is active for the two credits then expired by the claim
    //      slope = 1000 * TOKEN_1 / MAX_TIME (floored), bias = slope * (stakeEnd - ts)
    //      _vp2 = slope * 2 weeks at the first credit, _vp3 = slope * 1 week at the second credit, zero from epoch 4 onward
    uint128 _allocatedA = uint128(1000 * TOKEN_1);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(4 weeks));
    uint256 _vp2 = 9_589_041_095_890_233_600;
    uint256 _vp3 = 4_794_520_547_945_116_800;

    // @dev Permanent stake B holds 3 million TOKEN so rounding can leave buffered fees
    //      _supply2 = 3 million TOKEN + _vp2 = 3_000_009_589_041_095_890_233_600
    //      _supply3 = 3 million TOKEN + _vp3 = 3_000_004_794_520_547_945_116_800
    uint128 _weightB = uint128(3_000_000 * TOKEN_1);

    // @dev Two fees land while the stake is active then a third lands strictly after expiry where the weight is zero
    _credited0 = 8000 * TOKEN_1;
    _credited1 = 12_000 * TOKEN_1;
    _accrued0 = 4000 * TOKEN_1;
    _accrued1 = 6000 * TOKEN_1;
    _expired0 = 2000 * TOKEN_1;
    _expired1 = 3000 * TOKEN_1;

    // @dev Record the decaying stake and the permanent stake in the same epoch
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocatedA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The decaying weight is _vp2 at the first credit and _vp3 at the second then zero once the stake expires at epoch 4
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 2 weeks), _vp2);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 3 weeks), _vp3);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 5 weeks), 0);

    // @dev Credit the first fee against the higher decaying weight at epoch 2
    _advanceWithPendingFeesAt(2 weeks, _credited0, _credited1);

    // @dev Credit the second fee against the lower decaying weight at epoch 3
    _advanceWithPendingFeesAt(3 weeks, _credited0 + _accrued0, _credited1 + _accrued1);

    // @dev The claim collects the expired fee at epoch 5 where the weight is zero, so the cap must drop it
    _mockGaugeCollectFeesAt(5 weeks, _credited0 + _accrued0 + _expired0, _credited1 + _accrued1 + _expired1);

    // @dev The second credit includes the rounding remainder retained from the first accumulator increase
    //      reward0 = (_vp2 * (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply2) + _vp3 * ((_accrued0 + 1) * FEE_ACCUMULATOR_PRECISION / _supply3)) / FEE_ACCUMULATOR_PRECISION
    //      reward1 = (_vp2 * (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply2) + _vp3 * ((_accrued1 + 2) * FEE_ACCUMULATOR_PRECISION / _supply3)) / FEE_ACCUMULATOR_PRECISION
    //      the epoch 5 credit lands past expiry so it is never weighted into the reward
    uint256 _reward0 = 31_963_378_370_202_547;
    uint256 _reward1 = 47_945_067_555_303_821;

    // it should account for the decay at each global checkpoint
    // it should claim up to the global checkpoint before the expiry
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder including the full expired credit stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _accrued0 + _expired0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _accrued1 + _expired1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  function test_WhenTheCappedRewardVaries(
    uint256 _slope,
    uint128 _weightB,
    uint256 _credited0_,
    uint256 _credited1_,
    uint256 _accrued0_,
    uint256 _accrued1_,
    uint256 _expired0_,
    uint256 _expired1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAtTheUserCheckpoint
    whenTheStakeHasVotingPowerInEveryUserCheckpoint
    whenTheStakeIsDecaying
    whenTheStakeIsActiveAtTheRangeStart
    whenTheStakeExpiresWithinTheRange
  {
    _slope = bound(_slope, 1, 1_000_000 * TOKEN_1 / MAX_TIME);
    // @dev The permanent co-staker must exceed FEE_ACCUMULATOR_PRECISION for rounding to leave buffered fees
    _weightB = uint128(bound(_weightB, FEE_ACCUMULATOR_PRECISION + 1, 1_000_000_000 * TOKEN_1));

    // @dev The lock ends at week 4 so the weight is active for the first two credits and gone by the claim
    uint48 _stakeEnd = uint48(4 weeks);
    uint128 _allocatedA = uint128(_slope * MAX_TIME);

    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocatedA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The first two credits land against the live decaying weight and the expired credit lands after it is gone
    uint256 _supply2 = _weightB + _slope * (_stakeEnd - 2 weeks);
    uint256 _supply3 = _weightB + _slope * (_stakeEnd - 3 weeks);
    _credited0 = _boundFeeToCredit(_credited0_, _supply2);
    _credited1 = _boundFeeToCredit(_credited1_, _supply2);
    _accrued0 = _boundFeeToCredit(_accrued0_, _supply3);
    _accrued1 = _boundFeeToCredit(_accrued1_, _supply3);
    _expired0 = _boundFeeToCredit(_expired0_, _weightB);
    _expired1 = _boundFeeToCredit(_expired1_, _weightB);

    // @dev Advance the global history, crediting the two active fees while the weight decays
    _advanceWithPendingFeesAt(2 weeks, _credited0, _credited1);

    _advanceWithPendingFeesAt(3 weeks, _credited0 + _accrued0, _credited1 + _accrued1);

    // @dev The claim collects the expired fee at week 4 where the weight has decayed to zero
    _mockGaugeCollectFeesAt(4 weeks, _credited0 + _accrued0 + _expired0, _credited1 + _accrued1 + _expired1);

    // @dev The reward covers only the two pre expiry credits and never the expired one at week 4
    uint256 _vp2 = _slope * (_stakeEnd - 2 weeks);
    uint256 _vp3 = _slope * (_stakeEnd - 3 weeks);
    uint256 _reward0 =
      (_vp2
          * (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply2)
          + _vp3
          * ((_accrued0 + _computeRoundingRemainder(_credited0, _supply2)) * FEE_ACCUMULATOR_PRECISION / _supply3))
        / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 =
      (_vp2
          * (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply2)
          + _vp3
          * ((_accrued1 + _computeRoundingRemainder(_credited1, _supply2)) * FEE_ACCUMULATOR_PRECISION / _supply3))
        / FEE_ACCUMULATOR_PRECISION;

    // it should account for the decay at each global checkpoint
    // it should claim up to the global checkpoint before the expiry
    // @dev A small decaying share against a large supply can floor the reward to zero, which emits no event
    if (_reward0 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    }
    if (_reward1 > 0) {
      _expectEmit(address(votingRewardsManager));
      emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);
    }

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The unclaimed remainder including the expired credit stays in the contract for the permanent stake
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _credited0 + _accrued0 + _expired0 - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _credited1 + _accrued1 + _expired1 - _reward1);

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheRangeStartsAfterTheUserCheckpoint() {
    _;
  }

  function test_WhenTheResumedStakeRewardIsKnown()
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAfterTheUserCheckpoint
  {
    // @dev A single decaying user checkpoint with a permanent supporting stake, resumed across intermediate checkpoints
    uint128 _weightA = uint128(1000 * TOKEN_1);
    uint128 _weightB = uint128(1000 * TOKEN_1);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(1 weeks + MAX_TIME));
    _credited0 = 8000 * TOKEN_1;
    _credited1 = 12_000 * TOKEN_1;
    // @dev The resumed range carries a credit at week three and a smaller one at week five
    _accrued0 = 4000 * TOKEN_1;
    _accrued1 = 6000 * TOKEN_1;
    uint256 _laterAccrued0 = 2000 * TOKEN_1;
    uint256 _laterAccrued1 = 3000 * TOKEN_1;

    // @dev The weight is the slope times the weeks remaining to the stake end so it falls one slope week each epoch
    //      slope   = 1000e18 / MAX_TIME floored = 7_927_447_995_941
    //      vpWeek2 = slope * 207 weeks          = 992_465_753_424_639_177_600
    //      vpWeek3 = slope * 206 weeks          = 987_671_232_876_694_060_800
    //      vpWeek5 = slope * 204 weeks          = 978_082_191_780_803_827_200
    uint256 _vpWeek2 = 992_465_753_424_639_177_600;
    uint256 _vpWeek3 = 987_671_232_876_694_060_800;
    uint256 _vpWeek5 = 978_082_191_780_803_827_200;

    // @dev Record one decaying user checkpoint against a permanent supporting stake
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The historical balance confirms the single checkpoint keeps decaying across the credited weeks
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 2 weeks), _vpWeek2);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 3 weeks), _vpWeek3);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 5 weeks), _vpWeek5);
    assertGt(_vpWeek2, _vpWeek3);
    assertGt(_vpWeek3, _vpWeek5);

    // @dev The increased precision leaves no whole fee unit buffered at this supply
    //      inc0(week2) = floor(8000e18 * 1e24 / (vpWeek2 + 1000e18)) = 4_015_125_472_671_057_960_876_354
    //      inc1(week2) = floor(12000e18 * 1e24 / (vpWeek2 + 1000e18)) = 6_022_688_209_006_586_941_314_532
    //      inc0(week3) = floor(4000e18 * 1e24 / (vpWeek3 + 1000e18)) = 2_012_405_237_767_075_697_218_116
    //      inc1(week3) = floor(6000e18 * 1e24 / (vpWeek3 + 1000e18)) = 3_018_607_856_650_613_545_827_174
    //      inc0(week5) = floor(2000e18 * 1e24 / (vpWeek5 + 1000e18)) = 1_011_080_332_409_981_546_033_563
    //      inc1(week5) = floor(3000e18 * 1e24 / (vpWeek5 + 1000e18)) = 1_516_620_498_614_972_319_050_344
    // @dev The first claim settles the week two credit at its decayed weight
    //      first  reward0 = floor(vpWeek2 * inc0(week2) / 1e24) = 3_984_874_527_328_942_039_123
    //      first  reward1 = floor(vpWeek2 * inc1(week2) / 1e24) = 5_977_311_790_993_413_058_685
    // @dev The resume sums the week three and week five credits in one division and ignores the stuffed checkpoints
    //      second reward0 = floor((vpWeek3 * inc0(week3) + vpWeek5 * inc0(week5)) / 1e24) = 2_976_514_429_822_942_756_748
    //      second reward1 = floor((vpWeek3 * inc1(week3) + vpWeek5 * inc1(week5)) / 1e24) = 4_464_771_644_734_414_135_122
    uint256 _reward0First = 3_984_874_527_328_942_039_123;
    uint256 _reward0Second = 2_976_514_429_822_942_756_748;
    uint256 _reward1First = 5_977_311_790_993_413_058_685;
    uint256 _reward1Second = 4_464_771_644_734_414_135_122;

    // @dev The first claim collects the credited fee and caches the latest global checkpoint as the resume point
    _mockGaugeCollectFeesAt(2 weeks, _credited0, _credited1);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0First);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1First);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0First);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1First);

    // @dev The first claim caches the resume point at the week two global checkpoint past the lone user checkpoint
    IVotingRewardsManager.ClaimState memory _cachedState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_cachedState.lastUserCp, 1);
    assertEq(_cachedState.lastGlobalCp, 2);
    assertEq(votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A), 1);

    // @dev Credit a fee at week three and week five, holding pending unchanged at week four and week six
    _advanceWithPendingFeesAt(3 weeks, _accrued0, _accrued1);
    _advanceWithPendingFeesAt(4 weeks, _accrued0, _accrued1);
    _advanceWithPendingFeesAt(5 weeks, _accrued0 + _laterAccrued0, _accrued1 + _laterAccrued1);
    _advanceWithPendingFeesAt(6 weeks, _accrued0 + _laterAccrued0, _accrued1 + _laterAccrued1);

    // it should resume from the cached global checkpoint
    // it should claim only the rewards accrued since the prior claim
    // it should account for the intermediate global checkpoints
    // @dev The resume opens at the cached checkpoint after the user checkpoint and settles both credits in one range
    _mockGaugeCollectFeesAt(7 weeks, _accrued0 + _laterAccrued0, _accrued1 + _laterAccrued1);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN0, _reward0Second);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN1, _reward1Second);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.bob, type(uint256).max);

    // @dev The resume pays only the accrued decayed share so the second recipient never receives the first credit
    assertEq(IERC20(_TOKEN0).balanceOf(users.bob), _reward0Second);
    assertEq(IERC20(_TOKEN1).balanceOf(users.bob), _reward1Second);

    // @dev The remainder from all three credits stays in the contract for the supporting stake
    assertEq(
      IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)),
      _credited0 + _accrued0 + _laterAccrued0 - _reward0First - _reward0Second
    );
    assertEq(
      IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)),
      _credited1 + _accrued1 + _laterAccrued1 - _reward1First - _reward1Second
    );

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  function test_WhenTheResumedStakeRewardVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _accrued0_,
    uint256 _accrued1_
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimReachesTheLatestUserCheckpoint
    whenTheRangeStartsAfterTheUserCheckpoint
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));

    uint256 _supply = uint256(_weightA) + _weightB;
    // @dev The first credit is fixed setup that clears the threshold to establish the resume point
    _credited0 = 500 * TOKEN_1;
    _credited1 = 1500 * TOKEN_1;
    // @dev Bound each accrued fee so the resumed claim pays the claimed stake at least one fee unit
    uint256 _minClaimableFees =
      _ceilDiv(_ceilDiv(FEE_ACCUMULATOR_PRECISION, _weightA) * _supply, FEE_ACCUMULATOR_PRECISION);
    _accrued0 = bound(_accrued0_, _minClaimableFees, 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1_, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev Two permanent stakes hold all the supply so the weight stays constant across both claims
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev The first claim collects the credited fee and caches the latest global checkpoint as the resume point
    _mockGaugeCollectFeesAt(2 weeks, _credited0, _credited1);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, type(uint256).max);

    // @dev The second claim resumes from the cached global checkpoint which sits after the user checkpoint
    _mockGaugeCollectFeesAt(3 weeks, _accrued0, _accrued1);
    // @dev Compute the rounding remainder retained after the first accumulator increase
    uint256 _buffered0 = _computeRoundingRemainder(_credited0, _supply);
    uint256 _buffered1 = _computeRoundingRemainder(_credited1, _supply);
    uint256 _reward0 =
      _weightA * ((_accrued0 + _buffered0) * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 =
      _weightA * ((_accrued1 + _buffered1) * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION;

    // it should resume from the cached global checkpoint
    // it should claim only the rewards accrued since the prior claim
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.bob, type(uint256).max);

    // @dev The resume pays only the accrued share so the second recipient never receives the first credited fee
    assertEq(IERC20(_TOKEN0).balanceOf(users.bob), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.bob), _reward1);

    // @dev The remainder from both credits stays in the contract for the permanent stake
    assertEq(
      IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)),
      _credited0 + _accrued0
        - (_weightA * (_credited0 * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION) - _reward0
    );
    assertEq(
      IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)),
      _credited1 + _accrued1
        - (_weightA * (_credited1 * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION) - _reward1
    );

    // it should set the last claimed user checkpoint to the latest user checkpoint
    // it should set the last claimed global checkpoint to the latest global checkpoint
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_claimState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());
  }

  modifier whenTheClaimDoesNotReachTheLatestUserCheckpoint() {
    _;
  }

  modifier whenItIsAFirstBoundedClaim() {
    _;
  }

  function test_WhenTheBoundedRewardIsKnown()
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimDoesNotReachTheLatestUserCheckpoint
    whenItIsAFirstBoundedClaim
  {
    // @dev A decaying stake claimed against a permanent supporting stake so each credit settles a decayed share
    uint128 _weightA = uint128(1000 * TOKEN_1);
    uint128 _weightB = uint128(1000 * TOKEN_1);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(1 weeks + MAX_TIME));
    _credited0 = 7000 * TOKEN_1;
    _credited1 = 12_000 * TOKEN_1;

    // @dev The weight is the slope times the weeks remaining to the stake end so it falls one slope week each epoch
    //      slope   = 1000e18 / MAX_TIME floored = 7_927_447_995_941
    //      vpWeek2 = slope * 207 weeks          = 992_465_753_424_639_177_600
    //      vpWeek3 = slope * 206 weeks          = 987_671_232_876_694_060_800
    //      vpWeek4 = slope * 205 weeks          = 982_876_712_328_748_944_000
    uint256 _vpWeek2 = 992_465_753_424_639_177_600;
    uint256 _vpWeek3 = 987_671_232_876_694_060_800;
    uint256 _vpWeek4 = 982_876_712_328_748_944_000;

    // @dev Four user checkpoints close three ranges, recorded against the zero accumulator with the supporting stake
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Credit the first fee against the week two decayed weight then re checkpoint the decaying stake
    _checkpointWithPendingFeesAt(2 weeks, _TOKEN_ID_A, _credited0, _credited1, _weightA, _stakeEnd);

    // @dev Credit the second fee against the week three decayed weight then re checkpoint the decaying stake
    _checkpointWithPendingFeesAt(3 weeks, _TOKEN_ID_A, _credited0 * 2, _credited1 * 2, _weightA, _stakeEnd);

    // @dev Credit the third fee against the week four decayed weight then re checkpoint the decaying stake
    _checkpointWithPendingFeesAt(4 weeks, _TOKEN_ID_A, _credited0 * 3, _credited1 * 3, _weightA, _stakeEnd);

    // @dev The claim collects the cumulative fees and the bounded limit settles only the first two ranges
    _mockGaugeCollectFeesAt(5 weeks, _credited0 * 3, _credited1 * 3);

    // @dev The historical balance confirms the weight keeps decaying across the three credited weeks
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 2 weeks), _vpWeek2);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 3 weeks), _vpWeek3);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, 4 weeks), _vpWeek4);
    assertGt(_vpWeek2, _vpWeek3);
    assertGt(_vpWeek3, _vpWeek4);

    // @dev The increased precision leaves no whole fee unit buffered at this supply
    //      inc0(week2) = floor(7000e18 * 1e24 / (vpWeek2 + 1000e18)) = 3_513_234_788_587_175_715_766_810
    //      inc0(week3) = floor(7000e18 * 1e24 / (vpWeek3 + 1000e18)) = 3_521_709_166_092_382_470_131_704
    //      inc0(week4) = floor(7000e18 * 1e24 / (vpWeek4 + 1000e18)) = 3_530_224_525_043_210_258_505_039
    //      inc1(week2) = floor(12000e18 * 1e24 / (vpWeek2 + 1000e18)) = 6_022_688_209_006_586_941_314_532
    //      inc1(week3) = floor(12000e18 * 1e24 / (vpWeek3 + 1000e18)) = 6_037_215_713_301_227_091_654_349
    //      inc1(week4) = floor(12000e18 * 1e24 / (vpWeek4 + 1000e18)) = 6_051_813_471_502_646_157_437_210
    // @dev The bounded claim sums the week two and week three numerators before the final division
    //      reward0 first = floor((vpWeek2 * inc0(week2) + vpWeek3 * inc0(week3)) / 1e24) = 6_965_056_045_320_441_814_101
    //      reward1 first = floor((vpWeek2 * inc1(week2) + vpWeek3 * inc1(week3)) / 1e24) = 11_940_096_077_692_185_967_031
    // @dev The follow up claim floors its single remaining week four range
    //      reward0 week4 = floor(vpWeek4 * inc0(week4) / 1e24) = 3_469_775_474_956_789_741_494
    //      reward1 week4 = floor(vpWeek4 * inc1(week4) / 1e24) = 5_948_186_528_497_353_842_562
    uint256 _reward0First = 6_965_056_045_320_441_814_101;
    uint256 _reward0Second = 3_469_775_474_956_789_741_494;
    uint256 _reward1First = 11_940_096_077_692_185_967_031;
    uint256 _reward1Second = 5_948_186_528_497_353_842_562;

    // it should claim rewards only up to the bounded user checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0First);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1First);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, 2);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0First);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1First);

    // it should set the last claimed user checkpoint to the bounded range end
    // it should set the last claimed global checkpoint to the bounded range end
    // @dev The bounded claim stops one checkpoint past its two settled ranges
    IVotingRewardsManager.ClaimState memory _boundedState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_boundedState.lastUserCp, 3);
    assertEq(_boundedState.lastGlobalCp, 3);

    // it should settle the remaining range on a later claim
    // @dev The gauge is already drained so the follow up claim collects nothing and resumes the decaying math
    _mockGaugeCollectFeesAt(block.timestamp, 0, 0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN0, _reward0Second);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN1, _reward1Second);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.bob, type(uint256).max);

    assertEq(IERC20(_TOKEN0).balanceOf(users.bob), _reward0Second);
    assertEq(IERC20(_TOKEN1).balanceOf(users.bob), _reward1Second);

    // @dev The decaying stake has claimed its full share, leaving the remainder for the permanent co staker
    uint256 _remainder0 = _credited0 * 3 - _reward0First - _reward0Second;
    uint256 _remainder1 = _credited1 * 3 - _reward1First - _reward1Second;
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _remainder0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _remainder1);

    // @dev The finishing claim reaches the latest user and global checkpoints
    IVotingRewardsManager.ClaimState memory _finalState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_finalState.lastUserCp, votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A));
    assertEq(_finalState.lastGlobalCp, votingRewardsManager.globalCheckpointIndex());

    // @dev The permanent stake sweeps the remainder, leaving only the increment flooring dust
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_B, users.charlie, type(uint256).max);
    assertApproxEqAbs(IERC20(_TOKEN0).balanceOf(users.charlie), _remainder0, 1e4);
    assertApproxEqAbs(IERC20(_TOKEN1).balanceOf(users.charlie), _remainder1, 1e4);
  }

  function test_WhenTheBoundedRewardVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _numCheckpoints,
    uint256 _maxCheckpoints,
    uint256 _fee0,
    uint256 _fee1
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimDoesNotReachTheLatestUserCheckpoint
    whenItIsAFirstBoundedClaim
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev Fuzz at least three user checkpoints so the limit can stop strictly before the latest
    _numCheckpoints = bound(_numCheckpoints, 3, 10);
    // @dev Bound maxCheckpoints below the last range so the claim never reaches the latest user checkpoint
    _maxCheckpoints = bound(_maxCheckpoints, 1, _numCheckpoints - 2);

    uint256 _supply = uint256(_weightA) + _weightB;
    // @dev Bound the per step fee to clear the accumulator threshold and pay the claimed stake at least one fee unit
    uint256 _minClaimableFees =
      _ceilDiv(_ceilDiv(FEE_ACCUMULATOR_PRECISION, _weightA) * _supply, FEE_ACCUMULATOR_PRECISION);
    _fee0 = bound(_fee0, _minClaimableFees, 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev Record one checkpoint per epoch so each step closes a range with one credit
    _recordMultipleCheckpoints(_numCheckpoints, _weightA, _weightB, _fee0, _fee1);

    // @dev The claim collects the cumulative fees but the limit settles only the first ranges
    _mockGaugeCollectFeesAt(
      (_numCheckpoints + 1) * 1 weeks, _fee0 * (_numCheckpoints - 1), _fee1 * (_numCheckpoints - 1)
    );

    // @dev The bounded claim earns the carried increments in its settled ranges and never the later credits
    uint256 _reward0 =
      _weightA * _computeCumulativeFeeIncrement(_fee0, _supply, _maxCheckpoints) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 =
      _weightA * _computeCumulativeFeeIncrement(_fee1, _supply, _maxCheckpoints) / FEE_ACCUMULATOR_PRECISION;

    // it should claim rewards only up to the bounded user checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.alice, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, _maxCheckpoints);

    assertEq(IERC20(_TOKEN0).balanceOf(users.alice), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.alice), _reward1);

    // @dev The later credits stay in the contract for the unsettled ranges
    assertEq(IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)), _fee0 * (_numCheckpoints - 1) - _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)), _fee1 * (_numCheckpoints - 1) - _reward1);

    // it should set the last claimed user checkpoint to the bounded range end
    // it should set the last claimed global checkpoint to the bounded range end
    // @dev Each step advances the user and global checkpoints together so the range end is maxCheckpoints plus one
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, _maxCheckpoints + 1);
    assertEq(_claimState.lastGlobalCp, _maxCheckpoints + 1);
  }

  function test_WhenItResumesAPriorBoundedClaim(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _numCheckpoints,
    uint256 _firstClaimMax,
    uint256 _secondClaimMax,
    uint256 _fee0,
    uint256 _fee1
  )
    external
    whenThereAreUserCheckpointsToProcess
    whenTheCheckpointLimitIsNotZero
    whenThereAreNewGlobalCheckpointsToClaim
    whenTheStakeHasVotingPowerInAtLeastOneCheckpoint
    whenTheClaimDoesNotReachTheLatestUserCheckpoint
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));
    // @dev Fuzz at least four user checkpoints so two bounded claims can both stop before the latest
    _numCheckpoints = bound(_numCheckpoints, 4, 10);
    // @dev Set the maximum number of user checkpoints each claim can process
    //      Both claims process at least one checkpoint and together leave at least one for a later claim
    _firstClaimMax = bound(_firstClaimMax, 1, _numCheckpoints - 3);
    _secondClaimMax = bound(_secondClaimMax, 1, _numCheckpoints - 2 - _firstClaimMax);

    uint256 _supply = uint256(_weightA) + _weightB;
    // @dev Bound the per step fee to clear the accumulator threshold and pay the claimed stake at least one fee unit
    uint256 _minClaimableFees =
      _ceilDiv(_ceilDiv(FEE_ACCUMULATOR_PRECISION, _weightA) * _supply, FEE_ACCUMULATOR_PRECISION);
    _fee0 = bound(_fee0, _minClaimableFees, 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _minClaimableFees, 1_000_000 * TOKEN_1);

    // @dev Record one checkpoint per epoch so each step closes a range with one credit
    _recordMultipleCheckpoints(_numCheckpoints, _weightA, _weightB, _fee0, _fee1);

    // @dev The first bounded claim collects the cumulative fees and caches where it stopped
    _mockGaugeCollectFeesAt(
      (_numCheckpoints + 1) * 1 weeks, _fee0 * (_numCheckpoints - 1), _fee1 * (_numCheckpoints - 1)
    );
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.alice, _firstClaimMax);

    // @dev The first claim stops one step past its limit which is where the resume must continue from
    IVotingRewardsManager.ClaimState memory _cachedState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_cachedState.lastUserCp, _firstClaimMax + 1);
    assertEq(_cachedState.lastGlobalCp, _firstClaimMax + 1);

    // @dev Calculate what the stake earned from the end of the first claim through the end of the second claim
    uint256 _reward0 = _weightA
      * (_computeCumulativeFeeIncrement(_fee0, _supply, _firstClaimMax + _secondClaimMax)
        - _computeCumulativeFeeIncrement(_fee0, _supply, _firstClaimMax)) / FEE_ACCUMULATOR_PRECISION;
    uint256 _reward1 = _weightA
      * (_computeCumulativeFeeIncrement(_fee1, _supply, _firstClaimMax + _secondClaimMax)
        - _computeCumulativeFeeIncrement(_fee1, _supply, _firstClaimMax)) / FEE_ACCUMULATOR_PRECISION;

    // it should continue from the cached user and global checkpoints
    // it should claim rewards only up to the bounded user checkpoint
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN0, _reward0);
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimFees(_TOKEN_ID_A, users.bob, _TOKEN1, _reward1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_A, users.bob, _secondClaimMax);

    // @dev The resume pays only its own ranges so the second recipient never receives the first claim's rewards
    assertEq(IERC20(_TOKEN0).balanceOf(users.bob), _reward0);
    assertEq(IERC20(_TOKEN1).balanceOf(users.bob), _reward1);

    // @dev The unsettled ranges stay in the contract after both bounded claims
    assertEq(
      IERC20(_TOKEN0).balanceOf(address(votingRewardsManager)),
      _fee0 * (_numCheckpoints - 1) - IERC20(_TOKEN0).balanceOf(users.alice) - _reward0
    );
    assertEq(
      IERC20(_TOKEN1).balanceOf(address(votingRewardsManager)),
      _fee1 * (_numCheckpoints - 1) - IERC20(_TOKEN1).balanceOf(users.alice) - _reward1
    );

    // it should set the last claimed user checkpoint to the bounded range end
    // it should set the last claimed global checkpoint to the bounded range end
    // @dev Each step advances the user and global checkpoints together so the range end is the settled count plus one
    IVotingRewardsManager.ClaimState memory _claimState = votingRewardsManager.feeClaimState(_TOKEN_ID_A);
    assertEq(_claimState.lastUserCp, _firstClaimMax + _secondClaimMax + 1);
    assertEq(_claimState.lastGlobalCp, _firstClaimMax + _secondClaimMax + 1);
  }

  /**
   * @notice Simulate one checkpoint per epoch for the staker with one fee credit per step
   * @dev Records both stakes in week 1, then checkpoints the staker up to `_count` crediting one fee per step
   * @param _count The total number of user checkpoints to record for the staker
   * @param _weightA The permanent weight of the staker
   * @param _weightB The permanent weight of the supporting stake
   * @param _fee0 The token0 fee credited at each step
   * @param _fee1 The token1 fee credited at each step
   */
  function _recordMultipleCheckpoints(
    uint256 _count,
    uint128 _weightA,
    uint128 _weightB,
    uint256 _fee0,
    uint256 _fee1
  ) internal {
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    for (uint256 _i = 2; _i <= _count; _i++) {
      _checkpointWithPendingFeesAt(_i * 1 weeks, _TOKEN_ID_A, _fee0 * (_i - 1), _fee1 * (_i - 1), _weightA, 0);
    }
  }

  /**
   * @notice Credit pending fees, then checkpoint a veNFT allocation at the same timestamp
   * @param _timestamp Timestamp to warp to
   * @param _tokenId The veNFT token ID to checkpoint
   * @param _pending0 Pending token0 fees reported by the gauge
   * @param _pending1 Pending token1 fees reported by the gauge
   * @param _allocated Allocation to checkpoint
   * @param _stakeEnd Stake end for non-permanent allocations, or zero for permanent
   */
  function _checkpointWithPendingFeesAt(
    uint256 _timestamp,
    uint256 _tokenId,
    uint256 _pending0,
    uint256 _pending1,
    uint128 _allocated,
    uint48 _stakeEnd
  ) internal {
    vm.warp(_timestamp);
    _mockGaugePendingFees(_pending0, _pending1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _tokenId, _allocated: _allocated, _stakeEnd: _stakeEnd, _data: ''});
  }

  /**
   * @notice Advance global points at a timestamp with the given pending gauge fees
   * @param _timestamp Timestamp to warp to
   * @param _pending0 Pending token0 fees reported by the gauge
   * @param _pending1 Pending token1 fees reported by the gauge
   */
  function _advanceWithPendingFeesAt(uint256 _timestamp, uint256 _pending0, uint256 _pending1) internal {
    vm.warp(_timestamp);
    _mockGaugePendingFees(_pending0, _pending1);
    votingRewardsManager.advanceGlobalPoints();
  }

  /**
   * @notice Compute the fee remainder retained after an accumulator increase
   * @param _fees Fee amount available for the accumulator increase
   * @param _supply Voting supply used by the accumulator
   * @return _remainingBufferedFees Fee amount not included in the rounded-up notification
   */
  function _computeRoundingRemainder(
    uint256 _fees,
    uint256 _supply
  ) internal pure returns (uint256 _remainingBufferedFees) {
    uint256 _increment = _fees * FEE_ACCUMULATOR_PRECISION / _supply;
    uint256 _notifiedFees = _ceilDiv(_increment * _supply, FEE_ACCUMULATOR_PRECISION);
    _remainingBufferedFees = _fees - _notifiedFees;
  }

  /**
   * @notice Compute the cumulative accumulator increase for repeated fee credits
   * @param _fee Fee amount added by each credit
   * @param _supply Voting supply used by every accumulator increase
   * @param _count Number of fee credits to include
   * @return _cumulativeIncrement Sum of the accumulator increases including carried rounding remainders
   */
  function _computeCumulativeFeeIncrement(
    uint256 _fee,
    uint256 _supply,
    uint256 _count
  ) internal pure returns (uint256 _cumulativeIncrement) {
    uint256 _buffered;
    for (uint256 _i; _i < _count; _i++) {
      uint256 _fees = _fee + _buffered;
      _cumulativeIncrement += _fees * FEE_ACCUMULATOR_PRECISION / _supply;
      _buffered = _computeRoundingRemainder(_fees, _supply);
    }
  }

  /**
   * @notice Bound a fee amount so it clears the accumulator credit threshold for a given supply
   * @param _fee Fee amount to bound
   * @param _supply Voting supply used by the accumulator
   * @return Fee amount large enough to credit rather than buffer
   */
  function _boundFeeToCredit(uint256 _fee, uint256 _supply) internal pure returns (uint256) {
    return bound(_fee, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
  }

  /**
   * @notice Mock a call to `IGauge.collectFees()` and deliver the reported fees to the manager
   * @param _timestamp Timestamp to warp to before collecting
   * @param _amount0 Collected token0 fees
   * @param _amount1 Collected token1 fees
   */
  function _mockGaugeCollectFeesAt(uint256 _timestamp, uint256 _amount0, uint256 _amount1) internal {
    vm.warp(_timestamp);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_amount0, _amount1));
    TestERC20(_TOKEN0).mint(address(votingRewardsManager), _amount0);
    TestERC20(_TOKEN1).mint(address(votingRewardsManager), _amount1);
  }
}
