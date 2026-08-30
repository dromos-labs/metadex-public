// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

contract UnitVoterPaymentsModulewithdrawToNFT is BaseVoterPaymentsModule {
  bytes4 internal constant _SIG = IVoterPaymentsModule.withdrawToNFT.selector;

  function test_WhenDestinationsIsEmpty(address _caller, uint256 _sourceId) external {
    // it should revert with NoDestinations
    _assumeFuzzable(_caller);
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](0);
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.NoDestinations.selector);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenTheSourceAuthorizationFails(
    address _caller,
    address _recipient,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amount
  ) external {
    // it should revert with NotApprovedByOwner
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amount), _recipient);
    _mockIsAuthorized(_caller, _sourceId, false);
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IVoterPaymentsModule.NotApprovedByOwner.selector, _sourceId));
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  modifier whenTheSourceAuthorizationPasses() {
    _;
  }

  function test_WhenANonMintLegCarriesANonzeroRecipient(
    address _caller,
    address _recipient,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amount
  ) external whenTheSourceAuthorizationPasses {
    // it should revert with NonMintRecipientNotAllowed
    _assumeFuzzable(_caller);
    vm.assume(_recipient != address(0));
    vm.assume(_destTokenId != type(uint256).max); // a non-mint leg
    _amount = bound(_amount, 1, type(uint128).max);
    _mockIsAuthorized(_caller, _sourceId, true);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amount), _recipient);

    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.NonMintRecipientNotAllowed.selector, _destTokenId));
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenAZeroAmountNonMintLegCarriesANonzeroRecipient(
    address _caller,
    address _recipient,
    uint256 _sourceId,
    uint256 _cleanDestId,
    uint256 _dirtyDestId,
    uint256 _amount
  ) external whenTheSourceAuthorizationPasses {
    // it should revert with NonMintRecipientNotAllowed
    // A zero-amount dirty leg trims to nothing and would be dropped before VE, so it never reaches the VE guard;
    // the summing-loop check runs over every caller leg and still catches it. Index 0 carries the whole amount so
    // the total is nonzero (this is not the ZeroWithdraw path), and the dirty leg sits at index 1 to prove the
    // guard visits later legs, not only the first.
    _assumeFuzzable(_caller);
    vm.assume(_recipient != address(0));
    vm.assume(_cleanDestId != type(uint256).max && _dirtyDestId != type(uint256).max);
    _amount = bound(_amount, 1, type(uint128).max);
    _mockIsAuthorized(_caller, _sourceId, true);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_cleanDestId, uint128(_amount), address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_dirtyDestId, 0, _recipient);

    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.NonMintRecipientNotAllowed.selector, _dirtyDestId));
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenTotalDestinationsAmountIsZero(
    address _caller,
    uint256 _sourceId,
    uint256 _destTokenIdA,
    uint256 _destTokenIdB
  ) external whenTheSourceAuthorizationPasses {
    // it should revert with ZeroWithdraw
    _assumeFuzzable(_caller);
    _mockIsAuthorized(_caller, _sourceId, true);
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenIdA, 0, address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_destTokenIdB, 0, address(0));
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.ZeroWithdraw.selector);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  modifier whenTotalDestinationsAmountIsNonzero() {
    _;
  }

  function test_WhenTheOperationIsRestrictedAndTheCallerIsUnregistered(
    address _caller,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amount
  ) external whenTheSourceAuthorizationPasses whenTotalDestinationsAmountIsNonzero {
    // it should revert with NotRegistered
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setRestricted(_SIG, true);
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amount), address(0));
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.NotRegistered.selector);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  modifier whenTheOperationIsPermissionlessOrTheCallerIsRegistered() {
    _;
  }

  function test_WhenAMintSentinelTrimsToZero(
    address _caller,
    address _recipient,
    uint256 _sourceId,
    uint256 _destTokenId
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should drop the mint sentinel from the VE destinations
    // Hand-computed, 10% fee on amounts 100 (real) / 1 (sentinel), totalOut 101:
    //   net = 101 - floor(101*100000/1000000) = 91; trims = floor(100*91/101)=90, floor(1*91/101)=0;
    //   the sentinel trims to zero and is dropped, so no NFT is minted; fee = 101 - 90 = 11.
    _assumeFuzzable(_caller);
    vm.assume(_destTokenId != _sourceId && _destTokenId != type(uint256).max && _destTokenId != 0);
    vm.assume(_sourceId != type(uint256).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 100_000); // 10%

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, 100, address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(type(uint256).max, 1, _recipient);

    // Only the surviving real destination and the fee leg reach VE; the dropped sentinel mints nothing.
    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, 101);
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destTokenId, 90, address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, 11, address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, new uint256[](0));

    vm.expectCall(_ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_expectedSources, _expectedDest)));
    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, 101, 11);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenDestinationsContainMintSentinels(
    address _caller,
    address _recipient,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amountEach,
    uint256 _mintedId
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should rewrite mint sentinels using minted ids
    _assumeFuzzable(_caller);
    _amountEach = bound(_amountEach, 1, type(uint128).max / 4);
    vm.assume(_destTokenId != _sourceId && _destTokenId != type(uint256).max);
    // One destination is the mint sentinel; the source must differ from it.
    vm.assume(_sourceId != type(uint256).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 0);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amountEach), address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(type(uint256).max, uint128(_amountEach), _recipient);

    uint256[] memory _minted = new uint256[](1);
    _minted[0] = _mintedId;

    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, uint128(_amountEach * 2));
    // Rate is zero, so the flooring leaves no dust and the module drops the trailing fee leg.
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amountEach), address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(type(uint256).max, uint128(_amountEach), _recipient);
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, _minted);

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, _amountEach * 2, 0);
    uint256[] memory _result = _vpm.withdrawToNFT(_sourceId, _destinations);
    assertEq(_result.length, 1);
    assertEq(_result[0], _mintedId);
  }

  function test_WhenDestinationsContainAccumulatorEntries(
    address _caller,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amountEach,
    uint128 _rate
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should accept the entry as additional burn alongside the fee leg
    _assumeFuzzable(_caller);
    // Bound rate below 100% and amounts at least PIPS so both the trim and the fee are always positive.
    _rate = uint128(bound(_rate, 1, uint128(MAX_PIPS) - 1));
    _amountEach = bound(_amountEach, MAX_PIPS, type(uint128).max / 4);
    vm.assume(_destTokenId != _sourceId && _destTokenId != type(uint256).max && _destTokenId != 0);
    // One destination is the accumulator (tokenId 0); the source must differ from it.
    vm.assume(_sourceId != 0);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, _rate);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amountEach), address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(0, uint128(_amountEach), address(0));

    uint256 _totalOut = _amountEach * 2;
    uint256 _trimmed;
    uint256 _fee;
    {
      uint256 _net = _totalOut - (_totalOut * _rate) / MAX_PIPS;
      _trimmed = (_amountEach * _net) / _totalOut;
      _fee = _totalOut - _trimmed * 2;
    }

    {
      uint256[] memory _minted = new uint256[](0);
      IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
      _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, uint128(_totalOut));
      IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](3);
      _expectedDest[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_trimmed), address(0));
      _expectedDest[1] = IVotingEscrow.DestinationDelta(0, uint128(_trimmed), address(0));
      _expectedDest[2] = IVotingEscrow.DestinationDelta(0, uint128(_fee), address(0));
      _mockVERebalanceUnderlying(_expectedSources, _expectedDest, _minted);
    }

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, _totalOut, _fee);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenDestinationsProduceTrimmingDustOnAKnownExample(
    address _caller,
    uint256 _sourceId,
    uint256 _destA,
    uint256 _destB,
    uint256 _destC
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should keep destination amounts equal to proportional trim
    // it should route the dust into the fee leg
    // Hand-computed example, 10% fee on amounts 100/7/13 (totalOut 120):
    //   net = 120 - 12 = 108; trims = floor(100*108/120)=90, floor(7*108/120)=6, floor(13*108/120)=11;
    //   trimmed sum = 107, so fee = 120 - 107 = 13 (12 nominal fee + 1 rounding dust).
    _assumeFuzzable(_caller);
    vm.assume(_destA != _sourceId && _destB != _sourceId && _destC != _sourceId);
    vm.assume(_destA != type(uint256).max && _destB != type(uint256).max && _destC != type(uint256).max);
    vm.assume(_destA != _destB && _destA != _destC && _destB != _destC);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 100_000); // 10%

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](3);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destA, 100, address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_destB, 7, address(0));
    _destinations[2] = IVotingEscrow.DestinationDelta(_destC, 13, address(0));

    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, 120);
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](4);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destA, 90, address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(_destB, 6, address(0));
    _expectedDest[2] = IVotingEscrow.DestinationDelta(_destC, 11, address(0));
    _expectedDest[3] = IVotingEscrow.DestinationDelta(0, 13, address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, new uint256[](0));

    // The trimmed amounts and the fee leg are the hand-computed values, not the contract formula.
    vm.expectCall(_ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_expectedSources, _expectedDest)));
    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, 120, 13);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenDestinationsProduceTrimmingDustAcrossFuzzedInputs(
    address _caller,
    uint256 _sourceId,
    uint256 _baseDestId,
    uint128 _rate,
    uint256 _amountSeed,
    uint256 _len
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should keep the fee dust below the destination count
    _assumeFuzzable(_caller);
    // Fuzz the destination-array length so the trim/accumulation loops are exercised at variable N.
    _len = bound(_len, 1, 8);
    _rate = uint128(bound(_rate, 0, uint128(MAX_PIPS) - 1));
    // Destinations occupy [_baseDestId, _baseDestId + _len); keep clear of the source and the mint sentinel.
    _baseDestId = bound(_baseDestId, 1, type(uint256).max - 8);
    vm.assume(_sourceId < _baseDestId || _sourceId > _baseDestId + 8);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, _rate);
    // Generic mocks: the trimmed array is not precomputed; the oracle is an invariant on the emitted fee.
    vm.mockCall(_ve, abi.encodeWithSelector(IVotingEscrow.rebalanceUnderlying.selector), abi.encode(new uint256[](0)));

    // Cap keeps both _totalOut and the per-destination `amount * net` product within their types. Amounts are at
    // least PIPS so every destination keeps a nonzero trim under any sub-100% rate (the all-trim case reverts).
    uint256 _cap = type(uint128).max / 16;
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](_len);
    uint256 _totalOut;
    for (uint256 _i; _i < _len; ++_i) {
      uint128 _amount = uint128(bound(uint256(keccak256(abi.encode(_amountSeed, _i))), MAX_PIPS, _cap));
      _destinations[_i] = IVotingEscrow.DestinationDelta(_baseDestId + _i, _amount, address(0));
      _totalOut += _amount;
    }

    vm.recordLogs();
    vm.prank(_caller);
    _vpm.withdrawToNFT(_sourceId, _destinations);

    // The module emits a single log (WithdrawnToNFT); mocked calls emit none. Decode its fee field.
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    uint256 _fee;
    bool _found;
    for (uint256 _i; _i < _logs.length; ++_i) {
      if (_logs[_i].emitter != address(_vpm)) continue;
      (,, _fee) = abi.decode(_logs[_i].data, (IVotingEscrow.DestinationDelta[], uint256, uint256));
      _found = true;
    }
    assertTrue(_found);

    // Independent oracle: each of the _len destinations loses < 1 to floor division, so the dust
    // (fee above the nominal fee) is bounded by the destination count.
    uint256 _nominalFee = (_totalOut * _rate) / MAX_PIPS;
    assertGe(_fee, _nominalFee);
    assertLt(_fee - _nominalFee, _len);
  }

  function test_WhenEveryDestinationTrimsToZero(
    address _caller,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amount
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should revert with AllDestinationsTrimmedToZero
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint128).max);
    vm.assume(_destTokenId != _sourceId && _destTokenId != type(uint256).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, uint128(MAX_PIPS)); // 100% fee -- every destination trims to zero

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amount), address(0));

    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.AllDestinationsTrimmedToZero.selector);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenSomeDestinationsTrimToZeroAndSomeSurvive(
    address _caller,
    uint256 _sourceId,
    uint256 _destA,
    uint256 _destB
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should drop only the zero trimmed destinations
    // Hand-computed example, 10% fee on amounts 100/1 (totalOut 101):
    //   net = 101 - floor(101*100000/1000000) = 101 - 10 = 91;
    //   trims = floor(100*91/101) = 90 and floor(1*91/101) = 0 -> destB is dropped;
    //   trimmed sum = 90, so fee = 101 - 90 = 11 (10 nominal fee + 1 dust + destB's dropped stake).
    _assumeFuzzable(_caller);
    vm.assume(_destA != _sourceId && _destB != _sourceId);
    vm.assume(_destA != type(uint256).max && _destB != type(uint256).max);
    vm.assume(_destA != _destB && _destA != 0 && _destB != 0);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 100_000); // 10%

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destA, 100, address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_destB, 1, address(0));

    // destB trims to zero and is dropped; only destA's trim and the fee leg reach VE.
    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, 101);
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destA, 90, address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, 11, address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, new uint256[](0));

    vm.expectCall(_ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_expectedSources, _expectedDest)));
    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, 101, 11);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenAnEarlierDestinationTrimsToZeroAndALaterOneSurvives(
    address _caller,
    uint256 _sourceId,
    uint256 _destA,
    uint256 _destB
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should compact the survivor into the leading slot
    // Hand-computed example, 10% fee on amounts 1/100 (totalOut 101):
    //   net = 101 - floor(101*100000/1000000) = 101 - 10 = 91;
    //   trims = floor(1*91/101) = 0 -> destA dropped, floor(100*91/101) = 90 -> destB survives;
    //   trimmed sum = 90, so fee = 101 - 90 = 11. destB compacts from index 1 into the leading slot.
    _assumeFuzzable(_caller);
    vm.assume(_destA != _sourceId && _destB != _sourceId);
    vm.assume(_destA != type(uint256).max && _destB != type(uint256).max);
    vm.assume(_destA != _destB && _destA != 0 && _destB != 0);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 100_000); // 10%

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destA, 1, address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_destB, 100, address(0));

    // destA trims to zero and is dropped; destB survives and must land in slot 0 with its own id.
    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, 101);
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destB, 90, address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, 11, address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, new uint256[](0));

    vm.expectCall(_ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_expectedSources, _expectedDest)));
    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, 101, 11);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenFeeIsZero(
    address _caller,
    uint256 _sourceId,
    uint256 _destA,
    uint256 _destB,
    uint256 _amountEach
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should drop the fee leg from the VE destinations
    // it should emit WithdrawnToNFT with fee zero
    _assumeFuzzable(_caller);
    _amountEach = bound(_amountEach, 1, type(uint128).max / 4);
    vm.assume(_destA != _sourceId && _destB != _sourceId);
    vm.assume(_destA != type(uint256).max && _destB != type(uint256).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, 0);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](2);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destA, uint128(_amountEach), address(0));
    _destinations[1] = IVotingEscrow.DestinationDelta(_destB, uint128(_amountEach), address(0));

    uint256[] memory _minted = new uint256[](0);
    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, uint128(_amountEach * 2));
    // Rate is zero, so the flooring leaves no dust and the module drops the trailing fee leg.
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destA, uint128(_amountEach), address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(_destB, uint128(_amountEach), address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, _minted);

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, _amountEach * 2, 0);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }

  function test_WhenFeeIsNonZero(
    address _caller,
    uint256 _sourceId,
    uint256 _destTokenId,
    uint256 _amount,
    uint128 _rate
  )
    external
    whenTheSourceAuthorizationPasses
    whenTotalDestinationsAmountIsNonzero
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
  {
    // it should emit WithdrawnToNFT
    _assumeFuzzable(_caller);
    // Rate below 100% and amount at least PIPS so both the net and the fee are always positive.
    _rate = uint128(bound(_rate, 1, uint128(MAX_PIPS) - 1));
    _amount = bound(_amount, MAX_PIPS, type(uint128).max);
    vm.assume(_destTokenId != _sourceId && _destTokenId != type(uint256).max);
    _mockIsAuthorized(_caller, _sourceId, true);
    _setFee(_SIG, address(0), true, _rate);

    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](1);
    _destinations[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_amount), address(0));

    uint256 _net = _amount - (_amount * _rate) / MAX_PIPS;
    uint256 _fee = _amount - _net;

    uint256[] memory _minted = new uint256[](0);
    IVotingEscrow.SourceDelta[] memory _expectedSources = new IVotingEscrow.SourceDelta[](1);
    _expectedSources[0] = IVotingEscrow.SourceDelta(_sourceId, uint128(_amount));
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destTokenId, uint128(_net), address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, uint128(_fee), address(0));
    _mockVERebalanceUnderlying(_expectedSources, _expectedDest, _minted);

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.WithdrawnToNFT(_caller, _sourceId, _destinations, _amount, _fee);
    _vpm.withdrawToNFT(_sourceId, _destinations);
  }
}
