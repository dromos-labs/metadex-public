// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVoterPaymentsModule} from 'V3-test/unit/vpm/BaseVoterPaymentsModule.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

contract UnitVoterPaymentsModuledepositIntoNFT is BaseVoterPaymentsModule {
  bytes4 internal constant _SIG = IVoterPaymentsModule.depositIntoNFT.selector;

  function _makeSources(
    uint256 _len,
    uint256 _baseTokenId,
    uint256 _amountEach
  ) internal pure returns (IVotingEscrow.SourceDelta[] memory _sources) {
    _sources = new IVotingEscrow.SourceDelta[](_len);
    for (uint256 _i; _i < _len; ++_i) {
      _sources[_i] = IVotingEscrow.SourceDelta(_baseTokenId + _i, uint128(_amountEach));
    }
  }

  function test_WhenSourcesIsEmpty(address _caller, uint256 _destinationId, address _recipient) external {
    // it should revert with NoSources
    _assumeFuzzable(_caller);
    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](0);
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.NoSources.selector);
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }

  function test_WhenAnySourceAuthorizationCheckFails(
    address _caller,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint256 _destinationId,
    address _recipient
  ) external {
    // it should revert with NotApprovedByOwner
    _assumeFuzzable(_caller);
    _amountEach = bound(_amountEach, 1, type(uint128).max);
    // Ensure 3 sequential tokenIds without overflow.
    _baseTokenId = bound(_baseTokenId, 0, type(uint256).max - 2);
    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(3, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);
    _mockIsAuthorized(_caller, _sources[1].tokenId, false);
    _mockIsAuthorized(_caller, _sources[2].tokenId, true);
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IVoterPaymentsModule.NotApprovedByOwner.selector, _sources[1].tokenId));
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }

  modifier whenEverySourceAuthorizationPasses() {
    _;
  }

  function test_WhenTheOperationIsRestrictedAndTheCallerIsUnregistered(
    address _caller,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint256 _destinationId,
    address _recipient
  ) external whenEverySourceAuthorizationPasses {
    // it should revert with NotRegistered
    _assumeFuzzable(_caller);
    _amountEach = bound(_amountEach, 1, type(uint128).max);
    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(1, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);
    _setRestricted(_SIG, true);
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.NotRegistered.selector);
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }

  modifier whenTheOperationIsPermissionlessOrTheCallerIsRegistered() {
    _;
  }

  modifier whenTheDestinationIsTheMintSentinel() {
    _;
  }

  function test_WhenTheNetMintAmountIsZero(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint256 _amountEach
  )
    external
    whenEverySourceAuthorizationPasses
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
    whenTheDestinationIsTheMintSentinel
  {
    // it should revert with ZeroMintAmount
    _assumeFuzzable(_caller);
    // A full-PIPS fee makes net = totalIn - fee == 0, so a mint-sentinel destination would mint a
    // zero-stake NFT. The amount itself must stay nonzero (totalIn > 0) and within uint128 for 2 legs.
    _amountEach = bound(_amountEach, 1, type(uint128).max / 4);
    // Two sequential tokenIds without overflow.
    _baseTokenId = bound(_baseTokenId, 0, type(uint256).max - 1);
    // 100% fee: _fee == _totalIn, so the net to the minted destination is zero.
    _setFee(_SIG, address(0), true, uint128(MAX_PIPS));

    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(2, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);
    _mockIsAuthorized(_caller, _sources[1].tokenId, true);

    // No VE mock: the guard must revert before reaching rebalanceUnderlying.
    vm.prank(_caller);
    vm.expectRevert(IVoterPaymentsModule.ZeroMintAmount.selector);
    _vpm.depositIntoNFT(_sources, type(uint256).max, _recipient);
  }

  function test_WhenTheNetMintAmountIsNonzero(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint128 _defaultRate,
    uint256 _newId
  )
    external
    whenEverySourceAuthorizationPasses
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
    whenTheDestinationIsTheMintSentinel
  {
    // it should pass recipient through to VE
    // it should emit DepositedIntoNFT with the resolved destination id
    _assumeFuzzable(_caller);
    // Rate in [1, PIPS) so the fee leg is exercised (fee > 0) while the net mint stays nonzero;
    // a full-PIPS rate would zero the net and hit the ZeroMintAmount guard (covered separately).
    _defaultRate = uint128(bound(_defaultRate, 1, uint128(MAX_PIPS) - 1));
    // 2 sources, so totalIn = 2 * amount. Keep within uint128 to prevent overflow.
    _amountEach = bound(_amountEach, MAX_PIPS, type(uint128).max / 4);
    // Ensure 2 sequential tokenIds without overflow.
    _baseTokenId = bound(_baseTokenId, 0, type(uint256).max - 1);
    // VE assigns minted ids from `++tokenId`, so a resolved mint destination is never tokenId 0.
    _newId = bound(_newId, 1, type(uint256).max);
    _setFee(_SIG, address(0), true, _defaultRate);

    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(2, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);
    _mockIsAuthorized(_caller, _sources[1].tokenId, true);

    uint256 _totalIn = _amountEach * 2;
    uint256 _fee = (_totalIn * _defaultRate) / MAX_PIPS;
    uint256[] memory _minted = new uint256[](1);
    _minted[0] = _newId;

    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(type(uint256).max, uint128(_totalIn - _fee), _recipient);
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, uint128(_fee), address(0));
    _mockVERebalanceUnderlying(_sources, _expectedDest, _minted);

    vm.expectCall(_ve, abi.encodeCall(IVotingEscrow.rebalanceUnderlying, (_sources, _expectedDest)));

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.DepositedIntoNFT(_caller, _sources, _newId, _totalIn, _fee);
    uint256[] memory _result = _vpm.depositIntoNFT(_sources, type(uint256).max, _recipient);
    assertEq(_result.length, 1);
    assertEq(_result[0], _newId);
  }

  function test_WhenTheDestinationIsTheAccumulator(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint128 _rate
  ) external whenEverySourceAuthorizationPasses whenTheOperationIsPermissionlessOrTheCallerIsRegistered {
    // it should emit DepositedIntoNFT
    _assumeFuzzable(_caller);
    _rate = uint128(bound(_rate, 1, uint128(MAX_PIPS)));
    // Keep the moved amount at least PIPS so the fee is positive and the fee leg is appended (the `_fee > 0`
    // gate); the test then asserts both legs target tokenId 0, since the destination is the accumulator.
    _amountEach = bound(_amountEach, MAX_PIPS, type(uint128).max);
    // Source must not be the accumulator itself (VE rejects tokenId 0 as a source).
    _baseTokenId = bound(_baseTokenId, 1, type(uint256).max);
    _setFee(_SIG, address(0), true, _rate);

    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(1, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);

    uint256 _fee = (_amountEach * _rate) / MAX_PIPS;
    uint256[] memory _minted = new uint256[](0);

    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(0, uint128(_amountEach - _fee), address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, uint128(_fee), address(0));
    _mockVERebalanceUnderlying(_sources, _expectedDest, _minted);

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.DepositedIntoNFT(_caller, _sources, 0, _amountEach, _fee);
    _vpm.depositIntoNFT(_sources, 0, _recipient);
  }

  modifier whenTheDestinationIsAnExistingTokenId() {
    _;
  }

  function test_WhenFeeIsZero(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint256 _destinationId
  )
    external
    whenEverySourceAuthorizationPasses
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
    whenTheDestinationIsAnExistingTokenId
  {
    // it should drop the fee leg from the VE destinations
    // it should emit DepositedIntoNFT with fee zero
    _assumeFuzzable(_caller);
    // Two sources, fee zero: the sole overflow constraint is 2 * _amountEach <= type(uint128).max.
    _amountEach = bound(_amountEach, 1, type(uint128).max / 2);
    _baseTokenId = bound(_baseTokenId, 0, type(uint256).max - 1);
    // Existing tokenId path: not mint sentinel, not equal to a source tokenId (no such restriction here, but keep zero distinct).
    vm.assume(_destinationId != type(uint256).max);
    _setFee(_SIG, address(0), true, 0);
    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(2, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);
    _mockIsAuthorized(_caller, _sources[1].tokenId, true);

    uint256 _totalIn = _amountEach * 2;
    uint256[] memory _minted = new uint256[](0);

    // With a zero fee, the module drops the trailing fee leg: the destinations array holds only the net leg.
    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](1);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destinationId, uint128(_totalIn), address(0));
    _mockVERebalanceUnderlying(_sources, _expectedDest, _minted);

    vm.prank(_caller);
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }

  function test_WhenFeeIsNonzero(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint256 _amountEach,
    uint256 _destinationId,
    uint128 _rate
  )
    external
    whenEverySourceAuthorizationPasses
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
    whenTheDestinationIsAnExistingTokenId
  {
    // it should emit DepositedIntoNFT
    _assumeFuzzable(_caller);
    // Rate at least 1 and amount at least PIPS so the fee is always positive.
    _rate = uint128(bound(_rate, 1, uint128(MAX_PIPS)));
    _amountEach = bound(_amountEach, MAX_PIPS, type(uint128).max);
    // Existing, non-accumulator destination distinct from the source so the fee leg is always emitted.
    _baseTokenId = bound(_baseTokenId, 1, type(uint256).max);
    vm.assume(_destinationId != type(uint256).max && _destinationId != 0 && _destinationId != _baseTokenId);
    _setFee(_SIG, address(0), true, _rate);
    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(1, _baseTokenId, _amountEach);
    _mockIsAuthorized(_caller, _sources[0].tokenId, true);

    uint256 _fee = (_amountEach * _rate) / MAX_PIPS;
    uint256[] memory _minted = new uint256[](0);

    IVotingEscrow.DestinationDelta[] memory _expectedDest = new IVotingEscrow.DestinationDelta[](2);
    _expectedDest[0] = IVotingEscrow.DestinationDelta(_destinationId, uint128(_amountEach - _fee), address(0));
    _expectedDest[1] = IVotingEscrow.DestinationDelta(0, uint128(_fee), address(0));
    _mockVERebalanceUnderlying(_sources, _expectedDest, _minted);

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.DepositedIntoNFT(_caller, _sources, _destinationId, _amountEach, _fee);
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }

  function test_WhenSourcesSpanAFuzzedLength(
    address _caller,
    address _recipient,
    uint256 _baseTokenId,
    uint128 _amountEach,
    uint128 _rate,
    uint256 _destinationId,
    uint256 _len
  )
    external
    whenEverySourceAuthorizationPasses
    whenTheOperationIsPermissionlessOrTheCallerIsRegistered
    whenTheDestinationIsAnExistingTokenId
  {
    // it should accumulate totalIn across every source leg
    _assumeFuzzable(_caller);
    // Fuzz the source-array length so the accumulation loop runs at variable N.
    _len = bound(_len, 1, 8);
    // _len * _amountEach <= type(uint128).max so the destination amount cast never overflows.
    _amountEach = uint128(bound(_amountEach, 1, type(uint128).max / 8));
    _rate = uint128(bound(_rate, 0, uint128(MAX_PIPS)));
    _baseTokenId = bound(_baseTokenId, 1, type(uint256).max - 8);
    // Existing, non-accumulator, non-sentinel destination.
    vm.assume(_destinationId != type(uint256).max && _destinationId != 0);
    _setFee(_SIG, address(0), true, _rate);

    IVotingEscrow.SourceDelta[] memory _sources = _makeSources(_len, _baseTokenId, _amountEach);
    for (uint256 _i; _i < _len; ++_i) {
      _mockIsAuthorized(_caller, _sources[_i].tokenId, true);
    }

    uint256 _totalIn = uint256(_amountEach) * _len;
    uint256 _fee = (_totalIn * _rate) / MAX_PIPS;

    // Generic mocks: the destination array the module builds is not pre-enumerated here; the oracle
    // is the emitted (totalIn, fee) computed independently across the fuzzed source count.
    vm.mockCall(_ve, abi.encodeWithSelector(IVotingEscrow.rebalanceUnderlying.selector), abi.encode(new uint256[](0)));

    vm.prank(_caller);
    vm.expectEmit(true, true, true, true, address(_vpm));
    emit IVoterPaymentsModule.DepositedIntoNFT(_caller, _sources, _destinationId, _totalIn, _fee);
    _vpm.depositIntoNFT(_sources, _destinationId, _recipient);
  }
}
