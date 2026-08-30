// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowIncreaseStakingPeriod is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(
    address _caller,
    uint256 _tokenId,
    uint48 _stakingWeeks
  ) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.increaseStakingPeriod(_tokenId, _stakingWeeks);
  }

  function test_WhenTheStakeIsPermanent(uint256 _tokenId, uint128 _oldAmount, uint48 _stakingWeeks) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);

    // it should not park anything on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 0);

    // it should revert with PermanentStake
    vm.expectRevert(IVotingEscrow.PermanentStake.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _stakingWeeks);
  }

  function test_WhenTheNewEndIsNotStrictlyLaterThanTheCurrentEnd(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _stakingWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, 10));
    _setOwner(_tokenId, _owner);
    uint48 _existingEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_existingEnd > block.timestamp);
    _setStaked(_tokenId, _oldAmount, _existingEnd, false);

    // it should revert with StakingPeriodNotInFuture
    vm.expectRevert(IVotingEscrow.StakingPeriodNotInFuture.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _stakingWeeks);
  }

  function test_WhenTheStakeHasExpiredAndTheNewEndIsInThePast(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, _DECAY_AMOUNT_CAP));
    // Warp far enough that the current week boundary lies strictly after the existing (expired) end.
    // With weeks=0 and a long-past oldEnd, the computed _stakeEnd = currentBoundary <= now,
    // which previously passed (footgun) but now reverts because _minRequired = block.timestamp.
    vm.warp(_WEEK * 10);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(_WEEK), false);

    // it should revert with StakingPeriodNotInFuture
    vm.expectRevert(IVotingEscrow.StakingPeriodNotInFuture.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, 0);
  }

  function test_WhenTheNewEndExceedsTheMaximum(uint256 _tokenId, uint128 _oldAmount, uint48 _stakingWeeks) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 210, type(uint48).max / _WEEK));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp) + _WEEK, false);

    // it should revert with StakingPeriodTooLong
    vm.expectRevert(IVotingEscrow.StakingPeriodTooLong.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _stakingWeeks);
  }

  /// @dev Boundary at `_MAXTIME / _WEEK` (= 208 weeks). MAXTIME is 1460 days ≈ 208.57 weeks, so the
  ///      week-floored stake end is `(now / WEEK) * WEEK + 208 * WEEK`. Anchor block.timestamp to a
  ///      week boundary so the resolved end fits inside `now + MAXTIME` by exactly the 4-day remainder.
  function test_WhenTheNewEndIsTheLastValidValue(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, _DECAY_AMOUNT_CAP));
    vm.warp(_WEEK);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp) + _WEEK, false);

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _MAXTIME / _WEEK);

    // it should update the stake end to the maximum allowed boundary
    uint48 _expectedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + (_MAXTIME / _WEEK) * _WEEK;
    assertEq(_ve.staked(_tokenId).end, _expectedEnd);
  }

  /// @dev Boundary at `_MAXTIME / _WEEK + 1` (= 209 weeks). One week past the last valid value: with
  ///      block.timestamp on a week boundary, the resolved end exceeds `now + MAXTIME` by the 3-day
  ///      slack remaining (week - 4 days) and the check trips.
  function test_WhenTheNewEndIsTheFirstInvalidValue(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    vm.warp(_WEEK);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp) + _WEEK, false);

    // it should revert with StakingPeriodTooLong
    vm.expectRevert(IVotingEscrow.StakingPeriodTooLong.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _MAXTIME / _WEEK + 1);
  }

  function test_WhenTheStakeHasExpiredAndTheNewEndIsInTheFuture(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _newWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, _DECAY_AMOUNT_CAP));
    _newWeeks = uint48(bound(_newWeeks, 1, _MAXTIME / _WEEK - 1));
    // Old stake expired one week ago; reviving by extending into the future.
    vm.warp(_WEEK * 10);
    uint48 _oldEnd = uint48(_WEEK * 9);
    uint48 _newEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _oldEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);

    int128 _expectedSlope = int128(_oldAmount) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_newEnd - uint48(block.timestamp)));

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    // it should update the stake end timestamp to the new end
    assertEq(_ve.staked(_tokenId).end, _newEnd);
    assertEq(_ve.staked(_tokenId).amount, _oldAmount);
    // it should restore a user point with live slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.ts, block.timestamp);
    // it should schedule a slope change at the new end
    assertEq(_ve.slopeChanges(_newEnd), -_expectedSlope);
    // it should match the voting-power APIs to the revived bias (full bias since the old end was past)
    _assertVotingPower(uint256(int256(_expectedBias)), _tokenId, uint256(int256(_expectedBias)));
    _assertGlobalPointInvariants();
  }

  function test_WhenTheStakedAmountIsZero(uint256 _tokenId, uint48 _existingEnd, uint48 _newWeeks) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _newWeeks = uint48(bound(_newWeeks, 1, _MAXTIME / _WEEK - 1));
    _existingEnd = uint48(bound(_existingEnd, 0, _WEEK * 10 - 1));
    vm.warp(_WEEK * 10);
    _setOwner(_tokenId, _owner);
    // An empty shell — withdrawn or fully drained — has no period to extend; `reviveStake` rebuilds it.
    _setStaked(_tokenId, 0, _existingEnd, false);

    // it should revert with StakeNotFunded
    vm.expectRevert(IVotingEscrow.StakeNotFunded.selector);
    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);
  }

  function test_WhenTheCallerIsAnApprovedOperator(uint256 _tokenId, uint128 _oldAmount, uint48 _newWeeks) external {
    address _operator = makeAddr('Operator');
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, _DECAY_AMOUNT_CAP));
    _newWeeks = uint48(bound(_newWeeks, 2, _MAXTIME / _WEEK - 1));
    uint48 _existingEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _WEEK;
    uint48 _newEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _existingEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _setOperatorApproval(_owner, _operator, true);

    // it should emit the Deposit event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _operator, _tokenId, IVotingEscrow.DepositType.INCREASE_STAKING_PERIOD, 0, _newEnd, block.timestamp
    );

    vm.prank(_operator);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    // it should update the stake end timestamp to the new end
    assertEq(_ve.staked(_tokenId).end, _newEnd);
    // it should not change the staked amount
    assertEq(_ve.staked(_tokenId).amount, _oldAmount);
    _assertGlobalPointInvariants();
  }

  /// @dev Independent precision check for the slope/bias rescheduling on the non-expired extension path.
  ///      Inputs are chosen so the integer decay arithmetic is exact and the expected values are literals:
  ///      - block.timestamp warped to `_WEEK` (= 604800), a clean week boundary, so `now / WEEK * WEEK == now`.
  ///      - amount = 3 * iMAXTIME = 3 * 126_144_000 = 378_432_000, so slope = amount / iMAXTIME = 3 exactly.
  ///      - old end = (1 + 10) weeks = 11 * 604800 = 6_652_800; new end = (1 + 20) weeks = 21 * 604800 = 12_700_800.
  ///      - new bias = slope * (newEnd - now) = 3 * (12_700_800 - 604_800) = 3 * 12_096_000 = 36_288_000.
  ///      - slopeChanges[newEnd] = -slope = -3; slopeChanges[oldEnd] cancels back to +slope = +3 (seeded at zero).
  function test_WhenTheNewEndIsValidUsingExactDecayArithmetic(uint256 _tokenId) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.warp(_WEEK);
    uint128 _oldAmount = 378_432_000; // 3 * iMAXTIME
    uint48 _existingEnd = 6_652_800; // 11 * _WEEK
    uint48 _newEnd = 12_700_800; // 21 * _WEEK
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _existingEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, 20);

    // it should update the stake end timestamp to the new end
    assertEq(_ve.staked(_tokenId).end, _newEnd);
    // it should record a user point with the exact recomputed slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, int128(3));
    assertEq(_uPoint.bias, int128(36_288_000));
    // it should reschedule the slope change to the new end and cancel the old end entry
    assertEq(_ve.slopeChanges(_newEnd), int128(-3));
    assertEq(_ve.slopeChanges(_existingEnd), int128(3));
    _assertGlobalPointInvariants();
  }

  function test_WhenTheNewEndIsValid(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _oldWeeks,
    uint48 _newWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _oldWeeks = uint48(bound(_oldWeeks, 1, 100));
    _newWeeks = uint48(bound(_newWeeks, _oldWeeks + 1, _MAXTIME / _WEEK - 1));
    uint48 _existingEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _oldWeeks * _WEEK;
    uint48 _newEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    vm.assume(_existingEnd > block.timestamp);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _existingEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);

    int128 _expectedSlope = int128(_oldAmount) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_newEnd - uint48(block.timestamp)));

    // it should emit the Deposit event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.INCREASE_STAKING_PERIOD, 0, _newEnd, block.timestamp
    );
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);
    // it should call parkOnChain0 to reanchor the token shape on the voter
    // The deposited value is 0, so nothing is booked; the call re-anchors the token to the new expiry so the
    // Voter does not reject its next gauge vote as `StaleShape`.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)));

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    // it should update the stake end timestamp
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.end, _newEnd);
    // it should not change the staked amount
    assertEq(_staked.amount, _oldAmount);
    assertFalse(_staked.isPermanent);
    // it should leave supply and permanent balance unchanged
    assertEq(_ve.supply(), _oldAmount);
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should record a user point with the extended bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should advance the global epoch
    assertEq(_ve.epoch(), 1);
    // it should reschedule the slope change to the new end and cancel the old end entry. The old end was
    // seeded at zero, so cancelling _uOld.slope (== _expectedSlope, amount unchanged) leaves +_expectedSlope
    // there; the new end records -_uNew.slope (== -_expectedSlope).
    assertEq(_ve.slopeChanges(_newEnd), -_expectedSlope);
    assertEq(_ve.slopeChanges(_existingEnd), _expectedSlope);
    // it should match the voting-power APIs: balanceOfNFT reflects the full recomputed bias, but
    // totalVotingPowerAt only reflects slope * (newEnd - existingEnd) because the original bias was set
    // via storage cheat (no prior checkpoint).
    int128 _deltaBias = _expectedSlope * int128(uint128(_newEnd - _existingEnd));
    _assertVotingPower(uint256(int256(_deltaBias)), _tokenId, uint256(int256(_expectedBias)));
    _assertGlobalPointInvariants();
  }

  /// @dev LAZY-expiry revival: the old end was scheduled in `slopeChanges` and a prior global point sits
  ///      BEFORE the old end, so the revival's OWN week-walk is what crosses (and consumes) the scheduled
  ///      drop. Exercises the real `_checkpoint` interaction against a realistic post-lifecycle state set up
  ///      entirely via storage cheats (no `createStake`, to keep unit isolation).
  function test_WhenRevivingPastAnOldEndTheLoopHasNotYetCrossed(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _newWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    // slope > 0 requires amount >= iMAXTIME; cap keeps the decay bias inside int128.
    _oldAmount = uint128(bound(_oldAmount, uint128(_IMAXTIME), _DECAY_AMOUNT_CAP));
    _newWeeks = uint48(bound(_newWeeks, 1, 208));

    vm.warp(5 * _WEEK);
    uint48 _oldEnd = 2 * _WEEK;
    uint48 _t0 = 1 * _WEEK;
    int128 _slope = int128(_oldAmount) / _IMAXTIME;

    // Realistic post-lifecycle state: a live stake checkpointed at _t0 with its drop scheduled at _oldEnd.
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _oldEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _setEpoch(1);
    _setPointHistory(1, _slope * int128(uint128(_oldEnd - _t0)), _slope, _t0, 0);
    _setSlopeChange(_oldEnd, -_slope);

    uint48 _newEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    int128 _newBias = _slope * int128(uint128(_newEnd - uint48(block.timestamp)));

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.end, _newEnd);
    assertEq(_staked.amount, _oldAmount);
    // it should schedule a slope change at the new end
    assertEq(_ve.slopeChanges(_newEnd), -_slope);
    // it should leave the consumed slope change at the old end intact (consumed by the walk, not re-cancelled)
    assertEq(_ve.slopeChanges(_oldEnd), -_slope);
    // it should fold only the revived contribution into the global point (no leftover, no double count)
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(_ve.epoch());
    assertEq(_point.slope, _slope);
    assertEq(_point.bias, _newBias);
    // it should match the voting power apis to the revived bias
    _assertVotingPower(uint256(int256(_newBias)), _tokenId, uint256(int256(_newBias)));
    _assertGlobalPointInvariants();
  }

  /// @dev EAGER-expiry revival: a prior checkpoint already advanced PAST the old end with the slope drop
  ///      already applied (global point at 3*WEEK with slope 0). The revival's walk starts past _oldEnd, so it
  ///      must NOT re-apply `slopeChanges[oldEnd]`. Final state must be identical to the lazy case.
  function test_WhenRevivingPastAnOldEndAPriorCheckpointAlreadyCrossed(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _newWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, uint128(_IMAXTIME), _DECAY_AMOUNT_CAP));
    _newWeeks = uint48(bound(_newWeeks, 1, 208));

    vm.warp(5 * _WEEK);
    uint48 _oldEnd = 2 * _WEEK;
    int128 _slope = int128(_oldAmount) / _IMAXTIME;

    // Prior global point sits AFTER the old end with the slope already removed (drop fully consumed earlier).
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _oldEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _setEpoch(3);
    _setPointHistory(3, 0, 0, 3 * _WEEK, 0);
    _setSlopeChange(_oldEnd, -_slope);

    uint48 _newEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    int128 _newBias = _slope * int128(uint128(_newEnd - uint48(block.timestamp)));

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.end, _newEnd);
    assertEq(_staked.amount, _oldAmount);
    // it should schedule a slope change at the new end
    assertEq(_ve.slopeChanges(_newEnd), -_slope);
    // it should not reapply the slope change at the old end (entry untouched, walk started past it)
    assertEq(_ve.slopeChanges(_oldEnd), -_slope);
    // it should fold only the revived contribution into the global point
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(_ve.epoch());
    assertEq(_point.slope, _slope);
    assertEq(_point.bias, _newBias);
    // it should match the voting power apis to the revived bias
    _assertVotingPower(uint256(int256(_newBias)), _tokenId, uint256(int256(_newBias)));
    _assertGlobalPointInvariants();
  }

  /// @dev Double revival across two real expiries. Revive once to T3 (as in the lazy case), warp past T3, then
  ///      revive again to T5. After the second revival the global slope/bias must equal ONLY the second revived
  ///      contribution — proving the first revival's scheduled drop at T3 was consumed and no stale slope change
  ///      double-applies. Driven by two sequential live calls (warps keep contract state real between them); week
  ///      gaps stay small to stay well under the 255-iteration walk cap.
  function test_WhenRevivingTwiceAcrossTwoSeparateExpiries(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint48 _newWeeks
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, uint128(_IMAXTIME), _DECAY_AMOUNT_CAP));
    // Keep both revival spans short so the week-walk between calls is cheap.
    _newWeeks = uint48(bound(_newWeeks, 1, 4));
    int128 _slope = int128(_oldAmount) / _IMAXTIME;

    // First revival: identical realistic post-lifecycle setup to the lazy case.
    vm.warp(5 * _WEEK);
    uint48 _oldEnd = 2 * _WEEK;
    uint48 _t0 = 1 * _WEEK;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _oldEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _setEpoch(1);
    _setPointHistory(1, _slope * int128(uint128(_oldEnd - _t0)), _slope, _t0, 0);
    _setSlopeChange(_oldEnd, -_slope);

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);
    uint48 _firstEnd = _ve.staked(_tokenId).end;

    // Warp past the first revived end so the second call's walk crosses (and consumes) the drop at _firstEnd.
    vm.warp(uint256(_firstEnd) + _WEEK);

    vm.prank(_owner);
    _ve.increaseStakingPeriod(_tokenId, _newWeeks);

    uint48 _secondEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _newWeeks * _WEEK;
    int128 _secondBias = _slope * int128(uint128(_secondEnd - uint48(block.timestamp)));

    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.end, _secondEnd);
    assertEq(_staked.amount, _oldAmount);
    // it should leave no stale slope change that double applies (global is exactly the second contribution)
    IVotingEscrow.GlobalPoint memory _point = _ve.pointHistory(_ve.epoch());
    assertEq(_point.slope, _slope);
    assertEq(_point.bias, _secondBias);
    assertEq(_ve.slopeChanges(_secondEnd), -_slope);
    // it should match the voting power apis to the second revived bias
    _assertVotingPower(uint256(int256(_secondBias)), _tokenId, uint256(int256(_secondBias)));
    _assertGlobalPointInvariants();
  }
}
