// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitPoolPendingFees is UnitPool {
  using stdStorage for StdStorage;

  function test_WhenAccountHasNoLiquidity(address _account, uint256 _claimable0, uint256 _claimable1) external {
    _assumeFuzzable(_account);
    _setClaimable(_account, _claimable0, _claimable1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should return stored claimable amounts
    assertEq(_amount0, _claimable0);
    assertEq(_amount1, _claimable1);
  }

  function test_WhenAccountHasNoLiquidityAndStaleIndexes(
    address _account,
    uint256 _claimable0,
    uint256 _claimable1,
    uint256 _supplyIndex0,
    uint256 _supplyIndex1,
    uint256 _delta0,
    uint256 _delta1
  ) external {
    _assumeFuzzable(_account);
    _supplyIndex0 = bound(_supplyIndex0, 0, type(uint128).max);
    _supplyIndex1 = bound(_supplyIndex1, 0, type(uint128).max);
    _delta0 = bound(_delta0, 1, type(uint128).max);
    _delta1 = bound(_delta1, 1, type(uint128).max);
    _setClaimable(_account, _claimable0, _claimable1);
    _setSupplyIndexes(_account, _supplyIndex0, _supplyIndex1);
    _setIndexes(_supplyIndex0 + _delta0, _supplyIndex1 + _delta1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should ignore index deltas
    assertEq(_amount0, _claimable0);
    assertEq(_amount1, _claimable1);
  }

  function test_WhenAccountHasLiquidityAndNoNewFeeIndex(
    address _account,
    uint256 _liquidity,
    uint256 _claimable0,
    uint256 _claimable1,
    uint256 _feeIndex0,
    uint256 _feeIndex1
  ) external {
    _assumeFuzzable(_account);
    _liquidity = bound(_liquidity, 1, type(uint128).max);
    _feeIndex0 = bound(_feeIndex0, 0, type(uint128).max);
    _feeIndex1 = bound(_feeIndex1, 0, type(uint128).max);
    _setBalance(_account, _liquidity);
    _setClaimable(_account, _claimable0, _claimable1);
    _setSupplyIndexes(_account, _feeIndex0, _feeIndex1);
    _setIndexes(_feeIndex0, _feeIndex1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should return stored claimable amounts
    assertEq(_amount0, _claimable0);
    assertEq(_amount1, _claimable1);
  }

  function test_WhenAccountHasLiquidityAndOnlyToken0Accrued(
    address _account,
    uint256 _liquidity,
    uint256 _supplyIndex0,
    uint256 _supplyIndex1,
    uint256 _delta0
  ) external {
    _assumeFuzzable(_account);
    _liquidity = bound(_liquidity, 1, type(uint128).max);
    _supplyIndex0 = bound(_supplyIndex0, 0, type(uint128).max);
    _supplyIndex1 = bound(_supplyIndex1, 0, type(uint128).max);
    _delta0 = bound(_delta0, 1, type(uint128).max);
    _setBalance(_account, _liquidity);
    _setSupplyIndexes(_account, _supplyIndex0, _supplyIndex1);
    _setIndexes(_supplyIndex0 + _delta0, _supplyIndex1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should include the token0 index delta
    assertEq(_amount0, (_liquidity * _delta0) / 1e18);
    assertEq(_amount1, 0);
  }

  function test_WhenAccountHasLiquidityAndOnlyToken1Accrued(
    address _account,
    uint256 _liquidity,
    uint256 _supplyIndex0,
    uint256 _supplyIndex1,
    uint256 _delta1
  ) external {
    _assumeFuzzable(_account);
    _liquidity = bound(_liquidity, 1, type(uint128).max);
    _supplyIndex0 = bound(_supplyIndex0, 0, type(uint128).max);
    _supplyIndex1 = bound(_supplyIndex1, 0, type(uint128).max);
    _delta1 = bound(_delta1, 1, type(uint128).max);
    _setBalance(_account, _liquidity);
    _setSupplyIndexes(_account, _supplyIndex0, _supplyIndex1);
    _setIndexes(_supplyIndex0, _supplyIndex1 + _delta1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should include the token1 index delta
    assertEq(_amount0, 0);
    assertEq(_amount1, (_liquidity * _delta1) / 1e18);
  }

  function test_WhenAccountHasLiquidityAndBothTokensAccrued(
    address _account,
    uint256 _liquidity,
    uint256 _claimable0,
    uint256 _claimable1,
    uint256 _supplyIndex0,
    uint256 _supplyIndex1,
    uint256 _delta0,
    uint256 _delta1
  ) external {
    _assumeFuzzable(_account);
    _liquidity = bound(_liquidity, 1, type(uint128).max);
    _claimable0 = bound(_claimable0, 0, type(uint128).max);
    _claimable1 = bound(_claimable1, 0, type(uint128).max);
    _supplyIndex0 = bound(_supplyIndex0, 0, type(uint128).max);
    _supplyIndex1 = bound(_supplyIndex1, 0, type(uint128).max);
    _delta0 = bound(_delta0, 1, type(uint128).max);
    _delta1 = bound(_delta1, 1, type(uint128).max);
    _setBalance(_account, _liquidity);
    _setClaimable(_account, _claimable0, _claimable1);
    _setSupplyIndexes(_account, _supplyIndex0, _supplyIndex1);
    _setIndexes(_supplyIndex0 + _delta0, _supplyIndex1 + _delta1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should include stored claimable amounts and both index deltas
    assertEq(_amount0, _claimable0 + (_liquidity * _delta0) / 1e18);
    assertEq(_amount1, _claimable1 + (_liquidity * _delta1) / 1e18);
  }

  function test_WhenAccrualRoundsDown() external {
    address _account = makeAddr('account');
    uint256 _liquidity = 3;
    uint256 _delta0 = 1e18 - 1;
    uint256 _delta1 = 2e18 - 1;
    _setBalance(_account, _liquidity);
    _setSupplyIndexes(_account, 10e18, 20e18);
    _setIndexes(10e18 + _delta0, 20e18 + _delta1);

    (uint256 _amount0, uint256 _amount1) = _pool.pendingFees(_account);

    // it should return the rounded down pending fees
    assertEq(_amount0, 2);
    assertEq(_amount1, 5);
  }

  function testGas_pendingFees() external {
    address _account = makeAddr('account');
    _setBalance(_account, 1_000_000e18);
    _setClaimable(_account, 10e18, 20e18);
    _setSupplyIndexes(_account, 1e18, 2e18);
    _setIndexes(3e18, 5e18);

    _pool.pendingFees(_account);

    vm.snapshotGasLastCall('Pool_pendingFees');
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }

  function _setBalance(address _account, uint256 _balance) internal {
    stdstore.target(address(_pool)).sig(IERC20.balanceOf.selector).with_key(_account).checked_write(_balance);
  }

  function _setClaimable(address _account, uint256 _claimable0, uint256 _claimable1) internal {
    stdstore.target(address(_pool)).sig(IPool.claimable0.selector).with_key(_account).checked_write(_claimable0);
    stdstore.target(address(_pool)).sig(IPool.claimable1.selector).with_key(_account).checked_write(_claimable1);
  }

  function _setSupplyIndexes(address _account, uint256 _supplyIndex0, uint256 _supplyIndex1) internal {
    stdstore.target(address(_pool)).sig(IPool.supplyIndex0.selector).with_key(_account).checked_write(_supplyIndex0);
    stdstore.target(address(_pool)).sig(IPool.supplyIndex1.selector).with_key(_account).checked_write(_supplyIndex1);
  }

  function _setIndexes(uint256 _index0, uint256 _index1) internal {
    _set(address(_pool), _index0, IPool.index0.selector);
    _set(address(_pool), _index1, IPool.index1.selector);
  }
}
