// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {GaugeFactory} from 'V3/factories/GaugeFactory.sol';
import {ArbV2Gauge} from 'V3/gauges/extensions/ArbV2Gauge.sol';

contract ArbGaugeFactory is GaugeFactory {
  /**
   * @notice Deploys the Arbitrum gauge factory and its disabled implementation
   * @param _params The constructor wiring
   */
  constructor(InitParams memory _params) GaugeFactory(_params) {}

  /// @inheritdoc GaugeFactory
  function _deployGaugeImplementation() internal override returns (address) {
    return address(new ArbV2Gauge({_voter: LEAF_VOTER, _gaugeFactory: address(this)}));
  }
}
