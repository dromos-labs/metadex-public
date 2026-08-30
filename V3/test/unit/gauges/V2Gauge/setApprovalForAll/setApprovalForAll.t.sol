// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeSetApprovalForAll is UnitV2Gauge {
  function test_WhenTheOperatorIsTheZeroAddress(address _caller, bool _approved) external {
    _assumeFuzzable(_caller);

    vm.prank(_caller);
    // it should revert with ZeroAddress
    vm.expectRevert(IGauge.ZeroAddress.selector);
    _gauge.setApprovalForAll(address(0), _approved);
  }

  function test_WhenApprovalIsGranted(address _caller, address _operator) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_operator);

    vm.prank(_caller);
    // it should emit an ApprovalForAll event
    _expectEmit(address(_gauge));
    emit IGauge.ApprovalForAll(_caller, _operator, true);
    _gauge.setApprovalForAll(_operator, true);

    // it should set the allowance to the max sentinel
    assertEq(_gauge.allowance(_caller, _operator), type(uint256).max);
    assertTrue(_gauge.isApprovedForAll(_caller, _operator));
  }

  function test_WhenApprovalIsRevoked(address _caller, address _operator, uint256 _seededAllowance) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_operator);
    _seededAllowance = bound(_seededAllowance, 1, type(uint256).max);
    _seedAllowance(_caller, _operator, _seededAllowance);

    vm.prank(_caller);
    // it should emit an ApprovalForAll event
    _expectEmit(address(_gauge));
    emit IGauge.ApprovalForAll(_caller, _operator, false);
    _gauge.setApprovalForAll(_operator, false);

    // it should clear the allowance wiping any existing allowance
    assertEq(_gauge.allowance(_caller, _operator), 0);
    assertFalse(_gauge.isApprovedForAll(_caller, _operator));
  }
}
