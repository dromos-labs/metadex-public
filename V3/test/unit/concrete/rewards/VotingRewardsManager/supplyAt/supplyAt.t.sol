// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitConcreteVotingRewardsManagerSupplyAt is UnitVotingRewardsManager {
  uint256 internal constant _TOKEN_ID_C = 3;

  /// @dev Set by `whenThereAreGlobalCheckpoints`
  uint48 internal _checkpointTs;

  uint128 internal _weightPermanent;

  uint48 internal _stakeEndA;
  uint128 internal _weightA;
  int128 internal _slopeA;

  uint48 internal _stakeEndB;
  uint128 internal _weightB;
  int128 internal _slopeB;

  function test_WhenThereAreNoGlobalCheckpoints() external view {
    // it should return zero
    assertEq(votingRewardsManager.supplyAt(block.timestamp), 0);
  }

  modifier whenThereAreGlobalCheckpoints() {
    /// @dev Skip to a checkpoint timestamp one day into an epoch
    _checkpointTs = uint48(ProtocolTimeLibrary.epochNext(block.timestamp) + 1 days);
    vm.warp(_checkpointTs);

    /// @dev Setup non-permanent lock A, expiring 26 weeks out
    _stakeEndA = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 26 weeks));
    _weightA = uint128(1000 * TOKEN_1);
    // @dev slopeA = 1_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeA = 7_927_447_995_941;

    /// @dev Setup non-permanent lock B, expiring 52 weeks out (strictly after A)
    _stakeEndB = uint48(ProtocolTimeLibrary.epochStart(_checkpointTs + 52 weeks));
    _weightB = uint128(2000 * TOKEN_1);
    // @dev slopeB = 2_000 * TOKEN_1 / MAX_TIME (floored)
    _slopeB = 15_854_895_991_882;

    /// @dev Setup permanent lock
    _weightPermanent = uint128(500 * TOKEN_1);

    /// @dev Simulate checkpoints for two non-permanent locks and one permanent lock
    vm.startPrank(_VOTER);
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_A, _allocated: _weightA, _stakeEnd: _stakeEndA, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_B, _allocated: _weightB, _stakeEnd: _stakeEndB, _data: ''});
    votingRewardsManager.checkpoint({_tokenId: _TOKEN_ID_C, _allocated: _weightPermanent, _stakeEnd: 0, _data: ''});
    _;
  }

  function test_WhenThereAreNoCheckpointsBeforeOrAtTheTimestamp() external whenThereAreGlobalCheckpoints {
    // it should return zero
    assertEq(votingRewardsManager.supplyAt(_checkpointTs - 1), 0);
  }

  modifier whenThereAreCheckpointsBeforeOrAtTheTimestamp() {
    _;
  }

  function test_WhenTheTimestampMatchesTheCheckpointTimestamp()
    external
    whenThereAreGlobalCheckpoints
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
  {
    // @dev biasA at _checkpointTs = slopeA * (stakeEndA - _checkpointTs), 26 weeks minus 1 day of decay
    uint256 _biasA = 123_972_602_739_723_734_400;
    // @dev biasB at _checkpointTs = slopeB * (stakeEndB - _checkpointTs), 52 weeks minus 1 day of decay
    uint256 _biasB = 497_260_273_972_593_542_400;

    // it should return the sum of the global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_checkpointTs), _biasA + _biasB + _weightPermanent);
  }

  modifier whenTheTimestampDoesNotMatchTheCheckpointTimestamp() {
    _;
  }

  function test_WhenThereAreNoSlopeChanges()
    external
    whenThereAreGlobalCheckpoints
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // @dev Query on a whole-week boundary before either stake expires, so no slope changes apply
    uint48 _snapshotTs = _stakeEndA - 13 weeks;

    // @dev biasA at _snapshotTs = slopeA * (stakeEndA - _snapshotTs) = slopeA * 13 weeks
    uint256 _biasA = 62_328_767_123_286_518_400;
    // @dev biasB at _snapshotTs = slopeB * (stakeEndB - _snapshotTs) = slopeB * 39 weeks
    uint256 _biasB = 373_972_602_739_719_110_400;

    // it should return the sum of the decayed global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_snapshotTs), _biasA + _biasB + _weightPermanent);
  }

  function test_WhenThereAreSlopeChanges()
    external
    whenThereAreGlobalCheckpoints
    whenThereAreCheckpointsBeforeOrAtTheTimestamp
    whenTheTimestampDoesNotMatchTheCheckpointTimestamp
  {
    // @dev Query 13 weeks before B's stake end so B is still active; A already expired (at 26 weeks) so its slope change is applied
    uint48 _snapshotTs = _stakeEndB - 13 weeks;

    // it should apply slope changes at epoch boundaries
    assertEq(votingRewardsManager.slopeChanges(_stakeEndA), -_slopeA);
    assertEq(votingRewardsManager.slopeChanges(_stakeEndB), -_slopeB);

    // @dev A is fully decayed past stakeEndA; biasB at _snapshotTs = slopeB * (stakeEndB - _snapshotTs) = slopeB * 13 weeks
    uint256 _biasB = 124_657_534_246_573_036_800;

    // it should return the sum of the decayed global bias and permanent lock balance
    assertEq(votingRewardsManager.supplyAt(_snapshotTs), _biasB + _weightPermanent);
  }
}
