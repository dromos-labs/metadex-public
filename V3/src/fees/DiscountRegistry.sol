// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';
import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {IDiscountRegistry} from 'V3/interfaces/fees/IDiscountRegistry.sol';

/// @title DiscountRegistry
/// @notice Central registry for fee discounts applicable to CL and V2 pool types.
contract DiscountRegistry is Ownable2Step, IDiscountRegistry {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDiscountRegistry
  /// @dev The value is fixed at 800_000 (80%). Any registration attempt with
  ///      a discount higher than this cap will revert.
  uint24 public constant MAX_DISCOUNT = 800_000;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @dev The mapping stores discount data:
  ///      chain-wide discount and per-pool discounts.
  /// @inheritdoc IDiscountRegistry
  mapping(address _account => Discount _discount) public discounts;

  /// @dev The mapping stores set of discounted pools for account.
  mapping(address _account => EnumerableSet.AddressSet _discountedPools) private _discountedPools;

  /// @inheritdoc IDiscountRegistry
  mapping(address _pool => mapping(address _caller => bool _exempt)) public poolFeeFloorExempt;

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  constructor(address _initialOwner) Ownable(_initialOwner) {}

  /*////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDiscountRegistry
  function getDiscount(address _pool, address _caller) external view returns (uint24 _discount) {
    // slither-disable-next-line tx-origin
    if (tx.origin != _caller) {
      _discount = _getDiscount(_pool, _caller);
      if (_discount > 0) return _discount;
    }
    _discount = _getDiscount(_pool, tx.origin);
  }

  /// @inheritdoc IDiscountRegistry
  function getDiscountedPools(
    address _account,
    uint256 _start,
    uint256 _end
  ) external view returns (address[] memory _pools) {
    _pools = _discountedPools[_account].values(_start, _end);
  }

  /*////////////////////////////////////////////////////////////
                              AUTHORIZED FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDiscountRegistry
  function registerDiscount(address _account, uint24 _newDiscount) external onlyOwner {
    if (_account == address(0)) revert AccountIsZero();
    if (_newDiscount > MAX_DISCOUNT) revert NewDiscountGtMax();

    Discount storage _currentDiscount = discounts[_account];
    if (_currentDiscount.discount == _newDiscount) revert OldDiscountEqNewDiscount();

    _currentDiscount.discount = _newDiscount;

    emit DiscountSet(_account, _newDiscount);
  }

  /// @inheritdoc IDiscountRegistry
  function registerPoolDiscount(address _account, address _pool, uint24 _newDiscount) external onlyOwner {
    if (_account == address(0)) revert AccountIsZero();
    if (_newDiscount > MAX_DISCOUNT) revert NewDiscountGtMax();
    if (_pool == address(0)) revert PoolIsZero();

    Discount storage _currentDiscount = discounts[_account];
    if (_currentDiscount.poolDiscount[_pool] == _newDiscount) revert OldDiscountEqNewDiscount();

    EnumerableSet.AddressSet storage _pools = _discountedPools[_account];
    bool _isPoolDiscounted = _pools.contains(_pool);

    /// @dev Discount de-registration case.
    if (_isPoolDiscounted && _newDiscount == 0) {
      // slither-disable-next-line unused-return
      _pools.remove(_pool);

      /// @dev All discounted pools are now removed from `_account`.
      if (_pools.length() == 0) {
        _currentDiscount.isPoolDiscountSet = false;
      }
    }
    /// @dev Discount registration case.
    ///      Discount can't be 0 here, since when the pool isn't
    ///      discounted the value of `_oldDiscount` is zero,
    ///      and thus `_newDiscount > 0`.
    else if (!_isPoolDiscounted) {
      // slither-disable-next-line unused-return
      _pools.add(_pool);

      /// @dev Newly added pool is the only one in the set.
      if (_pools.length() == 1) {
        _currentDiscount.isPoolDiscountSet = true;
      }
    }

    _currentDiscount.poolDiscount[_pool] = _newDiscount;

    emit PoolDiscountSet(_account, _pool, _newDiscount);
  }

  /// @inheritdoc IDiscountRegistry
  function registerPoolFeeFloorExemption(address _account, address _pool, bool _exempt) external onlyOwner {
    if (_account == address(0)) revert AccountIsZero();
    if (_pool == address(0)) revert PoolIsZero();

    poolFeeFloorExempt[_pool][_account] = _exempt;

    emit PoolFeeFloorExemptionSet(_account, _pool, _exempt);
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  function _getDiscount(address _pool, address _account) internal view returns (uint24 _discount) {
    Discount storage _accountDiscount = discounts[_account];
    (bool _isPoolDiscountSet, uint24 _chainDiscount) = (_accountDiscount.isPoolDiscountSet, _accountDiscount.discount);

    if (_isPoolDiscountSet) {
      _discount = _accountDiscount.poolDiscount[_pool];
      if (_discount > 0) return _discount;
    }
    _discount = _chainDiscount;
  }
}
