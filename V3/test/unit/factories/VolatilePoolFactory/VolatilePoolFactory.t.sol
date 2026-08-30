// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {VolatilePoolFactory} from 'V3/factories/VolatilePoolFactory.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {UnitPoolFactory} from 'V3-test/unit/factories/PoolFactory.t.sol';

contract UnitVolatilePoolFactory is UnitPoolFactory {
  function setUp() public override {
    super.setUp();
    _poolImplementation = address(new VolatilePool());
    _poolFactory = _deployFactory();
  }

  function _deployFactory() internal override returns (IPoolFactory) {
    return IPoolFactory(
      address(
        new VolatilePoolFactory({
          _implementation: _poolImplementation,
          _poolAdmin: _poolAdmin,
          _pauser: _pauser,
          _feeManager: _feeManager,
          _discountRegistryManager: _discountRegistryManager,
          _poolTapeManager: _poolTapeManager,
          _factoryRegistry: _factoryRegistry
        })
      )
    );
  }
}
