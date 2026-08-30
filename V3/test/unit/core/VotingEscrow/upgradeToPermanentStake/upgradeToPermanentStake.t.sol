// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowUpgradeToPermanentStake is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(address _caller, uint256 _tokenId) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.upgradeToPermanentStake(_tokenId);
  }

  function test_WhenTheStakeIsAlreadyPermanent(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);

    // it should not park anything on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 0);

    // it should revert with PermanentStake
    vm.expectRevert(IVotingEscrow.PermanentStake.selector);
    vm.prank(_owner);
    _ve.upgradeToPermanentStake(_tokenId);
  }

  function test_WhenTheStakeHasExpired(uint256 _tokenId, uint128 _oldAmount, uint48 _now, uint48 _end) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _now = uint48(bound(_now, 2, type(uint48).max));
    vm.warp(_now);
    // Cover the full strictly-expired range: any end in [1, now - 1] trips the `end <= block.timestamp` guard.
    _end = uint48(bound(_end, 1, uint48(block.timestamp) - 1));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _end, false);

    // it should not park anything on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 0);

    // it should revert with StakeExpired
    vm.expectRevert(IVotingEscrow.StakeExpired.selector);
    vm.prank(_owner);
    _ve.upgradeToPermanentStake(_tokenId);
  }

  function test_WhenTheStakeEndEqualsTheCurrentTimestamp(uint256 _tokenId, uint128 _oldAmount, uint48 _now) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _now = uint48(bound(_now, 1, type(uint48).max));
    vm.warp(_now);
    _setOwner(_tokenId, _owner);
    // Boundary: end == block.timestamp must revert because the guard is `end <= block.timestamp`.
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp), false);

    // it should revert with StakeExpired
    vm.expectRevert(IVotingEscrow.StakeExpired.selector);
    vm.prank(_owner);
    _ve.upgradeToPermanentStake(_tokenId);
  }

  function test_WhenTheStakeAmountIsZeroAndNotExpired(uint256 _tokenId, uint48 _stakingWeeks) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, 207));
    uint48 _stakeEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_stakeEnd > block.timestamp);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, 0, _stakeEnd, false);

    // it should emit the UpgradeToPermanentStake event with zero amount
    _expectEmit(address(_ve));
    emit IVotingEscrow.UpgradeToPermanentStake(_owner, _tokenId, 0, block.timestamp);

    vm.prank(_owner);
    _ve.upgradeToPermanentStake(_tokenId);

    // it should flip the empty stake to permanent
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertTrue(_staked.isPermanent);
    assertEq(_staked.end, 0);
    assertEq(_staked.amount, 0);
    // it should leave the permanent stake balance at zero
    assertEq(_ve.permanentStakeBalance(), 0);
  }

  function test_WhenTheStakeIsDecayingAndNotExpired(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _stakingWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, 207));
    uint48 _stakeEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_stakeEnd > block.timestamp);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);

    // it should emit the UpgradeToPermanentStake event
    _expectEmit(address(_ve));
    emit IVotingEscrow.UpgradeToPermanentStake(_owner, _tokenId, _oldAmount, block.timestamp);
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);
    // it should call parkOnChain0 to reanchor the token shape on the voter
    // The amount is unchanged, so nothing is booked; the call re-anchors the token to the permanent shape so the
    // Voter does not keep the stale decaying expiry and reject its next gauge vote as `StaleShape`.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)));

    vm.prank(_owner);
    _ve.upgradeToPermanentStake(_tokenId);

    // it should flip the stake to permanent and zero the end
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertTrue(_staked.isPermanent);
    assertEq(_staked.end, 0);
    // it should leave the staked amount and supply unchanged
    assertEq(_staked.amount, _oldAmount);
    assertEq(_ve.supply(), _oldAmount);
    // it should bump the permanent stake balance by the staked amount
    assertEq(_ve.permanentStakeBalance(), _oldAmount);
    // it should record a user point with permanent equal to the amount
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, 0);
    assertEq(_uPoint.slope, 0);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, _oldAmount);
    // it should advance the global epoch and reflect the permanent balance
    assertEq(_ve.epoch(), 1);
    assertEq(_ve.pointHistory(1).permanentStakeBalance, _oldAmount);
    // it should match the voting-power APIs to the permanent amount
    _assertVotingPower(_oldAmount, _tokenId, _oldAmount);
    _assertGlobalPointInvariants();
  }

  function test_WhenAnApprovedOperatorTriggersTheUpgrade(
    address _operator,
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _stakingWeeks
  ) external {
    _assumeFuzzable(_operator);
    vm.assume(_operator != _owner);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, 207));
    uint48 _stakeEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_stakeEnd > block.timestamp);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _setOperatorApproval(_owner, _operator, true);

    // it should emit the UpgradeToPermanentStake event with the token owner
    _expectEmit(address(_ve));
    emit IVotingEscrow.UpgradeToPermanentStake(_owner, _tokenId, _oldAmount, block.timestamp);

    vm.prank(_operator);
    _ve.upgradeToPermanentStake(_tokenId);

    // it should flip the stake to permanent and zero the end
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertTrue(_staked.isPermanent);
    assertEq(_staked.end, 0);
    // it should leave the staked amount unchanged
    assertEq(_staked.amount, _oldAmount);
    // it should bump the permanent stake balance by the staked amount
    assertEq(_ve.permanentStakeBalance(), _oldAmount);
  }
}
