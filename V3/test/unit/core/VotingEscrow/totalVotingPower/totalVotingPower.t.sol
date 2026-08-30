// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowTotalVotingPower is BaseVotingEscrow {
  function test_WhenTheGlobalCurveIsSeeded() external {
    // Seed one week-aligned global point: ts=604800 (=1*WEEK), slope=3, bias=6000, permanent=1000.
    // Query at now=604900 (same week). supplyAt caps t_i to _t in one iteration, so:
    //   bias - slope*(now - ts) + permanent = 6000 - 3*(604900-604800) + 1000 = 6000 - 300 + 1000 = 6700.
    _setEpoch(1);
    _setPointHistory(1, 6000, 3, 604_800, 1000);
    vm.warp(604_900);

    // it should return the decayed bias plus permanent balance at the current timestamp
    assertEq(_ve.totalVotingPower(), 6700);
    // it should match totalVotingPowerAt at the current timestamp
    assertEq(_ve.totalVotingPower(), _ve.totalVotingPowerAt(block.timestamp));
  }
}
