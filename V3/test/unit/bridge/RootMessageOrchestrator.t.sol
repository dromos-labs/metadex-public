// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {
  IMessageAdapter,
  IMessageOrchestrator,
  IRootMessageOrchestrator,
  IVoter,
  RootMessageOrchestrator
} from 'V3/bridge/RootMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {Roles} from 'V3/libraries/Roles.sol';

contract UnitRootMessageOrchestrator is TestHelpers {
  /// @dev Storage slot of the `adapters` mapping in `RootMessageOrchestrator`.
  uint256 internal constant _ADAPTERS_SLOT = 0;
  /// @dev Storage slot of the `noncesUsed` nested mapping in `RootMessageOrchestrator`.
  uint256 internal constant _NONCES_USED_SLOT = 2;
  /// @dev Storage slot of the `deallocationReturnCost` mapping in `RootMessageOrchestrator`.
  ///      Verify with `forge inspect V3/src/bridge/RootMessageOrchestrator.sol:RootMessageOrchestrator storage`.
  uint256 internal constant _DEALLOCATION_RETURN_COST_SLOT = 3;
  /// @dev Destination gas budget used by tests that don't turn on the gas limit.
  uint256 internal constant _GAS_LIMIT = 1_000_000;

  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _VOTER_CONFIG_AUTHORITY = makeAddr('VoterConfigAuthority');
  address internal immutable _NATIVE_WITHDRAWER = makeAddr('NativeWithdrawer');
  address internal immutable _VOTER = makeAddr('Voter');
  address internal immutable _ADAPTER = makeAddr('Adapter');

  RootMessageOrchestrator internal _orchestrator;

  /*////////////////////////////////////////////////////////////
                              SETUP
  ////////////////////////////////////////////////////////////*/

  function setUp() public {
    _orchestrator = new RootMessageOrchestrator(_VOTER);
    // The orchestrator resolves adapter authority via VOTER.hasRole(Roles.ADAPTER_CONFIG_ROLE, caller). Default any
    // caller to false, then override for the recognized authority.
    vm.mockCall(_VOTER, abi.encodeWithSelector(IAccessControl.hasRole.selector), abi.encode(false));
    vm.mockCall(
      _VOTER, abi.encodeCall(IAccessControl.hasRole, (Roles.ADAPTER_CONFIG_ROLE, _ADAPTER_AUTHORITY)), abi.encode(true)
    );
    // The cost setter and the native withdrawal resolve their own roles through the same `VOTER.hasRole`
    // hook; give each one a dedicated recognized authority.
    vm.mockCall(
      _VOTER,
      abi.encodeCall(IAccessControl.hasRole, (Roles.VOTER_CONFIG_ROLE, _VOTER_CONFIG_AUTHORITY)),
      abi.encode(true)
    );
    vm.mockCall(
      _VOTER,
      abi.encodeCall(IAccessControl.hasRole, (Roles.NATIVE_WITHDRAWER_ROLE, _NATIVE_WITHDRAWER)),
      abi.encode(true)
    );
  }

  /*////////////////////////////////////////////////////////////
                        SHARED HELPERS
  ////////////////////////////////////////////////////////////*/

  /**
   * @notice Seed `deallocationReturnCost[_chainId]` directly.
   * @dev Written with `vm.store` rather than through `setDeallocationReturnCost`, so a bug in the setter
   *      cannot mask the `dispatch` split tests that read it.
   * @param _chainId Destination chain the cost applies to.
   * @param _cost Cost to write.
   */
  function _mockDeallocationReturnCost(uint256 _chainId, uint256 _cost) internal {
    vm.store(address(_orchestrator), keccak256(abi.encode(_chainId, _DEALLOCATION_RETURN_COST_SLOT)), bytes32(_cost));
    // Read back via the public getter so a slot drift fails here instead of downstream.
    assertEq(_orchestrator.deallocationReturnCost(_chainId), _cost);
  }

  /**
   * @notice Register `_adapter` for `_chainId` by writing the `adapters` slot directly.
   * @param _chainId Destination chain id.
   * @param _adapter Adapter address to register.
   */
  function _registerAdapter(uint256 _chainId, address _adapter) internal {
    vm.store(
      address(_orchestrator), keccak256(abi.encode(_chainId, _ADAPTERS_SLOT)), bytes32(uint256(uint160(_adapter)))
    );
  }

  /**
   * @notice Mock `VOTER.chainStates(_chainId)` to report `_status`, leaving every other field zero.
   * @dev `setDeallocationReturnCost` destructures the full 10-tuple and only reads the trailing status,
   *      so the encoded tuple must carry all ten members.
   * @param _chainId Chain id the mock answers for.
   * @param _status Status the `Voter` reports for `_chainId`.
   */
  function _mockChainStatus(uint256 _chainId, IVoterCommon.ChainStatus _status) internal {
    vm.mockCall(
      _VOTER,
      abi.encodeCall(IVoter.chainStates, (_chainId)),
      abi.encode(
        IVoterCommon.Point({bias: 0, slope: 0, ts: 0, permanentStakeBalance: 0}),
        uint256(0),
        uint256(0),
        uint256(0),
        uint256(0),
        uint256(0),
        uint256(0),
        uint256(0),
        uint256(0),
        _status
      )
    );
  }

  /**
   * @notice Select a fuzzed message type from the outbound set `dispatch` accepts.
   * @param _seed Raw fuzzed byte.
   * @return _msgType Supported outbound message type.
   */
  function _supportedOutboundMessageType(uint8 _seed)
    internal
    pure
    returns (IMessageOrchestrator.MessageType _msgType)
  {
    IMessageOrchestrator.MessageType[6] memory _supportedTypes = [
      IMessageOrchestrator.MessageType.AllocateChain,
      IMessageOrchestrator.MessageType.AllocateGauge,
      IMessageOrchestrator.MessageType.ClaimRewards,
      IMessageOrchestrator.MessageType.SetOperator,
      IMessageOrchestrator.MessageType.ReduceCooldown,
      IMessageOrchestrator.MessageType.EmergencyDeallocate
    ];
    _msgType = _supportedTypes[uint256(_seed) % _supportedTypes.length];
  }

  /*////////////////////////////////////////////////////////////
                            CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  function test_ConstructorWhenVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMessageOrchestrator.ZeroAddress.selector);
    new RootMessageOrchestrator(address(0));
  }

  function test_ConstructorWhenAllInputsAreValid(address _voter) external {
    _assumeFuzzable(_voter);

    _orchestrator = new RootMessageOrchestrator(_voter);

    // it should set VOTER to _voter
    assertEq(address(_orchestrator.VOTER()), _voter);
  }

  /*////////////////////////////////////////////////////////////
                              DISPATCH
  ////////////////////////////////////////////////////////////*/

  function test_DispatchWhenTheCallerIsNotVOTER(
    address _caller,
    uint8 _msgTypeByte,
    IRootMessageOrchestrator.ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTER);
    _msgTypeByte = uint8(bound(_msgTypeByte, 0, uint8(type(IMessageOrchestrator.MessageType).max)));

    // it should revert with CallerNotAuthorized
    vm.expectRevert(IMessageOrchestrator.CallerNotAuthorized.selector);

    vm.prank(_caller);
    _orchestrator.dispatch(IMessageOrchestrator.MessageType(_msgTypeByte), _dispatches, _refundRecipient);
  }

  modifier givenCallerIsTheVOTER() {
    vm.startPrank(_VOTER);
    _;
    vm.stopPrank();
  }

  function test_DispatchWhenMsgTypeIsNone(
    IRootMessageOrchestrator.ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.dispatch(IMessageOrchestrator.MessageType.None, _dispatches, _refundRecipient);
  }

  function test_DispatchWhenMsgTypeIsRedeem(
    IRootMessageOrchestrator.ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.dispatch(IMessageOrchestrator.MessageType.Redeem, _dispatches, _refundRecipient);
  }

  function test_DispatchWhenMsgTypeIsDeallocate(
    IRootMessageOrchestrator.ChainDispatch[] calldata _dispatches,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.dispatch(IMessageOrchestrator.MessageType.Deallocate, _dispatches, _refundRecipient);
  }

  function test_DispatchWhenAdapterIsNotSetForAChainId(
    uint8 _msgTypeByte,
    uint256 _chainId,
    uint256 _gasLimit,
    uint256 _nativeValue,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    _msgTypeByte = uint8(_supportedOutboundMessageType(_msgTypeByte));
    vm.assume(_chainId != 0);

    // single-entry array with no adapter set (slot zero by default)
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: false,
      payload: _payload
    });

    // it should revert with AdapterNotRegistered
    vm.expectRevert(IMessageOrchestrator.AdapterNotRegistered.selector);

    _orchestrator.dispatch(IMessageOrchestrator.MessageType(_msgTypeByte), _dispatches, _refundRecipient);
  }

  modifier givenTheAdapterIsSetForChainId(uint256 _arrayLen, uint256 _chainIdSeed) {
    for (uint256 _i; _i < _arrayLen; ++_i) {
      uint256 _chainId = uint256(keccak256(abi.encode(_chainIdSeed, _i))) % type(uint128).max + 1;
      bytes32 _slot = keccak256(abi.encode(_chainId, _ADAPTERS_SLOT));
      vm.store(address(_orchestrator), _slot, bytes32(uint256(uint160(_ADAPTER))));
    }
    _;
  }

  function test_DispatchWhenMsgValueEqualsTotalValue(
    uint8 _msgTypeByte,
    uint8 _arrayLen,
    uint256 _chainIdSeed,
    uint64 _gasLimitSeed,
    uint64 _nativeValueSeed,
    bytes calldata _payloadSeed,
    address _refundRecipient
  ) external givenCallerIsTheVOTER givenTheAdapterIsSetForChainId(bound(uint256(_arrayLen), 1, 5), _chainIdSeed) {
    _msgTypeByte = uint8(_supportedOutboundMessageType(_msgTypeByte));
    // re-bound to mirror the modifier's bounds (same raw inputs → same bounded values)
    _arrayLen = uint8(bound(_arrayLen, 1, 5));

    // Per-iteration random (non-sequential) chainId derived from the same fuzz seed the modifier uses for adapter
    // registration. The uint128 range makes per-array collisions statistically impossible — the duplicate-chainIds
    // case is covered by a dedicated test below.
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches =
      new IRootMessageOrchestrator.ChainDispatch[](_arrayLen);
    for (uint256 _i; _i < _arrayLen; ++_i) {
      uint256 _chainId = uint256(keccak256(abi.encode(_chainIdSeed, _i))) % type(uint128).max + 1;
      _dispatches[_i] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _chainId,
        gasLimit: _gasLimitSeed + _i,
        nativeValue: _nativeValueSeed + _i,
        chargeDeallocationReturn: false,
        payload: abi.encodePacked(_payloadSeed, _i)
      });
    }

    // All chainIds are unique, so each entry stamps nonce 1 for its chain.
    IMessageOrchestrator.MessageType _msgType = IMessageOrchestrator.MessageType(_msgTypeByte);
    uint256 _totalValue;
    for (uint256 _i; _i < _arrayLen; ++_i) {
      bytes memory _message =
        abi.encodePacked(_msgTypeByte, uint256(1), uint48(block.timestamp), _dispatches[_i].payload);
      // it should call sendMessage with the wrapped header, _gasLimit, and _refundRecipient on each iteration
      // it should forward _dispatch.nativeValue per iteration
      _mockAndExpectWithValue(
        _ADAPTER,
        _dispatches[_i].nativeValue,
        abi.encodeCall(IMessageAdapter.sendMessage, (_message, _dispatches[_i].gasLimit, _refundRecipient)),
        ''
      );
      // it should emit MessageDispatched with _dispatch.chainId, _nonce and _msgType on each iteration
      _expectEmit(address(_orchestrator));
      emit IMessageOrchestrator.MessageDispatched(_dispatches[_i].chainId, 1, _msgType);
      _totalValue += _dispatches[_i].nativeValue;
    }

    vm.deal(_VOTER, _totalValue);

    _orchestrator.dispatch{value: _totalValue}(_msgType, _dispatches, _refundRecipient);

    // it should advance nonceOut for each _dispatch.chainId to 1
    for (uint256 _i; _i < _arrayLen; ++_i) {
      assertEq(_orchestrator.nonceOut(_dispatches[_i].chainId), 1);
    }
  }

  function test_DispatchWhenMsgValueEqualsTotalValueWithDuplicateChainIds(
    uint8 _msgTypeByte,
    uint8 _arrayLen,
    uint256 _chainIdSeed,
    uint64 _gasLimitSeed,
    uint64 _nativeValueSeed,
    bytes calldata _payloadSeed,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    _msgTypeByte = uint8(_supportedOutboundMessageType(_msgTypeByte));
    // _arrayLen ∈ [4, 6] over a chainId pool of size 3 guarantees at least one duplicate by pigeonhole.
    _arrayLen = uint8(bound(_arrayLen, 4, 6));

    // Register an adapter for each chainId in the pool [1, 3].
    for (uint256 _i = 1; _i <= 3; ++_i) {
      bytes32 _slot = keccak256(abi.encode(_i, _ADAPTERS_SLOT));
      vm.store(address(_orchestrator), _slot, bytes32(uint256(uint160(_ADAPTER))));
    }

    // Per-iteration chainId in [1, 3]; differing payload/fee/gasLimit per entry so duplicates still vary.
    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches =
      new IRootMessageOrchestrator.ChainDispatch[](_arrayLen);
    for (uint256 _i; _i < _arrayLen; ++_i) {
      uint256 _chainId = bound(uint256(keccak256(abi.encode(_chainIdSeed, _i))), 1, 3);
      _dispatches[_i] = IRootMessageOrchestrator.ChainDispatch({
        chainId: _chainId,
        gasLimit: _gasLimitSeed + _i,
        nativeValue: _nativeValueSeed + _i,
        chargeDeallocationReturn: false,
        payload: abi.encodePacked(_payloadSeed, _i)
      });
    }

    // Per-iteration nonce = 1 + count of prior entries sharing this chainId.
    IMessageOrchestrator.MessageType _msgType = IMessageOrchestrator.MessageType(_msgTypeByte);
    uint256 _totalValue;
    for (uint256 _i; _i < _arrayLen; ++_i) {
      uint256 _expectedNonce = 1;
      for (uint256 _j; _j < _i; ++_j) {
        if (_dispatches[_j].chainId == _dispatches[_i].chainId) _expectedNonce++;
      }
      bytes memory _message =
        abi.encodePacked(_msgTypeByte, _expectedNonce, uint48(block.timestamp), _dispatches[_i].payload);
      // it should call sendMessage with the per-chain stamped nonce on each iteration
      _mockAndExpectWithValue(
        _ADAPTER,
        _dispatches[_i].nativeValue,
        abi.encodeCall(IMessageAdapter.sendMessage, (_message, _dispatches[_i].gasLimit, _refundRecipient)),
        ''
      );
      // it should emit MessageDispatched with the per-chain stamped nonce on each iteration
      _expectEmit(address(_orchestrator));
      emit IMessageOrchestrator.MessageDispatched(_dispatches[_i].chainId, _expectedNonce, _msgType);
      _totalValue += _dispatches[_i].nativeValue;
    }

    vm.deal(_VOTER, _totalValue);

    _orchestrator.dispatch{value: _totalValue}(_msgType, _dispatches, _refundRecipient);

    // it should advance nonceOut for each chainId by the count of dispatches targeting it
    for (uint256 _chainId = 1; _chainId <= 3; ++_chainId) {
      uint256 _expectedFinalNonce;
      for (uint256 _j; _j < _arrayLen; ++_j) {
        if (_dispatches[_j].chainId == _chainId) _expectedFinalNonce++;
      }
      assertEq(_orchestrator.nonceOut(_chainId), _expectedFinalNonce);
    }
  }

  function test_DispatchWhenMsgValueDoesNotEqualTotalValue(
    uint8 _msgTypeByte,
    uint256 _chainIdSeed,
    uint256 _gasLimit,
    uint64 _nativeValue,
    uint64 _wrongMsgValue,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER givenTheAdapterIsSetForChainId(1, _chainIdSeed) {
    _msgTypeByte = uint8(_supportedOutboundMessageType(_msgTypeByte));
    // overpayment branch: msg.value > total so the loop completes and the post-loop check fires.
    // (underpayment fails earlier with insufficient balance inside sendMessage, which does not exercise
    // the InvalidDispatchValue revert.)
    _nativeValue = uint64(bound(_nativeValue, 0, type(uint64).max - 1));
    _wrongMsgValue = uint64(bound(_wrongMsgValue, _nativeValue + 1, type(uint64).max));

    // Same derivation the modifier uses, so the dispatch entry's chainId matches the registered adapter slot.
    uint256 _chainId = uint256(keccak256(abi.encode(_chainIdSeed, uint256(0)))) % type(uint128).max + 1;

    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _gasLimit,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: false,
      payload: _payload
    });

    // mock so the inner sendMessage doesn't fail; the revert fires AFTER the loop completes
    bytes memory _message = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType(_msgTypeByte)), uint256(1), uint48(block.timestamp), _payload
    );
    vm.mockCall(_ADAPTER, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _gasLimit, _refundRecipient)), '');

    vm.deal(_VOTER, _wrongMsgValue);

    // it should revert with InvalidDispatchValue
    vm.expectRevert(IRootMessageOrchestrator.InvalidDispatchValue.selector);

    _orchestrator.dispatch{value: _wrongMsgValue}(
      IMessageOrchestrator.MessageType(_msgTypeByte), _dispatches, _refundRecipient
    );
  }

  /*////////////////////////////////////////////////////////////
                  DISPATCH - DEALLOCATION RETURN COST
  ////////////////////////////////////////////////////////////*/

  function test_DispatchWhenAChargingEntryValueCoversTheCost(
    uint8 _msgTypeByte,
    uint256 _chainId,
    uint128 _cost,
    uint128 _extra,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    IMessageOrchestrator.MessageType _msgType = _supportedOutboundMessageType(_msgTypeByte);
    _chainId = bound(_chainId, 1, type(uint128).max);
    // Keep both legs fundable; `nativeValue >= cost` by construction so the split is well defined.
    uint256 _boundedCost = bound(_cost, 0, 100 ether);
    uint256 _transportFee = bound(_extra, 0, 100 ether);

    // A real adapter that keeps whatever value it receives, so the split is observable on both sides:
    // the transport fee lands on the adapter and the retained cost stays on the orchestrator.
    address _adapter = address(new ValueRetainingAdapter());
    _registerAdapter(_chainId, _adapter);
    _mockDeallocationReturnCost(_chainId, _boundedCost);

    // it should forward nativeValue minus the chain's deallocationReturnCost to the adapter
    _expectAdapterSend(_adapter, _transportFee, _msgType, _payload, _refundRecipient);

    vm.deal(_VOTER, _boundedCost + _transportFee);

    _orchestrator.dispatch{value: _boundedCost + _transportFee}(
      _msgType, _singleDispatch(_chainId, _boundedCost + _transportFee, true, _payload), _refundRecipient
    );

    // it should retain exactly the chain's deallocationReturnCost in its own balance
    assertEq(address(_orchestrator).balance, _boundedCost);
    assertEq(_adapter.balance, _transportFee);
  }

  function test_DispatchWhenANonChargingEntryHasANonZeroCost(
    uint8 _msgTypeByte,
    uint256 _chainId,
    uint128 _cost,
    uint128 _nativeValueSeed,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    IMessageOrchestrator.MessageType _msgType = _supportedOutboundMessageType(_msgTypeByte);
    _chainId = bound(_chainId, 1, type(uint128).max);
    // A non-zero cost is seeded to prove the split only applies when the entry flags it. `nativeValue`
    // is deliberately allowed to fall below that cost: an unflagged entry never consults it.
    uint256 _nativeValue = bound(_nativeValueSeed, 0, 100 ether);

    address _adapter = address(new ValueRetainingAdapter());
    _registerAdapter(_chainId, _adapter);
    _mockDeallocationReturnCost(_chainId, bound(_cost, 1, 100 ether));

    // it should forward the whole nativeValue to the adapter
    _expectAdapterSend(_adapter, _nativeValue, _msgType, _payload, _refundRecipient);

    vm.deal(_VOTER, _nativeValue);

    _orchestrator.dispatch{value: _nativeValue}(
      _msgType, _singleDispatch(_chainId, _nativeValue, false, _payload), _refundRecipient
    );

    // it should retain nothing in its own balance
    assertEq(address(_orchestrator).balance, 0);
    assertEq(_adapter.balance, _nativeValue);
  }

  function test_DispatchWhenAChargingEntryValueIsBelowTheCost(
    uint8 _msgTypeByte,
    uint256 _chainId,
    uint128 _cost,
    uint128 _nativeValueSeed,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    IMessageOrchestrator.MessageType _msgType = _supportedOutboundMessageType(_msgTypeByte);
    _chainId = bound(_chainId, 1, type(uint128).max);
    // Cost strictly above the entry's value forces the shortfall.
    uint256 _boundedCost = bound(_cost, 1, 100 ether);
    uint256 _nativeValue = bound(_nativeValueSeed, 0, _boundedCost - 1);

    _registerAdapter(_chainId, address(new ValueRetainingAdapter()));
    _mockDeallocationReturnCost(_chainId, _boundedCost);

    vm.deal(_VOTER, _nativeValue);

    // it should revert with InsufficientDeallocationReturnCost
    vm.expectRevert(IRootMessageOrchestrator.InsufficientDeallocationReturnCost.selector);

    _orchestrator.dispatch{value: _nativeValue}(
      _msgType, _singleDispatch(_chainId, _nativeValue, true, _payload), _refundRecipient
    );
  }

  function test_DispatchWhenABatchMixesChargingAndNonChargingDestinations(
    uint8 _msgTypeByte,
    uint128 _cost,
    uint128 _chargedExtra,
    uint128 _plainValue,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    IMessageOrchestrator.MessageType _msgType = _supportedOutboundMessageType(_msgTypeByte);
    uint256 _boundedCost = bound(_cost, 1, 100 ether);
    uint256 _chargedFee = bound(_chargedExtra, 0, 100 ether);
    uint256 _boundedPlainValue = bound(_plainValue, 0, 100 ether);

    // Two distinct destinations with their own adapters so each forwarded amount is attributable. Both
    // chains carry the same seeded cost; only the flagged destination is charged for it.
    address _chargedAdapter = address(new ValueRetainingAdapter());
    address _plainAdapter = address(new ValueRetainingAdapter());
    _registerAdapter(1, _chargedAdapter);
    _registerAdapter(2, _plainAdapter);
    _mockDeallocationReturnCost(1, _boundedCost);
    _mockDeallocationReturnCost(2, _boundedCost);

    // it should forward each destination its own nativeValue minus its charged cost
    _expectAdapterSend(_chargedAdapter, _chargedFee, _msgType, _payload, _refundRecipient);
    _expectAdapterSend(_plainAdapter, _boundedPlainValue, _msgType, _payload, _refundRecipient);

    vm.deal(_VOTER, _boundedCost + _chargedFee + _boundedPlainValue);

    // it should require msg.value to equal the sum of the per-destination nativeValues
    _orchestrator.dispatch{value: _boundedCost + _chargedFee + _boundedPlainValue}(
      _msgType, _mixedDispatches(_boundedCost + _chargedFee, _boundedPlainValue, _payload), _refundRecipient
    );

    // it should retain the sum of the charged costs only
    assertEq(address(_orchestrator).balance, _boundedCost);
    assertEq(_chargedAdapter.balance, _chargedFee);
    assertEq(_plainAdapter.balance, _boundedPlainValue);
  }

  function test_DispatchWhenMsgValueDoesNotEqualTheSumOfNativeValues(
    uint8 _msgTypeByte,
    uint128 _chargedValue,
    uint128 _plainValue,
    uint128 _overpay,
    bytes calldata _payload,
    address _refundRecipient
  ) external givenCallerIsTheVOTER {
    IMessageOrchestrator.MessageType _msgType = _supportedOutboundMessageType(_msgTypeByte);
    uint256 _boundedCharged = bound(_chargedValue, 0, 100 ether);
    uint256 _boundedPlain = bound(_plainValue, 0, 100 ether);
    // Overpayment branch: the loop completes and the post-loop `msg.value` pin fires. (Underpayment
    // fails earlier inside `sendMessage` on insufficient balance, which never reaches the pin.)
    uint256 _msgValue = _boundedCharged + _boundedPlain + bound(_overpay, 1, 100 ether);

    _registerAdapter(1, address(new ValueRetainingAdapter()));
    _registerAdapter(2, address(new ValueRetainingAdapter()));
    // Zero cost on the flagged destination so the split is a no-op and the pin is what trips.
    _mockDeallocationReturnCost(1, 0);

    vm.deal(_VOTER, _msgValue);

    // it should revert with InvalidDispatchValue
    vm.expectRevert(IRootMessageOrchestrator.InvalidDispatchValue.selector);

    _orchestrator.dispatch{value: _msgValue}(
      _msgType, _mixedDispatches(_boundedCharged, _boundedPlain, _payload), _refundRecipient
    );
  }

  /**
   * @notice Build a single-entry `ChainDispatch[]`.
   * @dev Lives in its own frame so the split tests stay under the legacy non-via-ir stack limit.
   * @param _chainId Destination chain id.
   * @param _nativeValue Native value declared for the destination.
   * @param _chargeDeallocationReturn Whether the orchestrator must retain the chain's return cost.
   * @param _payload Dispatch payload.
   * @return _dispatches Length-1 dispatch array.
   */
  function _singleDispatch(
    uint256 _chainId,
    uint256 _nativeValue,
    bool _chargeDeallocationReturn,
    bytes memory _payload
  ) private pure returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _GAS_LIMIT,
      nativeValue: _nativeValue,
      chargeDeallocationReturn: _chargeDeallocationReturn,
      payload: _payload
    });
  }

  /**
   * @notice Build a two-entry `ChainDispatch[]`: chain 1 charging, chain 2 not.
   * @dev Lives in its own frame so the batch tests stay under the legacy non-via-ir stack limit.
   * @param _chargedValue Native value declared for the charging destination (chain 1).
   * @param _plainValue Native value declared for the non-charging destination (chain 2).
   * @param _payload Dispatch payload, shared by both entries.
   * @return _dispatches Length-2 dispatch array.
   */
  function _mixedDispatches(
    uint256 _chargedValue,
    uint256 _plainValue,
    bytes memory _payload
  ) private pure returns (IRootMessageOrchestrator.ChainDispatch[] memory _dispatches) {
    _dispatches = new IRootMessageOrchestrator.ChainDispatch[](2);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: 1, gasLimit: _GAS_LIMIT, nativeValue: _chargedValue, chargeDeallocationReturn: true, payload: _payload
    });
    _dispatches[1] = IRootMessageOrchestrator.ChainDispatch({
      chainId: 2, gasLimit: _GAS_LIMIT, nativeValue: _plainValue, chargeDeallocationReturn: false, payload: _payload
    });
  }

  /**
   * @notice Expect the adapter's `sendMessage` to be called with `_value` and the wrapped header.
   * @dev Every dispatch in these tests is the first to its chain, so the stamped nonce is always 1.
   * @param _adapter Adapter expected to receive the call.
   * @param _value Native value the orchestrator must forward.
   * @param _msgType Message type stamped into the header.
   * @param _payload Dispatch payload the header wraps.
   * @param _refundRecipient Refund recipient forwarded to the adapter.
   */
  function _expectAdapterSend(
    address _adapter,
    uint256 _value,
    IMessageOrchestrator.MessageType _msgType,
    bytes memory _payload,
    address _refundRecipient
  ) private {
    bytes memory _message = abi.encodePacked(uint8(_msgType), uint256(1), uint48(block.timestamp), _payload);
    vm.expectCall(
      _adapter, _value, abi.encodeCall(IMessageAdapter.sendMessage, (_message, _GAS_LIMIT, _refundRecipient))
    );
  }

  /*////////////////////////////////////////////////////////////
                              ROUTE
  ////////////////////////////////////////////////////////////*/

  function test_RouteWhenTheCallerIsNotTheRegisteredAdapter(
    address _caller,
    uint256 _originChainId,
    bytes calldata _payload
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _ADAPTER);
    // register an adapter for _originChainId so the test exercises "caller does not match registered adapter"
    bytes32 _slot = keccak256(abi.encode(_originChainId, _ADAPTERS_SLOT));
    vm.store(address(_orchestrator), _slot, bytes32(uint256(uint160(_ADAPTER))));

    // it should revert with CallerNotAdapter
    vm.expectRevert(IMessageOrchestrator.CallerNotAdapter.selector);

    vm.prank(_caller);
    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenTheCallerIsTheRegisteredAdapter(uint256 _originChainId) {
    bytes32 _slot = keccak256(abi.encode(_originChainId, _ADAPTERS_SLOT));
    vm.store(address(_orchestrator), _slot, bytes32(uint256(uint160(_ADAPTER))));
    vm.startPrank(_ADAPTER);
    _;
    vm.stopPrank();
  }

  function test_RouteWhenThePayloadIsShorterThanTheHeader(
    uint256 _originChainId,
    uint8 _payloadLen
  ) external givenTheCallerIsTheRegisteredAdapter(_originChainId) {
    // The header is 39 bytes (`uint8` type + `uint256` nonce + `uint48` dispatchedAt); 38 is the boundary.
    _payloadLen = uint8(bound(_payloadLen, 0, 38));
    bytes memory _payload = new bytes(_payloadLen);

    // it should revert with InvalidPayload
    vm.expectRevert(IMessageOrchestrator.InvalidPayload.selector);

    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenThePayloadContainsTheHeader() {
    _;
  }

  function test_RouteWhenTheMessageTypeByteIsNone(
    uint256 _originChainId,
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheRegisteredAdapter(_originChainId) givenThePayloadContainsTheHeader {
    bytes memory _payload = abi.encodePacked(uint8(0), _chainNonce, uint48(block.timestamp), _body);

    // it should revert with NoneMessageType
    vm.expectRevert(IMessageOrchestrator.NoneMessageType.selector);

    _orchestrator.route(_originChainId, _payload);
  }

  function test_RouteWhenTheMessageTypeByteIsOutOfRange(
    uint256 _originChainId,
    uint8 _msgTypeByte,
    uint256 _chainNonce,
    bytes calldata _body
  ) external givenTheCallerIsTheRegisteredAdapter(_originChainId) givenThePayloadContainsTheHeader {
    _msgTypeByte = uint8(bound(_msgTypeByte, uint8(type(IMessageOrchestrator.MessageType).max) + 1, type(uint8).max));
    bytes memory _payload = abi.encodePacked(_msgTypeByte, _chainNonce, uint48(block.timestamp), _body);

    // it should revert with InvalidMessageType
    vm.expectRevert(IMessageOrchestrator.InvalidMessageType.selector);

    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenTheMessageTypeByteIsInRange() {
    _;
  }

  function test_RouteWhenTheMessageWasDispatchedAheadOfTheLocalClock(
    uint256 _originChainId,
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount,
    uint48 _clockLag
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
  {
    // A chain resuming from an outage produces blocks stamped behind wall time, so a message can arrive with a
    // `dispatchedAt` its clock has not reached yet.
    _clockLag = uint48(bound(_clockLag, 1, 52 weeks));
    // Give the clock room to lag behind the dispatch stamp.
    vm.warp(block.timestamp + _clockLag);
    uint48 _dispatchedAt = uint48(block.timestamp);
    bytes memory _body = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _tokenId, amount: _amount}));
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Deallocate), _chainNonce, _dispatchedAt, _body);

    // it should revert with ClockBehindDispatch
    vm.warp(_dispatchedAt - _clockLag);
    vm.expectRevert(IMessageOrchestrator.ClockBehindDispatch.selector);
    _orchestrator.route(_originChainId, _payload);

    // it should deliver once the clock reaches the dispatch time
    vm.warp(_dispatchedAt);
    _mockAndExpect(_VOTER, abi.encodeCall(IVoter.processDeallocation, (_originChainId, _tokenId, _amount)), '');
    _orchestrator.route(_originChainId, _payload);
    assertTrue(_orchestrator.noncesUsed(_originChainId, _chainNonce));
  }

  function test_RouteWhenTheChainNonceHasAlreadyBeenUsed(
    uint256 _originChainId,
    uint8 _msgTypeByte,
    uint256 _chainNonce,
    bytes calldata _body
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
  {
    // exclude None — the decoder rejects it before reaching the nonce check
    _msgTypeByte = uint8(
      bound(
        _msgTypeByte,
        uint8(IMessageOrchestrator.MessageType.None) + 1,
        uint8(type(IMessageOrchestrator.MessageType).max)
      )
    );
    // pre-mark noncesUsed[_originChainId][_chainNonce]
    bytes32 _outerSlot = keccak256(abi.encode(_originChainId, _NONCES_USED_SLOT));
    bytes32 _innerSlot = keccak256(abi.encode(_chainNonce, _outerSlot));
    vm.store(address(_orchestrator), _innerSlot, bytes32(uint256(1)));

    bytes memory _payload = abi.encodePacked(_msgTypeByte, _chainNonce, uint48(block.timestamp), _body);

    // it should revert with NonceAlreadyUsed
    vm.expectRevert(IMessageOrchestrator.NonceAlreadyUsed.selector);

    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenTheChainNonceHasNotBeenUsed() {
    _;
  }

  function test_RouteWhenTheMessageTypeIsAnUnsupportedInboundType(
    uint256 _originChainId,
    uint8 _msgTypeByte,
    uint256 _chainNonce,
    bytes calldata _body
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    givenTheChainNonceHasNotBeenUsed
  {
    // msgType ∈ {AllocateChain, AllocateGauge, ClaimRewards, SetOperator, ReduceCooldown, EmergencyDeallocate} —
    // fuzz covers all 6 over the run. These are root-to-leaf outbound types, never routed inbound, so route rejects
    // them. None (0) is excluded because the decoder rejects it before reaching route's msgType cascade; Redeem and
    // Deallocate are the two inbound-supported types and are covered by their own branches below.
    _msgTypeByte = uint8(_supportedOutboundMessageType(_msgTypeByte));
    bytes memory _payload = abi.encodePacked(_msgTypeByte, _chainNonce, uint48(block.timestamp), _body);

    // it should revert with UnsupportedMessageType
    vm.expectRevert(IMessageOrchestrator.UnsupportedMessageType.selector);

    _orchestrator.route(_originChainId, _payload);
  }

  modifier givenTheMessageTypeIsRedeem() {
    _;
  }

  function test_RouteWhenTheRedeemBodyIsMalformed(
    uint256 _originChainId,
    uint256 _chainNonce,
    uint8 _bodyLen
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    givenTheChainNonceHasNotBeenUsed
    givenTheMessageTypeIsRedeem
  {
    // The Redeem body decodes as `RedeemMessageBody` = 96 bytes; anything shorter reverts inside abi.decode.
    _bodyLen = uint8(bound(_bodyLen, 0, 95));
    bytes memory _body = new bytes(_bodyLen);
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Redeem), _chainNonce, uint48(block.timestamp), _body);

    // it should revert with a decode error
    vm.expectRevert();

    _orchestrator.route(_originChainId, _payload);
  }

  function test_RouteWhenTheRedeemBodyIsWellFormed(
    uint256 _originChainId,
    uint256 _chainNonce,
    uint256 _amount,
    address _recipient,
    uint256 _surplusAccrued
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    givenTheChainNonceHasNotBeenUsed
    givenTheMessageTypeIsRedeem
  {
    bytes memory _body = abi.encode(
      IVoterCommon.RedeemMessageBody({amount: _amount, recipient: _recipient, surplusAccrued: _surplusAccrued})
    );
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Redeem), _chainNonce, uint48(block.timestamp), _body);

    // it should decode the body and call processRedeem on VOTER with the typed inputs
    _mockAndExpect(
      _VOTER, abi.encodeCall(IVoter.processRedeem, (_originChainId, _amount, _recipient, _surplusAccrued)), ''
    );

    // it should emit MessageReceived for redeem
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(_originChainId, _chainNonce, IMessageOrchestrator.MessageType.Redeem);

    _orchestrator.route(_originChainId, _payload);

    // it should mark the chain nonce as used for the origin chain
    assertTrue(_orchestrator.noncesUsed(_originChainId, _chainNonce));
  }

  modifier givenTheMessageTypeIsDeallocate() {
    _;
  }

  function test_RouteWhenTheDeallocateOriginChainIsSuspended(
    uint256 _originChainId,
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    givenTheChainNonceHasNotBeenUsed
    givenTheMessageTypeIsDeallocate
  {
    // Deallocate is accepted even while the origin chain is Suspended: unlike redeem it cannot inflate,
    // the credit path only pulls the token's own booked VP back to CHAIN0. The route must NOT consult
    // isSuspended for a Deallocate, so it is mocked `true` (a Suspended origin) but never expected.
    vm.mockCall(_VOTER, abi.encodeCall(IVoter.isSuspended, (_originChainId)), abi.encode(true));
    bytes memory _body = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _tokenId, amount: _amount}));
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Deallocate), _chainNonce, uint48(block.timestamp), _body);

    // it should still decode the body and call processDeallocation on VOTER
    _mockAndExpect(_VOTER, abi.encodeCall(IVoter.processDeallocation, (_originChainId, _tokenId, _amount)), '');

    // it should emit MessageReceived for the suspended deallocate
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(_originChainId, _chainNonce, IMessageOrchestrator.MessageType.Deallocate);

    _orchestrator.route(_originChainId, _payload);

    assertTrue(_orchestrator.noncesUsed(_originChainId, _chainNonce));
  }

  function test_RouteWhenTheDeallocateOriginChainIsNotSuspended(
    uint256 _originChainId,
    uint256 _chainNonce,
    uint256 _tokenId,
    uint128 _amount
  )
    external
    givenTheCallerIsTheRegisteredAdapter(_originChainId)
    givenThePayloadContainsTheHeader
    givenTheMessageTypeByteIsInRange
    givenTheChainNonceHasNotBeenUsed
    givenTheMessageTypeIsDeallocate
  {
    // Not-suspended happy path for Deallocate: the route accepts it and credits it back to CHAIN0.
    vm.mockCall(_VOTER, abi.encodeCall(IVoter.isSuspended, (_originChainId)), abi.encode(false));
    bytes memory _body = abi.encode(IVoterCommon.DeallocationMessageBody({tokenId: _tokenId, amount: _amount}));
    bytes memory _payload =
      abi.encodePacked(uint8(IMessageOrchestrator.MessageType.Deallocate), _chainNonce, uint48(block.timestamp), _body);

    // it should decode the body and call processDeallocation on VOTER
    _mockAndExpect(_VOTER, abi.encodeCall(IVoter.processDeallocation, (_originChainId, _tokenId, _amount)), '');

    // it should emit MessageReceived for the active deallocate
    _expectEmit(address(_orchestrator));
    emit IMessageOrchestrator.MessageReceived(_originChainId, _chainNonce, IMessageOrchestrator.MessageType.Deallocate);

    _orchestrator.route(_originChainId, _payload);

    assertTrue(_orchestrator.noncesUsed(_originChainId, _chainNonce));
  }

  /*////////////////////////////////////////////////////////////
                            SET ADAPTER
  ////////////////////////////////////////////////////////////*/

  function test_SetAdapterWhenTheCallerIsNotAdapterAuthority(
    address _caller,
    uint256 _chainId,
    IMessageAdapter _adapter
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _ADAPTER_AUTHORITY);

    // it should revert with CallerNotAdapterAuthority
    vm.expectRevert(IMessageOrchestrator.CallerNotAdapterAuthority.selector);

    vm.prank(_caller);
    _orchestrator.setAdapter(_chainId, _adapter);
  }

  modifier givenTheCallerIsAdapterAuthority() {
    vm.startPrank(_ADAPTER_AUTHORITY);
    _;
    vm.stopPrank();
  }

  function test_SetAdapterWhenChainIdIsZero(IMessageAdapter _adapter) external givenTheCallerIsAdapterAuthority {
    // it should revert with InvalidChainId
    vm.expectRevert(IRootMessageOrchestrator.InvalidChainId.selector);

    _orchestrator.setAdapter(0, _adapter);
  }

  modifier givenChainIdIsNotZero(uint256 _chainId) {
    vm.assume(_chainId != 0);
    _;
  }

  function test_SetAdapterWhenTheAdapterIsTheZeroAddress(uint256 _chainId)
    external
    givenTheCallerIsAdapterAuthority
    givenChainIdIsNotZero(_chainId)
  {
    // it should revert with InvalidAdapter
    vm.expectRevert(IMessageOrchestrator.InvalidAdapter.selector);

    _orchestrator.setAdapter(_chainId, IMessageAdapter(address(0)));
  }

  modifier givenTheAdapterIsNotTheZeroAddress(IMessageAdapter _adapter) {
    _assumeFuzzable(address(_adapter));
    _;
  }

  function test_SetAdapterWhenTheAdapterRemoteChainIdDoesNotMatchChainId(
    uint256 _chainId,
    IMessageAdapter _adapter,
    uint256 _wrongRemoteChainId
  )
    external
    givenTheCallerIsAdapterAuthority
    givenChainIdIsNotZero(_chainId)
    givenTheAdapterIsNotTheZeroAddress(_adapter)
  {
    vm.assume(_wrongRemoteChainId != _chainId);

    _mockAndExpect(
      address(_adapter), abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_wrongRemoteChainId)
    );

    // it should revert with AdapterChainIdMismatch
    vm.expectRevert(IRootMessageOrchestrator.AdapterChainIdMismatch.selector);

    _orchestrator.setAdapter(_chainId, _adapter);
  }

  function test_SetAdapterWhenTheAdapterRemoteChainIdMatchesChainId(
    uint256 _chainId,
    IMessageAdapter _adapter
  )
    external
    givenTheCallerIsAdapterAuthority
    givenChainIdIsNotZero(_chainId)
    givenTheAdapterIsNotTheZeroAddress(_adapter)
  {
    _mockAndExpect(address(_adapter), abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_chainId));

    // it should emit AdapterUpdated with _chainId and _adapter
    _expectEmit(address(_orchestrator));
    emit IRootMessageOrchestrator.AdapterUpdated(_chainId, _adapter);

    _orchestrator.setAdapter(_chainId, _adapter);

    // it should set the adapter for _chainId
    assertEq(address(_orchestrator.adapters(_chainId)), address(_adapter));
  }

  /*////////////////////////////////////////////////////////////
                  SET DEALLOCATION RETURN COST
  ////////////////////////////////////////////////////////////*/

  function test_SetDeallocationReturnCostWhenTheCallerIsNotVoterConfigAuthority(
    address _caller,
    uint256 _chainId,
    uint256 _cost
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _VOTER_CONFIG_AUTHORITY);

    // it should revert with CallerNotVoterConfigAuthority
    vm.expectRevert(IRootMessageOrchestrator.CallerNotVoterConfigAuthority.selector);

    vm.prank(_caller);
    _orchestrator.setDeallocationReturnCost(_chainId, _cost);
  }

  modifier givenTheCallerIsVoterConfigAuthority() {
    vm.startPrank(_VOTER_CONFIG_AUTHORITY);
    _;
    vm.stopPrank();
  }

  function test_SetDeallocationReturnCostWhenTheChainIsNotRegistered(
    uint256 _chainId,
    uint256 _cost
  ) external givenTheCallerIsVoterConfigAuthority {
    // `None` is the uninitialized status the `Voter` reports for a chain it never registered.
    _mockChainStatus(_chainId, IVoterCommon.ChainStatus.None);

    // it should revert with ChainNotRegistered
    vm.expectRevert(abi.encodeWithSelector(IRootMessageOrchestrator.ChainNotRegistered.selector, _chainId));

    _orchestrator.setDeallocationReturnCost(_chainId, _cost);
  }

  function test_SetDeallocationReturnCostWhenTheCostIsNonZeroForTheRootColocatedChain(uint256 _cost)
    external
    givenTheCallerIsVoterConfigAuthority
  {
    _cost = bound(_cost, 1, type(uint256).max);
    _mockChainStatus(block.chainid, IVoterCommon.ChainStatus.Active);

    // it should revert with DeallocationReturnCostNotAllowed
    vm.expectRevert(IRootMessageOrchestrator.DeallocationReturnCostNotAllowed.selector);

    _orchestrator.setDeallocationReturnCost(block.chainid, _cost);
  }

  function test_SetDeallocationReturnCostWhenTheCostIsZeroForTheRootColocatedChain()
    external
    givenTheCallerIsVoterConfigAuthority
  {
    _mockChainStatus(block.chainid, IVoterCommon.ChainStatus.Active);

    // it should emit DeallocationReturnCostSet with the chainId and a zero cost
    _expectEmit(address(_orchestrator));
    emit IRootMessageOrchestrator.DeallocationReturnCostSet(block.chainid, 0);

    _orchestrator.setDeallocationReturnCost(block.chainid, 0);

    // it should leave the stored cost at zero
    assertEq(_orchestrator.deallocationReturnCost(block.chainid), 0);
  }

  function test_SetDeallocationReturnCostWhenTheChainIsRegistered(
    uint256 _chainId,
    uint256 _cost,
    uint8 _statusByte
  ) external givenTheCallerIsVoterConfigAuthority {
    vm.assume(_chainId != block.chainid);
    // Any non-`None` status counts as registered — fuzz across Active / Paused / Suspended / Sunset.
    _statusByte =
      uint8(bound(_statusByte, uint8(IVoterCommon.ChainStatus.None) + 1, uint8(type(IVoterCommon.ChainStatus).max)));
    _mockChainStatus(_chainId, IVoterCommon.ChainStatus(_statusByte));

    // it should emit DeallocationReturnCostSet with the chainId and the cost
    _expectEmit(address(_orchestrator));
    emit IRootMessageOrchestrator.DeallocationReturnCostSet(_chainId, _cost);

    _orchestrator.setDeallocationReturnCost(_chainId, _cost);

    // it should store the cost for the chainId
    assertEq(_orchestrator.deallocationReturnCost(_chainId), _cost);
  }

  /*////////////////////////////////////////////////////////////
                          WITHDRAW NATIVE
  ////////////////////////////////////////////////////////////*/

  function test_WithdrawNativeWhenTheCallerIsNotNativeWithdrawer(
    address _caller,
    uint256 _amount,
    address _destination
  ) external {
    _assumeFuzzable(_caller);
    vm.assume(_caller != _NATIVE_WITHDRAWER);

    // it should revert with CallerNotNativeWithdrawer
    vm.expectRevert(IRootMessageOrchestrator.CallerNotNativeWithdrawer.selector);

    vm.prank(_caller);
    _orchestrator.withdrawNative(_amount, _destination);
  }

  modifier givenTheCallerIsNativeWithdrawer() {
    vm.startPrank(_NATIVE_WITHDRAWER);
    _;
    vm.stopPrank();
  }

  function test_WithdrawNativeWhenTheDestinationIsTheZeroAddress(uint256 _amount)
    external
    givenTheCallerIsNativeWithdrawer
  {
    // it should revert with ZeroAddress
    vm.expectRevert(IMessageOrchestrator.ZeroAddress.selector);

    _orchestrator.withdrawNative(_amount, address(0));
  }

  function test_WithdrawNativeWhenTheDestinationRejectsTheTransfer(uint128 _amount)
    external
    givenTheCallerIsNativeWithdrawer
  {
    uint256 _boundedAmount = bound(_amount, 1, 100 ether);
    vm.deal(address(_orchestrator), _boundedAmount);
    RevertingReceiver _receiver = new RevertingReceiver();

    // it should revert with WithdrawFailed
    vm.expectRevert(IRootMessageOrchestrator.WithdrawFailed.selector);

    _orchestrator.withdrawNative(_boundedAmount, address(_receiver));
  }

  function test_WithdrawNativeWhenTheDestinationAcceptsTheTransfer(
    uint128 _retained,
    uint128 _amount,
    address _destination
  ) external givenTheCallerIsNativeWithdrawer {
    _assumeFuzzable(_destination);
    // The destination must accept plain ETH: a code-bearing address (test contract, mocks) may reject
    // the transfer or emit its own logs, so require an EOA-like sink. Also excludes the orchestrator,
    // keeping the balance math clean.
    vm.assume(_destination.code.length == 0);
    vm.assume(_destination != address(_orchestrator));
    // The orchestrator holds at least the withdrawn amount (the accrued deallocation return costs).
    uint256 _boundedAmount = bound(_amount, 0, 100 ether);
    uint256 _boundedRetained = bound(_retained, _boundedAmount, _boundedAmount + 100 ether);
    vm.deal(address(_orchestrator), _boundedRetained);
    vm.deal(_destination, 0);

    // it should emit NativeWithdrawn with the destination and the amount
    _expectEmit(address(_orchestrator));
    emit IRootMessageOrchestrator.NativeWithdrawn(_destination, _boundedAmount);

    _orchestrator.withdrawNative(_boundedAmount, _destination);

    // it should transfer the amount to the destination
    assertEq(_destination.balance, _boundedAmount);
    // it should decrease its own balance by the amount
    assertEq(address(_orchestrator).balance, _boundedRetained - _boundedAmount);
  }
}

/**
 * @notice Minimal adapter that accepts and keeps whatever native value `sendMessage` is called with.
 * @dev Used by the `dispatch` split tests: `vm.mockCall` leaves the forwarded value on the caller, so the
 *      retained-versus-forwarded split is only observable against an adapter that actually receives it.
 *      Deliberately inert otherwise — no transport behavior is exercised.
 */
contract ValueRetainingAdapter {
  /**
   * @notice Accepts the outbound message and keeps the forwarded transport fee.
   * @dev Parameters are unnamed: the assertions live in the caller's `vm.expectCall`.
   */
  function sendMessage(bytes calldata, uint256, address) external payable {}
}

/**
 * @notice Destination that rejects every incoming native transfer.
 * @dev Drives the `withdrawNative` failure branch.
 */
contract RevertingReceiver {
  /// @notice Reject every incoming native transfer so the orchestrator's low-level call fails.
  receive() external payable {
    revert('nope');
  }
}
