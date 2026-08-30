// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowCreateStake is BaseVotingEscrow {
  function test_WhenTheValueIsZero(uint48 _stakingWeeks, bool _isPermanent) external {
    // it should revert with ZeroAmount
    vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
    vm.prank(_owner);
    _ve.createStake(0, _stakingWeeks, _isPermanent);
  }

  function test_WhenTheStakeIsPermanentAndTheStakingPeriodIsGreaterThanZero(
    uint128 _value,
    uint48 _stakingWeeks
  ) external {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, type(uint48).max));

    // it should revert with StakingPeriodNotAllowed
    vm.expectRevert(IVotingEscrow.StakingPeriodNotAllowed.selector);
    vm.prank(_owner);
    _ve.createStake(_value, _stakingWeeks, true);
  }

  modifier whenTheStakingPeriodResolvesToTheCurrentBlockOrEarlier() {
    _;
  }

  function test_WhenCalledOnAWeekBoundary(uint128 _value)
    external
    whenTheStakingPeriodResolvesToTheCurrentBlockOrEarlier
  {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    // block.timestamp on a week boundary: stakingWeeks=0 resolves to exactly block.timestamp (now),
    // which fails the strict `_stakeEnd > _minRequired` (= now) check.
    vm.warp(_WEEK);

    // it should revert with StakingPeriodNotInFuture
    vm.expectRevert(IVotingEscrow.StakingPeriodNotInFuture.selector);
    vm.prank(_owner);
    _ve.createStake(_value, 0, false);
  }

  function test_WhenCalledMidWeek(
    uint128 _value,
    uint48 _offset
  ) external whenTheStakingPeriodResolvesToTheCurrentBlockOrEarlier {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _offset = uint48(bound(_offset, 1, _WEEK - 1));
    // block.timestamp not on a week boundary: stakingWeeks=0 resolves to the prior week boundary,
    // which is strictly earlier than now and still fails the check.
    vm.warp(_WEEK + _offset);

    // it should revert with StakingPeriodNotInFuture
    vm.expectRevert(IVotingEscrow.StakingPeriodNotInFuture.selector);
    vm.prank(_owner);
    _ve.createStake(_value, 0, false);
  }

  function test_WhenTheStakingPeriodExceedsTheMaximum(uint128 _value, uint48 _stakingWeeks) external {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 210, type(uint48).max / _WEEK));

    // it should revert with StakingPeriodTooLong
    vm.expectRevert(IVotingEscrow.StakingPeriodTooLong.selector);
    vm.prank(_owner);
    _ve.createStake(_value, _stakingWeeks, false);
  }

  /// @dev Boundary at `_MAXTIME / _WEEK` (= 208 weeks). MAXTIME is 1460 days ≈ 208.57 weeks, so the
  ///      week-floored stake end is `(now / WEEK) * WEEK + 208 * WEEK`. Anchor block.timestamp to a
  ///      week boundary so the resolved end fits inside `now + MAXTIME` by exactly the 4-day remainder.
  function test_WhenTheStakingPeriodIsTheLastValidValue(uint128 _value) external {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    vm.warp(_WEEK);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, _MAXTIME / _WEEK, false);

    // it should set the staked balance with the end at the maximum allowed boundary
    uint48 _expectedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + (_MAXTIME / _WEEK) * _WEEK;
    assertEq(_ve.staked(_tokenId).end, _expectedEnd);
  }

  /// @dev Boundary at `_MAXTIME / _WEEK + 1` (= 209 weeks). One week past the last valid value: with
  ///      block.timestamp on a week boundary, the resolved end exceeds `now + MAXTIME` by the 3-day
  ///      slack remaining (week - 4 days) and the check trips.
  function test_WhenTheStakingPeriodIsTheFirstInvalidValue(uint128 _value) external {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    vm.warp(_WEEK);

    // it should revert with StakingPeriodTooLong
    vm.expectRevert(IVotingEscrow.StakingPeriodTooLong.selector);
    vm.prank(_owner);
    _ve.createStake(_value, _MAXTIME / _WEEK + 1, false);
  }

  function test_WhenTheValueExceedsTheSignedCap(uint48 _stakingWeeks, bool _isPermanent) external {
    _stakingWeeks = _isPermanent ? 0 : uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    uint128 _firstInvalid = uint128(type(int128).max) + 1;

    // it should not park anything on the voter
    // The cap guard trips inside `_commit`, before the deposit reaches the Voter, so the would-be tokenId
    // (counter starts at 0, so 1) is never parked.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (1)), 0);

    // it should revert with AmountExceedsCap
    vm.expectRevert(IVotingEscrow.AmountExceedsCap.selector);
    vm.prank(_owner);
    _ve.createStake(_firstInvalid, _stakingWeeks, _isPermanent);
  }

  /// @dev Boundary mirror of the cap-revert test. The `_commit` guard is `_new.amount > uint128(type(int128).max)`
  ///      (strict), so `amount == cap` must SUCCEED. A permanent stake is used so there is no decay bias to overflow:
  ///      `bias = slope * (end - now)` is skipped entirely (slope/bias stay zero) and the cap amount only flows into
  ///      `supply` and `permanentStakeBalance`. The cap literal is `type(int128).max = 170141183460469231731687303715884105727`.
  function test_WhenTheValueEqualsTheSignedCap() external {
    uint128 _cap = uint128(type(int128).max); // 170141183460469231731687303715884105727
    _mockTransferFrom(_owner, address(_ve), _cap);

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_cap, 0, true);

    // it should set the staked balance at the cap amount
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, 170_141_183_460_469_231_731_687_303_715_884_105_727);
    assertTrue(_staked.isPermanent);
    // it should bump supply to the cap
    assertEq(_ve.supply(), 170_141_183_460_469_231_731_687_303_715_884_105_727);
    // it should bump the permanent stake balance to the cap
    assertEq(_ve.permanentStakeBalance(), 170_141_183_460_469_231_731_687_303_715_884_105_727);
    _assertGlobalPointInvariants();
  }

  modifier whenTheDepositSucceeds() {
    _;
  }

  function test_WhenTheDepositSucceeds(
    uint128 _value,
    uint48 _stakingWeeks,
    uint256 _priorCounter,
    bool _isPermanent
  ) external whenTheDepositSucceeds {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _stakingWeeks = _isPermanent ? 0 : uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    _priorCounter = bound(_priorCounter, 0, type(uint64).max);
    uint48 _resolvedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_isPermanent || (_resolvedEnd > block.timestamp && _resolvedEnd <= block.timestamp + _MAXTIME));
    _setTokenIdCounter(_priorCounter);
    _mockTransferFrom(_owner, address(_ve), _value);

    // it should emit the Supply event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Supply(_value);
    // it should transfer the value from the caller
    vm.expectCall(_token, abi.encodeCall(IERC20.transferFrom, (_owner, address(_ve), _value)));
    // it should park the new voting power on the voter chain zero ledger
    // The fresh voting power is booked onto CHAIN0 so it is immediately allocable by the Voter.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_priorCounter + 1)));

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, _stakingWeeks, _isPermanent);

    // it should increment the token id counter and mint to the caller
    assertEq(_tokenId, _priorCounter + 1);
    assertEq(_ve.tokenId(), _priorCounter + 1);
    assertEq(_ve.ownerOf(_tokenId), _owner);
    // it should append the minted token to the owner enumeration
    assertEq(_ve.balanceOf(_owner), 1);
    assertEq(_ve.tokenOfOwnerByIndex(_owner, 0), _tokenId);
    // it should append the minted token to the global enumeration
    assertEq(_ve.totalSupply(), 1);
    assertEq(_ve.tokenByIndex(0), _tokenId);
    // it should bump supply by the value
    assertEq(_ve.supply(), _value);
    // it should advance the global epoch
    assertEq(_ve.epoch(), 1);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheStakeIsDecaying(
    uint128 _value,
    uint48 _stakingWeeks,
    uint256 _priorCounter
  ) external whenTheDepositSucceeds {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    _priorCounter = bound(_priorCounter, 0, type(uint64).max);
    uint48 _expectedEnd = (uint48(block.timestamp) / _WEEK) * _WEEK + _stakingWeeks * _WEEK;
    vm.assume(_expectedEnd > block.timestamp);
    vm.assume(_expectedEnd <= block.timestamp + _MAXTIME);
    _setTokenIdCounter(_priorCounter);
    _mockTransferFrom(_owner, address(_ve), _value);

    int128 _expectedSlope = int128(_value) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_expectedEnd - uint48(block.timestamp)));

    // it should emit the Deposit event with the computed end as unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _priorCounter + 1, IVotingEscrow.DepositType.CREATE_STAKE_TYPE, _value, _expectedEnd, block.timestamp
    );

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, _stakingWeeks, false);

    // it should set the staked balance with the computed end
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, _value);
    assertEq(_staked.end, _expectedEnd);
    assertFalse(_staked.isPermanent);
    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should write a user point with the decaying slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should match the voting-power APIs to the computed bias
    _assertVotingPower(uint256(int256(_expectedBias)), _tokenId, uint256(int256(_expectedBias)));
    // it should schedule a negative slope change at the computed end
    assertEq(_ve.slopeChanges(_expectedEnd), -_expectedSlope);
    _assertGlobalPointInvariants();
    // it should decay to zero voting power at the computed end
    vm.warp(_expectedEnd);
    assertEq(_ve.balanceOfNFTAt(_tokenId, _expectedEnd), 0);
  }

  /// @dev Concrete decay precision case. `_IMAXTIME = 126_144_000`. Choosing `value = 2 * _IMAXTIME =
  ///      252_288_000` makes `slope = value / _IMAXTIME = 2` exactly (no truncation). Anchoring `now` to
  ///      a week boundary (`now = _WEEK`) and staking `10` whole weeks gives
  ///      `end = (1 + 10) * _WEEK = 11 * 604_800 = 6_652_800` and `end - now = 10 * 604_800 = 6_048_000`,
  ///      so `bias = slope * (end - now) = 2 * 6_048_000 = 12_096_000`. Mid-life at `now + 5 weeks`
  ///      (`t = 6 * _WEEK = 3_628_800`) gives `bias - slope * (t - now) = 12_096_000 - 2 * 3_024_000 =
  ///      6_048_000`, and at `end` it reaches `12_096_000 - 2 * 6_048_000 = 0`.
  function test_WhenUsingAKnownDecayExample() external whenTheDepositSucceeds {
    uint128 _value = 252_288_000; // 2 * _IMAXTIME
    uint48 _stakingWeeks = 10;
    vm.warp(_WEEK);
    _setTokenIdCounter(0);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, _stakingWeeks, false);

    uint48 _expectedEnd = 6_652_800; // 11 * 604_800

    // it should write a user point with the hand-computed slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, 2);
    assertEq(_uPoint.bias, 12_096_000);
    assertEq(_uPoint.ts, _WEEK);
    assertEq(_uPoint.permanent, 0);
    // it should set the staked balance with the hand-computed end
    assertEq(_ve.staked(_tokenId).end, _expectedEnd);
    // it should report the hand-computed voting power at creation
    _assertVotingPower(12_096_000, _tokenId, 12_096_000);
    // it should report half the voting power at mid life
    assertEq(_ve.balanceOfNFTAt(_tokenId, 6 * _WEEK), 6_048_000); // now + 5 weeks
    // it should report zero voting power at the end
    assertEq(_ve.balanceOfNFTAt(_tokenId, _expectedEnd), 0);
    // it should schedule the negative slope change at the end
    assertEq(_ve.slopeChanges(_expectedEnd), -2);
    _assertGlobalPointInvariants();
  }

  /// @dev Dust decay stake. `slope = value / _IMAXTIME` truncates to zero for any `value < _IMAXTIME = 126_144_000`.
  ///      With `value = 1000` the slope floors to `1000 / 126_144_000 = 0`, so `bias = slope * (end - now) = 0` too.
  ///      Anchoring `now = _WEEK` and staking one week gives `end = (1 + 1) * _WEEK = 2 * 604_800 = 1_209_600`. The
  ///      stake is funded (amount/supply = 1000) yet carries zero voting power, and because the new slope is zero it
  ///      schedules NO slope change at the end (`slopeChanges[end] -= 0`).
  function test_WhenTheDecayingValueIsBelowOneSlopeUnit() external whenTheDepositSucceeds {
    uint128 _value = 1000; // < _IMAXTIME, so slope = value / _IMAXTIME = 0
    vm.warp(_WEEK);
    _setTokenIdCounter(0);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, 1, false);

    uint48 _expectedEnd = 1_209_600; // 2 * 604_800

    // it should set the staked balance with the nonzero amount
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, 1000);
    assertEq(_staked.end, _expectedEnd);
    assertFalse(_staked.isPermanent);
    // it should bump supply by the value
    assertEq(_ve.supply(), 1000);
    // it should write a user point with zero slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, 0);
    assertEq(_uPoint.bias, 0);
    assertEq(_uPoint.permanent, 0);
    // it should report zero voting power despite the funded stake
    _assertVotingPower(0, _tokenId, 0);
    // it should schedule no slope change at the end
    assertEq(_ve.slopeChanges(_expectedEnd), 0);
    _assertGlobalPointInvariants();
  }

  /// @dev Mid-week end alignment. `_computeStakeEnd` floors to the week boundary:
  ///      `end = (now / _WEEK) * _WEEK + stakingWeeks * _WEEK`. Warping to `now = 864_000` (= _WEEK + 3 days =
  ///      604_800 + 259_200, NOT week-aligned) and staking two weeks gives
  ///      `end = (864_000 / 604_800) * 604_800 + 2 * 604_800 = 604_800 + 1_209_600 = 1_814_400`. The 259_200-second
  ///      remainder is dropped by the floor.
  function test_WhenCalledMidWeekWithAValidPeriod() external whenTheDepositSucceeds {
    uint128 _value = 252_288_000; // 2 * _IMAXTIME, a clean nonzero decay amount
    vm.warp(864_000); // _WEEK + 3 days, not week-aligned
    _setTokenIdCounter(0);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, 2, false);

    // it should floor the staked end to the week boundary
    assertEq(_ve.staked(_tokenId).end, 1_814_400); // 604_800 + 2 * 604_800
  }

  function test_WhenTheStakeIsPermanent(uint128 _value, uint256 _priorCounter) external whenTheDepositSucceeds {
    _value = uint128(bound(_value, 1, uint128(type(int128).max)));
    _priorCounter = bound(_priorCounter, 0, type(uint64).max);
    _setTokenIdCounter(_priorCounter);
    _mockTransferFrom(_owner, address(_ve), _value);

    // it should emit the Deposit event with zero unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _priorCounter + 1, IVotingEscrow.DepositType.CREATE_STAKE_TYPE, _value, 0, block.timestamp
    );

    vm.prank(_owner);
    uint256 _tokenId = _ve.createStake(_value, 0, true);

    // it should set the staked balance as permanent with zero end
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, _value);
    assertEq(_staked.end, 0);
    assertTrue(_staked.isPermanent);
    // it should bump the permanent stake balance by the value
    assertEq(_ve.permanentStakeBalance(), _value);
    // it should write a user point with permanent equal to the amount
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, 0);
    assertEq(_uPoint.slope, 0);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, _value);
    // it should match the voting-power APIs to the staked amount
    _assertVotingPower(_value, _tokenId, _value);
    _assertGlobalPointInvariants();
  }
}
