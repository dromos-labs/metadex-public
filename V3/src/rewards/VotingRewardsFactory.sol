// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VotingRewardsFactoryLibrary} from 'V3/libraries/VotingRewardsFactoryLibrary.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsFactory} from 'V3/interfaces/rewards/IVotingRewardsFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title VotingRewardsFactory
 * @notice Deploys one VotingRewardsManager per gauge on a single chain
 */
contract VotingRewardsFactory is IVotingRewardsFactory {
  /// @inheritdoc IVotingRewardsFactory
  address public immutable voter;
  /// @inheritdoc IVotingRewardsFactory
  address public immutable wrappedNative;
  /// @inheritdoc IVotingRewardsFactory
  address public immutable FACTORY_REGISTRY;

  /**
   * @notice Initializes the VotingRewardsFactory
   * @dev The FactoryRegistry is read from the voter so both always agree on it. Reverts when any address is zero
   *      or the voter reports a zero FactoryRegistry
   * @param _voter The LeafVoter each deployed VotingRewardsManager authorizes at runtime
   * @param _wrappedNative The wrapped-native token forwarded to each deployed VotingRewardsManager
   */
  constructor(address _voter, address _wrappedNative) {
    if (_voter == address(0) || _wrappedNative == address(0)) revert ZeroAddress();
    address _factoryRegistry = address(ILeafVoter(_voter).FACTORY_REGISTRY());
    if (_factoryRegistry == address(0)) revert ZeroAddress();

    voter = _voter;
    FACTORY_REGISTRY = _factoryRegistry;
    wrappedNative = _wrappedNative;
  }

  /// @inheritdoc IVotingRewardsFactory
  function createRewards(address _gauge, address[] memory _rewards) external returns (address _votingRewardsManager) {
    if (!IFactoryRegistry(FACTORY_REGISTRY).isGaugeFactoryApproved(msg.sender)) revert NotAuthorized();

    _votingRewardsManager = VotingRewardsFactoryLibrary.createVotingRewardsManager({
      _voter: voter, _gauge: _gauge, _gaugeFactory: msg.sender, _wrappedNative: wrappedNative, _initialRewards: _rewards
    });

    emit VotingRewardsCreated({_gauge: _gauge, _votingRewardsManager: _votingRewardsManager});
  }
}
