// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC4906} from '@openzeppelin/contracts/interfaces/IERC4906.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

contract UnitVotingEscrowRebalanceUnderlying is BaseVotingEscrow {
  function _src(uint256 _tokenId, uint128 _amount) internal pure returns (IVotingEscrow.SourceDelta memory _d) {
    _d = IVotingEscrow.SourceDelta({tokenId: _tokenId, amount: _amount});
  }

  function _dst(
    uint256 _tokenId,
    uint128 _amount,
    address _recipient
  ) internal pure returns (IVotingEscrow.DestinationDelta memory _d) {
    _d = IVotingEscrow.DestinationDelta({tokenId: _tokenId, amount: _amount, recipient: _recipient});
  }

  function _wrap(
    IVotingEscrow.DestinationDelta memory _d
  ) internal pure returns (IVotingEscrow.DestinationDelta[] memory _arr) {
    _arr = new IVotingEscrow.DestinationDelta[](1);
    _arr[0] = _d;
  }

  function _empty() internal pure returns (IVotingEscrow.DestinationDelta[] memory _arr) {
    _arr = new IVotingEscrow.DestinationDelta[](0);
  }

  function _wrapSrc(
    IVotingEscrow.SourceDelta memory _d
  ) internal pure returns (IVotingEscrow.SourceDelta[] memory _arr) {
    _arr = new IVotingEscrow.SourceDelta[](1);
    _arr[0] = _d;
  }

  function _emptySrc() internal pure returns (IVotingEscrow.SourceDelta[] memory _arr) {
    _arr = new IVotingEscrow.SourceDelta[](0);
  }

  function test_WhenTheCallerIsNotAVpmRoleHolder(address _caller) external {
    _assumeFuzzable(_caller);
    // A caller without VPM_ROLE fails the `_isAuthorizedVPM` gate. `_vpm` already holds the role in setUp, so
    // exclude it here to keep this purely the unauthorized path.
    vm.assume(_caller != _vpm);

    // it should revert with NotVoterPaymentsModule
    vm.expectRevert(IVotingEscrow.NotVoterPaymentsModule.selector);
    vm.prank(_caller);
    _ve.rebalanceUnderlying(_emptySrc(), _empty());
  }

  function test_WhenAVpmRoleHolderRebalancesWithEmptyInputs() external {
    // A VPM_ROLE holder (granted in setUp) clears the access gate; an empty rebalance is a no-op that still emits
    // Rebalance.
    _expectEmit(address(_ve));
    emit IVotingEscrow.Rebalance(_emptySrc(), _empty());

    // it should authorize the caller to rebalance
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_emptySrc(), _empty());
  }

  function test_WhenAVpmRoleHolderDrainsASourceWithoutOwnerApproval(uint256 _tokenId, uint128 _amount) external {
    // A VPM_ROLE holder may only drain a source the owner authorized it for. Without operator or token approval,
    // the per-source `_checkAuthorized` reverts the whole call.
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));

    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _amount, 0, true);
    _setSupplyAndPermanent(_amount, _amount);
    // `_owner` has not approved `_vpm` for the source.

    // it should revert with the insufficient approval error
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, _vpm, _tokenId));
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_tokenId, _amount)), _wrap(_dst(0, _amount, address(0))));
  }

  function test_WhenAVpmRoleHolderIsApprovedByTheSourceOwner(uint256 _tokenId, uint128 _amount) external {
    // With operator approval from the source owner, a VPM_ROLE holder clears the per-source check and the
    // rebalance proceeds (here draining the source into the protocol accumulator).
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));

    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _amount, 0, true);
    _setSupplyAndPermanent(_amount, _amount);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = _wrapSrc(_src(_tokenId, _amount));
    IVotingEscrow.DestinationDelta[] memory _destinations = _wrap(_dst(0, _amount, address(0)));

    // it should authorize the rebalance
    _expectEmit(address(_ve));
    emit IVotingEscrow.Rebalance(_sources, _destinations);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_sources, _destinations);

    assertEq(_ve.staked(_tokenId).amount, 0);
  }

  function test_WhenAnAddDestinationTargetsANonExistentTokenId(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _amount
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _amount, 0, true);
    _setSupplyAndPermanent(_amount, _amount);
    _setOperatorApproval(_owner, _vpm, true);
    // _dstTokenId has no owner: it has never been minted.

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _dstTokenId));
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(_dstTokenId, _amount, address(0))));
  }

  function test_WhenASourceTargetsTheProtocolAccumulator(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    // The accumulator (tokenId 0) is rejected up front in the per-source loop, before the auth check and any
    // stake processing, so no owner/approval/stake seeding is needed.

    // it should revert with AccumulatorCannotBeSource
    vm.expectRevert(IVotingEscrow.AccumulatorCannotBeSource.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(0, _amount)), _wrap(_dst(0, _amount, address(0))));
  }

  function test_WhenASourceCarriesTheMintSentinelTokenId(uint128 _amount) external {
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    // The mint sentinel `type(uint256).max` is only meaningful as a DESTINATION tokenId. As a source it names a
    // token that can never exist, so the per-source auth check trips on the zero owner before any processing.

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, type(uint256).max));
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(type(uint256).max, _amount)), _wrap(_dst(0, _amount, address(0))));
  }

  function test_WhenANonMintDestinationCarriesARecipient(uint128 _amount, address _recipient) external {
    // A non-mint destination (here the accumulator) must leave recipient zero.
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max)));
    vm.assume(_recipient != address(0));

    // it should revert with NonMintRecipientNotAllowed
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.NonMintRecipientNotAllowed.selector, uint256(0)));
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_emptySrc(), _wrap(_dst(0, _amount, _recipient)));
  }

  function test_WhenASourceDeltaExceedsTheStakedAmount(
    uint256 _tokenId,
    uint128 _stakedAmount,
    uint128 _delta
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _stakedAmount = uint128(bound(_stakedAmount, 0, uint128(type(int128).max) - 1));
    _delta = uint128(bound(_delta, uint256(_stakedAmount) + 1, uint128(type(int128).max)));
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _stakedAmount, 0, true);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with AmountExceedsStake
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.AmountExceedsStake.selector, _tokenId));
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_tokenId, _delta)), _wrap(_dst(0, _delta, address(0))));
  }

  function test_WhenTotalInDoesNotEqualTotalOut(
    uint256 _tokenId,
    uint128 _stakedAmount,
    uint128 _srcAmount,
    uint128 _dstAmount
  ) external {
    _tokenId = bound(_tokenId, 1, type(uint128).max);
    _stakedAmount = uint128(bound(_stakedAmount, 2, uint128(type(int128).max)));
    _srcAmount = uint128(bound(_srcAmount, 1, _stakedAmount));
    _dstAmount = uint128(bound(_dstAmount, 1, _stakedAmount));
    vm.assume(_srcAmount != _dstAmount);
    _setOwner(_tokenId, _owner);
    _setStaked(_tokenId, _stakedAmount, 0, true);
    _setSupplyAndPermanent(_stakedAmount, _stakedAmount);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with BalanceMismatch
    vm.expectRevert(IVotingEscrow.BalanceMismatch.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_tokenId, _srcAmount)), _wrap(_dst(0, _dstAmount, address(0))));
  }

  function test_WhenTheLatestSourceUnlockIsLaterThanTheEarliestAddDestinationUnlock(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _amount,
    uint48 _srcEnd,
    uint48 _dstEnd
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _amount = uint128(bound(_amount, 1, _DECAY_AMOUNT_CAP));
    _dstEnd = uint48(bound(_dstEnd, _WEEK + 1, type(uint48).max - 2));
    _srcEnd = uint48(bound(_srcEnd, uint256(_dstEnd) + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _amount, _srcEnd, false);
    _setStaked(_dstTokenId, _amount, _dstEnd, false);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with UnlockTimeReduction
    vm.expectRevert(IVotingEscrow.UnlockTimeReduction.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(_dstTokenId, _amount, address(0))));
  }

  function test_WhenAPermanentSourceIsFollowedByANonPermanentAddDestination(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _amount,
    uint48 _dstEnd
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _amount = uint128(bound(_amount, 1, _DECAY_AMOUNT_CAP));
    _dstEnd = uint48(bound(_dstEnd, _WEEK + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _amount, 0, true); // permanent source -> type(uint48).max
    _setStaked(_dstTokenId, _amount, _dstEnd, false);
    _setSupplyAndPermanent(_amount, _amount);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with UnlockTimeReduction
    vm.expectRevert(IVotingEscrow.UnlockTimeReduction.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(_dstTokenId, _amount, address(0))));
  }

  /// @dev Drives `_dstStaked + _delta > int128.max` so `_commit` trips the cap guard on the Add
  ///      path. Source stake holds exactly `_delta` so the source decrement is valid; destination is
  ///      seeded close to the signed limit so any positive credit breaches the cap.
  function test_WhenTheAddDestinationCreditOverflowsTheSignedLimit(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _delta,
    uint128 _dstStaked
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _delta = uint128(bound(_delta, 1, uint128(type(int128).max)));
    _dstStaked = uint128(bound(_dstStaked, uint128(type(int128).max) - _delta + 1, uint128(type(int128).max)));

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _delta, 0, true);
    _setStaked(_dstTokenId, _dstStaked, 0, true);
    uint128 _supplyBefore = uint128(uint256(_delta) + _dstStaked);
    _setSupplyAndPermanent(_supplyBefore, _supplyBefore);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with AmountExceedsCap
    vm.expectRevert(IVotingEscrow.AmountExceedsCap.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(_dstTokenId, _delta, address(0))));
  }

  /// @dev Drives `_staked[0].amount + _delta > int128.max` so `_applyDestinationAccumulate` trips the cap
  ///      guard on the accumulator path. Source holds exactly `_delta`; accumulator is seeded close to the
  ///      signed limit.
  function test_WhenTheAccumulatorDestinationCreditOverflowsTheSignedLimit(
    uint256 _srcTokenId,
    uint128 _delta,
    uint128 _accStaked
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _delta = uint128(bound(_delta, 1, uint128(type(int128).max)));
    _accStaked = uint128(bound(_accStaked, uint128(type(int128).max) - _delta + 1, uint128(type(int128).max)));

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _delta, 0, true);
    _setStaked(0, _accStaked, 0, false);
    uint128 _supplyBefore = uint128(uint256(_delta) + _accStaked);
    _setSupplyAndPermanent(_supplyBefore, _supplyBefore);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with AmountExceedsCap
    vm.expectRevert(IVotingEscrow.AmountExceedsCap.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(0, _delta, address(0))));
  }

  /// @dev Drives `0 + _delta > int128.max` so `_commit` trips the cap guard on the mint path. Source
  ///      pays the `_delta` so the BalanceMismatch check is satisfied; the destination tokenId sentinel
  ///      `type(uint256).max` requests a fresh mint that must respect the cap.
  function test_WhenTheMintDestinationValueExceedsTheSignedCap(
    uint256 _srcTokenId,
    uint128 _firstInvalid,
    address _recipient
  ) external {
    _assumeFuzzable(_recipient);
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _firstInvalid = uint128(bound(_firstInvalid, uint128(type(int128).max) + 1, type(uint128).max));

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _firstInvalid, 0, true);
    _setSupplyAndPermanent(_firstInvalid, _firstInvalid);
    _setOperatorApproval(_owner, _vpm, true);

    // it should revert with AmountExceedsCap
    vm.expectRevert(IVotingEscrow.AmountExceedsCap.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(
      _wrapSrc(_src(_srcTokenId, _firstInvalid)), _wrap(_dst(type(uint256).max, _firstInvalid, _recipient))
    );
  }

  function test_WhenMovingTheFullBalanceFromOneDecayStakeToAnotherDecayStake(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _amount,
    uint48 _srcEnd
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _amount = uint128(bound(_amount, 1, _DECAY_AMOUNT_CAP));
    _srcEnd = uint48(bound(_srcEnd, _WEEK + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _amount, _srcEnd, false);
    _setStaked(_dstTokenId, _amount, _srcEnd, false); // dst end equals src end -> monotonic rule passes
    uint128 _supplyBefore = uint128(uint256(_amount) * 2);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = _wrapSrc(_src(_srcTokenId, _amount));
    IVotingEscrow.DestinationDelta[] memory _destinations = _wrap(_dst(_dstTokenId, _amount, address(0)));

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);
    // it should emit a MetadataUpdate event for the destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_dstTokenId);
    // it should emit the Rebalance event
    vm.expectEmit(address(_ve));
    emit IVotingEscrow.Rebalance(_sources, _destinations);

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(_sources, _destinations);

    // it should zero the source staked amount
    assertEq(_ve.staked(_srcTokenId).amount, 0);
    // it should bump the destination staked amount by the delta
    assertEq(_ve.staked(_dstTokenId).amount, uint128(uint256(_amount) * 2));
    // it should leave supply unchanged
    assertEq(_ve.supply(), _supplyBefore);
    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), 0);
    // it should return an empty minted ids array
    assertEq(_mintedIds.length, 0);
    _assertGlobalPointInvariants();
  }

  function test_WhenMovingFromAPermanentSourceToAnExistingPermanentDestination(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint128 _srcStaked,
    uint128 _dstStaked,
    uint128 _delta
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    _srcStaked = uint128(bound(_srcStaked, 1, uint128(type(int128).max) / 2));
    _dstStaked = uint128(bound(_dstStaked, 1, uint128(type(int128).max) / 2));
    _delta = uint128(bound(_delta, 1, _srcStaked));

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _srcStaked, 0, true);
    _setStaked(_dstTokenId, _dstStaked, 0, true);
    uint128 _supplyBefore = uint128(uint256(_srcStaked) + _dstStaked);
    _setSupplyAndPermanent(_supplyBefore, _supplyBefore);
    _setOperatorApproval(_owner, _vpm, true);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);
    // it should emit a MetadataUpdate event for the destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_dstTokenId);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(_dstTokenId, _delta, address(0))));

    // it should reduce the source staked amount by the delta
    assertEq(_ve.staked(_srcTokenId).amount, _srcStaked - _delta);
    // it should bump the destination staked amount by the delta
    assertEq(_ve.staked(_dstTokenId).amount, _dstStaked + _delta);
    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), _supplyBefore);
    // it should leave supply unchanged
    assertEq(_ve.supply(), _supplyBefore);
    // it should match totalVotingPowerAt to the permanent stake balance
    assertEq(_ve.totalVotingPowerAt(block.timestamp), _supplyBefore, 'totalVotingPowerAt drift');
    _assertGlobalPointInvariants();
  }

  function test_WhenRoutingADecaySourceIntoTheProtocolAccumulator(
    uint256 _srcTokenId,
    uint128 _srcStaked,
    uint128 _delta,
    uint48 _srcEnd
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _srcStaked = uint128(bound(_srcStaked, 1, _DECAY_AMOUNT_CAP));
    _delta = uint128(bound(_delta, 1, _srcStaked));
    _srcEnd = uint48(bound(_srcEnd, _WEEK + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _srcStaked, _srcEnd, false);
    _setSupplyAndPermanent(_srcStaked, 0);
    _setOperatorApproval(_owner, _vpm, true);

    // it should emit a MetadataUpdate event for the source only
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(0, _delta, address(0))));

    // it should reduce the source staked amount by the delta
    assertEq(_ve.staked(_srcTokenId).amount, _srcStaked - _delta);
    // it should bump the accumulator staked amount by the delta
    assertEq(_ve.staked(0).amount, _delta);
    // it should store the accumulator as a permanent position
    assertTrue(_ve.staked(0).isPermanent);
    // it should bump the permanent stake balance by the delta
    assertEq(_ve.permanentStakeBalance(), _delta);
    // it should leave supply unchanged
    assertEq(_ve.supply(), _srcStaked);
    // it should propagate the accumulator credit into the latest global point
    assertEq(_ve.pointHistory(_ve.epoch()).permanentStakeBalance, _delta);
    // it should reflect the accumulator credit in totalVotingPowerAt
    assertEq(_ve.totalVotingPowerAt(block.timestamp), _delta, 'totalVotingPowerAt drift');
    _assertGlobalPointInvariants();
  }

  function test_WhenMintingFromDecaySources(
    uint256 _srcTokenId,
    uint128 _srcStaked,
    uint48 _srcEnd,
    uint256 _priorCounter,
    address _recipientA,
    address _recipientB
  ) external {
    _assumeFuzzable(_recipientA);
    _assumeFuzzable(_recipientB);
    // Distinct, non-owner recipients so each fresh mint lands at index zero of its own enumeration.
    vm.assume(_recipientA != _recipientB && _recipientA != _owner && _recipientB != _owner);
    // Mints get IDs `_priorCounter + 1`, `_priorCounter + 2`; keep _srcTokenId below the counter so the
    // existing stake's slot does not collide with a freshly minted ID.
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max - 2);
    _priorCounter = bound(_priorCounter, _srcTokenId, type(uint128).max - 2);
    _srcStaked = uint128(bound(_srcStaked, 2, _DECAY_AMOUNT_CAP));
    _srcEnd = uint48(bound(_srcEnd, _WEEK + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    uint128 _amountA = _srcStaked / 2;
    uint128 _amountB = _srcStaked - _amountA;

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _srcStaked, _srcEnd, false);
    _setSupplyAndPermanent(_srcStaked, 0);
    _setTokenIdCounter(_priorCounter);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = _wrapSrc(_src(_srcTokenId, _srcStaked));
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = _dst(type(uint256).max, _amountA, _recipientA);
    _destinations[1] = _dst(type(uint256).max, _amountB, _recipientB);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(_sources, _destinations);

    // it should advance the token id counter by the number of mints
    assertEq(_ve.tokenId(), _priorCounter + 2);
    // it should return the minted ids in input order
    assertEq(_mintedIds.length, 2);
    assertEq(_mintedIds[0], _priorCounter + 1);
    assertEq(_mintedIds[1], _priorCounter + 2);
    // it should mint a new token id to the recipient
    assertEq(_ve.ownerOf(_priorCounter + 1), _recipientA);
    assertEq(_ve.ownerOf(_priorCounter + 2), _recipientB);
    // it should append the minted token to the recipient enumeration
    assertEq(_ve.balanceOf(_recipientA), 1);
    assertEq(_ve.tokenOfOwnerByIndex(_recipientA, 0), _priorCounter + 1);
    assertEq(_ve.balanceOf(_recipientB), 1);
    assertEq(_ve.tokenOfOwnerByIndex(_recipientB, 0), _priorCounter + 2);
    // it should record the new staked balance with the maximum source unlock
    IVotingEscrow.StakedBalance memory _mintedA = _ve.staked(_priorCounter + 1);
    IVotingEscrow.StakedBalance memory _mintedB = _ve.staked(_priorCounter + 2);
    assertEq(_mintedA.amount, _amountA);
    assertEq(_mintedA.end, _srcEnd);
    assertFalse(_mintedA.isPermanent);
    assertEq(_mintedB.amount, _amountB);
    assertEq(_mintedB.end, _srcEnd);
    assertFalse(_mintedB.isPermanent);
    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), 0);
    _assertGlobalPointInvariants();
  }

  function test_WhenMintingFromAPermanentSource(
    uint256 _srcTokenId,
    uint128 _amount,
    uint256 _priorCounter,
    address _recipient
  ) external {
    _assumeFuzzable(_recipient);
    // The mint gets ID `_priorCounter + 1`; keep _srcTokenId at or below _priorCounter so the existing
    // stake's slot does not collide with the new mint.
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max - 1);
    _priorCounter = bound(_priorCounter, _srcTokenId, type(uint128).max - 1);
    _amount = uint128(bound(_amount, 1, uint128(type(int128).max) / 2));

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _amount, 0, true);
    _setSupplyAndPermanent(_amount, _amount);
    _setTokenIdCounter(_priorCounter);
    _setOperatorApproval(_owner, _vpm, true);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(
      _wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(type(uint256).max, _amount, _recipient))
    );

    assertEq(_mintedIds.length, 1);
    uint256 _newId = _mintedIds[0];
    assertEq(_newId, _priorCounter + 1);
    // it should mint a permanent stake to the recipient
    assertEq(_ve.ownerOf(_newId), _recipient);
    // it should record the new staked balance with zero end and permanent true
    IVotingEscrow.StakedBalance memory _minted = _ve.staked(_newId);
    assertEq(_minted.amount, _amount);
    assertEq(_minted.end, 0);
    assertTrue(_minted.isPermanent);
    // it should bump the permanent stake balance by the minted amount
    // (source decremented by _amount, destination credited _amount; net at _amount)
    assertEq(_ve.permanentStakeBalance(), _amount);
    // it should match totalVotingPowerAt to the unchanged permanent stake balance
    assertEq(_ve.totalVotingPowerAt(block.timestamp), _amount, 'totalVotingPowerAt drift');
    _assertGlobalPointInvariants();
  }

  /// @dev Plant an initial delegatee checkpoint recording `_initialBalance` so subsequent
  ///      `_checkpointDelegatee` calls have a baseline to read from.
  function _seedDelegatee(uint256 _tokenId, address _delegateeOwner, uint256 _initialBalance) internal {
    _setOwner(_tokenId, _delegateeOwner);
    _setNumCheckpoints(_tokenId, 1);
    _setCheckpoint(_tokenId, 0, 1, _delegateeOwner, _initialBalance, 0);
  }

  function test_WhenReducingADelegatedPermanentSource(
    uint256 _srcTokenId,
    uint256 _srcDelegateeId,
    uint256 _dstTokenId,
    uint128 _srcStaked,
    uint128 _delta
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _srcDelegateeId = bound(_srcDelegateeId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _srcDelegateeId);
    vm.assume(_srcTokenId != _dstTokenId);
    vm.assume(_srcDelegateeId != _dstTokenId);
    _srcStaked = uint128(bound(_srcStaked, 2, uint128(type(int128).max) / 2));
    _delta = uint128(bound(_delta, 1, _srcStaked));

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _srcStaked, 0, true);
    _setStaked(_dstTokenId, _srcStaked, 0, true);
    _setSupplyAndPermanent(uint128(uint256(_srcStaked) * 2), uint128(uint256(_srcStaked) * 2));
    _setDelegate(_srcTokenId, _srcDelegateeId);
    _seedDelegatee(_srcDelegateeId, makeAddr('SrcDelegateeOwner'), _srcStaked);
    _setOperatorApproval(_owner, _vpm, true);

    // Advance so the new checkpoint appends rather than overwrites the seed at index 0.
    vm.warp(2);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);
    // it should emit a MetadataUpdate event for the destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_dstTokenId);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(_dstTokenId, _delta, address(0))));

    // it should decrease the delegatee's recorded balance by the moved amount
    assertEq(_ve.numCheckpoints(_srcDelegateeId), 2);
    assertEq(_ve.checkpoints(_srcDelegateeId, 1).delegatedBalance, uint256(_srcStaked) - _delta);
    // it should reflect the reduced delegated balance in getPastVotes
    assertEq(
      _ve.getPastVotes(makeAddr('SrcDelegateeOwner'), _srcDelegateeId, block.timestamp),
      uint256(_srcStaked) - _delta,
      'getPastVotes drift'
    );
    _assertGlobalPointInvariants();
  }

  function test_WhenCreditingADelegatedPermanentAddDestination(
    uint256 _srcTokenId,
    uint256 _dstTokenId,
    uint256 _dstDelegateeId,
    uint128 _dstStaked,
    uint128 _delta
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    _dstDelegateeId = bound(_dstDelegateeId, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenId);
    vm.assume(_srcTokenId != _dstDelegateeId);
    vm.assume(_dstTokenId != _dstDelegateeId);
    _dstStaked = uint128(bound(_dstStaked, 1, uint128(type(int128).max) / 2));
    _delta = uint128(bound(_delta, 1, _dstStaked));

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    // src is permanent and undelegated; the rebalance moves `_delta` from src to dst.
    _setStaked(_srcTokenId, _dstStaked, 0, true);
    _setStaked(_dstTokenId, _dstStaked, 0, true);
    _setSupplyAndPermanent(uint128(uint256(_dstStaked) * 2), uint128(uint256(_dstStaked) * 2));
    _setDelegate(_dstTokenId, _dstDelegateeId);
    _seedDelegatee(_dstDelegateeId, makeAddr('DstDelegateeOwner'), _dstStaked);
    _setOperatorApproval(_owner, _vpm, true);

    vm.warp(2);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_srcTokenId);
    // it should emit a MetadataUpdate event for the destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_dstTokenId);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(_dstTokenId, _delta, address(0))));

    // it should increase the delegatee's recorded balance by the moved amount
    assertEq(_ve.numCheckpoints(_dstDelegateeId), 2);
    assertEq(_ve.checkpoints(_dstDelegateeId, 1).delegatedBalance, uint256(_dstStaked) + _delta);
    // it should reflect the increased delegated balance in getPastVotes
    assertEq(
      _ve.getPastVotes(makeAddr('DstDelegateeOwner'), _dstDelegateeId, block.timestamp),
      uint256(_dstStaked) + _delta,
      'getPastVotes drift'
    );
    _assertGlobalPointInvariants();
  }

  struct DelegatedPair {
    uint256 srcTokenId;
    uint256 srcDelegateeId;
    uint256 dstTokenId;
    uint256 dstDelegateeId;
    uint128 srcStaked;
    uint128 dstStaked;
    uint128 delta;
  }

  function _boundDelegatedPair(DelegatedPair memory _c) internal pure {
    _c.srcTokenId = bound(_c.srcTokenId, 1, type(uint128).max);
    _c.srcDelegateeId = bound(_c.srcDelegateeId, 1, type(uint128).max);
    _c.dstTokenId = bound(_c.dstTokenId, 1, type(uint128).max);
    _c.dstDelegateeId = bound(_c.dstDelegateeId, 1, type(uint128).max);
    _c.srcStaked = uint128(bound(_c.srcStaked, 1, uint128(type(int128).max) / 4));
    _c.dstStaked = uint128(bound(_c.dstStaked, 1, uint128(type(int128).max) / 4));
    _c.delta = uint128(bound(_c.delta, 1, _c.srcStaked));
  }

  function test_WhenRebalancingBetweenTwoDistinctDelegatedPermanentStakes(DelegatedPair memory _c) external {
    _boundDelegatedPair(_c);
    vm.assume(_c.srcTokenId != _c.dstTokenId);
    vm.assume(_c.srcTokenId != _c.srcDelegateeId);
    vm.assume(_c.srcTokenId != _c.dstDelegateeId);
    vm.assume(_c.dstTokenId != _c.srcDelegateeId);
    vm.assume(_c.dstTokenId != _c.dstDelegateeId);
    vm.assume(_c.srcDelegateeId != _c.dstDelegateeId);

    _setOwner(_c.srcTokenId, _owner);
    _setOwner(_c.dstTokenId, _owner);
    _setStaked(_c.srcTokenId, _c.srcStaked, 0, true);
    _setStaked(_c.dstTokenId, _c.dstStaked, 0, true);
    uint128 _supply = uint128(uint256(_c.srcStaked) + _c.dstStaked);
    _setSupplyAndPermanent(_supply, _supply);
    _setDelegate(_c.srcTokenId, _c.srcDelegateeId);
    _setDelegate(_c.dstTokenId, _c.dstDelegateeId);
    _seedDelegatee(_c.srcDelegateeId, makeAddr('SrcDelegateeOwner'), _c.srcStaked);
    _seedDelegatee(_c.dstDelegateeId, makeAddr('DstDelegateeOwner'), _c.dstStaked);
    _setOperatorApproval(_owner, _vpm, true);

    vm.warp(2);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_c.srcTokenId);
    // it should emit a MetadataUpdate event for the destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_c.dstTokenId);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_c.srcTokenId, _c.delta)), _wrap(_dst(_c.dstTokenId, _c.delta, address(0))));

    // it should decrease the source delegatee's recorded balance by the moved amount
    assertEq(_ve.numCheckpoints(_c.srcDelegateeId), 2);
    assertEq(_ve.checkpoints(_c.srcDelegateeId, 1).delegatedBalance, uint256(_c.srcStaked) - _c.delta);
    // it should increase the destination delegatee's recorded balance by the moved amount
    assertEq(_ve.numCheckpoints(_c.dstDelegateeId), 2);
    assertEq(_ve.checkpoints(_c.dstDelegateeId, 1).delegatedBalance, uint256(_c.dstStaked) + _c.delta);
    // it should reflect both updated balances in getPastVotes
    assertEq(
      _ve.getPastVotes(makeAddr('SrcDelegateeOwner'), _c.srcDelegateeId, block.timestamp),
      uint256(_c.srcStaked) - _c.delta,
      'src getPastVotes drift'
    );
    assertEq(
      _ve.getPastVotes(makeAddr('DstDelegateeOwner'), _c.dstDelegateeId, block.timestamp),
      uint256(_c.dstStaked) + _c.delta,
      'dst getPastVotes drift'
    );
    // it should keep total supply equal to the unchanged permanent balance
    assertEq(_ve.totalVotingPowerAt(block.timestamp), _supply, 'totalVotingPowerAt drift');
    _assertGlobalPointInvariants();
  }

  struct MixedCase {
    uint256 srcTokenId;
    uint256 addDstTokenId;
    uint256 priorCounter;
    uint128 srcStaked;
    uint128 addDstStaked;
    uint48 srcEnd;
    address mintRecipient;
    uint128 accSlice;
    uint128 mintSlice;
    uint128 addSlice;
    uint128 supplyBefore;
  }

  function _boundMixedCase(MixedCase memory _c) internal pure {
    _c.srcTokenId = bound(_c.srcTokenId, 1, type(uint128).max - 1);
    _c.addDstTokenId = bound(_c.addDstTokenId, 1, type(uint128).max - 1);
    vm.assume(_c.srcTokenId != _c.addDstTokenId);
    uint256 _floor = _c.srcTokenId > _c.addDstTokenId ? _c.srcTokenId : _c.addDstTokenId;
    _c.priorCounter = bound(_c.priorCounter, _floor, type(uint128).max - 1);
    _c.srcStaked = uint128(bound(_c.srcStaked, 3, _DECAY_AMOUNT_CAP));
    _c.addDstStaked = uint128(bound(_c.addDstStaked, 1, _DECAY_AMOUNT_CAP));
    _c.srcEnd = uint48(bound(_c.srcEnd, _WEEK + 1, type(uint48).max - 1));
    // Split the source amount three ways; the add slice absorbs the rounding remainder.
    _c.accSlice = _c.srcStaked / 3;
    _c.mintSlice = _c.srcStaked / 3;
    _c.addSlice = _c.srcStaked - _c.accSlice - _c.mintSlice;
    _c.supplyBefore = uint128(uint256(_c.srcStaked) + _c.addDstStaked);
  }

  function _setupMixedCase(MixedCase memory _c) internal {
    _setOwner(_c.srcTokenId, _owner);
    _setOwner(_c.addDstTokenId, _owner);
    _setStaked(_c.srcTokenId, _c.srcStaked, _c.srcEnd, false);
    // Add destination's unlock must be at least the source unlock to satisfy the monotonic rule.
    _setStaked(_c.addDstTokenId, _c.addDstStaked, _c.srcEnd, false);
    _setSupplyAndPermanent(_c.supplyBefore, 0);
    _setTokenIdCounter(_c.priorCounter);
    _setOperatorApproval(_owner, _vpm, true);
  }

  function _runMixedCase(MixedCase memory _c) internal returns (uint256[] memory _mintedIds) {
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](3);
    _destinations[0] = _dst(0, _c.accSlice, address(0));
    _destinations[1] = _dst(type(uint256).max, _c.mintSlice, _c.mintRecipient);
    _destinations[2] = _dst(_c.addDstTokenId, _c.addSlice, address(0));
    vm.prank(_vpm);
    _mintedIds = _ve.rebalanceUnderlying(_wrapSrc(_src(_c.srcTokenId, _c.srcStaked)), _destinations);
  }

  function _assertMintedDecayStake(uint256 _mintedId, address _recipient, uint128 _amount, uint48 _end) internal view {
    assertEq(_ve.ownerOf(_mintedId), _recipient);
    IVotingEscrow.StakedBalance memory _minted = _ve.staked(_mintedId);
    assertEq(_minted.amount, _amount);
    assertEq(_minted.end, _end);
    assertFalse(_minted.isPermanent);
  }

  function test_WhenOneDecaySourceFeedsAnAccumulatorAMintAndAnAddInASingleCall(MixedCase memory _c) external {
    _assumeFuzzable(_c.mintRecipient);
    vm.assume(_c.mintRecipient != _owner);
    _boundMixedCase(_c);
    vm.warp(_WEEK);
    _setupMixedCase(_c);

    // it should emit a MetadataUpdate event for the source
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_c.srcTokenId);
    // it should emit a MetadataUpdate event for the add destination
    vm.expectEmit(address(_ve));
    emit IERC4906.MetadataUpdate(_c.addDstTokenId);

    uint256[] memory _mintedIds = _runMixedCase(_c);

    // it should return the minted ids in input order
    assertEq(_mintedIds.length, 1);
    assertEq(_mintedIds[0], _c.priorCounter + 1);
    // it should reduce the source staked amount by the total moved
    assertEq(_ve.staked(_c.srcTokenId).amount, 0);
    // it should bump the accumulator staked amount by the accumulator slice
    assertEq(_ve.staked(0).amount, _c.accSlice);
    // it should mint a new token id to the recipient with the maximum source unlock
    _assertMintedDecayStake(_c.priorCounter + 1, _c.mintRecipient, _c.mintSlice, _c.srcEnd);
    // it should bump the existing add destination staked amount by the add slice
    assertEq(_ve.staked(_c.addDstTokenId).amount, _c.addDstStaked + _c.addSlice);
    assertEq(_ve.staked(_c.addDstTokenId).end, _c.srcEnd);
    // it should bump the permanent stake balance by the accumulator slice only
    assertEq(_ve.permanentStakeBalance(), _c.accSlice);
    // it should leave supply unchanged
    assertEq(_ve.supply(), _c.supplyBefore);
    _assertGlobalPointInvariants();
  }

  // Pin the chain0 mirror: the Voter must receive the sources verbatim and the destinations with RESOLVED
  // tokenIds (mint sentinel replaced by the freshly assigned id, add and accumulator ids unchanged) and the
  // original amounts and recipients. No other test observes this call, so dropping the mirror, the resolved-id
  // assignment, or the `_resolvedDestinations[i]` write would otherwise go unnoticed.
  function test_WhenAMixedRebalanceMirrorsOntoTheVoterChainZeroLedger(MixedCase memory _c) external {
    _assumeFuzzable(_c.mintRecipient);
    vm.assume(_c.mintRecipient != _owner);
    _boundMixedCase(_c);
    vm.warp(_WEEK);
    _setupMixedCase(_c);

    IVotingEscrow.SourceDelta[] memory _sources = _wrapSrc(_src(_c.srcTokenId, _c.srcStaked));
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](3);
    _destinations[0] = _dst(0, _c.accSlice, address(0));
    _destinations[1] = _dst(type(uint256).max, _c.mintSlice, _c.mintRecipient);
    _destinations[2] = _dst(_c.addDstTokenId, _c.addSlice, address(0));

    // The mint leg resolves to the next counter value; the accumulator and add legs keep their input ids.
    IVotingEscrow.DestinationDelta[] memory _resolved = new IVotingEscrow.DestinationDelta[](3);
    _resolved[0] = _dst(0, _c.accSlice, address(0));
    _resolved[1] = _dst(_c.priorCounter + 1, _c.mintSlice, _c.mintRecipient);
    _resolved[2] = _dst(_c.addDstTokenId, _c.addSlice, address(0));

    // it should call rebalanceChain0 exactly once with the sources forwarded as is
    // it should credit the resolved destination token ids with unchanged amounts and recipients
    vm.expectCall(_voter, abi.encodeCall(IVoter.rebalanceChain0, (_sources, _resolved)), 1);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_sources, _destinations);
  }

  /// @dev Unlike the storage-seeded cases above, this case creates the source through the real
  ///      `createStake` flow so the source's slope and bias are genuinely written into the global
  ///      point and `slopeChanges`. The oracle is the sum of per-token balances (user-point path),
  ///      independent from the global accounting under test.
  function test_WhenRebalancingFromACheckpointedDecaySource(
    uint128 _srcAmount,
    uint128 _delta,
    uint48 _stakingWeeks,
    address _recipient
  ) external {
    _assumeFuzzable(_recipient);
    _srcAmount = uint128(bound(_srcAmount, 2e18, _DECAY_AMOUNT_CAP));
    // Keep the delta large enough that the moved slope (`_delta / iMAXTIME`, iMAXTIME ~ 1.26e8)
    // floors to a nonzero value, so the rebalance must visibly shrink the global slope and bias.
    _delta = uint128(bound(_delta, 1e18, _srcAmount / 2));
    _stakingWeeks = uint48(bound(_stakingWeeks, 1, _MAXTIME / _WEEK - 1));
    vm.warp(_WEEK);

    _mockTransferFrom(_owner, address(_ve), _srcAmount);
    vm.prank(_owner);
    uint256 _srcTokenId = _ve.createStake(_srcAmount, _stakingWeeks, false);
    uint256 _srcSupplyBefore = _ve.balanceOfNFT(_srcTokenId);
    uint256 _supplyBefore = _ve.totalVotingPower();
    _setOperatorApproval(_owner, _vpm, true);

    vm.prank(_vpm);
    uint256[] memory _mintedIds =
      _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _delta)), _wrap(_dst(type(uint256).max, _delta, _recipient)));

    // it should reduce the global voting supply by the source delta
    uint256 _moved = _srcSupplyBefore - _ve.balanceOfNFT(_srcTokenId);
    assertEq(_ve.totalVotingPower(), _supplyBefore - _moved + _ve.balanceOfNFT(_mintedIds[0]), 'supply delta drift');
    // it should keep total supply equal to the sum of the remaining token balances
    uint256 _expectedSupply = _ve.balanceOfNFT(_srcTokenId) + _ve.balanceOfNFT(_mintedIds[0]);
    assertEq(_ve.totalVotingPower(), _expectedSupply, 'global supply inflated');
    _assertGlobalPointInvariants();
  }

  // RU-1: exercise the running-max leg `_srcEnd > _maxSourceEnd` with TWO sources whose ends differ, so the
  // minted destination must inherit `max(E1, E2)`. Every other test uses a single source, leaving this branch
  // uncovered.
  function test_WhenTwoDecaySourcesWithDistinctUnlocksDrainIntoOneMint(
    uint256 _srcTokenIdA,
    uint256 _srcTokenIdB,
    uint128 _amountA,
    uint128 _amountB,
    uint48 _endLow,
    address _recipient
  ) external {
    _assumeFuzzable(_recipient);
    _srcTokenIdA = bound(_srcTokenIdA, 1, type(uint128).max - 1);
    _srcTokenIdB = bound(_srcTokenIdB, 1, type(uint128).max - 1);
    vm.assume(_srcTokenIdA != _srcTokenIdB);
    _amountA = uint128(bound(_amountA, 1, _DECAY_AMOUNT_CAP));
    _amountB = uint128(bound(_amountB, 1, _DECAY_AMOUNT_CAP));
    // E2 (the low end) sits at least one week ahead; E1 (the high end) strictly above it. The mint must inherit E1.
    _endLow = uint48(bound(_endLow, _WEEK + 1, type(uint48).max - 2));
    uint48 _endHigh = uint48(bound(uint256(_endLow) + 1, uint256(_endLow) + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    // Source A carries the LATER end so `_maxSourceEnd` must climb to it; source B is processed first with the
    // earlier end so the running-max comparison genuinely fires on the second iteration.
    _setOwner(_srcTokenIdA, _owner);
    _setOwner(_srcTokenIdB, _owner);
    _setStaked(_srcTokenIdA, _amountA, _endHigh, false);
    _setStaked(_srcTokenIdB, _amountB, _endLow, false);
    uint128 _supplyBefore = uint128(uint256(_amountA) + _amountB);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setTokenIdCounter(type(uint128).max);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    // Order: B (earlier end) first, A (later end) second, so the running max updates on the second pass.
    _sources[0] = _src(_srcTokenIdB, _amountB);
    _sources[1] = _src(_srcTokenIdA, _amountA);
    IVotingEscrow.DestinationDelta[] memory _destinations = _wrap(_dst(type(uint256).max, _supplyBefore, _recipient));

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(_sources, _destinations);

    // it should record the minted unlock as the latest source unlock
    assertEq(_mintedIds.length, 1);
    IVotingEscrow.StakedBalance memory _minted = _ve.staked(_mintedIds[0]);
    assertEq(_minted.end, _endHigh, 'minted end must be max source end');
    assertEq(_minted.amount, _supplyBefore);
    assertFalse(_minted.isPermanent);
    // it should zero both source staked amounts
    assertEq(_ve.staked(_srcTokenIdA).amount, 0);
    assertEq(_ve.staked(_srcTokenIdB).amount, 0);
    // it should return the single minted id
    assertEq(_mintedIds[0], uint256(type(uint128).max) + 1);
    _assertGlobalPointInvariants();
  }

  // RU-1: the reversed ordering. With the HIGH end first the running max must HOLD at E1 while the second
  // iteration presents the lower E2; a mutant that always assigns (or assigns on `!=`) would clobber the max
  // down to E2 and mint with the wrong unlock. The [low, high] ordering above cannot tell these apart because
  // there the max legitimately equals the last element.
  function test_WhenTwoDecaySourcesDrainIntoOneMintWithTheLaterUnlockFirst(
    uint256 _srcTokenIdA,
    uint256 _srcTokenIdB,
    uint128 _amountA,
    uint128 _amountB,
    uint48 _endLow,
    address _recipient
  ) external {
    _assumeFuzzable(_recipient);
    _srcTokenIdA = bound(_srcTokenIdA, 1, type(uint128).max - 1);
    _srcTokenIdB = bound(_srcTokenIdB, 1, type(uint128).max - 1);
    vm.assume(_srcTokenIdA != _srcTokenIdB);
    _amountA = uint128(bound(_amountA, 1, _DECAY_AMOUNT_CAP));
    _amountB = uint128(bound(_amountB, 1, _DECAY_AMOUNT_CAP));
    // E2 (the low end) sits at least one week ahead; E1 (the high end) strictly above it. The mint must inherit E1.
    _endLow = uint48(bound(_endLow, _WEEK + 1, type(uint48).max - 2));
    uint48 _endHigh = uint48(bound(uint256(_endLow) + 1, uint256(_endLow) + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    // Source A carries the LATER end and is processed FIRST, so `_maxSourceEnd` locks onto E1 up front and must
    // survive the second iteration's lower E2 untouched.
    _setOwner(_srcTokenIdA, _owner);
    _setOwner(_srcTokenIdB, _owner);
    _setStaked(_srcTokenIdA, _amountA, _endHigh, false);
    _setStaked(_srcTokenIdB, _amountB, _endLow, false);
    uint128 _supplyBefore = uint128(uint256(_amountA) + _amountB);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setTokenIdCounter(type(uint128).max);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    // Order: A (later end) first, B (earlier end) second, so the running max must resist being overwritten.
    _sources[0] = _src(_srcTokenIdA, _amountA);
    _sources[1] = _src(_srcTokenIdB, _amountB);
    IVotingEscrow.DestinationDelta[] memory _destinations = _wrap(_dst(type(uint256).max, _supplyBefore, _recipient));

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(_sources, _destinations);

    // it should record the minted unlock as the latest source unlock
    assertEq(_mintedIds.length, 1);
    IVotingEscrow.StakedBalance memory _minted = _ve.staked(_mintedIds[0]);
    assertEq(_minted.end, _endHigh, 'minted end must be max source end');
    assertEq(_minted.amount, _supplyBefore);
    assertFalse(_minted.isPermanent);
    // it should zero both source staked amounts
    assertEq(_ve.staked(_srcTokenIdA).amount, 0);
    assertEq(_ve.staked(_srcTokenIdB).amount, 0);
    // it should return the single minted id
    assertEq(_mintedIds[0], uint256(type(uint128).max) + 1);
    _assertGlobalPointInvariants();
  }

  // RU-1: the other leg. An ADD destination whose end lies strictly between E2 and E1 is earlier than the
  // running max E1, so the monotonic-unlock rule (`_maxSourceEnd > _minDestEnd`) must revert.
  function test_WhenAnAddDestinationUnlockLiesBetweenTheTwoSourceUnlocks(
    uint256 _srcTokenIdA,
    uint256 _srcTokenIdB,
    uint256 _dstTokenId,
    uint128 _amount,
    uint48 _endMid
  ) external {
    _srcTokenIdA = bound(_srcTokenIdA, 1, type(uint128).max);
    _srcTokenIdB = bound(_srcTokenIdB, 1, type(uint128).max);
    _dstTokenId = bound(_dstTokenId, 1, type(uint128).max);
    vm.assume(_srcTokenIdA != _srcTokenIdB);
    vm.assume(_srcTokenIdA != _dstTokenId);
    vm.assume(_srcTokenIdB != _dstTokenId);
    _amount = uint128(bound(_amount, 1, _DECAY_AMOUNT_CAP));
    // E2 < midEnd < E1: low end one week ahead, mid strictly above it, high strictly above mid.
    uint48 _endLow = uint48(_WEEK + 1);
    _endMid = uint48(bound(_endMid, uint256(_endLow) + 1, type(uint48).max - 2));
    uint48 _endHigh = uint48(bound(uint256(_endMid) + 1, uint256(_endMid) + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenIdA, _owner);
    _setOwner(_srcTokenIdB, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenIdA, _amount, _endHigh, false);
    _setStaked(_srcTokenIdB, _amount, _endLow, false);
    _setStaked(_dstTokenId, _amount, _endMid, false);
    uint128 _supplyBefore = uint128(uint256(_amount) * 3);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setOperatorApproval(_owner, _vpm, true);

    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](2);
    _sources[0] = _src(_srcTokenIdB, _amount);
    _sources[1] = _src(_srcTokenIdA, _amount);
    // Move the full 2*_amount drained from both sources into the mid-end add destination.
    IVotingEscrow.DestinationDelta[] memory _destinations =
      _wrap(_dst(_dstTokenId, uint128(uint256(_amount) * 2), address(0)));

    // it should revert with UnlockTimeReduction
    vm.expectRevert(IVotingEscrow.UnlockTimeReduction.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_sources, _destinations);
  }

  // Exercise the running-min leg `_dstEnd < _minDestEnd` with TWO add destinations ordered [earlier, later], so
  // the minimum is NOT the last element processed. The source unlock lies strictly between the two, violating
  // the monotonic rule only against the EARLIER destination; a mutant that always assigns (or assigns on `!=`)
  // would leave the min at the later end and let the call slip through.
  function test_WhenTheEarlierOfTwoAddDestinationUnlocksPrecedesTheSourceUnlock(
    uint256 _srcTokenId,
    uint256 _dstTokenIdA,
    uint256 _dstTokenIdB,
    uint128 _amount,
    uint48 _endMid
  ) external {
    _srcTokenId = bound(_srcTokenId, 1, type(uint128).max);
    _dstTokenIdA = bound(_dstTokenIdA, 1, type(uint128).max);
    _dstTokenIdB = bound(_dstTokenIdB, 1, type(uint128).max);
    vm.assume(_srcTokenId != _dstTokenIdA);
    vm.assume(_srcTokenId != _dstTokenIdB);
    vm.assume(_dstTokenIdA != _dstTokenIdB);
    _amount = uint128(bound(_amount, 2, _DECAY_AMOUNT_CAP));
    // dstA end < src end < dstB end: low end one week ahead, mid strictly above it, high strictly above mid.
    uint48 _endLow = uint48(_WEEK + 1);
    _endMid = uint48(bound(_endMid, uint256(_endLow) + 1, type(uint48).max - 2));
    uint48 _endHigh = uint48(bound(uint256(_endMid) + 1, uint256(_endMid) + 1, type(uint48).max - 1));
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenIdA, _owner);
    _setOwner(_dstTokenIdB, _owner);
    _setStaked(_srcTokenId, _amount, _endMid, false);
    _setStaked(_dstTokenIdA, _amount, _endLow, false);
    _setStaked(_dstTokenIdB, _amount, _endHigh, false);
    uint128 _supplyBefore = uint128(uint256(_amount) * 3);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setOperatorApproval(_owner, _vpm, true);

    // Split the source between both destinations; A (earlier end) first, B (later end) second.
    uint128 _half = _amount / 2;
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = _dst(_dstTokenIdA, _half, address(0));
    _destinations[1] = _dst(_dstTokenIdB, _amount - _half, address(0));

    // it should revert with UnlockTimeReduction
    vm.expectRevert(IVotingEscrow.UnlockTimeReduction.selector);
    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _amount)), _destinations);
  }

  // RU-3: strengthen the decay full-move case by inspecting the user-point and slope-change writes, which the
  // existing `test_WhenMovingTheFullBalanceFromOneDecayStakeToAnotherDecayStake` leaves unasserted.
  //
  // Inputs are chosen so the integer slope math is EXACT. With value = k * _IMAXTIME the slope is exactly k:
  //   srcStaked = 2 * _IMAXTIME = 252_288_000  -> srcSlope  = 2
  //   dstStaked = 3 * _IMAXTIME = 378_432_000  -> dstSlopeOld = 3
  // After the full move the destination holds (2 + 3) * _IMAXTIME -> dstSlopeNew = 5; the source holds 0.
  // Ends are whole weeks ahead of `now = _WEEK`, so the bias = slope * (end - now) is a clean literal.
  //   now      = _WEEK                = 604_800
  //   end      = 20 * _WEEK           = 12_096_000  -> (end - now) = 11_491_200
  //   srcBiasOld = 2 * 11_491_200 = 22_982_400
  //   dstBiasNew = 5 * 11_491_200 = 57_456_000
  function test_WhenMovingTheFullDecayBalanceIntoAnotherDecayStakeWithCheckpointInspection() external {
    uint256 _srcTokenId = 7;
    uint256 _dstTokenId = 9;
    uint128 _srcStaked = uint128(uint256(int256(_IMAXTIME)) * 2); // slope 2
    uint128 _dstStaked = uint128(uint256(int256(_IMAXTIME)) * 3); // slope 3
    uint48 _end = uint48(20 * uint256(_WEEK)); // 12_096_000, whole weeks ahead
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setOwner(_dstTokenId, _owner);
    _setStaked(_srcTokenId, _srcStaked, _end, false);
    _setStaked(_dstTokenId, _dstStaked, _end, false); // shared end keeps the monotonic rule satisfied
    uint128 _supplyBefore = uint128(uint256(_srcStaked) + _dstStaked);
    _setSupplyAndPermanent(_supplyBefore, 0);
    _setOperatorApproval(_owner, _vpm, true);
    // Pre-seed the scheduled slope change at the shared end to the negated sum of the two slopes, mirroring what
    // the curve would already hold for these two live stakes (-(2 + 3) = -5). The full move keeps the combined
    // slope at this end unchanged, so the scheduled change must remain -5 afterwards.
    _setSlopeChange(_end, -5);

    vm.prank(_vpm);
    _ve.rebalanceUnderlying(_wrapSrc(_src(_srcTokenId, _srcStaked)), _wrap(_dst(_dstTokenId, _srcStaked, address(0))));

    // it should write the source user point slope and bias to zero
    IVotingEscrow.UserPoint memory _srcPoint = _ve.userPointHistory(_srcTokenId, _ve.userPointEpoch(_srcTokenId));
    assertEq(_srcPoint.slope, 0, 'source slope must zero');
    assertEq(_srcPoint.bias, 0, 'source bias must zero');
    // it should write the destination user point slope and bias for the combined amount
    IVotingEscrow.UserPoint memory _dstPoint = _ve.userPointHistory(_dstTokenId, _ve.userPointEpoch(_dstTokenId));
    assertEq(_dstPoint.slope, 5, 'dst slope == 5'); // (2 + 3) * _IMAXTIME / _IMAXTIME
    assertEq(_dstPoint.bias, 57_456_000, 'dst bias == 5 * (end - now)'); // 5 * 11_491_200
    // it should keep the scheduled slope change at the shared end
    // The slope change at `_end` nets: cancel old src (+2), cancel old dst (+3), then re-add new dst (-5) => -5.
    // Because src and dst share the end key, the source's removal and the destination's re-add collapse onto the
    // same slot; the net scheduled change at `_end` stays at the original -5.
    assertEq(_ve.slopeChanges(_end), -5, 'scheduled slope change at shared end stays -5');
    _assertGlobalPointInvariants();
  }

  // RU-4: concrete exact-slope mint. value = k * _IMAXTIME makes the slope exactly k with no rounding, so the
  // minted user point and the folded global point can be asserted against hand-computed LITERALS.
  //   amount = 4 * _IMAXTIME = 504_576_000 -> slope = 4
  //   now    = _WEEK         = 604_800
  //   end    = 30 * _WEEK    = 18_144_000 -> (end - now) = 17_539_200
  //   bias   = 4 * 17_539_200 = 70_156_800
  // The source full-drains (slope 4 -> 0) and the mint re-adds the same slope/bias, so the final global point
  // settles back at slope 4, bias 70_156_800 (the intermediate source step floors to 0, then the mint restores).
  function test_WhenMintingFromADecaySourceWithAnExactSlopeAmount(address _recipient) external {
    _assumeFuzzable(_recipient);
    uint256 _srcTokenId = 11;
    uint128 _amount = uint128(uint256(int256(_IMAXTIME)) * 4); // slope 4
    uint48 _end = uint48(30 * uint256(_WEEK)); // 18_144_000, whole weeks ahead
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _amount, _end, false);
    _setSupplyAndPermanent(_amount, 0);
    _setTokenIdCounter(100);
    _setOperatorApproval(_owner, _vpm, true);

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(
      _wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(type(uint256).max, _amount, _recipient))
    );

    uint256 _mintedId = _mintedIds[0];
    // it should write the minted user point slope and bias as exact literals
    IVotingEscrow.UserPoint memory _mintedPoint = _ve.userPointHistory(_mintedId, _ve.userPointEpoch(_mintedId));
    assertEq(_mintedPoint.slope, 4, 'minted slope == 4'); // 4 * _IMAXTIME / _IMAXTIME
    assertEq(_mintedPoint.bias, 70_156_800, 'minted bias == 4 * (end - now)'); // 4 * 17_539_200
    // it should fold the exact slope and bias into the latest global point
    IVotingEscrow.GlobalPoint memory _global = _ve.pointHistory(_ve.epoch());
    assertEq(_global.slope, 4, 'global slope == 4');
    assertEq(_global.bias, 70_156_800, 'global bias == 70_156_800');
    _assertGlobalPointInvariants();
  }

  // RU-4: sub-_IMAXTIME amount. Any amount strictly below _IMAXTIME (126_144_000) yields slope = amount /
  // _IMAXTIME = 0 under integer division, so both the moved slope and bias floor to zero even on a long unlock.
  //   amount = _IMAXTIME - 1 = 126_143_999 -> slope = 0 -> bias = 0
  function test_WhenMintingFromADecaySourceWithASubMaxtimeAmount(address _recipient) external {
    _assumeFuzzable(_recipient);
    uint256 _srcTokenId = 13;
    uint128 _amount = uint128(uint256(int256(_IMAXTIME)) - 1); // 126_143_999, slope floors to 0
    uint48 _end = uint48(50 * uint256(_WEEK)); // far-future end; slope still floors to 0
    vm.warp(_WEEK);

    _setOwner(_srcTokenId, _owner);
    _setStaked(_srcTokenId, _amount, _end, false);
    _setSupplyAndPermanent(_amount, 0);
    _setTokenIdCounter(200);
    _setOperatorApproval(_owner, _vpm, true);

    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(
      _wrapSrc(_src(_srcTokenId, _amount)), _wrap(_dst(type(uint256).max, _amount, _recipient))
    );

    uint256 _mintedId = _mintedIds[0];
    // it should floor the minted slope and bias to zero
    IVotingEscrow.UserPoint memory _mintedPoint = _ve.userPointHistory(_mintedId, _ve.userPointEpoch(_mintedId));
    assertEq(_mintedPoint.slope, 0, 'sub-maxtime slope floors to 0');
    assertEq(_mintedPoint.bias, 0, 'sub-maxtime bias floors to 0');
    // The amount is still credited on the minted stake even though it carries no decay weight.
    assertEq(_ve.staked(_mintedId).amount, _amount);
    _assertGlobalPointInvariants();
  }

  // `test_WhenTheInputsAreEmpty` is intentionally skipped from the snapshot helper: it pokes storage
  // permanentStakeBalance without triggering any checkpoint, so the global point legitimately diverges
  // from storage as a setup artifact.
  function test_WhenTheInputsAreEmpty(uint128 _permanentBefore, uint256 _counterBefore) external {
    _counterBefore = bound(_counterBefore, 0, type(uint128).max);
    _setTokenIdCounter(_counterBefore);
    _setSupplyAndPermanent(0, _permanentBefore);

    // it should not revert
    vm.prank(_vpm);
    uint256[] memory _mintedIds = _ve.rebalanceUnderlying(_emptySrc(), _empty());

    // it should return an empty minted ids array
    assertEq(_mintedIds.length, 0);
    // it should leave the token id counter unchanged
    assertEq(_ve.tokenId(), _counterBefore);
    // it should leave the permanent stake balance unchanged
    assertEq(_ve.permanentStakeBalance(), _permanentBefore);
    // it should leave totalVotingPowerAt at the unchanged snapshot (zero, since no checkpoint ran in this test)
    assertEq(_ve.totalVotingPowerAt(block.timestamp), 0, 'totalVotingPowerAt drift');
  }
}
