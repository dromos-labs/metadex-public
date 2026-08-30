// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerEarnedIncentives is UnitVotingRewardsManager {
  // Program uses amount = duration * 1e18 so the rate is exactly 1e18 token/s (no rounding dust).
  uint256 internal constant _28D_AMOUNT = 2_419_200e18;
  uint48 internal constant _28D_DURATION = 28 days;
  // One full closed week of the stream at the rate above.
  uint256 internal constant _WEEK_STREAM = 604_800e18;
  // 1T AERO is the voting-power ceiling used by the incentive reward fuzz ranges.
  uint128 internal constant _MAX_VOTING_POWER = 1_000_000_000_000e18;

  address internal _recipient = makeAddr('recipient');
  address internal _creator = makeAddr('creator');

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

  function _earnedAll(uint256 _tokenId, uint256 _programId) internal view returns (uint256) {
    return votingRewardsManager.earnedIncentives(_tokenId, _programId, type(uint256).max);
  }

  function test_GivenTheProgramHasNotStarted(uint128 _allocated, uint48 _startOffset) external {
    _allocated = uint128(bound(_allocated, 1, _MAX_VOTING_POWER));
    _startOffset = uint48(bound(_startOffset, 1, 52 weeks));
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocated, _stakeEnd: 0, _data: ''});
    uint256 _programId = _createProgram(uint48(block.timestamp + _startOffset), _28D_AMOUNT, _28D_DURATION);

    // it should return zero
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 0);
  }

  function test_GivenTheVeNFTNeverVoted(uint48 _duration) external {
    _duration = uint48(bound(_duration, 1 weeks, 4 weeks));
    uint256 _amount = uint256(_duration) * 1e18;
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(block.timestamp), _amount, _duration);
    vm.warp(uint256(1 weeks) + uint256(_duration) + 1);

    // it should return zero
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 0);
  }

  function test_GivenAnotherVeNFTCreatedGlobalCheckpoints() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    vm.warp(uint256(1 weeks) + 3 days);

    // it should return zero for a veNFT with no checkpoint
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 0);
  }

  function test_GivenTheCheckpointLimitIsZero() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _advance();
    vm.warp(uint256(2 weeks) + 3 days);

    // it should return zero
    assertEq(votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programId, 0), 0);
  }

  function test_GivenOnlyClosedIntervalsExist() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    // close three full weeks: intervals [1w,2w], [2w,3w], [3w,4w]
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();
    vm.warp(4 weeks);
    _advance();

    // it should return the closed interval rewards
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 3 * _WEEK_STREAM);
  }

  function test_GivenTheOpenIntervalIsNotYetClosed() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    // close two weeks; the latest global checkpoint is at 3w
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    // three days into the open interval, without advancing
    vm.warp(uint256(3 weeks) + 3 days);

    // it should include the estimated open interval
    uint256 _earned = _earnedAll(_TOKEN_ID_A, _programId);
    assertEq(_earned, 2 * _WEEK_STREAM + 259_200e18);

    // a claim closes the stale open interval and pays the same estimated tail
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _claimed = _token.balanceOf(_recipient);
    assertEq(_claimed, 2 * _WEEK_STREAM + 259_200e18);
    assertEq(_earned, _claimed);
  }

  function test_GivenAnOpenIntervalBeforeTheProgramStarts() external {
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION);

    vm.warp(uint256(1 weeks) + 3 days);

    // it should return zero
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 0);
  }

  function test_GivenTheProgramStartsInsideTheOpenInterval() external {
    vm.warp(1 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    uint256 _programId = _createProgram(uint48(uint256(1 weeks) + 2 days), _28D_AMOUNT, _28D_DURATION);

    vm.warp(uint256(1 weeks) + 5 days);

    // it should estimate only after the program starts
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 259_200e18);
  }

  function test_GivenTheProgramEndedBeforeTheLatestGlobalCheckpoint() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _WEEK_STREAM, uint48(1 weeks));
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    // it should return only the program rewards
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _WEEK_STREAM);
  }

  function test_GivenTheOpenIntervalCrossesAWeekBoundary() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    vm.warp(uint256(4 weeks) + 2 days);

    // it should estimate the full unsettled interval
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 3 * _WEEK_STREAM + 172_800e18);
  }

  function test_GivenTheOpenIntervalExceedsTheCheckpointIterationLimit() external {
    vm.warp(1 weeks);
    uint48 _start = uint48(block.timestamp);
    uint48 _duration = uint48((MAX_CHECKPOINT_ITERATIONS + 1) * 1 weeks);
    uint256 _programId = _createProgram(_start, _duration, _duration);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    /// @dev Make the open interval exceed the checkpoint iteration limit by one second
    vm.warp(ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks + 1);

    // it should return the full pending estimate
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), block.timestamp - _start);
  }

  function test_GivenTheLatestGlobalCheckpointIsMidWeek(
    uint48 _checkpointOffset,
    uint48 _queryOffset,
    uint48 _programStartOffset,
    uint48 _duration
  ) external {
    _checkpointOffset = uint48(bound(_checkpointOffset, 1, 6 days));
    _queryOffset = uint48(bound(_queryOffset, 1, 6 days));
    _programStartOffset = uint48(bound(_programStartOffset, 0, _checkpointOffset));
    uint256 _programStart = uint256(2 weeks) + _programStartOffset;
    uint256 _minDuration = uint256(3 weeks) + 1 - _programStart;
    if (_minDuration < 7 days) _minDuration = 7 days;
    _duration = uint48(bound(_duration, _minDuration, _28D_DURATION));

    uint256 _midWeekCheckpoint = uint256(2 weeks) + _checkpointOffset;
    uint256 _queryTimestamp = uint256(3 weeks) + _queryOffset;
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(_programStart), uint256(_duration) * 1e18, _duration);

    vm.warp(_midWeekCheckpoint);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.globalRewardPointHistory(2).ts, _midWeekCheckpoint);

    vm.warp(_queryTimestamp);
    uint256 _earned = _earnedAll(_TOKEN_ID_A, _programId);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    // it should match a later claim across the next week boundary
    uint256 _programEnd = _programStart + _duration;
    uint256 _effectiveEnd = _programEnd < _queryTimestamp ? _programEnd : _queryTimestamp;
    assertEq(_earned, (_effectiveEnd - _midWeekCheckpoint) * 1e18);
    assertEq(_token.balanceOf(_recipient), _earned);
  }

  function test_GivenADecayingOpenIntervalStartsFromAMidWeekGlobalCheckpoint(
    uint48 _checkpointOffset,
    uint48 _queryWeekCount,
    uint48 _queryOffset,
    uint48 _programStartOffset,
    uint48 _duration
  ) external {
    _checkpointOffset = uint48(bound(_checkpointOffset, 1, 6 days));
    _queryWeekCount = uint48(bound(_queryWeekCount, 2, 3));
    _queryOffset = uint48(bound(_queryOffset, 1, 6 days));
    _programStartOffset = uint48(bound(_programStartOffset, 0, _checkpointOffset));
    uint256 _programStart = uint256(2 weeks) + _programStartOffset;
    uint256 _minDuration = uint256(4 weeks) + 1 - _programStart;
    if (_minDuration < 7 days) _minDuration = 7 days;
    _duration = uint48(bound(_duration, _minDuration, _28D_DURATION));

    uint256 _midWeekCheckpoint = uint256(2 weeks) + _checkpointOffset;
    uint256 _queryTimestamp = uint256(2 weeks) + uint256(_queryWeekCount) * 1 weeks + _queryOffset;
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(_programStart), uint256(_duration) * 1e18, _duration);

    vm.warp(_midWeekCheckpoint);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: uint128(MAX_TIME), _stakeEnd: uint48(8 weeks), _data: ''
    });
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: 3_628_800, _stakeEnd: 0, _data: ''});
    assertEq(votingRewardsManager.globalRewardPointHistory(2).ts, _midWeekCheckpoint);

    vm.warp(_queryTimestamp);
    uint256 _estimatedEarned = _earnedAll(_TOKEN_ID_A, _programId);

    uint256 _programEnd = _programStart + _duration;
    uint256 _effectiveEnd = _programEnd < _queryTimestamp ? _programEnd : _queryTimestamp;
    uint256 _expectedWeight = uint256(8 weeks) - _effectiveEnd + 1;
    uint256 _expectedSupply = _expectedWeight + 3_628_800;
    uint256 _unsettledReward = (_effectiveEnd - _midWeekCheckpoint) * 1e18;
    uint256 _expectedReward = _unsettledReward * _expectedWeight / _expectedSupply;

    // it should estimate rewards using the weight share at the end of the interval
    assertGt(_estimatedEarned, 0);
    assertEq(_estimatedEarned, _expectedReward);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    assertGe(votingRewardsManager.globalCheckpointIndex(), 4);

    /// @dev Skipping intermediate checkpoints applies the lower ending weight to earlier weeks
    // it should be lower than a claim at the same timestamp
    assertLt(_estimatedEarned, _token.balanceOf(_recipient));
  }

  function test_GivenABoundedReadOverMultipleUserCheckpoints(uint256 _maxCheckpoints) external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    // three user checkpoints, each a one-week span: cp1 [1w,2w], cp2 [2w,3w], cp3 [3w,...]
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(3 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(4 weeks);
    _advance();
    vm.warp(5 weeks);
    _advance();

    _maxCheckpoints = bound(_maxCheckpoints, 1, 2);

    // it should return only the bounded user checkpoints (each a full closed week)
    assertEq(
      votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programId, _maxCheckpoints), _maxCheckpoints * _WEEK_STREAM
    );
  }

  function test_GivenABoundedReadStopsBeforeTheLatestUserCheckpoint() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(3 weeks);
    _advance();

    vm.warp(uint256(3 weeks) + 3 days);

    // it should exclude the open interval
    assertEq(votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programId, 1), _WEEK_STREAM);
  }

  function test_GivenABoundedReadReachesTheLatestUserCheckpoint() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(3 weeks);
    _advance();

    vm.warp(uint256(3 weeks) + 3 days);

    // it should include the estimated open interval
    assertEq(votingRewardsManager.earnedIncentives(_TOKEN_ID_A, _programId, 2), 2 * _WEEK_STREAM + 259_200e18);
  }

  function test_GivenTheProgramEndsInsideTheOpenInterval() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _WEEK_STREAM, uint48(1 weeks));
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    vm.warp(uint256(2 weeks) + 3 days);

    // it should estimate only through the program end
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _WEEK_STREAM);
  }

  function test_GivenANonPermanentDecayingLock(uint128 _allocated) external {
    // sole decaying voter outliving the priced intervals: VP == supply at every ref, so each closed
    // week pays the full stream regardless of decay
    _allocated = uint128(bound(_allocated, uint256(MAX_TIME), _MAX_VOTING_POWER));
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _allocated, _stakeEnd: uint48(8 weeks), _data: ''
    });

    // close two weeks
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    // it should return the decayed voting power share of closed intervals
    assertLe(_earnedAll(_TOKEN_ID_A, _programId), 2 * _WEEK_STREAM);
    assertApproxEqRel(_earnedAll(_TOKEN_ID_A, _programId), 2 * _WEEK_STREAM, 1e6);
  }

  function test_GivenADecayingLockAlongsideAPermanentLock(uint128 _allocated) external {
    // equal initial voting power: A permanent (constant), B decaying. The first closed week splits evenly,
    // but from the second week on B's voting power has decayed, so it must earn strictly less than A
    _allocated = uint128(bound(_allocated, uint256(MAX_TIME), _MAX_VOTING_POWER));
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _allocated, _stakeEnd: 0, _data: ''});
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_B, _allocated: _allocated, _stakeEnd: uint48(8 weeks), _data: ''
    });

    // close two weeks
    vm.warp(2 weeks);
    _advance();
    vm.warp(3 weeks);
    _advance();

    uint256 _earnedPermanent = _earnedAll(_TOKEN_ID_A, _programId);
    uint256 _earnedDecaying = _earnedAll(_TOKEN_ID_B, _programId);

    // it should earn less than the permanent lock as its voting power decays
    assertLt(_earnedDecaying, _earnedPermanent);
    // both share supply every interval, so together they receive the full closed stream
    assertLe(_earnedPermanent + _earnedDecaying, 2 * _WEEK_STREAM);
    assertApproxEqRel(_earnedPermanent + _earnedDecaying, 2 * _WEEK_STREAM, 1e6);
  }

  function test_GivenADecayingLockAlongsideAPermanentLockInTheOpenInterval() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: uint128(MAX_TIME), _stakeEnd: uint48(6 weeks), _data: ''
    });
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: 3_628_800, _stakeEnd: 0, _data: ''});

    vm.warp(3 weeks);
    _advance();

    uint256 _closedEarned = _earnedAll(_TOKEN_ID_A, _programId);
    vm.warp(uint256(3 weeks) + 1 days);
    uint256 _estimatedEarned = _earnedAll(_TOKEN_ID_A, _programId);

    /// @dev The open-day estimate uses A's weight and total supply at block.timestamp - 1
    uint256 _endingWeight = uint256(6 weeks) - block.timestamp + 1;
    uint256 _endingSupply = _endingWeight + 3_628_800;

    // it should estimate the decaying share
    assertGt(_estimatedEarned, _closedEarned);
    /// @dev The unsettled reward is one day of streaming multiplied by A's ending share of supply
    assertEq(_estimatedEarned - _closedEarned, (_WEEK_STREAM / 7) * _endingWeight / _endingSupply);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);

    // it should match a later claim approximately
    assertApproxEqAbs(_estimatedEarned, _token.balanceOf(_recipient), 1);
  }

  function test_GivenADecayingLockExpiresInsideTheOpenInterval() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION);
    uint128 _permanentWeight = 1_209_600;
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: uint128(MAX_TIME), _stakeEnd: uint48(4 weeks), _data: ''
    });
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _permanentWeight, _stakeEnd: 0, _data: ''});

    vm.warp(3 weeks);
    _advance();
    vm.warp(uint256(4 weeks) + 1 days);

    // Right-aligned ref for [2w,3w] samples A=604_801 of total 1_814_401.
    uint256 _expectedClosedReward = _WEEK_STREAM * 604_801 / 1_814_401;
    uint256 _earned = _earnedAll(_TOKEN_ID_A, _programId);

    // it should return only closed rewards
    assertEq(_earned, _expectedClosedReward);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _claimed = _token.balanceOf(_recipient);

    /// @dev At 4 weeks - 1, expiring A has 1 weight while B retains its permanent weight
    assertEq(_claimed, _expectedClosedReward + _WEEK_STREAM / (_permanentWeight + 1));

    /// @dev Using the zero weight at the interval end for the whole open interval omits incentives earned before expiry
    // it should be lower than a claim at the same timestamp
    assertLt(_earned, _claimed);
  }

  function test_GivenAnotherDecayingLockExpiresInsideTheOpenInterval() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});

    /// @dev The competing lock expires during the open interval with 1e18 weight in its final second
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_B, _allocated: uint128(MAX_TIME) * 1e18, _stakeEnd: uint48(4 weeks), _data: ''
    });

    vm.warp(3 weeks);
    _advance();
    vm.warp(uint256(4 weeks) + 1 days);

    /// @dev At 3 weeks - 1, A has 1e18 weight and B has 604_801e18, so A owns 1 of 604_802 total units
    uint256 _expectedClosedReward = _WEEK_STREAM / 604_802;
    uint256 _dayStream = _WEEK_STREAM / 7;
    uint256 _estimatedEarned = _earnedAll(_TOKEN_ID_A, _programId);

    // it should estimate rewards using the weight share at the end of the interval
    assertEq(_estimatedEarned, _expectedClosedReward + _WEEK_STREAM + _dayStream);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    uint256 _claimed = _token.balanceOf(_recipient);

    /// @dev For [3w,4w], both locks have 1e18 weight at 4w - 1, so A receives half the week,
    ///      followed by the full day after B expires
    assertEq(_claimed, _expectedClosedReward + _WEEK_STREAM / 2 + _dayStream);

    /// @dev Using the larger ending share for the whole open interval ignores the other lock's weight before expiry
    // it should be higher than a claim at the same timestamp
    assertGt(_estimatedEarned, _claimed);
  }

  function test_GivenADecayingLockExpiredBeforeTheOpenInterval() external {
    vm.warp(2 weeks);
    uint256 _programId = _createProgram(uint48(2 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: uint128(MAX_TIME), _stakeEnd: uint48(3 weeks), _data: ''
    });

    vm.warp(3 weeks);
    _advance();
    vm.warp(uint256(3 weeks) + 1 days);

    // it should ignore the open interval after expiry
    uint256 _earned = _earnedAll(_TOKEN_ID_A, _programId);
    assertEq(_earned, _WEEK_STREAM);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    assertEq(_token.balanceOf(_recipient), _earned);
  }

  function test_GivenTheLatestUserCheckpointIsReset() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    _advance();
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    vm.warp(uint256(2 weeks) + 3 days);

    // it should ignore the open interval
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), _WEEK_STREAM);
  }

  function test_GivenRewardsWereAlreadyPartiallyClaimed() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    // three user checkpoints over the 4-week program: cp1 [1w,2w], cp2 [2w,3w], cp3 [3w,5w]
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(3 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(4 weeks);
    _advance();
    vm.warp(5 weeks);
    _advance();

    // claim only the first user checkpoint
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);
    assertEq(_token.balanceOf(_recipient), _WEEK_STREAM);

    // it should return only the remaining closed rewards: cp2 [2w,3w] + cp3 [3w,5w] = 3 weeks
    assertEq(_earnedAll(_TOKEN_ID_A, _programId), 3 * _WEEK_STREAM);
  }

  function test_GivenRewardsWereAlreadyPartiallyClaimedWithAStaleOpenInterval() external {
    vm.warp(1 weeks);
    uint256 _programId = _createProgram(uint48(1 weeks), _28D_AMOUNT, _28D_DURATION);
    // two user checkpoints: cp1 [1w,2w], cp2 [2w, tip]
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(2 weeks);
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1e18, _stakeEnd: 0, _data: ''});
    vm.warp(3 weeks);
    _advance();
    vm.warp(uint256(3 weeks) + 3 days);

    // Claim only the first user checkpoint, leaving one closed week plus the open interval pending.
    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, 1);
    uint256 _claimed = _token.balanceOf(_recipient);
    assertEq(_claimed, _WEEK_STREAM);

    // it should return remaining rewards including the open interval
    uint256 _earned = _earnedAll(_TOKEN_ID_A, _programId);
    assertEq(_earned, _WEEK_STREAM + 259_200e18);

    vm.prank(_VOTER);
    votingRewardsManager.claimIncentives(_TOKEN_ID_A, _recipient, _programId, type(uint256).max);
    assertEq(_token.balanceOf(_recipient) - _claimed, _earned);
  }
}
