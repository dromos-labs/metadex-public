// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ISplitter} from 'V3/interfaces/splitter/ISplitter.sol';

import {BaseSplitter, Splitter} from 'V3-test/unit/splitter/BaseSplitter.sol';

contract UnitSplitter is BaseSplitter {
  address internal immutable _AUTHORITY = makeAddr('authority');

  // --- constructor ---

  function test_ConstructorWhenRecipientsAndSharesLengthsMismatch(
    address _newToken,
    address _newVoter,
    uint256 _seed,
    uint256 _length
  ) external {
    // Token and voter are never read: the length modifier runs first, so they stay freely fuzzed.
    // LengthMismatch is the first check in `validListLength`, so any valid recipient count exercises it.
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients,) = _fuzzedRecipientsAndShares(_seed, _length);
    // A shares array of a different length than the recipients trips the mismatch guard.
    uint256[] memory _shares = new uint256[](_length + 1);

    // it should revert with LengthMismatch
    vm.expectRevert(ISplitter.LengthMismatch.selector);
    new Splitter(_newToken, _newVoter, _recipients, _shares);
  }

  function test_ConstructorWhenTheInitialListIsEmpty(address _newToken, address _newVoter) external {
    // it should revert with EmptyRecipients
    vm.expectRevert(ISplitter.EmptyRecipients.selector);
    new Splitter(_newToken, _newVoter, new address[](0), new uint256[](0));
  }

  function test_ConstructorWhenTheInitialListExceedsTheMaximum(
    address _newToken,
    address _newVoter,
    uint256 _seed
  ) external {
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _MAX_RECIPIENTS + 1);

    // it should revert with TooManyRecipients
    vm.expectRevert(ISplitter.TooManyRecipients.selector);
    new Splitter(_newToken, _newVoter, _recipients, _shares);
  }

  function test_ConstructorWhenTokenIsZeroAddress(address _newVoter, uint256 _seed, uint256 _length) external {
    // The list must be well-formed to clear the length modifier and reach the token check.
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);

    // it should revert with ZeroAddress
    vm.expectRevert(ISplitter.ZeroAddress.selector);
    new Splitter(address(0), _newVoter, _recipients, _shares);
  }

  function test_ConstructorWhenVoterIsZeroAddress(address _newToken, uint256 _seed, uint256 _length) external {
    // Token must be non-zero (and the list well-formed) so the voter check is the one that reverts.
    _assumeFuzzable(_newToken);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);

    // it should revert with ZeroAddress
    vm.expectRevert(ISplitter.ZeroAddress.selector);
    new Splitter(_newToken, address(0), _recipients, _shares);
  }

  function test_ConstructorWhenTheInitialListIsValid(
    address _newToken,
    address _newVoter,
    uint256 _seed,
    uint256 _length
  ) external {
    _assumeFuzzable(_newToken);
    _assumeFuzzable(_newVoter);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    _splitter = new Splitter(_newToken, _newVoter, _recipients, _shares);

    // it should set the TOKEN immutable to _token
    assertEq(_splitter.TOKEN(), _newToken);
    // it should set the VOTER immutable to _voter
    assertEq(_splitter.VOTER(), _newVoter);
    for (uint256 _i; _i < _length; ++_i) {
      // it should write _initialRecipients in insertion order
      assertEq(_splitter.recipients(_i), _recipients[_i]);
      (uint256 _sharePips, uint256 _lastIndex,) = _splitter.recipientState(_recipients[_i]);
      // it should set each recipient share from _initialShares
      assertEq(_sharePips, _shares[_i]);
      // it should seed each recipient lastSettledIndex at zero
      assertEq(_lastIndex, 0);
    }
    // it should leave the global accrual index at zero
    assertEq(_splitter.globalAccrualIndex(), 0);
  }

  // --- setRecipients ---

  function test_SetRecipientsWhenRecipientsAndSharesLengthsMismatch(uint256 _seed, uint256 _length) external {
    // The length modifier runs before the authority check, so this reverts for any caller.
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients,) = _fuzzedRecipientsAndShares(_seed, _length);
    // A shares array of a different length than the recipients trips the mismatch guard.
    uint256[] memory _shares = new uint256[](_length + 1);

    // it should revert with LengthMismatch
    vm.expectRevert(ISplitter.LengthMismatch.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenTheNewListIsEmpty() external {
    // it should revert with EmptyRecipients
    vm.expectRevert(ISplitter.EmptyRecipients.selector);
    _splitter.setRecipients(new address[](0), new uint256[](0));
  }

  function test_SetRecipientsWhenTheNewListExceedsTheMaximum(uint256 _seed) external {
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _MAX_RECIPIENTS + 1);

    // it should revert with TooManyRecipients
    vm.expectRevert(ISplitter.TooManyRecipients.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenTheCallerIsNotTheSplitterConfigAuthority(
    address _caller,
    uint256 _seed,
    uint256 _length
  ) external {
    // The list must be well-formed to clear the length modifier and reach the authority check.
    _caller = _boundNotEq(_caller, _AUTHORITY);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    _mockAndExpect(
      _voter, abi.encodeCall(IAccessControl.hasRole, (Roles.SPLITTER_CONFIG_ROLE, _caller)), abi.encode(false)
    );

    // it should revert with UnauthorizedCaller
    vm.expectRevert(ISplitter.UnauthorizedCaller.selector);
    vm.prank(_caller);
    _splitter.setRecipients(_recipients, _shares);
  }

  modifier givenTheCallerIsTheSplitterConfigAuthority() {
    _mockAndExpect(
      _voter, abi.encodeCall(IAccessControl.hasRole, (Roles.SPLITTER_CONFIG_ROLE, _AUTHORITY)), abi.encode(true)
    );
    vm.prank(_AUTHORITY);
    _;
  }

  function test_SetRecipientsWhenANewRecipientIsTheZeroAddress(
    uint256 _seed,
    uint256 _length,
    uint256 _index
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _mockBalance(0);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    _index = bound(_index, 0, _length - 1);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    _recipients[_index] = address(0);

    // it should revert with InvalidRecipient
    vm.expectRevert(ISplitter.InvalidRecipient.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenANewRecipientIsTheSplitterItself(
    uint256 _seed,
    uint256 _length,
    uint256 _index
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _mockBalance(0);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    _index = bound(_index, 0, _length - 1);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    _recipients[_index] = address(_splitter);

    // it should revert with InvalidRecipient
    vm.expectRevert(ISplitter.InvalidRecipient.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenANewRecipientShareIsZero(
    uint256 _seed,
    uint256 _length,
    uint256 _index
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _mockBalance(0);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    _index = bound(_index, 0, _length - 1);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    _shares[_index] = 0;

    // it should revert with ZeroShare
    vm.expectRevert(ISplitter.ZeroShare.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenANewRecipientAppearsMoreThanOnce(
    uint256 _seed,
    uint256 _length,
    uint256 _original,
    uint256 _duplicate
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _mockBalance(0);
    _length = bound(_length, 2, _MAX_RECIPIENTS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    // Repeat one recipient at a different index so the guard trips whichever of the two the loop reaches second.
    _original = bound(_original, 0, _length - 1);
    _duplicate = bound(_duplicate, 0, _length - 2);
    if (_duplicate >= _original) ++_duplicate;
    _recipients[_duplicate] = _recipients[_original];

    // it should revert with DuplicateRecipient
    vm.expectRevert(ISplitter.DuplicateRecipient.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  function test_SetRecipientsWhenTheNewListIsValid(
    uint256 _seed,
    uint256 _length,
    uint256 _inflow
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    // Excluding the setUp seed keeps the new list disjoint from the old one, so the old-recipient assertions hold.
    vm.assume(_seed != _SETUP_SEED);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    _mockAndExpectTokenBalance(_token, address(_splitter), _inflow);

    (address[] memory _newRecipients, uint256[] memory _newShares) = _fuzzedRecipientsAndShares(_seed, _length);

    uint256 _expectedIndex = (_inflow * _SCALE) / _MAX_PIPS;

    // it should emit RecipientsSet with _newRecipients, _newShares
    _expectEmit(address(_splitter));
    emit ISplitter.RecipientsSet(_newRecipients, _newShares);

    _splitter.setRecipients(_newRecipients, _newShares);

    // it should accrue pending inflow into the global accrual index
    assertEq(_splitter.globalAccrualIndex(), _expectedIndex);
    assertEq(_splitter.accountedBalance(), _inflow);
    for (uint256 _i; _i < _RECIPIENT_COUNT; ++_i) {
      (uint256 _sharePips,, uint256 _balance) = _splitter.recipientState(_setupRecipients[_i]);
      // it should settle each old recipient at its old share into claimable
      // Independent of the contract's scaled steps: each old recipient keeps its proportional slice of the inflow.
      assertEq(_balance, (_inflow * _setupShares[_i]) / _MAX_PIPS);
      // it should clear each old recipient share to zero
      assertEq(_sharePips, 0);
    }
    for (uint256 _i; _i < _length; ++_i) {
      // it should replace the recipients array with _newRecipients
      assertEq(_splitter.recipients(_i), _newRecipients[_i]);
      (uint256 _sharePips, uint256 _lastIndex,) = _splitter.recipientState(_newRecipients[_i]);
      // it should set each new recipient share from _newShares
      assertEq(_sharePips, _newShares[_i]);
      // it should set each new recipient lastSettledIndex to the global accrual index
      assertEq(_lastIndex, _expectedIndex);
    }
  }

  function test_SetRecipientsWhenTheNewListKeepsTheSameRecipientsWithNewShares(
    uint256 _seed,
    uint256 _inflow
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    _mockAndExpectTokenBalance(_token, address(_splitter), _inflow);

    // Resubmit the exact setUp recipients with a fresh split (still summing to MAX_PIPS): a shares-only update.
    // The contract clears every old share before re-writing, so reusing an address never trips the duplicate guard.
    (, uint256[] memory _newShares) = _fuzzedRecipientsAndShares(_seed, _RECIPIENT_COUNT);

    uint256 _expectedIndex = (_inflow * _SCALE) / _MAX_PIPS;

    _splitter.setRecipients(_setupRecipients, _newShares);

    // it should accrue pending inflow into the global accrual index
    assertEq(_splitter.globalAccrualIndex(), _expectedIndex);
    for (uint256 _i; _i < _RECIPIENT_COUNT; ++_i) {
      // it should keep the same recipients in the array
      assertEq(_splitter.recipients(_i), _setupRecipients[_i]);
      (uint256 _sharePips, uint256 _lastIndex, uint256 _balance) = _splitter.recipientState(_setupRecipients[_i]);
      // it should preserve each recipient settled balance as claimable
      // Settled at the OLD share before the update, so its already-earned slice survives the reconfiguration.
      assertEq(_balance, (_inflow * _setupShares[_i]) / _MAX_PIPS);
      // it should update each recipient share to the new value
      assertEq(_sharePips, _newShares[_i]);
      // it should reset each recipient lastSettledIndex to the global accrual index
      assertEq(_lastIndex, _expectedIndex);
    }
  }

  function test_SetRecipientsWhenTheNewSharesDoNotSumToTheMaximum(
    uint256 _seed,
    uint256 _length,
    uint256 _excess
  ) external givenTheCallerIsTheSplitterConfigAuthority {
    _mockBalance(0);
    _length = bound(_length, 1, _MAX_RECIPIENTS);
    _excess = bound(_excess, 1, _MAX_PIPS);
    (address[] memory _recipients, uint256[] memory _shares) = _fuzzedRecipientsAndShares(_seed, _length);
    // Inflate one share so the list stays otherwise valid but its sum overshoots MAX_PIPS.
    _shares[0] += _excess;

    // it should revert with InvalidShareSum
    vm.expectRevert(ISplitter.InvalidShareSum.selector);
    _splitter.setRecipients(_recipients, _shares);
  }

  // --- earned ---

  function test_EarnedWhenThereIsNoPendingInflow(uint256 _index, uint256 _claimable) external {
    address _recipient = _setupRecipients[bound(_index, 0, _RECIPIENT_COUNT - 1)];
    _setClaimable(_recipient, _claimable);
    _mockBalance(0);

    // it should return the settled claimable balance
    assertEq(_splitter.earned(_recipient), _claimable);
  }

  function test_EarnedWhenThereIsPendingInflow(uint256 _index, uint256 _inflow, uint256 _claimable) external {
    uint256 _bounded = bound(_index, 0, _RECIPIENT_COUNT - 1);
    address _recipient = _setupRecipients[_bounded];
    _inflow = bound(_inflow, _MAX_PIPS, _MAX_INFLOW);
    uint256 _accrual = (_inflow * _setupShares[_bounded]) / _MAX_PIPS;

    // Leave headroom so the settled balance plus the projected accrual cannot overflow.
    _claimable = bound(_claimable, 0, type(uint256).max - _accrual);
    _setClaimable(_recipient, _claimable);
    _mockBalance(_inflow);

    // it should return claimable plus the projected accrual
    assertEq(_splitter.earned(_recipient), _claimable + _accrual);
  }

  function test_EarnedWhenReadingAConcretePendingInflow() external {
    // A 50% recipient (500_000 pips) with 100 wei already settled, against a 1_000_001 wei pending inflow. By hand:
    //   accrual = floor(500_000 * 1_000_001 / 1_000_000) = floor(500_000.5) = 500_000
    //   earned  = 100 + 500_000                           = 500_100
    address _recipient = _setupRecipients[0];
    _setSharePips(_recipient, 500_000);
    _setClaimable(_recipient, 100);
    _mockBalance(1_000_001);

    // it should return the hardcoded claimable plus projected accrual
    assertEq(_splitter.earned(_recipient), 500_100);
  }

  // --- allRecipients ---

  function test_AllRecipientsWhenCalled() external view {
    // it should return the entire active list
    address[] memory _list = _splitter.allRecipients();
    assertEq(_list.length, _RECIPIENT_COUNT);
    for (uint256 _i; _i < _RECIPIENT_COUNT; ++_i) {
      assertEq(_list[_i], _setupRecipients[_i]);
    }
  }

  // --- storage seed helpers ---

  // Guards the `vm.store` slot derivations the other tests rely on: a wrong slot constant or struct offset would
  // land the value in the wrong place and the getter read-back would catch it. A fresh recipient starts every field
  // at zero, and the distinct per-field sentinels also catch a helper writing into a sibling field's slot.
  function test_StorageSeedHelpersWriteTheExpectedSlots() external {
    address _recipient = makeAddr('seedTarget');

    _setGlobalAccrualIndex(111);
    _setAccountedBalance(222);
    _setSharePips(_recipient, 333);
    _setLastSettledIndex(_recipient, 444);
    _setClaimable(_recipient, 555);

    assertEq(_splitter.globalAccrualIndex(), 111);
    assertEq(_splitter.accountedBalance(), 222);
    (uint256 _sharePips, uint256 _lastIndex, uint256 _claimable) = _splitter.recipientState(_recipient);
    assertEq(_sharePips, 333);
    assertEq(_lastIndex, 444);
    assertEq(_claimable, 555);
  }
}
