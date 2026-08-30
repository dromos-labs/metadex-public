// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

interface IDiscountRegistry {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Stores discount data for a single account.
  /// @dev The first three fields are packed into a single storage slot.
  /// @param isPoolDiscountSet Specifies if the per-pool override discount is set for the account.
  /// @param discount The value of a chain-wide discount.
  /// @param poolDiscount Mapping from pool address to per‑pool discount in pips.
  struct Discount {
    bool isPoolDiscountSet;
    uint24 discount;

    /// @param _pool An address of the discounted pool.
    /// @param _discount A discount value for a pool.
    mapping(address _pool => uint24 _discount) poolDiscount;
  }

  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when a chain‑wide discount is registered or cleared.
  /// @param _account The address whose discount changed.
  /// @param _discount New discount value.
  event DiscountSet(address indexed _account, uint24 _discount);

  /// @notice Emitted when a per‑pool discount is registered, updated, or cleared.
  /// @param _account The address that receives the discount.
  /// @param _pool The pool for which the discount applies.
  /// @param _discount New discount value.
  event PoolDiscountSet(address indexed _account, address indexed _pool, uint24 _discount);

  /// @notice Emitted when a fee-floor exemption is registered or cleared.
  /// @param _account The address whose exemption changed.
  /// @param _pool The pool for which the exemption applies.
  /// @param _exempt New exemption flag.
  event PoolFeeFloorExemptionSet(address indexed _account, address indexed _pool, bool _exempt);

  /*////////////////////////////////////////////////////////////
                              ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when pool address argument is `address(0)`.
  error PoolIsZero();

  /// @notice Thrown when account address argument is `address(0)`.
  error AccountIsZero();

  /// @notice Thrown when new discount is greater than {MAX_DISCOUNT}.
  error NewDiscountGtMax();

  /// @notice Thrown when new discount is equal to already set discount.
  error OldDiscountEqNewDiscount();

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Maximum allowed discount, expressed in pips.
  /// @return _maxDiscount The discount cap.
  function MAX_DISCOUNT() external pure returns (uint24 _maxDiscount);

  /// @notice Returns discount data for a given `_account`.
  /// @param _account An address of a discounted user.
  /// @return _isPoolDiscountSet Specifies if the per-pool override discount is set for the account.
  /// @return _discount The value of a chain-wide discount.
  function discounts(address _account) external view returns (bool _isPoolDiscountSet, uint24 _discount);

  /*////////////////////////////////////////////////////////////
                              PURE & VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the applicable discount for a given pool and caller or tx.origin.
  /// @dev The lookup follows this priority order:
  ///      1. Per‑pool discount of `_caller`.
  ///      2. Chain‑wide discount of `_caller`.
  ///      3. Per‑pool discount of `tx.origin`.
  ///      4. Chain‑wide discount of `tx.origin`.
  ///      If no discount exists, returns 0.
  ///      The discount value is expressed in pips (1_000_000 = 100%).
  /// @param _pool The pool address for which the discount is being queried.
  /// @param _caller The address of the swap initiator (`msg.sender` at the pool level).
  /// @return _feeDiscount The discount amount in pips (0 if none).
  function getDiscount(address _pool, address _caller) external view returns (uint24 _feeDiscount);

  /// @notice Returns all pools that are discounted for an `_account`.
  /// @param _account An address for which an array of discounted pools will be returned.
  /// @param _start An inclusive start index for array copying.
  /// @param _end An exclusive end index for array copying.
  /// @return _pools An array of pools that are discounted for an `_account`.
  function getDiscountedPools(
    address _account,
    uint256 _start,
    uint256 _end
  ) external view returns (address[] memory _pools);

  /// @notice Returns whether `_caller` is exempt from the fee floor on `_pool`.
  /// @param _pool The pool for which the exemption is queried.
  /// @param _caller The address of the swap initiator (`msg.sender` at the pool level).
  /// @return _exempt True when the pair has a fee-floor exemption.
  function poolFeeFloorExempt(address _pool, address _caller) external view returns (bool _exempt);

  /*////////////////////////////////////////////////////////////
                              WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Registers or clears a chain‑wide discount for an `_account`.
  /// @dev Can only be called by the contract owner (governance).
  /// @param _account The address that will receive the discount.
  /// @param _newDiscount Discount value in pips (0 to clear, >0 to set).
  function registerDiscount(address _account, uint24 _newDiscount) external;

  /// @notice Registers, updates, or clears a per‑pool discount for an `_account`.
  /// @dev Can only be called by the contract owner (governance).
  ///      If `_newDiscount == 0`, the discount is cleared; otherwise, it is set to the given value.
  ///      The discount is capped by {MAX_DISCOUNT}.
  ///      Flips the `Discount.isPoolDiscountSet` flag: set to `true` when the first per‑pool discount is added,
  ///      and back to `false` when the last one is removed.
  /// @param _account The address that will receive the discount.
  /// @param _pool The pool address for which the discount applies.
  /// @param _newDiscount Discount value in pips (0 to clear, >0 to set).
  function registerPoolDiscount(address _account, address _pool, uint24 _newDiscount) external;

  /// @notice Registers or clears a fee-floor exemption for an `_account` on a `_pool`.
  /// @dev Can only be called by the contract owner.
  /// @param _account The address that will receive the exemption.
  /// @param _pool The pool address for which the exemption applies.
  /// @param _exempt True to register the exemption, false to clear it.
  function registerPoolFeeFloorExemption(address _account, address _pool, bool _exempt) external;
}
