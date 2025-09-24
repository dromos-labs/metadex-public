// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';

import {PoolFactory} from 'V3/factories/PoolFactory.sol';

/// @title VolatilePoolFactory
/// @notice Deploys Aerodrome V2 volatile pools.
contract VolatilePoolFactory is PoolFactory {
  /// @inheritdoc IPoolFactory
  uint256 public constant DEFAULT_FEE = 30; // 0.3%

  /// @notice Wires the volatile pool implementation and the role holders.
  /// @param _implementation Volatile pool implementation the factory clones.
  /// @param _poolAdmin Initial pool admin.
  /// @param _pauser Initial pauser.
  /// @param _feeManager Initial fee manager.
  /// @param _discountRegistryManager Initial discount registry manager.
  /// @param _poolTapeManager Initial pool tape manager.
  /// @param _factoryRegistry Factory registry every created pool is recorded in as a target.
  constructor(
    address _implementation,
    address _poolAdmin,
    address _pauser,
    address _feeManager,
    address _discountRegistryManager,
    address _poolTapeManager,
    address _factoryRegistry
  )
    PoolFactory(
      _implementation,
      _poolAdmin,
      _pauser,
      _feeManager,
      DEFAULT_FEE,
      _discountRegistryManager,
      _poolTapeManager,
      _factoryRegistry
    )
  {}
}
