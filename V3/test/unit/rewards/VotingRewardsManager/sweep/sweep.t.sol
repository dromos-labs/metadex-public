// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerSweep is UnitVotingRewardsManager {
  using stdStorage for StdStorage;

  // Programs stream 1 token (1e18 wei) per second: amount = duration * 1e18, so rate = 1e36 and a zero-voter
  // window of W seconds is worth W * 1e18 wei.
  uint256 internal constant _TWO_WEEK_AMOUNT = 1_209_600e18;
  uint48 internal constant _TWO_WEEK_DURATION = uint48(2 weeks);
  uint256 internal constant _ONE_WEEK_STREAM = 604_800e18;

  address internal _creator = makeAddr('creator');
  address internal _recipient = makeAddr('recipient');
  TestERC20 internal _token;

  uint48 internal _start;
  uint48 internal _end;

  function setUp() public override {
    super.setUp();

    _token = new TestERC20('Incentive Token', 'INC', 18);
    vm.mockCall(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, 100_000_000e18);
    vm.prank(_creator);
    _token.approve(address(votingRewardsManager), type(uint256).max);

    // Align to a week boundary so program edges coincide with the week-boundary global checkpoints.
    vm.warp(1 weeks);
    _start = uint48(block.timestamp + 1 weeks);
    _end = _start + _TWO_WEEK_DURATION;
  }

  function _createProgram(uint48 _programStart, uint256 _amount, uint48 _duration) internal returns (uint256) {
    vm.prank(_creator);
    return votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _programStart, _duration: _duration
    });
  }

  function _createTwoWeekProgram() internal returns (uint256) {
    return _createProgram(_start, _TWO_WEEK_AMOUNT, _TWO_WEEK_DURATION);
  }

  /// @dev Funds the creator with wrapped native and opens a two-week program denominated in it on `_manager`.
  function _createWethProgram(VotingRewardsManager _manager) internal returns (uint256) {
    vm.mockCall(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_weth))), abi.encode(true));
    vm.deal(_creator, _TWO_WEEK_AMOUNT);
    vm.startPrank(_creator);
    _weth.deposit{value: _TWO_WEEK_AMOUNT}();
    _weth.approve(address(_manager), type(uint256).max);
    uint256 _programId = _manager.createIncentiveProgram({
      _token: address(_weth), _amount: _TWO_WEEK_AMOUNT, _start: _start, _duration: _TWO_WEEK_DURATION
    });
    vm.stopPrank();
    return _programId;
  }

  function _checkpoint(uint256 _tokenId, uint128 _allocated, uint48 _stakeEnd) internal {
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _tokenId, _allocated: _allocated, _stakeEnd: _stakeEnd, _data: ''});
  }

  /// @dev A reset is a checkpoint with zero allocation, clearing the voter's contribution to supply.
  function _reset(uint256 _tokenId) internal {
    _checkpoint(_tokenId, 0, 0);
  }

  function _advance() internal {
    vm.prank(_VOTER);
    votingRewardsManager.advanceGlobalPoints();
  }

  function _sweepAndReturnCreatorDelta(uint256 _programId) internal returns (uint256) {
    uint256 _balBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    return _token.balanceOf(_creator) - _balBefore;
  }

  function _claimAndReturnRecipientDelta(uint256 _programId) internal returns (uint256) {
    uint256 _balBefore = _token.balanceOf(_recipient);
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    return _token.balanceOf(_recipient) - _balBefore;
  }

  function _deployFeeTokens() internal {
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 0', 'FEE0', uint8(18)), _TOKEN0);
    deployCodeTo('V3/test/mocks/TestERC20.sol:TestERC20', abi.encode('Fee Token 1', 'FEE1', uint8(18)), _TOKEN1);
  }

  function _setupSameTimestampCheckpointAfterStaleSweep()
    internal
    returns (uint256 _sameTimestampGlobalIndex, uint256 _feeAcc0, uint256 _feeAcc1)
  {
    uint128 _weight = 1000e18;
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;
    uint256 _programId = _createTwoWeekProgram();

    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, _weight, 0);

    vm.warp(_end);
    _mockGaugePendingFees(_pending0, _pending1);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    _sameTimestampGlobalIndex = votingRewardsManager.globalCheckpointIndex();
    _feeAcc0 = _pending0 * FEE_ACCUMULATOR_PRECISION / _weight;
    _feeAcc1 = _pending1 * FEE_ACCUMULATOR_PRECISION / _weight;

    _checkpoint(_TOKEN_ID_B, _weight, 0);

    uint256 _advanceTs = _end + 1 weeks;
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

  function test_WhenTheProgramIdIsZero() external {
    // it should revert with ProgramNotFound
    vm.expectRevert(IIncentiveStreaming.ProgramNotFound.selector);
    vm.prank(_creator);
    votingRewardsManager.sweep(0);
  }

  function test_WhenTheProgramIdExceedsTheIncentiveCount(uint256 _unknownId) external {
    _createTwoWeekProgram();
    _unknownId = bound(_unknownId, votingRewardsManager.incentiveCount() + 1, type(uint256).max);

    // it should revert with ProgramNotFound
    vm.expectRevert(IIncentiveStreaming.ProgramNotFound.selector);
    vm.prank(_creator);
    votingRewardsManager.sweep(_unknownId);
  }

  function test_WhenTheCallerIsNotTheProgramCreator(address _caller) external {
    uint256 _programId = _createTwoWeekProgram();
    _assumeFuzzable(_caller);
    vm.assume(_caller != _creator);

    // it should revert with NotCreator
    vm.expectRevert(IIncentiveStreaming.NotCreator.selector);
    vm.prank(_caller);
    votingRewardsManager.sweep(_programId);
  }

  function test_WhenTheProgramHasNotEnded(uint256 _ts) external {
    uint256 _programId = _createTwoWeekProgram();
    _ts = bound(_ts, block.timestamp, _end - 1);
    vm.warp(_ts);

    // it should revert with ProgramNotEnded
    vm.expectRevert(IIncentiveStreaming.ProgramNotEnded.selector);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
  }

  function test_WhenASweepExceedsTheRemainingProgramBalance() external {
    uint256 _programIdA = _createTwoWeekProgram();
    uint256 _programIdB = _createTwoWeekProgram();
    vm.warp(_end);

    uint256 _remaining = _TWO_WEEK_AMOUNT - 1;
    stdstore.target(address(votingRewardsManager)).sig(votingRewardsManager.remainingAmount.selector)
      .with_key(_programIdA).checked_write(_remaining);

    /// @dev Leave program A one wei short while program B's same-token deposit remains pooled
    _token.burn(address(votingRewardsManager), 1);
    assertEq(
      _token.balanceOf(address(votingRewardsManager)), _remaining + votingRewardsManager.remainingAmount(_programIdB)
    );

    // it should revert with InsufficientProgramBalance
    vm.expectRevert(IIncentiveStreaming.InsufficientProgramBalance.selector);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programIdA);
  }

  modifier whenTheProgramCanBeSwept() {
    _;
  }

  function test_GivenOnlyTheInitializationCheckpointExists() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    vm.warp(_end);

    uint256 _balBefore = _token.balanceOf(_creator);

    // it should emit IncentiveSwept
    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveSwept(_programId, _creator, _TWO_WEEK_AMOUNT);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should credit the full program window
    // it should transfer the swept amount to the creator
    assertEq(_token.balanceOf(_creator) - _balBefore, _TWO_WEEK_AMOUNT);
    // it should record the swept amount
    assertEq(votingRewardsManager.sweptAmount(_programId), _TWO_WEEK_AMOUNT);
    // it should reduce the remaining program balance to zero
    assertEq(votingRewardsManager.remainingAmount(_programId), 0);
  }

  function test_GivenAZeroVoterPrefixPrecedesTheFirstVoterCheckpoint() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // The first voter checkpoint lands a week into the program, so [_start, _start + 1w) is zero-voter.
    vm.warp(_start + 1 weeks);
    _checkpoint(_TOKEN_ID_A, 1e21, 0);
    vm.warp(_end);

    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should credit the zero voter prefix
    // it should transfer the swept amount to the creator
    assertEq(_token.balanceOf(_creator) - _balBefore, _ONE_WEEK_STREAM);
    // it should reduce the remaining program balance by the swept amount
    assertEq(votingRewardsManager.remainingAmount(_programId), _TWO_WEEK_AMOUNT - _ONE_WEEK_STREAM);
  }

  function test_GivenTheHistoryIsStaleAcrossTheProgramEnd() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // A non-permanent voter expires a week into the program; the history is never advanced, so the sweep
    // must fill the missing week boundaries (applying the expiry slope change) before measuring supply.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end + 3 weeks);

    uint256 _indexBefore = votingRewardsManager.globalCheckpointIndex();
    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should advance the global history before measuring
    assertGt(votingRewardsManager.globalCheckpointIndex(), _indexBefore);
    // it should credit the zero voter intervals up to the program end ([_start + 1w, _end) = one week)
    assertEq(_token.balanceOf(_creator) - _balBefore, _ONE_WEEK_STREAM);
  }

  function test_GivenHistoryCannotReachTheProgramEndWithinTheIterationLimit() external whenTheProgramCanBeSwept {
    uint48 _duration = _TWO_WEEK_DURATION;
    uint48 _programStart =
      uint48(ProtocolTimeLibrary.epochStart(block.timestamp) + MAX_CHECKPOINT_ITERATIONS * 1 weeks - _duration + 1);
    uint48 _programEnd = _programStart + _duration;
    uint256 _programId = _createProgram(_programStart, uint256(_duration), _duration);

    /// @dev Make history exceed the single-advance limit by one second
    vm.warp(_programEnd);

    // it should revert with StaleCheckpointHistory
    vm.expectRevert(IIncentiveStreaming.StaleCheckpointHistory.selector);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    /// @dev Advance stale history so the program end falls within the iteration limit
    _advance();

    uint256 _swept = _sweepAndReturnCreatorDelta(_programId);

    // it should sweep the complete program window after history is advanced
    assertEq(_swept, uint256(_duration));
  }

  function test_GivenTheProgramIsLongerThanTheCheckpointIterationLimit() external whenTheProgramCanBeSwept {
    /// @dev Span two full checkpoint batches plus one week so recovery requires two advanceGlobalPoints calls
    uint256 _durationWeeks = 2 * MAX_CHECKPOINT_ITERATIONS + 1;
    uint48 _duration = uint48(_durationWeeks * 1 weeks);
    uint48 _programEnd = _start + _duration;

    /// @dev Stream one wei per second so every zero-voter second maps directly to one wei swept
    uint256 _programId = _createProgram(_start, uint256(_duration), _duration);

    /// @dev Limit voting supply to the first program week so the remaining window is fully sweepable
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_programEnd);

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;

    /// @dev Recover history until one final bounded update can reach the program end
    while (_programEnd > ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks) {
      // it should revert with StaleCheckpointHistory until the program end is reachable
      vm.expectRevert(IIncentiveStreaming.StaleCheckpointHistory.selector);
      vm.prank(_creator);
      votingRewardsManager.sweep(_programId);

      _advance();
      _globalIndex = votingRewardsManager.globalCheckpointIndex();
      _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    }

    uint256 _swept = _sweepAndReturnCreatorDelta(_programId);
    uint256 _expectedSweep = uint256(_duration) - 1 weeks;

    // it should transfer the complete zero voter reward to the creator
    assertEq(_swept, _expectedSweep);
    // it should conserve the deposited amount across swept and remaining balances
    assertEq(
      votingRewardsManager.sweptAmount(_programId) + votingRewardsManager.remainingAmount(_programId),
      uint256(_duration)
    );

    // it should transfer nothing on a repeat sweep
    assertEq(_sweepAndReturnCreatorDelta(_programId), 0);
  }

  function test_GivenTheProgramEndIsReachableButTheCurrentTimestampIsNot() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    uint256 _partialFrontier = ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks;

    /// @dev End the program within the reachable history while leaving the current timestamp one second beyond it
    vm.warp(_partialFrontier + 1);

    /// @dev Revert any pending-fee query to prove closing the ended program does not read the gauge
    // it should not query the gauge for pending fees
    vm.clearMockedCalls();
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), '');

    uint256 _swept = _sweepAndReturnCreatorDelta(_programId);
    _globalIndex = votingRewardsManager.globalCheckpointIndex();

    // it should advance global history through the program end
    assertEq(votingRewardsManager.globalRewardPointHistory(_globalIndex).ts, _partialFrontier);
    assertGe(_partialFrontier, _end);
    assertLt(_partialFrontier, block.timestamp);

    // it should preserve fee accounting
    _assertFeeAccumulator(0, 0, 0, 0);
    assertEq(votingRewardsManager.lastFeeUpdate(), 0);
    assertEq(votingRewardsManager.lastPendingFees0(), 0);
    assertEq(votingRewardsManager.lastPendingFees1(), 0);
    assertEq(votingRewardsManager.bufferedFees0(), 0);
    assertEq(votingRewardsManager.bufferedFees1(), 0);
    _assertFeeSnapshot(_globalIndex, 0, 0, 0, 0);

    // it should sweep the complete program window
    assertEq(_swept, _TWO_WEEK_AMOUNT);
    assertEq(votingRewardsManager.remainingAmount(_programId), 0);
  }

  function test_GivenStaleHistoryAcrossTheProgramEndAndASameTimestampCheckpointWithPendingFees()
    external
    whenTheProgramCanBeSwept
  {
    (uint256 _sameTimestampGlobalIndex, uint256 _feeAcc0, uint256 _feeAcc1) =
      _setupSameTimestampCheckpointAfterStaleSweep();

    (uint256 _earned0, uint256 _earned1) = votingRewardsManager.earnedFees(_TOKEN_ID_B, type(uint256).max);

    // it should report no earned fees for the arriving allocation
    assertEq(_earned0, 0);
    assertEq(_earned1, 0);

    // it should notify fees before the no user global point
    uint256 _origin = votingRewardsManager.ACCUMULATOR_ORIGIN();
    _assertFeeSnapshot(
      _sameTimestampGlobalIndex, _feeAcc0, _feeAcc1, _feeAcc0 * (_end - _origin), _feeAcc1 * (_end - _origin)
    );

    // it should keep the credited fee snapshot on the overwritten point
    _assertFeeAccumulator(_feeAcc0, _feeAcc1, _feeAcc0 * (_end - _origin), _feeAcc1 * (_end - _origin));

    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 2000e18,
      _expectedTs: _end,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_sameTimestampGlobalIndex)
    });
  }

  function test_GivenStaleHistoryAcrossTheProgramEndAndASameTimestampCheckpointWithPendingFeesWhenTheArrivingAllocationClaimsFees()
    external
    whenTheProgramCanBeSwept
  {
    _deployFeeTokens();

    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;
    _setupSameTimestampCheckpointAfterStaleSweep();

    _claimFeesForArrivingAllocation(_pending0, _pending1);

    // it should transfer no fees to the arriving allocation
    assertEq(TestERC20(_TOKEN0).balanceOf(_recipient), 0);
    assertEq(TestERC20(_TOKEN1).balanceOf(_recipient), 0);
  }

  function test_GivenAPermanentVoterIsActiveForTheWholeWindow() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, 1e21, 0);
    vm.warp(_end);

    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should not credit any amount
    // it should not transfer or emit (no balance change implies no IncentiveSwept, which only fires with a transfer)
    assertEq(_token.balanceOf(_creator), _balBefore);
    // it should leave the swept amount unchanged
    assertEq(votingRewardsManager.sweptAmount(_programId), 0);
  }

  function test_GivenANonPermanentVoterDecaysToZeroMidProgram() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // Voter's stake expires at the first week boundary. [_start, _start + 1w) has positive supply at its
    // right-aligned reference (_start + 1w - 1), while [_start + 1w, _end) is zero at its right-aligned
    // reference and is sweepable. Advancing first keeps the sweep on the fresh-history path.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end);
    _advance();

    uint256 _balBefore = _token.balanceOf(_creator);

    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveSwept(_programId, _creator, _ONE_WEEK_STREAM);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should credit only the interval that is zero at its right aligned reference (one week, not two)
    // it should transfer the swept amount to the creator
    assertEq(_token.balanceOf(_creator) - _balBefore, _ONE_WEEK_STREAM);
  }

  function test_GivenAPermanentVoterResetsMidProgram() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, 1e21, 0);
    // Reset a week into the program; supply is zero from the reset onward.
    vm.warp(_start + 1 weeks);
    _reset(_TOKEN_ID_A);
    vm.warp(_end);

    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should credit the interval after the reset ([_start + 1w, _end) = one week)
    // it should transfer the swept amount to the creator
    assertEq(_token.balanceOf(_creator) - _balBefore, _ONE_WEEK_STREAM);
  }

  function test_GivenACheckpointSitsExactlyOnTheProgramEnd() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // The program end is week-aligned, so advancing materializes a global checkpoint exactly at _end. That
    // checkpoint begins outside the program window and must not add zero-supply seconds to the swept amount.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end);
    _advance();

    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should keep zero supply accounting inside the program window (only the one zero-voter week is credited)
    assertEq(_token.balanceOf(_creator) - _balBefore, _ONE_WEEK_STREAM);

    // it should record the cumulative swept amount
    uint256 _sweptAmount = votingRewardsManager.sweptAmount(_programId);
    assertEq(_sweptAmount, _ONE_WEEK_STREAM);

    // A repeat sweep is a no-op because the cumulative zero-supply seconds are already swept.
    uint256 _balAfter = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    assertEq(_token.balanceOf(_creator), _balAfter);
    assertEq(votingRewardsManager.sweptAmount(_programId), _sweptAmount);
  }

  function test_GivenTheProgramWasAlreadyFullySwept() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    vm.warp(_end);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    uint256 _sweptAmount = votingRewardsManager.sweptAmount(_programId);
    uint256 _remainingBefore = votingRewardsManager.remainingAmount(_programId);
    uint256 _balBefore = _token.balanceOf(_creator);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should not credit any amount on a repeat sweep
    assertEq(_token.balanceOf(_creator), _balBefore);
    // it should keep the swept amount unchanged
    assertEq(votingRewardsManager.sweptAmount(_programId), _sweptAmount);
    // it should leave the remaining program balance unchanged
    assertEq(votingRewardsManager.remainingAmount(_programId), _remainingBefore);
  }

  function test_GivenAVoterClaimsAndTheCreatorSweepsTheSameProgram() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // Voter is active for the first week then expires; the second week is zero-voter.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end);
    _advance();

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _voterReceived = _token.balanceOf(_recipient);

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should not pay out more than the deposited amount (no overpay) and should leave at most
    // rounding dust unclaimed (no excessive stranding) — claim + sweep partition the deposit
    uint256 _totalOut = _voterReceived + _creatorReceived;
    assertLe(_totalOut, _TWO_WEEK_AMOUNT);
    assertGe(_totalOut, _TWO_WEEK_AMOUNT - 1);
    // it should account for the deposited amount across claim, sweep, and remaining balance
    assertEq(_totalOut + votingRewardsManager.remainingAmount(_programId), _TWO_WEEK_AMOUNT);
  }

  function test_GivenTheCreatorSweepsAndAVoterClaimsTheSameProgram() external whenTheProgramCanBeSwept {
    uint256 _programId = _createTwoWeekProgram();
    // Voter is active for the first week then expires; the second week is zero-voter.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end);
    _advance();

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _voterReceived = _token.balanceOf(_recipient);

    // it should not pay out more than the deposited amount. Sweep and claim still partition the deposit when
    // the creator sweeps before the voter claims.
    uint256 _totalOut = _voterReceived + _creatorReceived;
    assertLe(_totalOut, _TWO_WEEK_AMOUNT);
    assertGe(_totalOut, _TWO_WEEK_AMOUNT - 1);
    // it should account for the deposited amount across claim, sweep, and remaining balance
    assertEq(_totalOut + votingRewardsManager.remainingAmount(_programId), _TWO_WEEK_AMOUNT);
  }

  function test_GivenVariableProgramTimingAndStakeDuration(
    uint256 _startOffset,
    uint256 _durationSeed,
    uint256 _stakeEndCase,
    uint256 _stakeEndOffset,
    bool _sweepFirst
  ) external whenTheProgramCanBeSwept {
    _startOffset = bound(_startOffset, 1, 6 days);
    uint48 _programStart = uint48(uint256(_start) + _startOffset);
    uint48 _duration = uint48(bound(_durationSeed, 1 weeks, 6 weeks));
    uint48 _programEnd = uint48(uint256(_programStart) + _duration);
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_programStart, _amount, _duration);

    uint256 _stakeOffset;
    if (_stakeEndCase % 3 == 0) {
      _stakeOffset = bound(_stakeEndOffset, 1, uint256(_duration) - 1);
    } else if (_stakeEndCase % 3 == 1) {
      _stakeOffset = _duration;
    } else {
      _stakeOffset = bound(_stakeEndOffset, uint256(_duration) + 1, uint256(_duration) + 1 weeks);
    }

    vm.warp(_programStart);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(uint256(_programStart) + _stakeOffset));
    vm.warp(uint256(_programEnd) + 1);

    uint256 _claimed;
    uint256 _swept;
    if (_sweepFirst) {
      _swept = _sweepAndReturnCreatorDelta(_programId);
      _claimed = _claimAndReturnRecipientDelta(_programId);
    } else {
      _claimed = _claimAndReturnRecipientDelta(_programId);
      _swept = _sweepAndReturnCreatorDelta(_programId);
    }

    uint256 _totalOut = _claimed + _swept;

    // it should conserve the deposited amount across claim, sweep, and remaining balance
    assertLe(_totalOut, _amount);
    assertGe(_totalOut, _amount - 1);
    assertEq(_totalOut + votingRewardsManager.remainingAmount(_programId), _amount);
  }

  function test_GivenAKnownRoundedDownExample() external whenTheProgramCanBeSwept {
    // 604801 wei streamed over 604800 seconds: the per-second rate truncates, and over the full zero-voter
    // window the program deposits and pays 604800 wei, leaving one wei with the creator.
    uint256 _oddAmount = 604_801;
    uint48 _duration = uint48(7 days);
    uint256 _programId = _createProgram(_start, _oddAmount, _duration);
    vm.warp(_start + _duration);

    uint256 _balBefore = _token.balanceOf(_creator);

    // it should emit IncentiveSwept with the rounded down amount
    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveSwept(_programId, _creator, 604_800);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should transfer the rounded down amount to the creator
    assertEq(_token.balanceOf(_creator) - _balBefore, 604_800);
    assertEq(_token.balanceOf(address(votingRewardsManager)), 0);
  }

  function test_GivenACheckpointPrecedesANonAlignedStartWithZeroSupplyAtTheRightAlignedReference()
    external
    whenTheProgramCanBeSwept
  {
    // A permanent voter checkpoints at a week boundary, then resets before the program starts, leaving a
    // global checkpoint strictly before a non-week-aligned program.start. The first in-window interval clips
    // its start to program.start, but still measures zero supply at its right-aligned reference.
    vm.warp(_start); // _start is week-aligned
    _checkpoint(_TOKEN_ID_A, 1e21, 0);
    vm.warp(_start + 2 days);
    _reset(_TOKEN_ID_A); // checkpoint at _start + 2 days, supply -> 0

    uint48 _programStart = uint48(_start + 3 days); // non-week-aligned, after the reset checkpoint
    uint256 _programId = _createProgram(_programStart, uint256(_TWO_WEEK_DURATION), _TWO_WEEK_DURATION); // 1 wei/sec
    vm.warp(_programStart + _TWO_WEEK_DURATION);

    uint256 _balBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should credit the clipped first interval to the creator — supply is zero at the paid reference, and
    // the whole window is zero-voter, so the full duration is swept
    assertEq(_token.balanceOf(_creator) - _balBefore, uint256(_TWO_WEEK_DURATION));
  }

  function test_GivenACheckpointPrecedesANonAlignedStartWithPositiveSupplyAtTheRightAlignedReference()
    external
    whenTheProgramCanBeSwept
  {
    // A permanent voter checkpoints at a week boundary and stays active, leaving a global checkpoint strictly
    // before a non-week-aligned program.start. The first in-window interval clips to program.start (the
    // leading partial), but still has positive supply at its right-aligned reference and must not be swept.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, 1e21, 0);

    uint48 _programStart = uint48(_start + 3 days); // non-week-aligned
    uint256 _amount = uint256(_TWO_WEEK_DURATION); // 1 wei/sec
    uint256 _programId = _createProgram(_programStart, _amount, _TWO_WEEK_DURATION);
    vm.warp(_programStart + _TWO_WEEK_DURATION);
    _advance();

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _voterReceived = _token.balanceOf(_recipient);

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should not sweep the clipped first interval
    assertEq(_creatorReceived, 0);
    // it should not pay out more than the deposited amount
    assertLe(_voterReceived + _creatorReceived, _amount);
  }

  function test_GivenProgramStartIsInsideAZeroPricedIntervalWithPositiveStartSupply()
    external
    whenTheProgramCanBeSwept
  {
    uint48 _programStart = uint48(_start + 2 days);
    uint48 _duration = uint48(1 weeks);
    uint256 _amount = uint256(_duration); // 1 wei/sec
    uint256 _programId = _createProgram(_programStart, _amount, _duration);

    // The interval [_start, _start + 1 weeks) is priced from `_start + 1 weeks - 1`. The stake is still active
    // at program.start - 1, but has expired by that right-aligned reference.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 4 days));

    vm.warp(uint256(_programStart) + _duration);
    _token.mint(address(votingRewardsManager), 2 days); // make any over-sweep observable instead of reverting

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should not sweep the pre program slice
    assertEq(_creatorReceived, _amount);
  }

  function test_GivenLeadingAndTrailingPartialsHaveNoAlignedInterior() external whenTheProgramCanBeSwept {
    uint48 _programStart = uint48(_start + 1 days);
    uint48 _duration = uint48(1 weeks);
    uint48 _programEnd = _programStart + _duration;
    uint256 _amount = uint256(_duration); // 1 wei/sec
    uint256 _programId = _createProgram(_programStart, _amount, _duration);

    // The program starts inside [_start, _start + 1w) and ends inside [_start + 1w, _start + 2w), leaving no
    // full checkpoint-aligned interior interval. The voter is active at the leading partial's reference but
    // expired at the trailing partial's reference.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 7 days + 12 hours));
    vm.warp(uint256(_programEnd) + 1 days);

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should skip the aligned prefix delta
    // it should sweep only the trailing partial
    assertEq(_creatorReceived, uint256(1 days));

    uint256 _claimed = _claimAndReturnRecipientDelta(_programId);
    // it should conserve the deposited amount across claim and sweep
    assertEq(_claimed + _creatorReceived, _amount);
  }

  function test_GivenATrailingPartialHasSupplyAtTheRightAlignedReference() external whenTheProgramCanBeSwept {
    uint48 _duration = uint48(10 days);
    uint48 _programEnd = _start + _duration;
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_start, _amount, _duration);

    // The voter is active at program.end - 1, so the trailing partial is claimable. The stake expires before
    // the next week-boundary checkpoint, which would make a full-interval accumulator flat at the later
    // right-aligned reference if sweep did not clip its supply check to program.end - 1.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_programEnd + 1 days));
    vm.warp(_start + 2 weeks);
    _advance();

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should not sweep the trailing partial
    assertEq(_creatorReceived, 0);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _voterReceived = _token.balanceOf(_recipient);

    // it should leave the full amount claimable by the voter
    assertLe(_voterReceived, _amount);
    assertGe(_voterReceived, _amount - 1);
  }

  function test_GivenATrailingPartialHasZeroSupplyAtTheRightAlignedReference() external whenTheProgramCanBeSwept {
    uint48 _duration = uint48(10 days);
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_start, _amount, _duration);

    // The voter is active at the first week boundary reference but expired by program.end - 1. Since the
    // program ends before the next checkpoint, sweep must clip the supply check to program.end - 1 and
    // recover the whole trailing partial, not just the time after the voter expired.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 8 days));
    vm.warp(_start + 2 weeks);
    _advance();

    uint256 _creatorBefore = _token.balanceOf(_creator);
    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    uint256 _creatorReceived = _token.balanceOf(_creator) - _creatorBefore;

    // it should sweep only the trailing partial
    assertEq(_creatorReceived, uint256(3 days) * 1e18);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _voterReceived = _token.balanceOf(_recipient);

    // it should leave the right aligned positive prefix claimable by the voter
    uint256 _expectedClaim = uint256(7 days) * 1e18;
    assertLe(_voterReceived, _expectedClaim);
    assertGe(_voterReceived, _expectedClaim - 1);
  }

  function test_GivenTheProgramEndIsClippedBeforeTheNextCheckpoint() external whenTheProgramCanBeSwept {
    uint48 _duration = uint48(10 days);
    uint256 _amount = uint256(_duration) * 1e18;
    uint256 _programId = _createProgram(_start, _amount, _duration);

    // The program ends mid-interval, but sweep is called after a later checkpoint closes the whole week.
    // The creator must only recover the zero-supply tail inside the program window, not the extra four days
    // between program.end and the next checkpoint.
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_start + 2 weeks);
    _advance();

    uint256 _swept = _sweepAndReturnCreatorDelta(_programId);

    // it should sweep only through the program end
    assertEq(_swept, uint256(3 days) * 1e18);

    uint256 _claimed = _claimAndReturnRecipientDelta(_programId);
    uint256 _totalOut = _claimed + _swept;

    // it should conserve the deposited amount across claim and sweep
    assertLe(_totalOut, _amount);
    assertGe(_totalOut, _amount - 1);
  }

  function test_GivenTheSweptRewardIsTheWrappedNative() external whenTheProgramCanBeSwept {
    uint256 _programId = _createWethProgram(votingRewardsManager);
    vm.warp(_end);

    uint256 _balBefore = _weth.balanceOf(_creator);

    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveSwept(_programId, _creator, _TWO_WEEK_AMOUNT);

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);

    // it should transfer the wrapped native as an ERC20 token
    assertEq(_weth.balanceOf(_creator) - _balBefore, _TWO_WEEK_AMOUNT);
    // it should not send native token to the creator
    assertEq(_creator.balance, 0);
  }

  function testGas_sweep() external {
    uint256 _programId = _createTwoWeekProgram();
    vm.warp(_start);
    _checkpoint(_TOKEN_ID_A, uint128(MAX_TIME), uint48(_start + 1 weeks));
    vm.warp(_end);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_pending0, _pending1));

    vm.prank(_creator);
    votingRewardsManager.sweep(_programId);
    vm.snapshotGasLastCall('VotingRewardsManager_sweep');
  }
}
