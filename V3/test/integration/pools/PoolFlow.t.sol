// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Pool} from 'V3/pools/Pool.sol';

import {PoolsFixture} from 'V3-test/integration/PoolsFixture.sol';

/// @notice Example integration test for the pool flows.
/// TODO: Replace during integration tests implementation
contract IntegrationPoolFlow is PoolsFixture {
  function test_SetCustomFeeAppliesToPool() public {
    vm.prank(_users.alice);
    address _poolAddress = volatilePoolFactory.createPool(address(token0), address(token1));

    // default fee applies before any override
    assertEq(volatilePoolFactory.getBaseFee(_poolAddress, address(0), 0, 0, 0, 0), 30);

    vm.prank(_users.feeManager);
    volatileCustomFeeModule.setCustomFee(_poolAddress, 100);

    assertEq(volatilePoolFactory.getBaseFee(_poolAddress, address(0), 0, 0, 0, 0), 100);
  }
}
