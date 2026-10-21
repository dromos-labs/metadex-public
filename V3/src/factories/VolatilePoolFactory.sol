// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';

import {PoolFactory} from 'V3/factories/PoolFactory.sol';

/// @title VolatilePoolFactory
/// @notice Deploys Aerodrome V2 volatile pools.
contract VolatilePoolFactory is PoolFactory {
  /// @inheritdoc IPoolFactory
  uint256 public constant DEFAULT_FEE = 30; // 0.3%

  /// @notice Initializes the volatile pool factory with its governance roles and modules.
  /// @param _implementation Volatile pool implementation the factory clones.
  /// @param _config Initial governance roles and modules.
  constructor(
    address _implementation,
    IPoolFactory.PoolFactoryConfig memory _config
  ) PoolFactory(_implementation, DEFAULT_FEE, _config) {}
}
