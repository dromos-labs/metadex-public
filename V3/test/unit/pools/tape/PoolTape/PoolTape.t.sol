// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitBasePoolTape} from 'V3-test/unit/pools/tape/BasePoolTape/BasePoolTape.t.sol';
import {BasePoolTape} from 'V3/pools/tape/BasePoolTape.sol';
import {PoolTape} from 'V3/pools/tape/PoolTape.sol';

contract UnitPoolTape is UnitBasePoolTape {
  function _deployTape(address _initialOwner, uint32 _defaultCadenceInterval) internal override returns (BasePoolTape) {
    return new PoolTape(_initialOwner, _defaultCadenceInterval);
  }
}
