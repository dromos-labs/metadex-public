// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';

import {TokenRegistry} from 'V3/tokenRegistry/TokenRegistry.sol';

import {CancellingMintObserver} from 'V3-test/mocks/CancellingMintObserver.sol';
import {LockedFundsMintObserver} from 'V3-test/mocks/LockedFundsMintObserver.sol';
import {RevertingReceiver} from 'V3-test/mocks/RevertingReceiver.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitTokenRegistry is TestHelpers {
  uint8 internal constant _MAX_WEIGHT = 100;
  uint256 internal constant _DEPOSIT = 0.1 ether;

  // `TokenRegistry` storage slots. `ReentrancyGuardTransient` keeps its flag in transient storage, so the first
  // state variable `depositAmount` lands in slot zero.
  uint256 internal constant _DEPOSIT_AMOUNT_SLOT = 0;
  uint256 internal constant _NEXT_ID_SLOT = 1;
  uint256 internal constant _LOCKED_FUNDS_SLOT = 2;
  uint256 internal constant _REFUND_OF_SLOT = 3;
  uint256 internal constant _IS_LISTED_SLOT = 4;
  uint256 internal constant _IS_DELEGATE_SLOT = 5;
  uint256 internal constant _IS_EXEMPT_SLOT = 6;
  uint256 internal constant _CANONICAL_OF_SLOT = 7;
  uint256 internal constant _REGISTRATION_OF_SLOT = 8;
  uint256 internal constant _ID_TO_TOKEN_SLOT = 9;
  uint256 internal constant _NFT_CONTRACTS_SLOT = 10;
  uint256 internal constant _PENDING_REQUESTS_SLOT = 11;
  uint256 internal constant _TIERS_SLOT = 12;

  address internal _leafVoter;
  address internal _nftContract;
  address internal immutable _GOVERNOR = makeAddr('governor');
  address internal immutable _DELEGATE = makeAddr('delegate');
  address internal immutable _EXEMPT = makeAddr('exempt');

  TokenRegistry internal _registry;

  function setUp() external {
    _leafVoter = _mockContract('LeafVoter');
    _nftContract = _mockContract('TokenNFT');
    _registry = new TokenRegistry(_leafVoter, _DEPOSIT);
    // The constructor no longer registers a mint target, so seed the first NFT contract.
    _pushNftContract(_nftContract);
  }

  // --- constructor ---

  function test_ConstructorWhenTheLeafVoterIsTheZeroAddress(uint256 _deposit) external {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    new TokenRegistry(address(0), _deposit);
  }

  function test_ConstructorWhenTheDepositIsZero(address _newVoter) external {
    _assumeFuzzable(_newVoter);
    // it should revert with ZeroDeposit
    vm.expectRevert(ITokenRegistry.ZeroDeposit.selector);
    new TokenRegistry(_newVoter, 0);
  }

  function test_ConstructorWhenTheParametersAreValid(address _newVoter, uint256 _deposit) external {
    _assumeFuzzable(_newVoter);
    _deposit = bound(_deposit, 1, type(uint256).max);
    _registry = new TokenRegistry(_newVoter, _deposit);

    // it should set the leaf voter to _leafVoter
    assertEq(_registry.LEAF_VOTER(), _newVoter);
    // it should set the deposit amount to _depositAmount
    assertEq(_registry.depositAmount(), _deposit);
    // it should expose the MAX WEIGHT constant
    assertEq(_registry.MAX_WEIGHT(), _MAX_WEIGHT);
    // it should seed the next id at one
    assertEq(_registry.nextId(), 1);
  }

  // --- requestRegistration ---

  function test_RequestRegistrationWhenTheTokenIsTheZeroAddress(address _caller) external {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    vm.prank(_caller);
    _registry.requestRegistration(address(0), ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  /// @notice Constrains the fuzzed token away from the zero address the guard rejects.
  modifier givenTheTokenIsNotTheZeroAddress(address _token) {
    _assumeFuzzable(_token);
    _;
  }

  function test_RequestRegistrationWhenTheCanonicalChainIdIsTheLocalChain(
    address _token,
    address _caller,
    uint256 _nftId
  ) external givenTheTokenIsNotTheZeroAddress(_token) {
    // it should revert with InvalidCanonical
    vm.expectRevert(ITokenRegistry.InvalidCanonical.selector);
    vm.prank(_caller);
    _registry.requestRegistration(
      _token, ITokenRegistry.CanonicalReference(block.chainid, _nftId), new ITokenNFT.TextRecord[](0)
    );
  }

  function test_RequestRegistrationWhenTheTokenIsAlreadyRegistered(
    address _token,
    uint256 _id,
    address _caller
  ) external givenTheTokenIsNotTheZeroAddress(_token) {
    _id = bound(_id, 1, type(uint128).max);
    _seedRegistration(_token, _id, 0);

    // it should revert with AlreadyRegistered
    vm.expectRevert(ITokenRegistry.AlreadyRegistered.selector);
    vm.prank(_caller);
    _registry.requestRegistration(_token, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  /// @notice Fresh state has no registration for the fuzzed token, satisfying the branch by default.
  modifier givenTheTokenWasNotRegistered() {
    _;
  }

  function test_RequestRegistrationWhenTheTokenHasAnOpenRequest(
    address _token,
    address _requester,
    uint256 _deposit,
    address _caller
  ) external givenTheTokenIsNotTheZeroAddress(_token) givenTheTokenWasNotRegistered {
    _assumeFuzzable(_requester);
    _seedPendingRequest(_token, _requester, _deposit);

    // it should revert with RequestPending
    vm.expectRevert(ITokenRegistry.RequestPending.selector);
    vm.prank(_caller);
    _registry.requestRegistration(_token, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  /// @notice Fresh state has no open request for the fuzzed token, satisfying the branch by default.
  modifier givenTheTokenHasNoOpenRequest() {
    _;
  }

  function test_RequestRegistrationWhenTheSentValueDoesNotEqualTheDeposit(
    address _token,
    address _caller,
    uint256 _value
  ) external givenTheTokenIsNotTheZeroAddress(_token) givenTheTokenWasNotRegistered givenTheTokenHasNoOpenRequest {
    vm.assume(_value != _DEPOSIT);
    vm.deal(_caller, _value);

    // it should revert with WrongDeposit
    vm.expectRevert(ITokenRegistry.WrongDeposit.selector);
    vm.prank(_caller);
    _registry.requestRegistration{value: _value}(
      _token, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0)
    );
  }

  function test_RequestRegistrationWhenNoNftContractIsConfigured(
    address _token,
    address _caller
  ) external givenTheTokenIsNotTheZeroAddress(_token) givenTheTokenWasNotRegistered givenTheTokenHasNoOpenRequest {
    vm.deal(_caller, _DEPOSIT);
    // Empty the NFT contract list to model the window before governance registers the first mint target.
    vm.store(address(_registry), bytes32(_NFT_CONTRACTS_SLOT), bytes32(uint256(0)));

    // it should revert with NoNFTContract
    vm.expectRevert(ITokenRegistry.NoNFTContract.selector);
    vm.prank(_caller);
    _registry.requestRegistration{value: _DEPOSIT}(
      _token, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0)
    );
  }

  function test_RequestRegistrationWhenTheRequestIsValid(
    address _token,
    address _caller,
    uint256 _chainId,
    uint256 _nftId,
    ITokenNFT.TextRecord[] memory _records
  ) external givenTheTokenIsNotTheZeroAddress(_token) givenTheTokenWasNotRegistered givenTheTokenHasNoOpenRequest {
    _assumeFuzzable(_caller);
    vm.assume(_chainId != block.chainid);
    _records = _boundRecords(_records);
    vm.deal(_caller, _DEPOSIT);

    // it should emit RegistrationRequested with _token, _requester
    _expectEmit(address(_registry));
    emit ITokenRegistry.RegistrationRequested(_token, _caller);

    vm.prank(_caller);
    _registry.requestRegistration{value: _DEPOSIT}(
      _token, ITokenRegistry.CanonicalReference(_chainId, _nftId), _records
    );

    ITokenRegistry.MetadataRequest memory _request = _registry.pendingRequest(_token);
    // it should set the requester to the caller
    assertEq(_request.requester, _caller);
    // it should set the deposit to the deposit amount
    assertEq(_request.deposit, _DEPOSIT);
    // it should set the records to _records
    assertEq(_request.records.length, _records.length);
    for (uint256 _i; _i < _records.length; ++_i) {
      assertEq(_request.records[_i].key, _records[_i].key);
      assertEq(_request.records[_i].value, _records[_i].value);
    }
    // it should set the canonical to _canonical
    assertEq(_request.canonical.chainId, _chainId);
    assertEq(_request.canonical.nftId, _nftId);
    // it should increase the balance by the deposit
    assertEq(address(_registry).balance, _DEPOSIT);
    // it should lock the deposit
    assertEq(_registry.lockedFunds(), _DEPOSIT);
  }

  function test_RequestRegistrationWhenAnotherTokenHasAnOpenRequest(
    address _token,
    address _otherToken,
    address _caller,
    address _otherRequester,
    uint256 _otherDeposit
  ) external givenTheTokenIsNotTheZeroAddress(_token) givenTheTokenWasNotRegistered givenTheTokenHasNoOpenRequest {
    _assumeFuzzable(_caller);
    _otherToken = _boundNotEq(_otherToken, _token);
    _assumeFuzzable(_otherRequester);
    // Headroom keeps the two escrowed deposits from overflowing when they are summed.
    _otherDeposit = bound(_otherDeposit, 0, type(uint256).max - _DEPOSIT);
    _seedPendingRequest(_otherToken, _otherRequester, _otherDeposit);
    vm.deal(address(_registry), _otherDeposit);
    vm.deal(_caller, _DEPOSIT);

    vm.prank(_caller);
    _registry.requestRegistration{value: _DEPOSIT}(
      _token, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0)
    );

    // it should add the deposit to the locked funds
    assertEq(_registry.lockedFunds(), _otherDeposit + _DEPOSIT);
    // it should leave the other request untouched
    (address _readRequester, uint256 _readDeposit) = _pendingOf(_otherToken);
    assertEq(_readRequester, _otherRequester);
    assertEq(_readDeposit, _otherDeposit);
  }

  // --- registerExempt ---

  function test_RegisterExemptWhenTheCanonicalChainIdIsTheLocalChain(
    address _caller,
    address _token,
    address _to,
    uint256 _nftId
  ) external {
    // it should revert with InvalidCanonical
    vm.expectRevert(ITokenRegistry.InvalidCanonical.selector);
    vm.prank(_caller);
    _registry.registerExempt(
      _token, _to, ITokenRegistry.CanonicalReference(block.chainid, _nftId), new ITokenNFT.TextRecord[](0)
    );
  }

  function test_RegisterExemptWhenTheCallerIsNotExempt(address _caller, address _token, address _to) external {
    // it should revert with NotExempt
    vm.expectRevert(ITokenRegistry.NotExempt.selector);
    vm.prank(_caller);
    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  /// @notice Marks `_EXEMPT` as exempt and pranks every call in the test body as it.
  modifier givenTheCallerIsExempt() {
    vm.store(address(_registry), keccak256(abi.encode(_EXEMPT, _IS_EXEMPT_SLOT)), bytes32(uint256(1)));
    vm.startPrank(_EXEMPT);
    _;
    vm.stopPrank();
  }

  function test_RegisterExemptWhenTheTokenIsAlreadyRegistered(
    address _token,
    address _to,
    uint256 _id
  ) external givenTheCallerIsExempt {
    _id = bound(_id, 1, type(uint128).max);
    _seedRegistration(_token, _id, 0);

    // it should revert with AlreadyRegistered
    vm.expectRevert(ITokenRegistry.AlreadyRegistered.selector);
    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  function test_RegisterExemptWhenTheTokenIsTheZeroAddress(address _to) external givenTheCallerIsExempt {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    _registry.registerExempt(address(0), _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  function test_RegisterExemptWhenNoNftContractIsConfigured(
    address _token,
    address _to
  ) external givenTheCallerIsExempt {
    _assumeFuzzable(_token);
    // Empty the NFT contract list to model the window before governance registers the first mint target.
    vm.store(address(_registry), bytes32(_NFT_CONTRACTS_SLOT), bytes32(uint256(0)));

    // it should revert with NoNFTContract
    vm.expectRevert(ITokenRegistry.NoNFTContract.selector);
    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
  }

  /// @notice The NFT contract seeded in `setUp` already satisfies the branch, so no extra setup is needed.
  modifier givenAnNftContractIsConfigured() {
    _;
  }

  function test_RegisterExemptWhenTheTokenHasNoOpenRequest(
    address _token,
    address _to,
    ITokenNFT.TextRecord[] memory _records
  ) external givenTheCallerIsExempt {
    _assumeFuzzable(_token);
    _records = _boundRecords(_records);
    _mockAndExpectMint(1, _to, _records);

    // it should mint the nft to the recipient
    // it should emit Registered with _token, _id, _to
    _expectEmit(address(_registry));
    emit ITokenRegistry.Registered(_token, 1, _to);

    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), _records);

    // it should assign the next id and record the mapping
    (uint128 _nftId, uint128 _nftContractIndex) = _registry.registrationOf(_token);
    assertEq(_nftId, 1);
    assertEq(_nftContractIndex, 0);
    assertEq(_registry.idToToken(1), _token);
    assertEq(_registry.nextId(), 2);
  }

  function test_RegisterExemptWhenTheTokenHasAnOpenRequest(
    address _token,
    address _to,
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsExempt {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _seedPendingRequest(_token, _requester, _deposit);
    vm.deal(address(_registry), _deposit);
    uint256 _requesterBalanceBefore = _requester.balance;

    // it should mint the nft to the recipient
    _mockAndExpectMint(1, _to, new ITokenNFT.TextRecord[](0));

    // it should emit RefundCredited with _requester, _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.RefundCredited(_requester, _deposit);
    // it should emit RegistrationPreempted with _token, _requester
    _expectEmit(address(_registry));
    emit ITokenRegistry.RegistrationPreempted(_token, _requester);
    // it should emit Registered with _token, _id, _to
    _expectEmit(address(_registry));
    emit ITokenRegistry.Registered(_token, 1, _to);

    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));

    // it should credit the refund to the original requester
    assertEq(_registry.refundOf(_requester), _deposit);
    assertEq(_requester.balance, _requesterBalanceBefore);
    // it should close the request
    (address _readRequester,) = _pendingOf(_token);
    assertEq(_readRequester, address(0));
    // it should keep the credited refund locked
    assertEq(_registry.lockedFunds(), _deposit);
  }

  function test_RegisterExemptWhenTheOpenRequesterCannotReceiveEth(
    address _token,
    address _to,
    uint256 _deposit
  ) external givenTheCallerIsExempt givenAnNftContractIsConfigured {
    _assumeFuzzable(_token);
    RevertingReceiver _requester = new RevertingReceiver();
    _deposit = bound(_deposit, 1, type(uint256).max);
    _seedPendingRequest(_token, address(_requester), _deposit);
    vm.deal(address(_registry), _deposit);
    _mockAndExpectMint(1, _to, new ITokenNFT.TextRecord[](0));

    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));

    // it should credit the refund without reverting
    assertEq(_registry.refundOf(address(_requester)), _deposit);
  }

  function test_RegisterExemptWhenTheRecipientCancelsTheRequestDuringTheMint(
    address _token,
    uint256 _deposit
  ) external givenTheCallerIsExempt givenAnNftContractIsConfigured {
    _assumeFuzzable(_token);
    _deposit = bound(_deposit, 1, type(uint256).max);
    // `vm.mockFunction` runs the observer in the NFT contract's context, so the NFT contract is both the open
    // request's requester and the mint recipient, letting the callback try to cancel its own request
    // mid-registration. The request is already closed before the mint, so the reentrant cancel reverts.
    CancellingMintObserver _observer = new CancellingMintObserver(_registry, _token);
    _seedPendingRequest(_token, _nftContract, _deposit);
    vm.deal(address(_registry), _deposit);
    bytes memory _mintCall = abi.encodeCall(ITokenNFT.mint, (1, _nftContract, new ITokenNFT.TextRecord[](0)));
    vm.mockFunction(_nftContract, address(_observer), _mintCall);

    // it should revert with NotRequester
    vm.expectRevert(ITokenRegistry.NotRequester.selector);
    _registry.registerExempt(
      _token, _nftContract, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0)
    );
  }

  function test_RegisterExemptWhenTheCanonicalReferenceIsSet(
    address _token,
    address _to,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsExempt givenAnNftContractIsConfigured {
    _assumeFuzzable(_token);
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(_chainId != block.chainid);
    _mockAndExpectMint(1, _to, new ITokenNFT.TextRecord[](0));

    // it should emit CanonicalSet with _token, _chainId, _nftId
    _expectEmit(address(_registry));
    emit ITokenRegistry.CanonicalSet(_token, _chainId, _nftId);

    _registry.registerExempt(
      _token, _to, ITokenRegistry.CanonicalReference(_chainId, _nftId), new ITokenNFT.TextRecord[](0)
    );

    // it should set the canonical reference to _canonical
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, _chainId);
    assertEq(_readNftId, _nftId);
  }

  function test_RegisterExemptWhenTheCanonicalReferenceIsEmpty(
    address _token,
    address _to,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsExempt givenAnNftContractIsConfigured {
    _assumeFuzzable(_token);
    // A reference governance set before the registration must survive an empty requested one.
    _chainId = bound(_chainId, 1, type(uint256).max);
    _seedCanonical(_token, _chainId, _nftId);
    _mockAndExpectMint(1, _to, new ITokenNFT.TextRecord[](0));

    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));

    // it should leave the canonical reference untouched
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, _chainId);
    assertEq(_readNftId, _nftId);
  }

  function test_RegisterExemptWhenRegisteringTwoTokensInSequence(
    address _tokenA,
    address _tokenB,
    address _to
  ) external givenTheCallerIsExempt {
    _assumeFuzzable(_tokenA);
    _tokenB = _boundNotEq(_tokenB, _tokenA);
    _mockAndExpectMint(1, _to, new ITokenNFT.TextRecord[](0));
    _mockAndExpectMint(2, _to, new ITokenNFT.TextRecord[](0));

    _registry.registerExempt(_tokenA, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));
    _registry.registerExempt(_tokenB, _to, ITokenRegistry.CanonicalReference(0, 0), new ITokenNFT.TextRecord[](0));

    // it should assign strictly increasing unique ids
    (uint128 _idA,) = _registry.registrationOf(_tokenA);
    (uint128 _idB,) = _registry.registrationOf(_tokenB);
    assertEq(_idA, 1);
    assertEq(_idB, 2);
    assertGt(_idB, _idA);
    assertEq(_registry.idToToken(1), _tokenA);
    assertEq(_registry.idToToken(2), _tokenB);
    assertEq(_registry.nextId(), 3);
  }

  function test_RegisterExemptWhenANewerNftContractIsRegistered(
    address _token,
    address _to,
    ITokenNFT.TextRecord[] memory _records
  ) external givenTheCallerIsExempt {
    _assumeFuzzable(_token);
    _records = _boundRecords(_records);
    address _newerContract = _mockContract('NewerTokenNFT');
    _pushNftContract(_newerContract);
    // The contract seeded in setUp is superseded, so a mint reaching it fails the test.
    vm.mockCallRevert(_nftContract, abi.encodeCall(ITokenNFT.mint, (1, _to, _records)), 'older mint');

    // it should mint on the newest contract
    _mockAndExpect(_newerContract, abi.encodeCall(ITokenNFT.mint, (1, _to, _records)), '');

    _registry.registerExempt(_token, _to, ITokenRegistry.CanonicalReference(0, 0), _records);

    // it should record the newest contract index
    (uint128 _nftId, uint128 _nftContractIndex) = _registry.registrationOf(_token);
    assertEq(_nftId, 1);
    assertEq(_nftContractIndex, 1);
  }

  // --- resolveRequest ---

  function test_ResolveRequestWhenTheCallerIsNotADelegate(address _caller, address _token) external {
    // it should revert with NotReviewer
    vm.expectRevert(ITokenRegistry.NotReviewer.selector);
    vm.prank(_caller);
    _registry.resolveRequest(_token, true);
  }

  /// @notice Marks `_DELEGATE` as a delegate reviewer and pranks every call in the test body as it.
  modifier givenTheCallerIsADelegate() {
    vm.store(address(_registry), keccak256(abi.encode(_DELEGATE, _IS_DELEGATE_SLOT)), bytes32(uint256(1)));
    vm.startPrank(_DELEGATE);
    _;
    vm.stopPrank();
  }

  function test_ResolveRequestWhenNoRequestIsOpen(address _token, bool _approved) external givenTheCallerIsADelegate {
    // it should revert with NotPending
    vm.expectRevert(ITokenRegistry.NotPending.selector);
    _registry.resolveRequest(_token, _approved);
  }

  /// @notice Each test seeds its own open request for the fuzzed token, satisfying the branch.
  modifier givenARequestIsOpen() {
    _;
  }

  function test_ResolveRequestWhenApprovingTheZeroAddressToken(
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_requester);
    _seedPendingRequest(address(0), _requester, _deposit);

    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    _registry.resolveRequest(address(0), true);
  }

  function test_ResolveRequestWhenApprovingWithNoNftContractConfigured(
    address _token,
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    _seedPendingRequest(_token, _requester, _deposit);
    // Empty the NFT contract list to model the window before governance registers the first mint target.
    vm.store(address(_registry), bytes32(_NFT_CONTRACTS_SLOT), bytes32(uint256(0)));

    // it should revert with NoNFTContract
    vm.expectRevert(ITokenRegistry.NoNFTContract.selector);
    _registry.resolveRequest(_token, true);
  }

  function test_ResolveRequestWhenTheRequestIsApproved(
    address _token,
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _seedPendingRequest(_token, _requester, _deposit);
    vm.deal(address(_registry), _deposit);
    uint256 _requesterBalanceBefore = _requester.balance;
    // it should mint the nft to the requester
    _mockAndExpectMint(1, _requester, new ITokenNFT.TextRecord[](0));

    // it should emit Registered with _token, _id, _to
    _expectEmit(address(_registry));
    emit ITokenRegistry.Registered(_token, 1, _requester);
    // it should emit RefundCredited with _requester, _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.RefundCredited(_requester, _deposit);
    // it should emit RegistrationApproved with _token, _requester
    _expectEmit(address(_registry));
    emit ITokenRegistry.RegistrationApproved(_token, _requester);

    _registry.resolveRequest(_token, true);

    // it should close the request
    (address _readRequester,) = _pendingOf(_token);
    assertEq(_readRequester, address(0));
    // it should assign the next id and record the mapping
    (uint128 _nftId, uint128 _nftContractIndex) = _registry.registrationOf(_token);
    assertEq(_nftId, 1);
    assertEq(_nftContractIndex, 0);
    assertEq(_registry.idToToken(1), _token);
    // it should credit the refund to the requester
    assertEq(_registry.refundOf(_requester), _deposit);
    assertEq(_requester.balance, _requesterBalanceBefore);
    // it should keep the credited refund locked
    assertEq(_registry.lockedFunds(), _deposit);
    assertEq(address(_registry).balance, _deposit);
  }

  function test_ResolveRequestWhenTheApprovedRequestCarriesRecords(
    address _token,
    address _requester,
    bytes32 _keySeed,
    bytes32 _valueSeed,
    uint256 _lengthSeed
  ) external givenTheCallerIsADelegate givenARequestIsOpen {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    // Two records with distinct keys prove the whole stored array is forwarded, not just its first element.
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](2);
    _records[0] = ITokenNFT.TextRecord({
      key: _boundedShortText(_keySeed, _lengthSeed), value: _boundedShortText(_valueSeed, _lengthSeed)
    });
    _records[1] = ITokenNFT.TextRecord({
      key: _boundedShortText(keccak256(abi.encode(_keySeed)), _lengthSeed),
      value: _boundedShortText(keccak256(abi.encode(_valueSeed)), _lengthSeed)
    });
    _seedPendingRequest(_token, _requester, 0);
    _seedRequestRecords(_token, _records);

    // it should mint with the requested records
    _mockAndExpect(_nftContract, abi.encodeCall(ITokenNFT.mint, (1, _requester, _records)), '');

    _registry.resolveRequest(_token, true);
  }

  function test_ResolveRequestWhenTheApprovedRequestCarriesACanonicalReference(
    address _token,
    address _requester,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsADelegate givenARequestIsOpen {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    // The request guard rejects the local chain and a zero chain id is empty, so a stored reference is neither.
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(_chainId != block.chainid);
    _seedPendingRequest(_token, _requester, 0);
    _seedRequestCanonical(_token, _chainId, _nftId);
    _mockAndExpectMint(1, _requester, new ITokenNFT.TextRecord[](0));

    // it should emit CanonicalSet with _token, _chainId, _nftId
    _expectEmit(address(_registry));
    emit ITokenRegistry.CanonicalSet(_token, _chainId, _nftId);

    _registry.resolveRequest(_token, true);

    // it should set the canonical reference to the requested one
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, _chainId);
    assertEq(_readNftId, _nftId);
  }

  function test_ResolveRequestWhenTheApprovedRequestHasAnEmptyCanonicalReference(
    address _token,
    address _requester,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsADelegate givenARequestIsOpen {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _seedPendingRequest(_token, _requester, 0);
    // A reference governance set while the request was pending must survive an empty requested one.
    _chainId = bound(_chainId, 1, type(uint256).max);
    _seedCanonical(_token, _chainId, _nftId);
    _mockAndExpectMint(1, _requester, new ITokenNFT.TextRecord[](0));

    _registry.resolveRequest(_token, true);

    // it should leave the canonical reference untouched
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, _chainId);
    assertEq(_readNftId, _nftId);
  }

  function test_ResolveRequestWhenTheApprovedRequestIsMintingTheNft(
    address _token,
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_token);
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _deposit = bound(_deposit, 1, type(uint256).max);
    _seedPendingRequest(_token, _requester, _deposit);
    vm.deal(address(_registry), _deposit);

    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](0);
    bytes memory _mintCall = abi.encodeCall(ITokenNFT.mint, (1, _requester, _records));
    LockedFundsMintObserver _observer = new LockedFundsMintObserver(_registry, _deposit);
    vm.mockFunction(_nftContract, address(_observer), _mintCall);

    // it should keep the deposit locked
    vm.expectEmit(address(_nftContract));
    emit LockedFundsMintObserver.DepositObserved();
    _registry.resolveRequest(_token, true);
  }

  function test_ResolveRequestWhenTheRequesterCancelsTheRequestDuringTheMint(
    address _token,
    uint256 _deposit
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_token);
    _deposit = bound(_deposit, 1, type(uint256).max);
    // `vm.mockFunction` runs the observer in the NFT contract's context, so the NFT contract is both the request's
    // requester and the mint recipient, letting the callback try to cancel its own request mid-approval. Closing the
    // request before the mint is what makes that reentrant cancel revert instead of crediting the deposit twice.
    CancellingMintObserver _observer = new CancellingMintObserver(_registry, _token);
    _seedPendingRequest(_token, _nftContract, _deposit);
    vm.deal(address(_registry), _deposit);
    bytes memory _mintCall = abi.encodeCall(ITokenNFT.mint, (1, _nftContract, new ITokenNFT.TextRecord[](0)));
    vm.mockFunction(_nftContract, address(_observer), _mintCall);

    // it should revert with NotRequester
    vm.expectRevert(ITokenRegistry.NotRequester.selector);
    _registry.resolveRequest(_token, true);
  }

  function test_ResolveRequestWhenTheApprovedRequesterCannotReceiveEth(
    address _token,
    uint256 _deposit
  ) external givenTheCallerIsADelegate givenARequestIsOpen {
    _assumeFuzzable(_token);
    RevertingReceiver _requester = new RevertingReceiver();
    _deposit = bound(_deposit, 1, type(uint256).max);
    _seedPendingRequest(_token, address(_requester), _deposit);
    vm.deal(address(_registry), _deposit);
    _mockAndExpectMint(1, address(_requester), new ITokenNFT.TextRecord[](0));

    _registry.resolveRequest(_token, true);

    // it should credit the refund without reverting
    assertEq(_registry.refundOf(address(_requester)), _deposit);
  }

  function test_ResolveRequestWhenTheRequestIsRejected(
    address _token,
    address _requester,
    uint256 _deposit,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_requester);
    _seedPendingRequest(_token, _requester, _deposit);
    // A non-empty requested reference proves the rejection discards it rather than writing it.
    _chainId = bound(_chainId, 1, type(uint256).max);
    _seedRequestCanonical(_token, _chainId, _nftId);
    vm.deal(address(_registry), _deposit);
    uint256 _requesterBalanceBefore = _requester.balance;

    // it should emit RegistrationRejected with _token, _requester
    _expectEmit(address(_registry));
    emit ITokenRegistry.RegistrationRejected(_token, _requester);

    // A rejection must not mint, so a call to the NFT contract fails the test.
    vm.mockCallRevert(_nftContract, abi.encodeWithSelector(ITokenNFT.mint.selector), 'minted on reject');

    _registry.resolveRequest(_token, false);

    // it should not register the token
    (uint128 _registeredId,) = _registry.registrationOf(_token);
    assertEq(_registeredId, 0);
    assertEq(_registry.nextId(), 1);
    // it should close the request
    (address _readRequester,) = _pendingOf(_token);
    assertEq(_readRequester, address(0));
    // it should keep the deposit as a sweepable fee
    assertEq(_registry.lockedFunds(), 0);
    assertEq(address(_registry).balance, _deposit);
    // it should not credit a refund
    assertEq(_registry.refundOf(_requester), 0);
    assertEq(_requester.balance, _requesterBalanceBefore);
    // it should not set the canonical reference
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, 0);
    assertEq(_readNftId, 0);
  }

  function test_ResolveRequestWhenApprovingOneOfSeveralOpenRequests(
    address _requester,
    uint256 _deposit,
    uint256 _count,
    uint256 _pickSeed
  ) external givenTheCallerIsADelegate {
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    // Several open requests: 2 to 10 keeps "several" meaningful while bounding the seeding loop.
    _count = bound(_count, 2, 10);
    uint256 _pick = bound(_pickSeed, 0, _count - 1);
    // Leave headroom so the `_count` locked deposits sum without overflowing.
    _deposit = bound(_deposit, 0, type(uint256).max / _count);
    vm.deal(address(_registry), _count * _deposit);

    // Open `_count` requests for distinct tokens from the same requester. Ids are assigned only on approval, so no
    // open request holds one yet and the order they were opened in does not matter.
    address[] memory _tokens = new address[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _tokens[_i] = address(uint160(uint256(keccak256(abi.encode('token', _i)))));
      _seedPendingRequest(_tokens[_i], _requester, _deposit);
    }

    _mockAndExpectMint(1, _requester, new ITokenNFT.TextRecord[](0));
    _registry.resolveRequest(_tokens[_pick], true);

    // it should assign the next id to the approved token
    (uint128 _pickedId,) = _registry.registrationOf(_tokens[_pick]);
    assertEq(_pickedId, 1);
    assertEq(_registry.idToToken(1), _tokens[_pick]);
    assertEq(_registry.nextId(), 2);
    // it should credit only the approved deposit
    assertEq(_registry.refundOf(_requester), _deposit);
    assertEq(_registry.lockedFunds(), _count * _deposit);
    // it should leave the other requests untouched
    for (uint256 _i; _i < _count; ++_i) {
      if (_i == _pick) continue;
      (uint128 _openId,) = _registry.registrationOf(_tokens[_i]);
      assertEq(_openId, 0);
      (address _openRequester,) = _pendingOf(_tokens[_i]);
      assertEq(_openRequester, _requester);
    }
  }

  // --- cancel ---

  function test_CancelWhenNoRequestIsOpen(address _token, address _caller) external {
    // An empty request stores the zero requester, which only a pranked zero caller could ever match.
    _assumeFuzzable(_caller);

    // it should revert with NotRequester
    vm.expectRevert(ITokenRegistry.NotRequester.selector);
    vm.prank(_caller);
    _registry.cancel(_token);
  }

  function test_CancelWhenTheCallerIsNotTheRequester(
    address _token,
    address _requester,
    address _caller,
    uint256 _deposit
  ) external {
    _assumeFuzzable(_requester);
    _caller = _boundNotEq(_caller, _requester);
    _seedPendingRequest(_token, _requester, _deposit);

    // it should revert with NotRequester
    vm.expectRevert(ITokenRegistry.NotRequester.selector);
    vm.prank(_caller);
    _registry.cancel(_token);
  }

  /// @notice Each test seeds its own request and pranks as the fuzzed requester, satisfying the branch.
  modifier givenTheCallerIsTheRequester() {
    _;
  }

  function test_CancelWhenTheRequestIsCancelled(
    address _token,
    address _requester,
    uint256 _deposit
  ) external givenTheCallerIsTheRequester {
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _seedPendingRequest(_token, _requester, _deposit);
    vm.deal(address(_registry), _deposit);
    uint256 _requesterBalanceBefore = _requester.balance;

    // it should emit RefundCredited with _requester, _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.RefundCredited(_requester, _deposit);
    // it should emit RegistrationCancelled with _token, _requester
    _expectEmit(address(_registry));
    emit ITokenRegistry.RegistrationCancelled(_token, _requester);

    vm.prank(_requester);
    _registry.cancel(_token);

    // it should close the request
    (address _readRequester,) = _pendingOf(_token);
    assertEq(_readRequester, address(0));
    // it should credit the refund to the requester
    assertEq(_registry.refundOf(_requester), _deposit);
    assertEq(_requester.balance, _requesterBalanceBefore);
    // it should keep the credited refund locked
    assertEq(_registry.lockedFunds(), _deposit);
  }

  function test_CancelWhenTheRequesterCannotReceiveEth(
    address _token,
    uint256 _deposit
  ) external givenTheCallerIsTheRequester {
    RevertingReceiver _requester = new RevertingReceiver();
    _deposit = bound(_deposit, 1, type(uint256).max);
    _seedPendingRequest(_token, address(_requester), _deposit);
    vm.deal(address(_registry), _deposit);

    vm.prank(address(_requester));
    _registry.cancel(_token);

    // it should credit the refund without reverting
    assertEq(_registry.refundOf(address(_requester)), _deposit);
  }

  function test_CancelWhenCancellingOneOfSeveralOpenRequests(
    address _token,
    address _otherToken,
    address _requester,
    uint256 _deposit,
    uint256 _otherDeposit
  ) external givenTheCallerIsTheRequester {
    _assumeFuzzable(_requester);
    vm.assume(_requester.code.length == 0);
    _otherToken = _boundNotEq(_otherToken, _token);
    // Headroom keeps the two escrowed deposits from overflowing when they are summed.
    _deposit = bound(_deposit, 0, type(uint256).max / 2);
    _otherDeposit = bound(_otherDeposit, 0, type(uint256).max / 2);
    _seedPendingRequest(_token, _requester, _deposit);
    _seedPendingRequest(_otherToken, _requester, _otherDeposit);
    vm.deal(address(_registry), _deposit + _otherDeposit);

    vm.prank(_requester);
    _registry.cancel(_token);

    // it should credit only the cancelled deposit
    assertEq(_registry.refundOf(_requester), _deposit);
  }

  // --- claimRefund ---

  function test_ClaimRefundWhenTheRecipientIsTheZeroAddress(address _caller) external {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    vm.prank(_caller);
    _registry.claimRefund(address(0));
  }

  /// @notice Each test passes a fuzzed or deployed non-zero recipient, satisfying the branch.
  modifier givenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_ClaimRefundWhenTheCallerHasNoRefund(
    address _caller,
    address _recipient
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_recipient);

    // it should revert with NoRefund
    vm.expectRevert(ITokenRegistry.NoRefund.selector);
    vm.prank(_caller);
    _registry.claimRefund(_recipient);
  }

  function test_ClaimRefundWhenTheRecipientCannotReceiveEth(
    address _caller,
    uint256 _amount
  ) external givenTheRecipientIsNotTheZeroAddress {
    RevertingReceiver _recipient = new RevertingReceiver();
    _amount = bound(_amount, 1, type(uint128).max);
    _seedRefund(_caller, _amount);
    vm.deal(address(_registry), _amount);

    // The receiver bubbles up its `Error("no ether")` reason, which `_transferETH` wraps in `TransferFailed`.
    bytes memory _reason = abi.encodeWithSignature('Error(string)', 'no ether');

    // it should revert with TransferFailed
    vm.expectRevert(abi.encodeWithSelector(ITokenRegistry.TransferFailed.selector, _reason));
    vm.prank(_caller);
    _registry.claimRefund(address(_recipient));
  }

  function test_ClaimRefundWhenTheClaimSucceeds(
    address _caller,
    address _recipient,
    uint256 _amount,
    uint256 _otherLocked
  ) external givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient.code.length == 0);
    _amount = bound(_amount, 1, type(uint128).max);
    // Other locked funds prove the claim releases only what the caller is owed.
    _otherLocked = bound(_otherLocked, 0, type(uint128).max);
    _seedRefund(_caller, _amount);
    _seedLockedFunds(_amount + _otherLocked);
    vm.deal(address(_registry), _amount + _otherLocked);
    uint256 _recipientBalanceBefore = _recipient.balance;

    // it should emit RefundClaimed with _requester, _recipient, _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.RefundClaimed(_caller, _recipient, _amount);

    vm.prank(_caller);
    _registry.claimRefund(_recipient);

    // it should send the refund to the recipient
    assertEq(_recipient.balance, _recipientBalanceBefore + _amount);
    // it should clear the credited refund
    assertEq(_registry.refundOf(_caller), 0);
    // it should release the locked funds
    assertEq(_registry.lockedFunds(), _otherLocked);
  }

  // --- registerNFTContract ---

  function test_RegisterNFTContractWhenTheCallerIsNotGovernance(address _caller, address _newNft) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.registerNFTContract(_newNft);
  }

  /// @notice Mocks the governor as governance and pranks every call in the test body as it.
  modifier givenTheCallerIsGovernance() {
    _becomeGovernance();
    _;
    vm.stopPrank();
  }

  function test_RegisterNFTContractWhenTheNftContractIsTheZeroAddress() external givenTheCallerIsGovernance {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    _registry.registerNFTContract(address(0));
  }

  /// @notice Each test passes a fuzzed or mocked non-zero contract, satisfying the branch.
  modifier givenTheNftContractIsNotTheZeroAddress() {
    _;
  }

  function test_RegisterNFTContractWhenTheNftContractHasADifferentLeafVoter(address _otherLeafVoter)
    external
    givenTheCallerIsGovernance
    givenTheNftContractIsNotTheZeroAddress
  {
    _otherLeafVoter = _boundNotEq(_otherLeafVoter, _leafVoter);
    address _newNft = _mockContract('NewTokenNFT');
    vm.mockCall(_newNft, abi.encodeCall(ITokenNFT.LEAF_VOTER, ()), abi.encode(_otherLeafVoter));

    // it should revert with InvalidNFTContract
    vm.expectRevert(ITokenRegistry.InvalidNFTContract.selector);
    _registry.registerNFTContract(_newNft);
  }

  /// @notice Each test mocks the candidate's `LEAF_VOTER` to match the registry's, satisfying the branch.
  modifier givenTheNftContractHasTheSameLeafVoter() {
    _;
  }

  function test_RegisterNFTContractWhenTheNftContractHasADifferentTokenRegistry(address _otherRegistry)
    external
    givenTheCallerIsGovernance
    givenTheNftContractIsNotTheZeroAddress
    givenTheNftContractHasTheSameLeafVoter
  {
    _otherRegistry = _boundNotEq(_otherRegistry, address(_registry));
    address _newNft = _mockContract('NewTokenNFT');
    vm.mockCall(_newNft, abi.encodeCall(ITokenNFT.LEAF_VOTER, ()), abi.encode(_leafVoter));
    vm.mockCall(_newNft, abi.encodeCall(ITokenNFT.TOKEN_REGISTRY, ()), abi.encode(_otherRegistry));

    // it should revert with InvalidNFTContract
    vm.expectRevert(ITokenRegistry.InvalidNFTContract.selector);
    _registry.registerNFTContract(_newNft);
  }

  function test_RegisterNFTContractWhenTheNftContractIsValid()
    external
    givenTheCallerIsGovernance
    givenTheNftContractIsNotTheZeroAddress
    givenTheNftContractHasTheSameLeafVoter
  {
    address _newNft = _mockContract('NewTokenNFT');
    _mockAndExpect(_newNft, abi.encodeCall(ITokenNFT.LEAF_VOTER, ()), abi.encode(_leafVoter));
    _mockAndExpect(_newNft, abi.encodeCall(ITokenNFT.TOKEN_REGISTRY, ()), abi.encode(address(_registry)));
    // it should emit NFTContractRegistered with _nftContract
    _expectEmit(address(_registry));
    emit ITokenRegistry.NFTContractRegistered(_newNft);

    _registry.registerNFTContract(_newNft);

    // it should append the contract
    assertEq(_registry.nftContracts(1), _newNft);
  }

  // --- withdraw ---

  function test_WithdrawWhenTheCallerIsNotGovernance(address _caller, address _recipient) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.withdraw(_recipient);
  }

  function test_WithdrawWhenTheRecipientIsTheZeroAddress() external givenTheCallerIsGovernance {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenRegistry.ZeroAddress.selector);
    _registry.withdraw(address(0));
  }

  function test_WithdrawWhenTheRecipientCannotReceiveEth(uint256 _sweepable)
    external
    givenTheCallerIsGovernance
    givenTheRecipientIsNotTheZeroAddress
  {
    _sweepable = bound(_sweepable, 1, type(uint128).max);
    RevertingReceiver _recipient = new RevertingReceiver();
    // No locked funds, so the whole balance is sweepable.
    vm.deal(address(_registry), _sweepable);

    // The receiver bubbles up its `Error("no ether")` reason, which `_transferETH` wraps in `TransferFailed`.
    bytes memory _reason = abi.encodeWithSignature('Error(string)', 'no ether');

    // it should revert with TransferFailed
    vm.expectRevert(abi.encodeWithSelector(ITokenRegistry.TransferFailed.selector, _reason));
    _registry.withdraw(address(_recipient));
  }

  function test_WithdrawWhenTheTransferSucceeds(
    address _recipient,
    uint256 _locked,
    uint256 _sweepable
  ) external givenTheCallerIsGovernance givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient.code.length == 0);
    // Anything above the locked funds is sweepable: forfeited fees plus any ETH force-sent to the contract.
    _locked = bound(_locked, 0, type(uint128).max);
    _sweepable = bound(_sweepable, 0, type(uint128).max);
    _seedLockedFunds(_locked);
    vm.deal(address(_registry), _locked + _sweepable);
    uint256 _balanceBefore = _recipient.balance;

    // it should emit Withdrawn with _recipient, _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.Withdrawn(_recipient, _sweepable);

    _registry.withdraw(_recipient);

    // it should send the balance above the locked funds to the recipient
    assertEq(_recipient.balance, _balanceBefore + _sweepable);
    // it should leave the locked funds in the contract
    assertEq(address(_registry).balance, _locked);
    assertEq(_registry.lockedFunds(), _locked);
  }

  // --- setListing ---

  function test_SetListingWhenTheCallerIsNotGovernance(address _caller, address _token, bool _listed) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setListing(_token, _listed);
  }

  function test_SetListingWhenTheCallerIsGovernance(address _token, bool _listed) external {
    _becomeGovernance();
    // it should emit ListingSet with _token, _listed
    _expectEmit(address(_registry));
    emit ITokenRegistry.ListingSet(_token, _listed);

    _registry.setListing(_token, _listed);

    // it should set the listing to _listed
    assertEq(_registry.isListed(_token), _listed);
  }

  // --- setType ---

  function test_SetTypeWhenTheCallerIsNotGovernance(address _caller, address _token, uint8 _tierType) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setType(_token, _tierType);
  }

  function test_SetTypeWhenTheTypeIsNotZero(
    address _token,
    uint8 _tierType,
    uint8 _existingWeight
  ) external givenTheCallerIsGovernance {
    _tierType = uint8(bound(_tierType, 1, type(uint8).max));
    _existingWeight = uint8(bound(_existingWeight, 0, _MAX_WEIGHT));
    _seedTier(_token, 0, _existingWeight);

    // it should emit TypeSet with _token, _tierType
    _expectEmit(address(_registry));
    emit ITokenRegistry.TypeSet(_token, _tierType);

    _registry.setType(_token, _tierType);

    // it should set the type to _tierType keeping the weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, _tierType);
    assertEq(_readWeight, _existingWeight);
  }

  function test_SetTypeWhenTheTypeIsZero(
    address _token,
    uint8 _existingType,
    uint8 _existingWeight
  ) external givenTheCallerIsGovernance {
    _existingType = uint8(bound(_existingType, 1, type(uint8).max));
    _existingWeight = uint8(bound(_existingWeight, 0, _MAX_WEIGHT));
    _seedTier(_token, _existingType, _existingWeight);

    // it should emit TypeSet with _token, _tierType
    _expectEmit(address(_registry));
    emit ITokenRegistry.TypeSet(_token, 0);

    _registry.setType(_token, 0);

    // it should clear the type keeping the weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, 0);
    assertEq(_readWeight, _existingWeight);
  }

  // --- setWeight ---

  function test_SetWeightWhenTheCallerIsNotGovernance(address _caller, address _token, uint8 _weight) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setWeight(_token, _weight);
  }

  function test_SetWeightWhenTheWeightExceedsTheMaximum(
    address _token,
    uint8 _weight
  ) external givenTheCallerIsGovernance {
    _weight = uint8(bound(_weight, _MAX_WEIGHT + 1, type(uint8).max));

    // it should revert with InvalidWeight
    vm.expectRevert(ITokenRegistry.InvalidWeight.selector);
    _registry.setWeight(_token, _weight);
  }

  function test_SetWeightWhenTheWeightEqualsTheMaximum(
    address _token,
    uint8 _existingType
  ) external givenTheCallerIsGovernance {
    _seedTier(_token, _existingType, 0);

    _registry.setWeight(_token, _MAX_WEIGHT);

    // it should set the weight to the maximum
    (, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readWeight, _MAX_WEIGHT);
  }

  function test_SetWeightWhenTheWeightIsWithinRange(
    address _token,
    uint8 _weight,
    uint8 _existingType
  ) external givenTheCallerIsGovernance {
    _weight = uint8(bound(_weight, 0, _MAX_WEIGHT));
    _existingType = uint8(bound(_existingType, 1, type(uint8).max));
    _seedTier(_token, _existingType, 0);

    // it should emit WeightSet with _token, _weight
    _expectEmit(address(_registry));
    emit ITokenRegistry.WeightSet(_token, _weight);

    _registry.setWeight(_token, _weight);

    // it should set the weight to _weight keeping the type
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, _existingType);
    assertEq(_readWeight, _weight);
  }

  // --- setTier ---

  function test_SetTierWhenTheCallerIsNotGovernance(
    address _caller,
    address _token,
    uint8 _tierType,
    uint8 _weight
  ) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setTier(_token, _tierType, _weight);
  }

  function test_SetTierWhenTheWeightExceedsTheMaximum(
    address _token,
    uint8 _tierType,
    uint8 _weight
  ) external givenTheCallerIsGovernance {
    _weight = uint8(bound(_weight, _MAX_WEIGHT + 1, type(uint8).max));

    // it should revert with InvalidWeight
    vm.expectRevert(ITokenRegistry.InvalidWeight.selector);
    _registry.setTier(_token, _tierType, _weight);
  }

  function test_SetTierWhenTheWeightEqualsTheMaximum(
    address _token,
    uint8 _tierType
  ) external givenTheCallerIsGovernance {
    _registry.setTier(_token, _tierType, _MAX_WEIGHT);

    // it should set the weight to the maximum
    (, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readWeight, _MAX_WEIGHT);
  }

  function test_SetTierWhenTheWeightIsWithinRange(
    address _token,
    uint8 _tierType,
    uint8 _weight,
    uint8 _existingType,
    uint8 _existingWeight
  ) external givenTheCallerIsGovernance {
    _weight = uint8(bound(_weight, 0, _MAX_WEIGHT));
    _existingWeight = uint8(bound(_existingWeight, 0, _MAX_WEIGHT));
    // Seed a prior tier so the assertions prove `setTier` overwrites both bytes, leaking neither the old type nor weight.
    _seedTier(_token, _existingType, _existingWeight);

    // it should emit TierSet with _token, _tierType, _weight
    _expectEmit(address(_registry));
    emit ITokenRegistry.TierSet(_token, _tierType, _weight);

    _registry.setTier(_token, _tierType, _weight);

    // it should set the type and weight to _tierType and _weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, _tierType);
    assertEq(_readWeight, _weight);
  }

  // --- setCanonical ---

  function test_SetCanonicalWhenTheCallerIsNotGovernance(
    address _caller,
    address _token,
    uint256 _chainId,
    uint256 _nftId
  ) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setCanonical(_token, _chainId, _nftId);
  }

  function test_SetCanonicalWhenTheChainIdIsTheLocalChain(
    address _token,
    uint256 _nftId
  ) external givenTheCallerIsGovernance {
    // it should revert with InvalidCanonical
    vm.expectRevert(ITokenRegistry.InvalidCanonical.selector);
    _registry.setCanonical(_token, block.chainid, _nftId);
  }

  function test_SetCanonicalWhenSettingAReference(
    address _token,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsGovernance {
    _chainId = bound(_chainId, 1, type(uint256).max);
    vm.assume(_chainId != block.chainid);

    // it should emit CanonicalSet with _token, _chainId, _nftId
    _expectEmit(address(_registry));
    emit ITokenRegistry.CanonicalSet(_token, _chainId, _nftId);

    _registry.setCanonical(_token, _chainId, _nftId);

    // it should set the canonical reference to _chainId and _nftId
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, _chainId);
    assertEq(_readNftId, _nftId);
  }

  function test_SetCanonicalWhenClearingAReference(
    address _token,
    uint256 _chainId,
    uint256 _nftId
  ) external givenTheCallerIsGovernance {
    _chainId = bound(_chainId, 1, type(uint256).max);
    _nftId = bound(_nftId, 1, type(uint256).max);
    // Seed a non-zero reference first, then clear it with zero values.
    _seedCanonical(_token, _chainId, _nftId);

    // it should emit CanonicalSet with _token, _chainId, _nftId
    _expectEmit(address(_registry));
    emit ITokenRegistry.CanonicalSet(_token, 0, 0);

    _registry.setCanonical(_token, 0, 0);

    // it should clear the canonical reference
    (uint256 _readChainId, uint256 _readNftId) = _registry.canonicalOf(_token);
    assertEq(_readChainId, 0);
    assertEq(_readNftId, 0);
  }

  // --- setDepositAmount ---

  function test_SetDepositAmountWhenTheCallerIsNotGovernance(address _caller, uint256 _amount) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setDepositAmount(_amount);
  }

  function test_SetDepositAmountWhenTheCallerIsGovernance(uint256 _amount) external {
    _becomeGovernance();

    // it should emit DepositAmountSet with _amount
    _expectEmit(address(_registry));
    emit ITokenRegistry.DepositAmountSet(_amount);

    _registry.setDepositAmount(_amount);

    // it should set the deposit amount to _amount
    assertEq(_registry.depositAmount(), _amount);
  }

  // --- setExemptActor ---

  function test_SetExemptActorWhenTheCallerIsNotGovernance(address _caller, address _account, bool _exempt) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setExemptActor(_account, _exempt);
  }

  function test_SetExemptActorWhenTheCallerIsGovernance(address _account, bool _exempt) external {
    _becomeGovernance();
    // it should emit ExemptSet with _account, _exempt
    _expectEmit(address(_registry));
    emit ITokenRegistry.ExemptSet(_account, _exempt);

    _registry.setExemptActor(_account, _exempt);

    // it should set the exemption to _exempt
    assertEq(_registry.isExempt(_account), _exempt);
  }

  // --- setDelegateReviewer ---

  function test_SetDelegateReviewerWhenTheCallerIsNotGovernance(
    address _caller,
    address _account,
    bool _allowed
  ) external {
    _mockGovernor(_caller, false);

    // it should revert with NotGovernance
    vm.expectRevert(ITokenRegistry.NotGovernance.selector);
    vm.prank(_caller);
    _registry.setDelegateReviewer(_account, _allowed);
  }

  function test_SetDelegateReviewerWhenTheCallerIsGovernance(address _account, bool _allowed) external {
    _becomeGovernance();
    // it should emit DelegateSet with _account, _allowed
    _expectEmit(address(_registry));
    emit ITokenRegistry.DelegateSet(_account, _allowed);

    _registry.setDelegateReviewer(_account, _allowed);

    // it should set the delegate status to _allowed
    assertEq(_registry.isDelegate(_account), _allowed);
  }

  // --- tier ---

  function test_TierWhenTheTokenHasNoTierSet(address _token) external view {
    // it should return zero type and zero weight
    (uint8 _tierType, uint8 _weight) = _registry.tier(_token);
    assertEq(_tierType, 0);
    assertEq(_weight, 0);
  }

  function test_TierWhenTheTokenHasWeightWithoutAType(address _token, uint8 _weight) external {
    _weight = uint8(bound(_weight, 1, _MAX_WEIGHT));
    _seedTier(_token, 0, _weight);

    // it should return zero type and the weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, 0);
    assertEq(_readWeight, _weight);
  }

  function test_TierWhenTheTokenHasATypeWithoutAWeight(address _token, uint8 _tierType) external {
    _tierType = uint8(bound(_tierType, 1, type(uint8).max));
    _seedTier(_token, _tierType, 0);

    // it should return the type and zero weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, _tierType);
    assertEq(_readWeight, 0);
  }

  function test_TierWhenTheTokenHasATierSet(address _token, uint8 _tierType, uint8 _weight) external {
    _weight = uint8(bound(_weight, 1, _MAX_WEIGHT));
    _seedTier(_token, _tierType, _weight);

    // it should return the decoded type and weight
    (uint8 _readType, uint8 _readWeight) = _registry.tier(_token);
    assertEq(_readType, _tierType);
    assertEq(_readWeight, _weight);
  }

  // --- metadata ---

  function test_MetadataWhenTheTokenHasACanonicalReference(
    address _token,
    uint256 _chainId,
    uint256 _nftId,
    uint256 _id,
    string[] calldata _keys
  ) external {
    // A non-zero chain id marks the token as bridged.
    _chainId = bound(_chainId, 1, type(uint256).max);
    _seedCanonical(_token, _chainId, _nftId);
    // Seed a local NFT too, to prove the canonical short-circuit ignores it.
    _id = bound(_id, 1, type(uint128).max);
    _seedRegistration(_token, _id, 0);
    // The local read must never happen: a stray call reverts and fails the test.
    vm.mockCallRevert(_nftContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), 'records called');

    (ITokenRegistry.CanonicalReference memory _canonical, string[] memory _values) = _registry.metadata(_token, _keys);

    // it should return the reference
    assertEq(_canonical.chainId, _chainId);
    assertEq(_canonical.nftId, _nftId);
    // it should return empty values without reading the local nft
    assertEq(_values.length, 0);
  }

  function test_MetadataWhenTheTokenIsNativeAndHasNoNft(address _token, string[] calldata _keys) external view {
    (ITokenRegistry.CanonicalReference memory _canonical, string[] memory _values) = _registry.metadata(_token, _keys);

    // it should return an empty reference
    assertEq(_canonical.chainId, 0);
    assertEq(_canonical.nftId, 0);
    // it should return an empty array
    assertEq(_values.length, 0);
  }

  function test_MetadataWhenTheTokenIsNativeAndItsNftWasMintedOnTheCurrentContract(
    address _token,
    uint256 _id,
    string[] calldata _keys,
    string[] calldata _values
  ) external {
    _id = bound(_id, 1, type(uint128).max);
    _seedRegistration(_token, _id, 0);
    _mockAndExpect(_nftContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), abi.encode(_values));

    (ITokenRegistry.CanonicalReference memory _canonical, string[] memory _returned) = _registry.metadata(_token, _keys);

    // it should return an empty reference
    assertEq(_canonical.chainId, 0);
    assertEq(_canonical.nftId, 0);
    // it should forward the read to the current contract
    assertEq(_returned.length, _values.length);
    for (uint256 _i; _i < _values.length; ++_i) {
      assertEq(_returned[_i], _values[_i]);
    }
  }

  function test_MetadataWhenTheTokenIsNativeAndItsNftWasMintedOnAnOlderContract(
    address _token,
    uint256 _id,
    string[] calldata _keys,
    string[] calldata _values
  ) external {
    // Append a newer contract after the one seeded in setUp, while the token's recorded index stays on the older one.
    address _newerContract = _mockContract('NewerTokenNFT');
    _id = bound(_id, 1, type(uint128).max);
    _pushNftContract(_newerContract);
    _seedRegistration(_token, _id, 0);

    // The older contract, at index zero, is the one the read must forward to.
    _mockAndExpect(_nftContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), abi.encode(_values));
    // The newer contract must not be read, so a call to its `records` reverts the test.
    vm.mockCallRevert(_newerContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), 'newer read');

    (ITokenRegistry.CanonicalReference memory _canonical, string[] memory _returned) = _registry.metadata(_token, _keys);

    // it should return an empty reference
    assertEq(_canonical.chainId, 0);
    assertEq(_canonical.nftId, 0);
    // it should forward the read to the older contract
    assertEq(_returned.length, _values.length);
    for (uint256 _i; _i < _values.length; ++_i) {
      assertEq(_returned[_i], _values[_i]);
    }
  }

  function test_MetadataWhenTheTokenIsNativeAndItsNftWasMintedOnANewerContract(
    address _token,
    uint256 _id,
    string[] calldata _keys,
    string[] calldata _values
  ) external {
    // The token's recorded index points at the newer contract, so the older one must not be read.
    address _newerContract = _mockContract('NewerTokenNFT');
    _id = bound(_id, 1, type(uint128).max);
    _pushNftContract(_newerContract);
    _seedRegistration(_token, _id, 1);

    _mockAndExpect(_newerContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), abi.encode(_values));
    vm.mockCallRevert(_nftContract, abi.encodeCall(ITokenNFT.records, (_id, _keys)), 'older read');

    (ITokenRegistry.CanonicalReference memory _canonical, string[] memory _returned) = _registry.metadata(_token, _keys);

    // it should return an empty reference
    assertEq(_canonical.chainId, 0);
    assertEq(_canonical.nftId, 0);
    // it should forward the read to the newer contract
    assertEq(_returned.length, _values.length);
    for (uint256 _i; _i < _values.length; ++_i) {
      assertEq(_returned[_i], _values[_i]);
    }
  }

  // --- pendingRequest ---

  function test_PendingRequestWhenNoRequestIsOpen(address _token) external view {
    // it should return an empty request
    ITokenRegistry.MetadataRequest memory _request = _registry.pendingRequest(_token);
    assertEq(_request.requester, address(0));
    assertEq(_request.deposit, 0);
    assertEq(_request.records.length, 0);
  }

  function test_PendingRequestWhenARequestIsOpen(
    address _token,
    address _requester,
    uint256 _deposit,
    uint256 _chainId,
    uint256 _nftId
  ) external {
    _assumeFuzzable(_requester);
    _seedPendingRequest(_token, _requester, _deposit);

    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](1);
    _records[0] = ITokenNFT.TextRecord({key: 'key', value: 'value'});
    _seedRequestRecords(_token, _records);
    _seedRequestCanonical(_token, _chainId, _nftId);

    // it should return the requester and deposit
    (address _readRequester, uint256 _readDeposit) = _pendingOf(_token);
    assertEq(_readRequester, _requester);
    assertEq(_readDeposit, _deposit);
    // it should return the records
    ITokenRegistry.MetadataRequest memory _readRequest = _registry.pendingRequest(_token);
    assertEq(_readRequest.records.length, 1);
    assertEq(_readRequest.records[0].key, 'key');
    assertEq(_readRequest.records[0].value, 'value');
    // it should return the canonical reference
    assertEq(_readRequest.canonical.chainId, _chainId);
    assertEq(_readRequest.canonical.nftId, _nftId);
  }

  // --- Auth mocking ---

  /// @notice Mocks the LeafVoter's governance-role check for `_account` to return `_isGovernor` and expects it.
  function _mockGovernor(address _account, bool _isGovernor) internal {
    _mockAndExpect(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _account)), abi.encode(_isGovernor)
    );
  }

  /// @notice Mocks the governor as governance and starts pranking as it.
  /// @dev Uses `startPrank` so intermediate setup calls or deployments do not consume a single-shot prank before the
  ///      function under test runs. The role check is mocked without an `expectCall`, since callers may revert first.
  function _becomeGovernance() internal {
    vm.mockCall(
      _leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.GOVERNANCE_ROLE, _GOVERNOR)), abi.encode(true)
    );
    vm.startPrank(_GOVERNOR);
  }

  // --- NFT mocking ---

  /// @notice Mocks the current NFT contract's `mint` and expects it with the given arguments.
  function _mockAndExpectMint(uint256 _id, address _to, ITokenNFT.TextRecord[] memory _records) internal {
    _mockAndExpect(_nftContract, abi.encodeCall(ITokenNFT.mint, (_id, _to, _records)), '');
  }

  // --- Records ---

  /// @notice Caps a fuzzed records array at ten entries, exercising the multi-record path without discarding runs.
  function _boundRecords(ITokenNFT
        .TextRecord[] memory _records) internal pure returns (ITokenNFT.TextRecord[] memory _bounded) {
    if (_records.length <= 10) return _records;
    _bounded = new ITokenNFT.TextRecord[](10);
    for (uint256 _i; _i < 10; ++_i) {
      _bounded[_i] = _records[_i];
    }
  }

  // --- Storage seeding ---

  /// @notice Appends an NFT contract to `nftContracts` (one address slot each) and grows the length.
  function _pushNftContract(address _nftAddress) internal {
    uint256 _index = uint256(vm.load(address(_registry), bytes32(_NFT_CONTRACTS_SLOT)));
    uint256 _base = uint256(keccak256(abi.encode(_NFT_CONTRACTS_SLOT))) + _index;
    vm.store(address(_registry), bytes32(_base), bytes32(uint256(uint160(_nftAddress))));
    vm.store(address(_registry), bytes32(_NFT_CONTRACTS_SLOT), bytes32(_index + 1));
  }

  /// @notice Seeds `registrationOf[_token]`: the minting contract index packed above the NFT id.
  function _seedRegistration(address _token, uint256 _id, uint256 _index) internal {
    vm.store(address(_registry), keccak256(abi.encode(_token, _REGISTRATION_OF_SLOT)), bytes32((_index << 128) | _id));
  }

  /// @notice Seeds `refundOf[_requester]` and counts it in `lockedFunds`, mirroring a credited refund.
  function _seedRefund(address _requester, uint256 _amount) internal {
    vm.store(address(_registry), keccak256(abi.encode(_requester, _REFUND_OF_SLOT)), bytes32(_amount));
    uint256 _locked = uint256(vm.load(address(_registry), bytes32(_LOCKED_FUNDS_SLOT)));
    vm.store(address(_registry), bytes32(_LOCKED_FUNDS_SLOT), bytes32(_locked + _amount));
  }

  /// @notice Seeds `lockedFunds`.
  function _seedLockedFunds(uint256 _amount) internal {
    vm.store(address(_registry), bytes32(_LOCKED_FUNDS_SLOT), bytes32(_amount));
  }

  /// @notice Seeds the tier of `_token`, packed as the struct stores it: `tierType` in the low byte, `weight` above.
  function _seedTier(address _token, uint8 _tierType, uint8 _weight) internal {
    uint16 _packed = (uint16(_weight) << 8) | _tierType;
    vm.store(address(_registry), keccak256(abi.encode(_token, _TIERS_SLOT)), bytes32(uint256(_packed)));
  }

  /// @notice Seeds `canonicalOf[_token]` (the struct spans two slots: chain id then nft id).
  function _seedCanonical(address _token, uint256 _chainId, uint256 _nftId) internal {
    uint256 _base = uint256(keccak256(abi.encode(_token, _CANONICAL_OF_SLOT)));
    vm.store(address(_registry), bytes32(_base), bytes32(_chainId));
    vm.store(address(_registry), bytes32(_base + 1), bytes32(_nftId));
  }

  /// @notice Seeds a pending request's `requester` and `deposit` (its records left empty).
  /// @dev `requester` occupies the struct's first slot, `deposit` the next.
  function _seedPendingRequest(address _token, address _requester, uint256 _deposit) internal {
    bytes32 _base = keccak256(abi.encode(_token, _PENDING_REQUESTS_SLOT));
    vm.store(address(_registry), _base, bytes32(uint256(uint160(_requester))));
    vm.store(address(_registry), bytes32(uint256(_base) + 1), bytes32(_deposit));
    // Mirror `requestRegistration`: an open request's deposit is locked, so keep `lockedFunds` consistent.
    uint256 _locked = uint256(vm.load(address(_registry), bytes32(_LOCKED_FUNDS_SLOT)));
    vm.store(address(_registry), bytes32(_LOCKED_FUNDS_SLOT), bytes32(_locked + _deposit));
  }

  /// @notice Packs a short (`< 32` bytes) string as Solidity stores it: bytes high to low, `length * 2` in the low byte.
  function _packShortString(string memory _value) internal pure returns (bytes32 _packed) {
    bytes memory _bytes = bytes(_value);
    for (uint256 _i; _i < _bytes.length; ++_i) {
      _packed |= bytes32(uint256(uint8(_bytes[_i])) << (8 * (31 - _i)));
    }
    _packed |= bytes32(_bytes.length * 2);
  }

  /// @notice Seeds an open request's records array, one slot for each short key and value.
  function _seedRequestRecords(address _token, ITokenNFT.TextRecord[] memory _records) internal {
    bytes32 _recordsSlot = bytes32(uint256(keccak256(abi.encode(_token, _PENDING_REQUESTS_SLOT))) + 2);
    vm.store(address(_registry), _recordsSlot, bytes32(_records.length));
    uint256 _data = uint256(keccak256(abi.encode(_recordsSlot)));
    for (uint256 _i; _i < _records.length; ++_i) {
      vm.store(address(_registry), bytes32(_data + _i * 2), _packShortString(_records[_i].key));
      vm.store(address(_registry), bytes32(_data + _i * 2 + 1), _packShortString(_records[_i].value));
    }
  }

  /// @notice Writes a pending request's canonical reference into the struct slots trailing the records array.
  function _seedRequestCanonical(address _token, uint256 _chainId, uint256 _nftId) internal {
    bytes32 _base = keccak256(abi.encode(_token, _PENDING_REQUESTS_SLOT));
    vm.store(address(_registry), bytes32(uint256(_base) + 3), bytes32(_chainId));
    vm.store(address(_registry), bytes32(uint256(_base) + 4), bytes32(_nftId));
  }

  /// @notice Builds a non-empty, short (`< 32` bytes) text value from fuzz seeds, bounding the length instead of
  ///         discarding runs, since `_seedRequestRecords` only packs short strings.
  function _boundedShortText(bytes32 _seed, uint256 _lengthSeed) internal pure returns (string memory _text) {
    uint256 _length = bound(_lengthSeed, 1, 31);
    bytes memory _bytes = new bytes(_length);
    for (uint256 _i; _i < _length; ++_i) {
      _bytes[_i] = _seed[_i];
    }
    _text = string(_bytes);
  }

  /// @notice Reads back a pending request's requester and deposit through the getter.
  function _pendingOf(address _token) internal view returns (address _requester, uint256 _deposit) {
    ITokenRegistry.MetadataRequest memory _request = _registry.pendingRequest(_token);
    _requester = _request.requester;
    _deposit = _request.deposit;
  }
}
