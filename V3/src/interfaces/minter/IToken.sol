/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IToken
 * @notice Narrow token interface used by `Minter` to request root token mints.
 */
interface IToken {
  /**
   * @notice Mints tokens to an account.
   * @param _to Account receiving the minted tokens.
   * @param _amount Amount of tokens to mint.
   */
  function mint(address _to, uint256 _amount) external;
}
