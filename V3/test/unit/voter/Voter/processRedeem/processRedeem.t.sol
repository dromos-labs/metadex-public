// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseVoter, IMinter, IVoter, IVoterCommon} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterProcessRedeem is BaseVoter {
  function test_WhenTheCallerIsNotTheOrchestrator(
    address _caller,
    uint256 _chainId,
    uint256 _amount,
    address _recipient,
    uint256 _surplusAccrued
  ) external {
    _caller = _boundNotEq(_caller, _ORCHESTRATOR);

    // it should revert with NotAuthorized
    vm.expectRevert(IVoter.NotAuthorized.selector);
    vm.prank(_caller);
    _voter.processRedeem(_chainId, _amount, _recipient, _surplusAccrued);
  }

  modifier givenTheCallerIsTheOrchestrator() {
    vm.startPrank(_ORCHESTRATOR);
    _;
    vm.stopPrank();
  }

  function test_WhenTheOriginChainIsNotRegistered(
    uint256 _amount,
    address _recipient,
    uint256 _surplusAccrued
  ) external givenTheCallerIsTheOrchestrator {
    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _UNREGISTERED_CHAIN_ID));
    _voter.processRedeem(_UNREGISTERED_CHAIN_ID, _amount, _recipient, _surplusAccrued);
  }

  function test_WhenTheOriginChainIsPaused(
    uint128 _amount,
    address _recipient,
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external givenTheCallerIsTheOrchestrator {
    // Inbound Leaf→Root processing keeps running while a chain is Paused, since it does not
    // dispatch back to the paused Leaf. The stored ceiling advances at the stored emissions per VP up
    // to now (the catch-up the Pause spec calls out), and the redeem mints normally.
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 0, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // Permanent chain point (weight == _ONE_AERO == PRECISION) so the accrual is exactly the index delta,
    // i.e. `emissionsPerVP * elapsed`.
    uint256 _accrual = uint256(_emissionsPerVP) * _elapsed;
    // Headroom keeps the redeem below the post-settle ceiling regardless of _amount.
    uint256 _initialCeiling = uint256(_amount) + _accrual + 1 ether;

    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    // Pending accrual is seeded on the global accumulator; the chain's cursor sits at the current index.
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (uint256(_amount), _recipient)), '');

    // it should emit RedeemProcessed
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should advance the chain ceiling at the sampled emissions per VP
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling + _accrual);
    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
  }

  function test_WhenTheOriginChainIsSuspended(
    uint128 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // Redeem mints on root, so a Suspended (possibly compromised) origin is rejected before any accounting.
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);

    // it should revert with RouteSuspended
    vm.expectRevert(IVoter.RouteSuspended.selector);
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);
  }

  function test_WhenTheOriginChainIsSunset(
    uint128 _amount,
    address _recipient,
    uint128 _emissionsPerVP,
    uint48 _elapsed
  ) external givenTheCallerIsTheOrchestrator {
    // A sunset origin keeps redeeming against its frozen ceiling: the settle routes the elapsed accrual to
    // cumulativeSuspendedSurplus instead of the ceiling, and the redeem mints normally.
    _amount = uint128(bound(_amount, 1, type(uint128).max));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 0, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // Permanent chain point (weight == _ONE_AERO == PRECISION) so the accrual is exactly the index delta,
    // i.e. `emissionsPerVP * elapsed`.
    uint256 _accrual = uint256(_emissionsPerVP) * _elapsed;
    // Headroom keeps the redeem below the FROZEN ceiling, which no longer accrues.
    uint256 _initialCeiling = uint256(_amount) + 1 ether;

    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    // Pending accrual is seeded on the global accumulator; the chain's cursor sits at the current index.
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (uint256(_amount), _recipient)), '');

    // it should emit RedeemProcessed
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should accrue cumulativeSuspendedSurplus at the sampled emissions per VP
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, _accrual);
    // it should leave the ceiling unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling);
    // it should anchor the chain ceiling cursor at the advanced index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
  }

  modifier givenTheRedeemStaysWithinTheCeiling() {
    // Ample headroom so the solvency check always passes for the within-ceiling branch. The global
    // accumulator is current as of now, so the settle finds a zero delta and the ceiling stays put.
    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockChainCeiling(_CHAIN_ID_1, type(uint256).max);
    _;
  }

  function test_WhenTheReportedSurplusIsGreaterThanTheSurplusAlreadyReported(
    uint256 _existingSurplus,
    uint256 _surplusAccrued,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator givenTheRedeemStaysWithinTheCeiling {
    // Full range above zero (a zero amount mints nothing): the reported surplus (the new accumulator) plus
    // _amount must not overflow the solvency sum.
    _existingSurplus = bound(_existingSurplus, 0, type(uint256).max - 2);
    _surplusAccrued = bound(_surplusAccrued, _existingSurplus + 1, type(uint256).max - 1);
    _amount = bound(_amount, 1, type(uint256).max - _surplusAccrued);

    _mockSurplusAlreadyReported(_CHAIN_ID_1, _existingSurplus);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should emit RedeemProcessed with _chainId, _recipient, _amount and _surplusReported
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _surplusAccrued);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    // it should advance the surplus already reported to _surplusAccrued
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _surplusAccrued);
    // it should advance the global last settlement to the current timestamp
    assertEq(_voter.lastGlobalSettlement(), uint48(block.timestamp));
  }

  function test_WhenTheReportedSurplusIsNotGreaterThanTheSurplusAlreadyReported(
    uint256 _existingSurplus,
    uint256 _surplusAccrued,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator givenTheRedeemStaysWithinTheCeiling {
    // Full range above zero (a zero amount mints nothing): the stored surplus (the unchanged accumulator) plus
    // _amount must not overflow the solvency sum.
    _existingSurplus = bound(_existingSurplus, 1, type(uint256).max - 1);
    _surplusAccrued = bound(_surplusAccrued, 0, _existingSurplus);
    _amount = bound(_amount, 1, type(uint256).max - _existingSurplus);

    _mockSurplusAlreadyReported(_CHAIN_ID_1, _existingSurplus);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should emit RedeemProcessed with _chainId, _recipient, _amount and _surplusReported
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _existingSurplus);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    // it should leave the surplus already reported unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _existingSurplus);
  }

  function test_WhenTheSameSurplusIsReportedAgainOnALaterRedeem(
    uint256 _surplusAccrued,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator givenTheRedeemStaysWithinTheCeiling {
    // Full range above zero (a zero amount mints nothing): the redeem runs twice, so the surplus plus both
    // _amount increments must not overflow the sum.
    _surplusAccrued = bound(_surplusAccrued, 0, type(uint256).max - 2);
    _amount = bound(_amount, 1, (type(uint256).max - _surplusAccrued) / 2);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should emit RedeemProcessed with _chainId, _recipient, _amount and _surplusReported on each redeem
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _surplusAccrued);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _surplusAccrued);

    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _surplusAccrued);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    // it should leave the surplus already reported unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _surplusAccrued);
  }

  function test_WhenMultipleRedeemsAreProcessed(
    uint256 _firstAmount,
    uint256 _secondAmount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator givenTheRedeemStaysWithinTheCeiling {
    // Full range above zero (a zero amount mints nothing): both redeems accrue into totalRedeemed, so their
    // sum must not overflow the solvency check.
    _firstAmount = bound(_firstAmount, 1, type(uint256).max - 1);
    _secondAmount = bound(_secondAmount, 1, type(uint256).max - _firstAmount);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_firstAmount, _recipient)), '');
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_secondAmount, _recipient)), '');

    // it should emit RedeemProcessed with _chainId, _recipient, _amount and _surplusReported on each redeem
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _firstAmount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _firstAmount, _recipient, 0);
    uint256 _afterFirst = _chainState(_voter, _CHAIN_ID_1).totalRedeemed;
    assertEq(_afterFirst, _firstAmount);

    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _secondAmount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _secondAmount, _recipient, 0);

    // it should only increase total redeemed
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _afterFirst + _secondAmount);
    assertGe(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _afterFirst);
  }

  function test_WhenTheRedeemWouldExceedTheCeiling(
    uint256 _surplusAccrued,
    uint256 _totalRedeemed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // Full range: bound each term against the remaining headroom so the three-term required sum never overflows.
    _surplusAccrued = bound(_surplusAccrued, 0, type(uint256).max - 1);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint256).max - 1 - _surplusAccrued);
    _amount = bound(_amount, 1, type(uint256).max - _surplusAccrued - _totalRedeemed);

    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    // the surplus max rule advances reportedSurplus to _surplusAccrued before the solvency check, so the
    // required headroom is _surplusAccrued + _totalRedeemed + _amount; set the ceiling one wei below it to overflow
    uint256 _required = _surplusAccrued + _totalRedeemed + _amount;
    _mockChainCeiling(_CHAIN_ID_1, _required - 1);

    // it should revert with CeilingExceeded
    vm.expectRevert(IVoter.CeilingExceeded.selector);
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);
  }

  function test_WhenTheSurplusAlreadyReportedWouldExceedTheCeiling(
    uint256 _storedSurplus,
    uint256 _surplusAccrued,
    uint256 _totalRedeemed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The stored surplus is at least the freshly reported one, so the max rule keeps reportedSurplus as the
    // surplus term that drives the breach. Full range: bound each term against the remaining headroom.
    _storedSurplus = bound(_storedSurplus, 1, type(uint256).max - 1);
    _surplusAccrued = bound(_surplusAccrued, 0, _storedSurplus);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint256).max - 1 - _storedSurplus);
    _amount = bound(_amount, 1, type(uint256).max - _storedSurplus - _totalRedeemed);

    _mockSurplusAlreadyReported(_CHAIN_ID_1, _storedSurplus);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    // the max rule keeps reportedSurplus, so the required headroom is _storedSurplus + _totalRedeemed +
    // _amount; set the ceiling one wei below it to overflow
    uint256 _required = _storedSurplus + _totalRedeemed + _amount;
    _mockChainCeiling(_CHAIN_ID_1, _required - 1);

    // it should revert with CeilingExceeded
    vm.expectRevert(IVoter.CeilingExceeded.selector);
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);
  }

  function test_WhenTheRedeemExactlyMeetsTheCeiling(
    uint256 _surplusAccrued,
    uint256 _totalRedeemed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // Full range: bound each term against the remaining headroom so the three-term required sum never overflows.
    _surplusAccrued = bound(_surplusAccrued, 0, type(uint256).max - 1);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint256).max - 1 - _surplusAccrued);
    _amount = bound(_amount, 1, type(uint256).max - _surplusAccrued - _totalRedeemed);

    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    // ceiling sits exactly at the required headroom: the passing side of the solvency boundary
    _mockChainCeiling(_CHAIN_ID_1, _surplusAccrued + _totalRedeemed + _amount);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should emit RedeemProcessed with _chainId, _recipient, _amount and _surplusReported
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _surplusAccrued);

    // it should process the redeem at the solvency boundary
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _totalRedeemed + _amount);
  }

  function test_WhenTheRedeemExceedsTheCeilingAndTheBufferCoversTheShortfall(
    uint256 _headroom,
    uint256 _shortfall,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // Both legs stay real: the headroom leg is mintable (at or above the Minter minimum, so the sub-minimum
    // reroute stays off), the buffer covers at least the shortfall, and the solvency sum never overflows.
    _headroom = bound(_headroom, _MIN_MINT_AMOUNT, type(uint256).max / 2);
    _shortfall = bound(_shortfall, 1, type(uint256).max / 2);
    _buffer = bound(_buffer, _shortfall, type(uint256).max - _headroom);
    uint256 _amount = _headroom + _shortfall;

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _headroom);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint the ceiling headroom to the recipient
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_headroom, _recipient)), '');
    // it should transfer the shortfall to the recipient
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _shortfall);

    // it should emit BufferDrawn with the shortfall
    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _shortfall);
    // it should emit RedeemProcessed with the full amount
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should decrease the donated buffer by the shortfall
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer - _shortfall);
    // The packed chain state reports the same buffer as the standalone getter.
    assertEq(_chainState(_voter, _CHAIN_ID_1).donatedBuffer, _buffer - _shortfall);
    // it should charge only the minted part to total redeemed
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _headroom);
  }

  function test_WhenTheCeilingIsExhaustedAndTheBufferCoversTheRedeem(
    uint256 _ceiling,
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The ceiling is fully consumed by prior redeems, so the whole amount draws on the buffer.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 2);
    _amount = bound(_amount, 1, type(uint256).max / 2);
    _buffer = bound(_buffer, _amount, type(uint256).max - _ceiling);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockTotalRedeemed(_CHAIN_ID_1, _ceiling);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint nothing
    vm.expectCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), 0);
    // it should transfer the full amount to the recipient
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _amount);

    // it should emit BufferDrawn with the full amount
    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _amount);
    // it should emit RedeemProcessed with the full amount
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, 0);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should decrease the donated buffer by the full amount
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer - _amount);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _ceiling);
  }

  function test_WhenTheReportedSurplusExceedsTheCeilingAndTheBufferCoversTheRedeem(
    uint256 _ceiling,
    uint256 _surplusAccrued,
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The fresh surplus report alone overruns the ceiling, so the mint headroom is zero and the donated
    // buffer pays the whole redeem. The report is still stored as the high water mark even above the
    // chain's mint entitlement, and `spendableSurplus` clamps it back so the excess never mints.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 4 - 1);
    _surplusAccrued = bound(_surplusAccrued, _ceiling + 1, type(uint256).max / 4);
    _amount = bound(_amount, 1, type(uint256).max / 4);
    _buffer = bound(_buffer, _surplusAccrued - _ceiling + _amount, type(uint256).max / 2);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint nothing
    vm.expectCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), 0);
    // it should transfer the full amount to the recipient
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _amount);

    // it should emit BufferDrawn with the full amount
    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _amount);
    // it should emit RedeemProcessed with the full amount
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _surplusAccrued);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    // it should decrease the donated buffer by the full amount
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer - _amount);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 0);
    // it should store the advanced surplus report
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _surplusAccrued);
  }

  /// @notice Regression for the solvency gate charging the stored report excess against the buffer. A report
  ///         stored above the ceiling (a Sunset chain that kept accruing) made the old gate reserve
  ///         `_reserved - _ceiling` from the buffer on every later redeem, stranding donations the payout
  ///         never touched. The gate now checks only the actual buffer draw.
  function test_WhenTheSurplusAlreadyReportedExceedsTheCeilingAndTheBufferCoversTheRedeem(
    uint256 _ceiling,
    uint256 _excess,
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The stored surplus alone overruns the ceiling, so the mint headroom is zero and the buffer pays the
    // whole redeem. The buffer covers the amount but not the amount plus the report excess, which is exactly
    // the range the old gate wrongly bounced.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 4);
    _excess = bound(_excess, 1, type(uint256).max / 4);
    _amount = bound(_amount, 1, type(uint256).max / 4);
    _buffer = bound(_buffer, _amount, _amount + _excess - 1);
    uint256 _storedSurplus = _ceiling + _excess;

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _storedSurplus);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint nothing
    vm.expectCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), 0);
    // it should transfer the full amount to the recipient
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _amount);

    // it should emit BufferDrawn with the full amount
    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _amount);
    // it should emit RedeemProcessed with the full amount
    _expectEmit(address(_voter));
    emit IVoter.RedeemProcessed(_CHAIN_ID_1, _recipient, _amount, _storedSurplus);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should decrease the donated buffer by the full amount
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer - _amount);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 0);
    // it should leave the surplus already reported unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _storedSurplus);
  }

  /// @notice Regression for the audited double spend where a surplus report accepted only because donations
  ///         stood behind it could be minted in full by `spendSurplus` while the backing donation stayed in
  ///         the buffer, payable again. The redeem now clears from the buffer and the report is stored above
  ///         the entitlement, but `spendableSurplus` clamps the pot back to `ceiling - totalRedeemed` so the
  ///         buffer backed excess can never become a mint.
  function test_WhenReplayingTheAuditedBufferBackedSurplusDoubleSpendScenario(address _recipient)
    external
    givenTheCallerIsTheOrchestrator
  {
    // Chain at ceiling 1000 with 600 redeemed and 300 surplus reported leaves a mint entitlement of 400.
    // The leaf over-accrues to 500 and a 150 redeem arrives with a 400 donation standing behind it. The
    // gate passes (500 + 600 + 150 <= 1000 + 400), the buffer pays the 150 in full, and reportedSurplus
    // is stored at 500, 100 above the entitlement. The clamp keeps the spendable pot at 400.
    uint256 _ceiling = 1000 ether;
    uint256 _totalRedeemed = 600 ether;
    uint256 _storedSurplus = 300 ether;
    uint256 _surplusAccrued = 500 ether;
    uint256 _buffer = 400 ether;
    uint256 _amount = 150 ether;

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _storedSurplus);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should pay the redeem from the buffer
    vm.expectCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), 0);
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _amount);

    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _amount);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), 250 ether);
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 600 ether);
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, 500 ether);

    // it should clamp the spendable surplus to the remaining mint entitlement
    assertEq(_voter.spendableSurplus(_CHAIN_ID_1), 400 ether);
  }

  function test_WhenTheRedeemExceedsTheCeilingPlusTheBuffer(
    uint256 _ceiling,
    uint256 _buffer,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // Full range: the amount lands one past what ceiling plus buffer can cover, so the redeem bounces.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 2 - 1);
    _buffer = bound(_buffer, 0, type(uint256).max / 2 - 1);
    _amount = bound(_amount, _ceiling + _buffer + 1, type(uint256).max);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should revert with CeilingExceeded
    vm.expectRevert(IVoter.CeilingExceeded.selector);
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);
  }

  function test_WhenTheRedeemStaysWithinTheCeilingWithADonatedBuffer(
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The ceiling alone covers a leaf-valid amount (at or above the Minter minimum, so the sub-minimum
    // reroute stays off), so the buffer never moves.
    _amount = bound(_amount, _MIN_MINT_AMOUNT, type(uint256).max / 2);
    _buffer = bound(_buffer, 1, type(uint256).max - _amount);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _amount);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint the full amount to the recipient
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');
    // it should transfer nothing
    vm.expectCall(_TOKEN, abi.encodeWithSelector(IERC20.transfer.selector), 0);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should leave the donated buffer untouched
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer);
  }

  function test_WhenTheHeadroomIsBelowTheMinterMinimumAndTheBufferCoversTheRedeem(
    uint256 _headroom,
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // A sliver of headroom below the Minter minimum would revert as a mint leg, so the whole amount reroutes
    // through the buffer; the amount itself exceeds the sliver so the split would otherwise happen.
    _headroom = bound(_headroom, 1, _MIN_MINT_AMOUNT - 1);
    _amount = bound(_amount, _headroom + 1, type(uint256).max / 2);
    _buffer = bound(_buffer, _amount, type(uint256).max / 2);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _headroom);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should mint nothing
    vm.expectCall(_MINTER, abi.encodeWithSelector(IMinter.mint.selector), 0);
    // it should transfer the full amount to the recipient
    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _amount);

    _expectEmit(address(_voter));
    emit IVoter.BufferDrawn(_CHAIN_ID_1, _amount);

    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);

    // it should decrease the donated buffer by the full amount
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer - _amount);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 0);
  }

  function test_WhenTheHeadroomIsBelowTheMinterMinimumAndTheBufferCannotCoverTheRedeem(
    uint256 _headroom,
    uint256 _amount,
    uint256 _buffer,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The buffer covers the shortfall but not the full amount, so the sub-minimum headroom leg still goes to
    // the Minter, which rejects it; the redeem bounces until enough headroom accrues.
    _headroom = bound(_headroom, 1, _MIN_MINT_AMOUNT - 1);
    _amount = bound(_amount, _headroom + 1, type(uint256).max / 2);
    _buffer = bound(_buffer, _amount - _headroom, _amount - 1);

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _headroom);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    vm.mockCallRevert(
      _MINTER,
      abi.encodeCall(IMinter.mint, (_headroom, _recipient)),
      abi.encodeWithSelector(IMinter.AmountTooLow.selector)
    );

    // it should forward the sub minimum leg to the minter and bubble its revert
    vm.expectRevert(IMinter.AmountTooLow.selector);
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, 0);
  }

  function test_WhenSequentialRedeemsExhaustTheSameBuffer(
    uint256 _ceiling,
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _thirdAmount,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // The ceiling is fully consumed by prior redeems, so every redeem draws on the same buffer, sized to
    // exactly two draws; the redeem after the buffer runs dry bounces on the solvency check. Bounds keep the
    // solvency sums from overflowing.
    _ceiling = bound(_ceiling, 0, type(uint256).max / 4);
    _firstAmount = bound(_firstAmount, 1, type(uint256).max / 4);
    _secondAmount = bound(_secondAmount, 1, type(uint256).max / 4);
    _thirdAmount = bound(_thirdAmount, 1, type(uint256).max / 4);
    uint256 _buffer = _firstAmount + _secondAmount;

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockTotalRedeemed(_CHAIN_ID_1, _ceiling);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _firstAmount);
    _voter.processRedeem(_CHAIN_ID_1, _firstAmount, _recipient, 0);

    // it should decrease the donated buffer on each draw
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _secondAmount);

    _mockAndExpectTokenTransfer(_TOKEN, _recipient, _secondAmount);
    _voter.processRedeem(_CHAIN_ID_1, _secondAmount, _recipient, 0);

    // it should empty the buffer after the final draw
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), 0);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _ceiling);

    // it should revert with CeilingExceeded once the buffer is empty
    vm.expectRevert(IVoter.CeilingExceeded.selector);
    _voter.processRedeem(_CHAIN_ID_1, _thirdAmount, _recipient, 0);
  }

  function test_WhenTheBufferTransferReverts(
    uint256 _headroom,
    uint256 _shortfall,
    uint256 _buffer,
    uint256 _surplusAccrued,
    address _recipient
  ) external givenTheCallerIsTheOrchestrator {
    // A split redeem books the surplus advance, the mint accounting and the buffer draw before the payout, so
    // a reverting payout must roll all of them back in one piece. The headroom leg stays mintable (at or above
    // the Minter minimum, so the sub-minimum reroute stays off) and the surplus report reserves the rest of
    // the ceiling.
    _headroom = bound(_headroom, _MIN_MINT_AMOUNT, type(uint256).max / 4);
    _shortfall = bound(_shortfall, 1, type(uint256).max / 4);
    _buffer = bound(_buffer, _shortfall, type(uint256).max / 4);
    _surplusAccrued = bound(_surplusAccrued, 1, type(uint256).max / 4);
    uint256 _amount = _headroom + _shortfall;

    // The global accumulator is already current, so the settle prelude accrues nothing onto the ceiling.
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainCeiling(_CHAIN_ID_1, _surplusAccrued + _headroom);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    vm.mockCallRevert(_TOKEN, abi.encodeCall(IERC20.transfer, (_recipient, _shortfall)), 'transfer reverted');

    // it should bubble the transfer revert
    vm.expectRevert(bytes('transfer reverted'));
    _voter.processRedeem(_CHAIN_ID_1, _amount, _recipient, _surplusAccrued);

    // it should leave the donated buffer unchanged
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer);
    // it should leave total redeemed unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 0);
    // it should leave the surplus already reported unchanged
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, 0);
  }
}
