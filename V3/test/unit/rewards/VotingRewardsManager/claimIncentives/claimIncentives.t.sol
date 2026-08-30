// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerClaimIncentives is UnitVotingRewardsManager {
  using stdStorage for StdStorage;

  // Programs use amount = N * duration so that rate = N*1e18 is exact (no rounding dust).
  uint256 internal constant _7D_AMOUNT = 604_800e18;
  uint48 internal constant _7D_DURATION = 7 days;
  uint256 internal constant _28D_AMOUNT = 2_419_200e18;
  uint48 internal constant _28D_DURATION = 28 days;

  // One full closed week of a 28d program (rate 1e36) at the rate above.
  uint256 internal constant _WEEK_STREAM = 604_800e18;
  // Largest amount createIncentiveProgram accepts before `_amount * 1e18` overflows.
  uint256 internal constant _MAX_INCENTIVE_AMOUNT = type(uint256).max / 1e18;
  // 1T AERO is the voting-power ceiling these overflow regressions should cover.
  uint128 internal constant _MAX_VOTING_POWER = 1_000_000_000_000e18;
  uint256 internal constant _ROUNDING_STRESS_VOTERS = 128;
  uint256 internal constant _ROUNDING_STRESS_TOKEN_ID_OFFSET = 10_000;

  address internal _recipient = makeAddr('recipient');
  address internal _operator = makeAddr('operator');
  address internal _creator = makeAddr('creator');
  address internal _sameTokenRecipientA1 = makeAddr('sameTokenRecipientA1');
  address internal _sameTokenRecipientA2 = makeAddr('sameTokenRecipientA2');
  address internal _sameTokenRecipientB1 = makeAddr('sameTokenRecipientB1');
  address internal _sameTokenRecipientB2 = makeAddr('sameTokenRecipientB2');

  TestERC20 internal _token;

  function setUp() public override {
    super.setUp();
    _token = new TestERC20('Incentive Token', 'INC', 18);
    vm.mockCall(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, 100_000_000e18);
    vm.prank(_creator);
    _token.approve(address(votingRewardsManager), type(uint256).max);
  }

  /// @dev Close the open interval by appending a global checkpoint at the current week boundary.
  function _advance() internal {
    vm.prank(_VOTER);
    votingRewardsManager.advanceGlobalPoints();
  }

  function _createProgram(uint48 _start, uint256 _amount, uint48 _duration) internal returns (uint256) {
    vm.prank(_creator);
    return votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
  }

  function _createWethProgram(
    VotingRewardsManager _manager,
    uint48 _start,
    uint256 _amount,
    uint48 _duration
  ) internal returns (uint256) {
    vm.mockCall(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_weth))), abi.encode(true));
    vm.deal(_creator, _amount);
    vm.startPrank(_creator);
    _weth.deposit{value: _amount}();
    _weth.approve(address(_manager), type(uint256).max);
    uint256 _programId =
      _manager.createIncentiveProgram({_token: address(_weth), _amount: _amount, _start: _start, _duration: _duration});
    vm.stopPrank();
    return _programId;
  }

  function _checkpoint(uint256 _tokenId, uint128 _allocated, uint48 _stakeEnd) internal {
    _checkpoint(votingRewardsManager, _tokenId, _allocated, _stakeEnd);
  }

  function _checkpoint(VotingRewardsManager _manager, uint256 _tokenId, uint128 _allocated, uint48 _stakeEnd) internal {
    vm.prank(_VOTER);
    _manager.checkpoint({_tokenId: _tokenId, _allocated: _allocated, _stakeEnd: _stakeEnd, _data: ''});
  }

  function _claimAll(uint256 _tokenId, address _claimRecipient, uint256 _programId) internal {
    votingRewardsManager.claimIncentives(_tokenId, _claimRecipient, _programId, type(uint256).max);
  }

  function _earnedAll(uint256 _tokenId, uint256 _programId) internal view returns (uint256) {
    return votingRewardsManager.earnedIncentives(_tokenId, _programId, type(uint256).max);
  }

  function _deployFeeTokens() internal {
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 0', 'FEE0', uint8(18)), _TOKEN0);
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 1', 'FEE1', uint8(18)), _TOKEN1);
  }

  function _setupSameTimestampCheckpointAfterStaleClaim()
    internal
    returns (uint256 _sameTimestampGlobalIndex, uint256 _feeAcc0, uint256 _feeAcc1, uint256 _claimTs)
  {
    uint128 _weight = 1000e18;
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    _checkpoint(_TOKEN_ID_A, _weight, 0);

    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    _claimTs = uint256(3 weeks) + 3 days;
    vm.warp(_claimTs);
    _mockGaugePendingFees(_pending0, _pending1);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    _sameTimestampGlobalIndex = votingRewardsManager.globalCheckpointIndex();
    _feeAcc0 = _pending0 * FEE_ACCUMULATOR_PRECISION / _weight;
    _feeAcc1 = _pending1 * FEE_ACCUMULATOR_PRECISION / _weight;

    _checkpoint(_TOKEN_ID_B, _weight, 0);

    uint256 _advanceTs = _claimTs + 1 weeks;
    vm.warp(_advanceTs);
    _advance();
  }

  function _claimFeesForArrivingAllocation(uint256 _pending0, uint256 _pending1) internal {
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_pending0, _pending1));
    TestERC20(_TOKEN0).mint(address(votingRewardsManager), _pending0);
    TestERC20(_TOKEN1).mint(address(votingRewardsManager), _pending1);

    vm.prank(_VOTER);
    votingRewardsManager.claimFees(_TOKEN_ID_B, _recipient, type(uint256).max);
  }

  function test_WhenTheRecipientIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IIncentiveStreaming.ZeroAddress.selector);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, address(0), 1, type(uint256).max);
  }

  function test_WhenTheCheckpointLimitIsZero() external {
    // it should revert with ZeroCheckpoints
    vm.expectRevert(IVotingRewardsManager.ZeroCheckpoints.selector);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, 1, 0);
  }

  function test_WhenTheCallerIsNeitherTheVoterNorTheVeNFTOperator(address _caller) external {
    // operator unset => only the voter is authorized; _assumeFuzzable excludes address(0), which
    // would match the unset operator
    vm.mockCall(_VOTER, abi.encodeCall(ILeafVoter.operator, (_TOKEN_ID_A)), abi.encode(address(0)));
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTER);

    // it should revert with NotAuthorized
    vm.expectRevert(IVotingRewardsManager.NotAuthorized.selector);
    vm.prank(_caller);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, 1, type(uint256).max);
  }

  function test_WhenTheProgramIdIsZero() external {
    // it should revert with InvalidProgramId
    vm.expectRevert(IIncentiveStreaming.InvalidProgramId.selector);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, 0, type(uint256).max);
  }

  function test_WhenTheProgramDoesNotExist() external {
    // it should revert with InvalidProgramId
    vm.expectRevert(IIncentiveStreaming.InvalidProgramId.selector);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, 1, type(uint256).max);
  }

  function test_WhenAClaimExceedsTheRemainingProgramBalance() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programIdA = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    uint256 _programIdB = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    uint256 _earned = votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programIdA, type(uint256).max);
    assertEq(_earned, _7D_AMOUNT);

    /// @dev Simulate program A being one wei short while program B's same-token deposit remains pooled
    uint256 _remaining = _earned - 1;
    stdstore.target(address(votingRewardsManager)).sig(votingRewardsManager.remainingAmount.selector)
      .with_key(_programIdA).checked_write(_remaining);
    _token.burn(address(votingRewardsManager), _earned - _remaining);
    assertEq(
      _token.balanceOf(address(votingRewardsManager)), _remaining + votingRewardsManager.remainingAmount(_programIdB)
    );

    // it should revert with InsufficientProgramBalance
    vm.expectRevert(IIncentiveStreaming.InsufficientProgramBalance.selector);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programIdA, type(uint256).max);
  }

  function test_WhenTheCallerIsTheVeNFTOperator() external {
    vm.mockCall(_VOTER, abi.encodeCall(ILeafVoter.operator, (_TOKEN_ID_A)), abi.encode(_operator));
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    // it should claim successfully: the operator closes the open interval and receives the full stream
    vm.prank(_operator);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);
  }

  function test_GivenTheProgramHasNotStarted(uint128 _allocated, uint48 _startOffset) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_VOTING_POWER));
    _startOffset = uint48(bound(_startOffset, 1, 52 weeks));
    vm.warp(1 weeks);
    _checkpoint(_TOKEN_ID_A, _allocated, 0);
    uint256 _programId = _createProgram(uint48(block.timestamp + _startOffset), _7D_AMOUNT, _7D_DURATION);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should transfer nothing
    assertEq(_token.balanceOf(_recipient), 0);
  }

  function test_GivenTheVeNFTNeverVoted(uint48 _duration) external {
    _duration = uint48(bound(_duration, 1 weeks, 4 weeks));
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    IVotingCheckpoints.GlobalPoint memory _initialPoint = votingRewardsManager.globalRewardPointHistory(_globalIndex);
    vm.warp(uint256(_start) + uint256(_duration) + 1);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should preserve the initial global checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndex);
    IVotingCheckpoints.GlobalPoint memory _pointAfterClaim = votingRewardsManager.globalRewardPointHistory(_globalIndex);
    _assertGlobalPoint({
      _expectedBias: _initialPoint.bias,
      _expectedSlope: _initialPoint.slope,
      _expectedPermanentLockBalance: _initialPoint.permanentStakeBalance,
      _expectedTs: _initialPoint.ts,
      _globalPoint: _pointAfterClaim
    });
    assertEq(_pointAfterClaim.zeroSupplySeconds, _initialPoint.zeroSupplySeconds);
    // it should transfer nothing
    assertEq(_token.balanceOf(_recipient), 0);
  }

  function test_GivenTheLatestCheckpointIsCurrent() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    // close two weeks: intervals [1w,2w] and [2w,3w]
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    // a fresh checkpoint at 3w + 30m closes [3w, 3w+30m] and is the latest checkpoint at the claim timestamp
    vm.warp(uint256(3 weeks) + 30 minutes);
    _checkpoint(_TOKEN_ID_A, 2e18, 0);

    uint256 _indexBefore = votingRewardsManager.globalCheckpointIndex();
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should pay only the closed intervals: two full weeks plus the 30-minute closed interval
    uint256 _claimedAmount = 2 * _WEEK_STREAM + uint256(30 minutes) * 1e18;
    assertEq(_token.balanceOf(_recipient), _claimedAmount);
    // it should reduce the remaining program balance by the claimed amount
    assertEq(votingRewardsManager.remainingAmount(_programId), _28D_AMOUNT - _claimedAmount);
    // it should not close the open interval: the latest checkpoint is current, so the index is untouched
    assertEq(votingRewardsManager.globalCheckpointIndex(), _indexBefore);
    // it should not revert (reached this line)
  }

  function test_GivenAStaleOpenInterval() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    // close two weeks; the latest global checkpoint is at 3w
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    // three days into the open interval, the latest checkpoint (3w) is stale
    vm.warp(uint256(3 weeks) + 3 days);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should close the open interval
    assertEq(votingRewardsManager.globalCheckpointIndex(), 4);
    // it should pay through the closed interval: two full weeks plus the three-day trailing period
    assertEq(_token.balanceOf(_recipient), 2 * _WEEK_STREAM + 259_200e18);
    // it should advance the global claim pointer to the tip
    assertEq(
      votingRewardsManager.incentiveClaimState(_TOKEN_ID_A, _programId).lastGlobalCp,
      votingRewardsManager.globalCheckpointIndex()
    );
  }

  function test_GivenAStaleOpenIntervalBeyondTheCheckpointIterationLimit() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint48 _duration = uint48((MAX_CHECKPOINT_ITERATIONS + 1) * 1 weeks);
    uint256 _programId = _createProgram(_start, _duration, _duration);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    /// @dev Make history exceed the single-advance limit by one second
    vm.warp(ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks + 1);

    // it should revert with StaleCheckpointHistory
    vm.expectRevert(IIncentiveStreaming.StaleCheckpointHistory.selector);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    /// @dev Advance stale history so the current timestamp falls within the iteration limit
    _advance();

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should claim the complete required interval after history is advanced
    assertEq(_token.balanceOf(_recipient), block.timestamp - _start);
  }

  function test_GivenAnEndedProgramWhoseEndIsReachableButTheCurrentTimestampIsNot() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    uint256 _partialFrontier = ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks;

    /// @dev End the program within the reachable history while leaving the current timestamp one second beyond it
    vm.warp(_partialFrontier + 1);

    /// @dev Revert any pending-fee query to prove closing the ended program does not read the gauge
    // it should not query the gauge for pending fees
    vm.clearMockedCalls();
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should advance global history through the program end
    assertEq(votingRewardsManager.globalRewardPointHistory(_globalIndex).ts, _partialFrontier);
    assertGe(_partialFrontier, uint256(_start) + _7D_DURATION);
    assertLt(_partialFrontier, block.timestamp);

    // it should preserve fee accounting
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastFeeUpdate(), _start);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
    _assertFeeSnapshot(_globalIndex, 0, 0, 0, 0);

    // it should claim the complete program reward
    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);
    assertEq(votingRewardsManager.remainingAmount(_programId), 0);
  }

  function test_GivenAStaleOpenIntervalAndASameTimestampCheckpointWithPendingFees() external {
    (uint256 _sameTimestampGlobalIndex, uint256 _feeAcc0, uint256 _feeAcc1, uint256 _claimTs) =
      _setupSameTimestampCheckpointAfterStaleClaim();

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_B, type(uint256).max);

    // it should report no earned fees for the arriving allocation
    assertEq(_earned0, 0);
    assertEq(_earned1, 0);

    // it should notify fees before the no user global point
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeSnapshot(
      _sameTimestampGlobalIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_claimTs - _origin), _feeAcc1 * (_claimTs - _origin)
    );

    // it should keep the credited fee snapshot on the overwritten point
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_claimTs - _origin), _feeAcc1 * (_claimTs - _origin));

    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 2000e18,
      _expectedTs: _claimTs,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_sameTimestampGlobalIndex)
    });
  }

  function test_GivenAStaleOpenIntervalAndASameTimestampCheckpointWithPendingFeesWhenTheArrivingAllocationClaimsFees()
    external
  {
    _deployFeeTokens();

    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;
    _setupSameTimestampCheckpointAfterStaleClaim();

    _claimFeesForArrivingAllocation(_pending0, _pending1);

    // it should transfer no fees to the arriving allocation
    assertEq(TestERC20(_TOKEN0).balanceOf(_recipient), 0);
    assertEq(TestERC20(_TOKEN1).balanceOf(_recipient), 0);
  }

  function test_GivenASinglePermanentVoter(uint128 _allocated, uint48 _duration) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_VOTING_POWER));
    _duration = uint48(bound(_duration, 1 weeks, 4 weeks));
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    _checkpoint(_TOKEN_ID_A, _allocated, 0);
    vm.warp(uint256(_start) + uint256(_duration) + 1);

    // it should transfer the full streamed amount: sole permanent voter => VP == supply over the program
    // reward data field is not checked (checkData=false): the accumulator floors by <= 2 wei vs the exact amount
    vm.expectEmit(true, true, true, false, address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimIncentives(_TOKEN_ID_A, _recipient, _programId, _amount);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    assertLe(_token.balanceOf(_recipient), _amount);
    assertApproxEqRel(_token.balanceOf(_recipient), _amount, 1e6);
  }

  function test_GivenALargeAcceptedProgramAndSinglePermanentVoter() external {
    // Max accepted incentive amount plus 1T voting power used to exercise the permanent accumulator path.
    uint256 _amount = _MAX_INCENTIVE_AMOUNT;
    uint256 _rate = (_amount * 1e18) / _7D_DURATION;
    uint256 _expectedReward = (_rate * _7D_DURATION) / 1e18;

    _token.mint(_creator, _amount);

    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _amount, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, _MAX_VOTING_POWER, 0);

    vm.warp(2 weeks);
    _advance();

    // it should compute the full entitlement without overflowing on intermediate products
    assertEq(votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programId, type(uint256).max), _expectedReward);

    // it should claim the full entitlement without overflowing on intermediate products
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _expectedReward);
  }

  function test_GivenALargeAcceptedMisalignedProgramAndSinglePermanentVoter() external {
    // Misaligned boundaries force the direct partial-interval path at the same max amount / max VP bounds.
    uint48 _start = uint48(1 weeks) + 2 days;
    uint48 _duration = 20 days;
    uint256 _amount = _MAX_INCENTIVE_AMOUNT;
    uint256 _rate = (_amount * 1e18) / _duration;
    uint256 _expectedReward = (_rate * _duration) / 1e18;

    _token.mint(_creator, _amount);

    vm.warp(1 weeks);
    _checkpoint(_TOKEN_ID_A, _MAX_VOTING_POWER, 0);
    uint256 _programId = _createProgram(_start, _amount, _duration);

    for (uint256 _w = 2; _w <= 5; _w++) {
      vm.warp(_w * 1 weeks);
      _advance();
    }

    // it should claim without overflowing on partial-interval products
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    assertLe(_token.balanceOf(_recipient), _expectedReward);
    assertApproxEqRel(_token.balanceOf(_recipient), _expectedReward, 1e6);
  }

  function test_GivenALargeAcceptedProgramAndSingleDecayingVoter() external {
    // Max-lock-style expiry keeps the 1T decaying allocation alive through the whole max-amount program.
    uint256 _amount = _MAX_INCENTIVE_AMOUNT;
    uint256 _rate = (_amount * 1e18) / _7D_DURATION;
    uint256 _expectedReward = (_rate * _7D_DURATION) / 1e18;

    _token.mint(_creator, _amount);

    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _amount, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, _MAX_VOTING_POWER, uint48(block.timestamp + MAX_TIME));

    vm.warp(2 weeks);
    _advance();

    // it should claim without overflowing on decaying accumulator cancellation
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    assertLe(_token.balanceOf(_recipient), _expectedReward);
    assertApproxEqRel(_token.balanceOf(_recipient), _expectedReward, 1e6);
  }

  function test_GivenManyMinimumSlopeDecayingVotersAndTheMaximumAcceptedProgram() external {
    // Minimum valid decaying voters maximize per-claim rounding surface; max amount and min duration maximize rate.
    uint256 _amount = _MAX_INCENTIVE_AMOUNT;
    uint256 _rate = (_amount * 1e18) / _7D_DURATION;
    uint256 _expectedStreamed = (_rate * _7D_DURATION) / 1e18;

    _token.mint(_creator, _amount);
    // Add unrelated same-token surplus so any over-distribution succeeds instead of reverting on pooled balance.
    _token.mint(address(votingRewardsManager), _amount);

    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint48 _stakeEnd = uint48(block.timestamp + MAX_TIME);
    uint256 _programId = _createProgram(_start, _amount, _7D_DURATION);

    for (uint256 _i; _i < _ROUNDING_STRESS_VOTERS; ++_i) {
      _checkpoint(_ROUNDING_STRESS_TOKEN_ID_OFFSET + _i, uint128(MAX_TIME), _stakeEnd);
    }

    vm.warp(2 weeks);
    _advance();

    for (uint256 _i; _i < _ROUNDING_STRESS_VOTERS; ++_i) {
      vm.prank(_VOTER);
      _claimAll(_ROUNDING_STRESS_TOKEN_ID_OFFSET + _i, _recipient, _programId);
    }

    // it should not distribute more than the streamed amount
    assertLe(_token.balanceOf(_recipient), _expectedStreamed);
    assertLe(_token.balanceOf(_recipient), _amount);
  }

  function test_GivenTwoEqualPermanentVoters(uint128 _allocated, uint48 _duration) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_VOTING_POWER));
    _duration = uint48(bound(_duration, 1 weeks, 4 weeks));
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    _checkpoint(_TOKEN_ID_A, _allocated, 0);
    _checkpoint(_TOKEN_ID_B, _allocated, 0);
    vm.warp(uint256(_start) + uint256(_duration) + 1);

    address _recipientA = makeAddr('recipientA');
    address _recipientB = makeAddr('recipientB');

    // it should pay each voter an equal half of the stream
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipientA, _programId);
    assertLe(_token.balanceOf(_recipientA), _amount / 2);
    assertApproxEqRel(_token.balanceOf(_recipientA), _amount / 2, 1e6);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);
    assertLe(_token.balanceOf(_recipientB), _amount / 2);
    assertApproxEqRel(_token.balanceOf(_recipientB), _amount / 2, 1e6);
  }

  function test_GivenADecayingVoterAlongsideAPermanentVoter() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _7D_AMOUNT, _7D_DURATION); // [2w, 3w]
    // decaying A: alloc MAX_TIME, stakeEnd 4w => slope 1, bias at 2w = 4w - 2w = 1_209_600
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(4 weeks));
    // permanent co-voter B: VP = 3_628_800
    _checkpoint(_TOKEN_ID_B, 3_628_800, 0);
    // close the program week so [2w,3w] is a closed interior interval priced by the batched accumulator
    vm.warp(3 weeks);
    _advance();

    address _recipientB = makeAddr('recipientB');

    // it should pay each voter their voting power share
    // Right-aligned supply at 3w - 1: A bias = 604_801, B permanent = 3_628_800.
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);

    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT * 604_801 / (604_801 + 3_628_800));
    assertEq(_token.balanceOf(_recipientB), _7D_AMOUNT * 3_628_800 / (604_801 + 3_628_800));
  }

  function test_GivenAWeekMisalignedProgramAndDecayingVoter() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(1 weeks) + 2 days;
    uint48 _duration = 13 days; // [1w+2d, 3w+1d]: leading partial, one full week, trailing partial
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_start, _amount, _duration);
    // decaying A: slope 1, stakeEnd 6w. Permanent B keeps supply positive and independently claimable.
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(6 weeks));
    _checkpoint(_TOKEN_ID_B, 3_628_800, 0);

    // close through 4w so the interval containing the 3w+1d program end is closed
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();

    address _recipientB = makeAddr('recipientB');

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);

    // it should pay the expected decaying share
    // Right-aligned exact refs:
    // [1w+2d,2w] A=2_419_201 / 6_048_001 for 5d; [2w,3w] A=1_814_401 / 5_443_201
    // for 7d; [3w,3w+1d] A=1_728_001 / 5_356_801 for 1d. Accumulator dust is <= 1 wei per claim.
    assertApproxEqAbs(_token.balanceOf(_recipient), 402_271_095_599_248_307_129_565, 1);
    assertApproxEqAbs(_token.balanceOf(_recipientB), 720_928_904_400_751_692_870_432, 1);

    // it should not distribute more than the streamed amount
    assertLe(_token.balanceOf(_recipient) + _token.balanceOf(_recipientB), _amount);
  }

  function test_GivenVariedWeekMisalignedProgramInputsAndDecayingVoter(
    uint256 _amount,
    uint128 _allocatedA,
    uint128 _allocatedB,
    uint48 _startOffset,
    uint48 _duration
  ) external {
    _startOffset = uint48(bound(_startOffset, 1, 6 days));
    uint48 _start = uint48(1 weeks + _startOffset);
    // Keep every fuzz case in the target shape: start before 2w, end after 3w, and end before 4w.
    uint48 _minDuration = uint48(2 weeks - _startOffset + 1);
    uint48 _maxDuration = uint48(3 weeks - _startOffset - 1);
    _duration = uint48(bound(_duration, _minDuration, _maxDuration));
    _amount = bound(_amount, _duration, _MAX_INCENTIVE_AMOUNT);
    _allocatedA = uint128(bound(_allocatedA, uint256(MAX_TIME), _MAX_VOTING_POWER));
    _allocatedB = uint128(bound(_allocatedB, 1, _MAX_VOTING_POWER));

    _token.mint(_creator, _amount);

    vm.warp(1 weeks);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    _checkpoint(_TOKEN_ID_A, _allocatedA, uint48(6 weeks));
    _checkpoint(_TOKEN_ID_B, _allocatedB, 0);

    for (uint256 _w = 2; _w <= 4; ++_w) {
      vm.warp(_w * 1 weeks);
      _advance();
    }

    address _recipientB = makeAddr('recipientB');
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);

    // it should not distribute more than the streamed amount.
    assertLe(_token.balanceOf(_recipient) + _token.balanceOf(_recipientB), _amount);
  }

  function test_GivenADecayingLockThatExpiresBeforeTheProgramEnds() external {
    vm.warp(2 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _28D_AMOUNT, _28D_DURATION); // [2w, 6w]
    // decaying A: slope 1, stakeEnd 4w => bias at 2w = 1_209_600, expires at 4w (mid program)
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(4 weeks));
    // permanent B keeps supply positive after A expires, so the expiry clip (not the supply==0 skip) is exercised
    _checkpoint(_TOKEN_ID_B, 1_209_600, 0);

    // close every week through program end so [2w,3w]..[5w,6w] are closed intervals
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();
    vm.warp(5 weeks);
    _advance();
    vm.warp(6 weeks);
    _advance();

    uint256 _expectedReward = _WEEK_STREAM * 604_801 / 1_814_401 + _WEEK_STREAM / 1_209_601;

    // it should report the earned amount before claiming
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _expectedReward);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should stop paying at the stake expiry: A earns only over [2w,4w], nothing after 4w.
    // Right-aligned refs: [2w,3w] samples A=604_801 of total 1_814_401; [3w,4w] samples A=1 of total 1_209_601.
    assertEq(_token.balanceOf(_recipient), _expectedReward);
  }

  function test_GivenAVoterCheckpointsAtTheIntervalRightBoundary() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    // B enters exactly at program end. It must not affect or earn the previous interval [1w, 2w).
    vm.warp(2 weeks);
    _checkpoint(_TOKEN_ID_B, 1e18, 0);

    address _recipientB = makeAddr('recipientB');

    // it should report no earnings for the boundary voter
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _7D_AMOUNT);
    assertEq(_earnedAll(_TOKEN_ID_B, _programId), 0);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);

    // it should not pay the boundary voter for the previous interval
    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);
    assertEq(_token.balanceOf(_recipientB), 0);
  }

  function test_GivenSeveralProgramsFundingTheSameVeNFT() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    uint256 _pid1 = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);

    TestERC20 _token2 = new TestERC20('Token2', 'TK2', 18);
    vm.mockCall(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token2))), abi.encode(true));
    _token2.mint(_creator, _7D_AMOUNT);
    vm.prank(_creator);
    _token2.approve(address(votingRewardsManager), type(uint256).max);
    vm.prank(_creator);
    uint256 _pid2 = votingRewardsManager.createIncentiveProgram({
      _token: address(_token2), _amount: _7D_AMOUNT, _start: _start, _duration: _7D_DURATION
    });

    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    address _recipient1 = makeAddr('r1');
    address _recipient2 = makeAddr('r2');

    // it should claim each program independently
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient1, _pid1);
    assertEq(_token.balanceOf(_recipient1), _7D_AMOUNT);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient2, _pid2);
    assertEq(_token2.balanceOf(_recipient2), _7D_AMOUNT);
  }

  function test_GivenTheClaimedRewardIsTheWrappedNativeAndUnwrappingIsSupported() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createWethProgram(votingRewardsManager, _start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    uint256 _nativeBalBefore = _recipient.balance;
    uint256 _wethBalBefore = _weth.balanceOf(_recipient);

    // it should emit the ClaimIncentives event
    _expectEmit(address(votingRewardsManager));
    emit IVotingRewardsManager.ClaimIncentives(_TOKEN_ID_A, _recipient, _programId, _7D_AMOUNT);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    // it should unwrap the wrapped native
    assertEq(_weth.balanceOf(_recipient), _wethBalBefore);
    assertEq(_weth.balanceOf(address(votingRewardsManager)), 0);
    // it should send the native token to the recipient
    assertEq(_recipient.balance - _nativeBalBefore, _7D_AMOUNT);
  }

  function test_GivenTheClaimedRewardIsTheWrappedNativeAndUnwrappingIsNotSupported() external {
    VotingRewardsManager _managerNoUnwrap =
      new VotingRewardsManager(_VOTER, _GAUGE, _GAUGE_FACTORY, address(0), _initialRewards);
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createWethProgram(_managerNoUnwrap, _start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_managerNoUnwrap, _TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    uint256 _nativeBalBefore = _recipient.balance;
    uint256 _wethBalBefore = _weth.balanceOf(_recipient);

    vm.prank(_VOTER);
    _managerNoUnwrap.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    // it should transfer the wrapped native as an ERC20 token
    assertEq(_weth.balanceOf(_recipient) - _wethBalBefore, _7D_AMOUNT);
    // it should not send native token to the recipient
    assertEq(_recipient.balance, _nativeBalBefore);
  }

  function test_GivenTheClaimedRewardIsAnERC20Token() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    uint256 _nativeBalBefore = _recipient.balance;

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    // it should transfer the reward as an ERC20 token
    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);
    // it should not send native token to the recipient
    assertEq(_recipient.balance, _nativeBalBefore);
    // it should reduce the remaining program balance to zero
    assertEq(votingRewardsManager.remainingAmount(_programId), 0);
  }

  function test_GivenSameTokenProgramsFundingTheSameVeNFT(
    uint256 _amountA,
    uint256 _amountB,
    uint128 _weightA,
    uint128 _weightB
  ) external {
    _amountA = bound(_amountA, 14 days, _MAX_INCENTIVE_AMOUNT);
    _amountB = bound(_amountB, _7D_DURATION, _MAX_INCENTIVE_AMOUNT);
    _weightA = uint128(bound(_weightA, 1, _MAX_VOTING_POWER));
    _weightB = uint128(bound(_weightB, 1, _MAX_VOTING_POWER));
    uint256 _totalWeight = uint256(_weightA) + _weightB;
    uint256 _streamedA = ((_amountA * 1e18) / 14 days) * 14 days / 1e18;
    uint256 _streamedB = ((_amountB * 1e18) / _7D_DURATION) * _7D_DURATION / 1e18;

    _token.mint(_creator, _amountA);
    _token.mint(_creator, _amountB);

    vm.warp(1 weeks);
    _checkpoint(_TOKEN_ID_A, _weightA, 0);
    _checkpoint(_TOKEN_ID_B, _weightB, 0);

    {
      uint48 _startA = uint48(block.timestamp);
      uint256 _pid1 = _createProgram(_startA, _amountA, uint48(14 days));
      uint256 _pid2 = _createProgram(uint48(block.timestamp + 1 weeks), _amountB, _7D_DURATION);

      vm.warp(uint256(_startA) + 14 days + 1);

      // it should isolate interleaved claims by program
      vm.prank(_VOTER);
      _claimAll(_TOKEN_ID_A, _sameTokenRecipientA1, _pid1);
      vm.prank(_VOTER);
      _claimAll(_TOKEN_ID_B, _sameTokenRecipientB2, _pid2);
      vm.prank(_VOTER);
      _claimAll(_TOKEN_ID_B, _sameTokenRecipientA2, _pid1);
      vm.prank(_VOTER);
      _claimAll(_TOKEN_ID_A, _sameTokenRecipientB1, _pid2);

      // it should track each program's remaining balance independently
      assertEq(
        votingRewardsManager.remainingAmount(_pid1),
        _streamedA - _token.balanceOf(_sameTokenRecipientA1) - _token.balanceOf(_sameTokenRecipientA2)
      );
      assertEq(
        votingRewardsManager.remainingAmount(_pid2),
        _streamedB - _token.balanceOf(_sameTokenRecipientB1) - _token.balanceOf(_sameTokenRecipientB2)
      );
    }

    {
      uint256 _programAClaims = _token.balanceOf(_sameTokenRecipientA1) + _token.balanceOf(_sameTokenRecipientA2);
      // The per-voter reference uses one final division, while the accumulator path can differ by 1 wei.
      // The program total is the strict conservation check.
      assertLe(_token.balanceOf(_sameTokenRecipientA1), Math.mulDiv(_streamedA, _weightA, _totalWeight) + 1);
      assertLe(_token.balanceOf(_sameTokenRecipientA2), Math.mulDiv(_streamedA, _weightB, _totalWeight) + 1);
      assertLe(_programAClaims, _streamedA);
    }

    {
      uint256 _programBClaims = _token.balanceOf(_sameTokenRecipientB1) + _token.balanceOf(_sameTokenRecipientB2);
      // The per-voter reference uses one final division, while the accumulator path can differ by 1 wei.
      // The program total is the strict conservation check.
      assertLe(_token.balanceOf(_sameTokenRecipientB1), Math.mulDiv(_streamedB, _weightA, _totalWeight) + 1);
      assertLe(_token.balanceOf(_sameTokenRecipientB2), Math.mulDiv(_streamedB, _weightB, _totalWeight) + 1);
      assertLe(_programBClaims, _streamedB);
    }

    uint256 _totalClaims = _token.balanceOf(_sameTokenRecipientA1) + _token.balanceOf(_sameTokenRecipientA2)
      + _token.balanceOf(_sameTokenRecipientB1) + _token.balanceOf(_sameTokenRecipientB2);
    assertLe(_totalClaims, _streamedA + _streamedB);
    assertEq(_token.balanceOf(address(votingRewardsManager)), _streamedA + _streamedB - _totalClaims);
  }

  function test_GivenABoundedClaimOverMultipleUserCheckpoints() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    // three user checkpoints, each opening a new span: cp1 [1w,2w], cp2 [2w,3w], cp3 [3w, tip]
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(2 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(3 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    // close the remaining weeks of the 4-week program
    vm.warp(4 weeks);
    _advance();
    vm.warp(5 weeks);
    _advance();

    // _maxCheckpoints=1 prices only the first user checkpoint's span [1w,2w]
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);
    // it should pay only the processed user checkpoints
    assertEq(_token.balanceOf(_recipient), _WEEK_STREAM);
    // it should update the remaining program balance after each claim
    assertEq(votingRewardsManager.remainingAmount(_programId), _28D_AMOUNT - _WEEK_STREAM);
    // it should advance the claim pointers by the processed count
    assertEq(votingRewardsManager.incentiveClaimState(_TOKEN_ID_A, _programId).lastUserCp, 2);

    // it should let a later claim pay the remaining entitlement: cp2 [2w,3w] + cp3 [3w,5w] = 3 weeks
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 2);
    assertEq(_token.balanceOf(_recipient), 4 * _WEEK_STREAM);
    assertEq(votingRewardsManager.remainingAmount(_programId), 0);
  }

  function test_GivenABoundedClaimWithAStaleOpenInterval() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    // two user checkpoints: cp1 [1w,2w], cp2 [2w, tip]
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(2 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(3 weeks);
    _advance();

    // three days past the latest checkpoint (3w): the open interval is stale
    vm.warp(uint256(3 weeks) + 3 days);
    // _maxCheckpoints=1 prices only cp1 and stops before cp2, the checkpoint whose span runs to the open tip
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);

    // it should not close the open interval when the claim stops short of the latest checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), 3);
    // it should pay only the processed checkpoints: the first user checkpoint's span [1w,2w]
    assertEq(_token.balanceOf(_recipient), _WEEK_STREAM);

    // a second bounded claim resumes at cp2 (now the latest user checkpoint) and reaches it
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);

    // it should close the open interval once a later claim reaches the latest checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), 4);
    // it should pay the trailing period on that claim: cp2 [2w, 3w+3d] = one week plus three days
    assertEq(_token.balanceOf(_recipient), 2 * _WEEK_STREAM + 259_200e18);
  }

  function test_GivenABoundedHistoricalClaimBeyondTheCheckpointIterationLimit() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint48 _duration = uint48((MAX_CHECKPOINT_ITERATIONS + 2) * 1 weeks);
    uint256 _programId = _createProgram(_start, _duration, _duration);
    // Two user checkpoints leave the first interval closed and the latest interval open.
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(2 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    /// @dev Make history exceed the single-advance limit by one second
    vm.warp(ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks + 1);

    // it should allow the bounded historical claim
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);

    // it should pay only the processed checkpoint
    assertEq(_token.balanceOf(_recipient), 1 weeks);
  }

  function test_GivenABoundedClaimThatSkipsAZeroPowerCheckpoint() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0); // cp1 powered [1w,2w]
    vm.warp(2 weeks);
    _checkpoint(_TOKEN_ID_A, 0, 0); // cp2 reset: zero power [2w,3w]
    vm.warp(3 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0); // cp3 powered [3w, tip]
    vm.warp(4 weeks);
    _advance();
    vm.warp(5 weeks);
    _advance();

    // _maxCheckpoints=2 prices cp1, then the zero-power cp2 consumes the second slot, stopping before cp3
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 2);
    // it should count the skipped zero-power checkpoint against the limit
    assertEq(_token.balanceOf(_recipient), _WEEK_STREAM);

    // it should let a later claim pay the remaining: cp3 [3w,5w] = 2 weeks
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 2);
    assertEq(_token.balanceOf(_recipient), 3 * _WEEK_STREAM);
  }

  function test_GivenARepeatedClaimAfterTheDecayingStakeExpired() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION); // [2w, 6w]
    // decaying A expires at 4w; permanent B keeps global supply positive afterwards
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(4 weeks));
    _checkpoint(_TOKEN_ID_B, 1e18, 0);

    // close through A's expiry and claim: A is paid its share over [2w,4w]
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    uint256 _firstClaim = _token.balanceOf(_recipient);
    assertGt(_firstClaim, 0);

    // close weeks past A's expiry; A's resumed span is entirely after expiry -> empty priced range
    vm.warp(5 weeks);
    _advance();
    vm.warp(6 weeks);
    _advance();

    // it should pay nothing on the second claim
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _firstClaim);
  }

  function test_GivenAVoterThatResetBeforeClaiming() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _28D_AMOUNT, _28D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);

    // sole voter for the first week; the interval [1w,2w] is closed at the 2w boundary
    vm.warp(2 weeks);
    _advance();

    // the voter resets at the 2w boundary: subsequent intervals have no voting power for A
    _checkpoint(_TOKEN_ID_A, 0, 0);

    // close the next two weeks so [2w,3w] and [3w,4w] exist as zero-power intervals for A
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();

    // it should report only the earned share before claiming
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _WEEK_STREAM);

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);

    // it should pay only the share earned while voting: the single active week [1w,2w]
    // it should not pay for the period after the reset
    assertEq(_token.balanceOf(_recipient), _WEEK_STREAM);
  }

  function test_GivenARepeatedClaimWithNoNewClosedInterval() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _7D_AMOUNT, _7D_DURATION);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    vm.warp(uint256(_start) + uint256(_7D_DURATION) + 1);

    // first claim closes the open interval and pays the whole program through the program end
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);

    // it should report no remaining earned rewards
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 0);

    // it should transfer nothing on the second claim: nothing new is closeable
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _7D_AMOUNT);
  }

  function test_GivenAProgramMisalignedWithWeekBoundaries() external {
    // both program boundaries fall mid-interval: start at 1w+2d, end at 1w+2d+20d = 4w+1d
    vm.warp(1 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    uint48 _start = uint48(1 weeks) + 2 days;
    uint48 _duration = 20 days;
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_start, _amount, _duration);

    // close every week through the interval holding the end (4w+1d lives in [4w,5w])
    for (uint256 _w = 2; _w <= 5; _w++) {
      vm.warp(_w * 1 weeks);
      _advance();
    }

    // it should report the full streamed amount before claiming
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _amount);

    // it should pay the full streamed amount: a sole permanent voter earns the whole program regardless of
    // where the boundaries fall (leading and trailing partials clip exactly to start and end)
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_GivenAProgramEndingMidIntervalAtTheLatestCheckpoint() external {
    // end at 1w+17d = 3w+3d, mid the [3w,4w] interval whose right edge (4w) is the latest checkpoint
    vm.warp(1 weeks);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    uint48 _duration = 17 days;
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(uint48(1 weeks), _amount, _duration);

    // close through 4w: [3w,4w] is closed and 4w is the latest checkpoint
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();

    // it should report the full streamed amount before claiming
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _amount);

    // it should pay the full streamed amount without overpaying: the last interval must be clipped to the
    // program end (3w+3d), not paid through the tip checkpoint (4w)
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_GivenProgramBoundariesMisalignedWithTheUserCheckpoints() external {
    // the voter checkpoints mid-week (1w+2d) while the program is week-aligned [2w,5w]; the program
    // boundaries fall inside the voter's single span, not on its checkpoint
    vm.warp(uint256(1 weeks) + 2 days);
    _checkpoint(_TOKEN_ID_A, 1e18, 0);
    uint256 _amount = uint256(3 weeks) * 1e18;
    uint256 _programId = _createProgram(uint48(2 weeks), _amount, uint48(3 weeks));

    for (uint256 _w = 2; _w <= 5; _w++) {
      vm.warp(_w * 1 weeks);
      _advance();
    }

    // it should report the full streamed amount before claiming
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _amount);

    // it should pay the full streamed amount
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_GivenMultipleVotersOverTheFullProgram(uint128 _allocA, uint128 _allocB, uint48 _duration) external {
    // permanent A and decaying B both present for the whole program => no zero-supply gaps => the full
    // streamed amount is distributed between them
    _allocA = uint128(bound(_allocA, 1e18, _MAX_VOTING_POWER));
    _allocB = uint128(bound(_allocB, uint256(MAX_TIME), _MAX_VOTING_POWER));
    _duration = uint48(bound(_duration, 1 weeks, 4 weeks));
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    _checkpoint(_TOKEN_ID_A, _allocA, 0);
    _checkpoint(_TOKEN_ID_B, _allocB, uint48(208 weeks)); // decaying, outlives the program
    vm.warp(uint256(_start) + uint256(_duration) + 1);

    address _recipientB = makeAddr('recipientB');
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_B, _recipientB, _programId);

    uint256 _sum = _token.balanceOf(_recipient) + _token.balanceOf(_recipientB);
    // it should distribute the streamed amount without over-paying
    assertLe(_sum, _amount);
    assertApproxEqRel(_sum, _amount, 1e6);
  }

  /// @dev Heavy claim path: a decaying voter re-checkpointing weekly across a week-misaligned 10-week program,
  ///      so the claim prices many user-checkpoint spans plus the leading and trailing program-boundary partials.
  function _setupHeavyDecayingClaim() internal returns (uint256) {
    uint48 _start = uint48(1 weeks) + 2 days; // misaligned start -> leading partial
    uint48 _duration = 10 weeks;
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(_start, _amount, _duration);
    // re-checkpoint every week: each call closes the open interval and appends a new user checkpoint
    for (uint256 _w = 1; _w <= 11; _w++) {
      vm.warp(_w * 1 weeks);
      _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(208 weeks));
    }
    vm.warp(12 weeks); // leave the interval holding the misaligned program end stale for the measured claim
    return _programId;
  }

  function testGas_claimIncentives() external {
    uint256 _programId = _setupHeavyDecayingClaim();
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_pending0, _pending1));

    vm.prank(_VOTER);
    _claimAll(_TOKEN_ID_A, _recipient, _programId);
    vm.snapshotGasLastCall('VotingRewardsManager_claimIncentives');
  }
}
