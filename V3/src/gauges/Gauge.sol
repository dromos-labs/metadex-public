// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title Gauge
 * @notice Abstract gauge holding functionality common to both gauge types.
 */
abstract contract Gauge is ReentrancyGuardTransient, IGauge {
  using SafeCastLibrary for uint256;

  /// @inheritdoc IGauge
  address public immutable voter;
  /// @inheritdoc IGauge
  address public immutable gaugeFactory;

  /// @inheritdoc IGauge
  address public votingRewardsManager;
  /// @inheritdoc IGauge
  bool public isPool;
  /// @inheritdoc IGauge
  uint256 public lastCumulativeRewardShare;

  /// @inheritdoc IGauge
  mapping(address _account => mapping(address _operator => bool _approved)) public approvedForClaim;
  /// @inheritdoc IGauge
  mapping(address _referral => uint256 _deferredReferralEmissions) public deferredReferralEmissions;

  constructor(address _voter, address _gaugeFactory) {
    voter = _voter;
    gaugeFactory = _gaugeFactory;
  }

  /// @inheritdoc IGauge
  function deposit(uint256 _lp) external override nonReentrant {
    _deposit(_lp, msg.sender);
  }

  /// @inheritdoc IGauge
  function depositFor(uint256 _lp, address _owner) external virtual override nonReentrant {
    if (_owner == address(0)) revert ZeroAddress();
    _deposit(_lp, _owner);
  }

  /// @inheritdoc IGauge
  function withdraw(uint256 _lp) external override nonReentrant {
    _withdraw(_lp, msg.sender, msg.sender);
  }

  /// @inheritdoc IGauge
  function withdrawFrom(uint256 _lp, address _account) external override nonReentrant {
    if (_account == address(0)) revert ZeroAddress();

    _authorizeWithdrawalFrom(_lp, _account);
    address _claimRecipient = approvedForClaim[_account][msg.sender] ? msg.sender : _account;
    _withdraw(_lp, _account, _claimRecipient);
  }

  /// @inheritdoc IGauge
  function claimEmissions(address _account, address _recipient) external virtual override;

  /// @inheritdoc IGauge
  function claimReferralEmissions(address _referral, address _recipient) external override nonReentrant {
    if (msg.sender != _referral && !approvedForClaim[_referral][msg.sender]) revert NotAuthorized();
    if (_recipient == address(0)) revert ZeroAddress();

    uint256 _amount = deferredReferralEmissions[_referral];
    if (_amount == 0) return;

    delete deferredReferralEmissions[_referral];

    (address[] memory _recipients, uint128[] memory _amounts) = _buildMintArrays(_recipient, _amount);
    // slither-disable-next-line reentrancy-no-eth
    ILeafVoter(voter).mintEmissions({_recipients: _recipients, _amounts: _amounts});

    emit ReferralEmissionsClaimed(_referral, _recipient, _amount);
  }

  /// @inheritdoc IGauge
  function approveForClaim(address _operator, bool _approved) external override {
    if (_operator == address(0)) revert ZeroAddress();
    approvedForClaim[msg.sender][_operator] = _approved;
    emit ClaimApproval(msg.sender, _operator, _approved);
  }

  /// @inheritdoc IGauge
  function setApprovalForAll(address _operator, bool _approved) external override {
    if (_operator == address(0)) revert ZeroAddress();
    _setApprovalForAll(_operator, _approved);
    emit ApprovalForAll(msg.sender, _operator, _approved);
  }

  /// @inheritdoc IGauge
  function earned(address _account) external view virtual override returns (uint256);

  /**
   * @notice Deposits a staked position for an owner
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _owner The address credited as the staked owner
   */
  function _deposit(uint256 _lp, address _owner) internal virtual;

  /**
   * @notice Withdraws a staked position and attempts to claim accrued emissions
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _account The position owner
   * @param _claimRecipient The recipient of the claimed emissions
   */
  function _withdraw(uint256 _lp, address _account, address _claimRecipient) internal virtual;

  /**
   * @notice Grants or revokes blanket withdrawal authorization for an operator
   * @param _operator The operator to authorize or revoke
   * @param _approved True to grant blanket approval, false to revoke
   */
  function _setApprovalForAll(address _operator, bool _approved) internal virtual;

  /**
   * @notice Validates delegated withdrawal authorization
   * @param _lp A token amount for V2 gauges or an NFT token ID for CL gauges
   * @param _account The position owner
   */
  function _authorizeWithdrawalFrom(uint256 _lp, address _account) internal virtual;

  /**
   * @notice Checks whether this gauge is activated in the LeafVoter.
   * @return _activated Whether the gauge is activated.
   */
  function _isActivated() internal view returns (bool _activated) {
    return ILeafVoter(voter).isActivated(address(this));
  }

  /**
   * @notice Calculates the early withdraw penalty for a reward
   * @dev Assumes the penalty rate is smaller than or equal to `MAX_PIPS`
   * @param _depositBlock The LP's most recent deposit block
   * @param _reward The reward amount before penalty
   * @param _config The penalty config to apply
   * @return The penalty amount
   */
  function _applyPenalty(
    uint256 _depositBlock,
    uint256 _reward,
    IGaugeFactory.PenaltyConfig memory _config
  ) internal view returns (uint256) {
    return _config.penaltyRate > 0 && _config.minStakeBlocks > 0
      && block.number < _depositBlock + _config.minStakeBlocks
      ? _reward * _config.penaltyRate / MAX_PIPS
      : 0;
  }

  /**
   * @notice Calculates the referral fee for a reward
   * @dev Assumes the referral share is smaller than or equal to `MAX_PIPS`
   * @param _reward The reward amount before referral split
   * @param _referral The referral reward recipient
   * @param _referralShare The referral share in PIPS
   * @return The referral amount
   */
  function _applyReferral(uint256 _reward, address _referral, uint256 _referralShare) internal pure returns (uint256) {
    if (_referralShare == 0 || _referral == address(0)) return 0;

    return _reward * _referralShare / MAX_PIPS;
  }

  /**
   * @notice Builds the recipient and amount arrays for an emissions mint
   * @dev Assumes _amount is greater than zero
   * @param _recipient The emissions recipient
   * @param _amount The emissions amount
   * @return _recipients The mint recipients
   * @return _amounts The mint amounts
   */
  function _buildMintArrays(
    address _recipient,
    uint256 _amount
  ) internal pure returns (address[] memory _recipients, uint128[] memory _amounts) {
    _recipients = new address[](1);
    _amounts = new uint128[](1);
    _recipients[0] = _recipient;
    _amounts[0] = _amount.toUint128();
  }
}
