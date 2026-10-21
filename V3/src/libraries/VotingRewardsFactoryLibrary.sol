// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';

/// @title VotingRewardsFactoryLibrary
/// @notice Deploys VotingRewardsManager instances.
library VotingRewardsFactoryLibrary {
  /// @notice Deploys a VotingRewardsManager.
  /// @param _voter Voter authorized by the deployed manager.
  /// @param _gauge Gauge linked to the deployed manager.
  /// @param _gaugeFactory Gauge factory authorized to flush fees.
  /// @param _wrappedNative Wrapped native token used for reward unwrapping.
  /// @param _initialRewards Initial reward token addresses.
  /// @return Address of the deployed VotingRewardsManager.
  function createVotingRewardsManager(
    address _voter,
    address _gauge,
    address _gaugeFactory,
    address _wrappedNative,
    address[] calldata _initialRewards
  ) external returns (address) {
    return address(
      new VotingRewardsManager({
        _voter: _voter,
        _gauge: _gauge,
        _gaugeFactory: _gaugeFactory,
        _wrappedNative: _wrappedNative,
        _initialRewards: _initialRewards
      })
    );
  }
}
