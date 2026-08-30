// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

/**
 * @notice Tests the public `checkpoint` entry point of `VotingRewardsManager`.
 * @dev The `checkpoint` logic is covered across multiple test suites:
 *      - This suite verifies only dispatch behavior, ensuring the call is routed to:
 *          - `_reset` when the allocated weight is zero or the stake has expired.
 *          - `_checkpoint` otherwise.
 *      - `_checkpoint/` covers the internal checkpoint mechanics.
 *      - `_reset/` covers the internal reset mechanics.
 *
 *      The implementation details of each internal path are tested separately
 *      under `_checkpoint/` and `_reset/`.
 */
contract UnitConcreteVotingRewardsManagerCheckpoint is UnitVotingRewardsManager {
  function test_WhenTheCallerIsNotTheVoter() external {
    // it should revert with NotVoter
    vm.expectRevert(IVotingRewardsManager.NotVoter.selector);
    vm.prank(users.charlie);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});
  }

  modifier whenTheCallerIsTheVoter() {
    vm.startPrank(_VOTER);
    _;
  }

  function test_WhenTheAllocatedWeightsAreZero() external whenTheCallerIsTheVoter {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _initialWeight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // @dev Record a prior allocation so the reset has weight to clear
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _initialWeight, _stakeEnd: _stakeEnd, _data: ''
    });

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: 0, _stakeEnd: 0, _data: ''});

    // it should clear the veNFT's allocation
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.supplyAt(block.timestamp), 0);
  }

  modifier whenTheAllocatedWeightsAreNotZero() {
    _;
  }

  function test_WhenTheStakeIsPermanent() external whenTheCallerIsTheVoter whenTheAllocatedWeightsAreNotZero {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint128 _weight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: 0, _data: ''});

    // it should record the veNFT's allocation
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: _weight,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: _weight,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.permanentStakeBalance(), _weight);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), _weight);
    assertEq(votingRewardsManager.supplyAt(block.timestamp), _weight);
  }

  modifier whenTheStakeIsNotPermanent() {
    _;
  }

  function test_WhenTheStakeHasExpired()
    external
    whenTheCallerIsTheVoter
    whenTheAllocatedWeightsAreNotZero
    whenTheStakeIsNotPermanent
  {
    uint48 _ts = uint48(block.timestamp + 20 weeks);
    // @dev Non-permanent stake that expires before arrival
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts - 10 weeks));
    uint128 _weight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // it should clear the veNFT's allocation
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.supplyAt(block.timestamp), 0);
  }

  modifier whenTheStakeHasNotExpired() {
    _;
  }

  function test_WhenTheAllocationIsBelowTheMinimum()
    external
    whenTheCallerIsTheVoter
    whenTheAllocatedWeightsAreNotZero
    whenTheStakeIsNotPermanent
    whenTheStakeHasNotExpired
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _initialWeight = uint128(1000 * TOKEN_1);
    // @dev An allocation below `MAX_TIME` rounds down to a zero slope, so it carries no voting weight
    uint128 _weight = uint128(MAX_TIME - 1);

    vm.warp(_ts);

    // @dev Record a prior allocation so the reset has weight to clear
    votingRewardsManager.checkpoint({
      _tokenId: _TOKEN_ID_A, _allocated: _initialWeight, _stakeEnd: _stakeEnd, _data: ''
    });

    // it should emit the Reset event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Reset(_VOTER, _TOKEN_ID_A);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // it should clear the veNFT's allocation
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 1);
    _assertUserPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: 0,
      _expectedSlope: 0,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
    assertEq(votingRewardsManager.supplyAt(block.timestamp), 0);
  }

  modifier whenTheAllocationIsAtOrAboveTheMinimum() {
    _;
  }

  function test_WhenTheGaugeHasPendingFees()
    external
    whenTheCallerIsTheVoter
    whenTheAllocatedWeightsAreNotZero
    whenTheStakeIsNotPermanent
    whenTheStakeHasNotExpired
    whenTheAllocationIsAtOrAboveTheMinimum
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _weight = uint128(1000 * TOKEN_1);
    uint128 _totalSupply = uint128(1000 * TOKEN_1);
    uint256 _pending0 = 5 * TOKEN_1;
    uint256 _pending1 = 7 * TOKEN_1;

    // @dev Record a permanent stake one second early so totalSupply is non-zero and the same-timestamp guard is bypassed
    vm.warp(_ts - 1);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _totalSupply, _stakeEnd: 0, _data: ''});

    vm.warp(_ts);
    // @dev Simulate gauge fees to be credited on the next checkpoint
    _mockGaugePendingFees(_pending0, _pending1);

    // it should emit the NotifyFeesAmount event
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN0, _pending0);
    _expectEmit(address(votingRewardsManager));
    emit IFeeDistribution.NotifyFeesAmount(_GAUGE, _TOKEN1, _pending1);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // it should credit the pending fees to the accumulator
    // @dev totalSupply at credit time is the permanent _totalSupply
    _assertFeeAccumulator(
      _pending0 * FEE_ACCUMULATOR_PRECISION / _totalSupply,
      _pending1 * FEE_ACCUMULATOR_PRECISION / _totalSupply,
      _pending0 * FEE_ACCUMULATOR_PRECISION / _totalSupply * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _pending1 * FEE_ACCUMULATOR_PRECISION / _totalSupply * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );

    // it should record the veNFT's allocation
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEnd - _ts)
    int128 _bias = 249_315_060_565_698_077_659;
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 2);
    _assertUserPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: _totalSupply,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(_totalSupply) + uint256(uint128(_bias)));

    // it should snapshot the credited accumulator at the new global checkpoint index
    _assertFeeSnapshot(
      _globalIndex,
      _pending0 * FEE_ACCUMULATOR_PRECISION / _totalSupply,
      _pending1 * FEE_ACCUMULATOR_PRECISION / _totalSupply,
      _pending0 * FEE_ACCUMULATOR_PRECISION / _totalSupply * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN()),
      _pending1 * FEE_ACCUMULATOR_PRECISION / _totalSupply * (_ts - votingRewardsManager.ACCUMULATOR_ORIGIN())
    );
  }

  function test_WhenTheGaugeHasNoPendingFees()
    external
    whenTheCallerIsTheVoter
    whenTheAllocatedWeightsAreNotZero
    whenTheStakeIsNotPermanent
    whenTheStakeHasNotExpired
    whenTheAllocationIsAtOrAboveTheMinimum
  {
    uint48 _ts = uint48(block.timestamp + 1 weeks);
    uint48 _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_ts + 52 weeks));
    uint128 _weight = uint128(1000 * TOKEN_1);

    vm.warp(_ts);

    // it should emit the Checkpoint event
    _expectEmit(address(votingRewardsManager));
    emit IVotingCheckpoints.Checkpoint(_VOTER, _TOKEN_ID_A, _weight);

    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weight, _stakeEnd: _stakeEnd, _data: ''});

    // it should not credit any fees to the accumulator
    _assertFeeAccumulator(0, 0, 0, 0);

    // it should record the veNFT's allocation
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored)
    int128 _slope = 7_927_447_995_941;
    // @dev bias = slope * (stakeEnd - _ts)
    int128 _bias = 249_315_060_565_698_077_659;
    uint256 _userIndex = votingRewardsManager.userRewardCheckpointIndex(_TOKEN_ID_A);
    uint256 _globalIndex = votingRewardsManager.globalCheckpointIndex();
    assertEq(_userIndex, 1);
    assertEq(_globalIndex, 1);
    _assertUserPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanent: 0,
      _expectedTs: block.timestamp,
      _userPoint: votingRewardsManager.userRewardPointHistory(_TOKEN_ID_A, _userIndex)
    });
    _assertGlobalPoint({
      _expectedBias: _bias,
      _expectedSlope: _slope,
      _expectedPermanentLockBalance: 0,
      _expectedTs: block.timestamp,
      _globalPoint: votingRewardsManager.globalRewardPointHistory(_globalIndex)
    });
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), uint256(uint128(_bias)));
    assertEq(votingRewardsManager.supplyAt(block.timestamp), uint256(uint128(_bias)));

    // it should snapshot the unchanged accumulator at the new global checkpoint index
    _assertFeeSnapshot(_globalIndex, 0, 0, 0, 0);
  }
}
