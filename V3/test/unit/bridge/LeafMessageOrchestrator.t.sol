// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {
  ILeafMessageOrchestrator,
  ILeafVoter,
  IMessageAdapter,
  IMessageOrchestrator,
  LeafMessageOrchestrator
} from 'V3/bridge/LeafMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {Roles} from 'V3/libraries/Roles.sol';

contract UnitLeafMessageOrchestrator is TestHelpers {
  uint256 internal constant _ROOT_CHAIN_ID = 8453;

  /// @dev Storage slots as reported by `forge inspect LeafMessageOrchestrator storage`.
  uint256 internal constant _ADAPTER_SLOT = 0;
  /// @dev Storage slot of the `nonceOut` field in `LeafMessageOrchestrator`.
  uint256 internal constant _NONCE_OUT_SLOT = 1;
  /// @dev Storage slot of the `noncesUsed` mapping in `LeafMessageOrchestrator`.
  uint256 internal constant _NONCES_USED_SLOT = 2;
  /// @dev Storage slot of the `deallocationGasLimit` field in `LeafMessageOrchestrator`.
  uint256 internal constant _DEALLOCATION_GAS_LIMIT_SLOT = 3;
  /// @dev Storage slot of the `lastChainVoteNonce` field in `LeafMessageOrchestrator`.
  uint256 internal constant _LAST_CHAIN_VOTE_NONCE_SLOT = 4;
  /// @dev Storage slot of the `lastTokenIdVoteNonce` mapping in `LeafMessageOrchestrator`.
  uint256 internal constant _LAST_TOKEN_ID_VOTE_NONCE_SLOT = 5;
  /// @dev Storage slot of the `lastOperatorNonce` mapping in `LeafMessageOrchestrator`.
  uint256 internal constant _LAST_OPERATOR_NONCE_SLOT = 6;
  /// @dev Storage slot of the `lastEmergencyDeallocNonce` mapping in `LeafMessageOrchestrator`.
  uint256 internal constant _LAST_EMERGENCY_DEALLOC_NONCE_SLOT = 7;
  /// @dev Storage slot of the `lastShapeNonce` mapping in `LeafMessageOrchestrator`.
  uint256 internal constant _LAST_SHAPE_NONCE_SLOT = 8;

  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _GAS_CONFIGURER = makeAddr('GasConfigurer');
  address internal immutable _NATIVE_WITHDRAWER = makeAddr('NativeWithdrawer');
  address internal immutable _LEAF_VOTER = makeAddr('LeafVoter');
  address internal immutable _ADAPTER = makeAddr('Adapter');

  LeafMessageOrchestrator internal _orchestrator;

  /// @dev Seeds `deallocationGasLimit` directly in storage so the dispatch and quote paths never call the setter on
  /// the contract under test. Self-asserts through the public getter, so a slot-layout change fails loudly here.
  function _mockDeallocationGasLimit(uint256 _gasLimit) internal {
    vm.store(address(_orchestrator), bytes32(_DEALLOCATION_GAS_LIMIT_SLOT), bytes32(_gasLimit));
    assertEq(_orchestrator.deallocationGasLimit(), _gasLimit);
  }

  /// @dev Computes the storage slot of `noncesUsed[_nonce]`.
  function _noncesUsedSlot(uint256 _nonce) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_nonce, _NONCES_USED_SLOT));
  }

  /// @dev Computes the storage slot of `lastTokenIdVoteNonce[_tokenId]`.
  function _lastTokenIdVoteNonceSlot(uint256 _tokenId) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_tokenId, _LAST_TOKEN_ID_VOTE_NONCE_SLOT));
  }

  /// @dev Computes the storage slot of `lastOperatorNonce[_tokenId]`.
  function _lastOperatorNonceSlot(uint256 _tokenId) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_tokenId, _LAST_OPERATOR_NONCE_SLOT));
  }

  /// @dev Computes the storage slot of `lastEmergencyDeallocNonce[_tokenId]`.
  function _lastEmergencyDeallocNonceSlot(uint256 _tokenId) internal pure returns (bytes32 _slot) {
    _slot = keccak256(abi.encode(_tokenId, _LAST_EMERGENCY_DEALLOC_NONCE_SLOT));
  }

  /// @dev Builds an EmergencyDeallocateMessage route payload draining `_amount` for `_tokenId` at `_chainNonce`.
  function _emergencyDeallocatePayload(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount
  ) internal view returns (bytes memory _payload) {
    _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.EmergencyDeallocate),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.EmergencyDeallocateMessage({tokenId: _tokenId, amount: _amount}))
    );
  }

  /// @dev Distinct nonzero chain field and snapshot derived from `_seed`. Zeroed fields would let a wrong decode
  /// pass unnoticed — zero bytes decode to zeros at any offset — so only distinct values give the decode assertions
  /// teeth against field transposition.
  function _fuzzedChainFields(uint256 _seed)
    internal
    pure
    returns (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot)
  {
    _emissionsPerVP = uint256(keccak256(abi.encode(_seed, 'emissionsPerVP')));
    _tokenSnapshot = IVoterCommon.TokenSnapshot({
      staked: uint128(uint256(keccak256(abi.encode(_seed, 'staked')))),
      stakeEnd: uint48(uint256(keccak256(abi.encode(_seed, 'stakeEnd')))),
      // Independent seed so the flag round-trips both ways, giving the encode/decode assertions real teeth.
      isPermanent: (uint256(keccak256(abi.encode(_seed, 'isPermanent'))) & 1) == 1
    });
  }

  /// @dev Builds an AllocateChainMessage route payload with chain fields derived from the nonce.
  function _allocateChainPayload(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta
  ) internal view returns (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) {
    (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot) = _fuzzedChainFields(_chainNonce);
    _message = IVoterCommon.AllocateChainMessage({
      tokenId: _tokenId, allocationDelta: _allocationDelta, emissionsPerVP: _emissionsPerVP, snapshot: _tokenSnapshot
    });
    _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateChain), _chainNonce, uint48(block.timestamp), abi.encode(_message)
    );
  }

  /// @dev Builds a single-gauge AllocateGaugeMessage route payload and mocks applyGaugeAllocations to return one entry.
  /// Returns the encoded payload, the returned CheckpointData entry, and the built message so callers assert
  /// the decoded fields exactly. Snapshot derives from the nonce via `_fuzzedChainFields`.
  function _seedGaugeForward(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge,
    bytes memory _data
  )
    internal
    returns (
      bytes memory _payload,
      ILeafVoter.CheckpointData memory _callParams,
      IVoterCommon.AllocateGaugeMessage memory _gaugeMessage
    )
  {
    (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot) = _fuzzedChainFields(_chainNonce);
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _gauge, allocated: 0, data: ''});
    _gaugeMessage = IVoterCommon.AllocateGaugeMessage({
      tokenId: _tokenId,
      expiry: uint48(block.timestamp),
      emissionsPerVP: _emissionsPerVP,
      tokenSnapshot: _tokenSnapshot,
      allocations: _allocations
    });
    _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateGauge),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(_gaugeMessage)
    );

    _callParams = ILeafVoter.CheckpointData({gauge: _gauge, allocated: 0, data: _data});
    ILeafVoter.CheckpointData[] memory _callParamsList = new ILeafVoter.CheckpointData[](1);
    _callParamsList[0] = _callParams;
    // Callers of this helper apply the gauge distribution from a fresh nonce (the chain-vote high-water is
    // unseeded, so `_chainNonce > lastChainVoteNonce`), so the forwarded scalar-update flag is always true.
    // Scalar-freshness tests that need `_refreshEmissionsPerVP: false` build their own mock and do not use this helper.
    vm.mockCall(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (_tokenId, _gaugeMessage.expiry, _emissionsPerVP, true, true, _tokenSnapshot, _allocations)
      ),
      abi.encode(_callParamsList)
    );
  }

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    _orchestrator = new LeafMessageOrchestrator(_LEAF_VOTER, _ROOT_CHAIN_ID);
    // The orchestrator resolves adapter authority via LEAF_VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, caller). Default
    // any caller to false, then override for the recognized holder.
    vm.mockCall(_LEAF_VOTER, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    vm.mockCall(
      _LEAF_VOTER,
      abi.encodeCall(IAccessControl.hasRole, (Roles.ADAPTER_CONFIG_ROLE, _ADAPTER_AUTHORITY)),
      abi.encode(true)
    );
    vm.mockCall(
      _LEAF_VOTER,
      abi.encodeCall(IAccessControl.hasRole, (Roles.GAS_CONFIGURER_ROLE, _GAS_CONFIGURER)),
      abi.encode(true)
    );
    vm.mockCall(
      _LEAF_VOTER,
      abi.encodeCall(IAccessControl.hasRole, (Roles.NATIVE_WITHDRAWER_ROLE, _NATIVE_WITHDRAWER)),
      abi.encode(true)
    );
    // Default the chain status to Active; suspended-path tests override locally.
    vm.mockCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.chainStatus, ()), abi.encode(IVoterCommon.ChainStatus.Active));
  }

  /// @dev Builds the wrapped envelope `dispatch` stamps: the 39-byte header (`uint8` type + `uint256` nonce +
  /// `uint48` dispatchedAt) followed by the payload. Mirrors `MessageOrchestrator._encodeMessage`.
  function _wrap(
    IMessageOrchestrator.MessageType _msgType,
    uint256 _nonce,
    bytes memory _payload
  ) internal view returns (bytes memory _message) {
    _message = abi.encodePacked(uint8(_msgType), _nonce, uint48(block.timestamp), _payload);
  }

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenLeafVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMessageOrchestrator.ZeroAddress.selector);
    new LeafMessageOrchestrator(address(0), _ROOT_CHAIN_ID);
  }

  function test_ConstructorWhenRootChainIdIsZero(address _leafVoter) external {
    _assumeFuzzable(_leafVoter);

    // it should revert with InvalidRootChainId
    vm.expectRevert(ILeafMessageOrchestrator.InvalidRootChainId.selector);
    new LeafMessageOrchestrator(_leafVoter, 0);
  }

  function test_ConstructorWhenAllInputsAreValid(address _leafVoter, uint256 _rootChainId) external {
    _assumeFuzzable(_leafVoter);
    _rootChainId = bound(_rootChainId, 1, type(uint256).max);

    _orchestrator = new LeafMessageOrchestrator(_leafVoter, _rootChainId);

    // it should set LEAF_VOTER to _leafVoter
    assertEq(address(_orchestrator.LEAF_VOTER()), _leafVoter);
    // it should set ROOT_CHAIN_ID to _rootChainId
    assertEq(_orchestrator.ROOT_CHAIN_ID(), _rootChainId);
  }

  /*////////////////////////////////////////////////////////////
                              DISPATCH
  ////////////////////////////////////////////////////////////*/

  function test_DispatchWhenTheCallerIsNotTheLeafVoter(
    address _caller,
    uint8 _msgTypeByte,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    bool _fundFromPool
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _LEAF_VOTER);
    _msgTypeByte = uint8(bound(_msgTypeByte, 0, uint8(type(IMessageOrchestrator.MessageType).max)));

    // it should revert with CallerNotAuthorized
    vm.expectRevert(IMessageOrchestrator.CallerNotAuthorized.selector);

    vm.prank(_caller);
    _orchestrator.dispatch(
      IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient, _fundFromPool
    );
  }

  modifier givenTheCallerIsTheLeafVoter() {
    vm.startPrank(_LEAF_VOTER);
    _;
    vm.stopPrank();
  }

  function test_DispatchWhenTheMessageTypeIsNotRedeem(
    uint8 _msgTypeByte,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    bool _fundFromPool
  ) external givenTheCallerIsTheLeafVoter {
    // Skip Redeem and Deallocate — the only supported dispatch types on this leaf path. Bound to seven
    // slots, then shift past each supported value in ascending order so the fuzz covers the full
    // unsupported set {None, AllocateChain, AllocateGauge, ClaimRewards, SetOperator, ReduceCooldown,
    // EmergencyDeallocate} with no gaps.
    _msgTypeByte = uint8(bound(_msgTypeByte, 0, uint8(type(IMessageOrchestrator.MessageType).max) - 2));
    if (_msgTypeByte >= uint8(IMessageOrchestrator.MessageType.Redeem)) _msgTypeByte += 1;
    if (_msgTypeByte >= uint8(IMessageOrchestrator.MessageType.Deallocate)) _msgTypeByte += 1;

    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.dispatch(
      IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient, _fundFromPool
    );
  }

  modifier givenTheMessageTypeIsRedeem() {
    _;
  }

  function test_DispatchWhenNoAdapterIsRegistered(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    bool _fundFromPool
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsRedeem {
    // adapter slot is zero by default (setUp does not register one)

    // it should revert with AdapterNotRegistered
    vm.expectRevert(IMessageOrchestrator.AdapterNotRegistered.selector);

    _orchestrator.dispatch(
      IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, _fundFromPool
    );
  }

  modifier givenAnAdapterIsRegistered() {
    // write adapter slot directly to avoid calling setAdapter on the contract under test
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));
    _;
  }

  function test_DispatchGivenAnAdapterIsRegistered(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _msgValue
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsRedeem givenAnAdapterIsRegistered {
    _msgValue = bound(_msgValue, 0, type(uint128).max);
    vm.deal(_LEAF_VOTER, _msgValue);
    uint256 _expectedNonce = _orchestrator.nonceOut() + 1;
    bytes memory _message = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.Redeem), _expectedNonce, uint48(block.timestamp), _payload
    );

    // it should read the root chain id from the adapter
    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should call sendMessage on the adapter with the wrapped message, _gasLimit, _refundRecipient, and msg value
    _mockAndExpectWithValue(
      _ADAPTER, _msgValue, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, _refundRecipient)), ''
    );

    // it should emit MessageDispatched with the adapter remote chain id, _nonce and _msgType
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageDispatched(_ROOT_CHAIN_ID, _expectedNonce, IMessageOrchestrator.MessageType.Redeem);

    _orchestrator.dispatch{value: _msgValue}(
      IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, false
    );

    // it should increment nonceOut
    assertEq(_orchestrator.nonceOut(), _expectedNonce);
  }

  function test_DispatchWhenARedeemSuppliesAGasLimitAndADeallocationBudgetIsConfigured(
    bytes calldata _payload,
    uint256 _configuredGasLimit,
    uint256 _suppliedGasLimit,
    address _refundRecipient
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsRedeem givenAnAdapterIsRegistered {
    // `Redeem` is user-initiated and keeps its own budget: the configured deallocation limit must not leak into it.
    vm.assume(_configuredGasLimit != _suppliedGasLimit);
    _mockDeallocationGasLimit(_configuredGasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Redeem, _orchestrator.nonceOut() + 1, _payload);

    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should send the message with the supplied gas limit
    _mockAndExpect(
      _ADAPTER, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _suppliedGasLimit, _refundRecipient)), ''
    );

    // it should never pass the configured deallocation gas limit to the adapter
    vm.expectCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _configuredGasLimit, _refundRecipient)), 0
    );

    _orchestrator.dispatch(
      IMessageOrchestrator.MessageType.Redeem, _payload, _suppliedGasLimit, _refundRecipient, false
    );
  }

  function test_DispatchWhenTheAdapterQuotesANonzeroFeeForARedeem(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _fee,
    uint256 _msgValue
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsRedeem {
    // Only `Deallocate` is fee-gated. A Redeem never prices the transport, so it forwards the caller's whole value
    // even when it sits BELOW a nonzero quote — the transport, not the orchestrator, rejects an underpaid Redeem.
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));
    _fee = bound(_fee, 1, type(uint128).max);
    _msgValue = bound(_msgValue, 0, _fee - 1);
    vm.deal(_LEAF_VOTER, _msgValue);

    uint256 _expectedNonce = _orchestrator.nonceOut() + 1;
    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Redeem, _expectedNonce, _payload);

    vm.mockCall(_ADAPTER, abi.encodeWithSelector(IMessageAdapter.quoteMessage.selector), abi.encode(_fee));
    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should not quote the transport
    vm.expectCall(_ADAPTER, abi.encodeWithSelector(IMessageAdapter.quoteMessage.selector), 0);

    // it should forward the whole msg value to the adapter
    _mockAndExpectWithValue(
      _ADAPTER, _msgValue, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, _refundRecipient)), ''
    );

    _orchestrator.dispatch{value: _msgValue}(
      IMessageOrchestrator.MessageType.Redeem, _payload, _gasLimit, _refundRecipient, false
    );
  }

  /*////////////////////////////////////////////////////////////
                        DISPATCH DEALLOCATE
  ////////////////////////////////////////////////////////////*/

  /// @dev Registers an adapter so the Deallocate branch reaches the transport. The fee is a live adapter quote, so
  /// no cost slot is seeded. Writes storage directly to keep the dispatch path isolated from the setters.
  modifier givenTheMessageTypeIsDeallocate() {
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));
    _;
  }

  function test_DispatchWhenTheDeallocateRouteIsSuspended(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsDeallocate {
    // Unlike Redeem, a Deallocate confirmation dispatches through while Suspended: it only returns VP to
    // root (clamped, cannot inflate) and root accepts it during suspension, so blocking it here would
    // strand the return until resume. The status is never read on the Deallocate branch (short-circuit),
    // so it is set via `vm.mockCall` without an expectation.
    vm.mockCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.chainStatus, ()), abi.encode(IVoterCommon.ChainStatus.Suspended));
    // A Deallocate is stamped with the configured budget; seeding it as the value the call also supplies keeps this
    // test on the suspension behavior. The dedicated divergence tests below pin which of the two wins.
    _mockDeallocationGasLimit(_gasLimit);

    uint256 _expectedNonce = _orchestrator.nonceOut() + 1;
    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _expectedNonce, _payload);

    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));
    // Zero quote so the caller-funded path is satisfied by a zero-value dispatch; the fee is orthogonal to the
    // suspension behavior under test.
    _mockAndExpect(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _gasLimit, _refundRecipient)), abi.encode(0)
    );

    // it should dispatch the deallocation confirmation through the adapter
    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, _refundRecipient)), '');

    // it should emit MessageDispatched with the adapter remote chain id, _nonce and _msgType
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageDispatched(
      _ROOT_CHAIN_ID, _expectedNonce, IMessageOrchestrator.MessageType.Deallocate
    );

    _orchestrator.dispatch(IMessageOrchestrator.MessageType.Deallocate, _payload, _gasLimit, _refundRecipient, false);
  }

  function test_DispatchWhenTheDeallocationIsCallerFundedAndCoversTheQuote(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _fee,
    uint256 _msgValue
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsDeallocate {
    // Caller-funded (`_fundFromPool: false`): the quote is only a floor. The WHOLE `msg.value` is forwarded so the
    // transport refunds the excess to the caller's `_refundRecipient` — the orchestrator never keeps the difference.
    _fee = bound(_fee, 0, type(uint96).max);
    _msgValue = bound(_msgValue, _fee, type(uint128).max);
    vm.deal(_LEAF_VOTER, _msgValue);
    // The stamped budget comes from config on this branch; seeded equal to the supplied value so the funding
    // behavior is what this test isolates.
    _mockDeallocationGasLimit(_gasLimit);

    uint256 _expectedNonce = _orchestrator.nonceOut() + 1;
    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _expectedNonce, _payload);

    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should quote the transport with the wrapped message and the caller refund recipient
    _mockAndExpect(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _gasLimit, _refundRecipient)), abi.encode(_fee)
    );

    // it should forward the whole msg value with the caller refund recipient
    _mockAndExpectWithValue(
      _ADAPTER, _msgValue, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, _refundRecipient)), ''
    );

    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageDispatched(
      _ROOT_CHAIN_ID, _expectedNonce, IMessageOrchestrator.MessageType.Deallocate
    );

    _orchestrator.dispatch{value: _msgValue}(
      IMessageOrchestrator.MessageType.Deallocate, _payload, _gasLimit, _refundRecipient, false
    );

    // it should increment nonceOut
    assertEq(_orchestrator.nonceOut(), _expectedNonce);
  }

  function test_DispatchWhenTheDeallocationIsCallerFundedAndBelowTheQuote(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _fee,
    uint256 _msgValue
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsDeallocate {
    // The caller must cover the live quote; the pre-funding pool is never tapped on this path, so a shortfall
    // cannot be silently absorbed. Fund the pool anyway to prove the revert is not a balance failure.
    _fee = bound(_fee, 1, type(uint128).max);
    _msgValue = bound(_msgValue, 0, _fee - 1);
    vm.deal(_LEAF_VOTER, _msgValue);
    vm.deal(address(_orchestrator), _fee);
    // The quote is taken against the configured budget; seeded equal to the supplied value so the mock matches and
    // the shortfall is the only thing under test.
    _mockDeallocationGasLimit(_gasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _orchestrator.nonceOut() + 1, _payload);

    vm.mockCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _gasLimit, _refundRecipient)), abi.encode(_fee)
    );

    vm.expectCall(_ADAPTER, abi.encodeWithSelector(IMessageAdapter.sendMessage.selector), 0);

    // it should revert with InsufficientDeallocationMessageValue
    vm.expectRevert(ILeafMessageOrchestrator.InsufficientDeallocationMessageValue.selector);

    _orchestrator.dispatch{value: _msgValue}(
      IMessageOrchestrator.MessageType.Deallocate, _payload, _gasLimit, _refundRecipient, false
    );
  }

  function test_DispatchWhenTheDeallocationIsPoolFunded(
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _fee,
    uint256 _prefunding
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsDeallocate {
    // Pool-funded (`_fundFromPool: true`): the orchestrator draws EXACTLY the quote from its own pre-funding and
    // names itself as the refund recipient, so the transport's excess refund flows back into the pool. The caller's
    // `_refundRecipient` is ignored on this path.
    _fee = bound(_fee, 0, type(uint96).max);
    _prefunding = bound(_prefunding, _fee, type(uint128).max);
    vm.assume(_refundRecipient != address(_orchestrator));
    vm.deal(address(_orchestrator), _prefunding);
    // The stamped budget comes from config on this branch; seeded equal to the supplied value so the funding flow
    // is what this test isolates.
    _mockDeallocationGasLimit(_gasLimit);
    // A real value-accepting adapter, so the drawn fee actually leaves the pre-funding (a mocked call keeps it).
    address _sink = address(new ValueSinkAdapter(_fee, _ROOT_CHAIN_ID));
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_sink))));

    uint256 _expectedNonce = _orchestrator.nonceOut() + 1;
    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _expectedNonce, _payload);

    vm.expectCall(_sink, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _gasLimit, address(_orchestrator))));

    // it should forward exactly the quoted fee with the orchestrator as refund recipient
    vm.expectCall(
      _sink, _fee, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, address(_orchestrator)))
    );

    // it should emit MessageDispatched with the adapter remote chain id, _nonce and _msgType
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageDispatched(
      _ROOT_CHAIN_ID, _expectedNonce, IMessageOrchestrator.MessageType.Deallocate
    );

    _orchestrator.dispatch(IMessageOrchestrator.MessageType.Deallocate, _payload, _gasLimit, _refundRecipient, true);

    // it should draw the fee from the orchestrator balance
    assertEq(address(_orchestrator).balance, _prefunding - _fee);
    assertEq(_sink.balance, _fee);
    assertEq(_orchestrator.nonceOut(), _expectedNonce);
  }

  function test_DispatchWhenADeallocationSuppliesAGasLimitOtherThanTheConfiguredOne(
    bytes calldata _payload,
    uint256 _configuredGasLimit,
    uint256 _suppliedGasLimit,
    address _refundRecipient,
    uint256 _fee
  ) external givenTheCallerIsTheLeafVoter givenTheMessageTypeIsDeallocate {
    // A `Deallocate` is protocol-issued: the caller's gas limit is discarded and the configured budget is what both
    // the quote and the send carry, so the fee can never be priced against a budget the send does not use. Both
    // adapter calls are mocked by EXACT calldata, so a leaked `_suppliedGasLimit` misses the mock and fails here.
    vm.assume(_configuredGasLimit != _suppliedGasLimit);
    _fee = bound(_fee, 0, type(uint96).max);
    vm.deal(_LEAF_VOTER, _fee);
    _mockDeallocationGasLimit(_configuredGasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _orchestrator.nonceOut() + 1, _payload);

    _mockAndExpect(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should quote the transport with the configured deallocation gas limit
    _mockAndExpect(
      _ADAPTER,
      abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _configuredGasLimit, _refundRecipient)),
      abi.encode(_fee)
    );

    // it should send the message with the configured deallocation gas limit
    _mockAndExpectWithValue(
      _ADAPTER, _fee, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _configuredGasLimit, _refundRecipient)), ''
    );

    // it should never pass the supplied gas limit to the adapter
    vm.expectCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _suppliedGasLimit, _refundRecipient)), 0
    );
    vm.expectCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _suppliedGasLimit, _refundRecipient)), 0
    );

    _orchestrator.dispatch{value: _fee}(
      IMessageOrchestrator.MessageType.Deallocate, _payload, _suppliedGasLimit, _refundRecipient, false
    );
  }

  /*////////////////////////////////////////////////////////////
                              ROUTE
  ////////////////////////////////////////////////////////////*/

  function test_RouteWhenTheCallerIsNotTheAdapter(
    address _caller,
    uint256 _originChainId,
    bytes calldata _payload
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _ADAPTER);
    // register an adapter so the test exercises "adapter set, caller does not match"
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));

    // it should revert with CallerNotAdapter
    vm.expectRevert(IMessageOrchestrator.CallerNotAdapter.selector);

    vm.prank(_caller);
    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenTheCallerIsTheAdapter() {
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));
    vm.startPrank(_ADAPTER);
    _;
    vm.stopPrank();
  }

  function test_RouteWhenThePayloadIsShorterThanTheHeader(uint8 _payloadLen) external givenTheCallerIsTheAdapter {
    // The header is 39 bytes (`uint8` type + `uint256` nonce + `uint48` dispatchedAt); 38 is the boundary.
    _payloadLen = uint8(bound(_payloadLen, 0, 38));
    bytes memory _payload = new bytes(_payloadLen);

    // it should revert with InvalidPayload
    vm.expectRevert(IMessageOrchestrator.InvalidPayload.selector);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  modifier givenThePayloadContainsTheHeader() {
    _;
  }

  function test_RouteWhenTheMessageTypeByteIsNone(
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader {
    bytes memory _payload = abi.encodePacked(uint8(0), _chainNonce, uint48(block.timestamp), _body);

    // it should revert with NoneMessageType
    vm.expectRevert(IMessageOrchestrator.NoneMessageType.selector);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  function test_RouteWhenTheMessageTypeByteIsOutOfRange(
    uint8 _msgTypeByte,
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader {
    _msgTypeByte = uint8(bound(_msgTypeByte, uint8(type(IMessageOrchestrator.MessageType).max) + 1, type(uint8).max));
    bytes memory _payload = abi.encodePacked(_msgTypeByte, _chainNonce, uint48(block.timestamp), _body);

    // it should revert with InvalidMessageType
    vm.expectRevert(IMessageOrchestrator.InvalidMessageType.selector);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  modifier givenTheMessageTypeByteIsInRange() {
    _;
  }

  function test_RouteWhenTheMessageWasDispatchedAheadOfTheLocalClock(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint48 _clockLag
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // A chain resuming from an outage produces blocks stamped behind wall time, so a message can arrive with a
    // `dispatchedAt` its clock has not reached yet. Applying it would start accrual before root booked it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    _clockLag = uint48(bound(_clockLag, 1, 52 weeks));
    // Give the clock room to lag behind the dispatch stamp.
    vm.warp(block.timestamp + _clockLag);
    uint48 _dispatchedAt = uint48(block.timestamp);
    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should revert with ClockBehindDispatch
    vm.warp(_dispatchedAt - _clockLag);
    vm.expectRevert(IMessageOrchestrator.ClockBehindDispatch.selector);
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should deliver once the clock reaches the dispatch time
    vm.warp(_dispatchedAt);
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _message.emissionsPerVP, true, true, _message.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheNonceHasAlreadyBeenUsed(
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // Mark the inbound nonce as already consumed by a prior message.
    vm.store(address(_orchestrator), _noncesUsedSlot(_chainNonce), bytes32(uint256(1)));

    // The global replay gate fires before type dispatch, so any in-range type triggers it. Use AllocateChain.
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateChain), _chainNonce, uint48(block.timestamp), _body
    );

    // it should revert with NonceAlreadyUsed
    vm.expectRevert(IMessageOrchestrator.NonceAlreadyUsed.selector);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  /*////////////////////////////////////////////////////////////
                        ROUTE ALLOCATE CHAIN
  ////////////////////////////////////////////////////////////*/

  modifier whenTheMessageTypeIsAllocateChain() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsAllocateChain(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateChain
  {
    // The chain gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should call applyChainAllocation with the decoded chain fields and the scalar update flag true when the chain
    // nonce is newer
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _message.emissionsPerVP, true, true, _message.snapshot)
      ),
      ''
    );

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.AllocateChain
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastChainVoteNonce to the chain nonce when it is newer
    assertEq(_orchestrator.lastChainVoteNonce(), _chainNonce);
    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheChainNonceDoesNotAdvanceTheChainVoteNonce(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateChain
  {
    _chainNonce = bound(_chainNonce, 1, type(uint256).max - 1);
    // Seed lastChainVoteNonce above the inbound nonce so the chain gate does not advance.
    uint256 _seededNonce = _chainNonce + 1;
    vm.store(address(_orchestrator), bytes32(_LAST_CHAIN_VOTE_NONCE_SLOT), bytes32(_seededNonce));

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should still apply the allocation delta with the scalar update flag false
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _message.emissionsPerVP, false, true, _message.snapshot)
      ),
      ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastChainVoteNonce unchanged
    assertEq(_orchestrator.lastChainVoteNonce(), _seededNonce);
  }

  function test_RouteWhenAFencedChainNonceExceedsTheChainVoteNonce(
    uint256 _lowNonce,
    uint256 _fenceNonce,
    uint256 _staleNonce,
    uint256 _tokenId,
    uint128 _allocationDelta
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateChain
  {
    // Regression: a pre-emergency `AllocateChain` delivered post-resume gets its delta fenced to zero, but
    // its nonce can exceed `lastChainVoteNonce` (the emergency never bumps that high-water). Without
    // gating the scalar refresh on the fence too, it would write a stale pre-suspension `emissionsPerVP`
    // while the chain is Active.
    _allocationDelta = uint128(bound(_allocationDelta, 1, type(uint128).max));
    _lowNonce = bound(_lowNonce, 1, type(uint256).max - 2);
    _fenceNonce = bound(_fenceNonce, _lowNonce + 1, type(uint256).max);
    // Stale nonce sits strictly above the scalar high-water but at or below the emergency fence.
    _staleNonce = bound(_staleNonce, _lowNonce + 1, _fenceNonce);

    vm.store(address(_orchestrator), bytes32(_LAST_CHAIN_VOTE_NONCE_SLOT), bytes32(_lowNonce));
    vm.store(address(_orchestrator), _lastEmergencyDeallocNonceSlot(_tokenId), bytes32(_fenceNonce));

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_staleNonce, _tokenId, _allocationDelta);

    // it should fence the delta to zero and suppress the scalar refresh
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, uint128(0), _message.emissionsPerVP, false, false, _message.snapshot)
      ),
      ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastChainVoteNonce unchanged
    assertEq(_orchestrator.lastChainVoteNonce(), _lowNonce);
  }

  /*////////////////////////////////////////////////////////////
                        ROUTE ALLOCATE GAUGE
  ////////////////////////////////////////////////////////////*/

  modifier whenTheMessageTypeIsAllocateGauge() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsAllocateGauge(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    // The token gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);

    (bytes memory _payload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_chainNonce, _tokenId, _gauge, '');

    // it should call applyGaugeAllocations with the decoded token fields and the scalar update flag true when the token
    // nonce is newer
    vm.expectCall(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          true,
          true,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      )
    );

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.AllocateGauge
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastTokenIdVoteNonce to the chain nonce when it is newer
    assertEq(_orchestrator.lastTokenIdVoteNonce(_tokenId), _chainNonce);
    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  modifier whenTheChainNonceDoesNotAdvanceTheTokenVoteNonce() {
    _;
  }

  function test_RouteWhenTheChainNonceDoesNotAdvanceTheTokenVoteNonce(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    // Seed lastTokenIdVoteNonce[tokenId] equal to the inbound nonce so the token gate does not advance.
    vm.store(address(_orchestrator), _lastTokenIdVoteNonceSlot(_tokenId), bytes32(_chainNonce));

    (bytes memory _payload,,) = _seedGaugeForward(_chainNonce, _tokenId, _gauge, '');

    // it should not call applyGaugeAllocations
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.applyGaugeAllocations.selector), 0);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastTokenIdVoteNonce unchanged
    assertEq(_orchestrator.lastTokenIdVoteNonce(_tokenId), _chainNonce);
  }

  function test_RouteWhenTheGaugeAllocationRevertsCooldownActive(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);

    (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot) = _fuzzedChainFields(_chainNonce);
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _gauge, allocated: 0, data: ''});
    IVoterCommon.AllocateGaugeMessage memory _gaugeMessage = IVoterCommon.AllocateGaugeMessage({
      tokenId: _tokenId,
      expiry: uint48(block.timestamp),
      emissionsPerVP: _emissionsPerVP,
      tokenSnapshot: _tokenSnapshot,
      allocations: _allocations
    });
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateGauge),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(_gaugeMessage)
    );

    // The leaf rejects the gauge distribution because the cooldown has not elapsed. The nonce is fresh (the
    // chain-vote high-water is unseeded), so the forwarded scalar-update flag is true.
    vm.mockCallRevert(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (_tokenId, _gaugeMessage.expiry, _emissionsPerVP, true, true, _tokenSnapshot, _allocations)
      ),
      abi.encodeWithSelector(ILeafVoter.CooldownActive.selector)
    );

    // it should revert so the transport redelivers the message
    vm.expectRevert(ILeafVoter.CooldownActive.selector);
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  function test_RouteWhenTheGaugeChainNonceAdvancesTheChainVoteNonce(
    uint256 _seededNonce,
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    // A gauge vote whose nonce is strictly above the chain-vote high-water refreshes the global scalar: it
    // bumps `lastChainVoteNonce` and forwards `_refreshEmissionsPerVP: true` with the message's `emissionsPerVP`.
    // Seed the high-water below the inbound nonce (but leave the token gate at zero so the token gate passes).
    _chainNonce = bound(_chainNonce, 2, type(uint256).max);
    _seededNonce = bound(_seededNonce, 1, _chainNonce - 1);
    vm.store(address(_orchestrator), bytes32(_LAST_CHAIN_VOTE_NONCE_SLOT), bytes32(_seededNonce));

    (bytes memory _payload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_chainNonce, _tokenId, _gauge, '');

    // it should forward applyGaugeAllocations with the scalar update flag true and the message emissions per vp
    vm.expectCall(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          true,
          true,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      )
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastChainVoteNonce to the chain nonce
    assertEq(_orchestrator.lastChainVoteNonce(), _chainNonce);
  }

  function test_RouteWhenTheGaugeChainNonceDoesNotAdvanceTheChainVoteNonce(
    uint256 _seededNonce,
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    // A token-fresh gauge vote whose nonce is at or below the chain-vote high-water must not overwrite the
    // global scalar: it forwards `_refreshEmissionsPerVP: false` and leaves `lastChainVoteNonce` unchanged. Keep the
    // token gate at zero so the message is not dropped by the token gate, isolating the scalar gate.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    _seededNonce = bound(_seededNonce, _chainNonce, type(uint256).max);
    vm.store(address(_orchestrator), bytes32(_LAST_CHAIN_VOTE_NONCE_SLOT), bytes32(_seededNonce));

    (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot) = _fuzzedChainFields(_chainNonce);
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _gauge, allocated: 0, data: ''});
    IVoterCommon.AllocateGaugeMessage memory _gaugeMessage = IVoterCommon.AllocateGaugeMessage({
      tokenId: _tokenId,
      expiry: uint48(block.timestamp),
      emissionsPerVP: _emissionsPerVP,
      tokenSnapshot: _tokenSnapshot,
      allocations: _allocations
    });
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateGauge),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(_gaugeMessage)
    );

    ILeafVoter.CheckpointData memory _callParams = ILeafVoter.CheckpointData({gauge: _gauge, allocated: 0, data: ''});
    ILeafVoter.CheckpointData[] memory _callParamsList = new ILeafVoter.CheckpointData[](1);
    _callParamsList[0] = _callParams;

    // it should forward applyGaugeAllocations with the scalar update flag false
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (_tokenId, _gaugeMessage.expiry, _emissionsPerVP, false, true, _tokenSnapshot, _allocations)
      ),
      abi.encode(_callParamsList)
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastChainVoteNonce unchanged
    assertEq(_orchestrator.lastChainVoteNonce(), _seededNonce);
  }

  function test_RouteWhenAGaugeIsShapeStaleAgainstAPriorAllocateChain(
    uint256 _chainNonce,
    uint256 _gaugeNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    address _gauge
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // The per-token shape high-water (`lastShapeNonce`) is advanced by BOTH message types. A chain
    // allocation at a HIGH nonce lands first and raises it; a later gauge vote at a LOWER nonce is
    // token-fresh (chain messages never touch `lastTokenIdVoteNonce`) but shape-stale, so it must be
    // forwarded with `_refreshShape: false` — the leaf then books at the current shape instead of the
    // gauge's stale one. This is the exact sequence that would otherwise resurrect a downgraded token's
    // permanent shape.
    _chainNonce = bound(_chainNonce, 2, type(uint256).max);
    _gaugeNonce = bound(_gaugeNonce, 1, _chainNonce - 1);

    // 1) Chain allocation at the HIGH nonce: raises the shape high-water, forwards `_refreshShape: true`.
    (bytes memory _chainPayload, IVoterCommon.AllocateChainMessage memory _chainMessage) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _chainMessage.emissionsPerVP, true, true, _chainMessage.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _chainPayload);
    // it should leave the shape high water at the chain nonce
    assertEq(_orchestrator.lastShapeNonce(_tokenId), _chainNonce);

    // 2) Gauge vote at the LOWER nonce: token-fresh but shape-stale.
    (bytes memory _gaugePayload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_gaugeNonce, _tokenId, _gauge, '');

    // it should forward applyGaugeAllocations with the shape refresh flag false
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          false,
          false,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      ),
      abi.encode(new ILeafVoter.CheckpointData[](0))
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload);
    // it should leave the shape high water at the chain nonce
    assertEq(_orchestrator.lastShapeNonce(_tokenId), _chainNonce);
  }

  function test_RouteWhenAGaugeShareTheChainVoteHighWaterWithAllocateChain(
    uint256 _chainNonce,
    uint256 _gaugeNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    address _gauge
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // AllocateChain and AllocateGauge share one `lastChainVoteNonce` high-water on the same monotonic nonce
    // sequence. A gauge vote at a HIGH nonce lands first, refreshing the scalar and setting the high-water; a
    // later chain allocation at a LOWER nonce is then scalar-stale and must forward `_refreshEmissionsPerVP: false`.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max - 1);
    _gaugeNonce = bound(_gaugeNonce, _chainNonce + 1, type(uint256).max);

    // 1) Route the gauge vote at the HIGH nonce; it advances the shared high-water and forwards true.
    (bytes memory _gaugePayload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_gaugeNonce, _tokenId, _gauge, '');
    vm.expectCall(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          true,
          true,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      )
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload);

    // Sanity: the gauge vote set the shared high-water.
    assertEq(_orchestrator.lastChainVoteNonce(), _gaugeNonce);

    // 2) Route a later chain allocation at the LOWER nonce; it is scalar-stale against the gauge high-water.
    (bytes memory _chainPayload, IVoterCommon.AllocateChainMessage memory _chainMessage) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should forward applyChainAllocation with the scalar update flag false
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _chainMessage.emissionsPerVP, false, false, _chainMessage.snapshot)
      ),
      ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _chainPayload);

    // it should leave the shared chain vote high-water at the gauge nonce
    assertEq(_orchestrator.lastChainVoteNonce(), _gaugeNonce);
  }

  function test_RouteWhenAnAllocateGaugeMessageCarriesValue(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge,
    uint256 _value
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsAllocateGauge
  {
    // Deallocation funding moved out of the LeafVoter: inbound value stays in the orchestrator (the pool a
    // root-triggered return draws from) and `applyGaugeAllocations` is called with no value at all.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    _value = bound(_value, 1, type(uint128).max);
    vm.deal(_ADAPTER, _value);

    (bytes memory _payload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_chainNonce, _tokenId, _gauge, '');

    // it should call applyGaugeAllocations with no value
    vm.expectCall(
      _LEAF_VOTER,
      0,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          true,
          true,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      )
    );

    uint256 _balanceBefore = address(_orchestrator).balance;

    _orchestrator.route{value: _value}(_ROOT_CHAIN_ID, _payload);

    // it should keep the inbound value in the orchestrator
    assertEq(address(_orchestrator).balance, _balanceBefore + _value);
    assertEq(_LEAF_VOTER.balance, 0);
  }

  /*////////////////////////////////////////////////////////////
                        ROUTE OTHER TYPES
  ////////////////////////////////////////////////////////////*/

  modifier whenTheMessageTypeIsClaimRewards() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsClaimRewards(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _recipient,
    address _feeVotingRewardsManager,
    uint256 _feeMaxCheckpoints,
    address _incentiveVotingRewardsManager,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsClaimRewards
  {
    // An expiry at the current timestamp is still valid; only a strictly past one expires.
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _feeVotingRewardsManager, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _incentiveVotingRewardsManager,
      programId: _programId,
      maxCheckpoints: _incentiveMaxCheckpoints
    });

    bytes memory _body = abi.encode(_tokenId, _expiry, _recipient, _feeClaims, _incentiveClaims);
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.ClaimRewards), _chainNonce, uint48(block.timestamp), _body
    );

    // it should call claimRewards on the leaf voter with the decoded reward claims
    _mockAndExpect(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.claimRewards, (_tokenId, _recipient, _feeClaims, _incentiveClaims)), ''
    );

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.ClaimRewards
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheClaimRewardsExpiryEqualsTheCurrentTimestamp(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _recipient,
    address _feeVotingRewardsManager,
    uint256 _feeMaxCheckpoints,
    address _incentiveVotingRewardsManager,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsClaimRewards
  {
    // Pin the boundary deterministically so a < to <= change in the expiry check fails this test.
    uint48 _expiry = uint48(block.timestamp);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _feeVotingRewardsManager, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _incentiveVotingRewardsManager,
      programId: _programId,
      maxCheckpoints: _incentiveMaxCheckpoints
    });

    bytes memory _body = abi.encode(_tokenId, _expiry, _recipient, _feeClaims, _incentiveClaims);
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.ClaimRewards), _chainNonce, uint48(block.timestamp), _body
    );

    // it should call claimRewards on the leaf voter with the decoded reward claims
    _mockAndExpect(
      _LEAF_VOTER, abi.encodeCall(ILeafVoter.claimRewards, (_tokenId, _recipient, _feeClaims, _incentiveClaims)), ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheClaimRewardsMessageIsPastItsExpiry(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _recipient
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsClaimRewards
  {
    // Move past the stamped expiry so the claim arrives stale.
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max - 1));
    vm.warp(uint256(_expiry) + 1);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);

    bytes memory _body = abi.encode(_tokenId, _expiry, _recipient, _feeClaims, _incentiveClaims);
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.ClaimRewards), _chainNonce, uint48(block.timestamp), _body
    );

    // it should not call claimRewards
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.claimRewards.selector), 0);

    // it should emit ExpiredMessageDropped
    _expectEmit(address(_orchestrator));
    emit ILeafMessageOrchestrator.ExpiredMessageDropped(IMessageOrchestrator.MessageType.ClaimRewards, _tokenId);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  modifier whenTheMessageTypeIsSetOperator() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsSetOperator(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _operator
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsSetOperator
  {
    // The operator gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    // An expiry at the current timestamp is still valid; only a strictly past one expires.
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.SetOperator),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.OperatorMessage({tokenId: _tokenId, expiry: _expiry, operator: _operator}))
    );

    // it should call setOperator with the token id and operator when the operator nonce is newer
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.setOperator, (_tokenId, _operator)), '');

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(_ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.SetOperator);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastOperatorNonce to the chain nonce when it is newer
    assertEq(_orchestrator.lastOperatorNonce(_tokenId), _chainNonce);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheSetOperatorExpiryEqualsTheCurrentTimestamp(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _operator
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsSetOperator
  {
    // The operator gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    // Pin the boundary deterministically so a < to <= change in the expiry check fails this test.
    uint48 _expiry = uint48(block.timestamp);

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.SetOperator),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.OperatorMessage({tokenId: _tokenId, expiry: _expiry, operator: _operator}))
    );

    // it should call setOperator with the token id and operator
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.setOperator, (_tokenId, _operator)), '');

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheSetOperatorMessageIsPastItsExpiry(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _operator
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsSetOperator
  {
    // The operator gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    // Move past the stamped expiry so the assignment arrives expired.
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max - 1));
    vm.warp(uint256(_expiry) + 1);

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.SetOperator),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.OperatorMessage({tokenId: _tokenId, expiry: _expiry, operator: _operator}))
    );

    // it should not call setOperator
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.setOperator.selector), 0);

    // it should emit ExpiredMessageDropped
    _expectEmit(address(_orchestrator));
    emit ILeafMessageOrchestrator.ExpiredMessageDropped(IMessageOrchestrator.MessageType.SetOperator, _tokenId);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastOperatorNonce to the chain nonce
    assertEq(_orchestrator.lastOperatorNonce(_tokenId), _chainNonce);
  }

  function test_RouteWhenTheChainNonceDoesNotAdvanceTheOperatorNonce(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _operator
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsSetOperator
  {
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max));
    // Seed lastOperatorNonce[tokenId] equal to the inbound nonce so the operator gate does not advance.
    vm.store(address(_orchestrator), _lastOperatorNonceSlot(_tokenId), bytes32(_chainNonce));

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.SetOperator),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.OperatorMessage({tokenId: _tokenId, expiry: _expiry, operator: _operator}))
    );

    // it should not call setOperator
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.setOperator.selector), 0);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastOperatorNonce unchanged
    assertEq(_orchestrator.lastOperatorNonce(_tokenId), _chainNonce);
  }

  function test_RouteWhenTheSetOperatorMessageIsStaleAndPastItsExpiry(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _expiry,
    address _operator
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsSetOperator
  {
    // Move past the stamped expiry so the assignment arrives both stale and expired.
    _expiry = uint48(bound(_expiry, block.timestamp, type(uint48).max - 1));
    vm.warp(uint256(_expiry) + 1);
    // Seed lastOperatorNonce[tokenId] equal to the inbound nonce so the stale gate drops the message first.
    vm.store(address(_orchestrator), _lastOperatorNonceSlot(_tokenId), bytes32(_chainNonce));

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.SetOperator),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.OperatorMessage({tokenId: _tokenId, expiry: _expiry, operator: _operator}))
    );

    // it should not call setOperator
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.setOperator.selector), 0);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastOperatorNonce unchanged
    assertEq(_orchestrator.lastOperatorNonce(_tokenId), _chainNonce);
  }

  function test_RouteWhenTheMessageTypeIsReduceCooldown(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _reduction
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // No per-tokenId nonce gate on reductions: the global replay gate applies each exactly once, so the
    // handler always forwards to the leaf regardless of the nonce value.
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.ReduceCooldown),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction}))
    );

    // it should call applyCooldownReduction with the decoded token id and reduction
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyCooldownReduction, (_tokenId, _reduction)), '');

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.ReduceCooldown
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheReduceCooldownNonceIsReplayed(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint48 _reduction
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // The global replay gate consumes the nonce on first delivery, so re-delivering the same nonce reverts.
    vm.store(address(_orchestrator), _noncesUsedSlot(_chainNonce), bytes32(uint256(1)));

    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.ReduceCooldown),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(IVoterCommon.ReduceCooldownMessage({tokenId: _tokenId, reduction: _reduction}))
    );

    // it should not call applyCooldownReduction
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.applyCooldownReduction.selector), 0);

    // it should revert with NonceAlreadyUsed
    vm.expectRevert(IMessageOrchestrator.NonceAlreadyUsed.selector);
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  /*////////////////////////////////////////////////////////////
                    ROUTE EMERGENCY DEALLOCATE
  ////////////////////////////////////////////////////////////*/

  modifier whenTheMessageTypeIsEmergencyDeallocate() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsEmergencyDeallocate(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // The emergency has no ordering gate: it subtracts a fixed amount that commutes with the additive
    // chain deltas, so it always forwards. With the token gate at zero, any nonce >= 1 also advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);

    bytes memory _payload = _emergencyDeallocatePayload(_chainNonce, _tokenId, _amount);

    // it should call applyEmergencyDeallocation with the decoded token id and amount
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.EmergencyDeallocate
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastTokenIdVoteNonce to the chain nonce
    assertEq(_orchestrator.lastTokenIdVoteNonce(_tokenId), _chainNonce);
    // it should set lastEmergencyDeallocNonce to the chain nonce
    assertEq(_orchestrator.lastEmergencyDeallocNonce(_tokenId), _chainNonce);
    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenTheEmergencyDeallocateNonceIsReplayed(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // The global replay gate consumes the nonce on first delivery, so re-delivering the same nonce reverts.
    vm.store(address(_orchestrator), _noncesUsedSlot(_chainNonce), bytes32(uint256(1)));

    bytes memory _payload = _emergencyDeallocatePayload(_chainNonce, _tokenId, _amount);

    // it should not call applyEmergencyDeallocation
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.applyEmergencyDeallocation.selector), 0);

    // it should revert with NonceAlreadyUsed
    vm.expectRevert(IMessageOrchestrator.NonceAlreadyUsed.selector);
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  function test_RouteWhenTheEmergencyDeallocateNonceDoesNotAdvanceTheTokenVoteNonce(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount,
    uint256 _seededNonce
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // No ordering gate: even a stale emergency (nonce at or below the token's vote high-water) still forwards,
    // because it subtracts a fixed amount that commutes with the additive chain deltas. Its `if (nonce >
    // lastTokenIdVoteNonce)` guard is false, so it leaves the gauge high-water untouched, but it still arms the fence.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max - 1);
    _seededNonce = bound(_seededNonce, _chainNonce, type(uint256).max);
    vm.store(address(_orchestrator), _lastTokenIdVoteNonceSlot(_tokenId), bytes32(_seededNonce));

    bytes memory _payload = _emergencyDeallocatePayload(_chainNonce, _tokenId, _amount);

    // it should still forward applyEmergencyDeallocation with the token id and amount
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');

    // it should still emit MessageReceived
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.EmergencyDeallocate
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should leave lastTokenIdVoteNonce unchanged
    assertEq(_orchestrator.lastTokenIdVoteNonce(_tokenId), _seededNonce);
    // it should set lastEmergencyDeallocNonce to the chain nonce
    assertEq(_orchestrator.lastEmergencyDeallocNonce(_tokenId), _chainNonce);
    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenAPostResumeChainAllocationPrecedesTheEmergency(
    uint256 _emergencyNonce,
    uint256 _chainAllocNonce,
    uint256 _staleNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint128 _amount
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // ADVERSARIAL REORDER (was the budget leak): a post-resume `AllocateChain` lands first at a HIGH nonce and
    // applies a real delta; the emergency then arrives LATE at a LOWER nonce. The emergency no longer has an
    // ordering gate, so it still forwards and arms the emergency fence at its nonce. A later stale `AllocateChain`
    // at or below that fence is then zeroed, so an in-flight pre-reset delta cannot resurrect the drained budget.
    _allocationDelta = uint128(bound(_allocationDelta, 1, type(uint128).max));
    _emergencyNonce = bound(_emergencyNonce, 2, type(uint256).max - 1);
    _chainAllocNonce = bound(_chainAllocNonce, _emergencyNonce + 1, type(uint256).max);
    _staleNonce = bound(_staleNonce, 1, _emergencyNonce - 1);

    // 1) Post-resume chain allocation at the HIGH nonce applies its real delta (no fence armed yet).
    (bytes memory _allocPayload, IVoterCommon.AllocateChainMessage memory _allocMessage) =
      _allocateChainPayload(_chainAllocNonce, _tokenId, _allocationDelta);
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _allocMessage.emissionsPerVP, true, true, _allocMessage.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _allocPayload);

    // 2) The late, lower-nonce emergency still forwards and arms the fence.
    bytes memory _emergencyPayload = _emergencyDeallocatePayload(_emergencyNonce, _tokenId, _amount);
    // it should forward applyEmergencyDeallocation with the token id and amount
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');
    _orchestrator.route(_ROOT_CHAIN_ID, _emergencyPayload);

    // it should set lastEmergencyDeallocNonce to the emergency nonce
    assertEq(_orchestrator.lastEmergencyDeallocNonce(_tokenId), _emergencyNonce);

    // 3) A stale chain allocation at or below the fence is zeroed.
    (bytes memory _stalePayload, IVoterCommon.AllocateChainMessage memory _staleMessage) =
      _allocateChainPayload(_staleNonce, _tokenId, _allocationDelta);
    // it should fence a later lower nonce allocate chain delta to zero
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, uint128(0), _staleMessage.emissionsPerVP, false, false, _staleMessage.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _stalePayload);
  }

  function test_RouteWhenAnEmergencyArrivesAfterAHigherNonceChainAllocation(
    uint256 _emergencyNonce,
    uint256 _chainAllocNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint128 _amount
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // REGRESSION (budget leak): a higher-nonce `AllocateChain` used to advance a chain-allocation high-water that
    // silently dropped a later, lower-nonce emergency. The gate is gone: the emergency reduces the token's budget
    // and must still forward to the leaf voter regardless of the earlier higher-nonce allocation.
    _emergencyNonce = bound(_emergencyNonce, 1, type(uint256).max - 1);
    _chainAllocNonce = bound(_chainAllocNonce, _emergencyNonce + 1, type(uint256).max);

    // Land the higher-nonce chain allocation first.
    (bytes memory _allocPayload, IVoterCommon.AllocateChainMessage memory _allocMessage) =
      _allocateChainPayload(_chainAllocNonce, _tokenId, _allocationDelta);
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _allocMessage.emissionsPerVP, true, true, _allocMessage.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _allocPayload);

    bytes memory _emergencyPayload = _emergencyDeallocatePayload(_emergencyNonce, _tokenId, _amount);

    // it should forward the emergency deallocation to the leaf voter
    vm.mockCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');
    vm.expectCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), 1);

    _orchestrator.route(_ROOT_CHAIN_ID, _emergencyPayload);
  }

  function test_RouteWhenAnOlderEmergencyArrivesAfterANewerEmergency(
    uint256 _highEmergencyNonce,
    uint256 _olderEmergencyNonce,
    uint256 _betweenNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint128 _amount
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // REGRESSION (non-monotonic fence): the emergency fence used to be written unconditionally, so a reordered
    // OLDER (lower-nonce) emergency landing after a NEWER one would LOWER `lastEmergencyDeallocNonce`, un-fencing a
    // stale pre-reset delta the newer emergency already drained. The fence is now monotonic (high-water only), while
    // the subtraction still always runs. Seed the fence high, route the older emergency below it, and prove the
    // fence held: an `AllocateChain` between the two emergencies is still zeroed. The delta is bounded away from
    // zero so the zeroing is observable.
    _allocationDelta = uint128(bound(_allocationDelta, 1, type(uint128).max));
    // Leave room for a strictly-lower older emergency and a between nonce in `(older, high]`.
    _highEmergencyNonce = bound(_highEmergencyNonce, 3, type(uint256).max);
    _olderEmergencyNonce = bound(_olderEmergencyNonce, 1, _highEmergencyNonce - 2);
    _betweenNonce = bound(_betweenNonce, _olderEmergencyNonce + 1, _highEmergencyNonce);

    // Seed the fence to the newer emergency's HIGH nonce (as if it had already drained the budget).
    vm.store(address(_orchestrator), _lastEmergencyDeallocNonceSlot(_tokenId), bytes32(_highEmergencyNonce));

    // 1) The reordered older, lower-nonce emergency still subtracts on the leaf.
    bytes memory _emergencyPayload = _emergencyDeallocatePayload(_olderEmergencyNonce, _tokenId, _amount);
    // it should still forward applyEmergencyDeallocation with the token id and amount
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');
    _orchestrator.route(_ROOT_CHAIN_ID, _emergencyPayload);

    // it should leave lastEmergencyDeallocNonce at the higher emergency nonce
    assertEq(_orchestrator.lastEmergencyDeallocNonce(_tokenId), _highEmergencyNonce);

    // 2) An AllocateChain between the two emergencies is at or below the (unlowered) fence and is zeroed. Without
    // the monotonic guard the fence would have dropped to the older nonce and this delta (> older nonce) would pass
    // through non-zero.
    (bytes memory _allocPayload, IVoterCommon.AllocateChainMessage memory _allocMessage) =
      _allocateChainPayload(_betweenNonce, _tokenId, _allocationDelta);
    // it should keep fencing an allocate chain delta between the two emergencies to zero (and suppress its
    // stale scalar)
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, uint128(0), _allocMessage.emissionsPerVP, false, false, _allocMessage.snapshot)
      ),
      ''
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _allocPayload);
  }

  function test_RouteWhenAnEmergencyPrecedesAStaleGaugeVote(
    uint256 _emergencyNonce,
    uint256 _gaugeNonce,
    uint256 _tokenId,
    uint128 _amount,
    address _gauge
  )
    external
    givenTheCallerIsTheAdapter
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    whenTheMessageTypeIsEmergencyDeallocate
  {
    // The emergency bumps the token's gauge high-water (`lastTokenIdVoteNonce`), so a stale gauge vote that was
    // in flight at or below the emergency nonce is dropped by the token gate and cannot re-distribute the gauges
    // the reset just cleared.
    _gaugeNonce = bound(_gaugeNonce, 1, type(uint256).max - 1);
    _emergencyNonce = bound(_emergencyNonce, _gaugeNonce + 1, type(uint256).max);

    // 1) The emergency forwards and advances the token high-water to its nonce.
    bytes memory _emergencyPayload = _emergencyDeallocatePayload(_emergencyNonce, _tokenId, _amount);
    // it should forward the emergency deallocation to the leaf voter
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');
    _orchestrator.route(_ROOT_CHAIN_ID, _emergencyPayload);

    // it should bump lastTokenIdVoteNonce to the emergency nonce
    assertEq(_orchestrator.lastTokenIdVoteNonce(_tokenId), _emergencyNonce);

    // 2) A later, lower-nonce gauge vote is dropped by the token gate.
    (bytes memory _gaugePayload,,) = _seedGaugeForward(_gaugeNonce, _tokenId, _gauge, '');
    // it should drop the later lower nonce gauge vote
    vm.expectCall(_LEAF_VOTER, abi.encodeWithSelector(ILeafVoter.applyGaugeAllocations.selector), 0);
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload);
  }

  /*////////////////////////////////////////////////////////////
                ALLOCATE CHAIN EMERGENCY FENCE
  ////////////////////////////////////////////////////////////*/

  function test_RouteWhenAnAllocateChainDeltaIsFencedByAPriorEmergencyDeallocation(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint256 _fenceNonce
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // FENCE: an AllocateChain delta dispatched at or before the token's last emergency deallocation is
    // stale pre-reset budget and must not resurrect the cleared position, so the shipped delta is zeroed.
    // Bound the delta away from zero so the zeroing is actually observable (a zero draw would equal the
    // input and prove nothing).
    _allocationDelta = uint128(bound(_allocationDelta, 1, type(uint128).max));
    _chainNonce = bound(_chainNonce, 1, type(uint256).max - 1);
    _fenceNonce = bound(_fenceNonce, _chainNonce, type(uint256).max);
    vm.store(address(_orchestrator), _lastEmergencyDeallocNonceSlot(_tokenId), bytes32(_fenceNonce));

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should apply a zero allocation delta and suppress the scalar refresh (the fenced message carries
    // pre-emergency state, so its scalar is stale even though its nonce exceeds the high-water)
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, uint128(0), _message.emissionsPerVP, false, false, _message.snapshot)
      ),
      ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenAnAllocateChainNonceIsAboveTheEmergencyFence(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta,
    uint256 _fenceNonce
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // A fresh AllocateChain nonce strictly above the fence carries a legitimate post-reset delta and must
    // pass the real amount through unchanged.
    _chainNonce = bound(_chainNonce, 2, type(uint256).max);
    _fenceNonce = bound(_fenceNonce, 1, _chainNonce - 1);
    vm.store(address(_orchestrator), _lastEmergencyDeallocNonceSlot(_tokenId), bytes32(_fenceNonce));

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should apply the real allocation delta unchanged
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _message.emissionsPerVP, true, true, _message.snapshot)
      ),
      ''
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  function test_RouteWhenAGaugeFollowsAnEmergencyDeallocation(
    uint256 _emergencyNonce,
    uint256 _tokenId,
    uint128 _amount,
    address _gauge
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // The emergency bumps the token and emergency high-waters but NOT `lastShapeNonce` (it carries no
    // shape). A post-emergency gauge must therefore still be shape-fresh and refresh the shape.
    _emergencyNonce = bound(_emergencyNonce, 1, type(uint256).max - 1);
    uint256 _gaugeNonce = _emergencyNonce + 1;

    // 1) Emergency at `_emergencyNonce`.
    _mockAndExpect(_LEAF_VOTER, abi.encodeCall(ILeafVoter.applyEmergencyDeallocation, (_tokenId, _amount)), '');
    _orchestrator.route(_ROOT_CHAIN_ID, _emergencyDeallocatePayload(_emergencyNonce, _tokenId, _amount));

    // it should not advance the shape high water on the emergency
    assertEq(_orchestrator.lastShapeNonce(_tokenId), 0);

    // 2) Post-emergency gauge at a higher nonce: token-fresh and shape-fresh.
    (bytes memory _gaugePayload,, IVoterCommon.AllocateGaugeMessage memory _gaugeMessage) =
      _seedGaugeForward(_gaugeNonce, _tokenId, _gauge, '');

    // it should refresh the shape from the post emergency gauge
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (
          _tokenId,
          _gaugeMessage.expiry,
          _gaugeMessage.emissionsPerVP,
          true,
          true,
          _gaugeMessage.tokenSnapshot,
          _gaugeMessage.allocations
        )
      ),
      abi.encode(new ILeafVoter.CheckpointData[](0))
    );
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload);
    assertEq(_orchestrator.lastShapeNonce(_tokenId), _gaugeNonce);
  }

  function test_RouteWhenTheGaugeHandlerRevertsAfterBumpingTheShapeHighWater(
    uint256 _chainNonce,
    uint256 _tokenId,
    address _gauge
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // The orchestrator bumps `lastShapeNonce` before calling the voter. `route` is one atomic frame, so
    // if the voter reverts the bump (and `noncesUsed`) roll back — the high-water only advances on a
    // successful application, keeping it consistent with the replay gate on redelivery.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);

    (uint256 _emissionsPerVP, IVoterCommon.TokenSnapshot memory _tokenSnapshot) = _fuzzedChainFields(_chainNonce);
    IVoterCommon.GaugeAllocation[] memory _allocations = new IVoterCommon.GaugeAllocation[](1);
    _allocations[0] = IVoterCommon.GaugeAllocation({gauge: _gauge, allocated: 0, data: ''});
    IVoterCommon.AllocateGaugeMessage memory _gaugeMessage = IVoterCommon.AllocateGaugeMessage({
      tokenId: _tokenId,
      expiry: uint48(block.timestamp),
      emissionsPerVP: _emissionsPerVP,
      tokenSnapshot: _tokenSnapshot,
      allocations: _allocations
    });
    bytes memory _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateGauge),
      _chainNonce,
      uint48(block.timestamp),
      abi.encode(_gaugeMessage)
    );

    // Voter reverts (cooldown not elapsed). Nonce is fresh, so the forwarded flags are true.
    vm.mockCallRevert(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyGaugeAllocations,
        (_tokenId, _gaugeMessage.expiry, _emissionsPerVP, true, true, _tokenSnapshot, _allocations)
      ),
      abi.encodeWithSelector(ILeafVoter.CooldownActive.selector)
    );

    vm.expectRevert(ILeafVoter.CooldownActive.selector);
    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should roll back the shape high water with the whole message
    assertEq(_orchestrator.lastShapeNonce(_tokenId), 0);
    assertEq(_orchestrator.noncesUsed(_chainNonce), false);
  }

  function test_RouteWhenTheMessageTypeIsRedeem(
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Redeem), _chainNonce, uint48(block.timestamp), _body);

    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);
  }

  function test_RouteWhenTheChainStatusIsSuspended(
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _allocationDelta
  ) external givenTheCallerIsTheAdapter givenThePayloadContainsTheHeader givenTheMessageTypeByteIsInRange {
    // The chain gate defaults to zero, so any nonce >= 1 advances it.
    _chainNonce = bound(_chainNonce, 1, type(uint256).max);
    // Inbound root messages have no suspension gate: the pipeline keeps processing while the chain is Suspended so the
    // leaf mirror self-repairs (the LeafVoter forces the applied rate to zero for the suspended window). The zero-count
    // expectCall below pins the no-read behavior: a reintroduced gate would consume this mock and fail the test.
    vm.mockCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.chainStatus, ()), abi.encode(IVoterCommon.ChainStatus.Suspended));

    (bytes memory _payload, IVoterCommon.AllocateChainMessage memory _message) =
      _allocateChainPayload(_chainNonce, _tokenId, _allocationDelta);

    // it should not read the chain status
    vm.expectCall(_LEAF_VOTER, abi.encodeCall(ILeafVoter.chainStatus, ()), 0);
    // it should still process the message without reverting: apply the chain allocation with the decoded fields
    _mockAndExpect(
      _LEAF_VOTER,
      abi.encodeCall(
        ILeafVoter.applyChainAllocation,
        (_tokenId, _allocationDelta, _message.emissionsPerVP, true, true, _message.snapshot)
      ),
      ''
    );

    // it should emit MessageReceived with the origin chain id chain nonce and message type
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(
      _ROOT_CHAIN_ID, _chainNonce, IMessageOrchestrator.MessageType.AllocateChain
    );

    _orchestrator.route(_ROOT_CHAIN_ID, _payload);

    // it should set lastChainVoteNonce to the chain nonce
    assertEq(_orchestrator.lastChainVoteNonce(), _chainNonce);
    // it should mark the chain nonce as used
    assertEq(_orchestrator.noncesUsed(_chainNonce), true);
  }

  /*////////////////////////////////////////////////////////////
                            SET ADAPTER
  ////////////////////////////////////////////////////////////*/

  function test_SetAdapterWhenTheCallerIsNotAdapterAuthority(address _caller, IMessageAdapter _adapter) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _ADAPTER_AUTHORITY);

    // it should revert with CallerNotAdapterAuthority
    vm.expectRevert(IMessageOrchestrator.CallerNotAdapterAuthority.selector);

    vm.prank(_caller);
    _orchestrator.setAdapter(_adapter);
  }

  modifier givenTheCallerIsAdapterAuthority() {
    vm.startPrank(_ADAPTER_AUTHORITY);
    _;
    vm.stopPrank();
  }

  function test_SetAdapterWhenTheAdapterIsTheZeroAddress() external givenTheCallerIsAdapterAuthority {
    // it should revert with InvalidAdapter
    vm.expectRevert(IMessageOrchestrator.InvalidAdapter.selector);

    _orchestrator.setAdapter(IMessageAdapter(address(0)));
  }

  modifier givenTheAdapterIsNotTheZeroAddress(IMessageAdapter _adapter) {
    _assumeFuzzable(address(_adapter));
    _;
  }

  function test_SetAdapterWhenTheAdapterChainIdDoesNotMatchTheRootChainId(
    IMessageAdapter _adapter,
    uint256 _wrongChainId
  ) external givenTheCallerIsAdapterAuthority givenTheAdapterIsNotTheZeroAddress(_adapter) {
    // Any remote chain id other than root's must be rejected.
    vm.assume(_wrongChainId != _ROOT_CHAIN_ID);
    vm.mockCall(address(_adapter), abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_wrongChainId));

    // it should revert with AdapterChainIdMismatch
    vm.expectRevert(ILeafMessageOrchestrator.AdapterChainIdMismatch.selector);

    _orchestrator.setAdapter(_adapter);
  }

  function test_SetAdapterWhenTheAdapterChainIdMatchesTheRootChainId(IMessageAdapter _adapter)
    external
    givenTheCallerIsAdapterAuthority
    givenTheAdapterIsNotTheZeroAddress(_adapter)
  {
    vm.mockCall(address(_adapter), abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));

    // it should emit AdapterUpdated with _adapter
    _expectEmit(address(_orchestrator));
    emit ILeafMessageOrchestrator.AdapterUpdated(_adapter);

    _orchestrator.setAdapter(_adapter);

    // it should set the adapter
    assertEq(address(_orchestrator.adapter()), address(_adapter));
  }

  /*////////////////////////////////////////////////////////////
                          QUOTE DISPATCH
  ////////////////////////////////////////////////////////////*/

  function test_QuoteDispatchWhenQuotingWithNoAdapterRegistered(
    uint8 _msgTypeByte,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient
  ) external {
    _msgTypeByte = uint8(bound(_msgTypeByte, 1, uint8(type(IMessageOrchestrator.MessageType).max)));

    // it should revert with AdapterNotRegistered
    vm.expectRevert(IMessageOrchestrator.AdapterNotRegistered.selector);

    _orchestrator.quoteDispatch(IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient);
  }

  modifier givenAnAdapterIsRegisteredForTheQuote() {
    vm.store(address(_orchestrator), bytes32(_ADAPTER_SLOT), bytes32(uint256(uint160(_ADAPTER))));
    _;
  }

  function test_QuoteDispatchGivenAnAdapterIsRegisteredForTheQuote(
    uint8 _msgTypeByte,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _nonceOut,
    uint256 _fee
  ) external givenAnAdapterIsRegisteredForTheQuote {
    // The quote must price the WRAPPED envelope (39-byte header + payload) the matching dispatch would stamp with
    // the next outbound nonce and dispatchedAt, not the bare payload: the header bytes count toward the fee.
    _msgTypeByte = uint8(bound(_msgTypeByte, 1, uint8(type(IMessageOrchestrator.MessageType).max)));
    _nonceOut = bound(_nonceOut, 0, type(uint256).max - 1);
    vm.store(address(_orchestrator), bytes32(_NONCE_OUT_SLOT), bytes32(_nonceOut));
    // The fuzz spans every message type, and a `Deallocate` prices against the configured budget instead of the
    // supplied one. Seeding them equal keeps all types on one expected quote; the divergence tests below pin which
    // budget each type actually uses.
    _mockDeallocationGasLimit(_gasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType(_msgTypeByte), _nonceOut + 1, _payload);

    // it should return the adapter quote for the wrapped envelope with the next outbound nonce
    _mockAndExpect(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _gasLimit, _refundRecipient)), abi.encode(_fee)
    );

    assertEq(
      _orchestrator.quoteDispatch(
        IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient
      ),
      _fee
    );
    // The quote is a pure read: it must not consume the nonce it priced.
    assertEq(_orchestrator.nonceOut(), _nonceOut);
  }

  function test_QuoteDispatchWhenTheOutboundNonceDiffers(
    uint8 _msgTypeByte,
    bytes calldata _payload,
    uint256 _gasLimit,
    address _refundRecipient,
    uint256 _lowNonce,
    uint256 _highNonce,
    uint256 _fee
  ) external givenAnAdapterIsRegisteredForTheQuote {
    // The header is fixed-width, so the nonce's VALUE cannot move the quote: an interleaved dispatch that bumps
    // `nonceOut` between quote and send cannot invalidate the figure. Both envelopes are mocked by exact calldata,
    // so a variable-width header would miss the mock instead of silently returning the same fee.
    _msgTypeByte = uint8(bound(_msgTypeByte, 1, uint8(type(IMessageOrchestrator.MessageType).max)));
    _lowNonce = bound(_lowNonce, 0, type(uint256).max - 2);
    _highNonce = bound(_highNonce, _lowNonce + 1, type(uint256).max - 1);
    // Seeded equal to the supplied budget so the fuzz can span `Deallocate` too, which prices against config.
    _mockDeallocationGasLimit(_gasLimit);

    bytes memory _lowMessage = _wrap(IMessageOrchestrator.MessageType(_msgTypeByte), _lowNonce + 1, _payload);
    bytes memory _highMessage = _wrap(IMessageOrchestrator.MessageType(_msgTypeByte), _highNonce + 1, _payload);
    // it should return the same quote for the same envelope length
    assertEq(_lowMessage.length, _highMessage.length);

    _mockAndExpect(
      _ADAPTER,
      abi.encodeCall(IMessageAdapter.quoteMessage, (_lowMessage, _gasLimit, _refundRecipient)),
      abi.encode(_fee)
    );
    _mockAndExpect(
      _ADAPTER,
      abi.encodeCall(IMessageAdapter.quoteMessage, (_highMessage, _gasLimit, _refundRecipient)),
      abi.encode(_fee)
    );

    vm.store(address(_orchestrator), bytes32(_NONCE_OUT_SLOT), bytes32(_lowNonce));
    uint256 _lowQuote = _orchestrator.quoteDispatch(
      IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient
    );

    vm.store(address(_orchestrator), bytes32(_NONCE_OUT_SLOT), bytes32(_highNonce));
    uint256 _highQuote = _orchestrator.quoteDispatch(
      IMessageOrchestrator.MessageType(_msgTypeByte), _payload, _gasLimit, _refundRecipient
    );

    assertEq(_lowQuote, _highQuote);
    assertEq(_lowQuote, _fee);
  }

  function test_QuoteDispatchWhenQuotingADeallocationWithAGasLimitOtherThanTheConfiguredOne(
    bytes calldata _payload,
    uint256 _configuredGasLimit,
    uint256 _suppliedGasLimit,
    address _refundRecipient,
    uint256 _fee
  ) external givenAnAdapterIsRegisteredForTheQuote {
    // The quote must be taken against the same budget the send stamps, so a `Deallocate` prices against config and
    // discards the caller's argument. The mock matches by EXACT calldata, so pricing against `_suppliedGasLimit`
    // misses it and fails here rather than silently agreeing.
    vm.assume(_configuredGasLimit != _suppliedGasLimit);
    _mockDeallocationGasLimit(_configuredGasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Deallocate, _orchestrator.nonceOut() + 1, _payload);

    // it should price against the configured deallocation gas limit
    _mockAndExpect(
      _ADAPTER,
      abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _configuredGasLimit, _refundRecipient)),
      abi.encode(_fee)
    );

    // it should never price against the supplied gas limit
    vm.expectCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _suppliedGasLimit, _refundRecipient)), 0
    );

    assertEq(
      _orchestrator.quoteDispatch(
        IMessageOrchestrator.MessageType.Deallocate, _payload, _suppliedGasLimit, _refundRecipient
      ),
      _fee
    );
  }

  function test_QuoteDispatchWhenQuotingARedeemWhileADeallocationBudgetIsConfigured(
    bytes calldata _payload,
    uint256 _configuredGasLimit,
    uint256 _suppliedGasLimit,
    address _refundRecipient,
    uint256 _fee
  ) external givenAnAdapterIsRegisteredForTheQuote {
    // The configured deallocation budget must not leak into a user-initiated `Redeem` quote.
    vm.assume(_configuredGasLimit != _suppliedGasLimit);
    _mockDeallocationGasLimit(_configuredGasLimit);

    bytes memory _message = _wrap(IMessageOrchestrator.MessageType.Redeem, _orchestrator.nonceOut() + 1, _payload);

    // it should price against the supplied gas limit
    _mockAndExpect(
      _ADAPTER,
      abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _suppliedGasLimit, _refundRecipient)),
      abi.encode(_fee)
    );

    vm.expectCall(
      _ADAPTER, abi.encodeCall(IMessageAdapter.quoteMessage, (_message, _configuredGasLimit, _refundRecipient)), 0
    );

    assertEq(
      _orchestrator.quoteDispatch(
        IMessageOrchestrator.MessageType.Redeem, _payload, _suppliedGasLimit, _refundRecipient
      ),
      _fee
    );
  }

  /*////////////////////////////////////////////////////////////
                  SET DEALLOCATION GAS LIMIT
  ////////////////////////////////////////////////////////////*/

  function test_SetDeallocationGasLimitWhenTheCallerIsNotTheGasConfigurer(address _caller, uint256 _gasLimit) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _GAS_CONFIGURER);

    // it should revert with CallerNotGasConfigurer
    vm.expectRevert(ILeafMessageOrchestrator.CallerNotGasConfigurer.selector);

    vm.prank(_caller);
    _orchestrator.setDeallocationGasLimit(_gasLimit);
  }

  function test_SetDeallocationGasLimitWhenTheGasLimitIsZero() external {
    // it should revert with ZeroGasLimit
    vm.expectRevert(ILeafMessageOrchestrator.ZeroGasLimit.selector);

    vm.prank(_GAS_CONFIGURER);
    _orchestrator.setDeallocationGasLimit(0);
  }

  function test_SetDeallocationGasLimitWhenTheCallerIsTheGasConfigurer(uint256 _gasLimit) external {
    // The authority is the `GAS_CONFIGURER_ROLE` holder on the LeafVoter, which `setUp` mocks.
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    // it should emit DeallocationGasLimitSet
    _expectEmit(address(_orchestrator));
    emit ILeafMessageOrchestrator.DeallocationGasLimitSet(_gasLimit);

    vm.prank(_GAS_CONFIGURER);
    _orchestrator.setDeallocationGasLimit(_gasLimit);

    // it should set deallocationGasLimit
    assertEq(_orchestrator.deallocationGasLimit(), _gasLimit);
  }

  /*////////////////////////////////////////////////////////////
                          WITHDRAW NATIVE
  ////////////////////////////////////////////////////////////*/

  function test_WithdrawNativeWhenTheCallerIsNotTheNativeWithdrawer(
    address _caller,
    uint256 _amount,
    address _destination
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _NATIVE_WITHDRAWER);

    // it should revert with CallerNotNativeWithdrawer
    vm.expectRevert(ILeafMessageOrchestrator.CallerNotNativeWithdrawer.selector);

    vm.prank(_caller);
    _orchestrator.withdrawNative(_amount, _destination);
  }

  modifier givenTheCallerIsTheNativeWithdrawer() {
    vm.startPrank(_NATIVE_WITHDRAWER);
    _;
    vm.stopPrank();
  }

  function test_WithdrawNativeWhenTheDestinationIsTheZeroAddress(uint256 _amount)
    external
    givenTheCallerIsTheNativeWithdrawer
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IMessageOrchestrator.ZeroAddress.selector);

    _orchestrator.withdrawNative(_amount, address(0));
  }

  function test_WithdrawNativeWhenTheDestinationRejectsTheTransfer(uint256 _prefunding, uint256 _amount) external {
    // A destination whose `receive` reverts must surface as `WithdrawFailed` rather than silently succeeding.
    // The receiver is deployed outside the prank modifier, so this test starts the prank itself.
    _prefunding = bound(_prefunding, 1, type(uint128).max);
    _amount = bound(_amount, 0, _prefunding);
    RejectingReceiver _rejecting = new RejectingReceiver();
    vm.deal(address(_orchestrator), _prefunding);

    // it should revert with WithdrawFailed
    vm.expectRevert(ILeafMessageOrchestrator.WithdrawFailed.selector);

    vm.prank(_NATIVE_WITHDRAWER);
    _orchestrator.withdrawNative(_amount, address(_rejecting));
  }

  function test_WithdrawNativeWhenTheDestinationAcceptsTheTransfer(
    uint256 _prefunding,
    uint256 _amount,
    address _destination
  ) external givenTheCallerIsTheNativeWithdrawer {
    _assumeFuzzable(_destination);
    // Keep the destination a plain account: a fuzzed contract address could reject the transfer or hold a balance.
    vm.assume(_destination.code.length == 0);
    vm.assume(_destination != address(_orchestrator));
    _prefunding = bound(_prefunding, 1, type(uint128).max);
    _amount = bound(_amount, 1, _prefunding);
    vm.deal(address(_orchestrator), _prefunding);
    uint256 _destinationBefore = _destination.balance;

    // it should emit NativeWithdrawn
    _expectEmit(address(_orchestrator));
    emit ILeafMessageOrchestrator.NativeWithdrawn(_destination, _amount);

    _orchestrator.withdrawNative(_amount, _destination);

    // it should move the amount to the destination
    assertEq(_destination.balance, _destinationBefore + _amount);
    assertEq(address(_orchestrator).balance, _prefunding - _amount);
  }

  /*////////////////////////////////////////////////////////////
                              RECEIVE
  ////////////////////////////////////////////////////////////*/

  function test_ReceiveWhenItReceivesAPlainNativeTransfer(address _sender, uint256 _value) external {
    // The orchestrator holds the pre-funding that pays root-triggered deallocation returns, so a plain transfer
    // from anyone must be accepted (transport refunds arrive the same way).
    _assumeFuzzable(_sender);
    // A self-transfer would break the delta check: `vm.deal` sets a balance rather than adding to it.
    vm.assume(_sender != address(_orchestrator));
    _value = bound(_value, 0, type(uint128).max);
    vm.deal(_sender, _value);
    uint256 _balanceBefore = address(_orchestrator).balance;

    vm.prank(_sender);
    (bool _ok,) = address(_orchestrator).call{value: _value}('');
    assertTrue(_ok);

    // it should increase its balance by the sent value
    assertEq(address(_orchestrator).balance, _balanceBefore + _value);
  }
}

/**
 * @notice Adapter stand-in that quotes a fixed fee and actually receives the native value forwarded to
 *         `sendMessage`.
 * @dev `vm.mockCall` short-circuits the call without moving ETH, so a mocked adapter cannot prove that the fee
 * really left the orchestrator's pre-funding. Only the funding-flow tests use this; every other adapter
 * interaction is mocked.
 */
contract ValueSinkAdapter {
  /// @notice Fee returned by `quoteMessage`.
  uint256 public immutable FEE;
  /// @notice Chain id reported to the orchestrator.
  uint256 public immutable REMOTE_CHAIN_ID;

  /**
   * @notice Binds the fixed quote and remote chain id.
   * @param _fee Fee returned by `quoteMessage`.
   * @param _remoteChainId Chain id reported to the orchestrator.
   */
  constructor(uint256 _fee, uint256 _remoteChainId) {
    FEE = _fee;
    REMOTE_CHAIN_ID = _remoteChainId;
  }

  /// @notice Accepts the forwarded fee and drops the message.
  function sendMessage(bytes calldata, uint256, address) external payable {}

  /**
   * @notice Quotes the fixed fee regardless of the inputs.
   * @return _fee The configured fee.
   */
  function quoteMessage(bytes calldata, uint256, address) external view returns (uint256 _fee) {
    _fee = FEE;
  }
}

/**
 * @notice Destination whose `receive` always reverts, so a native transfer to it fails.
 * @dev Used to reach the `WithdrawFailed` branch of `withdrawNative`.
 */
contract RejectingReceiver {
  /// @notice Rejects every incoming native transfer.
  receive() external payable {
    revert('rejected');
  }
}
