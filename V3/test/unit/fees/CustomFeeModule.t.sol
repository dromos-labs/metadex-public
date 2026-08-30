// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {StdStorage} from 'forge-std/StdStorage.sol';
import {stdStorage} from 'forge-std/Test.sol';

import {CustomFeeModule} from 'V3/fees/CustomFeeModule.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {ICustomFeeModule} from 'V3/interfaces/fees/ICustomFeeModule.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitCustomFeeModule is TestHelpers {
  using stdStorage for StdStorage;

  uint256 internal constant MAX_FEE = 300; // 3%
  uint256 internal constant ZERO_FEE_INDICATOR = 420;

  address internal feeManager = makeAddr('feeManager');
  address internal factory = _mockContract('factory');
  address internal pool = makeAddr('pool');

  CustomFeeModule internal module;

  function setUp() public {
    vm.mockCall(factory, abi.encodeWithSelector(IPoolFactory.feeManager.selector), abi.encode(feeManager));
    module = new CustomFeeModule({_factory: factory});
  }

  function test_ConstructorGivenAFreshlyDeployedModule() external view {
    // it should set factory to the provided factory address
    assertEq(address(module.factory()), factory);
  }

  function test_SetCustomFeeWhenTheCallerIsNotTheFeeManager(address _caller, uint24 _fee) external {
    vm.assume(_caller != feeManager);
    // it should revert with NotFeeManager
    vm.prank(_caller);
    vm.expectRevert(ICustomFeeModule.NotFeeManager.selector);
    module.setCustomFee(pool, _fee);
  }

  modifier whenTheCallerIsTheFeeManager() {
    vm.startPrank(feeManager);
    _;
    vm.stopPrank();
  }

  function test_SetCustomFeeWhenTheFeeExceedsTheMaxFeeAndIsNotTheZeroIndicator(uint24 _fee)
    external
    whenTheCallerIsTheFeeManager
  {
    _fee = uint24(bound(uint256(_fee), MAX_FEE + 1, type(uint24).max));
    vm.assume(_fee != ZERO_FEE_INDICATOR);
    // it should revert with FeeTooHigh
    vm.expectRevert(ICustomFeeModule.FeeTooHigh.selector);
    module.setCustomFee(pool, _fee);
  }

  modifier whenTheFeeIsWithinTheCapOrTheZeroIndicator() {
    _;
  }

  function test_SetCustomFeeWhenThePoolIsNotARegisteredPool(uint24 _fee)
    external
    whenTheCallerIsTheFeeManager
    whenTheFeeIsWithinTheCapOrTheZeroIndicator
  {
    _fee = uint24(bound(uint256(_fee), 0, MAX_FEE));
    vm.mockCall(factory, abi.encodeCall(IPoolFactory.isPool, (pool)), abi.encode(false));
    // it should revert with InvalidPool
    vm.expectRevert(ICustomFeeModule.InvalidPool.selector);
    module.setCustomFee(pool, _fee);
  }

  function test_SetCustomFeeWhenThePoolIsARegisteredPool(uint24 _fee)
    external
    whenTheCallerIsTheFeeManager
    whenTheFeeIsWithinTheCapOrTheZeroIndicator
  {
    _fee = uint24(bound(uint256(_fee), 0, MAX_FEE));
    vm.mockCall(factory, abi.encodeCall(IPoolFactory.isPool, (pool)), abi.encode(true));

    // it should emit SetCustomFee
    vm.expectEmit(address(module));
    emit ICustomFeeModule.SetCustomFee(pool, _fee);
    module.setCustomFee(pool, _fee);

    // it should set the custom fee
    assertEq(module.customFee(pool), _fee);
  }

  function test_GetFeeWhenAZeroFeeHasBeenExplicitlySet() external {
    stdstore.target(address(module)).sig(ICustomFeeModule.customFee.selector).with_key(pool)
      .checked_write(ZERO_FEE_INDICATOR);

    // it should return zero
    assertEq(module.getFee(pool, address(0), 0, 0, 0, 0), 0);
  }

  function test_GetFeeWhenAPositiveFeeHasBeenSet(uint24 _fee) external {
    _fee = uint24(bound(uint256(_fee), 1, MAX_FEE));
    stdstore.target(address(module)).sig(ICustomFeeModule.customFee.selector).with_key(pool).checked_write(_fee);

    // it should return the custom fee
    assertEq(module.getFee(pool, address(0), 0, 0, 0, 0), _fee);
  }

  function test_GetFeeWhenNoFeeHasBeenSet() external {
    // it should revert with NoCustomFee
    vm.expectRevert(ICustomFeeModule.NoCustomFee.selector);
    module.getFee(pool, address(0), 0, 0, 0, 0);
  }
}
