// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IBaseTokenExtensions} from 'V3/interfaces/token/IBaseTokenExtensions.sol';

/// @title ITokenExtensions
/// @notice Interface for Token custom behavior not covered by the ERC20 interface.
interface ITokenExtensions is IBaseTokenExtensions {
  /// @notice Thrown when a caller other than the minter tries to mint tokens.
  error NotMinter();

  /// @notice Thrown when a caller without burn permission tries to burn tokens.
  error CallerNotBurner();

  /// @notice Thrown when a non-exempt sender tries to transfer tokens before transfers are enabled.
  error TransfersDisabled();

  /// @notice Thrown when the migration opening timestamp is not a future epoch start.
  error InvalidMigrationOpen();

  /// @notice Mints tokens to an account.
  /// @param _to The account that receives the minted tokens.
  /// @param _amount The amount of tokens to mint.
  function mint(address _to, uint256 _amount) external;

  /// @notice Burns tokens held by an authorized protocol burner.
  /// @param _amount The amount of tokens to burn.
  function burn(uint256 _amount) external;

  /// @notice Returns the minter address.
  /// @return _minter The address allowed to mint tokens.
  function MINTER() external view returns (address _minter);

  /// @notice Returns the voting escrow address.
  /// @return _votingEscrow The address allowed to burn tokens.
  function VOTING_ESCROW() external view returns (address _votingEscrow);

  /// @notice Returns the Aerodrome migration address.
  /// @return _migration The Aerodrome migration pre-mint recipient, exempt sender, and burner.
  function MIGRATION() external view returns (address _migration);

  /// @notice Returns the Velodrome migration entrypoint address.
  /// @return _velodromeMigration The Velodrome pre-mint recipient, exempt sender, and burner.
  function VELODROME_MIGRATION() external view returns (address _velodromeMigration);

  /// @notice Returns the timestamp at which token transfers become globally enabled.
  /// @return _transfersEnabledAt The transfer activation timestamp.
  function TRANSFERS_ENABLED_AT() external view returns (uint256 _transfersEnabledAt);
}
