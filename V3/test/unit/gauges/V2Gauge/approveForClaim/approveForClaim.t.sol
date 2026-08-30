// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeApproveForClaim is UnitV2Gauge {
  function test_WhenTheOperatorIsTheZeroAddress(address _caller, bool _approved) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.approveForClaim(address(0), _approved);
  }

  function test_WhenTheOperatorIsAValidAddress(address _caller, address _operator, bool _approved) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_operator);

    vm.prank(_caller);
    // it should emit a ClaimApproval event
    _expectEmit(address(_gauge));
    emit IGauge.ClaimApproval(_caller, _operator, _approved);
    _gauge.approveForClaim(_operator, _approved);

    // it should set the claim approval for the caller and operator
    assertEq(_gauge.approvedForClaim(_caller, _operator), _approved);
  }
}
