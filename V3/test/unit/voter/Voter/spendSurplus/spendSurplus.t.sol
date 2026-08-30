// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {Roles} from 'V3/libraries/Roles.sol';

import {BaseVoter, IVoter, IVoterCommon} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterSpendSurplus is BaseVoter {
  function test_WhenTheCallerLacksTheGovernanceRole(address _caller, uint256 _amount, address _recipient) external {
    _caller = _boundNotEq(_caller, _GOVERNOR);

    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, Roles.GOVERNANCE_ROLE)
    );
    vm.prank(_caller);
    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);
  }

  modifier givenTheCallerIsTheGovernor() {
    vm.startPrank(_GOVERNOR);
    _;
    vm.stopPrank();
  }

  function test_WhenTheRecipientIsTheZeroAddress(uint256 _amount) external givenTheCallerIsTheGovernor {
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    _voter.spendSurplus(_CHAIN_ID_1, _amount, address(0));
  }

  function test_WhenTheChainIsNeitherChainZeroNorRegistered(
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));

    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotRegistered.selector, _UNREGISTERED_CHAIN_ID));
    _voter.spendSurplus(_UNREGISTERED_CHAIN_ID, _amount, _recipient);
  }

  function test_WhenTheAmountExceedsTheSpendableSurplus(
    uint256 _reported,
    uint256 _suspended,
    uint256 _spent,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    // Pot terms bounded so `reported + suspended` never overflows and spendable leaves headroom for `+1`.
    _reported = bound(_reported, 0, (type(uint256).max - 2) / 2);
    _suspended = bound(_suspended, 0, (type(uint256).max - 2) / 2);
    _spent = bound(_spent, 0, _reported + _suspended);
    uint256 _spendable = _reported + _suspended - _spent;
    _amount = bound(_amount, _spendable + 1, type(uint256).max);

    // The global accumulator is current, so the settle prelude leaves the seeded pot untouched. The ceiling
    // matches the report so the entitlement clamp is provably inactive.
    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockChainCeiling(_CHAIN_ID_1, _reported);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockCumulativeSuspendedSurplus(_CHAIN_ID_1, _suspended);
    _mockSurplusSpent(_CHAIN_ID_1, _spent);

    // it should revert with InsufficientSurplus carrying the settled spendable amount
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, _spendable));
    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);
  }

  /// @notice A report stored above the chain's remaining mint entitlement by a buffer backed redeem must
  ///         never be mintable in full. The pot clamps to the entitlement and only that much spends.
  function test_WhenTheReportedSurplusExceedsTheRemainingMintEntitlement(
    uint256 _entitlement,
    uint256 _excess,
    uint256 _totalRedeemed,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _entitlement = bound(_entitlement, 1, type(uint128).max);
    _excess = bound(_excess, 1, type(uint128).max);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint128).max);
    // The stored report overruns the entitlement `ceiling - totalRedeemed` by `_excess`.
    uint256 _reported = _entitlement + _excess;

    // The global accumulator is current, so the settle prelude leaves the seeded pot untouched.
    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockChainCeiling(_CHAIN_ID_1, _totalRedeemed + _entitlement);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);

    // it should revert with InsufficientSurplus carrying the clamped entitlement on the full report
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, _entitlement));
    _voter.spendSurplus(_CHAIN_ID_1, _reported, _recipient);

    // it should spend the clamped entitlement
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_entitlement, _recipient)), '');
    _voter.spendSurplus(_CHAIN_ID_1, _entitlement, _recipient);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _entitlement);
  }

  /// @notice Spend side of the audited double spend regression. Picks up the exact end state the
  ///         `processRedeem` replay leaves behind (ceiling 1000, redeemed 600, report 500, buffer 250) and
  ///         proves governance can spend only the 400 entitlement: one wei more bounces, the full 400 mints,
  ///         the donated buffer stays payable to future redeems, and the pot is then dry.
  function test_WhenReplayingTheAuditedDoubleSpendScenarioAfterTheBufferBackedRedeem(address _recipient)
    external
    givenTheCallerIsTheGovernor
  {
    vm.assume(_recipient != address(0));
    // End state of the buffer backed redeem: report stored 100 above the entitlement `1000 - 600 = 400`.
    uint256 _ceiling = 1000 ether;
    uint256 _totalRedeemed = 600 ether;
    uint256 _reported = 500 ether;
    uint256 _buffer = 250 ether;
    uint256 _entitlement = 400 ether;

    // The global accumulator is current, so the settle prelude leaves the seeded pot untouched.
    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockDonatedBuffer(_CHAIN_ID_1, _buffer);

    // it should revert with InsufficientSurplus one wei above the clamped entitlement
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, _entitlement));
    _voter.spendSurplus(_CHAIN_ID_1, _entitlement + 1, _recipient);

    // it should spend the clamped entitlement in full
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_entitlement, _recipient)), '');
    _voter.spendSurplus(_CHAIN_ID_1, _entitlement, _recipient);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _entitlement);

    // it should leave the donated buffer untouched
    assertEq(_voter.donatedBuffer(_CHAIN_ID_1), _buffer);

    // it should revert with InsufficientSurplus on any further spend
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, 0));
    _voter.spendSurplus(_CHAIN_ID_1, 1, _recipient);
  }

  function test_WhenTheMinterRejectsTheAmount(
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _amount = bound(_amount, 1, type(uint256).max);

    _mockLastGlobalSettlement(uint48(block.timestamp));
    // The ceiling matches the report so the entitlement clamp is inactive and the pot is `_amount`.
    _mockChainCeiling(_CHAIN_ID_1, _amount);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _amount);
    vm.mockCallRevert(
      _MINTER,
      abi.encodeCall(IMinter.mint, (_amount, _recipient)),
      abi.encodeWithSelector(IMinter.AmountTooLow.selector)
    );

    // it should bubble the minter revert
    vm.expectRevert(IMinter.AmountTooLow.selector);
    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);
  }

  function test_WhenSpendingFromAnActiveChain(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _reported,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 0, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    _reported = bound(_reported, 1, type(uint128).max);
    _amount = bound(_amount, 1, _reported);
    // Permanent chain point with weight `_ONE_AERO == PRECISION`, so the pending accrual is exactly
    // `emissionsPerVP * elapsed`. The spend must not eat it, only the settle grows the ceiling.
    uint256 _accrual = uint256(_emissionsPerVP) * _elapsed;
    uint256 _initialCeiling = _reported + 1 ether;

    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    // it should call the minter with the amount and recipient
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should emit SurplusSpent with the chain recipient and amount
    _expectEmit(address(_voter));
    emit IVoter.SurplusSpent(_CHAIN_ID_1, _recipient, _amount);

    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);

    // it should increment the spent surplus by the amount
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _amount);
    // it should settle the chain ceiling before the check
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling + _accrual);
    // it should anchor the chain cursor at the advanced global index
    assertEq(_chainState(_voter, _CHAIN_ID_1).lastIndex, _voter.index());
    // it should leave the ceiling total redeemed and reported surplus untouched by the spend
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, 0);
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _reported);
  }

  function test_WhenSpendingFromASuspendedChain(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // Permanent weight `_ONE_AERO == PRECISION` prices the suspended window at exactly
    // `emissionsPerVP * elapsed`, all of it divertible surplus.
    uint256 _windowAccrual = uint256(_emissionsPerVP) * _elapsed;
    _amount = bound(_amount, 1, _windowAccrual);
    uint256 _initialCeiling = 1000 ether;

    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should allow spending the freshly settled surplus in the same call
    _expectEmit(address(_voter));
    emit IVoter.SurplusSpent(_CHAIN_ID_1, _recipient, _amount);

    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);

    // it should route the pending accrual into the cumulative suspended surplus before the check
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, _windowAccrual);
    // it should keep the ceiling frozen
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _amount);
  }

  function test_WhenSpendingFromASunsetChain(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    // Sunset diverts accrual exactly like Suspended: the wind-down window lands in the suspended-surplus
    // pot, stays spendable, and the ceiling never grows.
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // Permanent weight `_ONE_AERO == PRECISION` prices the sunset window at exactly
    // `emissionsPerVP * elapsed`, all of it divertible surplus.
    uint256 _windowAccrual = uint256(_emissionsPerVP) * _elapsed;
    _amount = bound(_amount, 1, _windowAccrual);
    uint256 _initialCeiling = 1000 ether;

    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should allow spending the freshly settled surplus in the same call
    _expectEmit(address(_voter));
    emit IVoter.SurplusSpent(_CHAIN_ID_1, _recipient, _amount);

    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);

    // it should route the pending accrual into the cumulative suspended surplus before the check
    assertEq(_chainState(_voter, _CHAIN_ID_1).cumulativeSuspendedSurplus, _windowAccrual);
    // it should keep the ceiling frozen
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _amount);
  }

  function test_WhenTheAmountExceedsTheFreshlySettledSuspendedSurplus(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    // Permanent weight `_ONE_AERO == PRECISION` prices the suspended window at exactly
    // `emissionsPerVP * elapsed`, so the settled pot is the whole spendable amount.
    uint256 _windowAccrual = uint256(_emissionsPerVP) * _elapsed;
    _amount = bound(_amount, _windowAccrual + 1, type(uint256).max);

    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    _mockChainPoint({_chainId: _CHAIN_ID_1, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN_ID_1, _voter.index());

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    // it should revert with InsufficientSurplus carrying the settled suspended pot
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, _windowAccrual));
    _voter.spendSurplus(_CHAIN_ID_1, _amount, _recipient);
  }

  function test_WhenSpendingFromChainZero(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _initialCeiling,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    _initialCeiling = bound(_initialCeiling, 0, type(uint128).max);
    // CHAIN0 is seeded Active at construction; a permanent park of `_ONE_AERO == PRECISION` accrues
    // exactly `emissionsPerVP * elapsed` onto its lazily settled ceiling.
    uint256 _accrual = uint256(_emissionsPerVP) * _elapsed;
    _amount = bound(_amount, 1, _initialCeiling + _accrual);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainCeiling(_CHAIN0, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_amount, _recipient)), '');

    // it should allow spending up to the settled ceiling
    _expectEmit(address(_voter));
    emit IVoter.SurplusSpent(_CHAIN0, _recipient, _amount);

    _voter.spendSurplus(_CHAIN0, _amount, _recipient);

    // it should settle the chain zero ceiling first
    assertEq(_chainState(_voter, _CHAIN0).ceiling, _initialCeiling + _accrual);
    assertEq(_chainState(_voter, _CHAIN0).surplusSpent, _amount);
  }

  function test_WhenTheAmountExceedsTheFreshlySettledChainZeroCeiling(
    uint128 _emissionsPerVP,
    uint48 _elapsed,
    uint256 _initialCeiling,
    uint256 _amount,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _emissionsPerVP = uint128(bound(_emissionsPerVP, 1, type(uint64).max));
    _elapsed = uint48(bound(_elapsed, 1, 365 days));
    _initialCeiling = bound(_initialCeiling, 0, type(uint128).max);
    // A permanent park of `_ONE_AERO == PRECISION` accrues exactly `emissionsPerVP * elapsed` onto the
    // lazily settled ceiling, which is the whole spendable pot for CHAIN0.
    uint256 _settledSpendable = _initialCeiling + uint256(_emissionsPerVP) * _elapsed;
    _amount = bound(_amount, _settledSpendable + 1, type(uint256).max);

    _mockChainPoint({_chainId: _CHAIN0, _bias: 0, _slope: 0, _ts: _INITIAL_TIMESTAMP, _perm: _ONE_AERO});
    _mockEmissionsPerVP(_emissionsPerVP);
    _mockLastGlobalSettlement(_INITIAL_TIMESTAMP);
    _mockChainLastIndex(_CHAIN0, _voter.index());
    _mockChainCeiling(_CHAIN0, _initialCeiling);

    vm.warp(uint256(_INITIAL_TIMESTAMP) + uint256(_elapsed));

    // it should revert with InsufficientSurplus carrying the settled ceiling
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN0, _settledSpendable));
    _voter.spendSurplus(_CHAIN0, _amount, _recipient);
  }

  function test_WhenTheAmountExactlyEqualsTheSpendableSurplus(
    uint256 _spendable,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    _spendable = bound(_spendable, 1, type(uint256).max - 1);

    _mockLastGlobalSettlement(uint48(block.timestamp));
    // The ceiling matches the report so the entitlement clamp is inactive and the pot is `_spendable`.
    _mockChainCeiling(_CHAIN_ID_1, _spendable);
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _spendable);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_spendable, _recipient)), '');

    // it should spend at the boundary
    _expectEmit(address(_voter));
    emit IVoter.SurplusSpent(_CHAIN_ID_1, _recipient, _spendable);

    _voter.spendSurplus(_CHAIN_ID_1, _spendable, _recipient);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _spendable);

    // it should revert with InsufficientSurplus on any further spend
    vm.expectRevert(abi.encodeWithSelector(IVoter.InsufficientSurplus.selector, _CHAIN_ID_1, 0));
    _voter.spendSurplus(_CHAIN_ID_1, 1, _recipient);
  }

  function test_WhenSpendingTwice(
    uint256 _firstAmount,
    uint256 _secondAmount,
    uint256 _totalRedeemed,
    address _recipient
  ) external givenTheCallerIsTheGovernor {
    vm.assume(_recipient != address(0));
    // Both spends draw from one reported pot sized at their exact sum. The ceiling sits at the report plus
    // the redeemed total so the entitlement clamp is inactive and the pot is exactly the report.
    _firstAmount = bound(_firstAmount, 1, type(uint128).max);
    _secondAmount = bound(_secondAmount, 1, type(uint128).max);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint128).max);
    uint256 _reported = _firstAmount + _secondAmount;
    uint256 _initialCeiling = _reported + _totalRedeemed;

    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockChainCeiling(_CHAIN_ID_1, _initialCeiling);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_firstAmount, _recipient)), '');
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_secondAmount, _recipient)), '');

    _voter.spendSurplus(_CHAIN_ID_1, _firstAmount, _recipient);
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _firstAmount);

    _voter.spendSurplus(_CHAIN_ID_1, _secondAmount, _recipient);

    // it should accumulate the spent surplus across both spends
    assertEq(_chainState(_voter, _CHAIN_ID_1).surplusSpent, _firstAmount + _secondAmount);

    // it should leave the redeem headroom terms unchanged
    // `processRedeem` checks `reportedSurplus + totalRedeemed + amount <= ceiling` and never reads
    // `surplusSpent`, so redeem headroom is exactly what it was before the spends.
    assertEq(_chainState(_voter, _CHAIN_ID_1).ceiling, _initialCeiling);
    assertEq(_chainState(_voter, _CHAIN_ID_1).reportedSurplus, _reported);
    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _totalRedeemed);
  }

  function test_WhenRedeemingAfterASpend(
    uint256 _spendAmount,
    uint256 _reported,
    uint256 _totalRedeemed,
    uint256 _headroom,
    address _recipient
  ) external {
    vm.assume(_recipient != address(0));
    // The spend draws from the reported pot; the redeem headroom `ceiling - reported - redeemed` must
    // survive it exactly, so the ceiling is sized to leave `_headroom` on top of the redeem terms.
    _spendAmount = bound(_spendAmount, 1, type(uint128).max);
    _reported = bound(_reported, _spendAmount, type(uint128).max);
    _totalRedeemed = bound(_totalRedeemed, 0, type(uint128).max);
    _headroom = bound(_headroom, 1, type(uint128).max);
    uint256 _ceiling = _reported + _totalRedeemed + _headroom;

    _mockLastGlobalSettlement(uint48(block.timestamp));
    _mockSurplusAlreadyReported(_CHAIN_ID_1, _reported);
    _mockTotalRedeemed(_CHAIN_ID_1, _totalRedeemed);
    _mockChainCeiling(_CHAIN_ID_1, _ceiling);

    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_spendAmount, _recipient)), '');
    vm.prank(_GOVERNOR);
    _voter.spendSurplus(_CHAIN_ID_1, _spendAmount, _recipient);

    // it should revert with CeilingExceeded one wei above the remaining headroom
    vm.expectRevert(IVoter.CeilingExceeded.selector);
    vm.prank(_ORCHESTRATOR);
    _voter.processRedeem(_CHAIN_ID_1, _headroom + 1, _recipient, 0);

    // it should redeem the exact remaining headroom after the spend
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.mint, (_headroom, _recipient)), '');
    vm.prank(_ORCHESTRATOR);
    _voter.processRedeem(_CHAIN_ID_1, _headroom, _recipient, 0);

    assertEq(_chainState(_voter, _CHAIN_ID_1).totalRedeemed, _totalRedeemed + _headroom);
  }
}
