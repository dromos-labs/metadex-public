// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IArbSys} from 'V3/interfaces/external/IArbSys.sol';

import {DynamicSwapFeeHook} from 'V3/hooks/dynamic/DynamicSwapFeeHook.sol';

contract ArbDynamicSwapFeeHook is DynamicSwapFeeHook {
  /**
   * @notice Deploys the Arbitrum dynamic swap fee hook
   * @param _factory The CL factory
   * @param _defaultScalingFactor The initial default scaling factor
   * @param _defaultFeeCap The initial default fee cap
   * @param _pools Pools to initialize
   * @param _fees Base fees for the pools
   * @param _recordCallGasLimit A gas limit for {ICLPoolTape.record} call
   */
  constructor(
    address _factory,
    uint256 _defaultScalingFactor,
    uint256 _defaultFeeCap,
    address[] memory _pools,
    uint24[] memory _fees,
    uint32 _recordCallGasLimit
  ) DynamicSwapFeeHook(_factory, _defaultScalingFactor, _defaultFeeCap, _pools, _fees, _recordCallGasLimit) {}

  /// @inheritdoc DynamicSwapFeeHook
  function _blockNumber() internal view override returns (uint256) {
    return IArbSys(address(0x64)).arbBlockNumber();
  }
}
