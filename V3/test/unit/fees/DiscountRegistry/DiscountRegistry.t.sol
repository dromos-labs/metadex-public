// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {DiscountRegistry, IDiscountRegistry} from 'V3/fees/DiscountRegistry.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @notice Defines constructor test and helpers for child DR tests.
contract UnitDiscountRegistryConstructor is TestHelpers {
  using stdStorage for StdStorage;

  uint256 private constant DISCOUNTS_SLOT = 2;
  uint256 private constant DISCOUNTED_POOLS_SLOT = 3;
  uint256 private constant _POOL_FEE_FLOOR_EXEMPT_SLOT = 4;

  DiscountRegistry public discountRegistry;
  address public owner = makeAddr('owner');

  function setUp() external {
    vm.prank(owner);
    discountRegistry = new DiscountRegistry(owner);
  }

  function test_WhenDeployed() external view {
    // it sets owner as msg.sender
    assertEq(discountRegistry.owner(), owner);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setIsPoolDiscountSet(address _account, bool _set) internal {
    stdstore.target(address(discountRegistry)).sig(IDiscountRegistry.discounts.selector).with_key(_account)
      .enable_packed_slots().depth(0).checked_write(_set);
  }

  function _setDiscount(address _account, uint24 _discount) internal {
    stdstore.target(address(discountRegistry)).sig(IDiscountRegistry.discounts.selector).with_key(_account)
      .enable_packed_slots().depth(1).checked_write(_discount);
  }

  /// @dev Using {vm.store}, because can't access nested storage maps with `stdstore`.
  function _setPoolDiscount(address _account, address _pool, uint24 _discount) internal {
    bytes32 _discountsSlot = keccak256(abi.encode(_account, DISCOUNTS_SLOT));
    bytes32 _poolDiscountsOffset = bytes32(uint256(_discountsSlot) + 1);
    bytes32 _poolDiscountsSlot = keccak256(abi.encode(_pool, _poolDiscountsOffset));

    vm.store(address(discountRegistry), _poolDiscountsSlot, bytes32(uint256(_discount)));
  }

  function _getPoolDiscount(address _account, address _pool) internal view returns (uint24 _discount) {
    bytes32 _discountsSlot = keccak256(abi.encode(_account, DISCOUNTS_SLOT));
    bytes32 _poolDiscountsOffset = bytes32(uint256(_discountsSlot) + 1);
    bytes32 _poolDiscountsSlot = keccak256(abi.encode(_pool, _poolDiscountsOffset));

    _discount = uint24(uint256(vm.load(address(discountRegistry), _poolDiscountsSlot)));
  }

  /**
   * @dev It's needed to update {Set._values} and {Set._indexes} to
   *      properly reflect element addition to {EnumerableSet}.
   *
   *    struct Set {
   *      // Storage of set values
   *      bytes32[] _values;
   *
   *      // Position of the value in the `values` array, plus 1 because index 0
   *      // means a value is not in the set.
   *      mapping (bytes32 => uint256) _indexes;
   *    }
   */
  function _pushDiscountedPool(address _account, address _pool) internal {
    bytes32 _enumSetSlot = keccak256(abi.encode(_account, DISCOUNTED_POOLS_SLOT));

    uint256 _len = uint256(vm.load(address(discountRegistry), _enumSetSlot));

    bytes32 _valuesSlot = keccak256(abi.encode(_enumSetSlot));
    bytes32 _appendPos = bytes32(uint256(_valuesSlot) + _len);

    bytes32 _newElement = bytes32(uint256(uint160(_pool)));

    /// @dev Append pool to {Set._values}.
    vm.store(address(discountRegistry), _appendPos, _newElement);

    /// @dev Update the length of {Set._values}.
    vm.store(address(discountRegistry), _enumSetSlot, bytes32(_len + 1));

    bytes32 _indexesSlot = bytes32(uint256(_enumSetSlot) + 1);
    bytes32 _index = keccak256(abi.encode(_newElement, _indexesSlot));

    /// @dev Indexes start at 1.
    vm.store(address(discountRegistry), _index, bytes32(_len + 1));
  }

  function _containsDiscountedPool(address _account, address _pool) internal view returns (bool _contains) {
    bytes32 _enumSetSlot = keccak256(abi.encode(_account, DISCOUNTED_POOLS_SLOT));
    bytes32 _indexesSlot = bytes32(uint256(_enumSetSlot) + 1);

    bytes32 _indexSlot = keccak256(abi.encode(bytes32(uint256(uint160(_pool))), _indexesSlot));

    _contains = uint256(vm.load(address(discountRegistry), _indexSlot)) != 0;
  }

  function _getDiscountedPoolsLen(address _account) internal view returns (uint256 _len) {
    bytes32 _enumSetSlot = keccak256(abi.encode(_account, DISCOUNTED_POOLS_SLOT));
    _len = uint256(vm.load(address(discountRegistry), _enumSetSlot));
  }

  function _setPoolFeeFloorExempt(address _pool, address _account, bool _exempt) internal {
    bytes32 _poolSlot = keccak256(abi.encode(_pool, _POOL_FEE_FLOOR_EXEMPT_SLOT));
    bytes32 _pairSlot = keccak256(abi.encode(_account, _poolSlot));

    vm.store(address(discountRegistry), _pairSlot, bytes32(uint256(_exempt ? 1 : 0)));
  }
}
