// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitConcreteVotingRewardsManagerBalanceOfNFTAt is UnitVotingRewardsManager {
  /// @dev State seeded by `whenThereAreUserCheckpoints`
  uint48 internal _checkpointTs;
  uint128 internal _weightA;
  uint128 internal _weightB;
  uint48 internal _stakeEnd;

  function test_WhenThereAreNoUserCheckpoints() external view {
    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, block.timestamp), 0);
  }

  modifier whenThereAreUserCheckpoints() {
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    vm.warp(_checkpointTs);

    // @dev TOKEN_ID_A is a non-permanent stake expiring 52 weeks out; TOKEN_ID_B is permanent
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    _weightA = uint128(1000 * TOKEN_1);
    _weightB = uint128(500 * TOKEN_1);

    /// @dev Simulate checkpoints for non-permanent and permanent locks
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    _;
  }

  function test_WhenThereIsNoCheckpointAtOrBeforeTheTimestamp() external whenThereAreUserCheckpoints {
    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs - 1), 0);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _checkpointTs - 1), 0);
  }

  modifier whenThereIsACheckpointAtOrBeforeTheTimestamp() {
    _;
  }

  function test_WhenTheStakeIsPermanent()
    external
    whenThereAreUserCheckpoints
    whenThereIsACheckpointAtOrBeforeTheTimestamp
  {
    uint48 _ts = _checkpointTs + 10 weeks;

    // it should return the permanent balance
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _ts), _weightB);
  }

  modifier whenTheStakeIsNotPermanent() {
    _;
  }

  function test_WhenTheTimestampMatchesTheCheckpointTimestamp()
    external
    whenThereAreUserCheckpoints
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
  {
    // it should return the recorded bias
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored) = 7_927_447_995_941
    // @dev bias at _checkpointTs = slope * (stakeEnd - _checkpointTs), 52 weeks minus 1 day of decay
    uint256 _expectedBias = 248_630_136_986_296_771_200;
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), _expectedBias);
  }

  modifier whenTheTimestampDoesNotMatchTheCheckpointTimestamp() {
    _;
  }

  function test_WhenTheStakeHasExpired()
    external
    whenThereAreUserCheckpoints
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _stakeEnd), 0);
  }

  function test_WhenTheStakeHasNotExpired()
    external
    whenThereAreUserCheckpoints
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // @dev Read 26 weeks before the stake end so the stake is active and decay is clean
    uint48 _ts = _stakeEnd - 26 weeks;

    // it should return the decayed bias based on the veNFT slope
    // @dev slope = 1_000 * TOKEN_1 / MAX_TIME (floored) = 7_927_447_995_941
    // @dev bias at _ts = slope * (stakeEnd - _ts) = slope * 26 weeks
    uint256 _expectedBias = 124_657_534_246_573_036_800;
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _ts), _expectedBias);
  }
}
