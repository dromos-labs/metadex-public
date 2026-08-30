// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerEarnedFees is UnitVotingRewardsManager {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();
    // @dev Deploy real ERC20 code at the fee token addresses for claim-driven buffer setup
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 0', 'FEE0', uint8(18)), _TOKEN0);
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 1', 'FEE1', uint8(18)), _TOKEN1);
  }

  function test_WhenTheEstimateDoesNotReachTheLatestCheckpoint(
    uint128 _weight,
    uint256 _fee0,
    uint256 _fee1,
    uint256 _accrued0,
    uint256 _accrued1
  ) external {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    _fee0 = bound(_fee0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0, TOKEN_1, 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1, TOKEN_1, 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, then credit fees on a second checkpoint, leaving the stake owed a settled reward
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge accrued more fees since the credit, so any added estimate would lift the result above the settled reward
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_fee0 + _accrued0, _fee1 + _accrued1));

    // @dev Two user checkpoints reach the end at a limit of two, so a limit of one stops short of the latest
    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, 1);

    // it should return only the settled rewards
    // @dev The sole staker is owed every credited fee, save for accumulator rounding dust, and no pending estimate
    assertApproxEqAbs(_earned0, _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(_earned1, _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertLe(_earned0, _fee0);
    assertLe(_earned1, _fee1);
  }

  modifier whenTheEstimateReachesTheLatestCheckpoint() {
    _;
  }

  function test_WhenTheStakeHasNoWeight(
    uint128 _weight,
    uint256 _fee0,
    uint256 _fee1,
    uint256 _accrued0,
    uint256 _accrued1
  ) external whenTheEstimateReachesTheLatestCheckpoint {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    _fee0 = bound(_fee0, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _fee1 = bound(_fee1, _ceilDiv(_weight, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _accrued0 = bound(_accrued0, TOKEN_1, 1_000_000 * TOKEN_1);
    _accrued1 = bound(_accrued1, TOKEN_1, 1_000_000 * TOKEN_1);

    // @dev Record a permanent stake, then credit fees on a second checkpoint, leaving the stake owed a settled reward
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Reset the allocation, dropping the current weight to zero while the earned reward remains owed
    vm.warp(3 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);

    // @dev Pending accrual would feed the estimate, but the zero current weight gates it before the gauge is read
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_fee0 + _accrued0, _fee1 + _accrued1));

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should return only the settled rewards
    assertApproxEqAbs(_earned0, _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(_earned1, _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertLe(_earned0, _fee0);
    assertLe(_earned1, _fee1);
  }

  modifier whenTheStakeHasWeight() {
    _;
  }

  modifier whenThereAreNoPendingFees() {
    _;
  }

  function test_WhenTheBufferIsEmpty(
    uint128 _weight,
    uint8 _multiplier0,
    uint8 _multiplier1
  ) external whenTheEstimateReachesTheLatestCheckpoint whenTheStakeHasWeight whenThereAreNoPendingFees {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));
    _multiplier0 = uint8(bound(_multiplier0, 1, type(uint8).max));
    _multiplier1 = uint8(bound(_multiplier1, 1, type(uint8).max));
    // @dev Make each fee amount a whole multiple of the supply so no fees remain after rounding
    uint256 _fee0 = uint256(_weight) * _multiplier0;
    uint256 _fee1 = uint256(_weight) * _multiplier1;

    // @dev Record a permanent stake, then credit fees on a second checkpoint, leaving the stake owed a settled reward
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _mockGaugePendingFees(_fee0, _fee1);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The gauge reports no pending fees and the buffer is empty, so the estimate has nothing to add
    _mockGaugePendingFees(0, 0);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should return only the settled rewards
    assertApproxEqAbs(_earned0, _fee0, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertApproxEqAbs(_earned1, _fee1, _weight / FEE_ACCUMULATOR_PRECISION + 1);
    assertLe(_earned0, _fee0);
    assertLe(_earned1, _fee1);
  }

  modifier whenTheBufferIsNotEmpty() {
    _;
  }

  function test_WhenTheGaugeIsNotActive()
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereAreNoPendingFees
    whenTheBufferIsNotEmpty
  {
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _settled0 = 8000 * TOKEN_1;
    uint256 _settled1 = 4000 * TOKEN_1;
    uint256 _buffered0 = 2000 * TOKEN_1;
    uint256 _buffered1 = 1000 * TOKEN_1;

    // @dev Record a permanent stake so the settling credit is owed to the staker
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev Settle fees into the accumulator, then flush the same timestamp collection with an extra buffered delta
    vm.warp(2 weeks);
    _mockGaugePendingFees(_settled0, _settled1);
    votingRewardsManager.advanceGlobalPoints();
    _mockGaugeCollectFees(_settled0 + _buffered0, _settled1 + _buffered1);
    // @dev Simulate gauge deactivation by flushing fees before later setting the emission cap to zero
    vm.prank(_GAUGE_FACTORY);
    votingRewardsManager.flushFees();

    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // @dev Suspend the gauge so the buffered fees are excluded from the view estimate
    _mockGaugePendingFees(0, 0);
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(uint128(0)));

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should return only the settled rewards
    assertEq(_earned0, _settled0);
    assertEq(_earned1, _settled1);
  }

  modifier whenTheGaugeIsActive() {
    _;
  }

  function test_WhenTheActiveBufferEstimateIsKnown()
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereAreNoPendingFees
    whenTheBufferIsNotEmpty
    whenTheGaugeIsActive
  {
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint256 _settled0 = 8000 * TOKEN_1;
    uint256 _settled1 = 4000 * TOKEN_1;
    uint256 _buffered0 = 2000 * TOKEN_1;
    uint256 _buffered1 = 1000 * TOKEN_1;

    // @dev Record equal permanent stakes so A can keep earned state while B creates the buffer
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Settle fees into the accumulator, then have B collect a same timestamp extra delta into the buffer
    vm.warp(2 weeks);
    _mockGaugePendingFees(_settled0, _settled1);
    votingRewardsManager.advanceGlobalPoints();
    _mockGaugeCollectFees(_settled0 + _buffered0, _settled1 + _buffered1);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_B, users.bob, type(uint256).max);

    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // @dev Keep the gauge active so the buffered fees are included in the view estimate
    _mockGaugePendingFees(0, 0);
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the buffered fee estimate
    assertEq(_earned0, _settled0 / 2 + _buffered0 / 2);
    assertEq(_earned1, _settled1 / 2 + _buffered1 / 2);
  }

  function test_WhenTheActiveBufferEstimateVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _settled0,
    uint256 _settled1,
    uint256 _buffered0,
    uint256 _buffered1
  )
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereAreNoPendingFees
    whenTheBufferIsNotEmpty
    whenTheGaugeIsActive
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));
    uint256 _supply = uint256(_weightA) + _weightB;
    _settled0 = bound(_settled0, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _settled1 = bound(_settled1, _ceilDiv(_supply, FEE_ACCUMULATOR_PRECISION), 1_000_000 * TOKEN_1);
    _buffered0 = bound(_buffered0, _ceilDiv(_supply, _weightA), 1_000_000 * TOKEN_1);
    _buffered1 = bound(_buffered1, _ceilDiv(_supply, _weightA), 1_000_000 * TOKEN_1);

    // @dev Record two permanent stakes so B can create the buffer while A remains unclaimed
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    // @dev Settle the pending fees, then collect a same timestamp residual through B's claim
    vm.warp(2 weeks);
    _mockGaugePendingFees(_settled0, _settled1);
    votingRewardsManager.advanceGlobalPoints();
    _mockGaugeCollectFees(_settled0 + _buffered0, _settled1 + _buffered1);
    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_B, users.bob, type(uint256).max);

    // @dev Include the rounding remainder retained after the initial accumulator increase
    _buffered0 += _settled0
      - _ceilDiv((_settled0 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);
    _buffered1 += _settled1
      - _ceilDiv((_settled1 * FEE_ACCUMULATOR_PRECISION / _supply) * _supply, FEE_ACCUMULATOR_PRECISION);

    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);

    // @dev Keep the gauge active while it reports zero pending fees
    _mockGaugePendingFees(0, 0);
    vm.mockCall(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.emissionCap, (_GAUGE)), abi.encode(type(uint128).max));

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    uint256 _settledShare0 =
      uint256(_weightA) * (_settled0 * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION;
    uint256 _settledShare1 =
      uint256(_weightA) * (_settled1 * FEE_ACCUMULATOR_PRECISION / _supply) / FEE_ACCUMULATOR_PRECISION;
    uint256 _bufferedShare0 = uint256(_weightA) * _buffered0 / _supply;
    uint256 _bufferedShare1 = uint256(_weightA) * _buffered1 / _supply;

    // it should add the buffered fee estimate
    assertEq(_earned0, _settledShare0 + _bufferedShare0);
    assertEq(_earned1, _settledShare1 + _bufferedShare1);
  }

  modifier whenThereArePendingFees() {
    _;
  }

  function test_WhenTheTotalSupplyIsZero(uint128 _weight)
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
  {
    _weight = uint128(bound(_weight, TOKEN_1, 1_000_000 * TOKEN_1));

    // @dev Record a permanent stake so the user point keeps its weight
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // @dev The supply guard is defensive so a zero supply under a positive weight is only reachable by writing storage
    stdstore.target(address(votingRewardsManager)).sig('globalCheckpointIndex()').checked_write(uint256(0));
    assertGt(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.totalSupply(), 0);

    // @dev Pending fees are nonzero, so a zero result proves the zero-supply guard skipped the estimate
    _mockGaugePendingFees(8000 * TOKEN_1, 4000 * TOKEN_1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should return only the settled rewards
    assertEq(_earned0, 0);
    assertEq(_earned1, 0);
  }

  modifier whenTheTotalSupplyIsNotZero() {
    _;
  }

  modifier whenTheStakeWeightIsPermanent() {
    _;
  }

  function test_WhenTheFullWeightEstimateVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _pending0,
    uint256 _pending1
  )
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
    whenTheTotalSupplyIsNotZero
    whenTheStakeWeightIsPermanent
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));
    _pending0 = bound(_pending0, TOKEN_1, 1_000_000 * TOKEN_1);
    _pending1 = bound(_pending1, TOKEN_1, 1_000_000 * TOKEN_1);

    // @dev A permanent stake shares the supply so the weight term does not cancel out
    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    _mockGaugePendingFees(_pending0, _pending1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the pending fee estimate using the full weight
    // @dev The permanent stake holds its full allocation so the estimate is that weight's share of the pending fees
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightA);
    uint256 _supply = uint256(_weightA) + _weightB;
    assertEq(_earned0, uint256(_weightA) * _pending0 / _supply);
    assertEq(_earned1, uint256(_weightA) * _pending1 / _supply);
  }

  function test_WhenTheFullWeightEstimateIsKnown()
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
    whenTheTotalSupplyIsNotZero
    whenTheStakeWeightIsPermanent
  {
    // @dev The stake holds a quarter of the supply, so it earns a quarter of the pending fees
    uint128 _weightA = uint128(1000 * TOKEN_1);
    uint128 _weightB = uint128(3000 * TOKEN_1);
    // @dev Each pending amount carries one spare wei, a quarter of which is too small to credit and rounds away
    uint256 _pending0 = 8000 * TOKEN_1 + 1;
    uint256 _pending1 = 4000 * TOKEN_1 + 1;

    vm.warp(1 weeks);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    _mockGaugePendingFees(_pending0, _pending1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the pending fee estimate using the full weight
    // @dev estimate = weightA * pending / supply = 1000 * pending / 4000, the trailing wei rounding away
    assertEq(_earned0, 2000 * TOKEN_1);
    assertEq(_earned1, 1000 * TOKEN_1);
  }

  function test_WhenTheBufferedAndSettledAmountsAreKnown()
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
    whenTheTotalSupplyIsNotZero
    whenTheStakeWeightIsPermanent
  {
    // @dev Both weights exceed FEE_ACCUMULATOR_PRECISION so buffered fees can produce a nonzero estimate
    uint128 _weightA = uint128(2_000_000 * TOKEN_1);
    uint128 _weightB = uint128(2_000_000 * TOKEN_1);

    // @dev A first credit clears the threshold and settles, a sub threshold delta then buffers, then new fees accrue
    uint256 _settled0 = 12_000 * TOKEN_1;
    uint256 _settled1 = 12_000 * TOKEN_1;
    uint256 _buffered0 = 3;
    uint256 _buffered1 = 2;
    uint256 _newlyPending0 = 8000 * TOKEN_1;
    uint256 _newlyPending1 = 4000 * TOKEN_1;

    // @dev Record the supporting stake first so the settling credit lands before the staker holds weight
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});

    // @dev The first advance settles the credit into lastPendingFees against the supporting stake alone
    vm.warp(2 weeks);
    _mockGaugePendingFees(_settled0, _settled1);
    votingRewardsManager.advanceGlobalPoints();

    // @dev The staker enters after the settling credit so its claim range never overlaps that credit
    vm.warp(3 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: 0, _data: ''});

    // @dev A sub threshold delta cannot credit so it advances lastPendingFees and rests in bufferedFees
    vm.warp(4 weeks);
    _mockGaugePendingFees(_settled0 + _buffered0, _settled1 + _buffered1);
    votingRewardsManager.advanceGlobalPoints();

    // @dev The settled watermark holds the first credit plus the buffered delta and bufferedFees holds the delta
    assertEq(votingRewardsManager.lastPendingFees0(), _settled0 + _buffered0);
    assertEq(votingRewardsManager.lastPendingFees1(), _settled1 + _buffered1);
    assertEq(votingRewardsManager.bufferedFees0(), _buffered0);
    assertEq(votingRewardsManager.bufferedFees1(), _buffered1);

    // @dev The query reports the settled watermark plus the buffered residual plus the newly pending fee
    vm.warp(5 weeks);
    _mockGaugePendingFees(_settled0 + _buffered0 + _newlyPending0, _settled1 + _buffered1 + _newlyPending1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the buffered and settled fees to the pending estimate
    // @dev The estimate nets out the settled watermark and keeps the buffered residual
    //      estimate = weightA * (pending - lastPendingFees + bufferedFees) / supply
    //      estimate = weightA * (newlyPending + buffered) / supply = (newlyPending + buffered) / 2
    //      estimate0 = (8000e18 + 3) / 2 = 4_000_000_000_000_000_000_001
    //      estimate1 = (4000e18 + 2) / 2 = 2_000_000_000_000_000_000_001
    // @dev The staker earns none of the settled credit since it held no weight when that credit landed
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weightA);
    assertEq(_earned0, 4_000_000_000_000_000_000_001);
    assertEq(_earned1, 2_000_000_000_000_000_000_001);
  }

  modifier whenTheStakeWeightIsDecaying() {
    _;
  }

  function test_WhenTheDecayedWeightEstimateVaries(
    uint128 _weightA,
    uint128 _weightB,
    uint256 _pending0,
    uint256 _pending1,
    uint48 _queryTs
  )
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
    whenTheTotalSupplyIsNotZero
    whenTheStakeWeightIsDecaying
  {
    _weightA = uint128(bound(_weightA, TOKEN_1, 1_000_000 * TOKEN_1));
    _weightB = uint128(bound(_weightB, TOKEN_1, 1_000_000 * TOKEN_1));
    _pending0 = bound(_pending0, TOKEN_1, 1_000_000 * TOKEN_1);
    _pending1 = bound(_pending1, TOKEN_1, 1_000_000 * TOKEN_1);

    uint48 _stakeTs = uint48(1 weeks);
    // @dev Align the stake end to an epoch boundary so its slope change lands where the supply walk applies it
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_stakeTs + MAX_TIME));
    // @dev Query before expiry so the stake still carries a decayed weight
    _queryTs = uint48(bound(_queryTs, _stakeTs + 1, _stakeEnd - 1));

    // @dev A permanent stake shares the supply so the weight term does not cancel out
    vm.warp(_stakeTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    vm.warp(_queryTs);
    _mockGaugePendingFees(_pending0, _pending1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the pending fee estimate using the decayed weight
    // @dev The weight has decayed below its allocation so the estimate is the decayed share of the pending fees
    uint256 _decayed = (uint256(_weightA) / MAX_TIME) * (_stakeEnd - _queryTs);
    uint256 _supply = uint256(_weightB) + _decayed;
    assertLt(_decayed, _weightA);
    assertEq(_earned0, _decayed * _pending0 / _supply);
    assertEq(_earned1, _decayed * _pending1 / _supply);
  }

  function test_WhenTheDecayedWeightEstimateIsKnown()
    external
    whenTheEstimateReachesTheLatestCheckpoint
    whenTheStakeHasWeight
    whenThereArePendingFees
    whenTheTotalSupplyIsNotZero
    whenTheStakeWeightIsDecaying
  {
    // @dev Both stakes lock the same 1000 token weight, but A decays while B stays permanent
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint48 _stakeTs = uint48(1 weeks);
    uint48 _queryTs = uint48(53 weeks);
    // @dev Align the stake end to an epoch boundary, 52 weeks past the query, so the remaining lock is exactly 52 weeks
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_queryTs + 52 weeks));
    // @dev slope = 1000 * TOKEN_1 / MAX_TIME (floored) = 7_927_447_995_941
    // @dev At the query the remaining lock is 52 weeks, so the decayed weight is slope * 52 weeks
    uint256 _decayed = 249_315_068_493_146_073_600;

    vm.warp(_stakeTs);
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weight, _stakeEnd: 0, _data: ''});
    vm.stopPrank();

    vm.warp(_queryTs);
    _mockGaugePendingFees(8000 * TOKEN_1, 4000 * TOKEN_1);

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_A, type(uint256).max);

    // it should add the pending fee estimate using the decayed weight
    // @dev A decayed to ~249 tokens against B's full 1000, so its share is decayed / (decayed + 1000 TOKEN_1)
    // @dev earned0 = decayed * 8000 TOKEN_1 / (decayed + 1000 TOKEN_1), earned1 = decayed * 4000 TOKEN_1 / (decayed + 1000 TOKEN_1)
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _queryTs), _decayed);
    assertLt(_decayed, _weight);
    assertEq(_earned0, 1_596_491_228_070_151_802_683);
    assertEq(_earned1, 798_245_614_035_075_901_341);
    // @dev Both earnings fall well below half of each pending amount because A decayed
    assertLt(_earned0, 4000 * TOKEN_1);
    assertLt(_earned1, 2000 * TOKEN_1);
  }

  function _mockGaugeCollectFees(uint256 _amount0, uint256 _amount1) internal {
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_amount0, _amount1));
    TestERC20(_TOKEN0).mint(address(votingRewardsManager), _amount0);
    TestERC20(_TOKEN1).mint(address(votingRewardsManager), _amount1);
  }
}
