// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {RewardsLogicLibrary} from 'V3/libraries/RewardsLogicLibrary.sol';

import {IIncentiveStreaming} from 'V3/interfaces/rewards/IIncentiveStreaming.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

abstract contract IncentiveStreaming is ReentrancyGuardTransient, IIncentiveStreaming {
  using EnumerableSet for EnumerableSet.UintSet;
  using EnumerableSet for EnumerableSet.AddressSet;

  /// @dev Minimum streaming duration of a program.
  uint256 internal constant _MIN_DURATION = 7 days;

  /// @inheritdoc IIncentiveStreaming
  address public immutable voter;

  /// @inheritdoc IIncentiveStreaming
  uint256 public incentiveCount;

  /// @dev Incentive program records keyed by program ID.
  mapping(uint256 _programId => IncentiveProgram _incentiveProgram) internal _incentives;
  /// @dev Program ID sets grouped by incentive token for on-chain discovery.
  mapping(address _token => EnumerableSet.UintSet _programIds) internal _incentivesByToken;
  /// @dev Program ID sets grouped by creator for on-chain discovery.
  mapping(address _creator => EnumerableSet.UintSet _programIds) internal _incentivesByCreator;
  /// @dev Set of reward tokens registered against at least one incentive program.
  EnumerableSet.AddressSet internal _rewards;
  /// @inheritdoc IIncentiveStreaming
  mapping(uint256 _checkpointIndex => SupplyAccumulator _accumulator) public supplyAccumulatorAt;
  /// @inheritdoc IIncentiveStreaming
  mapping(uint256 _programId => uint256 _amount) public remainingAmount;
  /// @inheritdoc IIncentiveStreaming
  mapping(uint256 _programId => uint256 _amount) public sweptAmount;

  /**
   * @notice Constructor function to initialize the contract
   * @param _voter Address of the voter contract
   * @param _initialRewards Array of initial reward token addresses
   */
  constructor(address _voter, address[] memory _initialRewards) {
    if (_voter == address(0)) revert ZeroAddress();
    voter = _voter;

    address _rewardToken;
    uint256 _length = _initialRewards.length;
    for (uint256 _i; _i < _length; ++_i) {
      _rewardToken = _initialRewards[_i];
      if (_rewardToken != address(0)) {
        // slither-disable-next-line unused-return
        _rewards.add(_rewardToken);
      }
    }
  }

  /// @inheritdoc IIncentiveStreaming
  function createIncentiveProgram(
    address _token,
    uint256 _amount,
    uint48 _start,
    uint48 _duration
  ) external nonReentrant returns (uint256) {
    if (_duration < _MIN_DURATION) revert InsufficientDuration();
    if (_amount < _duration) revert InsufficientAmount();
    if (_start < block.timestamp) revert InvalidStart();

    if (!ITokenRegistry(tokenRegistry()).isListed(_token)) revert NotListed();

    _initializeGlobalRewardHistory();

    uint256 _programId = ++incentiveCount;
    RewardsLogicLibrary.createIncentiveProgram({
      _incentives: _incentives,
      _incentivesByToken: _incentivesByToken,
      _incentivesByCreator: _incentivesByCreator,
      _rewards: _rewards,
      _remainingAmount: remainingAmount,
      _programId: _programId,
      _token: _token,
      _amount: _amount,
      _start: _start,
      _duration: _duration
    });

    return _programId;
  }

  /// @inheritdoc IIncentiveStreaming
  function incentive(uint256 _programId) external view returns (IncentiveProgram memory) {
    return _incentives[_programId];
  }

  /// @inheritdoc IIncentiveStreaming
  function incentives(uint256[] calldata _programIds) external view returns (IncentiveProgram[] memory) {
    uint256 _length = _programIds.length;
    IncentiveProgram[] memory _incentivePrograms = new IncentiveProgram[](_length);

    for (uint256 _i; _i < _length; ++_i) {
      _incentivePrograms[_i] = _incentives[_programIds[_i]];
    }
    return _incentivePrograms;
  }

  /// @inheritdoc IIncentiveStreaming
  function incentiveCountByToken(address _token) external view returns (uint256) {
    return _incentivesByToken[_token].length();
  }

  /// @inheritdoc IIncentiveStreaming
  function incentivesByToken(address _token, uint256 _start, uint256 _end) external view returns (uint256[] memory) {
    return _incentivesByToken[_token].values(_start, _end);
  }

  /// @inheritdoc IIncentiveStreaming
  function incentiveCountByCreator(address _creator) external view returns (uint256) {
    return _incentivesByCreator[_creator].length();
  }

  /// @inheritdoc IIncentiveStreaming
  function incentivesByCreator(
    address _creator,
    uint256 _start,
    uint256 _end
  ) external view returns (uint256[] memory) {
    return _incentivesByCreator[_creator].values(_start, _end);
  }

  /// @inheritdoc IIncentiveStreaming
  function rewards(uint256 _index) external view returns (address) {
    return _rewards.at(_index);
  }

  /// @inheritdoc IIncentiveStreaming
  function isReward(address _token) external view returns (bool) {
    return _rewards.contains(_token);
  }

  /// @inheritdoc IIncentiveStreaming
  function rewardsListLength() external view returns (uint256) {
    return _rewards.length();
  }

  /// @inheritdoc IIncentiveStreaming
  function tokenRegistry() public view returns (address) {
    return ILeafVoter(voter).FACTORY_REGISTRY().tokenRegistry();
  }

  /**
   * @notice Decreases an incentive program's remaining balance
   * @param _programId The incentive program ID
   * @param _amount The amount to debit
   */
  function _debitIncentive(uint256 _programId, uint256 _amount) internal {
    uint256 _remaining = remainingAmount[_programId];
    if (_amount > _remaining) revert InsufficientProgramBalance();

    remainingAmount[_programId] = _remaining - _amount;
  }

  /**
   * @notice Initializes global reward history or validates existing history before recording an incentive program
   */
  function _initializeGlobalRewardHistory() internal virtual;

  /**
   * @notice Snapshot the supply accumulator values at the given global checkpoint index
   * @dev Called when recording a global checkpoint.
   * @param _checkpointIndex The target global checkpoint index
   * @param _sharePerVote Running supply accumulator
   * @param _weightedSharePerVote Running time-weighted supply accumulator
   */
  function _snapshotIncentiveAccumulator(
    uint256 _checkpointIndex,
    uint256 _sharePerVote,
    uint256 _weightedSharePerVote
  ) internal {
    supplyAccumulatorAt[_checkpointIndex] = SupplyAccumulator({
      sharePerVote: _sharePerVote, weightedSharePerVote: _weightedSharePerVote
    });
  }
}
