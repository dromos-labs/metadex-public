// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IBaseTokenExtensions} from 'V3/interfaces/token/IBaseTokenExtensions.sol';

/// @title IReceiptTokenExtensions
/// @notice Interface for ReceiptToken custom behavior not covered by the ERC20 interface.
interface IReceiptTokenExtensions is IBaseTokenExtensions {
  /// @notice Thrown when a caller other than the leaf voter tries to mint or burn tokens.
  error NotLeafVoter();

  /// @notice Mints receipt tokens to an account.
  /// @param _to The account that receives the minted tokens.
  /// @param _amount The amount of tokens to mint.
  function mint(address _to, uint256 _amount) external;

  /// @notice Burns receipt tokens from an account.
  /// @param _from The account whose tokens are burned.
  /// @param _amount The amount of tokens to burn.
  function burn(address _from, uint256 _amount) external;

  /// @notice Returns the leaf voter address.
  /// @return _leafVoter The address allowed to mint and burn receipt tokens.
  function LEAF_VOTER() external view returns (address _leafVoter);
}
