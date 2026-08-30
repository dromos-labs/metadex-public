// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';

interface IV2Gauge is IGauge {
  /**
   * @notice Emitted when staking tokens are deposited into the gauge.
   * @param _caller The address that supplied the staking tokens.
   * @param _account The account credited with the deposited stake.
   * @param _amount The amount of staking tokens deposited.
   */
  event Deposit(address indexed _caller, address indexed _account, uint256 _amount);

  /**
   * @notice Emitted when staking tokens are withdrawn from the gauge.
   * @param _caller The address that initiated the withdrawal.
   * @param _account The account whose staked balance was debited.
   * @param _amount The amount of staking tokens withdrawn.
   */
  event Withdraw(address indexed _caller, address indexed _account, uint256 _amount);

  /**
   * @notice Emitted when accrued emissions are claimed.
   * @param _account The address of the LP staker whose emissions were claimed.
   * @param _recipient The recipient of the claimed emissions.
   * @param _rewardAmount The amount of emissions paid to the recipient.
   */
  event EmissionsClaimed(address indexed _account, address indexed _recipient, uint256 _rewardAmount);

  /**
   * @notice Emitted when accrued emissions are stored instead of claimed during withdrawal.
   * @param _account The account credited with the deferred emissions.
   * @param _rewardAmount The post-penalty, post-referral emissions added to the account's deferred balance.
   */
  event EmissionsDeferred(address indexed _account, uint256 _rewardAmount);

  /**
   * @notice Emitted when an account's referral emissions are stored for a later claim.
   * @param _account The address of the LP staker whose emissions paid the referral.
   * @param _referral The referral address credited with the emissions.
   * @param _amount The referral emissions added to the referral's deferred balance.
   */
  event ReferralEmissionsDeferred(address indexed _account, address indexed _referral, uint256 _amount);

  /**
   * @notice Emitted when an account's deferred emissions are claimed.
   * @param _account The account whose deferred emissions were claimed.
   * @param _recipient The recipient of the claimed emissions.
   * @param _amount The deferred emissions paid to the recipient.
   */
  event DeferredEmissionsClaimed(address indexed _account, address indexed _recipient, uint256 _amount);

  /**
   * @notice Emitted when an early withdrawal penalty is applied to an account's accrued emissions.
   * @param _account The address of the LP staker whose emissions were penalized.
   * @param _penalty The amount of emissions forfeited as the penalty.
   */
  event EarlyWithdrawPenalty(address indexed _account, uint256 _penalty);

  /**
   * @notice Emitted when an owner sets a withdrawal allowance for an operator.
   * @param _owner The owner granting the allowance.
   * @param _operator The operator being granted the allowance.
   * @param _amount The new allowance amount.
   */
  event Approval(address indexed _owner, address indexed _operator, uint256 _amount);

  /**
   * @notice Thrown when a caller other than the voter attempts to settle rewards.
   */
  error NotVoter();

  /**
   * @notice Thrown when a zero amount is supplied where a non-zero amount is required.
   */
  error ZeroAmount();

  /**
   * @notice Thrown when initializing an already initialized gauge.
   */
  error AlreadyInitialized();

  /**
   * @notice Thrown when an operator's withdrawal allowance is below the requested amount.
   */
  error InsufficientAllowance();

  /**
   * @notice Thrown when depositing for another account while early unstake penalties are active.
   */
  error PenaltyActive();

  /**
   * @notice Initializes clone-specific gauge state.
   * @param _stakingToken Address of the pool LP token or staking token.
   * @param _votingRewardsManager Address of the VotingRewardsManager.
   * @param _isPool Whether the staking token is a V2 pool.
   */
  function initialize(address _stakingToken, address _votingRewardsManager, bool _isPool) external;

  /**
   * @notice Address of the pool LP token which is deposited (staked) for rewards.
   * @return The address of the staking token.
   */
  function stakingToken() external view returns (address);

  /**
   * @notice Stored reward-per-token accumulator.
   * @return The accumulated emissions per staked token.
   */
  function rewardPerTokenStored() external view returns (uint256);

  /**
   * @notice Amount of stakingToken deposited for rewards.
   * @return The total amount of staking tokens deposited for rewards.
   */
  function totalSupply() external view returns (uint256);

  /**
   * @notice Get the amount of stakingToken deposited by an account.
   * @param _account The address of the LP staker.
   * @return The account's deposited staking token balance.
   */
  function balanceOf(address _account) external view returns (uint256);

  /**
   * @notice Returns the block number at which an account most recently deposited
   * @param _account The address of the LP staker
   * @return The deposit block for the account
   */
  function depositBlock(address _account) external view returns (uint256);

  /**
   * @notice Cached rewardPerTokenStored for an account based on their most recent action.
   * @param _account The address of the LP staker.
   * @return The account's cached reward-per-token value.
   */
  function userRewardPerTokenPaid(address _account) external view returns (uint256);

  /**
   * @notice Cached amount of emissions earned for an account.
   * @param _account The address of the LP staker.
   * @return The account's cached earned emissions.
   */
  function rewards(address _account) external view returns (uint256);

  /**
   * @notice Deferred post-penalty, post-referral emissions stored for an account.
   * @param _account The account credited with the deferred emissions.
   * @return The account's deferred emissions.
   */
  function deferredEmissions(address _account) external view returns (uint256);

  /**
   * @notice Remaining withdrawal allowance an owner has granted to an operator.
   * @param _owner The owner that granted the allowance.
   * @param _operator The operator being queried.
   * @return The remaining withdrawal allowance.
   */
  function allowance(address _owner, address _operator) external view returns (uint256);
}
