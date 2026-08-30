// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowReviveStake is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(
    address _caller,
    uint256 _tokenId,
    uint128 _value
  ) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.reviveStake(_tokenId, _value, 1, false);
  }

  function test_WhenTheValueIsZero(uint256 _tokenId, uint48 _stakingWeeks, bool _isPermanent) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _setOwner(_tokenId, _owner);

    // it should revert with ZeroAmount
    vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
    vm.prank(_owner);
    _ve.reviveStake(_tokenId, 0, _stakingWeeks, _isPermanent);
  }

  function test_WhenTheRevivedStakeIsPermanentAndTheStakingPeriodIsGreaterThanZero(
    uint256 _tokenId,
    uint128 _value,
    uint48 _stakingWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, type(uint48).max));
    _setOwner(_tokenId, _owner);

    // it should revert with StakingPeriodNotAllowed
    vm.expectRevert(IVotingEscrow.StakingPeriodNotAllowed.selector);
    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, _stakingWeeks, true);
  }

  function test_WhenTheTokenStillHoldsAFundedStake(uint256 _tokenId, uint128 _value, uint128 _fundedAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _fundedAmount = uint128(bound(_fundedAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    // A live funded position: revival must reject it whatever its end, funded stakes move through the
    // increase and upgrade paths.
    _setStaked(_tokenId, _fundedAmount, uint48(block.timestamp) + _WEEK, false);

    // it should revert with StakeAlreadyFunded
    vm.expectRevert(IVotingEscrow.StakeAlreadyFunded.selector);
    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, 1, false);
  }

  function test_WhenTheShellIsPermanent(uint256 _tokenId, uint128 _value) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    // A fully drained permanent shell keeps its permanence; it never expires, so it cannot be rebuilt here.
    _setStaked(_tokenId, 0, 0, true);

    // it should revert with PermanentStake
    vm.expectRevert(IVotingEscrow.PermanentStake.selector);
    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, 0, true);
  }

  function test_WhenTheShellEndIsStillInTheFuture(uint256 _tokenId, uint128 _value, uint48 _remaining) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _remaining = uint48(bound(_remaining, 1, _MAXTIME));
    vm.warp(_WEEK * 10);
    _setOwner(_tokenId, _owner);
    // A fully drained shell whose end has not passed keeps its committed window; it re-funds through
    // increaseStakeAmount at its own shape instead.
    _setStaked(_tokenId, 0, uint48(block.timestamp) + _remaining, false);

    // it should revert with StakeNotExpired
    vm.expectRevert(IVotingEscrow.StakeNotExpired.selector);
    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, 1, false);
  }

  function test_WhenRevivingAWithdrawnTokenWithADecayingStake(
    uint256 _tokenId,
    uint128 _value,
    uint48 _stakingWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, _DECAY_AMOUNT_CAP));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    uint48 _expectedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_expectedEnd > block.timestamp);
    vm.assume(_expectedEnd <= block.timestamp + _MAXTIME);
    _setOwner(_tokenId, _owner);
    // Withdraw leaves the cleared shell `{amount: 0, end: 0, isPermanent: false}`.
    _setStaked(_tokenId, 0, 0, false);
    _mockTransferFrom(_owner, address(_ve), _value);

    int128 _expectedSlope = int128(_value) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_expectedEnd - uint48(block.timestamp)));

    // it should call parkOnChain0 on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 1);

    // it should emit the Deposit event with the computed end as unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.REVIVE_STAKE_TYPE, _value, _expectedEnd, block.timestamp
    );

    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, _stakingWeeks, false);

    // it should set the staked balance with the computed end
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, _value);
    assertEq(_staked.end, _expectedEnd);
    assertFalse(_staked.isPermanent);
    // it should write a user point with the decaying slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.ts, block.timestamp);
    // it should schedule a negative slope change at the computed end
    assertEq(_ve.slopeChanges(_expectedEnd), -_expectedSlope);
    _assertVotingPower(uint256(int256(_expectedBias)), _tokenId, uint256(int256(_expectedBias)));
    _assertGlobalPointInvariants();
  }

  function test_WhenRevivingAWithdrawnTokenWithAPermanentStake(uint256 _tokenId, uint128 _value) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, 0, 0, false);
    _mockTransferFrom(_owner, address(_ve), _value);

    // it should emit the Deposit event with a zero unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.REVIVE_STAKE_TYPE, _value, 0, block.timestamp
    );

    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, 0, true);

    // it should set the staked balance as permanent
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, _value);
    assertEq(_staked.end, 0);
    assertTrue(_staked.isPermanent);
    // it should increase the permanent stake balance by the value
    assertEq(_ve.permanentStakeBalance(), _value);
    _assertGlobalPointInvariants();
  }

  function test_WhenRevivingADrainedShellWhoseEndHasPassed(
    uint256 _tokenId,
    uint128 _value,
    uint48 _stakingWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, _DECAY_AMOUNT_CAP));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    // A rebalance drained the token to zero at a decaying shape; its end has since passed.
    vm.warp(_WEEK * 10);
    uint48 _expectedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, 0, uint48(_WEEK * 9), false);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    _ve.reviveStake(_tokenId, _value, _stakingWeeks, false);

    // it should overwrite the expired end with the computed one
    assertEq(_ve.staked(_tokenId).end, _expectedEnd);
    // it should set the staked balance to the new value
    assertEq(_ve.staked(_tokenId).amount, _value);
    _assertGlobalPointInvariants();
  }
}
