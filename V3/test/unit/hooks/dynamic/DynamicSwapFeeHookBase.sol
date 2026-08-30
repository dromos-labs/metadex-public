// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IDiscountRegistry} from 'V3/interfaces/fees/IDiscountRegistry.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';
import {IDynamicSwapFeeHook, ISwapHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';
import {ICLPoolConstants} from 'V3/interfaces/pools/ICLPoolConstants.sol';
import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolState} from 'V3/interfaces/pools/ICLPoolState.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

import {ICLFactory} from 'V3/interfaces/factories/ICLFactory.sol';

import {DynamicSwapFeeHook} from 'V3/hooks/dynamic/DynamicSwapFeeHook.sol';

import {MockDynamicSwapFeeHook} from 'V3-test/mocks/MockDynamicSwapFeeHook.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {StdStorage, stdStorage} from 'forge-std/Test.sol';

contract UnitDynamicSwapFeeHookBase is TestHelpers {
  using stdStorage for StdStorage;

  uint256 internal constant _DEFAULT_SCALING_FACTOR = 100 * 1e6;
  uint256 internal constant _DEFAULT_FEE_CAP = 20_000;

  address public pool = makeAddr('dynamicSwapFeePool');
  address public caller = makeAddr('dynamicSwapFeeCaller');

  address public discountRegistry = makeAddr('dynamicSwapFeeHookDiscountRegistry');
  address public clPoolTape = makeAddr('dynamicSwapFeeHookCLPoolTape');
  address public clFactory = makeAddr('dynamicSwapFeeHookCLFactory');
  address public mevTaxModule = makeAddr('dynamicSwapFeeHookMevTaxModule');

  DynamicSwapFeeHook public dynamicSwapFeeHook;
  MockDynamicSwapFeeHook public mockDynamicSwapFeeHook;

  address public pool1 = makeAddr('dynamicSwapFeeHookPool1');
  address public pool2 = makeAddr('dynamicSwapFeeHookPool2');
  address public pool3 = makeAddr('dynamicSwapFeeHookPool3');

  address[] internal _pools;
  uint24[] internal _fees;

  function setUp() public virtual {
    dynamicSwapFeeHook = new DynamicSwapFeeHook({
      _factory: clFactory,
      _defaultScalingFactor: _DEFAULT_SCALING_FACTOR,
      _defaultFeeCap: _DEFAULT_FEE_CAP,
      _pools: _pools,
      _fees: _fees
    });

    mockDynamicSwapFeeHook = new MockDynamicSwapFeeHook({
      _factory: clFactory,
      _defaultScalingFactor: _DEFAULT_SCALING_FACTOR,
      _defaultFeeCap: _DEFAULT_FEE_CAP,
      _pools: _pools,
      _fees: _fees
    });

    vm.label({account: address(dynamicSwapFeeHook), newLabel: 'Dynamic Swap Fee Hook'});
    vm.label({account: address(mockDynamicSwapFeeHook), newLabel: 'Mock Dynamic Swap Fee Hook'});
  }

  /*////////////////////////////////////////////////////////////
                              MOCK HELPERS
  ////////////////////////////////////////////////////////////*/

  function _mockAndExpectIsPool(address _pool, bool _isPool) internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.isPool.selector, _pool);

    vm.mockCall(clFactory, 0, _data, abi.encode(_isPool));
    vm.expectCall(clFactory, _data);
  }

  function _mockAndExpectTickSpacingToFee(int24 _tickSpacing, uint24 _fee) internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.tickSpacingToFee.selector, _tickSpacing);

    vm.mockCall(clFactory, 0, _data, abi.encode(_fee));
    vm.expectCall(clFactory, 0, _data);
  }

  function _mockAndExpectSwapFeeManager(address _caller) internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.swapFeeManager.selector);

    vm.mockCall(clFactory, 0, _data, abi.encode(_caller));
    vm.expectCall(clFactory, _data);
  }

  function _mockAndExpectDiscountRegistry() internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.discountRegistry.selector);

    vm.mockCall(clFactory, 0, _data, abi.encode(discountRegistry));
    vm.expectCall(clFactory, _data);
  }

  function _mockAndExpectGetDiscount(address _pool, address _addr, uint24 _fee) internal {
    bytes memory _data = abi.encodeWithSelector(IDiscountRegistry.getDiscount.selector, _pool, _addr);

    vm.mockCall(address(discountRegistry), 0, _data, abi.encode(_fee));
    vm.expectCall(address(discountRegistry), _data);
  }

  function _mockAndExpectCLPoolTape() internal {
    bytes memory _data = abi.encodeWithSelector(ICLFactory.clPoolTape.selector);

    vm.mockCall(clFactory, 0, _data, abi.encode(clPoolTape));
    vm.expectCall(clFactory, _data);
  }

  function _mockAndExpectRecord(address _pool, ICLPoolTape.CLPoolTapeData memory _tapeData) internal {
    bytes memory _data = abi.encodeWithSelector(ICLPoolTape.record.selector, _pool, _tapeData);

    vm.mockCall(address(clPoolTape), 0, _data, abi.encode(false));
    vm.expectCall(address(clPoolTape), _data);
  }

  function _mockAndExpectTickSpacing(address _pool, int24 _tickSpacing) internal {
    bytes memory _data = abi.encodeWithSelector(ICLPoolConstants.tickSpacing.selector);

    vm.mockCall(_pool, 0, _data, abi.encode(_tickSpacing));
    vm.expectCall(_pool, _data);
  }

  function _mockAndExpectSlot0(address _pool, int24 _tick, uint16 _observationCardinality) internal {
    bytes memory _data = abi.encodeCall(ICLPoolState.slot0, ());
    _mockAndExpect(_pool, _data, abi.encode(uint160(0), _tick, uint16(0), _observationCardinality, uint16(0), true));
  }

  function _mockAndExpectObservations(
    address _pool,
    uint256 _index,
    uint32 _oldestObservationTimestamp,
    bool _initialized
  ) internal {
    bytes memory _data = abi.encodeCall(ICLPoolState.observations, (_index));
    _mockAndExpect(_pool, _data, abi.encode(_oldestObservationTimestamp, int56(0), uint160(0), _initialized));
  }

  function _mockAndExpectObserve(address _hook, address _pool, int24 _tick0, int24 _tick1) internal {
    uint160[] memory _skipped;
    int56[] memory _tickCumulatives = new int56[](2);
    _tickCumulatives[0] = _tick0;
    _tickCumulatives[1] = _tick1;

    uint32[] memory _secondsAgos = new uint32[](2);
    _secondsAgos[0] = IDynamicSwapFeeHook(_hook).secondsAgo();

    bytes memory _data = abi.encodeCall(ICLPoolDerivedState.observe, (_secondsAgos));
    _mockAndExpect(_pool, _data, abi.encode(_tickCumulatives, _skipped));
  }

  function _mockAndExpectGetMevTax(uint24 _mevFee, bool _toxic) internal {
    bytes memory _data = abi.encodeCall(IMevTaxModule.getMevTax, ());
    _mockAndExpect(mevTaxModule, _data, abi.encode(_mevFee, _toxic));
  }

  /*////////////////////////////////////////////////////////////
                              STORAGE HELPERS
  ////////////////////////////////////////////////////////////*/

  function _setBaseFee(address _hook, address _pool, uint24 _fee) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.dynamicFeeConfig.selector).enable_packed_slots().with_key(_pool)
      .depth(0).checked_write(_fee);
  }

  function _setFeeCap(address _hook, address _pool, uint24 _feeCap) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.dynamicFeeConfig.selector).enable_packed_slots().with_key(_pool)
      .depth(1).checked_write(_feeCap);
  }

  function _setScalingFactor(address _hook, address _pool, uint64 _scalingFactor) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.dynamicFeeConfig.selector).enable_packed_slots().with_key(_pool)
      .depth(2).checked_write(_scalingFactor);
  }

  function _setInitialFeeEnabled(address _hook, address _pool, bool _enabled) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.dynamicFeeConfig.selector).enable_packed_slots().with_key(_pool)
      .depth(3).checked_write(_enabled);
  }

  function _setInitialFee(address _hook, address _pool, uint24 _fee) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.dynamicFeeConfig.selector).enable_packed_slots().with_key(_pool)
      .depth(4).checked_write(_fee);
  }

  function _setBlockFee(address _hook, address _pool, uint256 _blockNumber, uint256 _fee) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.blockFee.selector).with_key(_pool).with_key(_blockNumber)
      .checked_write(_fee);
  }

  function _setMevTaxModule(address _hook) internal {
    stdstore.target(_hook).sig(IDynamicSwapFeeHook.mevTaxModule.selector).checked_write(mevTaxModule);
  }
}
