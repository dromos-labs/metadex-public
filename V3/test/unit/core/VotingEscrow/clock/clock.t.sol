// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowClock is BaseVotingEscrow {
  function test_WhenCalledAfterAWarp(uint48 _now) external {
    vm.warp(_now);

    // it should return the current block timestamp
    assertEq(_ve.clock(), _now);
  }
}
