// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeApprove is UnitV2Gauge {
  function test_WhenTheOperatorIsTheZeroAddress(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.approve(address(0), _amount);
  }

  function test_WhenTheOperatorIsAValidAddress(address _caller, address _operator, uint256 _amount) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_operator);

    vm.prank(_caller);
    // it should emit an Approval event
    _expectEmit(address(_gauge));
    emit IV2Gauge.Approval(_caller, _operator, _amount);
    _gauge.approve(_operator, _amount);

    // it should set the withdrawal allowance
    assertEq(_gauge.allowance(_caller, _operator), _amount);
  }
}
