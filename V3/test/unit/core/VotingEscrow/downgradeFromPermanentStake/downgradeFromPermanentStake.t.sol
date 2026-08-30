// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotes} from 'V3/interfaces/core/IVotes.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowDowngradeFromPermanentStake is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(address _caller, uint256 _tokenId) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.downgradeFromPermanentStake(_tokenId);
  }

  function test_WhenTheTokenIdHasNotBeenMinted(uint256 _tokenId) external {
    // _tokenId has no owner: no `_setOwner` call. Includes tokenId 0 (the accumulator, never minted).

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _tokenId));
    vm.prank(_owner);
    _ve.downgradeFromPermanentStake(_tokenId);
  }

  function test_WhenTheStakeIsNotPermanent(uint256 _tokenId, uint128 _oldAmount, uint48 _stakeEnd) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);

    // it should revert with NotPermanentStake
    vm.expectRevert(IVotingEscrow.NotPermanentStake.selector);
    vm.prank(_owner);
    _ve.downgradeFromPermanentStake(_tokenId);
  }

  function test_WhenTheStakeIsNotFullyOnChainZero(uint256 _tokenId, uint128 _oldAmount, uint128 _allocated) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    // Strictly under-allocated on chain0: any value in [0, amount - 1] trips `allocation < amount`.
    _allocated = uint128(bound(_allocated, 0, _oldAmount - 1));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _mockVoterChain0Allocation(_tokenId, _allocated);

    // it should revert with InsufficientChain0Allocation
    vm.expectRevert(IVoter.InsufficientChain0Allocation.selector);
    vm.prank(_owner);
    _ve.downgradeFromPermanentStake(_tokenId);
  }

  function test_WhenTheDelegatorOwnershipChangedInTheCurrentBlock(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    // Full balance idle on chain0 so the downgrade reaches the _delegate clear.
    _mockVoterChain0Allocation(_tokenId, _oldAmount);
    // Mark the delegator as having changed ownership this block so the _delegate clear reverts.
    _setOwnershipChange(_tokenId, block.number);

    // it should revert with OwnershipChange
    vm.expectRevert(IVotingEscrow.OwnershipChange.selector);
    vm.prank(_owner);
    _ve.downgradeFromPermanentStake(_tokenId);
  }

  function test_WhenAnAuthorizedCallerUnstakesAPermanentStakeWithNoPriorDelegatee(
    address _operator,
    uint256 _tokenId,
    uint128 _oldAmount,
    bool _useOperator
  ) external {
    _assumeFuzzable(_operator);
    vm.assume(_operator != _owner);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _mockVoterChain0Allocation(_tokenId, _oldAmount);
    // No prior delegatee: the delegation slot is already empty, so _delegate(_tokenId, 0) is a no-op
    // clear (currentDelegate == 0 == new delegatee, early return). This exercises the no-op control path.

    address _caller = _owner;
    if (_useOperator) {
      _setOperatorApproval(_owner, _operator, true);
      _caller = _operator;
    }

    uint48 _expectedEnd = ((uint48(block.timestamp) + _MAXTIME) / _WEEK) * _WEEK;
    int128 _expectedSlope = int128(_oldAmount) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_expectedEnd - uint48(block.timestamp)));

    // it should emit the DowngradeFromPermanentStake event with the token owner
    _expectEmit(address(_ve));
    emit IVotingEscrow.DowngradeFromPermanentStake(_owner, _tokenId, _oldAmount, block.timestamp);
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);

    // it should reanchor the token chain zero shape on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)));

    vm.prank(_caller);
    _ve.downgradeFromPermanentStake(_tokenId);

    // it should flip the stake to decaying and set the end to the next maxtime week boundary
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertFalse(_staked.isPermanent);
    assertEq(_staked.end, _expectedEnd);
    // it should leave the staked amount and supply unchanged
    assertEq(_staked.amount, _oldAmount);
    assertEq(_ve.supply(), _oldAmount);
    // it should decrement the permanent stake balance by the staked amount
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should leave the delegation slot clear
    assertEq(_ve.delegates(_tokenId), 0);
    // it should not record any delegator checkpoint because the clear is a no-op
    assertEq(_ve.numCheckpoints(_tokenId), 0);
    // it should record a user point with the recomputed slope and bias and zero permanent
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should advance the global epoch and reflect the lower permanent balance
    assertEq(_ve.epoch(), 1);
    assertEq(_ve.pointHistory(1).permanentStakeBalance, 0);
    // it should match the voting-power APIs to the recomputed decay bias
    _assertVotingPower(uint256(int256(_expectedBias)), _tokenId, uint256(int256(_expectedBias)));
    _assertGlobalPointInvariants();
  }

  function test_WhenAnAuthorizedCallerUnstakesAPermanentStakeWithARealPriorDelegatee(
    address _operator,
    uint256 _tokenId,
    uint256 _priorDelegatee,
    uint128 _oldAmount,
    bool _useOperator
  ) external {
    _assumeFuzzable(_operator);
    vm.assume(_operator != _owner);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _priorDelegatee = bound(_priorDelegatee, 1, type(uint128).max);
    vm.assume(_priorDelegatee != _tokenId);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));

    address _priorDelegateeOwner = makeAddr('PriorDelegateeOwner');
    _setOwner(_tokenId, _owner);
    _setOwner(_priorDelegatee, _priorDelegateeOwner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _mockVoterChain0Allocation(_tokenId, _oldAmount);
    _setDelegate(_tokenId, _priorDelegatee);
    // Seed the delegator's existing checkpoint pointing at the prior delegatee so _checkpointDelegator
    // de-delegates the former delegatee (it reads cpOld.delegatee, not _delegates).
    _setNumCheckpoints(_tokenId, 1);
    _setCheckpoint(_tokenId, 0, 1, _owner, 0, _priorDelegatee);
    // Seed the prior delegatee's checkpoint carrying the delegated balance so the downgrade drains it.
    _setNumCheckpoints(_priorDelegatee, 1);
    _setCheckpoint(_priorDelegatee, 0, 1, _priorDelegateeOwner, _oldAmount, 0);

    // Advance past the seeded checkpoints' timestamp so the downgrade appends instead of overwriting.
    vm.warp(2);

    address _caller = _owner;
    if (_useOperator) {
      _setOperatorApproval(_owner, _operator, true);
      _caller = _operator;
    }

    // it should emit the DelegateChanged event clearing the prior delegatee
    _expectEmit(address(_ve));
    emit IVotes.DelegateChanged(_owner, _priorDelegatee, 0);
    // it should emit the DowngradeFromPermanentStake event with the token owner
    _expectEmit(address(_ve));
    emit IVotingEscrow.DowngradeFromPermanentStake(_owner, _tokenId, _oldAmount, block.timestamp);
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);

    vm.prank(_caller);
    _ve.downgradeFromPermanentStake(_tokenId);

    // it should clear the delegation slot
    assertEq(_ve.delegates(_tokenId), 0);
    // it should advance the delegator num checkpoints recording the cleared delegatee
    assertEq(_ve.numCheckpoints(_tokenId), 2);
    assertEq(_ve.checkpoints(_tokenId, 1).delegatee, 0);
    assertEq(_ve.checkpoints(_tokenId, 1).owner, _owner);
    // it should advance the former delegatee num checkpoints draining its delegated balance to zero
    assertEq(_ve.numCheckpoints(_priorDelegatee), 2);
    assertEq(_ve.checkpoints(_priorDelegatee, 1).delegatedBalance, 0);
    assertEq(_ve.checkpoints(_priorDelegatee, 1).owner, _priorDelegateeOwner);
    // it should reflect the drained balance in the former delegatee getPastVotes
    assertEq(
      _ve.getPastVotes(_priorDelegateeOwner, _priorDelegatee, block.timestamp), 0, 'former delegatee not drained'
    );
    _assertGlobalPointInvariants();
  }

  function test_WhenAnAuthorizedCallerUnstakesUsingAKnownExactSlopeAndBias() external {
    // Independent precision case: pick amount = k * IMAXTIME so slope is an exact integer k, and warp to a
    // week-aligned timestamp so the recomputed end and bias are clean literals (no implementation formula reuse).
    //   IMAXTIME = 126_144_000, WEEK = 604_800, MAXTIME = 126_144_000.
    //   k = 3  -> amount = 3 * 126_144_000 = 378_432_000, slope = 378_432_000 / 126_144_000 = 3 (exact).
    //   block.timestamp = WEEK = 604_800 (week-aligned).
    //   newEnd = ((604_800 + 126_144_000) / 604_800) * 604_800 = 209 * 604_800 = 126_403_200.
    //   end - now = 126_403_200 - 604_800 = 125_798_400.
    //   bias = slope * (end - now) = 3 * 125_798_400 = 377_395_200.
    uint256 _tokenId = 7;
    uint128 _amount = 378_432_000;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _amount, 0, true);
    _setSupplyAndPermanent(_amount, _amount);
    _mockVoterChain0Allocation(_tokenId, _amount);

    vm.warp(604_800);

    // it should emit the DowngradeFromPermanentStake event with the token owner
    _expectEmit(address(_ve));
    emit IVotingEscrow.DowngradeFromPermanentStake(_owner, _tokenId, _amount, block.timestamp);
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);

    vm.prank(_owner);
    _ve.downgradeFromPermanentStake(_tokenId);

    // it should set the end to the known week boundary
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.end, 126_403_200);
    // it should record a user point with the known exact slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, 3);
    assertEq(_uPoint.bias, 377_395_200);
    assertEq(_uPoint.permanent, 0);
    // it should match the voting-power APIs to the known bias
    _assertVotingPower(377_395_200, _tokenId, 377_395_200);
    _assertGlobalPointInvariants();
  }
}
