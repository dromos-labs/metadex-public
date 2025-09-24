// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {PRECISION} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {Gauge} from 'V3/gauges/Gauge.sol';

/**
 * @title Aerodrome V2 Gauge
 * @notice Manages V2 pool stakes and distributes emissions by account
 */
contract V2Gauge is Gauge, IV2Gauge {
  using SafeERC20 for IERC20;
  using SafeCastLibrary for uint256;

  /// @notice FactoryRegistry used to resolve approved MetaRouters.
  IFactoryRegistry internal immutable FACTORY_REGISTRY;

  /// @inheritdoc IV2Gauge
  address public stakingToken;

  bool internal _initialized;

  /// @inheritdoc IV2Gauge
  uint256 public rewardPerTokenStored;
  /// @inheritdoc IV2Gauge
  uint256 public totalSupply;

  /// @inheritdoc IV2Gauge
  mapping(address _account => uint256 _balance) public balanceOf;
  /// @inheritdoc IV2Gauge
  mapping(address _account => uint256 _block) public depositBlock;
  /// @inheritdoc IV2Gauge
  mapping(address _account => uint256 _userRewardPerTokenPaid) public userRewardPerTokenPaid;
  /// @inheritdoc IV2Gauge
  mapping(address _account => uint256 _rewards) public rewards;
  /// @inheritdoc IV2Gauge
  mapping(address _account => uint256 _deferredEmissions) public deferredEmissions;

  /// @notice ERC20-style withdrawal allowance per (owner, operator).
  mapping(address _owner => mapping(address _operator => uint256 _allowance)) internal _allowances;

  constructor(address _voter, address _gaugeFactory) Gauge(_voter, _gaugeFactory) {
    FACTORY_REGISTRY = ILeafVoter(_voter).FACTORY_REGISTRY();
    _initialized = true;
  }

  /// @inheritdoc IV2Gauge
  function initialize(address _stakingToken, address _votingRewardsManager, bool _isPool) external {
    if (_initialized) revert AlreadyInitialized();
    _initialized = true;
    stakingToken = _stakingToken;
    votingRewardsManager = _votingRewardsManager;
    isPool = _isPool;
  }

  /// @inheritdoc IGauge
  function depositFor(uint256 _amount, address _owner) external override(Gauge, IGauge) nonReentrant {
    if (_owner == address(0)) revert ZeroAddress();

    /// @dev Prevents unapproved third parties from resetting early-unstake penalty timers.
    IGaugeFactory.PenaltyConfig memory _penaltyConfig =
      IGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));
    if (
      _penaltyConfig.penaltyRate > 0 && _penaltyConfig.minStakeBlocks > 0
        && !FACTORY_REGISTRY.isMetaRouterApproved({_metaRouter: msg.sender})
    ) revert PenaltyActive();

    _deposit(_amount, _owner);
  }

  /// @inheritdoc IGauge
  function claimEmissions(address _account, address _recipient) external override(Gauge, IGauge) nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();
    if (msg.sender != _account && !approvedForClaim[_account][msg.sender]) revert NotAuthorized();
    _claimEmissions(_account, _recipient, false);
  }

  /// @inheritdoc IGauge
  function collectFees() external nonReentrant returns (uint256 _claimed0, uint256 _claimed1) {
    address _votingRewardsManager = votingRewardsManager;
    if (msg.sender != _votingRewardsManager) revert NotVotingRewardsManager();
    if (!isPool) return (0, 0);
    if (!_isActivated()) return (0, 0);
    if (IGaugeFactory(gaugeFactory).emissionCap({_gauge: address(this)}) == 0) return (0, 0);

    (_claimed0, _claimed1) = IPool(stakingToken).claimFees({_recipient: _votingRewardsManager});
    if (_claimed0 > 0 || _claimed1 > 0) emit ClaimFees(msg.sender, _claimed0, _claimed1);
  }

  /// @inheritdoc IGauge
  function approve(address _operator, uint256 _amount) external {
    if (_operator == address(0)) revert ZeroAddress();
    _allowances[msg.sender][_operator] = _amount;
    emit Approval(msg.sender, _operator, _amount);
  }

  /// @inheritdoc IGauge
  function earned(address _account) external view override(Gauge, IGauge) returns (uint256) {
    uint256 _rewardPerToken = rewardPerTokenStored;
    uint256 _totalSupply = totalSupply;

    /// @dev Project rewardPerToken in memory by pulling the LeafVoter's projected cumulative reward
    ///      share and folding the delta since this gauge's cursor. `projectedCumulativeRewardShare` is the
    ///      read-only twin of the `settleGauge` pull in `_advanceRewards`, so the estimate matches
    ///      a claim in this block. The cumulative is monotonic, so the delta never underflows.
    if (_totalSupply > 0) {
      uint256 _delta = ILeafVoter(voter).projectedCumulativeRewardShare(address(this)) - lastCumulativeRewardShare;
      _rewardPerToken += (_delta * PRECISION) / _totalSupply;
    }

    /// @dev Compute accrued emissions
    uint256 _reward = _earned(_account, _rewardPerToken);

    if (_reward > 0) {
      /// @dev Load the gauge's referral and penalty config
      (address _referral, uint256 _referralShare) = IGaugeFactory(gaugeFactory).referralConfig(address(this));
      IGaugeFactory.PenaltyConfig memory _penaltyConfig =
        IGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));

      /// @dev Apply penalty and referral fees to live emissions
      _reward -= _applyPenalty(depositBlock[_account], _reward, _penaltyConfig);
      _reward -= _applyReferral(_reward, _referral, _referralShare);
    }

    return _reward + deferredEmissions[_account];
  }

  /// @inheritdoc IGauge
  function pendingFees() external view returns (uint256, uint256) {
    if (!isPool) return (0, 0);
    if (!_isActivated()) return (0, 0);
    if (IGaugeFactory(gaugeFactory).emissionCap({_gauge: address(this)}) == 0) return (0, 0);
    // slither-disable-next-line unused-return
    return IPool(stakingToken).pendingFees({_account: address(this)});
  }

  /// @inheritdoc IV2Gauge
  function allowance(address _owner, address _operator) external view returns (uint256) {
    return _allowances[_owner][_operator];
  }

  /// @inheritdoc IGauge
  function isApprovedForAll(address _owner, address _operator) external view override returns (bool) {
    return _allowances[_owner][_operator] == type(uint256).max;
  }

  /// @inheritdoc Gauge
  function _deposit(uint256 _amount, address _owner) internal override {
    if (_amount == 0) revert ZeroAmount();
    _updateRewards(_owner);
    IERC20(stakingToken).safeTransferFrom(msg.sender, address(this), _amount);
    totalSupply += _amount;
    balanceOf[_owner] += _amount;
    depositBlock[_owner] = block.number;
    emit Deposit(msg.sender, _owner, _amount);
  }

  /// @inheritdoc Gauge
  function _withdraw(uint256 _amount, address _account, address _claimRecipient) internal override {
    if (_amount == 0) revert ZeroAmount();

    /// @dev Claim before the balance decrement so the emissions accumulator reads the LP's pre-withdraw stake.
    ///      If minting fails, the emissions are deferred and the withdrawal continues.
    _claimEmissions(_account, _claimRecipient, true);

    totalSupply -= _amount;
    uint256 _balance = balanceOf[_account] - _amount;
    balanceOf[_account] = _balance;
    if (_balance == 0) delete depositBlock[_account];
    IERC20(stakingToken).safeTransfer(msg.sender, _amount);
    emit Withdraw(msg.sender, _account, _amount);
  }

  /**
   * @notice Claims accrued emissions for an account
   * @param _account The address of the LP staker whose emissions are being claimed
   * @param _recipient The recipient of the claimed emissions
   * @param _deferOnFailure Whether to defer emissions instead of reverting when minting fails
   */
  function _claimEmissions(address _account, address _recipient, bool _deferOnFailure) internal {
    /// @dev Advance the accumulator to the current timestamp, capturing any unused emissions
    (uint256 _rewardPerToken, uint128 _unusedEmissions) = _advanceRewards();

    /// @dev Load the gauge's referral and penalty config
    (address _referral, uint256 _referralShare) = IGaugeFactory(gaugeFactory).referralConfig(address(this));
    IGaugeFactory.PenaltyConfig memory _penaltyConfig =
      IGaugeFactory(gaugeFactory).effectivePenaltyConfig(address(this));

    /// @dev Compute the LP's emissions and reset state
    (uint256 _rewardAmount, uint256 _referralAmount, uint256 _penaltyAmount) =
      _computeLPEmissions(_account, _rewardPerToken, _referral, _referralShare, _penaltyConfig);

    if (_referralAmount > 0) {
      deferredReferralEmissions[_referral] += _referralAmount;
      emit ReferralEmissionsDeferred(_account, _referral, _referralAmount);
    }

    uint256 _deferredRewardAmount = deferredEmissions[_account];
    if (_deferredRewardAmount > 0) delete deferredEmissions[_account];

    _unusedEmissions += _penaltyAmount.toUint128();
    if (_unusedEmissions > 0) {
      // slither-disable-next-line reentrancy-no-eth
      ILeafVoter(voter).forfeitEmissions(_unusedEmissions);
    }

    uint256 _totalRewardAmount = _rewardAmount + _deferredRewardAmount;
    if (_totalRewardAmount > 0) {
      (address[] memory _recipients, uint128[] memory _amounts) = _buildMintArrays(_recipient, _totalRewardAmount);
      if (_deferOnFailure) {
        // slither-disable-next-line reentrancy-no-eth
        try ILeafVoter(voter).mintEmissions(_recipients, _amounts) {}
        catch {
          _deferEmissions(_account, _rewardAmount, _deferredRewardAmount);
          return;
        }
      } else {
        // slither-disable-next-line reentrancy-no-eth
        ILeafVoter(voter).mintEmissions(_recipients, _amounts);
      }

      if (_rewardAmount > 0) emit EmissionsClaimed(_account, _recipient, _rewardAmount);
      if (_deferredRewardAmount > 0) {
        emit DeferredEmissionsClaimed(_account, _recipient, _deferredRewardAmount);
      }
    }
  }

  /**
   * @notice Defers an account's emissions when minting fails
   * @param _account The address of the LP staker
   * @param _rewardAmount The newly accrued emissions
   * @param _deferredRewardAmount The previously deferred emissions
   */
  function _deferEmissions(address _account, uint256 _rewardAmount, uint256 _deferredRewardAmount) internal {
    deferredEmissions[_account] = _rewardAmount + _deferredRewardAmount;
    if (_rewardAmount > 0) emit EmissionsDeferred(_account, _rewardAmount);
  }

  /**
   * @notice Computes the LP's claimable emissions and advances its reward-per-token checkpoint
   * @dev Assumes `_rewardPerToken` has been advanced to the current timestamp
   * @dev Applies the early unstake penalty before the referral split
   * @param _account The address of the LP staker
   * @param _rewardPerToken The reward-per-token accumulator value
   * @param _referral The referral reward recipient
   * @param _referralShare The referral share in PIPS
   * @param _penaltyConfig The effective penalty config for this gauge
   * @return The rewards after penalty and referral fee
   * @return The referral amount
   * @return The penalty amount
   */
  function _computeLPEmissions(
    address _account,
    uint256 _rewardPerToken,
    address _referral,
    uint256 _referralShare,
    IGaugeFactory.PenaltyConfig memory _penaltyConfig
  ) internal returns (uint256, uint256, uint256) {
    /// @dev Compute accrued emissions
    uint256 _reward = _earned(_account, _rewardPerToken);

    /// @dev Advance the account's accumulator snapshot
    userRewardPerTokenPaid[_account] = _rewardPerToken;

    if (_reward > 0) {
      /// @dev Clear pending rewards
      delete rewards[_account];

      /// @dev Apply early unstake penalty
      uint256 _penaltyAmount = _applyPenalty(depositBlock[_account], _reward, _penaltyConfig);
      if (_penaltyAmount > 0) {
        _reward -= _penaltyAmount;
        emit EarlyWithdrawPenalty(_account, _penaltyAmount);
      }

      /// @dev Apply referral split
      uint256 _referralAmount = _applyReferral(_reward, _referral, _referralShare);
      if (_referralAmount > 0) {
        _reward -= _referralAmount;
      }

      return (_reward, _referralAmount, _penaltyAmount);
    } else {
      return (0, 0, 0);
    }
  }

  /**
   * @notice Updates the reward accounting for an account.
   * @param _account The account whose rewards are updated.
   */
  function _updateRewards(address _account) internal {
    /// @dev Advance the accumulator to the current timestamp and forfeit any unused emissions
    (uint256 _rewardPerToken, uint128 _unusedEmissions) = _advanceRewards();
    // slither-disable-next-line reentrancy-no-eth
    if (_unusedEmissions > 0) ILeafVoter(voter).forfeitEmissions(_unusedEmissions);

    /// @dev Snapshot the account's earned rewards and reward-per-token paid
    rewards[_account] = _earned(_account, _rewardPerToken);
    userRewardPerTokenPaid[_account] = _rewardPerToken;
  }

  /**
   * @notice Advance the global reward accumulator by pulling the LeafVoter's cumulative reward
   *         share and folding the delta since this gauge's cursor.
   * @dev Pull model: `settleGauge` settles the gauge on the LeafVoter and returns its monotonic
   *      cumulative reward share (TOKEN units). The delta since `lastCumulativeRewardShare` is every
   *      emission accrued to this gauge since the last pull, regardless of how many votes advanced
   *      it — so settling late loses nothing. With no stakers over the pulled span the delta cannot
   *      be distributed and is returned as surplus to forfeit.
   * @return The updated `rewardPerTokenStored`.
   * @return The unused emissions to forfeit.
   */
  function _advanceRewards() internal returns (uint256, uint128) {
    // slither-disable-next-line reentrancy-no-eth
    uint256 _cumulativeRewardShare = ILeafVoter(voter).settleGauge(address(this));
    uint256 _delta = _cumulativeRewardShare - lastCumulativeRewardShare;
    lastCumulativeRewardShare = _cumulativeRewardShare;

    uint128 _surplus = 0;
    uint256 _rewardPerToken = rewardPerTokenStored;
    if (_delta > 0) {
      if (totalSupply > 0) {
        /// @dev Distribute the pulled emissions across stakers.
        _rewardPerToken += (_delta * PRECISION) / totalSupply;
        rewardPerTokenStored = _rewardPerToken;
      } else {
        /// @dev No stakers over the pulled span; the accrual cannot be distributed, forfeit it.
        _surplus = _delta.toUint128();
      }
    }

    return (_rewardPerToken, _surplus);
  }

  /// @inheritdoc Gauge
  function _setApprovalForAll(address _operator, bool _approved) internal override {
    _allowances[msg.sender][_operator] = _approved ? type(uint256).max : 0;
  }

  /// @inheritdoc Gauge
  function _authorizeWithdrawalFrom(uint256 _amount, address _account) internal override {
    uint256 _remaining = _allowances[_account][msg.sender];
    /// @dev The max-value sentinel (set by setApprovalForAll) grants unlimited allowance and is not decremented.
    if (_remaining != type(uint256).max) {
      if (_remaining < _amount) revert InsufficientAllowance();
      _allowances[_account][msg.sender] = _remaining - _amount;
    }
  }

  /**
   * @notice Calculate an account's accrued rewards against a reward-per-token accumulator.
   * @param _account The account whose rewards are calculated.
   * @param _rewardPerToken The reward-per-token accumulator to use.
   * @return The account's accrued rewards.
   */
  function _earned(address _account, uint256 _rewardPerToken) internal view returns (uint256) {
    return (balanceOf[_account] * (_rewardPerToken - userRewardPerTokenPaid[_account])) / PRECISION + rewards[_account];
  }
}
