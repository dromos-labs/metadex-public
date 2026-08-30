// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StablePoolFactory} from 'V3/factories/StablePoolFactory.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {StablePool} from 'V3/pools/StablePool.sol';

import {UnitPoolFactory} from 'V3-test/unit/factories/PoolFactory.t.sol';

contract UnitStablePoolFactory is UnitPoolFactory {
  function setUp() public override {
    super.setUp();
    _poolImplementation = address(new StablePool());
    _poolFactory = _deployFactory();
  }

  function _deployFactory() internal override returns (IPoolFactory) {
    return IPoolFactory(
      address(
        new StablePoolFactory({
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
