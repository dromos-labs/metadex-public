// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerCreateIncentiveProgram is UnitVotingRewardsManager {
  uint256 internal constant _PRECISION = 1e18;
  uint256 internal constant _MIN_DURATION = 7 days;
  uint256 internal constant _MAX_DURATION = 365 days;
  uint256 internal constant _PROGRAM_AMOUNT = 100 ether;

  TestERC20 internal _token;
  address internal _creator = makeAddr('creator');

  function setUp() public override {
    super.setUp();
    _token = new TestERC20('Test Token', 'TT', 18);
    vm.prank(_creator);
    _token.approve(address(votingRewardsManager), type(uint256).max);
  }

  function test_WhenDurationIsLessThanTheMinimumDuration(uint256 _amount, uint48 _start, uint48 _duration) external {
    _duration = uint48(bound(_duration, 0, _MIN_DURATION - 1));

    // it should revert with InsufficientDuration
    vm.expectRevert(IIncentiveStreaming.InsufficientDuration.selector);

    votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
  }

  function test_WhenAmountIsLessThanDuration(uint256 _amount, uint48 _duration, uint48 _start) external {
    _duration = uint48(bound(_duration, _MIN_DURATION, _MAX_DURATION));
    _amount = bound(_amount, 0, _duration - 1);

    // it should revert with InsufficientAmount
    vm.expectRevert(IIncentiveStreaming.InsufficientAmount.selector);

    votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
  }

  function test_WhenStartIsInThePast(uint256 _amount, uint48 _duration, uint48 _start) external {
    vm.warp(_MAX_DURATION);
    _duration = uint48(bound(_duration, _MIN_DURATION, _MAX_DURATION));
    _amount = bound(_amount, _duration, type(uint256).max / _PRECISION);
    _start = uint48(bound(_start, 0, block.timestamp - 1));

    // it should revert with InvalidStart
    vm.expectRevert(IIncentiveStreaming.InvalidStart.selector);

    votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
  }

  function test_WhenTheTokenIsNotListed(uint256 _amount, uint48 _duration, uint48 _start) external {
    (_amount, _duration, _start) = _boundValidInputs(_amount, _duration, _start);
    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(false));

    // it should revert with NotListed
    vm.expectRevert(IIncentiveStreaming.NotListed.selector);

    votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
  }

  modifier whenTheParametersAreValid() {
    _;
  }

  modifier givenGlobalHistoryIsEmpty() {
    _;
  }

  function test_WhenTheProgramStartsImmediately() external whenTheParametersAreValid givenGlobalHistoryIsEmpty {
    uint48 _creationTs = uint48(block.timestamp);
    _createProgram(_creationTs);

    // it should initialize global history
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);

    IVotingCheckpoints.GlobalPoint memory _initialPoint = votingRewardsManager.globalRewardPointHistory(1);
    // it should timestamp the initial checkpoint at creation
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: _creationTs,
      _globalPoint: _initialPoint
    });
    // it should record zero supply in the initial checkpoint
    assertEq(_initialPoint.zeroSupplySeconds, 0);
  }

  function test_WhenTheProgramStartsInTheFuture() external whenTheParametersAreValid givenGlobalHistoryIsEmpty {
    uint48 _creationTs = uint48(block.timestamp);
    uint48 _start = _creationTs + uint48(4 weeks);
    uint256 _programId = _createProgram(_start);

    // it should initialize global history
    assertEq(votingRewardsManager.globalCheckpointIndex(), 1);

    IVotingCheckpoints.GlobalPoint memory _initialPoint = votingRewardsManager.globalRewardPointHistory(1);
    // it should timestamp the initial checkpoint at creation
    assertEq(_initialPoint.ts, _creationTs);
    // it should preserve the future program start
    assertEq(votingRewardsManager.incentive(_programId).start, _start);
  }

  modifier givenGlobalHistoryAlreadyExists() {
    _;
  }

  function test_WhenHistoryCannotReachTheCurrentTimestampWithinTheIterationLimit()
    external
    whenTheParametersAreValid
    givenGlobalHistoryAlreadyExists
  {
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1 ether, _stakeEnd: 0, _data: ''});

    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    uint256 _latestCheckpointTs = votingRewardsManager.globalRewardPointHistory(_globalIndex).ts;
    /// @dev Make history exceed the single-advance limit by one second
    vm.warp(ProtocolTimeLibrary.epochStart(_latestCheckpointTs) + MAX_CHECKPOINT_ITERATIONS * 1 weeks + 1);

    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, _PROGRAM_AMOUNT);

    // it should revert with StaleCheckpointHistory
    vm.expectRevert(IIncentiveStreaming.StaleCheckpointHistory.selector);
    vm.prank(_creator);
    votingRewardsManager.createIncentiveProgram({
      _token: address(_token),
      _amount: _PROGRAM_AMOUNT,
      _start: uint48(block.timestamp),
      _duration: uint48(_MIN_DURATION)
    });

    /// @dev Advance stale history so the current timestamp falls within the iteration limit
    votingRewardsManager.advanceGlobalPoints();

    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));

    vm.prank(_creator);
    uint256 _programId = votingRewardsManager.createIncentiveProgram({
      _token: address(_token),
      _amount: _PROGRAM_AMOUNT,
      _start: uint48(block.timestamp),
      _duration: uint48(_MIN_DURATION)
    });

    // it should allow program creation after history is advanced
    assertEq(_programId, 1);
    assertEq(votingRewardsManager.incentiveCount(), 1);
  }

  function test_WhenTheCurrentTimestampIsTheMaximumReachableTimestamp()
    external
    whenTheParametersAreValid
    givenGlobalHistoryAlreadyExists
  {
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1 ether, _stakeEnd: 0, _data: ''});

    uint256 _globalIndexBefore = votingRewardsManager.globalCheckpointIndex();
    IVotingCheckpoints.GlobalPoint memory _globalPointBefore =
      votingRewardsManager.globalRewardPointHistory(_globalIndexBefore);

    /// @dev Move to the maximum timestamp reachable within the iteration limit
    vm.warp(ProtocolTimeLibrary.epochStart(_globalPointBefore.ts) + MAX_CHECKPOINT_ITERATIONS * 1 weeks);
    uint256 _programId = _createProgram(uint48(block.timestamp));

    // it should create the incentive program
    assertEq(_programId, 1);
    assertEq(votingRewardsManager.incentiveCount(), 1);

    // it should not write a global checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndexBefore);
    assertEq(
      keccak256(abi.encode(votingRewardsManager.globalRewardPointHistory(_globalIndexBefore))),
      keccak256(abi.encode(_globalPointBefore))
    );
  }

  function test_WhenTheCurrentTimestampIsBeforeTheMaximumReachableTimestamp()
    external
    whenTheParametersAreValid
    givenGlobalHistoryAlreadyExists
  {
    vm.prank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 1 ether, _stakeEnd: 0, _data: ''});

    uint256 _globalIndexBefore = votingRewardsManager.globalCheckpointIndex();
    bytes32 _globalPointBefore =
      keccak256(abi.encode(votingRewardsManager.globalRewardPointHistory(_globalIndexBefore)));

    vm.warp(block.timestamp + 1 days);
    _createProgram(uint48(block.timestamp));

    // it should not write a global checkpoint
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndexBefore);
    assertEq(
      keccak256(abi.encode(votingRewardsManager.globalRewardPointHistory(_globalIndexBefore))), _globalPointBefore
    );
  }

  function test_GivenAnIncentiveProgramAlreadyExistsAndTimeHasAdvanced() external whenTheParametersAreValid {
    _createProgram(uint48(block.timestamp));

    uint256 _globalIndexBefore = votingRewardsManager.globalCheckpointIndex();
    bytes32 _globalPointBefore =
      keccak256(abi.encode(votingRewardsManager.globalRewardPointHistory(_globalIndexBefore)));

    vm.warp(block.timestamp + 1 days);
    _createProgram(uint48(block.timestamp));

    // it should not write a global checkpoint
    assertEq(votingRewardsManager.incentiveCount(), 2);
    assertEq(votingRewardsManager.globalCheckpointIndex(), _globalIndexBefore);
    assertEq(
      keccak256(abi.encode(votingRewardsManager.globalRewardPointHistory(_globalIndexBefore))), _globalPointBefore
    );
  }

  function test_WhenCreatingTheIncentiveProgram(
    uint256 _amount,
    uint48 _duration,
    uint48 _start
  ) external whenTheParametersAreValid {
    (_amount, _duration, _start) = _boundValidInputs(_amount, _duration, _start);
    uint256 _expectedProgramAmount = (((_amount * _PRECISION) / _duration) * _duration) / _PRECISION;
    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));

    _token.mint(_creator, _amount);

    // it should emit an IncentiveCreated event
    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveCreated({
      _programId: 1,
      _token: address(_token),
      _creator: _creator,
      _amount: _expectedProgramAmount,
      _start: _start,
      _duration: _duration
    });

    vm.prank(_creator);
    uint256 _programId = votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });

    // it should pull the calculated program amount from the caller
    assertEq(_token.balanceOf(address(votingRewardsManager)), _expectedProgramAmount);
    /// @dev Any rounding remainder stays with the program creator
    assertEq(_token.balanceOf(_creator), _amount - _expectedProgramAmount);

    // it should increment the incentive count
    assertEq(_programId, 1);
    assertEq(votingRewardsManager.incentiveCount(), 1);

    // it should store the program at the new id
    IIncentiveStreaming.IncentiveProgram memory _program = votingRewardsManager.incentive(_programId);
    assertEq(_program.token, address(_token));
    assertEq(_program.amount, _expectedProgramAmount);
    assertEq(_program.start, _start);
    assertEq(_program.creator, _creator);

    // it should initialize the remaining program balance
    assertEq(votingRewardsManager.remainingAmount(_programId), _expectedProgramAmount);

    // it should index the program by token
    assertEq(votingRewardsManager.incentiveCountByToken(address(_token)), 1);
    uint256[] memory _programIdsByToken = votingRewardsManager.incentivesByToken(address(_token), 0, 1);
    assertEq(_programIdsByToken.length, 1);
    assertEq(_programIdsByToken[0], _programId);

    // it should index the program by creator
    assertEq(votingRewardsManager.incentiveCountByCreator(_creator), 1);
    uint256[] memory _programIdsByCreator = votingRewardsManager.incentivesByCreator(_creator, 0, 1);
    assertEq(_programIdsByCreator.length, 1);
    assertEq(_programIdsByCreator[0], _programId);

    // it should register the token in the rewards list (in addition to the 2 initial fee tokens)
    assertEq(votingRewardsManager.rewardsListLength(), 3);
    assertTrue(votingRewardsManager.isReward(address(_token)));
    assertEq(votingRewardsManager.rewards(2), address(_token));
  }

  function test_WhenStreamingAKnownAmountOverAKnownDuration() external {
    // inputs: 5_000_000 tokens streamed over 1_000_000 seconds.
    // rate = 5_000_000 * 1e18 / 1_000_000 = 5e18 (tokens per second, scaled by PRECISION).
    uint256 _amount = 5_000_000;
    uint48 _duration = 1_000_000;
    uint48 _start = uint48(block.timestamp);
    uint256 _expectedRate = 5e18;
    uint48 _expectedEnd = _start + _duration;

    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, _amount);

    vm.prank(_creator);
    uint256 _programId = votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });

    IIncentiveStreaming.IncentiveProgram memory _program = votingRewardsManager.incentive(_programId);
    // it should store the computed rate
    assertEq(_program.rate, _expectedRate);
    // it should store the computed end
    assertEq(_program.end, _expectedEnd);
    // it should initialize the remaining program balance
    assertEq(votingRewardsManager.remainingAmount(_programId), _amount);
  }

  function test_WhenRateRoundingReducesTheProgramAmount() external {
    uint256 _amount = 604_801;
    uint48 _duration = uint48(7 days);
    uint48 _start = uint48(block.timestamp);
    uint256 _expectedProgramAmount = 604_800;

    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, _amount);

    // it should emit the IncentiveCreated event
    _expectEmit(address(votingRewardsManager));
    emit IIncentiveStreaming.IncentiveCreated({
      _programId: 1,
      _token: address(_token),
      _creator: _creator,
      _amount: _expectedProgramAmount,
      _start: _start,
      _duration: _duration
    });

    vm.prank(_creator);
    uint256 _programId = votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });

    // it should pull the rounded program amount from the caller
    assertEq(_token.balanceOf(address(votingRewardsManager)), _expectedProgramAmount);
    // it should leave the rounding remainder with the creator
    assertEq(_token.balanceOf(_creator), 1);

    // it should store the rounded program amount
    assertEq(votingRewardsManager.incentive(_programId).amount, _expectedProgramAmount);
    // it should initialize the remaining program balance
    assertEq(votingRewardsManager.remainingAmount(_programId), _expectedProgramAmount);
  }

  function testGas_CreateIncentiveProgram() external {
    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));

    uint256 _amount = 100 ether;
    uint48 _duration = uint48(7 days);
    uint48 _start = uint48(block.timestamp);

    _token.mint(_creator, _amount);

    vm.prank(_creator);
    votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _amount, _start: _start, _duration: _duration
    });
    vm.snapshotGasLastCall('VotingRewardsManager_createIncentiveProgram');
  }

  function _boundValidInputs(
    uint256 _amount,
    uint48 _duration,
    uint48 _start
  ) internal view returns (uint256, uint48, uint48) {
    _duration = uint48(bound(_duration, _MIN_DURATION, _MAX_DURATION));
    _start = uint48(bound(_start, block.timestamp, uint256(type(uint48).max) - _duration));
    _amount = bound(_amount, _duration, type(uint256).max / _PRECISION);
    return (_amount, _duration, _start);
  }

  function _createProgram(uint48 _start) internal returns (uint256 _programId) {
    _mockAndExpect(_TOKEN_REGISTRY, abi.encodeCall(ITokenRegistry.isListed, (address(_token))), abi.encode(true));
    _token.mint(_creator, _PROGRAM_AMOUNT);

    vm.prank(_creator);
    _programId = votingRewardsManager.createIncentiveProgram({
      _token: address(_token), _amount: _PROGRAM_AMOUNT, _start: _start, _duration: uint48(_MIN_DURATION)
    });
  }
}
