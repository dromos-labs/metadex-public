// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowIncreaseStakeAmount is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(
    address _caller,
    uint256 _tokenId,
    uint128 _value
  ) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, type(uint128).max));
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.increaseStakeAmount(_tokenId, _value);
  }

  function test_WhenTheValueIsZero(uint256 _tokenId) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _setOwner(_tokenId, _owner);

    // it should revert with ZeroAmount
    vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, 0);
  }

  function test_WhenTheStakeHasExpiredAndIsNotPermanent(uint256 _tokenId, uint128 _oldAmount, uint128 _value) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _value = uint128(bound(_value, 1, type(uint128).max));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp - 1), false);

    // it should not park anything on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 0);

    // it should revert with StakeExpired
    vm.expectRevert(IVotingEscrow.StakeExpired.selector);
    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);
  }

  /// @dev Drives `_oldAmount + _value > int128.max` so `_commit` trips the cap guard. The
  ///      `_oldAmount` lower bound starts at 2 so the `_value` bound below is non-empty
  ///      (`_value ∈ [int128.max - _oldAmount + 1, int128.max]`).
  function test_WhenTheResultingAmountOverflowsTheSignedLimit(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint128 _value
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 2, uint128(type(int128).max)));
    _value = uint128(bound(_value, uint128(type(int128).max) - _oldAmount + 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _mockTransferFrom(_owner, address(_ve), _value);

    // it should not park anything on the voter
    // The cap guard trips inside `_commit`, before the deposit reaches the Voter.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)), 0);

    // it should revert with AmountExceedsCap
    vm.expectRevert(IVotingEscrow.AmountExceedsCap.selector);
    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);
  }

  function test_WhenTheResultingAmountEqualsTheSignedCap(uint256 _tokenId) external {
    // type(int128).max = 170141183460469231731687303715884105727. The cap guard in `_commit` is
    // strict (`_new.amount > uint128(type(int128).max)`), so a resulting total of EXACTLY the cap
    // must succeed. Seed a permanent stake at a chosen oldAmount and top up with the exact
    // remaining headroom so oldAmount + value == cap.
    uint128 _cap = 170_141_183_460_469_231_731_687_303_715_884_105_727; // type(int128).max
    uint128 _oldAmount = 1_000_000; // arbitrary seeded permanent amount below the cap
    uint128 _value = _cap - _oldAmount; // 170141183460469231731687303715883105727

    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should set the staked amount to the cap
    assertEq(_ve.staked(_tokenId).amount, _cap);
    // it should bump supply to the cap
    assertEq(_ve.supply(), _cap);
    // it should bump the permanent stake balance to the cap
    assertEq(_ve.permanentStakeBalance(), _cap);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheStakedAmountIsZeroAndTheEndIsInTheFuture(
    uint256 _tokenId,
    uint128 _value,
    uint48 _existingEnd
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _value = uint128(bound(_value, 1, _DECAY_AMOUNT_CAP));
    _existingEnd = uint48(bound(_existingEnd, _WEEK + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, 0, _existingEnd, false);
    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should credit the value to the staked amount
    assertEq(_ve.staked(_tokenId).amount, _value);
    // it should bump supply by the value
    assertEq(_ve.supply(), _value);
    // it should keep the existing end
    assertEq(_ve.staked(_tokenId).end, _existingEnd);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheCallerIsAnApprovedOperator(uint256 _tokenId, uint128 _oldAmount, uint128 _value) external {
    address _operator = makeAddr('Operator');
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max) / 2));
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 2));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _setOperatorApproval(_owner, _operator, true);
    _mockTransferFrom(_operator, address(_ve), _value);

    // it should transfer the value from the operator
    vm.expectCall(_token, abi.encodeCall(IERC20.transferFrom, (_operator, address(_ve), _value)));

    vm.prank(_operator);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should bump the staked amount by the value
    assertEq(_ve.staked(_tokenId).amount, uint128(uint256(_oldAmount) + _value));
    _assertGlobalPointInvariants();
  }

  modifier whenTheTopUpSucceeds() {
    _;
  }

  function test_WhenTheTopUpSucceeds(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint128 _value,
    uint48 _stakingPeriod,
    bool _isPermanent
  ) external whenTheTopUpSucceeds {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max) / 2));
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 2));
    _stakingPeriod = uint48(bound(_stakingPeriod, 1 weeks, 4 * 365 days));
    uint48 _stakeEnd = _isPermanent ? uint48(0) : uint48(block.timestamp) + _stakingPeriod;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, _isPermanent);
    _setSupplyAndPermanent(_oldAmount, _isPermanent ? _oldAmount : uint128(0));
    _mockTransferFrom(_owner, address(_ve), _value);

    uint256 _newTotal = uint256(_oldAmount) + _value;

    // it should emit the Supply event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Supply(uint128(_newTotal));
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);
    // it should transfer the value from the caller
    vm.expectCall(_token, abi.encodeCall(IERC20.transferFrom, (_owner, address(_ve), _value)));
    // it should park the new voting power on the voter chain zero ledger
    // The top-up is booked onto CHAIN0 so the added voting power is immediately allocable by the Voter.
    vm.expectCall(_voter, abi.encodeCall(IVoter.parkOnChain0, (_tokenId)));

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should bump the staked amount by the value
    assertEq(_ve.staked(_tokenId).amount, uint128(_newTotal));
    // it should bump supply by the value
    assertEq(_ve.supply(), _newTotal);
    _assertGlobalPointInvariants();
  }

  function test_GivenTheStakeHasADelegatee() external whenTheTopUpSucceeds {
    uint256 _tokenId = 1;
    uint256 _delegateeId = 2;
    address _delegateeOwner = makeAddr('DelegateeOwner');
    uint128 _oldAmount = 5000;
    uint128 _value = 777;
    uint256 _existingDelegated = 1000;

    // The delegator: a permanent stake that delegates to _delegateeId.
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _setDelegate(_tokenId, _delegateeId);

    // The delegatee: an existing permanent stake with one prior checkpoint whose fromTimestamp is in
    // a past block, so the propagation creates a NEW checkpoint at index 1 rather than overwriting.
    _setOwner(_delegateeId, _delegateeOwner);
    _setNumCheckpoints(_delegateeId, 1);
    _setCheckpoint({
      _tokenId: _delegateeId,
      _index: 0,
      _fromTimestamp: block.timestamp - 1,
      _ownerAddr: _delegateeOwner,
      _delegatedBalance: _existingDelegated,
      _delegatee: 0
    });

    _mockTransferFrom(_owner, address(_ve), _value);

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should append a new delegatee checkpoint
    assertEq(_ve.numCheckpoints(_delegateeId), 2);
    // it should increase the delegatee latest checkpoint delegated balance by exactly the value
    IVotingEscrow.Checkpoint memory _cp = _ve.checkpoints(_delegateeId, 1);
    assertEq(_cp.delegatedBalance, _existingDelegated + _value); // 1000 + 777 = 1777
    assertEq(_cp.fromTimestamp, block.timestamp);
    assertEq(_cp.owner, _delegateeOwner);
    assertEq(_cp.delegatee, 0);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheStakeIsPermanent(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint128 _value
  ) external whenTheTopUpSucceeds {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max) / 2));
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 2));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);
    _setSupplyAndPermanent(_oldAmount, _oldAmount);
    _mockTransferFrom(_owner, address(_ve), _value);

    uint256 _newTotal = uint256(_oldAmount) + _value;

    // it should emit the Deposit event with zero unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.INCREASE_STAKE_AMOUNT, _value, 0, block.timestamp
    );

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should bump the permanent stake balance by the value
    assertEq(_ve.permanentStakeBalance(), _newTotal);
    // it should record a user point with permanent equal to the new total
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, 0);
    assertEq(_uPoint.slope, 0);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, _newTotal);
    // it should match the voting-power APIs to the new permanent total
    _assertVotingPower(_newTotal, _tokenId, _newTotal);
    _assertGlobalPointInvariants();
  }

  function test_WhenTheStakeIsDecayingAndNotExpired(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint128 _value,
    uint48 _stakingPeriod
  ) external whenTheTopUpSucceeds {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max) / 2));
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 2));
    _stakingPeriod = uint48(bound(_stakingPeriod, 1 weeks, 4 * 365 days));
    uint48 _stakeEnd = uint48(block.timestamp) + _stakingPeriod;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _mockTransferFrom(_owner, address(_ve), _value);

    uint256 _newTotal = uint256(_oldAmount) + _value;
    int128 _expectedSlope = int128(uint128(_newTotal)) / _IMAXTIME;
    int128 _expectedBias = _expectedSlope * int128(uint128(_stakeEnd - uint48(block.timestamp)));

    // it should emit the Deposit event with the current end as unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.INCREASE_STAKE_AMOUNT, _value, _stakeEnd, block.timestamp
    );

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should record a user point with the recomputed slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, _expectedBias);
    assertEq(_uPoint.slope, _expectedSlope);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should match the voting-power APIs: balanceOfNFT reflects the full new user-point bias,
    // but totalVotingPowerAt only reflects the (newSlope - oldSlope) * (end - now) delta because the
    // original _oldAmount was set via storage cheat (no prior checkpoint).
    int128 _oldSlope = int128(uint128(_oldAmount)) / _IMAXTIME;
    int128 _deltaBias = (_expectedSlope - _oldSlope) * int128(uint128(_stakeEnd - uint48(block.timestamp)));
    _assertVotingPower(uint256(int256(_deltaBias)), _tokenId, uint256(int256(_expectedBias)));
    _assertGlobalPointInvariants();
  }

  /// @dev Concrete decay case with hand-computed LITERAL slope/bias (independent of the contract
  ///      formula). Inputs are chosen so the integer math is EXACT:
  ///        now           = _WEEK            = 604_800 (a whole-week boundary)
  ///        end           = now + 10 weeks   = 6_652_800  => (end - now) = 6_048_000
  ///        oldAmount     = 1 * _IMAXTIME    = 126_144_000
  ///        value         = 2 * _IMAXTIME    = 252_288_000
  ///        newTotal      = 3 * _IMAXTIME    = 378_432_000
  ///      slope = newTotal / _IMAXTIME = 3 (exact, no truncation since newTotal is a clean multiple)
  ///      bias  = slope * (end - now) = 3 * 6_048_000 = 18_144_000
  ///      The pre-existing oldAmount was seeded via storage cheat with no prior checkpoint, so
  ///      totalVotingPowerAt only reflects the (newSlope - oldSlope) delta:
  ///        oldSlope   = oldAmount / _IMAXTIME = 1
  ///        deltaSlope = 3 - 1 = 2
  ///        deltaBias  = deltaSlope * (end - now) = 2 * 6_048_000 = 12_096_000
  function test_WhenTheStakeIsDecayingUsingAKnownExactExample() external whenTheTopUpSucceeds {
    uint256 _tokenId = 1;
    uint128 _oldAmount = 126_144_000; // 1 * _IMAXTIME
    uint128 _value = 252_288_000; // 2 * _IMAXTIME
    vm.warp(_WEEK); // now = 604_800
    uint48 _stakeEnd = uint48(_WEEK) + 10 * uint48(_WEEK); // 6_652_800

    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);
    _setSupplyAndPermanent(_oldAmount, 0);
    _mockTransferFrom(_owner, address(_ve), _value);

    // it should emit the Deposit event with the current end as unstake time
    _expectEmit(address(_ve));
    emit IVotingEscrow.Deposit(
      _owner, _tokenId, IVotingEscrow.DepositType.INCREASE_STAKE_AMOUNT, _value, _stakeEnd, block.timestamp
    );

    vm.prank(_owner);
    _ve.increaseStakeAmount(_tokenId, _value);

    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should record a user point with the hand-computed slope and bias
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.slope, int128(3)); // 378_432_000 / 126_144_000
    assertEq(_uPoint.bias, int128(18_144_000)); // 3 * 6_048_000
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should match the voting-power APIs: balanceOfNFT reflects the full bias (18_144_000),
    // totalVotingPowerAt reflects only the delta from the seeded slope (deltaBias = 2 * 6_048_000)
    _assertVotingPower(12_096_000, _tokenId, 18_144_000);
    _assertGlobalPointInvariants();
  }
}
