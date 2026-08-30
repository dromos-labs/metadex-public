// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowBalanceOfNFT is BaseVotingEscrow {
  function test_WhenAUserPointExistsAtOrBeforeTheCurrentTimestamp(uint256 _tokenId) external {
    // Seed one user point: slope=3, ts=2000, bias=6000. Query at now=2500.
    // Independent decay: bias - slope*(now - ts) = 6000 - 3*(2500-2000) = 6000 - 1500 = 4500.
    _setUserPoint(_tokenId, 1, 6000, 3, 2000, 0);
    vm.warp(2500);

    // it should return the decayed balance at the current timestamp
    assertEq(_ve.balanceOfNFT(_tokenId), 4500);
  }
}
