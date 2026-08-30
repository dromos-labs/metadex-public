// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {IPool} from 'V3/interfaces/pools/IPool.sol';

import {MockPool} from 'V3-test/mocks/MockPool.sol';
import {UnitPool} from 'V3-test/unit/pools/Pool.t.sol';

contract UnitPoolApproveForClaim is UnitPool {
  using stdStorage for StdStorage;

  function test_WhenOperatorIsZeroAddress(address _caller, bool _approved) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IPool.ZeroAddress.selector);
    _pool.approveForClaim(address(0), _approved);
  }

  function test_WhenOperatorIsNotZeroAddress(
    address _caller,
    address _operator,
    bool _initialApproval,
    bool _approved
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_operator);
    stdstore.target(address(_pool)).sig(IPool.approvedForClaim.selector).with_key(_caller).with_key(_operator)
      .checked_write(_initialApproval);

    vm.prank(_caller);
    // it should emit a ClaimApproval event
    _expectEmit(address(_pool));
    emit IPool.ClaimApproval(_caller, _operator, _approved);
    _pool.approveForClaim(_operator, _approved);

    // it should set the caller approval for the operator
    assertEq(_pool.approvedForClaim(_caller, _operator), _approved);
  }

  function testGas_approveForClaim() external {
    address _operator = makeAddr('operator');

    _pool.approveForClaim(_operator, true);

    vm.snapshotGasLastCall('Pool_approveForClaim');
  }

  function _deployPool() internal override returns (IPool) {
    return IPool(address(new MockPool()));
  }
}
