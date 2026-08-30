// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugeCollectFees is UnitV2Gauge {
  function test_WhenCallerIsNotTheVotingRewardsManager(address _caller) external {
    _caller = _boundNotEq(_caller, _votingRewardsManager);

    vm.prank(_caller);
    // it should revert with NotVotingRewardsManager
    vm.expectRevert(IGauge.NotVotingRewardsManager.selector);
    _gauge.collectFees();
  }

  function test_WhenTheGaugeIsNotAPool() external {
    _gauge = _newGauge(false);

    vm.prank(_votingRewardsManager);
    (uint256 _claimed0, uint256 _claimed1) = _gauge.collectFees();

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
  }

  function test_WhenTheEmissionCapIsZero() external {
    _expectActivation(true);
    _expectEmissionCap(0);

    vm.prank(_votingRewardsManager);
    (uint256 _claimed0, uint256 _claimed1) = _gauge.collectFees();

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
  }

  function test_WhenTheGaugeIsNotActivated() external {
    _expectActivation(false);

    vm.prank(_votingRewardsManager);
    (uint256 _claimed0, uint256 _claimed1) = _gauge.collectFees();

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
  }

  function test_WhenThePoolClaimsZeroFees() external {
    _expectActivation(true);
    _expectEmissionCap(1);
    _expectPoolClaimFees(0, 0);

    vm.recordLogs();
    vm.prank(_votingRewardsManager);
    (uint256 _claimed0, uint256 _claimed1) = _gauge.collectFees();

    // it should return zero amounts
    assertEq(_claimed0, 0);
    assertEq(_claimed1, 0);
    // it should not emit a ClaimFees event
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenThePoolClaimsFees(uint128 _claimed0, uint128 _claimed1, uint128 _emissionCap) external {
    _emissionCap = uint128(bound(_emissionCap, 1, type(uint128).max));
    _claimed0 = uint128(bound(_claimed0, 1, type(uint128).max));
    _claimed1 = uint128(bound(_claimed1, 1, type(uint128).max));
    _expectActivation(true);
    _expectEmissionCap(_emissionCap);
    _expectPoolClaimFees(_claimed0, _claimed1);

    vm.prank(_votingRewardsManager);
    // it should emit a ClaimFees event
    _expectEmit(address(_gauge));
    emit IGauge.ClaimFees(_votingRewardsManager, _claimed0, _claimed1);
    (uint256 _actualClaimed0, uint256 _actualClaimed1) = _gauge.collectFees();

    // it should claim fees to the voting rewards manager
    // it should return the claimed amounts
    assertEq(_actualClaimed0, _claimed0);
    assertEq(_actualClaimed1, _claimed1);
  }

  function testGas_collectFees() external {
    _expectActivation(true);
    _expectEmissionCap(1);
    _expectPoolClaimFees(10e18, 20e18);

    vm.prank(_votingRewardsManager);
    _gauge.collectFees();

    vm.snapshotGasLastCall('V2Gauge_collectFees');
  }

  function _expectPoolClaimFees(uint256 _claimed0, uint256 _claimed1) internal {
    _mockAndExpect(
      _stakingToken,
      abi.encodeWithSelector(bytes4(keccak256('claimFees(address)')), _votingRewardsManager),
      abi.encode(_claimed0, _claimed1)
    );
  }

  function _expectActivation(bool _isActivated) internal {
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.isActivated, (address(_gauge))), abi.encode(_isActivated));
  }
}
