// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Pausable} from '@openzeppelin/contracts/utils/Pausable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';
import {IV2Minter} from 'V3/interfaces/migration/v2/IV2Minter.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

/**
 * @title V2-to-V3 Migration
 * @notice Shared migration engine for Aerodrome and Velodrome positions
 */
abstract contract Migration is Ownable, Pausable, ReentrancyGuardTransient, IMigration {
  using SafeCastLibrary for uint256;
  using SafeCastLibrary for int128;
  using SafeERC20 for IERC20;

  /// @dev Default defeated result used by the v2 Minter to reduce the tail emission rate
  ProposalState private constant _RESULT = ProposalState.Defeated;

  /// @inheritdoc IMigration
  IERC20 public immutable V2_TOKEN;
  /// @inheritdoc IMigration
  IV2Voter public immutable V2_VOTER;
  /// @inheritdoc IMigration
  IV2Minter public immutable V2_MINTER;
  /// @inheritdoc IMigration
  IV2VotingEscrow public immutable V2_ESCROW;
  /// @inheritdoc IMigration
  uint48 public immutable ACTIVATION;
  /// @inheritdoc IMigration
  uint48 public immutable MIGRATION_OPEN;
  /// @inheritdoc IMigration
  uint256 public immutable MIGRATION_TOKEN_ID;

  /// @inheritdoc IV2EpochGovernor
  ProposalState public override result;

  /// @inheritdoc IMigration
  uint256 public paidBasis;

  /// @inheritdoc IMigration
  mapping(uint256 _tokenId => address _depositor) public depositorOf;
  /// @inheritdoc IMigration
  mapping(uint256 _tokenId => bool _restricted) public restricted;

  /**
   * @notice Initializes the shared migration engine and creates the permanent migration veNFT
   * @param _params Shared migration parameters
   */
  // slither-disable-start arbitrary-send-erc20
  constructor(BaseParams memory _params) Ownable(_params.owner) {
    if (
      _params.deployer == address(0) || _params.v2Token == address(0) || _params.escrow == address(0)
        || _params.voter == address(0)
    ) {
      revert ZeroAddress();
    }
    if (_params.migrationOpen % WEEK != 0 || _params.migrationOpen <= block.timestamp) revert InvalidOpen();

    V2_TOKEN = IERC20(_params.v2Token);
    V2_VOTER = IV2Voter(_params.voter);
    V2_ESCROW = IV2VotingEscrow(_params.escrow);
    V2_MINTER = IV2Minter(IV2Voter(_params.voter).minter());
    MIGRATION_OPEN = _params.migrationOpen;
    ACTIVATION = _params.migrationOpen + WEEK;
    result = _RESULT;

    uint256 _restrictedLength = _params.restricted.length;
    for (uint256 _i; _i < _restrictedLength; ++_i) {
      restricted[_params.restricted[_i]] = true;
      emit RestrictionsSet(_params.restricted[_i]);
    }

    IERC20(_params.v2Token).safeTransferFrom(_params.deployer, address(this), PRECISION);
    IERC20(_params.v2Token).forceApprove(_params.escrow, PRECISION);

    /// @dev Create the permanent v2 migration veNFT
    uint256 _migrationTokenId = IV2VotingEscrow(_params.escrow).createLock(PRECISION, MAXTIME);
    IV2VotingEscrow(_params.escrow).lockPermanent(_migrationTokenId);
    MIGRATION_TOKEN_ID = _migrationTokenId;
  }

  // slither-disable-end arbitrary-send-erc20

  // slither-disable-start locked-ether
  /// @inheritdoc IMigration
  function depositVeNFT(
    uint256 _tokenId,
    address _recipient
  ) external payable virtual override nonReentrant whenNotPaused {
    _checkValue();

    if (block.timestamp < MIGRATION_OPEN) revert MigrationNotOpen();
    if (_recipient == address(0)) revert ZeroAddress();
    if (restricted[_tokenId]) revert Restricted(_tokenId);
    if (V2_ESCROW.escrowType(_tokenId) != IV2VotingEscrow.EscrowType.NORMAL) revert NotNormalVeNFT(_tokenId);

    IV2VotingEscrow.LockedBalance memory _locked = V2_ESCROW.locked(_tokenId);
    uint256 _amount = _locked.amount.toUint256();
    if (_amount == 0) revert NothingToConvert(_tokenId);
    if (V2_ESCROW.voted(_tokenId)) revert AlreadyVoted(_tokenId);
    if (V2_ESCROW.ownerOf(_tokenId) != msg.sender) revert NotOwner(_tokenId);

    _checkBudget(_amount);

    /// @dev Update conversion accounting and record the depositor
    paidBasis += _amount;
    depositorOf[_tokenId] = msg.sender;

    /// @dev Unlock permanent veNFTs and merge the deposited veNFT into the migration veNFT
    if (_locked.isPermanent) V2_ESCROW.unlockPermanent(_tokenId);
    V2_ESCROW.merge(_tokenId, MIGRATION_TOKEN_ID);

    /// @dev Settle the converted position
    (bool _isLiquid, uint256 _out) = _settleStake(_recipient, _amount, _locked.end, _locked.isPermanent);

    emit VeNFTMigrated({
      _depositor: msg.sender,
      _recipient: _recipient,
      _v2TokenId: _tokenId,
      _amount: _amount,
      _out: _out,
      _permanent: _locked.isPermanent,
      _liquid: _isLiquid
    });
  }

  /// @inheritdoc IMigration
  function depositLiquid(
    uint256 _amount,
    address _recipient
  ) external payable virtual override nonReentrant whenNotPaused {
    _checkValue();

    if (block.timestamp < MIGRATION_OPEN) revert MigrationNotOpen();
    if (_amount == 0) revert ZeroAmount();
    if (_recipient == address(0)) revert ZeroAddress();

    _checkBudget(_amount);

    /// @dev Update conversion accounting
    paidBasis += _amount;

    /// @dev Capture the deposited v2 tokens in the migration veNFT
    V2_TOKEN.safeTransferFrom(msg.sender, address(this), _amount);
    V2_TOKEN.forceApprove(address(V2_ESCROW), _amount);
    V2_ESCROW.increaseAmount(MIGRATION_TOKEN_ID, _amount);

    /// @dev Settle the converted tokens
    uint256 _out = _settleLiquid(_recipient, _amount);

    emit LiquidMigrated({_depositor: msg.sender, _recipient: _recipient, _amountIn: _amount, _out: _out});
  }

  // slither-disable-end locked-ether

  /// @inheritdoc IMigration
  function decreaseTailEmissionRate() external override onlyOwner {
    uint256 _previousTailEmissionRate = V2_MINTER.tailEmissionRate();
    V2_MINTER.nudge();
    if (V2_MINTER.tailEmissionRate() >= _previousTailEmissionRate) revert TailEmissionRateNotDecreased();
    emit NudgeExecuted();
  }

  /// @inheritdoc IMigration
  function setRestricted(uint256[] calldata _tokenIds) external override onlyOwner {
    uint256 _length = _tokenIds.length;
    for (uint256 _i; _i < _length; ++_i) {
      restricted[_tokenIds[_i]] = true;
      emit RestrictionsSet(_tokenIds[_i]);
    }
  }

  /// @inheritdoc IMigration
  function setResult(ProposalState _result) external override onlyOwner {
    result = _result;
    emit ResultSet({_result: _result});
  }

  /// @inheritdoc IMigration
  function vote(address[] calldata _pools, uint256[] calldata _weights) external override onlyOwner {
    V2_VOTER.vote({_tokenId: MIGRATION_TOKEN_ID, _poolVote: _pools, _weights: _weights});
  }

  /// @inheritdoc IMigration
  function resetVote() external override onlyOwner {
    V2_VOTER.reset({_tokenId: MIGRATION_TOKEN_ID});
  }

  /// @inheritdoc IMigration
  function claimFees(
    address[] calldata _feeContracts,
    address[][] calldata _tokens,
    address _recipient
  ) external override onlyOwner nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();

    V2_VOTER.claimFees({_fees: _feeContracts, _tokens: _tokens, _tokenId: MIGRATION_TOKEN_ID});
    _transferClaimed({_rewardContracts: _feeContracts, _tokens: _tokens, _recipient: _recipient});
  }

  /// @inheritdoc IMigration
  function claimIncentives(
    address[] calldata _incentiveContracts,
    address[][] calldata _tokens,
    address _recipient
  ) external override onlyOwner nonReentrant {
    if (_recipient == address(0)) revert ZeroAddress();

    V2_VOTER.claimBribes({_bribes: _incentiveContracts, _tokens: _tokens, _tokenId: MIGRATION_TOKEN_ID});
    _transferClaimed({_rewardContracts: _incentiveContracts, _tokens: _tokens, _recipient: _recipient});
  }

  /// @inheritdoc IMigration
  function pause() external override onlyOwner {
    _pause();
  }

  /// @inheritdoc IMigration
  function unpause() external override onlyOwner {
    _unpause();
  }

  /// @inheritdoc IMigration
  function previewConversion(uint256 _tokenId) external view override returns (uint256, uint256, bool, bool) {
    IV2VotingEscrow.LockedBalance memory _locked = V2_ESCROW.locked(_tokenId);
    uint256 _amount = _locked.amount.toUint256();
    (bool _isLiquid,) = _resolveStake(_locked.end, _locked.isPermanent);

    return (_amount, _computeMigrationAmount(_amount), _locked.isPermanent, _isLiquid);
  }

  /// @inheritdoc Ownable
  function renounceOwnership() public virtual override onlyOwner whenPaused {
    _transferOwnership(address(0));
  }

  /**
   * @notice Settles the v3 position for the recipient
   * @param _recipient Address that receives the v3 position
   * @param _out Conversion basis amount to settle
   * @param _end V2 lock expiration timestamp
   * @param _isPermanent Whether the v2 lock is permanent
   * @return Whether settlement produces liquid tokens
   * @return Final v3 token amount settled
   */
  function _settleStake(
    address _recipient,
    uint256 _out,
    uint256 _end,
    bool _isPermanent
  ) internal virtual returns (bool, uint256);

  /**
   * @notice Settles liquid v3 tokens for the recipient
   * @param _recipient Address that receives the v3 tokens
   * @param _out Conversion basis amount to settle
   * @return Final v3 token amount settled
   */
  function _settleLiquid(address _recipient, uint256 _out) internal virtual returns (uint256);

  /**
   * @notice Transfers locally claimed reward-token balances to a recipient.
   * @param _rewardContracts Reward contracts corresponding to each token group.
   * @param _tokens Reward tokens grouped by reward contract.
   * @param _recipient Address receiving the rewards.
   */
  function _transferClaimed(
    address[] calldata _rewardContracts,
    address[][] calldata _tokens,
    address _recipient
  ) internal virtual;

  /**
   * @notice Hook for chain-specific native token handling
   * @dev Aerodrome rejects native tokens while Velodrome accepts them
   */
  function _checkValue() internal view virtual;

  /**
   * @notice Checks whether a conversion fits within the available migration budget
   * @dev Aerodrome checks its available TOKEN balance while Velodrome holds no TOKEN locally
   * @param _amount Conversion basis amount
   */
  function _checkBudget(uint256 _amount) internal view virtual;

  /**
   * @notice Derives the v3 settlement type and duration from a v2 lock
   * @param _end V2 lock expiration timestamp
   * @param _isPermanent Whether the v2 lock is permanent
   * @return Whether settlement produces liquid tokens
   * @return Duration of the v3 stake in weeks
   */
  function _resolveStake(uint256 _end, bool _isPermanent) internal view returns (bool, uint48) {
    if (_isPermanent) return (false, 0);

    /// @dev Expired v2 locks settle as liquid TOKEN
    if (_end <= block.timestamp) return (true, 0);

    /// @dev Convert the remaining duration to rounded-up weeks, up to the maximum v3 stake duration
    uint48 _durationWeeks = _ceilWeeks(_end - block.timestamp);
    uint48 _maximumDurationWeeks = ((MAXTIME + (block.timestamp % WEEK)) / WEEK).toUint48();
    return (false, _durationWeeks >= _maximumDurationWeeks ? _maximumDurationWeeks : _durationWeeks);
  }

  /**
   * @notice Converts a duration in seconds to weeks, rounding up
   * @param _duration Duration in seconds
   * @return Rounded duration in weeks
   */
  function _ceilWeeks(uint256 _duration) internal pure returns (uint48) {
    return ((_duration + WEEK - 1) / WEEK).toUint48();
  }

  /**
   * @notice Converts a migration basis amount into the final v3 token amount
   * @param _basis Migration basis amount
   * @return Final v3 token amount
   */
  function _computeMigrationAmount(uint256 _basis) internal pure virtual returns (uint256);
}
