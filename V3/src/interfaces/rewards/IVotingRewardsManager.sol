// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFeeDistribution} from 'V3/interfaces/rewards/IFeeDistribution.sol';
import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {IVotingCheckpoints} from 'V3/interfaces/rewards/IVotingCheckpoints.sol';

/**
 * @title IVotingRewardsManager
 * @notice Interface for the VotingRewardsManager contract
 */
interface IVotingRewardsManager is IVotingCheckpoints, IFeeDistribution, IIncentiveStreaming {
  /**
   * @notice Reward claim pointers for a staked position
   * @param lastGlobalCp The global checkpoint index through which rewards have been claimed
   * @param lastUserCp The user checkpoint index active at lastGlobalCp
   */
  struct ClaimState {
    uint64 lastGlobalCp;
    uint64 lastUserCp;
  }

  /**
   * @notice Emitted when a fee token is claimed for a veNFT
   * @param _tokenId The ID of the veNFT that claimed the fees
   * @param _recipient The address that received the claimed fees
   * @param _token The fee token that was claimed
   * @param _amount The amount of the fee token claimed
   */
  event ClaimFees(uint256 indexed _tokenId, address indexed _recipient, address indexed _token, uint256 _amount);

  /**
   * @notice Emitted when incentive rewards are claimed for a veNFT from a program
   * @param _tokenId The veNFT token ID
   * @param _recipient Address that received the incentive rewards
   * @param _programId The incentive program claimed from
   * @param _amount The incentive reward amount transferred
   */
  event ClaimIncentives(
    uint256 indexed _tokenId, address indexed _recipient, uint256 indexed _programId, uint256 _amount
  );

  /**
   * @notice Emitted when fees are collected from a gauge
   * @param _gauge The gauge whose fees were collected
   * @param _token The fee token that was collected
   * @param _amount The amount of fees collected from the gauge
   */
  event FeesCollected(address indexed _gauge, address indexed _token, uint256 _amount);

  /**
   * @notice Emitted when global reward checkpoints are advanced without any weight change
   * @param _caller Address that triggered the advance
   * @param _globalCheckpointIndex Resulting global checkpoint index after the advance
   */
  event GlobalPointsAdvanced(address indexed _caller, uint256 _globalCheckpointIndex);

  /**
   * @notice Thrown when the caller is not the voter contract
   */
  error NotVoter();

  /**
   * @notice Thrown when the caller is neither the voter nor the veNFT's operator
   */
  error NotAuthorized();

  /**
   * @notice Thrown when there is no prior global reward checkpoint to advance from
   */
  error NoGlobalCheckpoint();

  /**
   * @notice Thrown when the latest global reward checkpoint is already in the current epoch
   */
  error TooSoon();

  /**
   * @notice Thrown when the global checkpoint iteration limit is zero or exceeds `MAX_CHECKPOINT_ITERATIONS`
   */
  error InvalidCheckpointIterations();

  /**
   * @notice Thrown when the caller is not the gauge factory
   */
  error NotGaugeFactory();

  /**
   * @notice Thrown when the gauge's fee collection call fails
   * @param _gauge The gauge whose fee collection failed
   */
  error FeeCollectionFailed(address _gauge);

  /**
   * @notice Thrown when a bounded claim is requested with a zero checkpoint limit
   */
  error ZeroCheckpoints();

  /**
   * @notice Thrown when the contract receives native tokens from an address other than `wrappedNative`
   */
  error NotWrappedNative();

  /**
   * @notice Updates the voting weight allocation for a given veNFT
   * @dev Only callable by the LeafVoter
   *      Assumes stale checkpoint calls are skipped upstream
   *      Assumes checkpoint history is within the iteration limit
   *      Assumes fees are flushed before suspension and pending fees are zero for suspended gauges
   *      Permanent stakes are signaled via a zero `_stakeEnd`
   *      Clears the existing allocation if no weights are allocated, or if a non-permanent stake carries no weight
   * @param _tokenId Unique identifier of the veNFT
   * @param _allocated Allocation amount for this reward contract
   * @param _stakeEnd Expiration timestamp of the veNFT's stake
   * @param _data Extensible calldata forwarded from the LeafVoter
   */
  function checkpoint(uint256 _tokenId, uint128 _allocated, uint48 _stakeEnd, bytes calldata _data) external;

  /**
   * @notice Advances the global reward checkpoint history toward `block.timestamp`
   * @dev Each call advances at most `MAX_CHECKPOINT_ITERATIONS` intervals
   *      Pending fees are notified only when the call can reach the current timestamp
   */
  function advanceGlobalPoints() external;

  /**
   * @notice Advances the global reward checkpoint history toward `block.timestamp`
   * @dev Pending fees are notified only when the call can reach the current timestamp
   * @param _maxIterations Maximum number of checkpoint intervals to process
   */
  function advanceGlobalPoints(uint256 _maxIterations) external;

  /**
   * @notice Claims fee rewards for a veNFT up to a bounded number of user checkpoints
   * @dev Only callable by the LeafVoter or the veNFT's registered operator
   *      Assumes checkpoint history is within the iteration limit when notifying fees
   * @param _tokenId The ID of the veNFT to claim for
   * @param _recipient The address to receive the claimed fees
   * @param _maxCheckpoints The maximum number of user checkpoints to process
   */
  function claimFees(uint256 _tokenId, address _recipient, uint256 _maxCheckpoints) external;

  /**
   * @notice Claim incentive rewards for a veNFT from a single program, up to a bounded number of the
   *         veNFT's own user checkpoints.
   * @dev Delegates to _claimIncentives with the given _maxCheckpoints, pricing at most that many user
   *      checkpoints. Closes the open interval first only when _maxCheckpoints reaches the veNFT's latest user
   *      checkpoint (the span priced to the open tip) and that interval is still open; a bounded claim that
   *      stops short leaves it for a later claim.
   *      Reverts with StaleCheckpointHistory if closing the required open interval exceeds the iteration limit
   * @param _tokenId        The veNFT token ID
   * @param _recipient      Address to receive the incentive rewards
   * @param _programId      The incentive program ID to claim from
   * @param _maxCheckpoints Maximum number of user checkpoints to examine
   */
  function claimIncentives(uint256 _tokenId, address _recipient, uint256 _programId, uint256 _maxCheckpoints) external;

  /**
   * @notice Flushes accrued fees to active voters and writes a fee-only global checkpoint
   * @dev Only callable by the gauge factory
   *      Reverts if the gauge's fee collection call fails
   */
  function flushFees() external;

  /**
   * @notice Returns the address of the wrapped native token
   * @dev Set to the zero address if auto unwrapping is not supported
   * @return The address of the wrapped native token
   */
  function wrappedNative() external view returns (address);

  /**
   * @notice Estimates the pending fee rewards for a veNFT up to a bounded number of user checkpoints
   * @dev If claiming past the last user checkpoint, estimates pending fees since the last global point
   *      Derives the estimate from the gauge's uncollected fees, weighted by the stake's share of supply
   *      Pending reward estimates may differ with fee accrual, collection, or weight changes before claiming
   * @param _tokenId The ID of the veNFT to estimate for
   * @param _maxCheckpoints The maximum number of user checkpoints to process
   * @return The pending token0 fee rewards
   * @return The pending token1 fee rewards
   */
  function earnedFees(uint256 _tokenId, uint256 _maxCheckpoints) external view returns (uint256, uint256);

  /**
   * @notice Estimates pending incentive rewards for a veNFT from a single program up to a bounded number of user checkpoints
   * @dev If claiming past the last user checkpoint, estimates incentives streamed since the last global point
   *      Derives the estimate from the program's unsettled incentives, weighted by the stake's share of supply at the end of the interval
   *      Pending reward estimates may differ with incentive streaming, weight changes, or epoch boundaries during the interval
   * @param _tokenId The veNFT token ID
   * @param _programId The incentive program ID
   * @param _maxCheckpoints Maximum number of user checkpoints to examine
   * @return Pending incentive rewards
   */
  function earnedIncentives(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _maxCheckpoints
  ) external view returns (uint256);

  /**
   * @notice Returns the fee claim pointers for a staked position
   * @param _tokenId The staked position ID
   * @return The fee claim progress for the position
   */
  function feeClaimState(uint256 _tokenId) external view returns (ClaimState memory);

  /**
   * @notice Returns incentive claim progress for a staked position and program
   * @param _tokenId The staked position ID
   * @param _programId The incentive program ID
   * @return The incentive claim progress for the position and program
   */
  function incentiveClaimState(uint256 _tokenId, uint256 _programId) external view returns (ClaimState memory);
}
