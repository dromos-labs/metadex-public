// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';
import {stdError} from 'forge-std/StdError.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IStablePool} from 'V3/interfaces/pools/IStablePool.sol';
import {StablePool} from 'V3/pools/StablePool.sol';

import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitStablePool is UnitPool {
  /// @dev Largest balance that fits in uint256
  uint256 internal constant _MAX_BALANCED_TOKENS = 490_526_216_596_018;

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new StablePool()));
  }

  function test_InitializeGivenAFreshlyDeployedStablePool() external view {
    // it should derive the name from the stable prefix and the token symbols
    assertEq(IERC20Metadata(address(_pool)).name(), 'StableV2 AMM - TK0/TK1');
    // it should derive the symbol from the stable prefix and the token symbols
    assertEq(IERC20Metadata(address(_pool)).symbol(), 'sAMMV2-TK0/TK1');
  }

  function test_MINIMUM_KShouldExposeTheHardCodedStableInvariantFloor() external view {
    // it should expose the hard coded stable invariant floor
    assertEq(IStablePool(address(_pool)).MINIMUM_K(), 10 ** 10);
  }

  function test_GetKWhenReservesAreZero() external {
    // it should return zero
    assertEq(_pool.getK(), 0);
  }

  function test_GetKWhenReservesAreWithinTheInvariantCeiling(uint256 _tokens) external {
    _tokens = bound(_tokens, 1, _MAX_BALANCED_TOKENS);
    uint256 _amount0 = _tokens * _decimals0;
    uint256 _amount1 = _tokens * _decimals1;

    _mockAndExpectTokenBalance(_token0, address(_pool), _amount0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _amount1);
    _pool.mint(address(this));

    uint256 _x = (_amount0 * 1e18) / _decimals0;
    uint256 _y = (_amount1 * 1e18) / _decimals1;
    uint256 _a = Math.mulDiv(_x, _y, 1e18);
    uint256 _b = Math.mulDiv(_x, _x, 1e18) + Math.mulDiv(_y, _y, 1e18);
    uint256 _expectedK = Math.mulDiv(_a, _b, 1e18);
    // it should return the cubic stable invariant
    assertEq(_pool.getK(), _expectedK);
  }

  function test_GetKWhenReservesExceedTheInvariantCeiling(uint256 _tokens) external {
    _tokens = bound(_tokens, _MAX_BALANCED_TOKENS + 1, 1e29);

    // the first mint validates k
    _mockAndExpectTokenBalance(_token0, address(_pool), _decimals0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _decimals1);
    _pool.mint(address(this));
    _mockAndExpectTokenBalance(_token0, address(_pool), _tokens * _decimals0);
    _mockAndExpectTokenBalance(_token1, address(_pool), _tokens * _decimals1);
    _pool.sync();

    // it should revert with an arithmetic overflow
    vm.expectRevert(stdError.arithmeticError);
    _pool.getK();
  }

  function test_POOL_TYPEShouldReturnTheStablePoolIdentifier() external view {
    // it should return the stable pool identifier
    assertEq(_pool.POOL_TYPE(), bytes32('V2_STABLE'));
  }
}
