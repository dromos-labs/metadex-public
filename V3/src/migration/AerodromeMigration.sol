// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';

import {Migration} from 'V3/migration/Migration.sol';

/**
 * @title Aerodrome Migration
 * @notice Migrates Aerodrome v2 positions to v3 on Base
 */
contract AerodromeMigration is Migration, IERC721Receiver, IAerodromeMigration {
  using SafeCastLibrary for uint256;
  using SafeERC20 for IERC20;

  /// @inheritdoc IAerodromeMigration
  IERC20 public immutable V3_TOKEN;
  /// @inheritdoc IAerodromeMigration
  IVotingEscrow public immutable V3_ESCROW;

  /**
   * @notice Initializes the Aerodrome migration dependencies
   * @param _params Shared migration parameters
   * @param _token Address of the v3 token
   * @param _v3Escrow Address of the v3 VotingEscrow
   */
  constructor(BaseParams memory _params, address _token, address _v3Escrow) Migration(_params) {
    if (_token == address(0) || _v3Escrow == address(0)) revert ZeroAddress();

    V3_TOKEN = IERC20(_token);
    V3_ESCROW = IVotingEscrow(_v3Escrow);
  }

  /// @inheritdoc IAerodromeMigration
  function burnRemaining() external override onlyOwner whenPaused {
    uint256 _remaining = V3_TOKEN.balanceOf({account: address(this)});
    ITokenExtensions(address(V3_TOKEN)).burn({_amount: _remaining});
    emit RemainingBurned({_amount: _remaining});
  }

  /// @inheritdoc IAerodromeMigration
  function killGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_VOTER.killGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IAerodromeMigration
  function reviveGauges(address[] calldata _gauges) external override onlyOwner {
    uint256 _length = _gauges.length;
    for (uint256 _i; _i < _length; ++_i) {
      V2_VOTER.reviveGauge({_gauge: _gauges[_i]});
    }
  }

  /// @inheritdoc IERC721Receiver
  function onERC721Received(
    address _operator,
    address,
    uint256,
    bytes calldata
  ) external view override returns (bytes4) {
    /// @dev Only accept migration-initiated sTOKEN transfers from V3_ESCROW
    if (msg.sender != address(V3_ESCROW) || _operator != address(this)) revert InvalidERC721Transfer();
    return IERC721Receiver.onERC721Received.selector;
  }

  /// @inheritdoc IAerodromeMigration
  function remaining() external view override returns (uint256 _remaining) {
    _remaining = V3_TOKEN.balanceOf({account: address(this)});
  }

  /// @inheritdoc Ownable
  function renounceOwnership() public override onlyOwner whenPaused {
    if (V3_TOKEN.balanceOf({account: address(this)}) != 0) revert RemainingBalance();
    _transferOwnership(address(0));
  }

  /// @inheritdoc Migration
  function _settleStake(
    address _recipient,
    uint256 _out,
    uint256 _end,
    bool _isPermanent
  ) internal override returns (bool, uint256) {
    (bool _isLiquid, uint48 _durationWeeks) = _resolveStake(_end, _isPermanent);

    if (_isLiquid) {
      /// @dev Expired v2 locks settle as liquid TOKEN
      _settleLiquid(_recipient, _out);
    } else {
      /// @dev Active v2 locks settle as v3 staked positions
      V3_TOKEN.forceApprove(address(V3_ESCROW), _out);
      uint256 _tokenId = V3_ESCROW.createStake(_out.toUint128(), _durationWeeks, _isPermanent);
      V3_ESCROW.safeTransferFrom(address(this), _recipient, _tokenId);
    }

    return (_isLiquid, _out);
  }

  /// @inheritdoc Migration
  function _settleLiquid(address _recipient, uint256 _out) internal override returns (uint256) {
    V3_TOKEN.safeTransfer(_recipient, _out);
    return _out;
  }

  /// @inheritdoc Migration
  function _transferClaimed(address[] calldata, address[][] calldata _tokens, address _recipient) internal override {
    uint256 _outerLength = _tokens.length;
    for (uint256 _i; _i < _outerLength; ++_i) {
      uint256 _innerLength = _tokens[_i].length;
      for (uint256 _j; _j < _innerLength; ++_j) {
        IERC20 _token = IERC20(_tokens[_i][_j]);
        if (_token == V3_TOKEN) revert InvalidRewardToken({_token: address(_token)});

        uint256 _balance = _token.balanceOf(address(this));
        if (_balance > 0) _token.safeTransfer(_recipient, _balance);
      }
    }
  }

  /// @inheritdoc Migration
  function _checkValue() internal view override {
    if (msg.value != 0) revert UnexpectedValue();
  }

  /// @inheritdoc Migration
  function _checkBudget(uint256 _amount) internal view override {
    if (_amount > V3_TOKEN.balanceOf(address(this))) revert BudgetExhausted();
  }

  /// @inheritdoc Migration
  function _computeMigrationAmount(uint256 _basis) internal pure override returns (uint256) {
    return _basis;
  }
}
