// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {LibTransient} from '@solady/utils/LibTransient.sol';

import {TransientMevTaxLib} from 'V3/hooks/dynamic/libraries/TransientMevTaxLib.sol';

import {DynamicSwapFeeHook} from 'V3/hooks/dynamic/DynamicSwapFeeHook.sol';

contract MockDynamicSwapFeeHook is DynamicSwapFeeHook {
  using TransientMevTaxLib for mapping(address => LibTransient.TBytes32);
  using LibTransient for LibTransient.TUint256;

  constructor(
    address _factory,
    uint256 _defaultScalingFactor,
    uint256 _defaultFeeCap,
    address[] memory _pools,
    uint24[] memory _fees
  ) DynamicSwapFeeHook(_factory, _defaultScalingFactor, _defaultFeeCap, _pools, _fees) {}

  function getFirstSwapFee(
    address _pool,
    address _caller
  ) external view returns (uint24 _feeToUse, uint256 _feeToStore) {
    (_feeToUse, _feeToStore) = _getFirstSwapFee(_pool, _caller);
  }

  function getFee(address _pool, address _caller) external view returns (uint24 _feeToUse, uint256 _feeToStore) {
    (_feeToUse, _feeToStore) = _getFee(_pool, _caller);
  }

  function getDynamicFee(address _pool, uint256 _scalingFactor) external view returns (uint256 _dynamicFee) {
    _dynamicFee = _getDynamicFee(_pool, _scalingFactor);
  }

  function tstoreFirstTxInitialFee(address _pool, uint256 _initialFee) external {
    _transientFirstTxInitialFee[_pool].set(_initialFee);
  }

  function tloadFirstTxInitialFee(address _pool) external view returns (uint256 _initialFee) {
    _initialFee = _transientFirstTxInitialFee[_pool].get();
  }

  function tstoreMevData(address _pool, uint24 _dynamicFee, bool _toxic) external {
    _transientMevData.write(_pool, _dynamicFee, _toxic);
  }

  function tloadMevData(address _pool) external view returns (uint24 _dynamicFee, bool _toxic) {
    (_dynamicFee, _toxic) = _transientMevData.read(_pool);
  }
}
