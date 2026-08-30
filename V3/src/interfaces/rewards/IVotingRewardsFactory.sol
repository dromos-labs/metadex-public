// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IVotingRewardsFactory
 * @notice Interface for the VotingRewardsFactory contract
 * @dev Deploys one VotingRewardsManager per gauge on a single chain.
 */
interface IVotingRewardsFactory {
  /// @notice Emitted when a new VotingRewardsManager is deployed for a gauge
  /// @param _gauge The gauge the VotingRewardsManager is bound to
  /// @param _votingRewardsManager The address of the newly deployed VotingRewardsManager
  event VotingRewardsCreated(address indexed _gauge, address indexed _votingRewardsManager);

  /// @notice Thrown when `createRewards` is called by an address other than an approved gauge factory
  error NotAuthorized();

  /// @notice Thrown when a constructor address is zero
  error ZeroAddress();

  /// @notice Deploys a new VotingRewardsManager for a gauge
  /// @dev Caller must be a gauge factory approved in the FactoryRegistry and is
  ///      recorded as the factory authorized to flush fees. The gauge may be a
  ///      predicted address with no deployed code and is never introspected.
  /// @param _gauge The gauge the VotingRewardsManager is bound to
  /// @param _rewards Initial reward token addresses forwarded to the deployed VotingRewardsManager
  /// @return _votingRewardsManager The address of the deployed VotingRewardsManager
  function createRewards(address _gauge, address[] memory _rewards) external returns (address _votingRewardsManager);

  /// @notice The voter each deployed VotingRewardsManager authorizes at runtime
  /// @return The voter address
  function voter() external view returns (address);

  /// @notice The FactoryRegistry resolving gauge factory approval for `createRewards`
  /// @return The FactoryRegistry address
  function FACTORY_REGISTRY() external view returns (address);

  /// @notice The wrapped-native token forwarded to each deployed VotingRewardsManager
  /// @return The wrapped-native token address
  function wrappedNative() external view returns (address);
}
