// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {UnitPriorityFeeMevTaxModule} from 'V3-test/unit/fees/PriorityFeeMevTaxModule/PriorityFeeMevTaxModule.t.sol';
import {PriorityFeeMevTaxModule} from 'V3/fees/PriorityFeeMevTaxModule.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';

contract UnitPriorityFeeMevTaxModuleGetMevTax is UnitPriorityFeeMevTaxModule {
  using stdStorage for StdStorage;

  /// @dev Max gas price accepted by the vm.txGasPrice cheatcode
  uint256 internal constant _MAX_GAS_PRICE = type(uint64).max;

  function test_WhenTheGasPriceIsLteTheBaseFee(
    uint256 _multiplier,
    uint256 _minThreshold,
    uint256 _baseFeeFactor,
    uint256 _baseFee,
    uint256 _gasPrice
  ) external {
    _multiplier = bound(_multiplier, 0, type(uint64).max);
    _minThreshold = bound(_minThreshold, 0, type(uint96).max);
    _baseFeeFactor = bound(_baseFeeFactor, 0, type(uint96).max);
    _baseFee = bound(_baseFee, 0, _MAX_GAS_PRICE);
    _gasPrice = bound(_gasPrice, 0, _baseFee);

    _setPriorityFeeMultiplier(_multiplier);
    _setMinThreshold(_minThreshold);
    _setBaseFeeFactor(_baseFeeFactor);

    vm.fee(_baseFee);
    vm.txGasPrice(_gasPrice);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return zero tax and false toxic
    assertEq(_mevTax, 0);
    assertFalse(_toxic);
  }

  function test_WhenThePriorityFeeIsLteTheThreshold(
    uint256 _minThreshold,
    uint256 _baseFeeFactor,
    uint256 _baseFee,
    uint256 _priorityFee
  ) external {
    _minThreshold = bound(_minThreshold, 1, type(uint96).max);
    _baseFee = bound(_baseFee, 0, _MAX_GAS_PRICE - 1);
    _baseFeeFactor = bound(_baseFeeFactor, 0, type(uint96).max);

    _setMinThreshold(_minThreshold);
    _setBaseFeeFactor(_baseFeeFactor);

    // max between the congestion threshold and the min threshold
    uint256 _threshold = Math.max(_baseFeeFactor * _baseFee, _minThreshold);

    // keeps the priority fee positive but at or below the threshold, and the gas price below the max value
    _priorityFee = bound(_priorityFee, 1, Math.min(_threshold, _MAX_GAS_PRICE - _baseFee));

    vm.fee(_baseFee);
    vm.txGasPrice(_baseFee + _priorityFee);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return zero tax and false toxic
    assertEq(_mevTax, 0);
    assertFalse(_toxic);
  }

  modifier whenThePriorityFeeIsGtTheThreshold() {
    _;
  }

  function test_WhenTheComputedTaxDoesNotExceedTheCap(
    uint256 _multiplier,
    uint256 _minThreshold,
    uint256 _baseFeeFactor,
    uint256 _baseFee,
    uint256 _excessPriorityFee
  ) external whenThePriorityFeeIsGtTheThreshold {
    // largest scaled tax that still rounds up to at most the cap
    uint256 _maxScaledTax = uint256(_mevTaxModule.MEV_TAX_CAP()) * _mevTaxModule.PRECISION();
    _multiplier = bound(_multiplier, 0, _maxScaledTax);
    _baseFee = bound(_baseFee, 0, _MAX_GAS_PRICE - 2);
    uint256 _maxPriorityFee = _MAX_GAS_PRICE - _baseFee;

    uint256 _maxThreshold = _maxPriorityFee - 1;
    _minThreshold = bound(_minThreshold, 0, _maxThreshold);
    uint256 _maxBaseFeeFactor = _baseFee == 0 ? type(uint96).max : Math.min(_maxThreshold / _baseFee, type(uint96).max);
    _baseFeeFactor = bound(_baseFeeFactor, 0, _maxBaseFeeFactor);
    uint256 _threshold = Math.max(_baseFeeFactor * _baseFee, _minThreshold);

    _setMinThreshold(_minThreshold);
    _setBaseFeeFactor(_baseFeeFactor);
    _setPriorityFeeMultiplier(_multiplier);

    // max value for `_priorityFee - _threshold` before the tax cap is reached
    uint256 _maxExcessPriorityFee = _maxScaledTax / Math.max(_multiplier, 1);
    _excessPriorityFee = bound(_excessPriorityFee, 1, Math.min(_maxExcessPriorityFee, _maxPriorityFee - _threshold));

    vm.fee(_baseFee);
    vm.txGasPrice(_baseFee + _threshold + _excessPriorityFee);

    uint256 _expectedMevTax = Math.ceilDiv(_excessPriorityFee * _multiplier, _mevTaxModule.PRECISION());

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the mev tax
    assertEq(_mevTax, _expectedMevTax);
    // it should return true toxic
    assertTrue(_toxic);
  }

  function test_WhenTheComputedTaxExceedsTheCap(
    uint256 _multiplier,
    uint256 _minThreshold,
    uint256 _baseFeeFactor,
    uint256 _baseFee,
    uint256 _excessPriorityFee
  ) external whenThePriorityFeeIsGtTheThreshold {
    uint256 _minScaledTaxToClamp =
      uint256(_mevTaxModule.MEV_TAX_CAP()) * _mevTaxModule.PRECISION() + 1;
    _multiplier = bound(_multiplier, 1, type(uint64).max);
    uint256 _minExcessPriorityFee = Math.ceilDiv(_minScaledTaxToClamp, _multiplier);

    _baseFee = bound(_baseFee, 0, _MAX_GAS_PRICE - _minExcessPriorityFee);
    uint256 _maxPriorityFee = _MAX_GAS_PRICE - _baseFee;

    uint256 _maxThreshold = _maxPriorityFee - _minExcessPriorityFee;
    _minThreshold = bound(_minThreshold, 0, _maxThreshold);
    uint256 _maxBaseFeeFactor = _baseFee == 0 ? type(uint96).max : Math.min(_maxThreshold / _baseFee, type(uint96).max);
    _baseFeeFactor = bound(_baseFeeFactor, 0, _maxBaseFeeFactor);
    uint256 _threshold = Math.max(_baseFeeFactor * _baseFee, _minThreshold);
    _excessPriorityFee = bound(_excessPriorityFee, _minExcessPriorityFee, _maxPriorityFee - _threshold);

    _setMinThreshold(_minThreshold);
    _setBaseFeeFactor(_baseFeeFactor);
    _setPriorityFeeMultiplier(_multiplier);

    vm.fee(_baseFee);
    vm.txGasPrice(_baseFee + _threshold + _excessPriorityFee);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the cap and true toxic
    assertEq(_mevTax, _mevTaxModule.MEV_TAX_CAP());
    assertTrue(_toxic);
  }

  function test_WhenTestingAConcreteExample() external whenThePriorityFeeIsGtTheThreshold {
    // block.basefee = 0.05 gwei
    vm.fee(5e7);

    // _BASE_FEE_FACTOR (5) * 0.05 gwei = 0.25 gwei, below _MIN_THRESHOLD = 0.3 gwei
    // so _threshold = 0.3 gwei

    vm.txGasPrice(5e7 + 4e8);
    // _priorityFee = 0.4 gwei

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the expected tax and true toxic
    // _mevTax = (1e8 * 25000000(_PRIORITY_FEE_MULTIPLIER)) / 1e12 = 2500
    assertEq(_mevTax, 2500);
    assertTrue(_toxic);
  }

  function test_WhenTestingARoundedUpExample() external whenThePriorityFeeIsGtTheThreshold {
    // block.basefee = 0.05 gwei keeps the congestion term below the 0.3 gwei floor
    vm.fee(5e7);

    // a single wei of excess above the 0.3 gwei threshold
    vm.txGasPrice(5e7 + 3e8 + 1);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the rounded up tax and true toxic
    // 1 wei of excess at 25000000 / 1e12 = 0.000025 pips, rounded up to 1
    assertEq(_mevTax, 1);
    assertTrue(_toxic);
  }

  function test_WhenTestingAThresholdAboveTheMinimumThreshold() external whenThePriorityFeeIsGtTheThreshold {
    // _BASE_FEE_FACTOR = 5
    // _MIN_THRESHOLD = 3e8

    // block.basefee = 0.1 gwei
    // threshold = to 5 * 0.1 = 0.5 gwei which is higher than _MIN_THRESHOLD
    vm.fee(1e8);

    // a searcher tip of 0.7 gwei sits 0.2 gwei above the threshold
    vm.txGasPrice(1e8 + 7e8);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the expected tax and true toxic
    // 2e8 wei  *  25000000 / 1e12 = 5000 pips
    assertEq(_mevTax, 5000);
    assertTrue(_toxic);
  }

  function test_WhenTestingACappedExample() external whenThePriorityFeeIsGtTheThreshold {
    // block.basefee = 0.05 gwei keeps the threshold below the 0.3 gwei floor (_MIN_THRESHOLD)
    vm.fee(5e7);

    // one wei past the 4 gwei of excess where the tax reaches the cap
    vm.txGasPrice(5e7 + 3e8 + 4e9 + 1);

    (uint24 _mevTax, bool _toxic) = _mevTaxModule.getMevTax();

    // it should return the cap and true toxic
    // (4e9 + 1) wei * 25000000 / 1e12 rounds up to 100001 pips and caps to MEV_TAX_CAP
    assertEq(_mevTax, 100_000);
    assertTrue(_toxic);
  }

  /*////////////////////////////////////////////////////////////
                              HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setPriorityFeeMultiplier(uint256 _multiplier) internal {
    stdstore.enable_packed_slots().target(address(_mevTaxModule)).sig(IMevTaxModule.priorityFeeMultiplier.selector)
      .checked_write(_multiplier);
  }

  function _setMinThreshold(uint256 _minThreshold) internal {
    stdstore.enable_packed_slots().target(address(_mevTaxModule)).sig(IMevTaxModule.minThreshold.selector)
      .checked_write(_minThreshold);
  }

  function _setBaseFeeFactor(uint256 _baseFeeFactor) internal {
    stdstore.enable_packed_slots().target(address(_mevTaxModule)).sig(IMevTaxModule.baseFeeFactor.selector)
      .checked_write(_baseFeeFactor);
  }
}
