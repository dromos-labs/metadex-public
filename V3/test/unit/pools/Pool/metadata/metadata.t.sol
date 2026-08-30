// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

contract UnitPoolMetadata is UnitPool {
  function test_ShouldReturnThePoolDecimalsReservesAndTokens(
    uint256 _expectedDecimals0,
    uint256 _expectedDecimals1,
    uint256 _reserve0,
    uint256 _reserve1,
    address _expectedToken0,
    address _expectedToken1
  ) external {
    vm.store(address(_pool), bytes32(_observationBufferInformationSlot + 1), bytes32(_expectedDecimals0));
    vm.store(address(_pool), bytes32(_observationBufferInformationSlot + 2), bytes32(_expectedDecimals1));
    _setReserves(_reserve0, _reserve1);
    _set(address(_pool), uint256(uint160(_expectedToken0)), _pool.token0.selector);
    _set(address(_pool), uint256(uint160(_expectedToken1)), _pool.token1.selector);

    (uint256 _dec0, uint256 _dec1, uint256 _returnedReserve0, uint256 _returnedReserve1, address _t0, address _t1) =
      _pool.metadata();

    // it should return the pool decimals reserves and tokens
    assertEq(_dec0, _expectedDecimals0);
    assertEq(_dec1, _expectedDecimals1);
    assertEq(_returnedReserve0, _reserve0);
    assertEq(_returnedReserve1, _reserve1);
    assertEq(_t0, _expectedToken0);
    assertEq(_t1, _expectedToken1);
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }
}
