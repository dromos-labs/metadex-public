// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowCLOCKMODE is BaseVotingEscrow {
  function test_WhenCalled() external view {
    // it should return the timestamp mode string
    assertEq(_ve.CLOCK_MODE(), 'mode=timestamp');
  }
}
