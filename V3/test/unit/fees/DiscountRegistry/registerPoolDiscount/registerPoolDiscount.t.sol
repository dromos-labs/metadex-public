// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {
  IDiscountRegistry,
  UnitDiscountRegistryConstructor
} from 'V3-test/unit/fees/DiscountRegistry/DiscountRegistry.t.sol';

contract UnitDiscountRegistryRegisterPoolDiscount is UnitDiscountRegistryConstructor {
  function test_WhenCallerIsntOwner() external {
    // it reverts with OwnableUnauthorizedAccount
    /// @dev Error message is thrown during {Ownable.onlyOwner} execution.
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
    discountRegistry.registerPoolDiscount(address(0), address(0), 0);
  }

  modifier whenCallerIsOwner() {
    vm.startPrank(owner);
    _;
    vm.stopPrank();
  }

  function test_WhenAccountToDiscountIsAddressZero() external whenCallerIsOwner {
    // it reverts with AccountIsZero
    vm.expectRevert(IDiscountRegistry.AccountIsZero.selector);
    discountRegistry.registerPoolDiscount(address(0), address(0), 0);
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
    discountRegistry.registerPoolDiscount(_account, address(0), _discount);
  }

  modifier whenNewDiscountIsLtOrEqMaxDiscount(uint24 _discount) {
    _discount = uint24(bound(uint256(_discount), 0, discountRegistry.MAX_DISCOUNT()));
    _;
  }

  function test_WhenPoolIsAddressZero(
    address _account,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
  {
    _discount = uint24(bound(uint256(_discount), 0, uint256(discountRegistry.MAX_DISCOUNT())));

    // it reverts with PoolIsZero
    vm.expectRevert(IDiscountRegistry.PoolIsZero.selector);
    discountRegistry.registerPoolDiscount(_account, address(0), _discount);
  }

  modifier whenPoolIsntAddressZero(address _pool) {
    vm.assume(_pool != address(0));
    _;
  }

  function test_WhenNewDiscountEqualsOldDiscount(
    address _account,
    address _pool,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
    whenPoolIsntAddressZero(_pool)
  {
    _discount = uint24(bound(uint256(_discount), 0, uint256(discountRegistry.MAX_DISCOUNT())));

    /// @dev Set initial discount (old).
    _setPoolDiscount(_account, _pool, _discount);

    // it reverts with OldDiscountEqNewDiscount
    vm.expectRevert(IDiscountRegistry.OldDiscountEqNewDiscount.selector);
    discountRegistry.registerPoolDiscount(_account, _pool, _discount);
  }

  modifier whenNewDiscountIsDifferentFromOldDiscount(address _account, address _pool, uint24 _discount) {
    /// @dev In de-registration case the old discount must be >0.
    if (_discount == 0) {
      _setPoolDiscount(_account, _pool, 1);
      /// @dev Mark {isPoolDiscountSet} as true, to test mutations
      ///      of de-registration against non-zero state.
      _setIsPoolDiscountSet(_account, true);

      _pushDiscountedPool(_account, _pool);
    }
    /// @dev In all other cases the old discount's value is 0.
    _;
  }

  function test_WhenPoolIsInDiscountedSingleElementSetAndNewDiscountIsZero(
    address _account,
    address _pool
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(0)
    whenPoolIsntAddressZero(_pool)
    whenNewDiscountIsDifferentFromOldDiscount(_account, _pool, 0)
  {
    // {whenNewDiscountIsDifferentFromOldDiscount} sets up
    // the set with one pool element.

    /// @dev The set MUST be singleton.
    assertEq(_getDiscountedPoolsLen(_account), 1);
    assertTrue(_containsDiscountedPool(_account, _pool));

    // it emits PoolDiscountSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolDiscountSet(_account, _pool, 0);

    discountRegistry.registerPoolDiscount(_account, _pool, 0);

    uint256 _newLen = _getDiscountedPoolsLen(_account);
    (bool _isPoolDiscountSet,) = discountRegistry.discounts(_account);

    // it removes pool from discounted pools set
    assertEq(_newLen, 0);
    assertFalse(_containsDiscountedPool(_account, _pool));

    // it flips isPoolDiscountSet to false
    assertFalse(_isPoolDiscountSet);

    // it sets poolDiscount to zero
    assertEq(uint256(_getPoolDiscount(_account, _pool)), 0);
  }

  function test_WhenPoolIsInDiscountedMultiElementSetAndNewDiscountIsZero(
    address _account,
    address _pool,
    address _anotherPool
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(0)
    whenPoolIsntAddressZero(_pool)
    whenNewDiscountIsDifferentFromOldDiscount(_account, _pool, 0)
  {
    vm.assume(_pool != _anotherPool);
    vm.assume(_anotherPool != address(0));

    // The pool becomes multi-element.
    _pushDiscountedPool(_account, _anotherPool);
    _setPoolDiscount(_account, _anotherPool, 1);

    assertEq(_getDiscountedPoolsLen(_account), 2);
    assertTrue(_containsDiscountedPool(_account, _anotherPool));

    // it emits PoolDiscountSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolDiscountSet(_account, _pool, 0);

    discountRegistry.registerPoolDiscount(_account, _pool, 0);

    (bool _isPoolDiscountSet,) = discountRegistry.discounts(_account);

    /// @dev The global flag is still true.
    assertTrue(_isPoolDiscountSet);

    // it removes pool from discounted pools set
    assertEq(_getDiscountedPoolsLen(_account), 1);
    assertFalse(_containsDiscountedPool(_account, _pool));

    // it sets poolDiscount to zero
    assertEq(uint256(_getPoolDiscount(_account, _pool)), 0);

    /// @dev Discount for another pool is still present.
    assertEq(uint256(_getPoolDiscount(_account, _anotherPool)), 1);
    assertTrue(_containsDiscountedPool(_account, _anotherPool));
  }

  function test_WhenPoolIsInDiscountedMultiElementSetAndNewDiscountIsGtZero(
    address _account,
    address _pool,
    address _anotherPool,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
    whenPoolIsntAddressZero(_pool)
    whenNewDiscountIsDifferentFromOldDiscount(_account, _pool, 0)
  {
    vm.assume(_pool != _anotherPool);
    vm.assume(_anotherPool != address(0));

    /// @dev Start with 2, since {whenNewDiscountIsDifferentFromOldDiscount} sets discount to 1.
    _discount = uint24(bound(uint256(_discount), 2, discountRegistry.MAX_DISCOUNT()));

    // The pool becomes multi-element.
    _pushDiscountedPool(_account, _anotherPool);
    _setPoolDiscount(_account, _anotherPool, 1);

    assertEq(_getDiscountedPoolsLen(_account), 2);
    assertTrue(_containsDiscountedPool(_account, _anotherPool));

    /// @dev The current pool to discount is also already discounted.
    assertTrue(_containsDiscountedPool(_account, _pool));

    // it emits PoolDiscountSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolDiscountSet(_account, _pool, _discount);

    discountRegistry.registerPoolDiscount(_account, _pool, _discount);

    // it sets poolDiscount to new discount
    assertEq(uint256(_getPoolDiscount(_account, _pool)), uint256(_discount));

    /// @dev The length is the same
    assertEq(_getDiscountedPoolsLen(_account), 2);
  }

  function test_WhenPoolIsntDiscountedAndTheSetIsEmpty(
    address _account,
    address _pool,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
    whenPoolIsntAddressZero(_pool)
    whenNewDiscountIsDifferentFromOldDiscount(_account, _pool, 1)
  {
    _discount = uint24(bound(uint256(_discount), 1, discountRegistry.MAX_DISCOUNT()));

    /// @dev The set is empty.
    assertEq(_getDiscountedPoolsLen(_account), 0);

    // it emits PoolDiscountSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolDiscountSet(_account, _pool, _discount);

    discountRegistry.registerPoolDiscount(_account, _pool, _discount);

    (bool _isPoolDiscountSet,) = discountRegistry.discounts(_account);

    // it adds pool to discounted pools set
    assertTrue(_containsDiscountedPool(_account, _pool));
    assertEq(_getDiscountedPoolsLen(_account), 1);

    // it marks isPoolDiscountSet as true
    assertTrue(_isPoolDiscountSet);

    // it sets poolDiscount to new discount
    assertEq(uint256(_getPoolDiscount(_account, _pool)), uint256(_discount));
  }

  function test_WhenPoolIsntDiscountedAndTheSetIsMultiElement(
    address _account,
    address _pool,
    uint24 _discount
  )
    external
    whenCallerIsOwner
    whenAccountToDiscountIsntAddressZero(_account)
    whenNewDiscountIsLtOrEqMaxDiscount(_discount)
    whenPoolIsntAddressZero(_pool)
    whenNewDiscountIsDifferentFromOldDiscount(_account, _pool, 1)
  {
    _pool = address(uint160(bound(uint256(uint160(_pool)), 1, type(uint160).max - 2)));

    address _pool0 = address(uint160(_pool) + 1);
    address _pool1 = address(uint160(_pool0) + 1);

    _setPoolDiscount(_account, _pool0, 1);
    _setPoolDiscount(_account, _pool1, 1);

    _setIsPoolDiscountSet(_account, true);

    _pushDiscountedPool(_account, _pool0);
    _pushDiscountedPool(_account, _pool1);

    /// @dev The set is multi-element.
    assertEq(_getDiscountedPoolsLen(_account), 2);

    _discount = uint24(bound(uint256(_discount), 1, discountRegistry.MAX_DISCOUNT()));

    // it emits PoolDiscountSet
    vm.expectEmit();
    emit IDiscountRegistry.PoolDiscountSet(_account, _pool, _discount);

    discountRegistry.registerPoolDiscount(_account, _pool, _discount);

    // it adds pool to discounted pools set
    assertTrue(_containsDiscountedPool(_account, _pool));
    assertEq(_getDiscountedPoolsLen(_account), 3);

    // it sets poolDiscount to new discount
    assertEq(uint256(_getPoolDiscount(_account, _pool)), uint256(_discount));
  }
}
