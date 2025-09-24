// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

interface IGaugeFactory is IAccessControl {
  /**
   * @notice Constructor wiring for a GaugeFactory.
   * @param leafVoter The LeafVoter gauges authorize at runtime. The GaugeManager is read from it.
   * @param votingRewardsFactory The VotingRewardsFactory deploying each gauge's VotingRewardsManager.
   * @param isStable Whether the factory creates stable-pool gauges.
   * @param capAdmin Initial CAP_ADMIN_ROLE holder.
   * @param referralAdmin Initial REFERRAL_ADMIN_ROLE holder.
   * @param penaltyAdmin Initial PENALTY_ADMIN_ROLE holder.
   * @param capOperator Initial CAP_OPERATOR_ROLE holder.
   * @param defaultCap Factory-wide default emission cap.
   * @param operatorMinCap Minimum cap CAP_OPERATOR_ROLE may set.
   * @param operatorMaxCap Maximum cap CAP_OPERATOR_ROLE may set.
   * @param maxMinStakeBlocks Upper bound on per-gauge minimum staking period overrides.
   */
  struct InitParams {
    address leafVoter;
    address votingRewardsFactory;
    bool isStable;
    address capAdmin;
    address referralAdmin;
    address penaltyAdmin;
    address capOperator;
    uint128 defaultCap;
    uint128 operatorMinCap;
    uint128 operatorMaxCap;
    uint256 maxMinStakeBlocks;
  }

  /**
   * @notice Referral configuration for a gauge.
   * @param referral Address receiving the referral share.
   * @param share Referral share in PIPS.
   */
  struct ReferralConfig {
    address referral;
    uint256 share;
  }

  /**
   * @notice Early unstake penalty configuration shared by gauges created by this factory.
   * @param minStakeBlocks Factory-wide default minimum staking period in blocks.
   * @param penaltyRate Penalty rate in PIPS. Zero disables the penalty.
   */
  struct PenaltyConfig {
    uint256 minStakeBlocks;
    uint256 penaltyRate;
  }

  /**
   * @notice Emitted when a new gauge is deployed.
   * @param _gauge Address of the deployed gauge.
   * @param _pool Address of the pool or staking token.
   * @param _isPool Whether the staking token is a V2 pool.
   */
  event GaugeCreated(address indexed _gauge, address indexed _pool, bool _isPool);

  /**
   * @notice Emitted when a gauge emission cap is updated.
   * @param _gauge Address of the gauge.
   * @param _cap Stored cap value written for the gauge.
   * @param _caller Address that updated the cap.
   */
  event EmissionCapSet(address indexed _gauge, uint128 _cap, address indexed _caller);

  /**
   * @notice Emitted when fee flushing fails during forced gauge deactivation.
   * @param _gauge Address of the gauge whose fee flush failed.
   */
  event FeeFlushFailed(address indexed _gauge);

  /**
   * @notice Emitted when the default cap is updated.
   * @param _cap New default cap.
   */
  event DefaultCapSet(uint128 _cap);

  /**
   * @notice Emitted when the operator cap range is updated.
   * @param _minCap New minimum cap allowed for operators.
   * @param _maxCap New maximum cap allowed for operators.
   */
  event OperatorCapRangeSet(uint128 _minCap, uint128 _maxCap);

  /**
   * @notice Emitted when the maximum referral share cap is updated.
   * @param _cap New maximum share cap in PIPS.
   */
  event MaxShareCapSet(uint256 _cap);

  /**
   * @notice Emitted when a gauge referral configuration is updated.
   * @param _gauge Address of the gauge.
   * @param _referral Address receiving the referral share.
   * @param _share Referral share in PIPS.
   */
  event ReferralConfigSet(address indexed _gauge, address indexed _referral, uint256 _share);

  /**
   * @notice Emitted when the factory-wide penalty configuration is updated.
   * @param _minStakeBlocks New factory-wide minimum staking period in blocks.
   * @param _penaltyRate New penalty rate in PIPS.
   */
  event PenaltyConfigSet(uint256 _minStakeBlocks, uint256 _penaltyRate);

  /**
   * @notice Emitted when a gauge minimum staking period override is updated.
   * @param _gauge Address of the gauge.
   * @param _minStakeBlocks New per-gauge minimum staking period override in blocks.
   */
  event MinStakeBlocksSet(address indexed _gauge, uint256 _minStakeBlocks);

  /**
   * @notice Thrown when a caller is not authorized.
   */
  error NotAuthorized();

  /**
   * @notice Thrown when a zero address is invalid.
   */
  error ZeroAddress();

  /**
   * @notice Thrown when an operator cap is outside the allowed range.
   */
  error CapOutOfOperatorRange();

  /**
   * @notice Thrown when a cap range is invalid.
   */
  error InvalidCapRange();

  /**
   * @notice Thrown when attempting to set the default cap to zero.
   */
  error ZeroDefaultCap();

  /**
   * @notice Thrown when a referral share exceeds the maximum share cap.
   */
  error ShareExceedsMax();

  /**
   * @notice Thrown when the maximum share cap exceeds `MAX_PIPS`.
   */
  error InvalidMaxShareCap();

  /**
   * @notice Thrown when a penalty rate exceeds `MAX_PIPS`.
   */
  error InvalidPenaltyRate();

  /**
   * @notice Thrown when a minimum staking period exceeds MAX_MIN_STAKE_BLOCKS.
   */
  error InvalidMinStakeBlocks();

  /**
   * @notice Thrown when an address is not a gauge created by this factory.
   */
  error InvalidGauge();

  /**
   * @notice Thrown when a referral configuration is invalid.
   */
  error InvalidReferral();

  /**
   * @notice Deploy a gauge for `_target` together with its VotingRewardsManager.
   * @dev Only callable by the GaugeManager. The VotingRewardsManager is
   *      deployed through the VotingRewardsFactory against the precomputed
   *      gauge address before the gauge itself, seeded with the pool's pair
   *      tokens as the initial reward tokens. Unknown params are ignored.
   * @param _target Address of the pool the gauge points at.
   * @param _factoryData Optional encoded creation parameters.
   * @return _gauge Address of the deployed gauge.
   * @return _rewards Address of the deployed VotingRewardsManager.
   */
  function createGauge(address _target, bytes calldata _factoryData) external returns (address _gauge, address _rewards);

  /**
   * @notice Set the default emission cap for future gauges.
   * @dev Existing gauges retain their stored emission caps.
   * @param _cap New default cap.
   */
  function setDefaultCap(uint128 _cap) external;

  /**
   * @notice Set a per-gauge cap.
   * @param _gauge Address of the gauge.
   * @param _cap New stored cap value.
   */
  function setEmissionCap(address _gauge, uint128 _cap) external;

  /**
   * @notice Sets a gauge's emission cap to zero without requiring a successful fee flush.
   * @dev Only callable by the emergency council.
   * @param _gauge Address of the gauge to deactivate.
   */
  function clearEmissionCap(address _gauge) external;

  /**
   * @notice Set the inclusive range within which CAP_OPERATOR_ROLE may set per-gauge caps.
   * @param _minCap New minimum cap.
   * @param _maxCap New maximum cap.
   */
  function setOperatorCapRange(uint128 _minCap, uint128 _maxCap) external;

  /**
   * @notice Set the factory-wide ceiling on per-gauge referral shares.
   * @param _cap New maximum referral share cap in PIPS.
   */
  function setMaxShareCap(uint256 _cap) external;

  /**
   * @notice Set or clear referral config for `_gauge`.
   * @param _gauge Address of the gauge.
   * @param _referral Address receiving the referral share.
   * @param _share Referral share in PIPS.
   */
  function setReferralConfig(address _gauge, address _referral, uint256 _share) external;

  /**
   * @notice Set the factory-wide penalty defaults.
   * @param _minStakeBlocks New factory-wide minimum staking period in blocks.
   * @param _penaltyRate New penalty rate in PIPS.
   */
  function setPenaltyConfig(uint256 _minStakeBlocks, uint256 _penaltyRate) external;

  /**
   * @notice Set a per-gauge minimum staking period override.
   * @param _gauge Address of the gauge.
   * @param _minStakeBlocks New minimum staking period override in blocks.
   */
  function setMinStakeBlocks(address _gauge, uint256 _minStakeBlocks) external;

  /**
   * @notice Initial value of `maxShareCap`.
   * @return _defaultMaxShareCap Default max share cap in PIPS.
   */
  function DEFAULT_MAX_SHARE_CAP() external view returns (uint256 _defaultMaxShareCap);

  /**
   * @notice Initial value of `minStakeBlocks`.
   * @return _defaultMinStakeBlocks Default minimum staking period in blocks.
   */
  function DEFAULT_MIN_STAKE_BLOCKS() external view returns (uint256 _defaultMinStakeBlocks);

  /**
   * @notice Initial value of `penaltyRate`.
   * @return _defaultPenaltyRate Default penalty rate in PIPS.
   */
  function DEFAULT_PENALTY_RATE() external view returns (uint256 _defaultPenaltyRate);

  /**
   * @notice OZ AccessControl role for cap administration.
   * @return _capAdminRole Cap admin role identifier.
   */
  function CAP_ADMIN_ROLE() external view returns (bytes32 _capAdminRole);

  /**
   * @notice OZ AccessControl role for referral configuration.
   * @return _referralAdminRole Referral admin role identifier.
   */
  function REFERRAL_ADMIN_ROLE() external view returns (bytes32 _referralAdminRole);

  /**
   * @notice OZ AccessControl role for penalty configuration.
   * @return _penaltyAdminRole Penalty admin role identifier.
   */
  function PENALTY_ADMIN_ROLE() external view returns (bytes32 _penaltyAdminRole);

  /**
   * @notice OZ AccessControl role for per-gauge cap adjustments.
   * @return _capOperatorRole Cap operator role identifier.
   */
  function CAP_OPERATOR_ROLE() external view returns (bytes32 _capOperatorRole);

  /**
   * @notice Address of the LeafVoter.
   * @return _leafVoter Address of the LeafVoter.
   */
  function LEAF_VOTER() external view returns (address _leafVoter);

  /**
   * @notice GaugeManager authorized to call `createGauge`.
   * @return _gaugeManager Address of the GaugeManager.
   */
  function GAUGE_MANAGER() external view returns (address _gaugeManager);

  /**
   * @notice VotingRewardsFactory deploying each gauge's VotingRewardsManager.
   * @return _votingRewardsFactory Address of the VotingRewardsFactory.
   */
  function VOTING_REWARDS_FACTORY() external view returns (address _votingRewardsFactory);

  /**
   * @notice Address of the Gauge implementation used for deterministic clones.
   * @return _implementation Address of the Gauge implementation.
   */
  function IMPLEMENTATION() external view returns (address _implementation);

  /**
   * @notice Computes the deterministic clone address for the gauge deployed
   *         over `_pool`.
   * @dev The salt derives from the pool address, so the prediction is fixed
   *      and unique per pool. The registry links at most one gauge per
   *      target, so no second deployment ever needs a fresh address.
   * @param _pool Address of the pool or staking token.
   * @return _gauge Predicted gauge address.
   */
  function computeGaugeAddress(address _pool) external view returns (address _gauge);

  /**
   * @notice True if this factory creates stable-pool gauges.
   * @return _isStable Whether gauges created by this factory are for stable pools.
   */
  function IS_STABLE() external view returns (bool _isStable);

  /**
   * @notice Upper bound on per-gauge minimum staking period overrides.
   * @return _maxMinStakeBlocks Maximum minimum staking period in blocks.
   */
  function MAX_MIN_STAKE_BLOCKS() external view returns (uint256 _maxMinStakeBlocks);

  /**
   * @notice String identifying the gauge type produced by this factory.
   * @return _gaugeType Gauge type string.
   */
  function GAUGE_TYPE() external view returns (string memory _gaugeType);

  /**
   * @notice True if `_gauge` was deployed by this factory.
   * @param _gauge Address to check.
   * @return _isGauge True if `_gauge` was deployed by this factory.
   */
  function isGauge(address _gauge) external view returns (bool _isGauge);

  /**
   * @notice Emission cap stored for `_gauge`.
   * @param _gauge Address of the gauge.
   * @return _cap Stored emission cap.
   */
  function emissionCap(address _gauge) external view returns (uint128 _cap);

  /**
   * @notice Factory-wide default cap.
   * @return _defaultCap Current default cap.
   */
  function defaultCap() external view returns (uint128 _defaultCap);

  /**
   * @notice Minimum cap CAP_OPERATOR_ROLE may set on any gauge.
   * @return _operatorMinCap Operator minimum cap.
   */
  function operatorMinCap() external view returns (uint128 _operatorMinCap);

  /**
   * @notice Maximum cap CAP_OPERATOR_ROLE may set on any gauge.
   * @return _operatorMaxCap Operator maximum cap.
   */
  function operatorMaxCap() external view returns (uint128 _operatorMaxCap);

  /**
   * @notice Factory-wide ceiling on per-gauge referral shares.
   * @return _maxShareCap Maximum referral share cap in PIPS.
   */
  function maxShareCap() external view returns (uint256 _maxShareCap);

  /**
   * @notice Returns the referral configuration for `_gauge`.
   * @param _gauge Address of the gauge.
   * @return _referral Address receiving the referral share.
   * @return _share Referral share in PIPS.
   */
  function referralConfig(address _gauge) external view returns (address _referral, uint256 _share);

  /**
   * @notice Factory-wide early unstake penalty defaults.
   * @return _config Current penalty configuration.
   */
  function penaltyConfig() external view returns (PenaltyConfig memory _config);

  /**
   * @notice Effective penalty config for `_gauge`.
   * @param _gauge The gauge to query.
   * @return The penalty config with the effective minimum-stake threshold.
   */
  function effectivePenaltyConfig(address _gauge) external view returns (PenaltyConfig memory);

  /**
   * @notice Resolves the effective minimum-stake threshold for `_gauge`.
   * @param _gauge Address of the gauge.
   * @return _minStakeBlocks Effective minimum staking period in blocks.
   */
  function minStakeBlocks(address _gauge) external view returns (uint256 _minStakeBlocks);
}
