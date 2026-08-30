// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowBalanceOfNFTAt is BaseVotingEscrow {
  function test_WhenTheTimestampIsBeforeTheFirstUserPoint(uint256 _tokenId) external {
    // The only user point sits at ts=2000; querying earlier resolves to the implicit zero balance.
    _setUserPoint(_tokenId, 1, 6000, 3, 2000, 0);

    // it should return zero
    assertEq(_ve.balanceOfNFTAt(_tokenId, 1500), 0);
  }

  function test_WhenAUserPointExistsAtOrBeforeTheTimestamp(uint256 _tokenId) external {
    // Seed one user point: slope=3, ts=2000, bias=6000. Query at t=2500.
    // Independent decay: bias - slope*(t - ts) = 6000 - 3*(2500-2000) = 6000 - 1500 = 4500.
    _setUserPoint(_tokenId, 1, 6000, 3, 2000, 0);

    // it should return the decayed balance at the timestamp
    assertEq(_ve.balanceOfNFTAt(_tokenId, 2500), 4500);
  }
}
