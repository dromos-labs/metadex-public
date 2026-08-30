// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {
  IDiscountRegistry,
  UnitDiscountRegistryConstructor
} from 'V3-test/unit/fees/DiscountRegistry/DiscountRegistry.t.sol';

contract UnitDiscountRegistryRegisterPoolFeeFloorExemption is UnitDiscountRegistryConstructor {
  function test_WhenCallerIsntTheOwner() external {
    // it reverts with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
    discountRegistry.registerPoolFeeFloorExemption(address(0), address(0), false);
  }

  modifier whenCallerIsTheOwner() {
    vm.startPrank(owner);
    _;
    vm.stopPrank();
  }

  function test_WhenAccountAddressEqZero() external whenCallerIsTheOwner {
    // it reverts with AccountIsZero
    vm.expectRevert(IDiscountRegistry.AccountIsZero.selector);
    discountRegistry.registerPoolFeeFloorExemption(address(0), address(0), false);
  }

  modifier whenAccountAddressDoesNotEqZero(address _account) {
    vm.assume(_account != address(0));
    _;
  }

  function test_WhenPoolAddressEqZero(address _account)
    external
    whenCallerIsTheOwner
    whenAccountAddressDoesNotEqZero(_account)
  {
    // it reverts with PoolIsZero
    vm.expectRevert(IDiscountRegistry.PoolIsZero.selector);
    discountRegistry.registerPoolFeeFloorExemption(_account, address(0), false);
  }

  function test_WhenPoolAddressDoesNotEqZero(
    address _account,
    address _pool,
    bool _previousExempt,
    bool _newExempt
  ) external whenCallerIsTheOwner whenAccountAddressDoesNotEqZero(_account) {
    vm.assume(_pool != address(0));

    _setPoolFeeFloorExempt(_pool, _account, _previousExempt);

    assertEq(discountRegistry.poolFeeFloorExempt(_pool, _account), _previousExempt);

    // it emits PoolFeeFloorExemptionSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolFeeFloorExemptionSet(_account, _pool, _newExempt);

    discountRegistry.registerPoolFeeFloorExemption(_account, _pool, _newExempt);

    // it sets poolFeeFloorExempt to the new exempt flag
    assertEq(discountRegistry.poolFeeFloorExempt(_pool, _account), _newExempt);
  }
}
