// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {
  IDiscountRegistry,
  UnitDiscountRegistryConstructor
} from 'V3-test/unit/fees/DiscountRegistry/DiscountRegistry.t.sol';

contract UnitDiscountRegistryRegisterDiscount is UnitDiscountRegistryConstructor {
  function test_WhenCallerIsntOwner() external {
    // it reverts with OwnableUnauthorizedAccount
    /// @dev Error message is thrown during {Ownable.onlyOwner} execution.
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
    discountRegistry.registerDiscount(address(0), 0);
  }

  modifier whenCallerIsOwner() {
    vm.startPrank(owner);
    _;
    vm.stopPrank();
  }

  function test_WhenAccountToDiscountIsAddressZero() external whenCallerIsOwner {
    // it reverts with AccountIsZero
    vm.expectRevert(IDiscountRegistry.AccountIsZero.selector);
    discountRegistry.registerDiscount(address(0), 0);
  }

  modifier whenAccountToDiscountIsntAddressZero(address _account) {
    vm.assume(_account != address(0));
    _;
  }

  function test_WhenNewDiscountExceedsMaxDiscount(
    address _account,
    uint24 _discount
  ) external whenCallerIsOwner whenAccountToDiscountIsntAddressZero(_account) {
    _discount = uint24(bound(uint256(_discount), uint256(discountRegistry.MAX_DISCOUNT() + 1), type(uint24).max));

    // it reverts with NewDiscountGtMax
    vm.expectRevert(IDiscountRegistry.NewDiscountGtMax.selector);
    discountRegistry.registerDiscount(_account, _discount);
  }

  modifier whenNewDiscountIsLtOrEqMaxDiscount(uint24 _discount) {
    _discount = uint24(bound(uint256(_discount), 0, uint256(discountRegistry.MAX_DISCOUNT())));
    _;
  }

  function test_WhenNewDiscountEqualsOldDiscount(
    address _account,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
  {
    _discount = uint24(bound(uint256(_discount), 0, uint256(discountRegistry.MAX_DISCOUNT())));

    /// @dev Set initial discount (old).
    _setDiscount(_account, _discount);

    // it reverts with OldDiscountEqNewDiscount
    vm.expectRevert(IDiscountRegistry.OldDiscountEqNewDiscount.selector);
    discountRegistry.registerDiscount(_account, _discount);
  }

  function test_WhenNewDiscountIsDifferentFromOldDiscount(
    address _account,
    uint24 _oldDiscount,
    uint24 _newDiscount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_newDiscount)
  {
    _newDiscount = uint24(bound(uint256(_newDiscount), 0, uint256(discountRegistry.MAX_DISCOUNT())));
    vm.assume(_oldDiscount != _newDiscount);

    _setDiscount(_account, _oldDiscount);

    // it emits DiscountSet event
    vm.expectEmit();
    emit IDiscountRegistry.DiscountSet(_account, _newDiscount);

    discountRegistry.registerDiscount(_account, _newDiscount);

    (, uint24 _discount) = discountRegistry.discounts(_account);

    // it sets discount to new discount
    assertEq(uint256(_discount), uint256(_newDiscount));
  }
}
