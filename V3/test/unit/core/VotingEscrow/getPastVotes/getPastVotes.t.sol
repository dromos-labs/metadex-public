// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowGetPastVotes is BaseVotingEscrow {
  /// @dev Current block timestamp for these tests. Checkpoints sit at 1000/2000, so queries at or below this are
  ///      historical while queries above it are rejected by the FutureLookup guard.
  uint48 internal constant _NOW = 10_000;

  function test_WhenTheTimestampIsAfterTheCurrentBlock(uint256 _tokenId, address _account, uint48 _future) external {
    vm.warp(_NOW);
    _future = uint48(bound(_future, uint256(_NOW) + 1, type(uint48).max));

    // it should revert with FutureLookup
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.FutureLookup.selector, uint256(_future), _NOW));
    _ve.getPastVotes(_account, _tokenId, _future);
  }

  function test_WhenTheTimestampEqualsTheCurrentBlock(uint256 _tokenId, address _account) external {
    vm.warp(_NOW);
    // Latest checkpoint at 2000 has delegatedBalance 888 and a non-zero delegatee, so a query at the current
    // block resolves to it with no balanceOfNFTAt term.
    _setNumCheckpoints(_tokenId, 2);
    _setCheckpoint(_tokenId, 0, 1000, _account, 777, 99);
    _setCheckpoint(_tokenId, 1, 2000, _account, 888, 99);

    // it should return the votes at the current block
    assertEq(_ve.getPastVotes(_account, _tokenId, block.timestamp), 888);
  }

  function test_WhenTheTimestampIsBeforeTheFirstCheckpoint(uint256 _tokenId, address _account) external {
    vm.warp(_NOW);
    // Two checkpoints at fromTimestamp 1000 and 2000; querying at 500 precedes both.
    _setNumCheckpoints(_tokenId, 2);
    _setCheckpoint(_tokenId, 0, 1000, _account, 777, 99);
    _setCheckpoint(_tokenId, 1, 2000, _account, 888, 99);

    // it should return zero
    assertEq(_ve.getPastVotes(_account, _tokenId, 500), 0);
  }

  function test_WhenTheTimestampFallsBetweenCheckpoints(uint256 _tokenId, address _account) external {
    vm.warp(_NOW);
    // Checkpoints at 1000 (delegatedBalance 777) and 2000; querying at 1500 selects the earlier one.
    // delegatee is non-zero (99), so the result is exactly the delegatedBalance with no balanceOfNFTAt term.
    _setNumCheckpoints(_tokenId, 2);
    _setCheckpoint(_tokenId, 0, 1000, _account, 777, 99);
    _setCheckpoint(_tokenId, 1, 2000, _account, 888, 99);

    // it should return the earlier checkpoint delegated balance
    assertEq(_ve.getPastVotes(_account, _tokenId, 1500), 777);
  }

  function test_WhenTheAccountIsNotTheCheckpointOwner(uint256 _tokenId, address _ownerAddr, address _account) external {
    vm.warp(_NOW);
    vm.assume(_ownerAddr != _account);
    // The selected checkpoint at 2000 is owned by _ownerAddr; querying as a different account fails the owner check.
    _setNumCheckpoints(_tokenId, 2);
    _setCheckpoint(_tokenId, 0, 1000, _ownerAddr, 777, 99);
    _setCheckpoint(_tokenId, 1, 2000, _ownerAddr, 888, 99);

    // it should return zero
    assertEq(_ve.getPastVotes(_account, _tokenId, 2500), 0);
  }
}
