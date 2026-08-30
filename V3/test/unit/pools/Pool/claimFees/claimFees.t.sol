// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitPoolClaimFees is UnitPool {
  using stdStorage for StdStorage;

  function test_WhenRecipientIsTheZeroAddress(address _caller) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IPool.ZeroAddress.selector);
    _pool.claimFees(address(0));
  }

  function test_WhenCallerHasNoClaimableFees(
    address _caller,
    address _recipient,
    uint256 _index0,
    uint256 _index1
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _index0 = bound(_index0, 0, type(uint128).max);
    _index1 = bound(_index1, 0, type(uint128).max);
    _setIndexes(_index0, _index1);

    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_caller);
    // it should have no pending fees before claim
    assertEq(_pending0, 0);
    assertEq(_pending1, 0);

    vm.recordLogs();
    vm.prank(_caller);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
    // it should return the previously pending amounts
    assertEq(_claimed0, _pending0);
    assertEq(_claimed1, _pending1);
    // it should sync the caller fee indexes
    assertEq(_pool.supplyIndex0(_caller), _index0);
    assertEq(_pool.supplyIndex1(_caller), _index1);
    // it should not emit a Claim event
    assertEq(vm.getRecordedLogs().length, 0);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasStoredToken0Fees(address _caller, address _recipient, uint256 _claimable0) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _claimable0 = bound(_claimable0, 1, type(uint128).max);
    _setClaimable(_caller, _claimable0, 0);

    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_caller);
    // it should have pending token0 fees before claim
    assertEq(_pending0, _claimable0);
    assertEq(_pending1, 0);
    _mockAndExpectTokenTransfer(_token0, _recipient, _pending0);

    vm.prank(_caller);
    // it should emit a Claim event
    _expectEmit(address(_pool));
    emit IPool.Claim(_caller, _caller, _recipient, _pending0, _pending1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should transfer token0 fees to the recipient
    // it should clear caller token0 claimable
    assertEq(_pool.claimable0(_caller), 0);
    // it should return the claimed token0 amount
    assertEq(_claimed0, _claimable0);
    assertEq(_claimed1, 0);
    // it should return the previously pending amounts
    assertEq(_claimed0, _pending0);
    assertEq(_claimed1, _pending1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasStoredToken1Fees(address _caller, address _recipient, uint256 _claimable1) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _claimable1 = bound(_claimable1, 1, type(uint128).max);
    _setClaimable(_caller, 0, _claimable1);

    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_caller);
    // it should have pending token1 fees before claim
    assertEq(_pending0, 0);
    assertEq(_pending1, _claimable1);
    _mockAndExpectTokenTransfer(_token1, _recipient, _pending1);

    vm.prank(_caller);
    // it should emit a Claim event
    _expectEmit(address(_pool));
    emit IPool.Claim(_caller, _caller, _recipient, _pending0, _pending1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should transfer token1 fees to the recipient
    // it should clear caller token1 claimable
    assertEq(_pool.claimable1(_caller), 0);
    // it should return the claimed token1 amount
    assertEq(_claimed0, 0);
    assertEq(_claimed1, _claimable1);
    // it should return the previously pending amounts
    assertEq(_claimed0, _pending0);
    assertEq(_claimed1, _pending1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasStoredFeesForBothTokens(
    address _caller,
    address _recipient,
    uint256 _claimable0,
    uint256 _claimable1
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, _caller);
    _claimable0 = bound(_claimable0, 1, type(uint128).max);
    _claimable1 = bound(_claimable1, 1, type(uint128).max);
    _setClaimable(_caller, _claimable0, _claimable1);

    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_caller);
    // it should have pending fees before claim
    assertEq(_pending0, _claimable0);
    assertEq(_pending1, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _pending0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _pending1);

    vm.prank(_caller);
    // it should emit a Claim event
    _expectEmit(address(_pool));
    emit IPool.Claim(_caller, _caller, _recipient, _pending0, _pending1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should transfer both token fees to the recipient
    // it should clear caller claimable amounts
    assertEq(_pool.claimable0(_caller), 0);
    assertEq(_pool.claimable1(_caller), 0);
    // it should return both claimed amounts
    assertEq(_claimed0, _claimable0);
    assertEq(_claimed1, _claimable1);
    // it should return the previously pending amounts
    assertEq(_claimed0, _pending0);
    assertEq(_claimed1, _pending1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasStoredAndNewlyAccruedFees() external {
    address _caller = makeAddr('caller');
    address _recipient = makeAddr('recipient');
    uint256 _liquidity = 3e18;
    uint256 _claimable0 = 7e18;
    uint256 _claimable1 = 11e18;
    uint256 _supplyIndex0 = 5e18;
    uint256 _supplyIndex1 = 8e18;
    uint256 _index0 = 7e18;
    uint256 _index1 = 12e18;
    uint256 _expected0 = 13e18;
    uint256 _expected1 = 23e18;

    _setBalance(_caller, _liquidity);
    _setClaimable(_caller, _claimable0, _claimable1);
    _setSupplyIndexes(_caller, _supplyIndex0, _supplyIndex1);
    _setIndexes(_index0, _index1);

    // it should include stored and newly accrued fees before claim
    _assertPendingFees(_caller, _expected0, _expected1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _expected0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _expected1);

    vm.prank(_caller);
    // it should emit a Claim event
    _expectEmit(address(_pool));
    emit IPool.Claim(_caller, _caller, _recipient, _expected0, _expected1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should update caller fee indexes
    assertEq(_pool.supplyIndex0(_caller), _index0);
    assertEq(_pool.supplyIndex1(_caller), _index1);
    // it should clear caller claimable amounts
    assertEq(_pool.claimable0(_caller), 0);
    assertEq(_pool.claimable1(_caller), 0);
    // it should transfer stored and newly accrued fees to the recipient
    // it should return stored and newly accrued amounts
    assertEq(_claimed0, _expected0);
    assertEq(_claimed1, _expected1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerIsTheRecipient(address _caller, uint256 _claimable0, uint256 _claimable1) external {
    _assumeFuzzable(_caller);
    _claimable0 = bound(_claimable0, 1, type(uint128).max);
    _claimable1 = bound(_claimable1, 1, type(uint128).max);
    _setClaimable(_caller, _claimable0, _claimable1);

    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_caller);
    // it should have pending fees before claim
    assertEq(_pending0, _claimable0);
    assertEq(_pending1, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _caller, _pending0);
    _mockAndExpectTokenTransfer(_token1, _caller, _pending1);

    vm.prank(_caller);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_caller);

    // it should transfer fees to the caller
    // it should return the previously pending amounts
    assertEq(_claimed0, _pending0);
    assertEq(_claimed1, _pending1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasNewlyAccruedFeesAndAmountsAreKnown() external {
    address _caller = makeAddr('caller');
    address _recipient = makeAddr('recipient');
    uint256 _liquidity = 4e18;
    uint256 _supplyIndex0 = 1e18;
    uint256 _supplyIndex1 = 2e18;
    uint256 _index0 = 3e18;
    uint256 _index1 = 5e18;
    uint256 _expected0 = 8e18;
    uint256 _expected1 = 12e18;

    _setBalance(_caller, _liquidity);
    _setSupplyIndexes(_caller, _supplyIndex0, _supplyIndex1);
    _setIndexes(_index0, _index1);

    // it should have pending newly accrued fees before claim
    _assertPendingFees(_caller, _expected0, _expected1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _expected0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _expected1);

    vm.prank(_caller);
    // it should emit a Claim event
    _expectEmit(address(_pool));
    emit IPool.Claim(_caller, _caller, _recipient, _expected0, _expected1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should update caller fee indexes
    assertEq(_pool.supplyIndex0(_caller), _index0);
    assertEq(_pool.supplyIndex1(_caller), _index1);
    // it should clear newly accrued claimable amounts
    assertEq(_pool.claimable0(_caller), 0);
    assertEq(_pool.claimable1(_caller), 0);
    // it should transfer newly accrued fees to the recipient
    // it should return the newly accrued amounts
    assertEq(_claimed0, _expected0);
    assertEq(_claimed1, _expected1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function test_WhenCallerHasNewlyAccruedFees(
    address _caller,
    address _recipient,
    uint256 _liquidity,
    uint256 _supplyIndex0,
    uint256 _supplyIndex1,
    uint256 _delta0,
    uint256 _delta1
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _liquidity = bound(_liquidity, 1e18, type(uint128).max);
    _supplyIndex0 = bound(_supplyIndex0, 0, type(uint128).max);
    _supplyIndex1 = bound(_supplyIndex1, 0, type(uint128).max);
    _delta0 = bound(_delta0, 1, type(uint128).max);
    _delta1 = bound(_delta1, 1, type(uint128).max);
    uint256 _index0 = _supplyIndex0 + _delta0;
    uint256 _index1 = _supplyIndex1 + _delta1;
    uint256 _expected0 = (_liquidity * _delta0) / 1e18;
    uint256 _expected1 = (_liquidity * _delta1) / 1e18;
    _setBalance(_caller, _liquidity);
    _setSupplyIndexes(_caller, _supplyIndex0, _supplyIndex1);
    _setIndexes(_index0, _index1);

    // it should have pending newly accrued fees before claim
    _assertPendingFees(_caller, _expected0, _expected1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _expected0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _expected1);

    vm.prank(_caller);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_recipient);

    // it should update caller fee indexes
    assertEq(_pool.supplyIndex0(_caller), _index0);
    assertEq(_pool.supplyIndex1(_caller), _index1);
    // it should clear newly accrued claimable amounts
    assertEq(_pool.claimable0(_caller), 0);
    assertEq(_pool.claimable1(_caller), 0);
    // it should transfer newly accrued fees to the recipient
    // it should return the newly accrued amounts
    assertEq(_claimed0, _expected0);
    assertEq(_claimed1, _expected1);
    // it should have no pending fees after claim
    _assertPendingFees(_caller, 0, 0);
  }

  function testGas_claimFees() external {
    address _caller = makeAddr('caller');
    uint256 _claimable0 = 10e18;
    uint256 _claimable1 = 20e18;
    _setClaimable(_caller, _claimable0, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _claimable0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _claimable1);

    vm.prank(_caller);
    _pool.claimFees(_recipient);

    vm.snapshotGasLastCall('Pool_claimFees');
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

  function _assertPendingFees(address _account, uint256 _expected0, uint256 _expected1) internal view {
    (uint256 _pending0, uint256 _pending1) = _pool.pendingFees(_account);
    assertEq(_pending0, _expected0);
    assertEq(_pending1, _expected1);
  }
}
