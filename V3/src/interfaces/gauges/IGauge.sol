// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface IGauge {
  /**
   * @notice Emitted when the gauge collects pool fees through the VotingRewardsManager.
   * @param _caller The address that triggered fee collection.
   * @param _claimed0 The amount of token0 fees collected.
   * @param _claimed1 The amount of token1 fees collected.
   */
  event ClaimFees(address indexed _caller, uint256 _claimed0, uint256 _claimed1);

  /**
   * @notice Emitted when an account grants or revokes claim approval for an operator
   * @param _account The account whose approval state changed
   * @param _operator The operator being approved or revoked
   * @param _approved The new approval state
   */
  event ClaimApproval(address indexed _account, address indexed _operator, bool _approved);

  /**
   * @notice Emitted when an owner grants or revokes blanket withdrawal approval for an operator
   * @param _owner The owner whose approval changed
   * @param _operator The operator being approved or revoked
   * @param _approved The new approval state
   */
  event ApprovalForAll(address indexed _owner, address indexed _operator, bool _approved);

  /**
   * @notice Emitted when a referral's deferred emissions are claimed.
   * @param _referral The referral address whose deferred emissions were claimed.
   * @param _recipient The recipient of the claimed emissions.
   * @param _amount The deferred referral emissions paid to the recipient.
   */
  event ReferralEmissionsClaimed(address indexed _referral, address indexed _recipient, uint256 _amount);

  /**
   * @notice Thrown when the caller is neither the account nor an approved operator.
   */
  error NotAuthorized();

  /**
   * @notice Thrown when a caller other than the VotingRewardsManager attempts to collect fees.
   */
  error NotVotingRewardsManager();

  /**
   * @notice Thrown when a zero address is supplied where a non-zero address is required.
   */
  error ZeroAddress();

  /**
   * @notice Deposit a staked position
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function deposit(uint256 _lp) external;

  /**
   * @notice Deposit a staked position on behalf of an owner
   * @dev For V2 gauges, approved MetaRouters are trusted to restrict `_owner` to the account that authorized the
   *      routed deposit; otherwise, they could reset another account's early-unstake penalty timer.
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _owner The address credited as the staked owner
   */
  function depositFor(uint256 _lp, address _owner) external;

  /**
   * @notice Withdraw a staked position owned by the caller
   * @dev Defers accrued emissions when emission minting reverts
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function withdraw(uint256 _lp) external;

  /**
   * @notice Withdraw a staked position on behalf of an account
   * @dev Defers accrued emissions when emission minting reverts
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _account The position owner
   */
  function withdrawFrom(uint256 _lp, address _account) external;

  /**
   * @notice Claim accrued and deferred emissions
   * @dev Requires the caller to be the LP or an operator with claim approval
   * @param _account The address of the LP staker whose emissions are being claimed
   * @param _recipient The recipient of the claimed emissions
   */
  function claimEmissions(address _account, address _recipient) external;

  /**
   * @notice Claims a referral's deferred emissions.
   * @dev Requires the caller to be the referral or an operator with claim approval.
   * @param _referral The referral address whose deferred emissions are being claimed.
   * @param _recipient The recipient of the claimed emissions.
   */
  function claimReferralEmissions(address _referral, address _recipient) external;

  /**
   * @notice Grant or revoke an operator's approval to claim emissions on behalf of the caller
   * @param _operator The operator to approve or revoke
   * @param _approved True to approve, false to revoke
   */
  function approveForClaim(address _operator, bool _approved) external;

  /**
   * @notice Grant or revoke blanket withdrawal authorization for an operator over all staked positions
   * @param _operator The operator to authorize or revoke
   * @param _approved True to grant blanket approval, false to revoke
   */
  function setApprovalForAll(address _operator, bool _approved) external;

  /**
   * @notice Approve an operator to withdraw a staked position
   * @param _operator The operator to authorize
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   */
  function approve(address _operator, uint256 _lp) external;

  /**
   * @notice Collect currently claimable pool fees directly to the VotingRewardsManager.
   * @dev Only callable by the VotingRewardsManager.
   * @return _amount0 The token0 fees collected.
   * @return _amount1 The token1 fees collected.
   */
  function collectFees() external returns (uint256 _amount0, uint256 _amount1);

  /**
   * @notice LeafVoter contract used for gauge settlement.
   * @return The address of the LeafVoter.
   */
  function voter() external view returns (address);

  /**
   * @notice Address of the factory that created this gauge.
   * @return The address of the gauge factory.
   */
  function gaugeFactory() external view returns (address);

  /**
   * @notice Address of the VotingRewardsManager contract linked to the gauge.
   * @return The address of the VotingRewardsManager.
   */
  function votingRewardsManager() external view returns (address);

  /**
   * @notice Returns if gauge is linked to a legitimate pool.
   * @return Whether the gauge is linked to a legitimate pool.
   */
  function isPool() external view returns (bool);

  /**
   * @notice The gauge's cursor into the LeafVoter's cumulative reward share accumulator
   * @return The cumulative reward share at the gauge's last settlement
   */
  function lastCumulativeRewardShare() external view returns (uint256);

  /**
   * @notice Estimates the accrued and deferred emissions claimable by an account
   * @dev Rewards accrued since the last settlement are an estimate
   * @param _account The address of the LP staker
   * @return The estimated claimable amount
   */
  function earned(address _account) external view returns (uint256);

  /**
   * @notice Whether an operator is approved to claim emissions on behalf of an account
   * @param _account The account that granted the approval
   * @param _operator The operator being queried
   * @return True if the operator is approved
   */
  function approvedForClaim(address _account, address _operator) external view returns (bool);

  /**
   * @notice Deferred referral emissions stored for a referral.
   * @param _referral The referral credited with the deferred emissions.
   * @return The referral's deferred emissions.
   */
  function deferredReferralEmissions(address _referral) external view returns (uint256);

  /**
   * @notice Returns whether an operator has blanket withdrawal authorization for an owner's positions
   * @param _owner The staked position owner
   * @param _operator The candidate operator
   * @return True if blanket approval is active
   */
  function isApprovedForAll(address _owner, address _operator) external view returns (bool);

  /**
   * @notice Return currently claimable pool fees without moving tokens or mutating state.
   * @return _amount0 The currently pending token0 fees.
   * @return _amount1 The currently pending token1 fees.
   */
  function pendingFees() external view returns (uint256 _amount0, uint256 _amount1);
}
