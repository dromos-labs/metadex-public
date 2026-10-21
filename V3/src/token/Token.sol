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

  /// @notice Initializes the root token.
  /// @param _minter The address allowed to mint tokens.
  /// @param _votingEscrow The address allowed to burn tokens.
  /// @param _migration The Aerodrome migration pre-mint recipient and burner.
  /// @param _velodromeMigration The Velodrome migration pre-mint recipient and burner.
  /// @param _migrationAllocation The one-time Aerodrome migration allocation.
  /// @param _velodromeAllocation The one-time Velodrome migration allocation.
  /// @param _name The token name.
  /// @param _symbol The token symbol.
  constructor(
    address _minter,
    address _votingEscrow,
    address _migration,
    address _velodromeMigration,
    uint256 _migrationAllocation,
    uint256 _velodromeAllocation,
    string memory _name,
    string memory _symbol
  ) BaseToken(_name, _symbol) {
    if (_minter == address(0)) revert ZeroAddress();
    if (_votingEscrow == address(0)) revert ZeroAddress();
    if (_migration == address(0)) revert ZeroAddress();
    if (_velodromeMigration == address(0)) revert ZeroAddress();

    MINTER = _minter;
    VOTING_ESCROW = _votingEscrow;
    MIGRATION = _migration;
    VELODROME_MIGRATION = _velodromeMigration;
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
    if (msg.sender != VOTING_ESCROW && !_isMigrationBurner(msg.sender)) revert CallerNotBurner();
    _burn(msg.sender, _amount);
  }

  /// @notice Whether `_account` is a migration contract authorized to burn its remaining allocation.
  /// @param _account Address to check.
  /// @return _authorized True when `_account` is `MIGRATION` or `VELODROME_MIGRATION`.
  function _isMigrationBurner(address _account) internal view returns (bool _authorized) {
    _authorized = _account == MIGRATION || _account == VELODROME_MIGRATION;
  }
}
