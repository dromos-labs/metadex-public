// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IPool} from 'V3/interfaces/pools/IPool.sol';

/**
 * @title IStablePool
 * @notice Interface for the StablePool contract, an Aerodrome V2 stable-swap AMM pool
 */
interface IStablePool is IPool {
  /*////////////////////////////////////////////////////////////
                            ERRORS
  ////////////////////////////////////////////////////////////*/
  /// @notice Thrown on first mint when `_k(amount0, amount1)` is less than or equal to `MINIMUM_K`
  error BelowMinimumK();

  /// @notice Thrown when the Newton-Raphson search cannot solve for `y` within its iteration budget
  error CannotCalculateY();

  /// @notice Thrown when the deposited amounts are not equal
  error DepositsNotEqual();

  /// @notice Thrown after burn when remaining reserves cause `_k` to round to zero
  error KIsZero();

  /*////////////////////////////////////////////////////////////
                      PURE AND VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/
  /// @notice Minimum value of the stable-swap invariant
  function MINIMUM_K() external view returns (uint256);
}
