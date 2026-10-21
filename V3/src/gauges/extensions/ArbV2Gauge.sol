// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IArbSys} from 'V3/interfaces/external/IArbSys.sol';

import {Gauge} from 'V3/gauges/Gauge.sol';
import {V2Gauge} from 'V3/gauges/V2Gauge.sol';

contract ArbV2Gauge is V2Gauge {
  /**
   * @notice Deploys the Arbitrum gauge implementation
   * @param _voter The leaf voter
   * @param _gaugeFactory The gauge factory
   */
  constructor(address _voter, address _gaugeFactory) V2Gauge(_voter, _gaugeFactory) {}

  /// @inheritdoc Gauge
  function _blockNumber() internal view override returns (uint256) {
    return IArbSys(address(0x64)).arbBlockNumber();
  }
}
