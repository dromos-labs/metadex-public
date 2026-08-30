// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotes} from 'V3/interfaces/core/IVotes.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowDelegate is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(
    address _caller,
    uint256 _delegator,
    uint256 _delegatee
  ) external {
    _assumeFuzzable(_caller);
    _delegator = bound(_delegator, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_delegator, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _delegator));
    vm.prank(_caller);
    _ve.delegate(_delegator, _delegatee);
  }

  function test_WhenTheDelegatorTokenIdDoesNotExist(uint256 _delegator, uint256 _delegatee) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    // No _setOwner: the delegator tokenId has never been minted, so _ownerOf returns address(0).

    // it should revert with ERC721NonexistentToken
    // _checkAuthorized resolves owner == address(0) to the nonexistent-token branch (VotingEscrow.sol:407 -> OZ
    // _checkAuthorized), so the missing-token path reverts before _delegate is ever reached.
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _delegator));
    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);
  }

  function test_WhenTheDelegatorStakeIsNotPermanent(
    uint256 _delegator,
    uint256 _delegatee,
    uint128 _oldAmount,
    uint48 _stakeEnd
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_delegator, _owner);
    _setStaked(_delegator, _oldAmount, _stakeEnd, false);

    // it should revert with NotPermanentStake
    vm.expectRevert(IVotingEscrow.NotPermanentStake.selector);
    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);
  }

  function test_WhenTheDelegateeTokenIdIsNotZeroAndDoesNotExist(
    uint256 _delegator,
    uint256 _delegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_delegator, _owner);
    _setStaked(_delegator, _oldAmount, 0, true);

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _delegatee));
    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);
  }

  function test_WhenTheOwnershipOfTheDelegatorChangedInTheCurrentBlock(
    uint256 _delegator,
    uint256 _delegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_delegator, _owner);
    _setOwner(_delegatee, makeAddr('DelegateeOwner'));
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_delegatee, _oldAmount, 0, true);
    _setOwnershipChange(_delegator, block.number);

    // it should revert with OwnershipChange
    vm.expectRevert(IVotingEscrow.OwnershipChange.selector);
    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);
  }

  function test_WhenTheDelegatorIsAlreadyDelegatingToThatDelegatee(
    uint256 _delegator,
    uint256 _delegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_delegator, _owner);
    _setOwner(_delegatee, makeAddr('DelegateeOwner'));
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_delegatee, _oldAmount, 0, true);
    _setDelegate(_delegator, _delegatee);

    // it should not emit a DelegateChanged event
    vm.recordLogs();
    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenTheDelegatorDelegatesToItself(
    uint256 _delegator,
    uint256 _oldDelegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _oldDelegatee = bound(_oldDelegatee, 1, type(uint128).max);
    vm.assume(_oldDelegatee != _delegator);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));

    address _oldDelegateeOwner = makeAddr('OldDelegateeOwner');
    _setOwner(_delegator, _owner);
    _setOwner(_oldDelegatee, _oldDelegateeOwner);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_oldDelegatee, _oldAmount, 0, true);
    _setDelegate(_delegator, _oldDelegatee);
    // Seed the delegator's prior checkpoint pointing at the old delegatee so the self-delegation dedelegates it.
    _setNumCheckpoints(_delegator, 1);
    _setCheckpoint(_delegator, 0, 1, _owner, 0, _oldDelegatee);
    // Seed the old delegatee with delegated balance equal to the delegator amount so the drain lands exactly at zero.
    _setNumCheckpoints(_oldDelegatee, 1);
    _setCheckpoint(_oldDelegatee, 0, 1, _oldDelegateeOwner, _oldAmount, 0);

    // Advance so the next checkpoint appends rather than overwrites the seeded one.
    vm.warp(2);

    // it should emit the DelegateChanged event clearing to zero
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_owner, _oldDelegatee, 0);

    vm.prank(_owner);
    _ve.delegate(_delegator, _delegator);

    // it should clear the delegate slot to zero
    assertEq(_ve.delegates(_delegator), 0);
    // it should record a delegator checkpoint with a zero delegatee
    assertEq(_ve.numCheckpoints(_delegator), 2);
    assertEq(_ve.checkpoints(_delegator, 1).delegatee, 0);
    assertEq(_ve.checkpoints(_delegator, 1).owner, _owner);
    // it should drain the old delegatee delegated balance to zero
    assertEq(_ve.numCheckpoints(_oldDelegatee), 2);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).delegatedBalance, 0);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).owner, _oldDelegateeOwner);
    assertEq(_ve.getPastVotes(_oldDelegateeOwner, _oldDelegatee, block.timestamp), 0, 'old getPastVotes drift');
  }

  function test_WhenClearingAPriorDelegateeWithAZeroDelegatee(
    uint256 _delegator,
    uint256 _oldDelegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _oldDelegatee = bound(_oldDelegatee, 1, type(uint128).max);
    vm.assume(_oldDelegatee != _delegator);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));

    address _oldDelegateeOwner = makeAddr('OldDelegateeOwner');
    _setOwner(_delegator, _owner);
    _setOwner(_oldDelegatee, _oldDelegateeOwner);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_oldDelegatee, _oldAmount, 0, true);
    _setDelegate(_delegator, _oldDelegatee);
    // Seed the delegator's prior checkpoint pointing at the old delegatee so clearing dedelegates it.
    _setNumCheckpoints(_delegator, 1);
    _setCheckpoint(_delegator, 0, 1, _owner, 0, _oldDelegatee);
    // Seed the old delegatee with delegated balance equal to the delegator amount so the drain lands exactly at zero.
    _setNumCheckpoints(_oldDelegatee, 1);
    _setCheckpoint(_oldDelegatee, 0, 1, _oldDelegateeOwner, _oldAmount, 0);

    // Advance so the next checkpoint appends rather than overwrites the seeded one.
    vm.warp(2);

    // it should emit the DelegateChanged event clearing to zero
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_owner, _oldDelegatee, 0);

    vm.prank(_owner);
    _ve.delegate(_delegator, 0);

    // it should clear the delegate slot to zero
    assertEq(_ve.delegates(_delegator), 0);
    // it should record a delegator checkpoint with a zero delegatee
    assertEq(_ve.numCheckpoints(_delegator), 2);
    assertEq(_ve.checkpoints(_delegator, 1).delegatee, 0);
    assertEq(_ve.checkpoints(_delegator, 1).owner, _owner);
    // it should drain the old delegatee delegated balance to zero
    assertEq(_ve.numCheckpoints(_oldDelegatee), 2);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).delegatedBalance, 0);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).owner, _oldDelegateeOwner);
    assertEq(_ve.getPastVotes(_oldDelegateeOwner, _oldDelegatee, block.timestamp), 0, 'old getPastVotes drift');
  }

  function test_WhenDelegatingFromNoPriorDelegate(uint256 _delegator, uint256 _delegatee, uint128 _oldAmount) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _delegatee = bound(_delegatee, 1, type(uint128).max);
    vm.assume(_delegator != _delegatee);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    address _delegateeOwner = makeAddr('DelegateeOwner');
    _setOwner(_delegator, _owner);
    _setOwner(_delegatee, _delegateeOwner);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_delegatee, _oldAmount, 0, true);
    // Seed the delegatee's mint-time checkpoint so the subsequent delegate() propagates the real
    // owner forward. Using fromTimestamp = block.timestamp makes checkpointDelegatee overwrite in
    // place (same-block path), preserving numCheckpoints == 1 below.
    _setNumCheckpoints(_delegatee, 1);
    _setCheckpoint(_delegatee, 0, block.timestamp, _delegateeOwner, 0, 0);

    // it should emit the DelegateChanged event
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_owner, 0, _delegatee);

    vm.prank(_owner);
    _ve.delegate(_delegator, _delegatee);

    // it should set the delegate slot to the delegatee
    assertEq(_ve.delegates(_delegator), _delegatee);
    // it should bump the delegator num checkpoints to one
    assertEq(_ve.numCheckpoints(_delegator), 1);
    // it should bump the delegatee num checkpoints to one
    assertEq(_ve.numCheckpoints(_delegatee), 1);
    // it should record a delegator checkpoint at the current timestamp with the new delegatee
    IVotingEscrow.Checkpoint memory _dCp = _ve.checkpoints(_delegator, 0);
    assertEq(_dCp.fromTimestamp, block.timestamp);
    assertEq(_dCp.owner, _owner);
    assertEq(_dCp.delegatedBalance, 0);
    assertEq(_dCp.delegatee, _delegatee);
    // it should record a delegatee checkpoint with delegated balance equal to the delegator amount
    IVotingEscrow.Checkpoint memory _eCp = _ve.checkpoints(_delegatee, 0);
    assertEq(_eCp.fromTimestamp, block.timestamp);
    assertEq(_eCp.owner, _delegateeOwner);
    assertEq(_eCp.delegatedBalance, _oldAmount);
    assertEq(_eCp.delegatee, 0);
    // it should reflect the new delegated balance in getPastVotes
    assertEq(_ve.getPastVotes(_delegateeOwner, _delegatee, block.timestamp), _oldAmount, 'getPastVotes drift');
  }

  function test_WhenSwitchingFromAPriorDelegateeToANewOne(
    uint256 _delegator,
    uint256 _oldDelegatee,
    uint256 _newDelegatee,
    uint128 _oldAmount
  ) external {
    _delegator = bound(_delegator, 1, type(uint128).max);
    _oldDelegatee = bound(_oldDelegatee, 1, type(uint128).max);
    _newDelegatee = bound(_newDelegatee, 1, type(uint128).max);
    vm.assume(_delegator != _oldDelegatee);
    vm.assume(_delegator != _newDelegatee);
    vm.assume(_oldDelegatee != _newDelegatee);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));

    address _oldDelegateeOwner = makeAddr('OldDelegateeOwner');
    address _newDelegateeOwner = makeAddr('NewDelegateeOwner');
    _setOwner(_delegator, _owner);
    _setOwner(_oldDelegatee, _oldDelegateeOwner);
    _setOwner(_newDelegatee, _newDelegateeOwner);
    _setStaked(_delegator, _oldAmount, 0, true);
    _setStaked(_oldDelegatee, _oldAmount, 0, true);
    _setStaked(_newDelegatee, _oldAmount, 0, true);
    _setDelegate(_delegator, _oldDelegatee);
    _setNumCheckpoints(_delegator, 1);
    _setCheckpoint(_delegator, 0, 1, _owner, 0, _oldDelegatee);
    // Seed the old delegatee's prior-delegation checkpoint with the real owner so the post-switch
    // checkpoint propagates it.
    _setNumCheckpoints(_oldDelegatee, 1);
    _setCheckpoint(_oldDelegatee, 0, 1, _oldDelegateeOwner, _oldAmount, 0);
    // Seed the new delegatee's mint-time checkpoint so delegate() propagates its owner forward
    // instead of stamping address(0). Mirrors the (_update -> _checkpointDelegator) path real
    // mints take before the delegatee ever receives a delegation.
    _setNumCheckpoints(_newDelegatee, 1);
    _setCheckpoint(_newDelegatee, 0, 1, _newDelegateeOwner, 0, 0);

    // Advance so the next checkpoint appends rather than overwrites.
    vm.warp(2);

    vm.prank(_owner);
    _ve.delegate(_delegator, _newDelegatee);

    // it should record a delegator checkpoint with the new delegatee
    assertEq(_ve.delegates(_delegator), _newDelegatee);
    assertEq(_ve.numCheckpoints(_delegator), 2);
    assertEq(_ve.checkpoints(_delegator, 1).delegatee, _newDelegatee);
    // it should record an old delegatee checkpoint with delegated balance back to zero
    assertEq(_ve.numCheckpoints(_oldDelegatee), 2);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).delegatedBalance, 0);
    assertEq(_ve.checkpoints(_oldDelegatee, 1).owner, _oldDelegateeOwner);
    // it should record a new delegatee checkpoint with delegated balance equal to the delegator amount
    assertEq(_ve.numCheckpoints(_newDelegatee), 2);
    assertEq(_ve.checkpoints(_newDelegatee, 1).delegatedBalance, _oldAmount);
    assertEq(_ve.checkpoints(_newDelegatee, 1).owner, _newDelegateeOwner);
    // it should reflect the swapped delegation in getPastVotes (old drains, new fills)
    assertEq(_ve.getPastVotes(_oldDelegateeOwner, _oldDelegatee, block.timestamp), 0, 'old getPastVotes drift');
    assertEq(_ve.getPastVotes(_newDelegateeOwner, _newDelegatee, block.timestamp), _oldAmount, 'new getPastVotes drift');
  }
}
