// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';

/**
 * @title V2PoolLib
 * @notice Authenticates existing V2 pools independently of current factory approval.
 */
library V2PoolLib {
  /// @notice Pool family reported by stable V2 pools.
  bytes32 private constant _V2_STABLE_POOL_TYPE = 'V2_STABLE';
  /// @notice Pool family reported by volatile V2 pools.
  bytes32 private constant _V2_VOLATILE_POOL_TYPE = 'V2_VOLATILE';

  /**
   * @notice Validates a recorded V2 pool and returns its deploying factory.
   * @dev Factory retirement prevents creation, but does not invalidate existing pools. Match swap validation by
   *      checking the permanent creation record, factory membership, and supported pool family.
   * @param _pool Pool target to authenticate.
   * @param _factoryRegistry Registry holding the permanent creation record.
   * @return _factory Recorded deploying factory.
   */
  function validatePool(address _pool, IFactoryRegistry _factoryRegistry) internal view returns (address _factory) {
    _factory = _factoryRegistry.targetToFactory(_pool);
    if (_factory == address(0)) revert IMetarouter.PoolNotRegistered();
    if (!IPoolFactory(_factory).isPool(_pool)) revert IMetarouter.InvalidPool(_pool);
    bytes32 _poolType = IPool(_pool).POOL_TYPE();
    if (_poolType != _V2_VOLATILE_POOL_TYPE && _poolType != _V2_STABLE_POOL_TYPE) {
      revert IMetarouter.InvalidPool(_pool);
    }
  }
}
