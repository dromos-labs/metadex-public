// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowGetters is BaseVotingEscrow {
  function test_WhenAKnownPackedValueIsStored(uint256 _tokenId, address _account) external {
    _assumeFuzzable(_account);
    vm.assume(_tokenId != type(uint256).max); // leave an adjacent unwritten key to probe below

    // it should decode the staked balance fields
    _setStaked(_tokenId, 12_345, 6000, true);
    IVotingEscrow.StakedBalance memory _s = _ve.staked(_tokenId);
    assertEq(_s.amount, 12_345);
    assertEq(_s.end, 6000);
    assertTrue(_s.isPermanent);

    // it should decode the user point history fields
    _setUserPoint(_tokenId, 1, 6000, 3, 2000, 4242);
    IVotingEscrow.UserPoint memory _u = _ve.userPointHistory(_tokenId, 1);
    assertEq(_u.bias, 6000);
    assertEq(_u.slope, 3);
    assertEq(_u.ts, 2000);
    assertEq(_u.permanent, 4242);

    // it should decode the point history fields
    _setPointHistory(7, -11, 22, 3333, 5555);
    IVotingEscrow.GlobalPoint memory _p = _ve.pointHistory(7);
    assertEq(_p.bias, -11);
    assertEq(_p.slope, 22);
    assertEq(_p.ts, 3333);
    assertEq(_p.permanentStakeBalance, 5555);

    // it should decode the delegates entry
    _setDelegate(_tokenId, 909);
    assertEq(_ve.delegates(_tokenId), 909);

    // it should decode the checkpoint fields
    _setCheckpoint(_tokenId, 0, 1111, _account, 2222, 3333);
    IVotingEscrow.Checkpoint memory _c = _ve.checkpoints(_tokenId, 0);
    assertEq(_c.fromTimestamp, 1111);
    assertEq(_c.owner, _account);
    assertEq(_c.delegatedBalance, 2222);
    assertEq(_c.delegatee, 3333);

    // it should decode the num checkpoints entry
    _setNumCheckpoints(_tokenId, 5);
    assertEq(_ve.numCheckpoints(_tokenId), 5);

    // it should decode the nonces entry
    _setNonce(_account, 8);
    assertEq(_ve.nonces(_account), 8);

    // it should decode the slope changes entry
    _setSlopeChange(6000, -77);
    assertEq(_ve.slopeChanges(6000), -77);

    // it should decode the ownership change entry
    _setOwnershipChange(_tokenId, 444);
    assertEq(_ve.ownershipChange(_tokenId), 444);

    // it should decode the user point epoch entry (set by _setUserPoint above)
    assertEq(_ve.userPointEpoch(_tokenId), 1);

    // it should return zero for an unwritten key
    assertEq(_ve.numCheckpoints(_tokenId + 1), 0);
  }
}
