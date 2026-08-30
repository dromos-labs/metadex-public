// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitFuzzVotingRewardsManagerBalanceOfNFTAt is UnitFuzzVotingRewardsManager {
  using SafeCastLibrary for uint256;
  using SafeCastLibrary for int128;

  /// @dev State seeded by `whenThereAreUserCheckpoints`
  uint48 internal _checkpointTs;
  uint120 internal _weightA;
  uint120 internal _weightB;
  uint48 internal _stakeEnd;
  int128 internal _slope;

  function testFuzz_WhenThereAreNoUserCheckpoints(uint256 _tokenId, uint48 _timestamp) external view {
    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_tokenId, _timestamp), 0);
  }

  modifier whenThereAreUserCheckpoints(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration
  ) {
    _checkpointTs = uint48(bound(_cpTs, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks));
    vm.warp(_checkpointTs);

    uint256 _duration = bound(_stakeDuration, 2 weeks, MAX_TIME);
    _stakeEnd = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + _duration));
    _weightA = uint120(bound(_weightStakeA, MAX_TIME, type(uint120).max));
    (, _slope) = _contribution(_weightA, _stakeEnd, _checkpointTs);
    _weightB = uint120(bound(_weightStakeB, 1, type(uint120).max));

    /// @dev Simulate checkpoints for non-permanent and permanent locks
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEnd, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: 0, _data: ''});
    _;
  }

  function testFuzz_WhenThereIsNoCheckpointAtOrBeforeTheTimestamp(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration,
    uint48 _ts
  ) external whenThereAreUserCheckpoints(_cpTs, _weightStakeA, _weightStakeB, _stakeDuration) {
    _ts = uint48(bound(_ts, 0, _checkpointTs - 1));

    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _ts), 0);
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _ts), 0);
  }

  modifier whenThereIsACheckpointAtOrBeforeTheTimestamp() {
    _;
  }

  function testFuzz_WhenTheStakeIsPermanent(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration,
    uint48 _ts
  )
    external
    whenThereAreUserCheckpoints(_cpTs, _weightStakeA, _weightStakeB, _stakeDuration)
    whenThereIsACheckpointAtOrBeforeTheTimestamp
  {
    _ts = uint48(bound(_ts, _checkpointTs, _checkpointTs + MAX_CHECKPOINT_ITERATIONS * 1 weeks));

    // it should return the permanent balance
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_B, _ts), _weightB);
  }

  modifier whenTheStakeIsNotPermanent() {
    _;
  }

  function testFuzz_WhenTheTimestampMatchesTheCheckpointTimestamp(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration
  )
    external
    whenThereAreUserCheckpoints(_cpTs, _weightStakeA, _weightStakeB, _stakeDuration)
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
  {
    // it should return the recorded bias
    (int128 _expectedBias,) = _contribution(_weightA, _stakeEnd, _checkpointTs);

    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _checkpointTs), _expectedBias.toUint256());
  }

  modifier whenTheTimestampDoesNotMatchTheCheckpointTimestamp() {
    _;
  }

  function testFuzz_WhenTheStakeHasExpired(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration,
    uint48 _ts
  )
    external
    whenThereAreUserCheckpoints(_cpTs, _weightStakeA, _weightStakeB, _stakeDuration)
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    _ts = uint48(bound(_ts, _stakeEnd, _stakeEnd + MAX_CHECKPOINT_ITERATIONS * 1 weeks));

    // it should return zero
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _ts), 0);
  }

  function testFuzz_WhenTheStakeHasNotExpired(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint120 _weightStakeB,
    uint48 _stakeDuration,
    uint48 _ts
  )
    external
    whenThereAreUserCheckpoints(_cpTs, _weightStakeA, _weightStakeB, _stakeDuration)
    whenThereIsACheckpointAtOrBeforeTheTimestamp
    whenTheStakeIsNotPermanent
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    _ts = uint48(bound(_ts, _checkpointTs + 1, _stakeEnd - 1));

    (int128 _expectedBias,) = _contribution(_weightA, _stakeEnd, _ts);

    // it should return the decayed bias based on the veNFT slope
    assertEq(votingRewardsManager.balanceOfNFTAt(_TOKEN_ID_A, _ts), _expectedBias.toUint256());
  }
}
