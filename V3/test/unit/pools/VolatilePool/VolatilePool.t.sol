// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {VolatilePool} from 'V3/pools/VolatilePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitVolatilePool is UnitPool {
  function _deployPool() internal override returns (IPool) {
    return IPool(address(new VolatilePool()));
  }

  function test_InitializeGivenAFreshlyDeployedVolatilePool() external view {
    // it should derive the name from the volatile prefix and the token symbols
    assertEq(IERC20Metadata(address(_pool)).name(), 'VolatileV2 AMM - TK0/TK1');
    // it should derive the symbol from the volatile prefix and the token symbols
    assertEq(IERC20Metadata(address(_pool)).symbol(), 'vAMMV2-TK0/TK1');
  }

  function test_GetKWhenReservesAreZero() external {
    // it should return zero
    assertEq(_pool.getK(), 0);
  }

  function test_GetKWhenReservesAreNonZero(uint256 _amount0, uint256 _amount1) external {
    _amount0 = bound(_amount0, 1e4, 1e30);
    _amount1 = bound(_amount1, 1e4, 1e30);
    _mockAndExpectTokenBalance(_token0, address(_pool), _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _amount1);
    _pool.mint(address(this));
    // it should return reserve0 times reserve1
    assertEq(_pool.getK(), _amount0 * _amount1);
  }

  function test_POOL_TYPEShouldReturnTheVolatilePoolIdentifier() external view {
    // it should return the volatile pool identifier
    assertEq(_pool.POOL_TYPE(), bytes32('V2_VOLATILE'));
  }
}
