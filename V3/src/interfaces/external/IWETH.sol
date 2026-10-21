// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

interface IWETH is IERC20 {
  /// @notice Deposits native tokens and mints wrapped native tokens to the caller
  function deposit() external payable;

  /// @notice Burns wrapped native tokens and returns native tokens to the caller
  /// @param _wad The amount of wrapped native tokens to unwrap
  function withdraw(uint256 _wad) external;
}
