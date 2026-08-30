// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {BasePoolClaimFees} from 'V3-test/unit/pools/Pool/BasePoolClaimFees.sol';

contract UnitPoolClaimFeesRecipientOperator is BasePoolClaimFees {
  function test_WhenOperatorIsNotApprovedByAccount(address _account, address _operator, address _recipient) external {
    _assumeFuzzable(_account);
    _assumeFuzzable(_operator);
    _assumeFuzzable(_recipient);
    _operator = _boundNotEq(_operator, _account);

    vm.prank(_operator);
    // it should revert with NotAuthorized
    vm.expectRevert(IPool.NotAuthorized.selector);
    _pool.claimFees(_account, _recipient);
  }

  modifier whenOperatorIsApprovedByAccount() {
    _;
  }

  function test_WhenAccountHasStoredFees(
    address _account,
    address _operator,
    address _recipient,
    uint256 _claimable0,
    uint256 _claimable1
  ) external whenOperatorIsApprovedByAccount {
    _assumeFuzzable(_account);
    _assumeFuzzable(_operator);
    _assumeFuzzable(_recipient);
    _operator = _boundNotEq(_operator, _account);
    _claimable0 = bound(_claimable0, 1, type(uint128).max);
    _claimable1 = bound(_claimable1, 1, type(uint128).max);
    _setApprovedForClaim(_account, _operator, true);
    _setClaimable(_account, _claimable0, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _claimable0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _claimable1);

    vm.prank(_operator);
    // it should emit a Claim event with the operator as caller
    _expectEmit(address(_pool));
    emit IPool.Claim(_operator, _account, _recipient, _claimable0, _claimable1);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_account, _recipient);

    // it should transfer both fee tokens to the recipient
    // it should clear the account claimable amounts
    assertEq(_pool.claimable0(_account), 0);
    assertEq(_pool.claimable1(_account), 0);
    // it should return both claimed amounts
    assertEq(_claimed0, _claimable0);
    assertEq(_claimed1, _claimable1);
  }

  function test_WhenAccountHasNewlyAccruedFees() external whenOperatorIsApprovedByAccount {
    address _account = makeAddr('account');
    address _operator = makeAddr('operator');
    address _recipient = makeAddr('recipient');
    address _otherAccount = makeAddr('otherAccount');
    uint256 _index0 = 7e18;
    uint256 _index1 = 12e18;
    uint256 _expected0 = 6e18;
    uint256 _expected1 = 12e18;
    uint256 _otherExpected0 = 18e18;
    uint256 _otherExpected1 = 32e18;
    _setApprovedForClaim(_account, _operator, true);
    _setBalance(_account, 3e18);
    _setSupplyIndexes(_account, 5e18, 8e18);
    _setBalance(_otherAccount, 5e18);
    _setClaimable(_otherAccount, 13e18, 17e18);
    _setSupplyIndexes(_otherAccount, 6e18, 9e18);
    _setIndexes(_index0, _index1);
    _assertPendingFees(_account, _expected0, _expected1);
    _assertPendingFees(_otherAccount, _otherExpected0, _otherExpected1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _expected0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _expected1);

    vm.prank(_operator);
    (uint256 _claimed0, uint256 _claimed1) = _pool.claimFees(_account, _recipient);

    // it should update the account fee indexes
    assertEq(_pool.supplyIndex0(_account), _index0);
    assertEq(_pool.supplyIndex1(_account), _index1);
    // it should clear the account claimable amounts
    assertEq(_pool.claimable0(_account), 0);
    assertEq(_pool.claimable1(_account), 0);
    // it should not change another account pending fees
    _assertPendingFees(_otherAccount, _otherExpected0, _otherExpected1);
    // it should transfer both fee tokens to the recipient
    // it should return both claimed amounts
    assertEq(_claimed0, _expected0);
    assertEq(_claimed1, _expected1);
  }

  function testGas_claimFeesRecipientOperator() external {
    address _account = makeAddr('account');
    address _operator = makeAddr('operator');
    uint256 _claimable0 = 10e18;
    uint256 _claimable1 = 20e18;
    _setApprovedForClaim(_account, _operator, true);
    _setClaimable(_account, _claimable0, _claimable1);
    _mockAndExpectTokenTransfer(_token0, _recipient, _claimable0);
    _mockAndExpectTokenTransfer(_token1, _recipient, _claimable1);

    vm.prank(_operator);
    _pool.claimFees(_account, _recipient);

    vm.snapshotGasLastCall('Pool_claimFeesRecipientOperator');
  }
}
