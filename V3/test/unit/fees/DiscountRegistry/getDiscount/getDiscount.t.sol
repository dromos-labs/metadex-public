// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {UnitDiscountRegistryConstructor} from 'V3-test/unit/fees/DiscountRegistry/DiscountRegistry.t.sol';

contract UnitDiscountRegistryGetDiscount is UnitDiscountRegistryConstructor {
  function test_WhenOriginEqCallerAndHasPoolDiscount(address _origin, address _pool, uint24 _discount) external {
    vm.startPrank(_origin, _origin);

    _discount = uint24(bound(uint256(_discount), 1, discountRegistry.MAX_DISCOUNT()));

    _setPoolDiscount(_origin, _pool, _discount);
    _setIsPoolDiscountSet(_origin, true);

    vm.record();
    uint24 _poolDiscount = discountRegistry.getDiscount(_pool, _origin);
    vm.stopPrank();

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses 2 SLOADs
    assertEq(_sloads.length, 2);

    // it returns pool discount
    assertEq(_poolDiscount, _discount);
  }

  function test_WhenOriginEqCallerAndHasNoPoolDiscountOrItIsZero(
    address _origin,
    address _pool,
    uint24 _poolDiscount,
    uint24 _discount
  ) external {
    vm.startPrank(_origin, _origin);

    _discount = uint24(bound(uint256(_discount), 0, discountRegistry.MAX_DISCOUNT()));
    _setDiscount(_origin, _discount);

    _poolDiscount = uint24(bound(uint256(_poolDiscount), 0, discountRegistry.MAX_DISCOUNT()));
    /// @dev `isPoolDiscountSet` is either TRUE or FALSE (additional SLOAD)
    ///      Pool discount is always zero.
    if (_poolDiscount > 0) {
      _setIsPoolDiscountSet(_origin, true);
    }

    vm.record();
    uint24 _originDiscount = discountRegistry.getDiscount(_pool, _origin);

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses at least 1 SLOAD and at most 2 SLOADs
    assertGe(_sloads.length, 1);
    assertLe(_sloads.length, 2);

    // it returns discount value for origin
    assertEq(_originDiscount, _discount);
  }

  function test_WhenOriginDoesntEqCallerAndCallerHasPoolDiscountAndItIsGtZero(
    address _origin,
    address _caller,
    address _pool,
    uint24 _poolDiscount
  ) external {
    vm.assume(_origin != _caller);

    vm.startPrank(_caller, _origin);

    _poolDiscount = uint24(bound(uint256(_poolDiscount), 1, discountRegistry.MAX_DISCOUNT()));

    /// @dev Pool discount is set for `_caller`.
    _setPoolDiscount(_caller, _pool, _poolDiscount);
    _setIsPoolDiscountSet(_caller, true);

    vm.record();
    uint24 _callerPoolDiscount = discountRegistry.getDiscount(_pool, _caller);

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses 2 SLOADs
    assertEq(_sloads.length, 2);

    // it returns caller's pool discount
    assertEq(_callerPoolDiscount, _poolDiscount);
  }

  modifier whenOriginDoesntEqCallerAndCallerDoesntHavePoolDiscountOrItIsZero(
    address _origin,
    address _caller,
    uint24 _poolDiscount
  ) {
    vm.assume(_origin != _caller);

    _poolDiscount = uint24(bound(uint256(_poolDiscount), 0, discountRegistry.MAX_DISCOUNT()));
    /// @dev `isPoolDiscountSet` is either TRUE or FALSE (additional SLOAD)
    ///      Pool discount is always zero.
    if (_poolDiscount > 0) {
      _setIsPoolDiscountSet(_caller, true);
    }

    vm.startPrank(_caller, _origin);
    _;
    vm.stopPrank();
  }

  function test_WhenCallerHasDiscount(
    address _origin,
    address _caller,
    address _pool,
    uint24 _poolDiscount,
    uint24 _discount
  ) external whenOriginDoesntEqCallerAndCallerDoesntHavePoolDiscountOrItIsZero(_origin, _caller, _poolDiscount) {
    _discount = uint24(bound(uint256(_discount), 1, discountRegistry.MAX_DISCOUNT()));

    /// @dev Discount is set for caller.
    _setDiscount(_caller, _discount);

    vm.record();
    uint24 _callerDiscount = discountRegistry.getDiscount(_pool, _caller);

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses at least 1 SLOAD and at most 2 SLOADs
    assertGe(_sloads.length, 1);
    assertLe(_sloads.length, 2);

    // it returns caller's discount
    assertEq(_callerDiscount, _discount);
  }

  modifier whenCallerDoesntHaveDiscount() {
    _;
  }

  function test_WhenOriginHasPoolDiscountAndItIsGtZero(
    address _origin,
    address _caller,
    address _pool,
    uint24 _poolDiscount
  )
    external
    whenOriginDoesntEqCallerAndCallerDoesntHavePoolDiscountOrItIsZero(_origin, _caller, _poolDiscount)
    whenCallerDoesntHaveDiscount
  {
    _poolDiscount = uint24(bound(uint256(_poolDiscount), 1, discountRegistry.MAX_DISCOUNT()));

    _setPoolDiscount(_origin, _pool, _poolDiscount);
    _setIsPoolDiscountSet(_origin, true);

    vm.record();
    uint24 _originPoolDiscount = discountRegistry.getDiscount(_pool, _caller);

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses at least 3 SLOADs and at most 4 SLOADs
    assertGe(_sloads.length, 3);
    assertLe(_sloads.length, 4);

    // it returns origin's pool discount
    assertEq(_originPoolDiscount, _poolDiscount);
  }

  function test_WhenOriginDoesntHavePoolDiscountOrItIsZero(
    address _caller,
    address _origin,
    address _pool,
    uint24 _poolDiscount,
    uint24 _discount
  )
    external
    whenOriginDoesntEqCallerAndCallerDoesntHavePoolDiscountOrItIsZero(_origin, _caller, _poolDiscount)
    whenCallerDoesntHaveDiscount
  {
    _discount = uint24(bound(uint256(_discount), 0, discountRegistry.MAX_DISCOUNT()));

    _setDiscount(_origin, _discount);

    vm.record();
    uint24 _originDiscount = discountRegistry.getDiscount(_pool, _caller);

    (bytes32[] memory _sloads,) = vm.accesses(address(discountRegistry));

    // it uses at least 2 SLOADs and at most 4 SLOADs
    assertGe(_sloads.length, 2);
    assertLe(_sloads.length, 4);

    // it returns discount value for origin
    assertEq(_originDiscount, _discount);
  }
}
