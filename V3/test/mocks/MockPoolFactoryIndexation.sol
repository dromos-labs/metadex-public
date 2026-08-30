// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity 0.8.36;

import {PoolFactoryIndexation} from 'V3/pools/PoolFactoryIndexation.sol';

contract MockPoolFactoryIndexation is PoolFactoryIndexation {
  /// @dev Invokes an internal pool-creation hook that atomically updates indexes.
  function createPoolHook(address _tokenA, address _tokenB, address _pool) external {
    _createPoolHook(_tokenA, _tokenB, _pool);
  }
}
