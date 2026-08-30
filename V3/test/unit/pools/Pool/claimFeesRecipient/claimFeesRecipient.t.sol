// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {BasePoolClaimFees} from 'V3-test/unit/pools/Pool/BasePoolClaimFees.sol';

contract UnitPoolClaimFeesRecipient is BasePoolClaimFees {
  function test_WhenRecipientIsZeroAddress(address _account) external {
    _assumeFuzzable(_account);

    vm.prank(_account);
    // it should revert with ZeroAddress
    vm.expectRevert(IPool.ZeroAddress.selector);
    _pool.claimFees(_account, address(0));
  }

  modifier whenRecipientIsNotZeroAddress() {
    _;
  }

  function test_WhenAccountHasNoClaimableFees(
    address _account,
    address _recipient,
    uint256 _index0,
    uint256 _index1
  ) external whenRecipientIsNotZeroAddress {
    _assumeFuzzable(_account);
    _assumeFuzzable(_recipient);
    _index0 = bound(_index0, 0, type(uint128).max);
    _index1 = bound(_index1, 0, type(uint128).max);
    _setIndexes(_index0, _index1);

    vm.recordLogs();
    vm.prank(_account);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_account, _recipient);

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
    // it should sync the account fee indexes
    assertEq(_pool.supplyIndex0(_account), _index0);
    assertEq(_pool.supplyIndex1(_account), _index1);
    // it should not emit a Claim event
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenAccountHasStoredFees(
    address _account,
    address _recipient,
    uint256 _claimable0,
    uint256 _claimable1
  ) external whenRecipientIsNotZeroAddress {
    _assumeFuzzable(_account);
    _assumeFuzzable(_recipient);
    _claimable0 = bound(_claimable0, 1, type(uint128).max);
    _claimable1 = bound(_claimable1, 1, type(uint128).max);
    _setClaimable(_account, _claimable0, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _claimable0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _claimable1);

    vm.prank(_account);
    // it should emit a Claim event with the account as caller
    _expectEmit(address(_pool));
    emit IPool.Claim(_account, _account, _recipient, _claimable0, _claimable1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_account, _recipient);

    // it should transfer both fee tokens to the recipient
    // it should clear the account claimable amounts
    assertEq(_pool.claimable0(_account), 0);
    assertEq(_pool.claimable1(_account), 0);
    // it should return both claimed amounts
    assertEq(_claimed0, _claimable0);
    assertEq(_claimed1, _claimable1);
  }

  function testGas_claimFeesRecipient() external {
    address _account = makeAddr('account');
    uint256 _claimable0 = 10e18;
    uint256 _claimable1 = 20e18;
    _setClaimable(_account, _claimable0, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _claimable0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _claimable1);

    vm.prank(_account);
    _pool.claimFees(_account, _recipient);

    vm.snapshotGasLastCall('Pool_claimFeesRecipient');
  }
}
