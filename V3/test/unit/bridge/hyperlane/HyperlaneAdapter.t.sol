// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {
  HyperlaneAdapter,
  IHyperlaneAdapter,
  IMailbox,
  IMessageAdapter,
  IMessageOrchestrator,
  StandardHookMetadata
} from 'V3/bridge/hyperlane/HyperlaneAdapter.sol';

contract UnitHyperlaneAdapter is TestHelpers {
  uint256 internal constant _REMOTE_CHAIN_ID = 1;
  uint32 internal constant _REMOTE_DOMAIN_ID = 1;
  /// @dev Local Hyperlane domain reported by the mailbox; distinct from `_REMOTE_DOMAIN_ID` so construction succeeds.
  uint32 internal constant _LOCAL_DOMAIN_ID = 2;

  /// @dev Storage slot of `remoteAdapter` in `HyperlaneAdapter` (the only mutable storage).
  uint256 internal constant _REMOTE_ADAPTER_SLOT = 0;

  address internal immutable _ORCHESTRATOR = makeAddr('Orchestrator');
  address internal immutable _MAILBOX = makeAddr('Mailbox');
  address internal immutable _VOTER = makeAddr('Voter');
  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');

  HyperlaneAdapter internal _adapter;

  function setUp() public {
    // The constructor reads MAILBOX.localDomain() to reject self-loop domains; mock it distinct from the remote domain.
    vm.mockCall(_MAILBOX, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_LOCAL_DOMAIN_ID));
    _adapter = new HyperlaneAdapter(_REMOTE_CHAIN_ID, _REMOTE_DOMAIN_ID, _ORCHESTRATOR, _MAILBOX, _VOTER);
    // The adapter resolves authority via VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, caller). Default any caller to false,
    // then override for the recognized authority.
    vm.mockCall(_VOTER, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    vm.mockCall(
      _VOTER, abi.encodeCall(IAccessControl.hasRole, (Roles.ADAPTER_CONFIG_ROLE, _ADAPTER_AUTHORITY)), abi.encode(true)
    );
  }

  function test_ConstructorWhenRemoteChainIdIsZero(
    uint32 _remoteDomainId,
    address _orchestrator,
    address _mailbox,
    address _voter
  ) external {
    // it should revert with InvalidChainId
    vm.expectRevert(IMessageAdapter.InvalidChainId.selector);
    new HyperlaneAdapter(0, _remoteDomainId, _orchestrator, _mailbox, _voter);
  }

  function test_ConstructorWhenRemoteChainIdIsEqualToBlockChainid(
    uint32 _remoteDomainId,
    address _orchestrator,
    address _mailbox,
    address _voter
  ) external {
    // it should revert with InvalidChainId
    vm.expectRevert(IMessageAdapter.InvalidChainId.selector);
    new HyperlaneAdapter(block.chainid, _remoteDomainId, _orchestrator, _mailbox, _voter);
  }

  function test_ConstructorWhenRemoteDomainIdIsZero(
    uint256 _remoteChainId,
    address _orchestrator,
    address _mailbox,
    address _voter
  ) external {
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);

    // it should revert with InvalidDomain
    vm.expectRevert(IHyperlaneAdapter.InvalidDomain.selector);
    new HyperlaneAdapter(_remoteChainId, 0, _orchestrator, _mailbox, _voter);
  }

  function test_ConstructorWhenOrchestratorIsTheZeroAddress(
    uint256 _remoteChainId,
    uint32 _remoteDomainId,
    address _mailbox,
    address _voter
  ) external {
    vm.assume(_remoteDomainId != 0);
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);

    // it should revert with ZeroAddress
    vm.expectRevert(IMessageAdapter.ZeroAddress.selector);
    new HyperlaneAdapter(_remoteChainId, _remoteDomainId, address(0), _mailbox, _voter);
  }

  function test_ConstructorWhenMailboxIsTheZeroAddress(
    uint256 _remoteChainId,
    uint32 _remoteDomainId,
    address _orchestrator,
    address _voter
  ) external {
    vm.assume(_remoteDomainId != 0);
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);
    vm.assume(_orchestrator != address(0));

    // it should revert with ZeroAddress
    vm.expectRevert(IMessageAdapter.ZeroAddress.selector);
    new HyperlaneAdapter(_remoteChainId, _remoteDomainId, _orchestrator, address(0), _voter);
  }

  function test_ConstructorWhenAdapterAuthorityIsTheZeroAddress(
    uint256 _remoteChainId,
    uint32 _remoteDomainId,
    address _orchestrator,
    address _mailbox
  ) external {
    vm.assume(_remoteDomainId != 0);
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);
    vm.assume(_orchestrator != address(0));
    vm.assume(_mailbox != address(0));

    // it should revert with ZeroAddress
    vm.expectRevert(IMessageAdapter.ZeroAddress.selector);
    new HyperlaneAdapter(_remoteChainId, _remoteDomainId, _orchestrator, _mailbox, address(0));
  }

  function test_ConstructorWhenRemoteDomainIdIsEqualToLocalDomain(
    uint256 _remoteChainId,
    uint32 _localDomain,
    address _orchestrator,
    address _mailbox,
    address _voter
  ) external {
    vm.assume(_localDomain != 0);
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);
    _assumeFuzzable(_orchestrator);
    _assumeFuzzable(_mailbox);
    _assumeFuzzable(_voter);

    // The mailbox reports _localDomain; passing the same value as the remote domain is a transport self-loop.
    vm.mockCall(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_localDomain));

    // it should revert with InvalidDomain
    vm.expectRevert(IHyperlaneAdapter.InvalidDomain.selector);
    new HyperlaneAdapter(_remoteChainId, _localDomain, _orchestrator, _mailbox, _voter);
  }

  function test_ConstructorWhenAllInputsAreValid(
    uint256 _remoteChainId,
    uint32 _remoteDomainId,
    uint32 _localDomain,
    address _orchestrator,
    address _mailbox,
    address _voter
  ) external {
    vm.assume(_remoteDomainId != 0);
    vm.assume(_remoteDomainId != _localDomain);
    vm.assume(_remoteChainId != 0);
    vm.assume(_remoteChainId != block.chainid);
    _assumeFuzzable(_orchestrator);
    _assumeFuzzable(_mailbox);
    _assumeFuzzable(_voter);

    // it should call localDomain on MAILBOX
    _mockAndExpect(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_localDomain));

    _adapter = new HyperlaneAdapter(_remoteChainId, _remoteDomainId, _orchestrator, _mailbox, _voter);

    // it should set REMOTE_CHAIN_ID to _remoteChainId
    assertEq(_adapter.REMOTE_CHAIN_ID(), _remoteChainId);
    // it should set REMOTE_DOMAIN_ID to _remoteDomainId
    assertEq(_adapter.REMOTE_DOMAIN_ID(), _remoteDomainId);
    // it should set ORCHESTRATOR to _orchestrator
    assertEq(address(_adapter.ORCHESTRATOR()), _orchestrator);
    // it should set MAILBOX to _mailbox
    assertEq(address(_adapter.MAILBOX()), _mailbox);
    // it should set VOTER to _voter
    assertEq(address(_adapter.VOTER()), _voter);
  }

  function test_SendMessageWhenMsgSenderIsNotORCHESTRATOR(
    address _msgSender,
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    vm.assume(_msgSender != _ORCHESTRATOR);

    // it should revert with CallerNotOrchestrator
    vm.expectRevert(IMessageAdapter.CallerNotOrchestrator.selector);

    vm.prank(_msgSender);
    _adapter.sendMessage(_message, _gasLimit, _refundRecipient);
  }

  modifier givenMsgSenderIsORCHESTRATOR() {
    vm.prank(_ORCHESTRATOR);
    _;
  }

  function test_SendMessageWhenGasLimitIsZero(
    bytes calldata _message,
    address _refundRecipient
  ) external givenMsgSenderIsORCHESTRATOR {
    // it should revert with InvalidGasLimit
    vm.expectRevert(IHyperlaneAdapter.InvalidGasLimit.selector);

    _adapter.sendMessage(_message, 0, _refundRecipient);
  }

  function test_SendMessageWhenRemoteAdapterIsZero(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenMsgSenderIsORCHESTRATOR {
    vm.assume(_gasLimit != 0);

    // it should revert with RemoteAdapterNotSet
    vm.expectRevert(IHyperlaneAdapter.RemoteAdapterNotSet.selector);

    _adapter.sendMessage(_message, _gasLimit, _refundRecipient);
  }

  function test_SendMessageWhenRemoteAdapterIsSet(
    uint256 _value,
    bytes32 _remoteAdapter,
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient,
    bytes32 _messageId
  ) external givenMsgSenderIsORCHESTRATOR givenRemoteAdapterIsSet(_remoteAdapter) {
    vm.assume(_gasLimit != 0);
    vm.deal(_ORCHESTRATOR, _value);

    // NOTE: `IMailbox.dispatch` is overloaded — `abi.encodeCall` rejects ambiguous refs, use signature form.
    bytes memory _expectedCalldata = abi.encodeWithSignature(
      'dispatch(uint32,bytes32,bytes,bytes)',
      _REMOTE_DOMAIN_ID,
      _remoteAdapter,
      _message,
      StandardHookMetadata.format(0, _gasLimit, _refundRecipient)
    );

    // it should call dispatch on MAILBOX with REMOTE_DOMAIN_ID, _remoteAdapter, _message and the formatted hook metadata forwarding msg.value
    _mockAndExpectWithValue(_MAILBOX, _value, _expectedCalldata, abi.encode(_messageId));

    // it should emit MessageSent with _messageId and _remoteAdapter
    _expectEmit(address(_adapter));
    emit IHyperlaneAdapter.MessageSent(_messageId, _remoteAdapter);

    _adapter.sendMessage{value: _value}(_message, _gasLimit, _refundRecipient);
  }

  function test_QuoteMessageWhenGasLimitIsZero(bytes calldata _message, address _refundRecipient) external {
    // it should revert with InvalidGasLimit
    vm.expectRevert(IHyperlaneAdapter.InvalidGasLimit.selector);

    _adapter.quoteMessage(_message, 0, _refundRecipient);
  }

  function test_QuoteMessageWhenRemoteAdapterIsZero(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    vm.assume(_gasLimit != 0);

    // it should revert with RemoteAdapterNotSet
    vm.expectRevert(IHyperlaneAdapter.RemoteAdapterNotSet.selector);

    _adapter.quoteMessage(_message, _gasLimit, _refundRecipient);
  }

  function test_QuoteMessageWhenRemoteAdapterIsSet(
    bytes32 _remoteAdapter,
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _quotedFee
  ) external givenRemoteAdapterIsSet(_remoteAdapter) {
    vm.assume(_gasLimit != 0);

    // NOTE: `IMailbox.quoteDispatch` is overloaded — `abi.encodeCall` rejects ambiguous refs, use signature form.
    // Built exactly like the `sendMessage` dispatch expectation so both assert the same hook metadata bytes.
    bytes memory _expectedCalldata = abi.encodeWithSignature(
      'quoteDispatch(uint32,bytes32,bytes,bytes)',
      _REMOTE_DOMAIN_ID,
      _remoteAdapter,
      _message,
      StandardHookMetadata.format(0, _gasLimit, _refundRecipient)
    );

    // it should call quoteDispatch on MAILBOX with REMOTE_DOMAIN_ID, _remoteAdapter, _message and the same formatted hook metadata sendMessage dispatches with
    _mockAndExpect(_MAILBOX, _expectedCalldata, abi.encode(_quotedFee));

    // it should return the fee quoted by MAILBOX
    assertEq(_adapter.quoteMessage(_message, _gasLimit, _refundRecipient), _quotedFee);
  }

  function test_HandleWhenMsgSenderIsNotMAILBOX(
    address _msgSender,
    uint32 _origin,
    bytes32 _sender,
    bytes calldata _message
  ) external {
    vm.assume(_msgSender != _MAILBOX);

    // it should revert with CallerNotMailbox
    vm.expectRevert(IHyperlaneAdapter.CallerNotMailbox.selector);

    vm.prank(_msgSender);
    _adapter.handle(_origin, _sender, _message);
  }

  modifier givenMsgSenderIsMAILBOX() {
    vm.prank(_MAILBOX);
    _;
  }

  function test_HandleWhenOriginIsNotEqualToRemoteDomainId(
    uint32 _origin,
    bytes32 _sender,
    bytes calldata _message
  ) external givenMsgSenderIsMAILBOX {
    vm.assume(_origin != _REMOTE_DOMAIN_ID);

    // it should revert with UnauthorizedOrigin
    vm.expectRevert(IHyperlaneAdapter.UnauthorizedOrigin.selector);

    _adapter.handle(_origin, _sender, _message);
  }

  modifier givenOriginIsEqualToRemoteDomainId() {
    _;
  }

  function test_HandleWhenRemoteAdapterIsZero(
    bytes32 _sender,
    bytes calldata _message
  ) external givenMsgSenderIsMAILBOX givenOriginIsEqualToRemoteDomainId {
    // it should revert with RemoteAdapterNotSet
    vm.expectRevert(IHyperlaneAdapter.RemoteAdapterNotSet.selector);

    _adapter.handle(_REMOTE_DOMAIN_ID, _sender, _message);
  }

  modifier givenRemoteAdapterIsSet(bytes32 _remoteAdapter) {
    vm.assume(_remoteAdapter != bytes32(0));
    vm.store(address(_adapter), bytes32(_REMOTE_ADAPTER_SLOT), _remoteAdapter);
    _;
  }

  function test_HandleWhenSenderIsNotTheRemoteAdapter(
    bytes32 _remoteAdapter,
    bytes32 _sender,
    bytes calldata _message
  ) external givenMsgSenderIsMAILBOX givenOriginIsEqualToRemoteDomainId givenRemoteAdapterIsSet(_remoteAdapter) {
    vm.assume(_sender != _remoteAdapter);

    // it should revert with UnauthorizedSender
    vm.expectRevert(IHyperlaneAdapter.UnauthorizedSender.selector);

    _adapter.handle(_REMOTE_DOMAIN_ID, _sender, _message);
  }

  function test_HandleWhenAllInputsAreValid(
    bytes32 _remoteAdapter,
    bytes calldata _message
  ) external givenMsgSenderIsMAILBOX givenOriginIsEqualToRemoteDomainId givenRemoteAdapterIsSet(_remoteAdapter) {
    // it should call route on ORCHESTRATOR with REMOTE_CHAIN_ID and _message
    _mockAndExpect(_ORCHESTRATOR, abi.encodeCall(IMessageOrchestrator.route, (_REMOTE_CHAIN_ID, _message)), '');

    _adapter.handle(_REMOTE_DOMAIN_ID, _remoteAdapter, _message);
  }

  function test_HandleWhenTheDeliveryCarriesRelayerValue(
    bytes32 _remoteAdapter,
    bytes calldata _message,
    uint96 _value
  ) external givenOriginIsEqualToRemoteDomainId givenRemoteAdapterIsSet(_remoteAdapter) {
    // The Hyperlane Mailbox forwards `msg.value` from `process()` into `handle`, so a relayer can fund the
    // deallocation return in the same delivery; the adapter must pass it through to the pre-funding pool.
    _value = uint96(bound(_value, 1, type(uint96).max));
    vm.deal(_MAILBOX, _value);

    // it should forward the full value to route
    vm.mockCall(_ORCHESTRATOR, abi.encodeCall(IMessageOrchestrator.route, (_REMOTE_CHAIN_ID, _message)), '');
    vm.expectCall(_ORCHESTRATOR, _value, abi.encodeCall(IMessageOrchestrator.route, (_REMOTE_CHAIN_ID, _message)));

    // Raw call: the mailbox delivers with value attached, exactly as `Mailbox.process{value:...}` does.
    vm.prank(_MAILBOX);
    (bool _delivered,) = address(_adapter).call{value: _value}(
      abi.encodeCall(IMessageAdapter.handle, (_REMOTE_DOMAIN_ID, _remoteAdapter, _message))
    );

    // it should accept the value carrying delivery
    assertTrue(_delivered);
  }

  function test_SetRemoteAdapterWhenMsgSenderIsNotAdapterAuthority(
    address _msgSender,
    bytes32 _remoteAdapter
  ) external {
    vm.assume(_msgSender != _ADAPTER_AUTHORITY);

    // it should revert with CallerNotAdapterAuthority
    vm.expectRevert(IHyperlaneAdapter.CallerNotAdapterAuthority.selector);

    vm.prank(_msgSender);
    _adapter.setRemoteAdapter(_remoteAdapter);
  }

  modifier givenMsgSenderIsAdapterAuthority() {
    vm.prank(_ADAPTER_AUTHORITY);
    _;
  }

  function test_SetRemoteAdapterWhenRemoteAdapterIsZero() external givenMsgSenderIsAdapterAuthority {
    // it should revert with InvalidRemoteAdapter
    vm.expectRevert(IHyperlaneAdapter.InvalidRemoteAdapter.selector);

    _adapter.setRemoteAdapter(bytes32(0));
  }

  function test_SetRemoteAdapterWhenRemoteAdapterIsNonzero(bytes32 _remoteAdapter)
    external
    givenMsgSenderIsAdapterAuthority
  {
    vm.assume(_remoteAdapter != bytes32(0));

    // it should emit RemoteAdapterUpdated with _remoteAdapter
    _expectEmit(address(_adapter));
    emit IHyperlaneAdapter.RemoteAdapterUpdated(_remoteAdapter);
    _adapter.setRemoteAdapter(_remoteAdapter);

    // it should set remoteAdapter to _remoteAdapter
    assertEq(_adapter.remoteAdapter(), _remoteAdapter);
  }
}
