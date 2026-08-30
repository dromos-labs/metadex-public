// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';

import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';

import {UnitDynamicSwapFeeHookBase} from 'V3-test/unit/hooks/dynamic/DynamicSwapFeeHookBase.sol';

contract UnitDynamicSwapFeeHook_GetFirstSwapFee is UnitDynamicSwapFeeHookBase {
  using FixedPointMathLib for uint256;

  uint256 private constant _INIT_FEE = 500;
  uint256 private constant _DISCOUNT = 500_000;
  uint64 private constant _SCALING_FACTOR = 200 * 1e6;
  uint24 private constant _FEE_CAP = 30_000;
  uint24 private constant _BASE_FEE = 10_000;

  int24 internal constant _MIN_TICK = -887_272;
  int24 internal constant _MAX_TICK = 887_272;

  int24 internal constant _TICK_DIST = 50_000;

  /*////////////////////////////////////////////////////////////
            WHEN BASE FEE IS ZERO_FEE_INDICATOR
  ////////////////////////////////////////////////////////////*/

  function test_WhenBaseFeeIsZERO_FEE_INDICATOR() external {
    _setBaseFee(address(mockDynamicSwapFeeHook), pool, uint24(mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()));

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (0, ZERO_FEE_INDICATOR)
    assertEq(uint256(_feeToUse), 0);
    assertEq(_feeToStore, dynamicSwapFeeHook.ZERO_FEE_INDICATOR());
  }

  /*////////////////////////////////////////////////////////////
            WHEN BASE FEE IS NOT ZERO_FEE_INDICATOR
  ////////////////////////////////////////////////////////////*/

  modifier whenBaseFeeIsNotZeroFeeIndicator() {
    _setBaseFee(address(mockDynamicSwapFeeHook), pool, _BASE_FEE);
    _;
  }

  function test_WhenObserveCallReverts() external whenBaseFeeIsNotZeroFeeIndicator {
    _setBaseFee(address(mockDynamicSwapFeeHook), pool, _BASE_FEE);

    vm.warp(dynamicSwapFeeHook.secondsAgo() * 2);

    _mockAndExpectSlot0(pool, 0, 2);
    _mockAndExpectObservations(pool, 1, dynamicSwapFeeHook.secondsAgo(), true);

    // Bypass discount registry.
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    uint32[] memory _secondsAgos = new uint32[](2);
    _secondsAgos[0] = mockDynamicSwapFeeHook.secondsAgo();

    bytes memory _data = abi.encodeCall(ICLPoolDerivedState.observe, (_secondsAgos));
    vm.mockCallRevert(pool, _data, '');

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (base fee, bas fee)
    assertEq(_feeToUse, _BASE_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  /*////////////////////////////////////////////////////////////
            WHEN INITIAL FEE IS ENABLED
  ////////////////////////////////////////////////////////////*/

  modifier whenInitialFeeIsEnabled() {
    _setInitialFeeEnabled(address(mockDynamicSwapFeeHook), pool, true);
    _;
  }

  function test_WhenInitialFeeOverrideIs0() external whenBaseFeeIsNotZeroFeeIndicator whenInitialFeeIsEnabled {
    _mockAndExpectSlot0(pool, 0, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (base fee, total fee)
    assertEq(uint256(_feeToUse), _BASE_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  function test_WhenInitialFeeOverrideIsZERO_FEE_INDICATOR()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsEnabled
  {
    _setInitialFee(address(mockDynamicSwapFeeHook), pool, uint24(mockDynamicSwapFeeHook.ZERO_FEE_INDICATOR()));

    _mockAndExpectSlot0(pool, 0, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (0, total fee)
    assertEq(uint256(_feeToUse), 0);
    assertEq(_feeToStore, _BASE_FEE);
  }

  function test_WhenInitialFeeOverrideIsNonZero() external whenBaseFeeIsNotZeroFeeIndicator whenInitialFeeIsEnabled {
    _setInitialFee(address(mockDynamicSwapFeeHook), pool, uint24(_INIT_FEE));

    _mockAndExpectSlot0(pool, 0, 0);
    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (initial fee, total fee)
    assertEq(uint256(_feeToUse), _INIT_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  /*////////////////////////////////////////////////////////////
            WHEN INITIAL FEE IS NOT ENABLED
  ////////////////////////////////////////////////////////////*/

  modifier whenInitialFeeIsNotEnabled() {
    _;
  }

  /*////////////////////////////////////////////////////////////
            WHEN SCALING FACTOR IS NOT SET ON THE POOL
  ////////////////////////////////////////////////////////////*/

  modifier whenScalingFactorIsNotSetOnThePool() {
    _;
  }

  /*////////////////////////////////////////////////////////////
            WHEN OBSERVATION CARDINALITY IS INSUFFICIENT
  ////////////////////////////////////////////////////////////*/

  modifier whenObservationCardinalityIsInsufficient() {
    _;
  }

  function test_WhenDiscountIsZero()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsInsufficient
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    _mockAndExpectSlot0(pool, 0, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (baseFee, baseFee)
    assertEq(uint256(_feeToUse), _BASE_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  function test_WhenDiscountIsGtZero()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsInsufficient
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_DISCOUNT));

    _mockAndExpectSlot0(pool, 0, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (discounted base fee, base fee)
    assertEq(uint256(_feeToUse), uint256(_BASE_FEE).mulDivUp((1e6 - _DISCOUNT), 1e6));
    assertEq(_feeToStore, _BASE_FEE);
  }

  /*////////////////////////////////////////////////////////////
            WHEN OBSERVATION CARDINALITY IS SUFFICIENT
  ////////////////////////////////////////////////////////////*/

  modifier whenObservationCardinalityIsSufficient() {
    // now - secondsAgo = secondsAgo
    vm.warp(dynamicSwapFeeHook.secondsAgo() * 2);
    _mockAndExpectSlot0(pool, 0, 2);
    // index is 1 => 0 + 1 % 2 = 1
    _mockAndExpectObservations(pool, 1, dynamicSwapFeeHook.secondsAgo(), true);
    _;
  }

  modifier whenObservationsLatestSlotIsUninitialized() {
    // Bypass discount registry.
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    vm.warp(mockDynamicSwapFeeHook.secondsAgo() * 2);
    _mockAndExpectSlot0(pool, 0, 2);

    // Observation index doesn't matter here, as we're mocking the call.
    // returns (timestamp=0, initialized=false)
    _mockAndExpectObservations(pool, 1, 0, false);
    _;
  }

  function test_WhenLatestObservationTimestampIsLtSecondsAgo()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationsLatestSlotIsUninitialized
  {
    _mockAndExpectObservations(pool, 0, mockDynamicSwapFeeHook.secondsAgo() * 2, true);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should fall back to observations(0) and return base fee
    assertEq(uint256(_feeToUse), _BASE_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  function test_WhenLatestObservationTimestampIsGeqSecondsAgo()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationsLatestSlotIsUninitialized
  {
    _mockAndExpectObservations(pool, 0, mockDynamicSwapFeeHook.secondsAgo(), true);
    _mockAndExpectObserve(address(mockDynamicSwapFeeHook), pool, 0, _TICK_DIST);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee =
      mockDynamicSwapFeeHook.getDynamicFee(pool, mockDynamicSwapFeeHook.defaultScalingFactor());

    // it should fall back to observations(0) and return base fee with dynamic fee
    assertEq(uint256(_feeToUse), _BASE_FEE + _expectedDynamicFee);
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  // -------------------- total fee < fee cap --------------------
  modifier whenTotalFeeIsLtFeeCap() {
    _mockAndExpectObserve(address(mockDynamicSwapFeeHook), pool, 0, _TICK_DIST);
    _;
  }

  function test_WhenDiscountIsZero_()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsLtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee =
      mockDynamicSwapFeeHook.getDynamicFee(pool, mockDynamicSwapFeeHook.defaultScalingFactor());

    // it should return (total fee, total fee)
    assertEq(uint256(_feeToUse), _BASE_FEE + _expectedDynamicFee);
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  function test_WhenDiscountIsGtZero_()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsLtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_DISCOUNT));

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee =
      mockDynamicSwapFeeHook.getDynamicFee(pool, mockDynamicSwapFeeHook.defaultScalingFactor());

    // it should return (discounted total fee, total fee)
    assertEq(uint256(_feeToUse), (_BASE_FEE + _expectedDynamicFee).mulDivUp(1e6 - _DISCOUNT, 1e6));
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  // -------------------- total fee >= fee cap --------------------
  modifier whenTotalFeeIsGtFeeCap() {
    _mockAndExpectObserve(address(mockDynamicSwapFeeHook), pool, _MIN_TICK, _MAX_TICK);
    _;
  }

  function test_WhenDiscountIsZero__()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsGtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (fee cap, fee cap)
    assertEq(uint256(_feeToUse), mockDynamicSwapFeeHook.defaultFeeCap());
    assertEq(_feeToStore, mockDynamicSwapFeeHook.defaultFeeCap());
  }

  function test_WhenDiscountIsGtZero__()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsNotSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsGtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_DISCOUNT));

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (discounted fee cap, fee cap)
    assertEq(uint256(_feeToUse), mockDynamicSwapFeeHook.defaultFeeCap().mulDivUp(1e6 - _DISCOUNT, 1e6));
    assertEq(_feeToStore, mockDynamicSwapFeeHook.defaultFeeCap());
  }

  /*////////////////////////////////////////////////////////////
            WHEN SCALING FACTOR IS SET ON THE POOL
  ////////////////////////////////////////////////////////////*/

  modifier whenScalingFactorIsSetOnThePool() {
    _setFeeCap(address(mockDynamicSwapFeeHook), pool, _FEE_CAP);
    _setScalingFactor(address(mockDynamicSwapFeeHook), pool, _SCALING_FACTOR);
    _;
  }

  modifier whenObservationCardinalityIsSufficient_() {
    // This modifier is only for bulloak check to pass.
    _;
  }

  modifier whenObservationsLatestSlotIsUninitialized_() {
    // This modifier is only for bulloak check to pass.
    _;
  }

  function test_WhenLatestObservationTimestampIsLtSecondsAgo_()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationsLatestSlotIsUninitialized
  {
    _mockAndExpectObservations(pool, 0, mockDynamicSwapFeeHook.secondsAgo() * 2, true);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should fall back to observations(0) and return base fee
    assertEq(uint256(_feeToUse), _BASE_FEE);
    assertEq(_feeToStore, _BASE_FEE);
  }

  function test_WhenLatestObservationTimestampIsGeqSecondsAgo_()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationCardinalityIsSufficient_
    whenObservationsLatestSlotIsUninitialized
  {
    _mockAndExpectObservations(pool, 0, mockDynamicSwapFeeHook.secondsAgo(), true);
    _mockAndExpectObserve(address(mockDynamicSwapFeeHook), pool, 0, _TICK_DIST);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee = mockDynamicSwapFeeHook.getDynamicFee(pool, _SCALING_FACTOR);

    // it should fall back to observations(0) and return base fee with dynamic fee
    assertEq(uint256(_feeToUse), _BASE_FEE + _expectedDynamicFee);
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  // -------------------- total fee < fee cap_ --------------------
  modifier whenTotalFeeIsLtFeeCap_() {
    // This modifier is only for bulloak check to pass.
    _;
  }

  function test_WhenDiscountIsZero___()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsLtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee = mockDynamicSwapFeeHook.getDynamicFee(pool, _SCALING_FACTOR);

    // it should return (total fee, total fee)
    assertEq(uint256(_feeToUse), _BASE_FEE + _expectedDynamicFee);
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  function test_WhenDiscountIsGtZero___()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsLtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_DISCOUNT));

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    uint256 _expectedDynamicFee = mockDynamicSwapFeeHook.getDynamicFee(pool, _SCALING_FACTOR);

    // it should return (discounted total fee, total fee)
    assertEq(uint256(_feeToUse), uint256(_BASE_FEE + _expectedDynamicFee).mulDivUp(1e6 - _DISCOUNT, 1e6));
    assertEq(_feeToStore, _BASE_FEE + _expectedDynamicFee);
  }

  // -------------------- total fee >= fee cap_ --------------------
  modifier whenTotalFeeIsGtFeeCap_() {
    // This modifier is only for bulloak check to pass.
    _;
  }

  function test_WhenDiscountIsZero____()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsGtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, 0);

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (fee cap, fee cap)
    assertEq(uint256(_feeToUse), _FEE_CAP);
    assertEq(uint256(_feeToStore), _FEE_CAP);
  }

  function test_WhenDiscountIsGtZero____()
    external
    whenBaseFeeIsNotZeroFeeIndicator
    whenInitialFeeIsNotEnabled
    whenScalingFactorIsSetOnThePool
    whenObservationCardinalityIsSufficient
    whenTotalFeeIsGtFeeCap
  {
    _mockAndExpectDiscountRegistry();
    _mockAndExpectGetDiscount(pool, caller, uint24(_DISCOUNT));

    (uint24 _feeToUse, uint256 _feeToStore) = mockDynamicSwapFeeHook.getFirstSwapFee(pool, caller);

    // it should return (discounted fee cap, fee cap)
    assertEq(uint256(_feeToUse), uint256(_FEE_CAP).mulDivUp(1e6 - _DISCOUNT, 1e6));
    assertEq(uint256(_feeToStore), _FEE_CAP);
  }
}
