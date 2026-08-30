// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowWithdraw is BaseVotingEscrow {
  function test_WhenTheCallerIsNotTheOwnerOrApprovedOperator(address _caller, uint256 _tokenId) external {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    vm.assume(_caller != _owner);
    _setOwner(_tokenId, _owner);

    // it should revert with ERC721InsufficientApproval
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _caller, _tokenId));
    vm.prank(_caller);
    _ve.withdraw(_tokenId, _owner);
  }

  function test_WhenTheTokenIdHasNotBeenMinted(uint256 _tokenId) external {
    // _tokenId has no owner: no `_setOwner` call. Includes tokenId 0 (the accumulator, never minted).

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _tokenId));
    vm.prank(_owner);
    _ve.withdraw(_tokenId, _owner);
  }

  function test_WhenTheStakeIsPermanent(uint256 _tokenId, uint128 _oldAmount) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, 0, true);

    // it should not clear the voter ledger
    vm.expectCall(_voter, abi.encodeCall(IVoter.clearToken, (_tokenId)), 0);

    // it should revert with PermanentStake
    vm.expectRevert(IVotingEscrow.PermanentStake.selector);
    vm.prank(_owner);
    _ve.withdraw(_tokenId, _owner);
  }

  function test_WhenTheStakeHasNotExpired(uint256 _tokenId, uint128 _oldAmount, uint48 _stakingWeeks) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, 207));
    uint48 _stakeEnd = uint48(block.timestamp) + _stakingWeeks * _WEEK;
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, _stakeEnd, false);

    // it should not clear the voter ledger
    vm.expectCall(_voter, abi.encodeCall(IVoter.clearToken, (_tokenId)), 0);

    // it should revert with StakeNotExpired
    vm.expectRevert(IVotingEscrow.StakeNotExpired.selector);
    vm.prank(_owner);
    _ve.withdraw(_tokenId, _owner);
  }

  function test_WhenTheStakeIsNotFullyReturnedToChainZero(
    uint256 _tokenId,
    uint128 _oldAmount,
    uint128 _onChain0
  ) external {
    // An expired stake with voting power still booked on a remote chain: less than the full amount sits on
    // CHAIN0, so withdraw is blocked until the remainder is deallocated back.
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    _onChain0 = uint128(bound(_onChain0, 0, _oldAmount - 1));
    vm.warp(_WEEK + 1);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp), false);
    _mockVoterChain0Allocation(_tokenId, _onChain0);

    // it should not clear the voter ledger
    vm.expectCall(_voter, abi.encodeCall(IVoter.clearToken, (_tokenId)), 0);

    // it should revert with InsufficientChain0Allocation
    vm.expectRevert(IVoter.InsufficientChain0Allocation.selector);
    vm.prank(_owner);
    _ve.withdraw(_tokenId, _owner);
  }

  function test_WhenAnAuthorizedCallerWithdrawsAnExpiredStake(
    address _operator,
    address _recipient,
    uint256 _tokenId,
    uint128 _oldAmount,
    bool _useOperator
  ) external {
    _assumeFuzzable(_operator);
    _assumeFuzzable(_recipient);
    vm.assume(_operator != _owner);
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _oldAmount = uint128(bound(_oldAmount, 1, uint128(type(int128).max)));
    vm.warp(_WEEK + 1);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _oldAmount, uint48(block.timestamp), false);
    _setSupplyAndPermanent(_oldAmount, 0);
    // The whole stake sits on CHAIN0, so the return-to-chain0 check passes.
    _mockVoterChain0Allocation(_tokenId, _oldAmount);
    _mockTransfer(_recipient, _oldAmount);

    // The owner is always authorized; an approved operator must also succeed when the owner has approved it.
    address _caller = _owner;
    if (_useOperator) {
      _setOperatorApproval(_owner, _operator, true);
      _caller = _operator;
    }

    // it should emit the Withdraw event with the token owner
    _expectEmit(address(_ve));
    emit IVotingEscrow.Withdraw(_owner, _tokenId, _oldAmount, block.timestamp);
    // it should emit the Supply event
    _expectEmit(address(_ve));
    emit IVotingEscrow.Supply(0);
    // it should emit the MetadataUpdate event
    _expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_tokenId);
    // it should transfer the underlying tokens to the recipient
    vm.expectCall(_token, abi.encodeCall(IERC20.transfer, (_recipient, _oldAmount)));
    // it should clear the voter ledger for the token
    // The stake is expired, so its weight already decayed out of the Voter's points; only the ledger residue
    // is dropped, so a later revival of the same id starts clean.
    vm.expectCall(_voter, abi.encodeCall(IVoter.clearToken, (_tokenId)));

    vm.prank(_caller);
    _ve.withdraw(_tokenId, _recipient);

    // it should preserve the token owner at zero balance
    assertEq(_ve.ownerOf(_tokenId), _owner);
    // it should zero out the staked balance
    IVotingEscrow.StakedBalance memory _staked = _ve.staked(_tokenId);
    assertEq(_staked.amount, 0);
    assertEq(_staked.end, 0);
    assertFalse(_staked.isPermanent);
    // it should decrement the supply by the staked amount
    assertEq(_ve.supply(), 0);
    // it should record a user point with zeroed bias slope and permanent
    IVotingEscrow.UserPoint memory _uPoint = _ve.userPointHistory(_tokenId, 1);
    assertEq(_uPoint.bias, 0);
    assertEq(_uPoint.slope, 0);
    assertEq(_uPoint.ts, block.timestamp);
    assertEq(_uPoint.permanent, 0);
    // it should advance the global epoch
    assertEq(_ve.epoch(), 1);
    // it should drop the voting-power APIs to zero after withdraw
    _assertVotingPower(0, _tokenId, 0);
    _assertGlobalPointInvariants();
  }
}
