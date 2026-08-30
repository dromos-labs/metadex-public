// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {IMessageAdapter, IRootLocalAdapter, RootLocalAdapter} from 'V3/bridge/RootLocalAdapter.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';

contract UnitRootLocalAdapter is TestHelpers {
  uint256 internal constant _ROOT_CHAIN_ID = 8453;

  address internal immutable _ROOT_MESSAGE_ORCHESTRATOR = makeAddr('RootMessageOrchestrator');
  address internal immutable _LEAF_MESSAGE_ORCHESTRATOR = makeAddr('LeafMessageOrchestrator');

  RootLocalAdapter internal _adapter;

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    vm.chainId(_ROOT_CHAIN_ID);
    _adapter = new RootLocalAdapter(_ROOT_MESSAGE_ORCHESTRATOR, _LEAF_MESSAGE_ORCHESTRATOR);
  }

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenRootMessageOrchestratorIsTheZeroAddress(address _leafMessageOrchestrator) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMessageAdapter.ZeroAddress.selector);

    new RootLocalAdapter(address(0), _leafMessageOrchestrator);
  }

  function test_ConstructorWhenLeafMessageOrchestratorIsTheZeroAddress(address _rootMessageOrchestrator) external {
    _assumeFuzzable(_rootMessageOrchestrator);

    // it should revert with ZeroAddress
    vm.expectRevert(IMessageAdapter.ZeroAddress.selector);

    new RootLocalAdapter(_rootMessageOrchestrator, address(0));
  }

  function test_ConstructorWhenRootMessageOrchestratorAndLeafMessageOrchestratorHaveTheSameAddress(address _messageOrchestrator)
    external
  {
    _assumeFuzzable(_messageOrchestrator);

    // it should revert with IdenticalOrchestrators
    vm.expectRevert(IRootLocalAdapter.IdenticalOrchestrators.selector);

    new RootLocalAdapter(_messageOrchestrator, _messageOrchestrator);
  }

  function test_ConstructorWhenAllInputsAreValid(
    address _rootMessageOrchestrator,
    address _leafMessageOrchestrator
  ) external {
    _assumeFuzzable(_rootMessageOrchestrator);
    _assumeFuzzable(_leafMessageOrchestrator);
    vm.assume(_rootMessageOrchestrator != _leafMessageOrchestrator);

    _adapter = new RootLocalAdapter(_rootMessageOrchestrator, _leafMessageOrchestrator);

    // it should set REMOTE_CHAIN_ID to block.chainid
    assertEq(_adapter.REMOTE_CHAIN_ID(), block.chainid);

    // it should set ROOT_MESSAGE_ORCHESTRATOR to _rootMessageOrchestrator
    assertEq(_adapter.ROOT_MESSAGE_ORCHESTRATOR(), _rootMessageOrchestrator);

    // it should set LEAF_MESSAGE_ORCHESTRATOR to _leafMessageOrchestrator
    assertEq(_adapter.LEAF_MESSAGE_ORCHESTRATOR(), _leafMessageOrchestrator);
  }

  /*////////////////////////////////////////////////////////////
                          SEND MESSAGE
  ////////////////////////////////////////////////////////////*/

  function test_SendMessageWhenMsgValueIsNonzero(
    address _caller,
    bytes calldata _message,
    uint256 _value,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    vm.assume(_value != 0);
    _assumeFuzzable(_caller);
    vm.deal(_caller, _value);

    // it should revert with NoFeeRequired
    vm.expectRevert(IRootLocalAdapter.NoFeeRequired.selector);

    vm.prank(_caller);
    _adapter.sendMessage{value: _value}(_message, _gasLimit, _refundRecipient);
  }

  modifier givenMsgValueIsZero() {
    _;
  }

  function test_SendMessageWhenMessageSenderIsTheRootMessageOrchestrator(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenMsgValueIsZero {
    // it should call route on LEAF_MESSAGE_ORCHESTRATOR with REMOTE_CHAIN_ID and _message
    _mockAndExpect(
      _LEAF_MESSAGE_ORCHESTRATOR, abi.encodeCall(IMessageOrchestrator.route, (_ROOT_CHAIN_ID, _message)), ''
    );

    vm.prank(_ROOT_MESSAGE_ORCHESTRATOR);
    _adapter.sendMessage(_message, _gasLimit, _refundRecipient);
  }

  function test_SendMessageWhenMessageSenderIsTheLeafMessageOrchestrator(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenMsgValueIsZero {
    // it should call route on ROOT_MESSAGE_ORCHESTRATOR with REMOTE_CHAIN_ID and _message
    _mockAndExpect(
      _ROOT_MESSAGE_ORCHESTRATOR, abi.encodeCall(IMessageOrchestrator.route, (_ROOT_CHAIN_ID, _message)), ''
    );

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _adapter.sendMessage(_message, _gasLimit, _refundRecipient);
  }

  function test_SendMessageWhenMessageSenderIsNotARegisteredOrchestrator(
    address _caller,
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenMsgValueIsZero {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _ROOT_MESSAGE_ORCHESTRATOR);
    vm.assume(_caller != _LEAF_MESSAGE_ORCHESTRATOR);

    // it should revert with CallerNotOrchestrator
    vm.expectRevert(IMessageAdapter.CallerNotOrchestrator.selector);

    vm.prank(_caller);
    _adapter.sendMessage(_message, _gasLimit, _refundRecipient);
  }

  /*////////////////////////////////////////////////////////////
                          QUOTE MESSAGE
  ////////////////////////////////////////////////////////////*/

  function test_QuoteMessageWhenCalledWithAnyInputs(
    bytes calldata _message,
    uint256 _gasLimit,
    address _refundRecipient
  ) external view {
    // it should return zero
    assertEq(_adapter.quoteMessage(_message, _gasLimit, _refundRecipient), 0);
  }

  /*////////////////////////////////////////////////////////////
                              HANDLE
  ////////////////////////////////////////////////////////////*/

  function test_HandleWhenCalledWithAnyInputs(
    address _caller,
    uint32 _origin,
    bytes32 _sender,
    bytes calldata _message
  ) external {
    _assumeFuzzable(_caller);

    // it should revert with NotSupported
    vm.expectRevert(IRootLocalAdapter.NotSupported.selector);

    vm.prank(_caller);
    _adapter.handle(_origin, _sender, _message);
  }

  /*////////////////////////////////////////////////////////////
                        SET REMOTE ADAPTER
  ////////////////////////////////////////////////////////////*/

  function test_SetRemoteAdapterWhenCalledWithAnyInputs(address _caller, bytes32 _remoteAdapter) external {
    _assumeFuzzable(_caller);

    // it should revert with NotSupported
    vm.expectRevert(IRootLocalAdapter.NotSupported.selector);

    vm.prank(_caller);
    _adapter.setRemoteAdapter(_remoteAdapter);
  }
}
