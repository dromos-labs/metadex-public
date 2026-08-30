// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {DeployPoolsFixture} from 'V3-script/DeployPoolsFixture.s.sol';

/**
 * @title DeployPools
 * @notice Optimism deployment parameters for the pool deployment unit
 */
contract DeployPools is DeployPoolsFixture {
  /// @notice Sets the Optimism deployment parameters
  function setUp() public override {
    _params = DeploymentParameters({
      chainId: 10,
      // TODO Replace zero placeholders with operational addresses and a nonzero cadence before deploying
      poolAdmin: address(0),
      pauser: address(0),
      feeManager: address(0),
      poolTapeManager: address(0),
      discountRegistryManager: address(0),
      poolTapeOwner: address(0),
      discountRegistryOwner: address(0),
      targetFactoryAdmin: address(0),
      defaultCadenceInterval: 0,
      poolTapeGasLimit: 0,
      feeModuleGasLimit: 0,
      outputFilename: 'pools-optimism.json'
    });
  }
}
