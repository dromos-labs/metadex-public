// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';
import {BaseToken} from 'V3/token/BaseToken.sol';

/// @title Token
/// @notice Canonical root chain token.
contract Token is BaseToken, ITokenExtensions {
  /// @inheritdoc ITokenExtensions
  address public immutable MINTER;

  /// @inheritdoc ITokenExtensions
  address public immutable VOTING_ESCROW;

  /// @inheritdoc ITokenExtensions
  address public immutable MIGRATION;

  /// @inheritdoc ITokenExtensions
  address public immutable VELODROME_MIGRATION;

  /// @inheritdoc ITokenExtensions
  uint256 public immutable TRANSFERS_ENABLED_AT;

  /// @notice Initializes the root token.
  /// @param _minter The address allowed to mint tokens.
  /// @param _votingEscrow The address allowed to burn tokens.
  /// @param _migration The Aerodrome migration pre-mint recipient, exempt sender, and burner.
  /// @param _velodromeMigration The Velodrome migration pre-mint recipient, exempt sender, and burner.
  /// @param _migrationOpen The timestamp when migration opens.
  /// @param _migrationAllocation The one-time Aerodrome migration allocation.
  /// @param _velodromeAllocation The one-time Velodrome migration allocation.
  /// @param _name The token name.
  /// @param _symbol The token symbol.
  constructor(
    address _minter,
    address _votingEscrow,
    address _migration,
    address _velodromeMigration,
    uint48 _migrationOpen,
    uint256 _migrationAllocation,
    uint256 _velodromeAllocation,
    string memory _name,
    string memory _symbol
  ) BaseToken(_name, _symbol) {
    if (_minter == address(0)) revert ZeroAddress();
    if (_votingEscrow == address(0)) revert ZeroAddress();
    if (_migration == address(0)) revert ZeroAddress();
    if (_velodromeMigration == address(0)) revert ZeroAddress();
    if (_migrationOpen % 1 weeks != 0 || _migrationOpen <= block.timestamp) revert InvalidMigrationOpen();

    MINTER = _minter;
    VOTING_ESCROW = _votingEscrow;
    MIGRATION = _migration;
    VELODROME_MIGRATION = _velodromeMigration;
    TRANSFERS_ENABLED_AT = uint256(_migrationOpen) + 1 weeks;
    _mint(_migration, _migrationAllocation);
    _mint(_velodromeMigration, _velodromeAllocation);
  }

  /// @inheritdoc ITokenExtensions
  function mint(address _to, uint256 _amount) external {
    if (msg.sender != MINTER) revert NotMinter();
    _mint(_to, _amount);
  }

  /// @inheritdoc ITokenExtensions
  function burn(uint256 _amount) external {
    if (msg.sender != VOTING_ESCROW && !_isMigrationExempt(msg.sender)) revert CallerNotBurner();
    _burn(msg.sender, _amount);
  }

  /// @inheritdoc BaseToken
  /// @dev Adds the transfer gate; the zero-address check runs in `BaseToken`.
  function transfer(address _to, uint256 _amount) public override returns (bool _success) {
    if (block.timestamp < TRANSFERS_ENABLED_AT && !_isMigrationExempt(msg.sender)) revert TransfersDisabled();
    _success = super.transfer(_to, _amount);
  }

  /// @inheritdoc BaseToken
  /// @dev Adds the transfer gate; the zero-address check runs in `BaseToken`.
  function transferFrom(address _from, address _to, uint256 _amount) public override returns (bool _success) {
    if (block.timestamp < TRANSFERS_ENABLED_AT && !_isMigrationExempt(_from)) revert TransfersDisabled();
    _success = super.transferFrom(_from, _to, _amount);
  }

  /// @notice Whether `_account` is one of the migration contracts, allowed to burn and to send while the
  ///         transfer gate is closed.
  /// @param _account Address to check.
  /// @return _exempt True when `_account` is `MIGRATION` or `VELODROME_MIGRATION`.
  function _isMigrationExempt(address _account) internal view returns (bool _exempt) {
    _exempt = _account == MIGRATION || _account == VELODROME_MIGRATION;
  }
}
