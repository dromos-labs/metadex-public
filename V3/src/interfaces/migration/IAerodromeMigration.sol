// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMigration} from 'V3/interfaces/migration/IMigration.sol';

/**
 * @title Aerodrome Migration Interface
 * @notice Interface for migrating Aerodrome v2 positions to v3 on Base
 */
interface IAerodromeMigration is IMigration {
  /**
   * @notice Emitted when the remaining v3 TOKEN balance is burned
   * @param _amount Amount of v3 TOKEN burned
   */
  event RemainingBurned(uint256 _amount);

  /**
   * @notice Thrown when native tokens are sent
   */
  error UnexpectedValue();

  /**
   * @notice Thrown when a conversion exceeds the available migration budget
   */
  error BudgetExhausted();

  /**
   * @notice Thrown when an invalid ERC-721 transfer is received
   */
  error InvalidERC721Transfer();

  /**
   * @notice Thrown when ownership is renounced while the migration holds v3 TOKEN
   */
  error RemainingBalance();

  /**
   * @notice Thrown when a reward claim includes the v3 TOKEN
   * @param _token Address of the invalid reward token
   */
  error InvalidRewardToken(address _token);

  /**
   * @notice Burns the remaining v3 TOKEN balance held by the paused migration contract
   */
  function burnRemaining() external;

  /**
   * @notice Kills v2 Aerodrome gauges.
   * @param _gauges v2 Aerodrome gauges to kill.
   */
  function killGauges(address[] calldata _gauges) external;

  /**
   * @notice Revives v2 Aerodrome gauges.
   * @param _gauges v2 Aerodrome gauges to revive.
   */
  function reviveGauges(address[] calldata _gauges) external;

  /**
   * @notice Returns the remaining v3 TOKEN balance held by the migration contract
   * @return _remaining The remaining v3 TOKEN balance
   */
  function remaining() external view returns (uint256 _remaining);

  /**
   * @notice Returns the address of the v3 token contract
   * @return The v3 token address
   */
  function V3_TOKEN() external view returns (IERC20);

  /**
   * @notice Returns the address of the v3 VotingEscrow contract
   * @return The v3 VotingEscrow address
   */
  function V3_ESCROW() external view returns (IVotingEscrow);
}
