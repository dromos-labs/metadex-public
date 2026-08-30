// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {UnitFuzzVotingRewardsManager} from 'V3-test/unit/fuzz/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitFuzzVotingRewardsManagerSupplyAt is UnitFuzzVotingRewardsManager {
  using SafeCastLibrary for uint256;
  using SafeCastLibrary for int128;

  uint256 internal constant _TOKEN_ID_C = 3;

  /// @dev Set by `whenThereAreGlobalCheckpoints` from bounded fuzz seeds
  uint48 internal _checkpointTs;

  uint120 internal _weightPermanent;

  uint48 internal _stakeEndA;
  uint120 internal _weightA;
  int128 internal _slopeA;

  uint48 internal _stakeEndB;
  uint120 internal _weightB;
  int128 internal _slopeB;

  function testFuzz_WhenThereAreNoGlobalCheckpoints(uint48 _ts) external view {
    // it should return zero
    assertEq(votingRewardsManager.supplyAt(_ts), 0);
  }

  modifier whenThereAreGlobalCheckpoints(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint48 _stakeDurationA,
    uint120 _weightStakeB,
    uint48 _stakeDurationB,
    uint120 _weightPerm
  ) {
    /// @dev Skip to a random checkpoint timestamp
    _checkpointTs = uint48(bound(_cpTs, 1 weeks, MAX_CHECKPOINT_ITERATIONS * 1 weeks));
    vm.warp(_checkpointTs);

    /// @dev Setup non-permanent lock A
    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + bound(_stakeDurationA, 2 weeks, MAX_TIME / 2)));
    _weightA = uint120(bound(_weightStakeA, MAX_TIME, type(uint120).max));
    (, _slopeA) = _contribution(_weightA, _stakeEndA, _checkpointTs);

    /// @dev Setup non-permanent lock B, with stakeEnd strictly after A's
    _stakeEndB = uint48(
      ProtocolTimeLibrary.epochStart(
        _checkpointTs + bound(_stakeDurationB, (_stakeEndA - _checkpointTs) + 2 weeks, MAX_TIME)
      )
    );
    _weightB = uint120(bound(_weightStakeB, MAX_TIME, type(uint120).max));
    (, _slopeB) = _contribution(_weightB, _stakeEndB, _checkpointTs);

    /// @dev Setup permanent lock
    _weightPermanent = uint120(bound(_weightPerm, 1, type(uint120).max));

    /// @dev Simulate checkpoints for two non-permanent locks and one permanent lock
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEndA, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_C, _allocated: _weightPermanent, _stakeEnd: 0, _data: ''});
    _;
  }

  function testFuzz_WhenThereAreNoCheckpointsBeforeOrAtTheTimestamp(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint48 _stakeDurationA,
    uint120 _weightStakeB,
    uint48 _stakeDurationB,
    uint120 _weightPerm,
    uint48 _ts
  )
    external
    whenThereAreGlobalCheckpoints(_cpTs, _weightStakeA, _stakeDurationA, _weightStakeB, _stakeDurationB, _weightPerm)
  {
    _ts = uint48(bound(_ts, 0, _checkpointTs - 1));

    // it should return zero
    assertEq(votingRewardsManager.supplyAt(_ts), 0);
  }

  modifier whenThereAreCheckpointsBeforeOrAtTheTimestamp() {
    _;
  }

  function testFuzz_WhenTheTimestampMatchesTheCheckpointTimestamp(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint48 _stakeDurationA,
    uint120 _weightStakeB,
    uint48 _stakeDurationB,
    uint120 _weightPerm
  )
    external
    whenThereAreGlobalCheckpoints(_cpTs, _weightStakeA, _stakeDurationA, _weightStakeB, _stakeDurationB, _weightPerm)
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
  {
    (int128 _biasA,) = _contribution(_weightA, _stakeEndA, _checkpointTs);
    (int128 _biasB,) = _contribution(_weightB, _stakeEndB, _checkpointTs);

    // it should return the sum of the global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), (_biasA + _biasB).toUint256() + _weightPermanent);
  }

  modifier whenTheTimestampDoesNotMatchTheCheckpointTimestamp() {
    _;
  }

  function testFuzz_WhenThereAreNoSlopeChanges(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint48 _stakeDurationA,
    uint120 _weightStakeB,
    uint48 _stakeDurationB,
    uint120 _weightPerm,
    uint48 _snapshotTs
  )
    external
    whenThereAreGlobalCheckpoints(_cpTs, _weightStakeA, _stakeDurationA, _weightStakeB, _stakeDurationB, _weightPerm)
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // @dev Keep the query strictly inside the active window of both locks (A's stakeEnd is the earlier one)
    _snapshotTs = uint48(bound(_snapshotTs, _checkpointTs + 1, _stakeEndA - 1));

    (int128 _biasA,) = _contribution(_weightA, _stakeEndA, _snapshotTs);
    (int128 _biasB,) = _contribution(_weightB, _stakeEndB, _snapshotTs);

    // it should return the sum of the decayed global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_snapshotTs), (_biasA + _biasB).toUint256() + _weightPermanent);
  }

  function testFuzz_WhenThereAreSlopeChanges(
    uint48 _cpTs,
    uint120 _weightStakeA,
    uint48 _stakeDurationA,
    uint120 _weightStakeB,
    uint48 _stakeDurationB,
    uint120 _weightPerm,
    uint48 _snapshotTs
  )
    external
    whenThereAreGlobalCheckpoints(_cpTs, _weightStakeA, _stakeDurationA, _weightStakeB, _stakeDurationB, _weightPerm)
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // @dev Query strictly after A's expiry; B may or may not have expired by then
    _snapshotTs = uint48(bound(_snapshotTs, _stakeEndA, _stakeEndB + MAX_TIME));

    // it should apply slope changes at epoch boundaries
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slopeA);
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);

    // @dev A is fully decayed past `stakeEndA`, while B decays until its own stakeEnd
    (int128 _biasB,) = _contribution(_weightB, _stakeEndB, _snapshotTs);

    // it should return the sum of the decayed global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_snapshotTs), _biasB.toUint256() + _weightPermanent);
  }
}
