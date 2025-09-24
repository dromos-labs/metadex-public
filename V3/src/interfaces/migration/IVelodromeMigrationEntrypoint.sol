// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {IMessageRecipient} from '@hyperlane/contracts/interfaces/IMessageRecipient.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

/**
 * @title Velodrome Migration Entrypoint Interface
 * @notice Interface for settling Velodrome migrations on root
 */
interface IVelodromeMigrationEntrypoint is IMessageRecipient {
  /**
   * @notice Parameters for initializing the Velodrome migration entrypoint
   * @param owner Owner of the migration entrypoint
   * @param token Address of the v3 token
   * @param v3Escrow Address of the v3 voting escrow
   * @param mailbox Address of the Hyperlane mailbox
   * @param opDomain Hyperlane domain identifier of OP
   */
  struct EntrypointParams {
    address owner;
    address token;
    address v3Escrow;
    address mailbox;
    uint32 opDomain;
  }

  /**
   * @notice Velodrome migration settlement message
   * @param nonce Nonce used to prevent replayed settlements
   * @param recipient Address receiving the migrated position
   * @param tokenAmount Amount of v3 tokens to settle
   * @param isLiquid Whether the migration settles as liquid tokens
   * @param isPermanent Whether the migrated stake is permanent
   * @param durationWeeks Duration of the migrated stake in weeks
   */
  struct MigrationMessage {
    uint64 nonce;
    address recipient;
    uint256 tokenAmount;
    bool isLiquid;
    bool isPermanent;
    uint48 durationWeeks;
  }

  /**
   * @notice Emitted when a Velodrome migration is settled
   * @param _nonce Nonce of the settled migration message
   * @param _recipient Address receiving the migrated position
   * @param _tokenAmount Amount of v3 tokens settled
   * @param _isLiquid Whether the migration settled as liquid tokens
   */
  event Migrated(uint64 indexed _nonce, address indexed _recipient, uint256 _tokenAmount, bool _isLiquid);

  /**
   * @notice Emitted when the remaining v3 TOKEN balance is burned
   * @param _amount Amount of v3 TOKEN burned
   */
  event RemainingBurned(uint256 _amount);

  /**
   * @notice Thrown when the caller is not the Hyperlane mailbox
   */
  error CallerNotMailbox();

  /**
   * @notice Thrown when the OP domain is zero or matches the mailbox local domain
   */
  error InvalidDomain();

  /**
   * @notice Thrown when an invalid ERC-721 transfer is received
   */
  error InvalidERC721Transfer();

  /**
   * @notice Thrown when a migration message has an invalid length
   */
  error InvalidMessageLength();

  /**
   * @notice Thrown when a migration message nonce has already been used
   */
  error NonceAlreadyUsed();

  /**
   * @notice Thrown when the message origin is not the OP domain
   */
  error UnauthorizedOrigin();

  /**
   * @notice Thrown when the message sender is not the OP migration contract
   */
  error UnauthorizedSender();

  /**
   * @notice Thrown when an address is the zero address
   */
  error ZeroAddress();

  /**
   * @notice Thrown when a migration settlement exceeds the available v3 TOKEN balance
   */
  error BudgetExhausted();

  /**
   * @notice Thrown when ownership is renounced while the entrypoint holds v3 TOKEN
   */
  error RemainingBalance();

  /**
   * @notice Settles an authenticated Velodrome migration message
   * @dev Message delivery across an epoch end may extend a non-permanent stake by one week
   * @param _origin Hyperlane domain from which the message originated
   * @param _sender Address that dispatched the message
   * @param _body Encoded migration settlement message
   */
  function handle(uint32 _origin, bytes32 _sender, bytes calldata _body) external payable override;

  /**
   * @notice Burns the remaining v3 TOKEN balance held by the entrypoint
   */
  function burnRemaining() external;

  /**
   * @notice Returns the remaining v3 TOKEN balance held by the entrypoint
   * @return _remaining The remaining v3 TOKEN balance
   */
  function remaining() external view returns (uint256 _remaining);

  /**
   * @notice Returns the v3 token used to settle liquid migrations and fund stakes
   * @return The v3 token
   */
  function V3_TOKEN() external view returns (IERC20);

  /**
   * @notice Returns the v3 voting escrow used to create migrated stakes
   * @return The v3 voting escrow
   */
  function V3_ESCROW() external view returns (IVotingEscrow);

  /**
   * @notice Returns the Hyperlane mailbox authorized to deliver migration messages
   * @return The Hyperlane mailbox
   */
  function MAILBOX() external view returns (IMailbox);

  /**
   * @notice Returns the Hyperlane domain identifier authorized for OP messages
   * @return The OP domain identifier
   */
  function OP_DOMAIN() external view returns (uint32);

  /**
   * @notice Returns the v3 TOKEN amount settled
   * @return The settled amount
   */
  function paid() external view returns (uint256);

  /**
   * @notice Returns whether a migration message nonce has been used
   * @param _nonce Nonce to query
   * @return Whether the nonce has been used
   */
  function noncesUsed(uint64 _nonce) external view returns (bool);
}
