// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StandardHookMetadata} from '@hyperlane/contracts/hooks/libs/StandardHookMetadata.sol';
import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {ExcessivelySafeCall} from '@nomad-xyz/src/ExcessivelySafeCall.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2EmergencyCouncil} from 'V3/interfaces/migration/v2/IV2EmergencyCouncil.sol';
import {IV2RootVotingReward} from 'V3/interfaces/migration/v2/IV2RootVotingReward.sol';
import {IV2RootVotingRewardsFactory} from 'V3/interfaces/migration/v2/IV2RootVotingRewardsFactory.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {Migration} from 'V3/migration/Migration.sol';

/**
 * @title Velodrome Migration
 * @notice Migrates Velodrome v2 positions to v3 on root
 */
contract VelodromeMigration is Migration, IVelodromeMigration {
  using ExcessivelySafeCall for address;
  using SafeCastLibrary for int128;
  using SafeERC20 for IERC20;

  /// @inheritdoc IVelodromeMigration
  uint256 public constant DISPATCH_GAS_LIMIT = 900_000;

  /// @dev VELO-to-TOKEN conversion ratio in pips
  uint256 internal constant _RATIO_PIPS = 55_000;

  /// @dev Gas limit for querying a reward contract chain identifier
  uint256 internal constant _CHAIN_ID_CALL_GAS_LIMIT = 50_000;

  /// @dev OP Mainnet chain identifier
  uint256 internal constant _OP_CHAIN_ID = 10;

  /// @inheritdoc IVelodromeMigration
  IMailbox public immutable MAILBOX;
  /// @inheritdoc IVelodromeMigration
  uint32 public immutable ROOT_DOMAIN;
  /// @inheritdoc IVelodromeMigration
  IV2EmergencyCouncil public immutable V2_EMERGENCY_COUNCIL;
  /// @inheritdoc IVelodromeMigration
  IV2RootVotingRewardsFactory public immutable V2_ROOT_VOTING_REWARDS_FACTORY;

  /// @inheritdoc IVelodromeMigration
  uint64 public dispatchNonce;

  /**
   * @notice Initializes the Velodrome migration state
   * @param _params Shared migration parameters
   * @param _mailbox Address of the Hyperlane mailbox
   * @param _rootDomain Hyperlane domain identifier of the root chain
   * @param _v2RootVotingRewardsFactory Address of the v2 root voting rewards factory
   */
  constructor(
    BaseParams memory _params,
    address _mailbox,
    uint32 _rootDomain,
    address _v2RootVotingRewardsFactory
  ) Migration(_params) {
    if (_mailbox == address(0)) revert ZeroAddress();
    if (_rootDomain == 0 || _rootDomain == IMailbox(_mailbox).localDomain()) revert InvalidDomain();
    if (_v2RootVotingRewardsFactory == address(0)) revert ZeroAddress();

    address _emergencyCouncil = V2_VOTER.emergencyCouncil();
    if (_emergencyCouncil == address(0)) revert ZeroAddress();

    MAILBOX = IMailbox(_mailbox);
    ROOT_DOMAIN = _rootDomain;
    V2_EMERGENCY_COUNCIL = IV2EmergencyCouncil(_emergencyCouncil);
    V2_ROOT_VOTING_REWARDS_FACTORY = IV2RootVotingRewardsFactory(_v2RootVotingRewardsFactory);
  }

  /// @inheritdoc IVelodromeMigration
  function killRootGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_EMERGENCY_COUNCIL.killRootGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IVelodromeMigration
  function killLeafGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_EMERGENCY_COUNCIL.killLeafGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IVelodromeMigration
  function reviveRootGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_EMERGENCY_COUNCIL.reviveRootGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IVelodromeMigration
  function reviveLeafGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_EMERGENCY_COUNCIL.reviveLeafGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IVelodromeMigration
  function setRecipient(uint256 _chainId, address _recipient) external override onlyOwner {
    V2_ROOT_VOTING_REWARDS_FACTORY.setRecipient({_chainId: _chainId, _recipient: _recipient});
  }

  /// @inheritdoc IVelodromeMigration
  function quoteDepositVeNFT(uint256 _tokenId, address _recipient) external view override returns (uint256) {
    IV2VotingEscrow.LockedBalance memory _locked = V2_ESCROW.locked(_tokenId);
    (bool _isLiquid, uint48 _durationWeeks) = _resolveStake(_locked.end, _locked.isPermanent);

    return
      _quoteDispatch(_recipient, _toToken(_locked.amount.toUint256()), _isLiquid, _locked.isPermanent, _durationWeeks);
  }

  /// @inheritdoc IVelodromeMigration
  function quoteDepositLiquid(uint256 _amount, address _recipient) external view override returns (uint256) {
    return _quoteDispatch(_recipient, _toToken(_amount), true, false, 0);
  }

  /// @inheritdoc Migration
  function _settleStake(
    address _recipient,
    uint256 _out,
    uint256 _end,
    bool _isPermanent
  ) internal override returns (bool, uint256) {
    (bool _isLiquid, uint48 _durationWeeks) = _resolveStake(_end, _isPermanent);
    _out = _toToken(_out);
    _dispatch(_recipient, _out, _isLiquid, _isPermanent, _durationWeeks);
    return (_isLiquid, _out);
  }

  /// @inheritdoc Migration
  function _settleLiquid(address _recipient, uint256 _out) internal override returns (uint256) {
    _out = _toToken(_out);
    _dispatch(_recipient, _out, true, false, 0);
    return _out;
  }

  /**
   * @notice Dispatches a migration settlement message to root
   * @dev Message delivery across an epoch end may extend a non-permanent stake by one week
   * @param _recipient Address that receives the v3 position
   * @param _tokenAmount TOKEN amount to settle
   * @param _isLiquid Whether settlement produces liquid tokens
   * @param _isPermanent Whether the v3 stake is permanent
   * @param _durationWeeks Duration of the v3 stake in weeks
   */
  function _dispatch(
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal {
    uint64 _nonce = ++dispatchNonce;
    bytes memory _body = _encodeMessage(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);

    // slither-disable-next-line unused-return
    MAILBOX.dispatch{value: msg.value}(
      ROOT_DOMAIN,
      TypeCasts.addressToBytes32(address(this)),
      _body,
      StandardHookMetadata.format(0, DISPATCH_GAS_LIMIT, msg.sender)
    );

    emit MessageDispatched({_nonce: _nonce, _recipient: _recipient});
  }

  /// @inheritdoc Migration
  function _transferClaimed(
    address[] calldata _rewardContracts,
    address[][] calldata _tokens,
    address _recipient
  ) internal override {
    uint256 _length = _rewardContracts.length;
    for (uint256 _i; _i < _length; ++_i) {
      (bool _success, bytes memory _returnData) = _rewardContracts[_i].excessivelySafeStaticCall(
        _CHAIN_ID_CALL_GAS_LIMIT, 32, abi.encodeCall(IV2RootVotingReward.chainid, ())
      );
      if (_success && abi.decode(_returnData, (uint256)) != _OP_CHAIN_ID) continue;

      uint256 _innerLength = _tokens[_i].length;
      for (uint256 _j; _j < _innerLength; ++_j) {
        IERC20 _token = IERC20(_tokens[_i][_j]);
        uint256 _balance = _token.balanceOf(address(this));
        if (_balance > 0) _token.safeTransfer(_recipient, _balance);
      }
    }
  }

  /**
   * @notice Quotes the native token fee required to dispatch a migration settlement message
   * @param _recipient Address that receives the v3 position
   * @param _tokenAmount TOKEN amount to settle
   * @param _isLiquid Whether settlement produces liquid tokens
   * @param _isPermanent Whether the v3 stake is permanent
   * @param _durationWeeks Duration of the v3 stake in weeks
   * @return Native token fee required for dispatch
   */
  function _quoteDispatch(
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal view returns (uint256) {
    bytes memory _body = _encodeMessage(
      dispatchNonce + 1, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks
    );

    return MAILBOX.quoteDispatch(
      ROOT_DOMAIN,
      TypeCasts.addressToBytes32(address(this)),
      _body,
      StandardHookMetadata.format(0, DISPATCH_GAS_LIMIT, msg.sender)
    );
  }

  /**
   * @notice Encodes a migration settlement message
   * @param _nonce Nonce of the dispatched message
   * @param _recipient Address that receives the v3 position
   * @param _tokenAmount TOKEN amount to settle
   * @param _isLiquid Whether settlement produces liquid tokens
   * @param _isPermanent Whether the v3 stake is permanent
   * @param _durationWeeks Duration of the v3 stake in weeks
   * @return Encoded migration settlement message
   */
  function _encodeMessage(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);
  }

  /**
   * @notice Converts VELO-denominated basis output into TOKEN
   * @param _basis VELO-denominated basis output
   * @return Converted TOKEN amount
   */
  function _toToken(uint256 _basis) internal pure returns (uint256) {
    uint256 _tokenAmount = _computeMigrationAmount(_basis);
    if (_tokenAmount == 0) revert ZeroConversion();
    return _tokenAmount;
  }

  /// @inheritdoc Migration
  function _computeMigrationAmount(uint256 _basis) internal pure override returns (uint256) {
    return Math.mulDiv(_basis, _RATIO_PIPS, MAX_PIPS);
  }

  /// @inheritdoc Migration
  function _checkValue() internal pure override {}

  /// @inheritdoc Migration
  function _checkBudget(uint256) internal pure override {}
}
