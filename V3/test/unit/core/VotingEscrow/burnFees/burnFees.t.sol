// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowBurnFees is BaseVotingEscrow {
  function _mockTokenBurn(uint256 _amount) internal {
    vm.mockCall(_token, abi.encodeCall(ITokenExtensions.burn, (_amount)), abi.encode());
  }

  /// @dev Grant BURN_FEES_ROLE to a fresh account through its admin and return it as the burn caller.
  function _burnFeesRoleHolder() internal returns (address _caller) {
    _caller = makeAddr('BurnFeesRoleHolder');
    // Cache the role before the prank so the BURN_FEES_ROLE() read doesn't consume it.
    bytes32 _role = _ve.BURN_FEES_ROLE();
    vm.prank(_burnFeesAdmin);
    _ve.grantRole(_role, _caller);
  }

  function test_WhenTheCallerLacksTheBurnFeesRole(address _caller, uint128 _amount) external {
    _assumeFuzzable(_caller);

    // it should revert with AccessControlUnauthorizedAccount
    vm.expectRevert(
      abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, _caller, _ve.BURN_FEES_ROLE())
    );
    vm.prank(_caller);
    _ve.burnFees(_amount);
  }

  function test_WhenTheAmountIsZero() external {
    address _caller = _burnFeesRoleHolder();

    // it should revert with ZeroAmount
    vm.expectRevert(IVotingEscrow.ZeroAmount.selector);
    vm.prank(_caller);
    _ve.burnFees(0);
  }

  function test_WhenTheAmountExceedsTheAccumulatorStakedAmount(uint128 _accBalance, uint128 _amount) external {
    _accBalance = uint128(bound(_accBalance, 0, uint128(type(int128).max) - 1));
    _amount = uint128(bound(_amount, uint256(_accBalance) + 1, uint128(type(int128).max)));
    // The accumulator is stored as a permanent position (its amount counts toward permanentStakeBalance).
    _setStaked(0, _accBalance, 0, true);
    address _caller = _burnFeesRoleHolder();

    // it should revert with AmountExceedsAccumulator
    vm.expectRevert(IVotingEscrow.AmountExceedsAccumulator.selector);
    vm.prank(_caller);
    _ve.burnFees(_amount);
  }

  function test_WhenABurnFeesRoleHolderBurnsFromTheAccumulator(uint128 _accBalance, uint128 _amount) external {
    _accBalance = uint128(bound(_accBalance, 1, uint128(type(int128).max) / 2));
    _amount = uint128(bound(_amount, 1, _accBalance));
    // The accumulator is stored as a permanent position (its amount counts toward permanentStakeBalance).
    _setStaked(0, _accBalance, 0, true);
    _setSupplyAndPermanent(_accBalance, _accBalance);
    _mockTokenBurn(uint256(_amount));

    address _caller = _burnFeesRoleHolder();

    // it should call the token burn with the amount
    vm.expectCall(_token, abi.encodeCall(ITokenExtensions.burn, (uint256(_amount))));
    // it should burn the matching voting power on the voter
    vm.expectCall(_voter, abi.encodeCall(IVoter.burn, (_amount)));
    // it should emit the Supply event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Supply(_accBalance - _amount);
    // it should emit the Burn event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Burn(_amount);

    vm.prank(_caller);
    _ve.burnFees(_amount);

    // it should reduce the accumulator staked amount by the amount
    assertEq(_ve.staked(0).amount, _accBalance - _amount);
    // it should decrement supply by the amount
    assertEq(_ve.supply(), _accBalance - _amount);
    // it should decrement the permanent stake balance by the amount
    assertEq(_ve.permanentStakeBalance(), _accBalance - _amount);
    // it should propagate the debit into the latest global point
    assertEq(_ve.pointHistory(_ve.epoch()).permanentStakeBalance, _accBalance - _amount);
    _assertGlobalPointInvariants();
  }
}
