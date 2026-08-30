// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {AccessControl} from '@openzeppelin/contracts/access/AccessControl.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';

import {ParamsLib} from 'V3/libraries/ParamsLib.sol';
import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {Roles} from 'V3/libraries/Roles.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IVotingRewardsFactory} from 'V3/interfaces/rewards/IVotingRewardsFactory.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {V2Gauge} from 'V3/gauges/V2Gauge.sol';

contract GaugeFactory is AccessControl, IGaugeFactory {
  /// @inheritdoc IGaugeFactory
  string public constant override GAUGE_TYPE = 'v2';
  /// @inheritdoc IGaugeFactory
  bytes32 public constant CAP_ADMIN_ROLE = keccak256('CAP_ADMIN_ROLE');
  /// @inheritdoc IGaugeFactory
  bytes32 public constant REFERRAL_ADMIN_ROLE = keccak256('REFERRAL_ADMIN_ROLE');
  /// @inheritdoc IGaugeFactory
  bytes32 public constant PENALTY_ADMIN_ROLE = keccak256('PENALTY_ADMIN_ROLE');
  /// @inheritdoc IGaugeFactory
  bytes32 public constant CAP_OPERATOR_ROLE = keccak256('CAP_OPERATOR_ROLE');

  /// @inheritdoc IGaugeFactory
  uint256 public constant DEFAULT_MAX_SHARE_CAP = 50_000;
  /// @inheritdoc IGaugeFactory
  uint256 public constant DEFAULT_MIN_STAKE_BLOCKS = 5;
  /// @inheritdoc IGaugeFactory
  uint256 public constant DEFAULT_PENALTY_RATE = 1_000_000;

  /// @inheritdoc IGaugeFactory
  address public immutable LEAF_VOTER;
  /// @inheritdoc IGaugeFactory
  address public immutable GAUGE_MANAGER;
  /// @inheritdoc IGaugeFactory
  address public immutable VOTING_REWARDS_FACTORY;
  /// @inheritdoc IGaugeFactory
  address public immutable IMPLEMENTATION;
  /// @inheritdoc IGaugeFactory
  bool public immutable IS_STABLE;
  /// @inheritdoc IGaugeFactory
  uint256 public immutable MAX_MIN_STAKE_BLOCKS;

  /// @inheritdoc IGaugeFactory
  uint128 public defaultCap;
  /// @inheritdoc IGaugeFactory
  uint128 public operatorMinCap;
  /// @inheritdoc IGaugeFactory
  uint128 public operatorMaxCap;
  /// @inheritdoc IGaugeFactory
  uint256 public maxShareCap;
  /// @inheritdoc IGaugeFactory
  mapping(address _gauge => bool _isGauge) public isGauge;
  /// @inheritdoc IGaugeFactory
  mapping(address _gauge => uint128 _cap) public emissionCap;
  /// @inheritdoc IGaugeFactory
  mapping(address _gauge => ReferralConfig _config) public referralConfig;

  PenaltyConfig internal _penaltyConfig;
  mapping(address _gauge => uint256 _minStakeBlocks) internal _minStakeBlocks;

  /**
   * @notice Wire the factory references, caps, penalty defaults and initial
   *         role holders, and deploy the disabled gauge implementation.
   * @dev The GaugeManager is read from the LeafVoter so both always agree on
   *      it. Reverts when any wired address or role holder is zero, the
   *      default cap is zero, the operator cap range is invalid or the max
   *      min stake blocks is below the default.
   * @param _params The constructor wiring.
   */
  constructor(InitParams memory _params) {
    if (
      _params.leafVoter == address(0) || _params.votingRewardsFactory == address(0) || _params.capAdmin == address(0)
        || _params.referralAdmin == address(0) || _params.penaltyAdmin == address(0)
        || _params.capOperator == address(0)
    ) {
      revert ZeroAddress();
    }
    if (_params.defaultCap == 0) revert ZeroDefaultCap();
    if (_params.operatorMinCap == 0 || _params.operatorMinCap > _params.operatorMaxCap) revert InvalidCapRange();
    if (_params.maxMinStakeBlocks < DEFAULT_MIN_STAKE_BLOCKS) revert InvalidMinStakeBlocks();

    address _gaugeManager = ILeafVoter(_params.leafVoter).GAUGE_MANAGER();
    if (_gaugeManager == address(0)) revert ZeroAddress();

    LEAF_VOTER = _params.leafVoter;
    GAUGE_MANAGER = _gaugeManager;
    VOTING_REWARDS_FACTORY = _params.votingRewardsFactory;
    IMPLEMENTATION = address(new V2Gauge({_voter: LEAF_VOTER, _gaugeFactory: address(this)}));
    IS_STABLE = _params.isStable;
    defaultCap = _params.defaultCap;
    operatorMinCap = _params.operatorMinCap;
    operatorMaxCap = _params.operatorMaxCap;
    MAX_MIN_STAKE_BLOCKS = _params.maxMinStakeBlocks;
    maxShareCap = DEFAULT_MAX_SHARE_CAP;
    _penaltyConfig = PenaltyConfig({minStakeBlocks: DEFAULT_MIN_STAKE_BLOCKS, penaltyRate: DEFAULT_PENALTY_RATE});

    _setRoleAdmin(CAP_ADMIN_ROLE, CAP_ADMIN_ROLE);
    _setRoleAdmin(REFERRAL_ADMIN_ROLE, REFERRAL_ADMIN_ROLE);
    _setRoleAdmin(PENALTY_ADMIN_ROLE, PENALTY_ADMIN_ROLE);
    _setRoleAdmin(CAP_OPERATOR_ROLE, CAP_ADMIN_ROLE);

    _grantRole(CAP_ADMIN_ROLE, _params.capAdmin);
    _grantRole(REFERRAL_ADMIN_ROLE, _params.referralAdmin);
    _grantRole(PENALTY_ADMIN_ROLE, _params.penaltyAdmin);
    _grantRole(CAP_OPERATOR_ROLE, _params.capOperator);
  }

  /// @inheritdoc IGaugeFactory
  function createGauge(
    address _target,
    bytes calldata _factoryData
  ) external returns (address _gauge, address _rewards) {
    if (msg.sender != GAUGE_MANAGER) revert NotAuthorized();

    // The pool's pair tokens are the fee reward tokens, derived here rather
    // than trusted from the caller.
    address[] memory _rewardTokens = new address[](2);
    _rewardTokens[0] = IPool(_target).token0();
    _rewardTokens[1] = IPool(_target).token1();

    bytes32 _salt = _gaugeSalt(_target);
    address _predicted =
      Clones.predictDeterministicAddress({implementation: IMPLEMENTATION, salt: _salt, deployer: address(this)});

    // The clone address is deterministic, so all effects are written against
    // the predicted address before any external interaction.
    isGauge[_predicted] = true;
    emissionCap[_predicted] = defaultCap;

    if (ParamsLib.isReferral(_factoryData)) {
      (address _referral, uint256 _share) = ParamsLib.decodeReferral(_factoryData);
      _setReferralConfig(_predicted, _referral, _share);
    }

    emit GaugeCreated({_gauge: _predicted, _pool: _target, _isPool: true});

    _rewards =
      IVotingRewardsFactory(VOTING_REWARDS_FACTORY).createRewards({_gauge: _predicted, _rewards: _rewardTokens});

    _gauge = Clones.cloneDeterministic({implementation: IMPLEMENTATION, salt: _salt});
    V2Gauge(_gauge).initialize({_stakingToken: _target, _votingRewardsManager: _rewards, _isPool: true});
  }

  /// @inheritdoc IGaugeFactory
  function setDefaultCap(uint128 _cap) external onlyRole(CAP_ADMIN_ROLE) {
    if (_cap == 0) revert ZeroDefaultCap();
    defaultCap = _cap;
    emit DefaultCapSet(_cap);
  }

  // slither-disable-start reentrancy-no-eth
  /// @inheritdoc IGaugeFactory
  function setEmissionCap(address _gauge, uint128 _cap) external {
    if (!isGauge[_gauge]) revert InvalidGauge();

    bool _shouldFlushFees = false;
    if (hasRole(CAP_ADMIN_ROLE, msg.sender)) {
      if (_cap == 0) {
        _shouldFlushFees = true;
      }
    } else if (_cap == 0 && ILeafVoter(LEAF_VOTER).hasRole(Roles.EMERGENCY_COUNCIL_ROLE, msg.sender)) {
      _shouldFlushFees = true;
    } else if (hasRole(CAP_OPERATOR_ROLE, msg.sender)) {
      if (emissionCap[_gauge] == 0) revert NotAuthorized();
      if (_cap < operatorMinCap || _cap > operatorMaxCap) revert CapOutOfOperatorRange();
    } else {
      revert NotAuthorized();
    }

    _settleGauge(_gauge);
    if (_shouldFlushFees) {
      _flushFees(_gauge);
    }
    _setEmissionCap(_gauge, _cap);
    // slither-disable-end reentrancy-no-eth
  }

  // slither-disable-start reentrancy-no-eth
  /// @inheritdoc IGaugeFactory
  function clearEmissionCap(address _gauge) external {
    if (!isGauge[_gauge]) revert InvalidGauge();
    if (!ILeafVoter(LEAF_VOTER).hasRole(Roles.EMERGENCY_COUNCIL_ROLE, msg.sender)) revert NotAuthorized();

    _settleGauge(_gauge);

    address _votingRewardsManager = IGauge(_gauge).votingRewardsManager();
    try IVotingRewardsManager(_votingRewardsManager).flushFees() {}
    catch {
      emit FeeFlushFailed(_gauge);
    }

    _setEmissionCap(_gauge, 0);
    // slither-disable-end reentrancy-no-eth
  }

  /// @inheritdoc IGaugeFactory
  function setOperatorCapRange(uint128 _minCap, uint128 _maxCap) external onlyRole(CAP_ADMIN_ROLE) {
    if (_minCap == 0 || _minCap > _maxCap) revert InvalidCapRange();
    operatorMinCap = _minCap;
    operatorMaxCap = _maxCap;
    emit OperatorCapRangeSet(_minCap, _maxCap);
  }

  /// @inheritdoc IGaugeFactory
  function setMaxShareCap(uint256 _cap) external onlyRole(REFERRAL_ADMIN_ROLE) {
    if (_cap > MAX_PIPS) revert InvalidMaxShareCap();
    maxShareCap = _cap;
    emit MaxShareCapSet(_cap);
  }

  /// @inheritdoc IGaugeFactory
  function setReferralConfig(address _gauge, address _referral, uint256 _share) external onlyRole(REFERRAL_ADMIN_ROLE) {
    if (!isGauge[_gauge]) revert InvalidGauge();
    _setReferralConfig(_gauge, _referral, _share);
  }

  /// @inheritdoc IGaugeFactory
  function setPenaltyConfig(uint256 _minStakeBlocksValue, uint256 _penaltyRate) external onlyRole(PENALTY_ADMIN_ROLE) {
    if (_penaltyRate > MAX_PIPS) revert InvalidPenaltyRate();
    if (_minStakeBlocksValue > MAX_MIN_STAKE_BLOCKS) revert InvalidMinStakeBlocks();
    _penaltyConfig = PenaltyConfig({minStakeBlocks: _minStakeBlocksValue, penaltyRate: _penaltyRate});
    emit PenaltyConfigSet(_minStakeBlocksValue, _penaltyRate);
  }

  /// @inheritdoc IGaugeFactory
  function setMinStakeBlocks(address _gauge, uint256 _minStakeBlocksValue) external onlyRole(PENALTY_ADMIN_ROLE) {
    if (!isGauge[_gauge]) revert InvalidGauge();
    if (_minStakeBlocksValue > MAX_MIN_STAKE_BLOCKS) revert InvalidMinStakeBlocks();
    _minStakeBlocks[_gauge] = _minStakeBlocksValue;
    emit MinStakeBlocksSet(_gauge, _minStakeBlocksValue);
  }

  /// @inheritdoc IGaugeFactory
  function computeGaugeAddress(address _pool) external view returns (address _gauge) {
    _gauge = Clones.predictDeterministicAddress({
      implementation: IMPLEMENTATION, salt: _gaugeSalt(_pool), deployer: address(this)
    });
  }

  /// @inheritdoc IGaugeFactory
  function penaltyConfig() external view returns (PenaltyConfig memory _config) {
    _config = _penaltyConfig;
  }

  /// @inheritdoc IGaugeFactory
  function effectivePenaltyConfig(address _gauge) external view returns (PenaltyConfig memory) {
    return PenaltyConfig({minStakeBlocks: minStakeBlocks(_gauge), penaltyRate: _penaltyConfig.penaltyRate});
  }

  /// @inheritdoc IGaugeFactory
  function minStakeBlocks(address _gauge) public view returns (uint256 _minStakeBlocksValue) {
    _minStakeBlocksValue = _minStakeBlocks[_gauge];
    if (_minStakeBlocksValue == 0) {
      _minStakeBlocksValue = _penaltyConfig.minStakeBlocks;
    }
  }

  /**
   * @notice Sets the referral configuration for a gauge.
   * @param _gauge The gauge whose referral config is updated.
   * @param _referral The referral reward recipient.
   * @param _share The referral share in PIPS.
   */
  function _setReferralConfig(address _gauge, address _referral, uint256 _share) internal {
    if (_share > maxShareCap) revert ShareExceedsMax();
    if (_share > 0 && _referral == address(0)) revert InvalidReferral();

    referralConfig[_gauge] = ReferralConfig({referral: _referral, share: _share});
    emit ReferralConfigSet({_gauge: _gauge, _referral: _referral, _share: _share});
  }

  /**
   * @notice Sets the stored emission cap for a gauge.
   * @param _gauge The gauge whose cap is updated.
   * @param _cap The stored emission cap.
   */
  function _setEmissionCap(address _gauge, uint128 _cap) internal {
    emissionCap[_gauge] = _cap;
    emit EmissionCapSet({_gauge: _gauge, _cap: _cap, _caller: msg.sender});
  }

  /**
   * @notice Settles a gauge through the LeafVoter.
   * @param _gauge The gauge to settle.
   */
  function _settleGauge(address _gauge) internal {
    // slither-disable-next-line unused-return
    ILeafVoter(LEAF_VOTER).settleGauge(_gauge);
  }

  /**
   * @notice Flushes collected fees for a gauge's VotingRewardsManager.
   * @param _gauge The gauge whose fees are flushed.
   */
  function _flushFees(address _gauge) internal {
    IVotingRewardsManager(IGauge(_gauge).votingRewardsManager()).flushFees();
  }

  /**
   * @notice Computes the deterministic deployment salt for a pool's gauge.
   * @dev The pool address alone keys the salt, so distinct targets can never
   *      collide regardless of the target factory's uniqueness semantics. A
   *      repeat deployment over the same pool reverts on the CREATE2
   *      collision.
   * @param _pool The pool used to derive the gauge salt.
   * @return _salt The deterministic deployment salt.
   */
  function _gaugeSalt(address _pool) internal pure returns (bytes32 _salt) {
    _salt = keccak256(abi.encodePacked(_pool));
  }
}
