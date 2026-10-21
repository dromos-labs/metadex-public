// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {TypeCasts} from '@hyperlane/contracts/libs/TypeCasts.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVelodromeMigrationEntrypoint} from 'V3/interfaces/migration/IVelodromeMigrationEntrypoint.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';

/**
 * @title Velodrome Migration Entrypoint
 * @notice Settles Velodrome migrations on root
 */
contract VelodromeMigrationEntrypoint is Ownable, IERC721Receiver, IVelodromeMigrationEntrypoint {
  using SafeCastLibrary for uint256;
  using SafeERC20 for IERC20;

  /// @dev Length of a packed migration settlement message
  uint256 internal constant _MESSAGE_LENGTH = 68;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  IERC20 public immutable V3_TOKEN;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  IVotingEscrow public immutable V3_ESCROW;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  IMailbox public immutable MAILBOX;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  uint32 public immutable OP_DOMAIN;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  uint256 public paid;

  /// @inheritdoc IVelodromeMigrationEntrypoint
  mapping(uint64 _nonce => bool _used) public noncesUsed;

  /**
   * @notice Initializes the Velodrome migration entrypoint state
   * @param _params Velodrome migration entrypoint parameters
   */
  constructor(EntrypointParams memory _params) Ownable(_params.owner) {
    if (_params.token == address(0) || _params.v3Escrow == address(0) || _params.mailbox == address(0)) {
      revert ZeroAddress();
    }
    if (_params.opDomain == 0 || _params.opDomain == IMailbox(_params.mailbox).localDomain()) revert InvalidDomain();

    V3_TOKEN = IERC20(_params.token);
    V3_ESCROW = IVotingEscrow(_params.v3Escrow);
    MAILBOX = IMailbox(_params.mailbox);
    OP_DOMAIN = _params.opDomain;
  }

  // slither-disable-start locked-ether
  /// @inheritdoc IVelodromeMigrationEntrypoint
  function handle(uint32 _origin, bytes32 _sender, bytes calldata _body) external payable override {
    if (msg.sender != address(MAILBOX)) revert CallerNotMailbox();
    if (_origin != OP_DOMAIN) revert UnauthorizedOrigin();
    if (_sender != TypeCasts.addressToBytes32(address(this))) revert UnauthorizedSender();

    /// @dev Decode the migration payload and validate settlement
    MigrationMessage memory _message = _decode(_body);
    if (noncesUsed[_message.nonce]) revert NonceAlreadyUsed();
    if (_message.tokenAmount > V3_TOKEN.balanceOf({account: address(this)})) revert BudgetExhausted();

    /// @dev Consume the nonce and update settlement accounting
    noncesUsed[_message.nonce] = true;
    paid += _message.tokenAmount;

    /// @dev Settle the migration as liquid tokens or a staked position
    if (_message.isLiquid) {
      V3_TOKEN.safeTransfer(_message.recipient, _message.tokenAmount);
    } else {
      _mintStake(_message.recipient, _message.tokenAmount, _message.isPermanent, _message.durationWeeks);
    }

    emit Migrated({
      _nonce: _message.nonce,
      _recipient: _message.recipient,
      _tokenAmount: _message.tokenAmount,
      _isLiquid: _message.isLiquid
    });
  }

  // slither-disable-end locked-ether

  /// @inheritdoc IVelodromeMigrationEntrypoint
  function burnRemaining() external override onlyOwner {
    uint256 _remaining = V3_TOKEN.balanceOf({account: address(this)});
    ITokenExtensions(address(V3_TOKEN)).burn({_amount: _remaining});
    emit RemainingBurned({_amount: _remaining});
  }

  /// @inheritdoc IVelodromeMigrationEntrypoint
  function remaining() external view override returns (uint256 _remaining) {
    _remaining = V3_TOKEN.balanceOf({account: address(this)});
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

  /// @inheritdoc Ownable
  function renounceOwnership() public override onlyOwner {
    if (V3_TOKEN.balanceOf({account: address(this)}) != 0) revert RemainingBalance();
    _transferOwnership(address(0));
  }

  /**
   * @notice Creates a v3 staked position and forwards it to the recipient
   * @dev Assumes `_durationWeeks` is zero for permanent stakes
   * @param _recipient Address that receives the v3 staked position
   * @param _amount Amount of v3 tokens to stake
   * @param _isPermanent Whether the v3 stake is permanent
   * @param _durationWeeks Duration of the v3 stake in weeks
   */
  function _mintStake(address _recipient, uint256 _amount, bool _isPermanent, uint48 _durationWeeks) internal {
    /// @dev Clamp the stake duration to the maximum accepted after delivery
    if (!_isPermanent) {
      uint48 _maximumDurationWeeks = ((MAXTIME + (block.timestamp % WEEK)) / WEEK).toUint48();
      if (_durationWeeks > _maximumDurationWeeks) _durationWeeks = _maximumDurationWeeks;
    }

    V3_TOKEN.forceApprove(address(V3_ESCROW), _amount);
    uint256 _tokenId = V3_ESCROW.createStake(_amount.toUint128(), _durationWeeks, _isPermanent);
    V3_ESCROW.transferFrom(address(this), _recipient, _tokenId);
  }

  /**
   * @notice Decodes a packed Velodrome migration message
   * @param _body Encoded migration settlement message
   * @return Decoded migration settlement message
   */
  function _decode(bytes calldata _body) internal pure returns (MigrationMessage memory) {
    if (_body.length != _MESSAGE_LENGTH) revert InvalidMessageLength();

    return MigrationMessage({
      nonce: uint64(bytes8(_body[0:8])),
      recipient: address(bytes20(_body[8:28])),
      tokenAmount: uint256(bytes32(_body[28:60])),
      isLiquid: uint8(_body[60]) != 0,
      isPermanent: uint8(_body[61]) != 0,
      durationWeeks: uint48(bytes6(_body[62:68]))
    });
  }
}
