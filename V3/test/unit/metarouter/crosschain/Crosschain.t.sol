// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {ITokenRouter} from 'V3/interfaces/external/ITokenRouter.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';
import {WarpRoutePullProbe} from 'V3-test/unit/metarouter/harnesses/WarpRoutePullProbe.sol';

/// @notice Cross-chain module tests: bridging a router-held token to the derived destination account, dispatching a
///         destination-plan commitment, and redeeming held `ReceiptToken` for `TOKEN` on root. All three commands run
///         through the real `execute` entrypoint. The token fee is priced by the route's own quote, so these tests mock
///         that quote rather than reimplementing a fee model, and cover the handlers' own behavior including the
///         reverts they surface.
contract UnitCrosschain is BaseMetarouter {
  /// @notice Fixed destination Hyperlane domain exercised by the commands.
  uint32 internal constant _DOMAIN = 8453;
  /// @notice Non-zero destination router the mocked interchain account router reports for an enrolled domain.
  bytes32 internal constant _REMOTE_ROUTER = keccak256('metarouter.test.remote.router');
  /// @notice Destination ISM the mocked interchain account router reports for an enrolled domain.
  bytes32 internal constant _REMOTE_ISM = keccak256('metarouter.test.remote.ism');
  /// @notice Length of the hook metadata's fixed prefix (variant, msgValue, gasLimit, refund address); shorter
  ///         metadata carries no refund address and reverts, and the optional fee token begins at this offset.
  uint256 internal constant _HOOK_METADATA_PREFIX_LENGTH = 86;
  /// @notice The leaf Voter's `MIN_REDEEM_AMOUNT`, one unit in pips; mirrored here because the voter is mocked.
  uint256 internal constant _MIN_REDEEM_AMOUNT = MAX_PIPS;

  /// @notice Native quantities of a six-decimal native ERC20 pull, each a whole number of raw native ERC20 units plus a
  ///         sub-unit remainder the conversion cannot express.
  struct NativeErc20PullNative {
    uint256 stranded;
    uint256 batchNative;
    uint256 messageFee;
  }

  /// @notice Router the lite-deployment branch dispatches through: no voting system and no cross-chain layer, so its
  ///         `ICA_ROUTER` is `address(0)` and any interchain-account read would reach an account with no code.
  MetarouterHarness internal _liteMetarouter;

  // --- bridgeToken ---

  /// @dev Deploys the lite router the branch's tests dispatch through.
  modifier givenALiteDeploymentWithNoInterchainAccountRouter() {
    _liteMetarouter = _deployLiteMetarouter();
    _;
  }

  /// @notice A zero recipient asks the handler to derive the logical sender's interchain account, which a lite
  ///         deployment cannot do, so the command is gated off.
  function test_BridgeTokenWhenTheRecipientIsTheZeroAddress(
    address _caller,
    address _token,
    address _bridge,
    uint256 _amount,
    uint256 _messageFee
  ) external givenALiteDeploymentWithNoInterchainAccountRouter {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_liteMetarouter));
    vm.deal(_caller, _messageFee);

    // The guard opens the derivation branch, so no collaborator is reached: neither the route nor the token is mocked.
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, 0);

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.BRIDGE_TOKEN));
    _liteMetarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice A direct recipient never consults the interchain account router, so the command still bridges on a lite
  ///         deployment that ships without one.
  function test_BridgeTokenWhenADirectRecipientIsSuppliedOnTheLiteDeployment(
    address _caller,
    address _recipient,
    uint256 _amount,
    uint256 _messageFee
  ) external givenALiteDeploymentWithNoInterchainAccountRouter {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_liteMetarouter));
    // The recipient is only encoded into the route arguments, never called, so it needs no code; it may not be the
    // router itself and may not be zero, which would select the derivation path.
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_liteMetarouter));
    _amount = bound(_amount, 1, type(uint128).max);
    address _token = _mockContract('liteDirectToken');
    address _bridge = _mockContract('liteDirectBridge');
    bytes32 _recipientWord = bytes32(uint256(uint160(_recipient)));
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalancesTwice(_token, address(_liteMetarouter), [_amount, uint256(0)]);
    _mockQuote(_bridge, _token, _recipientWord, _amount, 0, _amount, 0);
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should bridge to the direct recipient without the interchain account router: the lite router holds
    // `ICA_ROUTER == address(0)`, so a surviving derivation read would revert before the route is reached.
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, _recipientWord, _amount)),
      abi.encode(bytes32(0))
    );
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithRecipient(_token, _bridge, _amount, _messageFee, 0, _recipient);

    vm.prank(_caller);
    _liteMetarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice Destination router custody outside a batch is publicly sweepable, so the router is never a valid direct
  ///         recipient.
  function test_BridgeTokenWhenTheRecipientIsTheMetarouter(
    address _caller,
    address _token,
    address _bridge,
    uint256 _amount,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    vm.deal(_caller, _messageFee);

    // The guard opens the direct-recipient branch, so no collaborator is reached: neither the route nor the
    // interchain account router is mocked.
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithRecipient(_token, _bridge, _amount, _messageFee, 0, address(_metarouter));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice A custom interchain account configuration only exists to derive the account a direct recipient replaces,
  ///         so the two are contradictory however the configuration is filled in.
  function test_BridgeTokenWhenADirectRecipientIsCombinedWithACustomInterchainAccountConfiguration(
    address _caller,
    address _recipient,
    address _router,
    address _ism,
    uint256 _amount,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    address _token = _mockContract('directRecipientConfigToken');
    address _bridge = _mockContract('directRecipientConfigBridge');
    // Each half of the configuration is rejected on its own, so all three fillings are dispatched against the same
    // expectation rather than branching on a fuzzed selector.
    _router = _excludingAddressZero(_router);
    _ism = _excludingAddressZero(_ism);
    vm.deal(_caller, _messageFee);

    bytes[] memory _inputs = new bytes[](1);

    // it should revert with InvalidInterchainAccountConfig
    _inputs[0] = _bridgeInputWithRecipientAndConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      0,
      _recipient,
      IMetarouter.IcaConfig({router: _router, ism: address(0)})
    );
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidInterchainAccountConfig.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);

    // it should revert with InvalidInterchainAccountConfig
    _inputs[0] = _bridgeInputWithRecipientAndConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      0,
      _recipient,
      IMetarouter.IcaConfig({router: address(0), ism: _ism})
    );
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidInterchainAccountConfig.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);

    // it should revert with InvalidInterchainAccountConfig
    _inputs[0] = _bridgeInputWithRecipientAndConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      0,
      _recipient,
      IMetarouter.IcaConfig({router: _router, ism: _ism})
    );
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidInterchainAccountConfig.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);
  }

  /// @notice A direct recipient delivers the ERC20 straight to the destination address, leaving the rest of the ERC20
  ///         path — tracking, approval, and the route call — unchanged.
  function test_BridgeTokenWhenADirectRecipientIsSuppliedForAnERC20(
    address _caller,
    address _recipient,
    uint256 _amount,
    uint256 _remainder,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_recipient);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The router held the amount plus the remainder before the bridge pulled the amount, so the two share the range.
    _amount = bound(_amount, 1, type(uint128).max);
    _remainder = bound(_remainder, 1, type(uint128).max);
    address _token = _mockContract('directRecipientToken');
    address _bridge = _mockContract('directRecipientBridge');
    bytes32 _recipientWord = bytes32(uint256(uint160(_recipient)));
    vm.deal(_caller, _messageFee);

    // it should not read the interchain account router: every call to it reverts, so a surviving enrollment or
    // derivation read would fail the dispatch instead of reaching the route.
    vm.mockCallRevert(_ICA_ROUTER, bytes(''), 'unexpected interchain account router read');
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    // resolveSpend reads the balance, then closure re-reads it after the bridge consumed the amount.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount + _remainder, _remainder]);
    _mockQuote(_bridge, _token, _recipientWord, _amount, 0, _amount, 0);
    // it should approve the bridge for the resolved amount
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should bridge the token to the direct recipient
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, _recipientWord, _amount)),
      abi.encode(bytes32(0))
    );
    // it should clear the bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));
    // it should track the token: the unbridged remainder is returned to the caller at closure.
    _mockAndExpectTokenTransfer(_token, _caller, _remainder);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithRecipient(_token, _bridge, _amount, _messageFee, 0, _recipient);

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice An ERC20 bridge pays the message fee on top of the bridged amount, so a fee above the native the batch
  ///         introduced is rejected up front even when the router holds enough pre-batch native to cover it.
  function test_BridgeTokenWhenAnErc20BridgeNamesAMessageFeeAboveTheAvailableNativeBalance(
    address _caller,
    address _recipient,
    uint256 _batchNative,
    uint256 _excess,
    uint256 _stranded,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The direct-recipient path reaches the fee bound without an interchain account derivation to mock.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _batchNative = bound(_batchNative, 0, type(uint256).max - 1);
    _excess = bound(_excess, 1, type(uint256).max - _batchNative);
    // The router already holds enough to cover the excess, capped so the incoming value cannot overflow its balance.
    _stranded = bound(_stranded, _excess, type(uint256).max - _batchNative);
    uint256 _messageFee = _batchNative + _excess;
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_metarouter), _stranded);

    // The guard precedes the route read, so the bridge is never asked which token it manages.
    vm.mockCallRevert(
      _bridge, abi.encodeWithSelector(ITokenRouter.token.selector), 'fee check must precede the route read'
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithRecipient(_token, _bridge, _amount, _messageFee, 0, _recipient);

    // it should revert with InsufficientBalance for the native asset
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, address(0)));
    _metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheInterchainAccountConfigurationNamesAnISMWithoutARouter(
    address _caller,
    address _ism
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_ism);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      address(0),
      address(0),
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)}),
      uint256(0),
      uint256(0),
      IMetarouter.IcaConfig({router: address(0), ism: _ism})
    );

    // it should revert with InvalidInterchainAccountConfig
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidInterchainAccountConfig.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);
  }

  function test_BridgeTokenWhenACustomInterchainAccountConfigurationUsesTheZeroISM(
    address _caller,
    address _recipientIca,
    address _router,
    uint256 _amount,
    uint256 _gas
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_recipientIca);
    _assumeFuzzable(_router);
    _amount = bound(_amount, 2, type(uint128).max);
    _gas = bound(_gas, 1, _amount - 1);
    address _bridge = _mockContract('customConfigBridge');
    IMetarouter.IcaConfig memory _icaConfig = IMetarouter.IcaConfig({router: _router, ism: address(0)});
    vm.deal(_caller, _amount);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(address(0)));
    // it should derive the recipient with the custom router and zero ISM
    _mockCustomDerivedRecipient(_caller, _recipientIca, _icaConfig);
    _mockQuote(_bridge, address(0), bytes32(uint256(uint160(_recipientIca))), _amount, _gas, _amount, 0);
    _mockAndExpectWithValue(
      _bridge,
      _amount,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount - _gas)),
      abi.encode(bytes32(0))
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      address(0),
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      uint256(0),
      _gas,
      _icaConfig
    );

    // it should not require an enrolled router for the domain
    vm.prank(_caller);
    _metarouter.execute{value: _amount}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenACustomInterchainAccountConfigurationIsUsedForAnERC20(
    address _caller,
    address _recipientIca,
    address _router,
    address _ism,
    uint256 _amount,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_recipientIca);
    _assumeFuzzable(_router);
    _assumeFuzzable(_ism);
    _amount = bound(_amount, 1, type(uint128).max);
    address _token = _mockContract('customConfigToken');
    address _bridge = _mockContract('customConfigErc20Bridge');
    IMetarouter.IcaConfig memory _icaConfig = IMetarouter.IcaConfig({router: _router, ism: _ism});
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount, uint256(0)]);
    // it should derive the recipient with the custom router and non-zero ISM
    _mockCustomDerivedRecipient(_caller, _recipientIca, _icaConfig);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount, 0);
    // it should approve the bridge for the resolved amount
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should bridge the token to the custom-derived recipient
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount)),
      abi.encode(bytes32(0))
    );
    // it should clear the bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      uint256(0),
      _icaConfig
    );

    // it should track the token: closure re-reads its balance, and the zero remainder needs no transfer.
    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  modifier givenTheTokenIsTheZeroAddress() {
    _;
  }

  function test_BridgeTokenWhenTheNativeSpendIsAnAbsoluteAmount(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _gas
  ) external givenTheTokenIsTheZeroAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The route's native overhead must leave a positive delivery, so the amount reserves room for a non-zero gas fee.
    _amount = bound(_amount, 2, type(uint128).max);
    _gas = bound(_gas, 1, _amount - 1);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _amount);

    // The domain is enrolled, so the handler passes the registration guard shared with the ERC20 path.
    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(_REMOTE_ROUTER));
    // A native route reports the zero address as its managed token, so the mismatch guard passes for a native bridge.
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(address(0)));
    // it should derive _recipient from the interchain account router with the logical sender as salt
    _mockDerivedRecipient(_caller, _recipientIca);
    // Every native quote entry is native, so the summed total folds the interchain gas into the fee: total = amount +
    // gas, leaving a delivery of amount less gas.
    _mockQuote(_bridge, address(0), bytes32(uint256(uint160(_recipientIca))), _amount, _gas, _amount, 0);
    // it should forward the whole spend as value to transferRemote with the delivery amount
    // it should neither approve nor track the native route: no approve is mocked, and a native token is never tracked,
    // so an erroneous `approve`/`balanceOf` against `address(0)` would revert at the call or the closing sweep.
    _mockAndExpectWithValue(
      _bridge,
      _amount,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount - _gas)),
      abi.encode(bytes32(0))
    );

    bytes[] memory _inputs = new bytes[](1);
    // A native bridge names `address(0)`, spends `_amount` from the batch's native, and leaves `_messageFee` unused.
    _inputs[0] = _bridgeInput(address(0), _bridge, _amount, 0, _gas);

    // it should resolve the spend against the available native balance
    vm.prank(_caller);
    _metarouter.execute{value: _amount}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheNativeSpendTakesTheFullAvailableBalanceInPips(
    address _caller,
    address _recipientIca,
    uint256 _available,
    uint256 _gas
  ) external givenTheTokenIsTheZeroAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The full available native balance is bridged, and the gas fee must leave a positive delivery.
    _available = bound(_available, 2, type(uint128).max);
    _gas = bound(_gas, 1, _available - 1);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _available);

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(_REMOTE_ROUTER));
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(address(0)));
    // it should resolve the full available native balance (a full-pips spend of the batch's native)
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, address(0), bytes32(uint256(uint160(_recipientIca))), _available, _gas, _available, 0);
    // it should forward the whole spend as value to transferRemote with the delivery amount
    // it should neither approve nor track the native route
    _mockAndExpectWithValue(
      _bridge,
      _available,
      abi.encodeCall(
        ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _available - _gas)
      ),
      abi.encode(bytes32(0))
    );

    bytes[] memory _inputs = new bytes[](1);
    // A full-pips native spend takes the entire available native balance; the pip max fee of `MAX_PIPS` accepts any
    // gas fee below the amount, and `_messageFee` stays unused.
    _inputs[0] = _bridgeInputWithConfig(
      address(0),
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      uint256(0),
      MAX_PIPS,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _metarouter.execute{value: _available}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheRouterHoldsNativePredatingTheBatch(
    address _caller,
    address _recipientIca,
    uint256 _available,
    uint256 _pips,
    uint256 _gas,
    uint256 _preBatchBalance,
    uint256 _messageFee
  ) external givenTheTokenIsTheZeroAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The closure refund sends the leftover native to the caller, so it must be an account that can receive ETH.
    vm.assume(_caller.code.length == 0);
    // Two whole pips of batch native so any pip value resolves a proportion of at least two, leaving room for a gas
    // fee below it.
    _available = bound(_available, 2 * MAX_PIPS, type(uint128).max);
    _pips = bound(_pips, 1, MAX_PIPS);
    uint256 _proportion = Math.mulDiv(_available, _pips, MAX_PIPS);
    _gas = bound(_gas, 1, _proportion - 1);
    // A pips spend is the sharpest probe for the balance source: resolving against the raw balance instead of the
    // available one would inflate every downstream expectation by the pre-batch share.
    _preBatchBalance = bound(_preBatchBalance, 1, type(uint128).max);
    _messageFee = bound(_messageFee, 1, type(uint128).max);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _available);
    vm.deal(address(_metarouter), _preBatchBalance);

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(_REMOTE_ROUTER));
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(address(0)));
    // it should resolve only the batch introduced native
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, address(0), bytes32(uint256(uint160(_recipientIca))), _proportion, _gas, _proportion, 0);
    // it should forward the whole spend as value to transferRemote with the delivery amount
    // it should ignore _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _proportion,
      abi.encodeCall(
        ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _proportion - _gas)
      ),
      abi.encode(bytes32(0))
    );

    bytes[] memory _inputs = new bytes[](1);
    // A nonzero `_messageFee` must stay unused: the native route is funded from the forwarded spend alone. The pip
    // max fee of `MAX_PIPS` accepts any gas fee below the proportion.
    _inputs[0] = _bridgeInputWithConfig(
      address(0),
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      MAX_PIPS,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _metarouter.execute{value: _available}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );

    // it should leave the pre batch balance untouched
    assertEq(address(_metarouter).balance, _preBatchBalance);
    // it should clear the transient execution slots at closure
    _assertTransientCleared();
  }

  modifier givenTheTokenIsNotTheZeroAddress() {
    _;
  }

  function test_BridgeTokenWhenTheDestinationDomainIsNotRegistered(
    address _caller,
    address _token,
    address _bridge,
    uint256 _amount,
    uint256 _messageFee
  ) external givenTheTokenIsNotTheZeroAddress {
    _assumeFuzzable(_caller);
    vm.deal(_caller, _messageFee);

    // The domain has no enrolled router, so the handler reverts before the route, the amount, or the quote.
    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(bytes32(0)));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, 0);

    // it should revert with UnregisteredDomain
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.UnregisteredDomain.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  modifier givenTheDestinationDomainIsRegistered() {
    // The interchain account router reports an enrolled destination router for the domain.
    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(_REMOTE_ROUTER));
    _;
  }

  function test_BridgeTokenWhenTheBridgeDoesNotManageTheToken(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _messageFee,
    address _managedToken
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    // The route reports a managed token other than the one being bridged, tripping the mismatch guard.
    _managedToken = _boundNotEq(_managedToken, _token);
    vm.deal(_caller, _messageFee);

    // The recipient resolves before the route is questioned, so the derivation is reached even on this revert path.
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_managedToken));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, 0);

    // it should revert with BridgeTokenMismatch
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.BridgeTokenMismatch.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  modifier givenTheBridgeManagesTheToken() {
    _;
  }

  function test_BridgeTokenWhenTheResolvedAmountIsZero(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _messageFee
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    // A zero-amount spend resolves to zero against any balance, so the handler reverts before quoting.
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, 0, _messageFee, 0);

    // it should revert with ZeroAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.ZeroAmount.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenAPipsSpendResolvesToZero(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _pips,
    uint256 _messageFee
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // A pip spend floors to zero whenever balance times pips is below the denominator, so bound the product under it.
    _pips = bound(_pips, 1, MAX_PIPS - 1);
    _balance = bound(_balance, 0, (MAX_PIPS - 1) / _pips);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    // A zero resolved amount reverts before quoting, after the recipient has already been derived.
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      0,
      _emptyIcaConfig()
    );

    // it should revert with ZeroAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.ZeroAmount.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice A native ERC20 bridge and its message fee draw from the same batch native, so an amount the batch can
  ///         only cover by ignoring the committed fee is rejected at resolution, even when the router holds enough
  ///         stranded pre-batch native to cover the difference.
  function test_BridgeTokenWhenAnAmountSpendOfTheNativeMirrorTokenExceedsTheBatchNativeLessTheMessageFee(
    address _caller,
    address _recipientIca,
    uint256 _batchNative,
    uint256 _messageFee,
    uint256 _amount,
    uint256 _stranded
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the spend resolution has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 1, type(uint128).max);
    _messageFee = bound(_messageFee, 1, _batchNative);
    // The amount fits the batch native alone but not once the message fee is reserved from it.
    _amount = bound(_amount, _batchNative - _messageFee + 1, _batchNative);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_NATIVE_ERC20, _bridge, _amount, _messageFee, 0);

    // it should revert with InsufficientBalance for the token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice On a lower-decimals native ERC20 the message fee is native decimals while the spend is the native ERC20 decimals, so
  ///         the fee is reserved from the batch native before the conversion floors: an amount the batch's whole
  ///         tokens could cover alone is rejected once the fee is reserved from them.
  function test_BridgeTokenWhenALowerDecimalsMirrorSpendExceedsTheBatchNativeLessTheConvertedMessageFee(
    address _caller,
    address _recipientIca,
    uint256 _batchAmount,
    uint256 _messageFee,
    uint256 _amount,
    uint256 _strandedAmount
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` and its six-decimal scale for the batch.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _strandedAmount = bound(_strandedAmount, 1, type(uint64).max);
    _batchAmount = bound(_batchAmount, 1, type(uint64).max);
    uint256 _batchNative = _batchAmount * _NATIVE_ERC20_SCALE;
    _messageFee = bound(_messageFee, 1, _batchNative);
    // The resolution reserves the fee from the batch native before flooring to the native ERC20 decimals; on a whole-token
    // batch that costs `ceil(fee / scale)` raw units.
    uint256 _feeAmount = (_messageFee + _NATIVE_ERC20_SCALE - 1) / _NATIVE_ERC20_SCALE;
    // The amount fits the batch's raw units alone but not once the converted fee is reserved from them.
    _amount = bound(_amount, _batchAmount - _feeAmount + 1, _batchAmount);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _strandedAmount * _NATIVE_ERC20_SCALE);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_NATIVE_ERC20, _bridge, _amount, _messageFee, 0);

    // it should revert with InsufficientBalance for the token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice A message fee whose reservation consumes the whole batch native ERC20 balance floors the available balance to
  ///         zero instead of underflowing, so a full-pips spend resolves nothing and the command reports ZeroAmount.
  function test_BridgeTokenWhenAConvertedMessageFeeConsumesTheWholeBatchMirrorBalance(
    address _caller,
    address _recipientIca,
    uint256 _messageFee,
    uint256 _strandedAmount
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` and its six-decimal scale for the batch.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _strandedAmount = bound(_strandedAmount, 1, type(uint64).max);
    // Exactly one raw native ERC20 unit of batch native; any nonzero fee leaves less than one raw unit once
    // reserved, so the conversion floors the available balance to zero.
    uint256 _batchNative = _NATIVE_ERC20_SCALE;
    _messageFee = bound(_messageFee, 1, _batchNative);
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _strandedAmount * _NATIVE_ERC20_SCALE);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _NATIVE_ERC20,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      _messageFee,
      0,
      _emptyIcaConfig()
    );

    // it should revert with ZeroAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.ZeroAmount.selector);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice Pins the fee-guard equality edge: a message fee equal to the batch native passes the strictly-greater
  ///         guard and may commit the entire batch native, after which the reservation saturates the available native ERC20
  ///         balance to zero and the pips spend has nothing to resolve.
  function test_BridgeTokenWhenAPipsSpendMessageFeeEqualsTheBatchNative(
    address _caller,
    address _recipientIca,
    uint256 _batchNative,
    uint256 _pips,
    uint256 _stranded
  ) external givenTheTokenIsNotTheZeroAddress givenTheDestinationDomainIsRegistered givenTheBridgeManagesTheToken {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the spend resolution has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 1, type(uint128).max);
    _pips = bound(_pips, 1, MAX_PIPS);
    // The fee equals the batch native exactly: the strictly-greater guard passes, and the reservation leaves zero.
    uint256 _messageFee = _batchNative;
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _NATIVE_ERC20,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      0,
      _emptyIcaConfig()
    );

    // it should revert with ZeroAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.ZeroAmount.selector);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  modifier givenTheResolvedAmountIsPositive() {
    _;
  }

  function test_BridgeTokenWhenAPipsSpendNamesAMaxFeeAboveTheDenominator(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _pips,
    uint256 _maxFee,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _pips = bound(_pips, 1, MAX_PIPS);
    _balance = bound(_balance, MAX_PIPS, type(uint128).max);
    // A pips spend reads the max fee as pips too, so a value above the denominator is not a fraction.
    _maxFee = bound(_maxFee, MAX_PIPS + 1, type(uint256).max);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    // The pips guard trips after the recipient is derived, so the derivation is still reached on this revert path.
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      _maxFee,
      _emptyIcaConfig()
    );

    // it should revert with InvalidPips
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InvalidPips.selector, _maxFee));
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheQuotedTotalIsBelowTheAmount(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _total,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _amount = bound(_amount, 1, type(uint256).max);
    // No honest route quotes less than the amount, since the total covers the delivered amount itself.
    _total = bound(_total, 0, _amount - 1);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _amount);
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _total, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, type(uint256).max);

    // it should revert with InvalidBridgeQuote
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidBridgeQuote.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  modifier givenTheQuotedTotalCoversTheAmount() {
    _;
  }

  function test_BridgeTokenWhenTheTokenFeeExceedsTheMaxTokenFee(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _fee,
    uint256 _maxTokenFee,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The quoted total is the amount plus the fee, so the amount reserves headroom for a non-zero fee.
    _amount = bound(_amount, 1, type(uint256).max - 1);
    // The quoted fee lands strictly above the caller's accepted maximum.
    _fee = bound(_fee, 1, type(uint256).max - _amount);
    _maxTokenFee = bound(_maxTokenFee, 0, _fee - 1);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _amount);
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount + _fee, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, _maxTokenFee);

    // it should revert with TokenFeeExceedsMax
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.TokenFeeExceedsMax.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenAPipsSpendFeeExceedsTheMaxTokenFee(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _pips,
    uint256 _maxFeePips,
    uint256 _fee,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _pips = bound(_pips, 1, MAX_PIPS);
    _balance = bound(_balance, MAX_PIPS, type(uint128).max);
    uint256 _proportion = Math.mulDiv(_balance, _pips, MAX_PIPS);
    // A pips spend derives the max fee as pips of the resolved proportion, so the quoted fee lands strictly above that
    // derived cap rather than above an absolute figure.
    _maxFeePips = bound(_maxFeePips, 0, MAX_PIPS);
    uint256 _maxFee = Math.mulDiv(_proportion, _maxFeePips, MAX_PIPS, Math.Rounding.Ceil);
    _fee = bound(_fee, _maxFee + 1, type(uint256).max - _proportion);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _proportion, 0, _proportion + _fee, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      _maxFeePips,
      _emptyIcaConfig()
    );

    // it should revert with TokenFeeExceedsMax
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.TokenFeeExceedsMax.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenUsingAKnownCeilRoundedPipFeeAtTheMaximum()
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    address _caller = makeAddr('ceilBoundaryCaller');
    address _recipientIca = makeAddr('ceilBoundaryRecipient');
    address _token = _mockContract('ceilBoundaryToken');
    address _bridge = _mockContract('ceilBoundaryBridge');
    // One pip of 1_000_001 is 1.000001, so the caller's accepted ceiling is exactly 2 token units.
    uint256 _amount = 1_000_001;
    uint256 _fee = 2;
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount, uint256(0)]);
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount + _fee, 0);
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    _mockAndExpectWithValue(
      _bridge,
      0,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount - _fee)),
      abi.encode(bytes32(0))
    );
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      uint256(0),
      uint256(1),
      _emptyIcaConfig()
    );

    // it should accept the hand computed ceiling fee boundary
    vm.prank(_caller);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);
  }

  function test_BridgeTokenWhenUsingAKnownCeilRoundedPipFeeAboveTheMaximum()
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    address _caller = makeAddr('aboveCeilBoundaryCaller');
    address _recipientIca = makeAddr('aboveCeilBoundaryRecipient');
    address _token = _mockContract('aboveCeilBoundaryToken');
    address _bridge = _mockContract('aboveCeilBoundaryBridge');
    // The same hand-computed ceiling is 2, so a fee of 3 must be rejected.
    uint256 _amount = 1_000_001;
    uint256 _fee = 3;
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _amount);
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount + _fee, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      uint256(0),
      uint256(1),
      _emptyIcaConfig()
    );

    // it should revert with TokenFeeExceedsMax
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.TokenFeeExceedsMax.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp);
  }

  function test_BridgeTokenWhenTheTokenFeeConsumesTheWholeAmount(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _amount = bound(_amount, 1, type(uint256).max / 2);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _amount);
    _mockDerivedRecipient(_caller, _recipientIca);
    // A fee equal to the amount leaves nothing to deliver, so the bridge would be a no-op.
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount + _amount, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, type(uint256).max);

    // it should revert with TokenFeeExceedsAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.TokenFeeExceedsAmount.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenAPipsSpendFeeConsumesTheWholeAmount(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _pips,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _pips = bound(_pips, 1, MAX_PIPS);
    _balance = bound(_balance, MAX_PIPS, type(uint128).max);
    uint256 _proportion = Math.mulDiv(_balance, _pips, MAX_PIPS);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalance(_token, address(_metarouter), _balance);
    _mockDerivedRecipient(_caller, _recipientIca);
    // A full-pips cap equals the proportion, so a fee reaching it clears the cap yet consumes the whole amount.
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _proportion, 0, _proportion + _proportion, 0);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      MAX_PIPS,
      _emptyIcaConfig()
    );

    // it should revert with TokenFeeExceedsAmount
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.TokenFeeExceedsAmount.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheRouteChargesNoFee(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _remainder,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The router held the amount plus the remainder before the bridge pulled the amount, so the two share the range.
    _amount = bound(_amount, 1, type(uint256).max - 1);
    _remainder = bound(_remainder, 1, type(uint256).max - _amount);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    // resolveSpend reads the balance, then closure re-reads it after the bridge consumed the amount.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount + _remainder, _remainder]);
    // it should derive _recipient from the interchain account router with the logical sender as salt
    _mockDerivedRecipient(_caller, _recipientIca);
    // A fee-less quote charges exactly the amount, so the whole amount is delivered.
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount, 0);
    // it should approve _bridge for the resolved amount
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the whole amount forwarding _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount)),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));
    // it should track _token (the unbridged remainder is returned to the caller at closure)
    _mockAndExpectTokenTransfer(_token, _caller, _remainder);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, 0);

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheSpendSelectsAPipsProportion(
    address _caller,
    address _recipientIca,
    uint256 _balance,
    uint256 _pips,
    uint256 _maxFeePips,
    uint256 _fee,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // Bound so the pip spend resolves to a positive proportion strictly below the balance, leaving a remainder. This
    // is the swap-then-bridge-everything shape: the proportion is only known once the balance is read on chain.
    _pips = bound(_pips, 1, MAX_PIPS - 1);
    // Two whole pips of balance so the proportion is at least two, leaving room for a fee below it.
    _balance = bound(_balance, 2 * MAX_PIPS, type(uint128).max);
    uint256 _proportion = Math.mulDiv(_balance, _pips, MAX_PIPS);
    // A pips spend reads the max fee as pips of the resolved proportion, so the quoted fee is bounded by that share
    // rather than by an absolute figure the batch could not have known.
    _maxFeePips = bound(_maxFeePips, 1, MAX_PIPS);
    uint256 _maxFee = Math.mulDiv(_proportion, _maxFeePips, MAX_PIPS, Math.Rounding.Ceil);
    _fee = bound(_fee, 1, Math.min(_maxFee, _proportion - 1));
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    // resolveSpend reads the balance, then closure re-reads it after the bridge consumed the resolved proportion.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_balance, _balance - _proportion]);
    // it should derive _recipient from the interchain account router with the logical sender as salt
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _proportion, 0, _proportion + _fee, 0);
    // it should approve _bridge for the resolved proportion
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _proportion)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the proportion less the quoted fee forwarding
    // _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(
        ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _proportion - _fee)
      ),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));
    // it should track _token (the unbridged remainder is returned to the caller at closure)
    _mockAndExpectTokenTransfer(_token, _caller, _balance - _proportion);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
      _messageFee,
      _maxFeePips,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  /// @notice A full-pips spend of the native ERC20 resolves against the batch native with the message fee
  ///         already reserved, pinning the router's own fee reservation and refund accounting. The mocked bridge
  ///         pulls none of the approved amount, so the whole un-pulled budget remains batch native and returns
  ///         through the closure refund; the end state with a pulling Warp Route is integration-test territory.
  function test_BridgeTokenWhenAFullPipsSpendSelectsTheNativeMirrorToken(
    address _caller,
    address _recipientIca,
    uint256 _batchNative,
    uint256 _messageFee,
    uint256 _stranded
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the spend resolution has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 2, type(uint128).max);
    // The fee leaves at least one unit for the spend to resolve, so the resolved amount stays positive.
    _messageFee = bound(_messageFee, 1, _batchNative - 1);
    uint256 _reduced = _batchNative - _messageFee;
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.
    // it should resolve the batch native less the message fee
    // A fee-less quote charges exactly the reduced amount, so the whole reduced amount is delivered.
    _mockQuote(_bridge, _NATIVE_ERC20, bytes32(uint256(uint160(_recipientIca))), _reduced, 0, _reduced, 0);
    // it should approve _bridge for the reduced amount
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_bridge, _reduced)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the reduced amount less the quoted fee forwarding
    // _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _reduced)),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _NATIVE_ERC20,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      _messageFee,
      0,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );

    // it should refund the unresolved batch native to the caller at closure
    // The mocked bridge pulls none of the approved `_reduced`, so that whole un-pulled budget remains batch native
    // and returns through the closure refund; a pulling Warp Route's end state is integration-test territory.
    assertEq(_caller.balance, _reduced, 'caller should receive the batch native remaining after the message fee');
    assertEq(address(_nativeErc20Metarouter).balance, _stranded, 'the stranded pre-batch native should stay put');
  }

  /// @notice Pins the inclusive Amount boundary of the native ERC20 resolution: a spend exactly equal to the fee-reserved
  ///         batch balance passes the strictly-greater balance check and bridges, rather than reverting.
  function test_BridgeTokenWhenAMirrorAmountSpendEqualsTheBatchNativeLessTheMessageFee(
    address _caller,
    address _recipientIca,
    uint256 _batchNative,
    uint256 _messageFee,
    uint256 _stranded
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the spend resolution has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 2, type(uint128).max);
    // The fee leaves at least one unit for the spend, which takes exactly the fee-reserved batch balance.
    _messageFee = bound(_messageFee, 1, _batchNative - 1);
    uint256 _amount = _batchNative - _messageFee;
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_NATIVE_ERC20));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.
    // it should resolve the spend at the fee reserved batch balance
    // A fee-less quote charges exactly the amount, so the whole amount is delivered.
    _mockQuote(_bridge, _NATIVE_ERC20, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount, 0);
    // it should approve _bridge for the amount
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the amount forwarding _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount)),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_NATIVE_ERC20, _bridge, _amount, _messageFee, 0);

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );

    // it should refund the unpulled batch native to the caller at closure
    // The mocked bridge pulls none of the approved amount, so beyond the message fee no native moves and the whole
    // budget returns through the closure refund; a pulling Warp Route's end state is integration-test territory.
    assertEq(_caller.balance, _amount, 'caller should receive the batch native remaining after the message fee');
    assertEq(address(_nativeErc20Metarouter).balance, _stranded, 'the stranded pre-batch native should stay put');
  }

  /// @notice Complements the mocked-bridge native ERC20 tests with a route that does pull: the probe consumes the approved
  ///         amount as native, so the caller gets no closing refund, the pre-batch balance stays put, and the batch
  ///         still closes cleanly.
  function test_BridgeTokenWhenTheBridgePullsTheApprovedMirrorAmount(
    address _caller,
    address _recipientIca,
    uint256 _batchNative,
    uint256 _messageFee,
    uint256 _stranded
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the spend resolution has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 2, type(uint128).max);
    // The fee leaves at least one unit for the spend to resolve, so the resolved amount stays positive.
    _messageFee = bound(_messageFee, 1, _batchNative - 1);
    uint256 _reduced = _batchNative - _messageFee;
    // The probe emulates an ERC20-collateral route: settling the transfer moves the pulled amount of native out of
    // the router, as the native ERC20's `transferFrom` would on a real deployment.
    WarpRoutePullProbe _bridge = new WarpRoutePullProbe(_NATIVE_ERC20, 1);
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (address(_bridge), _reduced)), abi.encode(true));
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (address(_bridge), 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _NATIVE_ERC20,
      address(_bridge),
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      _messageFee,
      0,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );

    // it should call transferRemote on the bridge with the resolved amount forwarding _messageFee
    assertEq(_bridge.transferRemoteCalls(), 1);
    assertEq(_bridge.lastAmount(), _reduced);
    assertEq(_bridge.lastValue(), _messageFee);
    // it should leave no closing refund for the caller
    assertEq(_caller.balance, 0, 'the pulled budget leaves no batch native to refund');
    // it should leave the pre batch native with the router at closure
    assertEq(address(_nativeErc20Metarouter).balance, _stranded, 'the stranded pre-batch native should stay put');
  }

  /// @notice Composes the pulling route with the six-decimal native ERC20 and a sub-token remainder on every quantity: the
  ///         pre-batch native, the batch native and the message fee each carry one. The bridge can only take whole
  ///         raw native ERC20 units, so the fee reservation and the conversion flooring both leave native behind, and the
  ///         caller gets exactly that back while the stranded remainder never moves.
  function test_BridgeTokenWhenTheBridgePullsTheApprovedSixDecimalMirrorAmount(
    address _caller,
    address _recipientIca,
    uint256 _strandedWhole,
    uint256 _strandedRemainder,
    uint256 _batchWhole,
    uint256 _batchRemainder,
    uint256 _feeWhole,
    uint256 _feeRemainder
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    // The caller receives a nonzero closure refund here, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` and its six-decimal scale for the batch.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    NativeErc20PullNative memory _native =
      _boundSixDecimalPull(_strandedWhole, _strandedRemainder, _batchWhole, _batchRemainder, _feeWhole, _feeRemainder);
    // The fee is reserved from the batch native before the conversion floors it to raw native ERC20 units.
    uint256 _pulled = (_native.batchNative - _native.messageFee) / _NATIVE_ERC20_SCALE;
    // The probe emulates an ERC20-collateral route: settling the transfer moves the pulled amount, scaled back to
    // native, out of the router, as the six-decimal native ERC20's `transferFrom` would on a real deployment.
    WarpRoutePullProbe _bridge = new WarpRoutePullProbe(_NATIVE_ERC20, _NATIVE_ERC20_SCALE);
    vm.deal(_caller, _native.batchNative);
    vm.deal(address(_nativeErc20Metarouter), _native.stranded);

    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_nativeErc20Metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (address(_bridge), _pulled)), abi.encode(true));
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (address(_bridge), 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInputWithConfig(
      _NATIVE_ERC20,
      address(_bridge),
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
      _native.messageFee,
      0,
      _emptyIcaConfig()
    );

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _native.batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );

    // it should call transferRemote on the bridge with the converted raw unit amount forwarding _messageFee
    assertEq(_bridge.transferRemoteCalls(), 1);
    assertEq(_bridge.lastAmount(), _pulled);
    assertEq(_bridge.lastValue(), _native.messageFee);
    // it should refund the fee reservation and flooring remainders to the caller at closure
    assertEq(
      _caller.balance,
      _native.batchNative - _native.messageFee - _pulled * _NATIVE_ERC20_SCALE,
      'caller should receive the batch native the raw unit pull could not express'
    );
    // it should leave the fractional pre batch native with the router at closure
    assertEq(address(_nativeErc20Metarouter).balance, _native.stranded, 'the stranded pre-batch native should stay put');
  }

  function test_BridgeTokenWhenTheRouteChargesAFeeWithinTheMaximum(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _fee,
    uint256 _remainder,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The quote is the amount plus the fee, and the router held the amount plus the remainder, so the three share the
    // range; the fee must leave something to deliver.
    _amount = bound(_amount, 2, type(uint256).max / 3);
    _fee = bound(_fee, 1, _amount - 1);
    _remainder = bound(_remainder, 1, type(uint256).max / 3);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount + _remainder, _remainder]);
    // it should derive _recipient from the interchain account router with the logical sender as salt
    _mockDerivedRecipient(_caller, _recipientIca);
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, 0, _amount + _fee, 0);
    // it should approve _bridge for the resolved amount
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the amount less the quoted fee forwarding
    // _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount - _fee)),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));
    // it should track _token (the unbridged remainder is returned to the caller at closure)
    _mockAndExpectTokenTransfer(_token, _caller, _remainder);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, _fee);

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  function test_BridgeTokenWhenTheQuoteSpreadsTheTokenTotalAcrossEntries(
    address _caller,
    address _recipientIca,
    uint256 _amount,
    uint256 _externalFee,
    uint256 _nativeGasFee,
    uint256 _messageFee
  )
    external
    givenTheTokenIsNotTheZeroAddress
    givenTheDestinationDomainIsRegistered
    givenTheBridgeManagesTheToken
    givenTheResolvedAmountIsPositive
    givenTheQuotedTotalCoversTheAmount
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The token total sums the amount and the external fee, which must leave something to deliver.
    _amount = bound(_amount, 2, type(uint256).max / 2);
    _externalFee = bound(_externalFee, 1, _amount - 1);
    // A non-zero native gas entry must not reach the token total, so it spans the full range independently.
    _nativeGasFee = bound(_nativeGasFee, 1, type(uint256).max);
    address _token = _mockContract('token');
    address _bridge = _mockContract('bridge');
    vm.deal(_caller, _messageFee);

    _mockAndExpect(_bridge, abi.encodeCall(ITokenRouter.token, ()), abi.encode(_token));
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount, 0]);
    // it should derive _recipient from the interchain account router with the logical sender as salt
    _mockDerivedRecipient(_caller, _recipientIca);
    // The token total spans the second and third entries while the first is denominated in native.
    _mockQuote(_bridge, _token, bytes32(uint256(uint160(_recipientIca))), _amount, _nativeGasFee, _amount, _externalFee);
    // it should approve _bridge for the resolved amount
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, _amount)), abi.encode(true));
    // it should call transferRemote on _bridge with _recipient and the amount less the summed fee ignoring entries in
    // other denominations forwarding _messageFee
    _mockAndExpectWithValue(
      _bridge,
      _messageFee,
      abi.encodeCall(
        ITokenRouter.transferRemote, (_DOMAIN, bytes32(uint256(uint160(_recipientIca))), _amount - _externalFee)
      ),
      abi.encode(bytes32(0))
    );
    // it should clear the _bridge approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_bridge, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _bridgeInput(_token, _bridge, _amount, _messageFee, _externalFee);

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.BRIDGE_TOKEN))), _inputs, block.timestamp
    );
  }

  // --- executeCrosschain ---

  function test_ExecuteCrosschainGivenALiteDeploymentWithNoInterchainAccountRouter(address _caller) external {
    _assumeFuzzable(_caller);
    // A lite deployment carries no cross-chain layer, so its `ICA_ROUTER` is zero and the command is gated off.
    MetarouterHarness _liteMetarouter = _deployLiteMetarouter();
    _caller = _boundNotEq(_caller, address(_liteMetarouter));

    // The guard is the first statement of the branch, so the input is never decoded and no collaborator is reached.
    bytes[] memory _inputs = new bytes[](1);

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.EXECUTE_CROSS_CHAIN));
    _liteMetarouter.execute(abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp);
  }

  /// @notice A dispatch fee above the native the batch introduced is rejected up front, even when the router holds
  ///         enough pre-batch native to cover it.
  function test_ExecuteCrosschainWhenTheMessageFeeExceedsTheAvailableNativeBalance(
    address _caller,
    bytes32 _commitment,
    uint256 _batchNative,
    uint256 _excess,
    uint256 _stranded
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _batchNative = bound(_batchNative, 0, type(uint256).max - 1);
    _excess = bound(_excess, 1, type(uint256).max - _batchNative);
    // The router already holds enough to cover the excess, capped so the incoming value cannot overflow its balance.
    _stranded = bound(_stranded, _excess, type(uint256).max - _batchNative);
    uint256 _messageFee = _batchNative + _excess;
    vm.deal(_caller, _batchNative);
    vm.deal(address(_metarouter), _stranded);

    // The guard precedes every collaborator read, so the domain is never resolved.
    vm.mockCallRevert(
      _ICA_ROUTER,
      abi.encodeWithSelector(IInterchainAccountRouter.routers.selector),
      'fee check must precede the domain read'
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, address(0), '', _emptyIcaConfig());

    // it should revert with InsufficientBalance for the native asset
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, address(0)));
    _metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheInterchainAccountConfigurationNamesAnISMWithoutARouter(
    address _caller,
    address _ism
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_ism);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(
      _DOMAIN,
      bytes32(0),
      uint256(0),
      uint256(0),
      address(0),
      bytes(''),
      IMetarouter.IcaConfig({router: address(0), ism: _ism})
    );

    // it should revert with InvalidInterchainAccountConfig
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidInterchainAccountConfig.selector);
    _metarouter.execute(abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp);
  }

  function test_ExecuteCrosschainWhenACustomInterchainAccountConfigurationUsesTheZeroISM(
    address _caller,
    address _router,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_router);
    vm.deal(_caller, _messageFee);
    bytes memory _hookMetadata = abi.encodePacked(uint16(1), _msgValue, _gasLimit, _caller);
    IMetarouter.IcaConfig memory _icaConfig = IMetarouter.IcaConfig({router: _router, ism: address(0)});

    // it should dispatch with the custom router and zero ISM
    _mockCommitRevealWithConfig(
      _hookMetadata, _hook, _caller, _commitment, _messageFee, bytes32(uint256(uint160(_router))), bytes32(0)
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, uint256(0), _hook, _hookMetadata, _icaConfig);

    // it should not read the enrolled router or ISM
    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenACustomInterchainAccountConfigurationUsesANonzeroISM(
    address _caller,
    address _router,
    address _ism,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _assumeFuzzable(_router);
    _assumeFuzzable(_ism);
    vm.deal(_caller, _messageFee);
    bytes memory _hookMetadata = abi.encodePacked(uint16(1), _msgValue, _gasLimit, _caller);
    IMetarouter.IcaConfig memory _icaConfig = IMetarouter.IcaConfig({router: _router, ism: _ism});

    // it should dispatch with the custom router and ISM
    _mockCommitRevealWithConfig(
      _hookMetadata,
      _hook,
      _caller,
      _commitment,
      _messageFee,
      bytes32(uint256(uint160(_router))),
      bytes32(uint256(uint160(_ism)))
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, uint256(0), _hook, _hookMetadata, _icaConfig);

    // it should not read the enrolled router or ISM
    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheDestinationDomainIsNotRegistered(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook
  ) external {
    _assumeFuzzable(_caller);
    vm.deal(_caller, _messageFee);

    // An unregistered destination domain has no enrolled router, so the handler reverts before dispatching.
    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.routers, (_DOMAIN)), abi.encode(bytes32(0)));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, _hook, '', _emptyIcaConfig());

    // it should revert with UnregisteredDomain
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.UnregisteredDomain.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheHookMetadataIsShorterThanTheRefundOffset(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _length
  ) external givenTheDestinationDomainIsRegistered {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // Any length below the refund-address offset lacks a refund target; the guard rejects it before dispatching.
    _length = bound(_length, 0, _HOOK_METADATA_PREFIX_LENGTH - 1);
    vm.deal(_caller, _messageFee);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, _hook, new bytes(_length), _emptyIcaConfig());

    // it should revert with InvalidHookMetadata
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidHookMetadata.selector);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  modifier givenTheHookMetadataCarriesARefundAddress() {
    _;
  }

  function test_ExecuteCrosschainWhenTheHookMetadataStopsBeforeTheFeeTokenField(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    vm.deal(_caller, _messageFee);
    // Exactly the refund-bearing length: the metadata ends where the fee-token field would start, so the dispatch is
    // paid in native and no token is approved or tracked.
    bytes memory _hookMetadata = abi.encodePacked(uint16(1), _msgValue, _gasLimit, _caller);

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // it should call callRemoteCommitReveal with _commitment and the logical sender as salt forwarding _messageFee
    _mockCommitReveal(_hookMetadata, _hook, _caller, _commitment, _messageFee);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, _hook, _hookMetadata, _emptyIcaConfig());

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheHookMetadataNamesTheZeroAddressAsFeeToken(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit,
    bytes calldata _customMetadata
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    vm.deal(_caller, _messageFee);
    // The fee-token field is present but zero, which denotes native, so no token is approved or tracked.
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, address(0), _customMetadata);

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // it should call callRemoteCommitReveal with _commitment and the logical sender as salt forwarding _messageFee
    _mockCommitReveal(_hookMetadata, _hook, _caller, _commitment, _messageFee);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, _hook, _hookMetadata, _emptyIcaConfig());

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheHookMetadataNamesAFeeToken(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _tokenFee,
    uint256 _remainder,
    uint256 _msgValue,
    uint256 _gasLimit,
    bytes calldata _customMetadata
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _tokenFee = bound(_tokenFee, 1, type(uint256).max);
    _remainder = bound(_remainder, 1, type(uint256).max);
    address _token = _mockContract('feeToken');
    vm.deal(_caller, _messageFee);
    // The metadata names the fee token, so the handler reads it from there rather than from a separate input. The
    // fuzzed custom tail follows the field, proving it does not shift the read.
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, _token, _customMetadata);

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // it should approve the interchain account router for _tokenFee
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_ICA_ROUTER, _tokenFee)), abi.encode(true));
    // it should call callRemoteCommitReveal with _commitment and the logical sender as salt forwarding _messageFee
    _mockCommitReveal(_hookMetadata, _hook, _caller, _commitment, _messageFee);
    // it should clear the metadata fee token approval
    _mockAndExpect(_token, abi.encodeCall(IERC20.approve, (_ICA_ROUTER, 0)), abi.encode(true));
    // it should track the metadata fee token (the unconsumed fee returns to the caller at closure)
    _mockAndExpectTokenBalance(_token, address(_metarouter), _remainder);
    _mockAndExpectTokenTransfer(_token, _caller, _remainder);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, _tokenFee, _hook, _hookMetadata, _emptyIcaConfig());

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  /// @notice A native ERC20 fee grant is bounded by the batch native remaining after the message fee commits: the
  ///         fee hook pulls that same native through the ERC20 entry point, so a larger grant could spend the
  ///         pre-batch balance the router holds. The command is rejected before the approval even though the
  ///         stranded balance could cover the fee.
  function test_ExecuteCrosschainWhenTheHookMetadataNamesTheNativeMirrorTokenBeyondTheBatchNative(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    uint256 _batchNative,
    uint256 _tokenFee,
    uint256 _stranded,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the fee-token bound has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 0, type(uint128).max);
    _messageFee = bound(_messageFee, 0, _batchNative);
    // The grant exceeds what the batch native can still cover once the message fee commits.
    _tokenFee = bound(_tokenFee, _batchNative - _messageFee + 1, type(uint256).max);
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, _NATIVE_ERC20, '');

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, _tokenFee, _hook, _hookMetadata, _emptyIcaConfig());

    // it should revert with InsufficientBalance for the fee token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  /// @notice Pins the inclusive boundary of the native ERC20 fee-grant guard: a grant exactly equal to the
  ///         fee-reserved batch balance passes the strictly-greater check and reaches the ICA dispatch.
  function test_ExecuteCrosschainWhenTheNativeMirrorFeeGrantEqualsTheBatchNativeLessTheMessageFee(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    uint256 _batchNative,
    uint256 _stranded,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    // The caller receives the closure refund, so it must be a code-less account that accepts ETH.
    vm.assume(_caller.code.length == 0);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` for the batch, so the fee-token bound has a native ERC20 to match.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint128).max);
    _batchNative = bound(_batchNative, 2, type(uint128).max);
    // The fee leaves at least one unit for the grant, which takes exactly the fee-reserved batch balance.
    _messageFee = bound(_messageFee, 1, _batchNative - 1);
    uint256 _tokenFee = _batchNative - _messageFee;
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, _NATIVE_ERC20, '');

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // The native ERC20 fee-grant bound reads only the router's native balance; the native ERC20's `balanceOf` is never called.
    // it should approve the interchain account router for the fee grant
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_ICA_ROUTER, _tokenFee)), abi.encode(true));
    // it should call callRemoteCommitReveal with _commitment and the logical sender as salt forwarding _messageFee
    _mockCommitReveal(_hookMetadata, _hook, _caller, _commitment, _messageFee);
    // it should clear the metadata fee token approval
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20.approve, (_ICA_ROUTER, 0)), abi.encode(true));

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, _tokenFee, _hook, _hookMetadata, _emptyIcaConfig());

    vm.prank(_caller);
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );

    // it should leave the stranded pre batch native with the router at closure
    // The mocked ICA router pulls none of the granted native ERC20 value, so the batch native beyond the message fee
    // returns through the closure refund and only the stranded pre-batch balance stays with the router.
    assertEq(address(_nativeErc20Metarouter).balance, _stranded, 'the stranded pre-batch native should stay put');
  }

  /// @notice On a lower-decimals native ERC20 the fee grant is in the native ERC20 decimals while the message fee is native, so
  ///         the bound reserves the fee from the batch native before flooring to the native ERC20 decimals: a grant the
  ///         batch's whole units could cover alone is rejected once the message fee is reserved from them.
  function test_ExecuteCrosschainWhenTheHookMetadataNamesALowerDecimalsMirrorBeyondTheConvertedBatchNative(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    uint256 _batchAmount,
    uint256 _tokenFee,
    uint256 _strandedAmount,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    // The native ERC20 deployment publishes `_NATIVE_ERC20` and its six-decimal scale for the batch.
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20_DECIMALS);
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _strandedAmount = bound(_strandedAmount, 1, type(uint64).max);
    _batchAmount = bound(_batchAmount, 0, type(uint64).max);
    uint256 _batchNative = _batchAmount * _NATIVE_ERC20_SCALE;
    _messageFee = bound(_messageFee, 0, _batchNative);
    {
      // The bound reserves the fee from the batch native before flooring to the native ERC20 decimals; on a whole-token
      // batch that costs `ceil(fee / scale)` raw units, saturated at the raw units.
      uint256 _feeAmount = (_messageFee + _NATIVE_ERC20_SCALE - 1) / _NATIVE_ERC20_SCALE;
      // The grant exceeds what the batch's raw units can still cover once the converted fee is reserved.
      _tokenFee = bound(_tokenFee, (_batchAmount > _feeAmount ? _batchAmount - _feeAmount : 0) + 1, type(uint128).max);
    }
    vm.deal(_caller, _batchNative);
    vm.deal(address(_nativeErc20Metarouter), _strandedAmount * _NATIVE_ERC20_SCALE);
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, _NATIVE_ERC20, '');

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // The native ERC20 resolution reads only the router's native balance; the native ERC20's `balanceOf` is never called.

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, _tokenFee, _hook, _hookMetadata, _emptyIcaConfig());

    // it should revert with InsufficientBalance for the fee token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(
      abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN))), _inputs, block.timestamp
    );
  }

  function test_ExecuteCrosschainWhenTheCommandAllowsRevert(
    address _caller,
    bytes32 _commitment,
    uint256 _messageFee,
    address _hook,
    uint256 _msgValue,
    uint256 _gasLimit
  ) external givenTheDestinationDomainIsRegistered givenTheHookMetadataCarriesARefundAddress {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    vm.deal(_caller, _messageFee);
    bytes memory _hookMetadata = _hookMetadataWithFeeToken(_msgValue, _gasLimit, _caller, address(0), '');

    _mockAndExpect(_ICA_ROUTER, abi.encodeCall(IInterchainAccountRouter.isms, (_DOMAIN)), abi.encode(_REMOTE_ISM));
    // it should call callRemoteCommitReveal with the logical sender as salt from the self called child frame
    _mockCommitReveal(_hookMetadata, _hook, _caller, _commitment, _messageFee);

    // The allow-revert flag routes the command through a self-called child frame; `msgSender()` must still resolve to
    // the original caller, so the dispatch salt is the caller.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.EXECUTE_CROSS_CHAIN)) | Commands.FLAG_ALLOW_REVERT);
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = _executeInputWithConfig(_DOMAIN, _commitment, _messageFee, 0, _hook, _hookMetadata, _emptyIcaConfig());

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(_commands, _inputs, block.timestamp);
  }

  // --- redeem ---

  /// @notice A lite deployment carries no voting system, so the command is gated off before its handler runs.
  function test_RedeemWhenTheDeploymentHasNoLeafVoter(address _caller) external {
    _assumeFuzzable(_caller);
    MetarouterHarness _liteMetarouter = _deployLiteMetarouter();

    // The guard is the first statement of the branch, so the input is never decoded and no collaborator is reached.
    bytes[] memory _inputs = new bytes[](1);

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.REDEEM));
    _liteMetarouter.execute(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);
  }

  /// @notice Naming this router as the root recipient is rejected: on other commands that address means "keep it in
  ///         custody", but here it would mint `TOKEN` to whatever holds that address on root, where any caller can
  ///         sweep a Metarouter's idle balance.
  function test_RedeemWhenTheRecipientIsTheMetarouter(
    address _caller,
    uint256 _amount,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // The guard precedes every collaborator read, so the receipt balance is never read.
    vm.mockCallRevert(
      _EMISSION_TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector), 'recipient check must precede the spend read'
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
        payerIsUser: false,
        recipient: address(_metarouter),
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);
  }

  /// @notice A fee above the native the batch introduced is rejected up front, even when the router holds enough
  ///         pre-batch native to pay it, so a redeem never transiently spends native the batch does not own.
  function test_RedeemWhenTheMessageFeeExceedsTheAvailableNativeBalance(
    address _caller,
    address _recipient,
    address _refundRecipient,
    uint256 _batchNative,
    uint256 _excess,
    uint256 _stranded,
    uint256 _amount,
    uint256 _gasLimit
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _batchNative = bound(_batchNative, 0, type(uint256).max - 1);
    _excess = bound(_excess, 1, type(uint256).max - _batchNative);
    // The router already holds enough to cover the excess, so only the guard stops the fee from reaching it. Capped so
    // the incoming value cannot overflow the router's balance.
    _stranded = bound(_stranded, _excess, type(uint256).max - _batchNative);
    uint256 _messageFee = _batchNative + _excess;
    vm.deal(_caller, _batchNative);
    vm.deal(address(_metarouter), _stranded);

    // The guard precedes the spend resolution, so the receipt balance is never read.
    vm.mockCallRevert(
      _EMISSION_TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector), 'fee check must precede the spend read'
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
        payerIsUser: false,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: _refundRecipient,
        messageFee: _messageFee
      })
    );

    // it should revert with InsufficientBalance for the native asset
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, address(0)));
    _metarouter.execute{value: _batchNative}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);
  }

  /// @notice A wallet-funded redeem accepts only an exact amount, since a percentage of a wallet has no meaning to the
  ///         pull.
  function test_RedeemWhenThePayerIsTheUserAndTheSpendModeIsPips(
    address _caller,
    address _recipient,
    uint256 _pips,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _pips = bound(_pips, 1, MAX_PIPS);
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
        payerIsUser: true,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    // it should revert with InvalidSpendMode
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidSpendMode.selector);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);
  }

  /// @notice A user who pre-approved the router redeems straight from their wallet in one command. The burn takes the
  ///         measured delta, not the requested value, which is what keeps a fee-on-transfer receipt usable.
  function test_RedeemWhenThePayerIsTheUserAndTheSpendModeIsAnAmount(
    address _caller,
    address _recipient,
    uint256 _spendValue,
    uint256 _received,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _spendValue = bound(_spendValue, _MIN_REDEEM_AMOUNT, type(uint256).max);
    _received = bound(_received, _MIN_REDEEM_AMOUNT, _spendValue);
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // Balances are read three times: before the pull, after it to measure the delta, and once at closure. The pull
    // tracks the receipt, so the closing read returns zero and no sweep transfer runs.
    uint256[] memory _balances = new uint256[](3);
    _balances[1] = _received;
    _mockAndExpectTokenBalances(_EMISSION_TOKEN, address(_metarouter), _balances);
    // it should pull the amount from the logical sender
    _mockAndExpect(
      _EMISSION_TOKEN,
      abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _spendValue)),
      abi.encode(true)
    );
    // it should call redeem on the leaf voter with the measured delta
    _mockAndExpectWithValue(
      _VOTER,
      _messageFee,
      abi.encodeCall(ILeafVoter.redeem, (_received, _recipient, _gasLimit, address(_metarouter))),
      ''
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _spendValue}),
        payerIsUser: true,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);

    _assertTransientCleared(_EMISSION_TOKEN);
  }

  /// @notice An absolute spend burns exactly that much held receipt through the voter and forwards the message fee,
  ///         leaving the rest of the balance to the closing sweep.
  function test_RedeemWhenThePayerIsInternalAndTheSpendModeIsAnAmount(
    address _caller,
    address _recipient,
    uint256 _amount,
    uint256 _remainder,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // The router held the amount plus the remainder before the voter burned the amount, so the two share the range.
    _amount = bound(_amount, _MIN_REDEEM_AMOUNT, type(uint256).max - 1);
    _remainder = bound(_remainder, 1, type(uint256).max - _amount);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // it should track the receipt token
    // resolveSpend reads the balance, then closure re-reads it after the voter burned the amount.
    _mockAndExpectTokenBalancesTwice(_EMISSION_TOKEN, address(_metarouter), [_amount + _remainder, _remainder]);
    // it should call redeem on the leaf voter with the amount _recipient and _gasLimit forwarding _messageFee
    // it should name itself as the refund recipient
    _mockAndExpectWithValue(
      _VOTER, _messageFee, abi.encodeCall(ILeafVoter.redeem, (_amount, _recipient, _gasLimit, address(_metarouter))), ''
    );
    // it should return the unredeemed receipt balance to the caller at closure
    _mockAndExpectTokenTransfer(_EMISSION_TOKEN, _caller, _remainder);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
        payerIsUser: false,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_EMISSION_TOKEN);
  }

  /// @notice A pips spend resolves the amount from the balance the batch actually holds: the redeem-what-a-claim-just
  ///         -produced shape, where the amount is only known once the balance is read on chain.
  function test_RedeemWhenThePayerIsInternalAndTheSpendModeIsPips(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _pips,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // A whole pip of balance and a proportion below the denominator, so the resolved amount is positive and leaves a
    // remainder behind.
    _pips = bound(_pips, 1, MAX_PIPS - 1);
    uint256 _minimumBalance = Math.ceilDiv(_MIN_REDEEM_AMOUNT * MAX_PIPS, _pips);
    _balance = bound(_balance, _minimumBalance, type(uint256).max);
    uint256 _proportion = Math.mulDiv(_balance, _pips, MAX_PIPS);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // it should track the receipt token
    // resolveSpend reads the balance, then closure re-reads it after the voter burned the resolved proportion.
    _mockAndExpectTokenBalancesTwice(_EMISSION_TOKEN, address(_metarouter), [_balance, _balance - _proportion]);
    // it should call redeem on the leaf voter with the resolved proportion _recipient and _gasLimit forwarding
    // _messageFee
    _mockAndExpectWithValue(
      _VOTER,
      _messageFee,
      abi.encodeCall(ILeafVoter.redeem, (_proportion, _recipient, _gasLimit, address(_metarouter))),
      ''
    );
    // it should return the unredeemed receipt balance to the caller at closure
    _mockAndExpectTokenTransfer(_EMISSION_TOKEN, _caller, _balance - _proportion);

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: _pips}),
        payerIsUser: false,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_EMISSION_TOKEN);
  }

  /// @notice A full-balance spend leaves nothing behind: the closing sweep reads a zero balance and must skip the
  ///         transfer entirely, while the tracked flag still clears.
  function test_RedeemWhenThePayerIsInternalAndTheSpendConsumesTheWholeReceiptBalance(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _balance = bound(_balance, _MIN_REDEEM_AMOUNT, type(uint256).max);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // resolveSpend reads the full balance, then closure re-reads it as zero after the voter burned everything.
    _mockAndExpectTokenBalancesTwice(_EMISSION_TOKEN, address(_metarouter), [_balance, 0]);
    // it should call redeem on the leaf voter with the full balance
    _mockAndExpectWithValue(
      _VOTER,
      _messageFee,
      abi.encodeCall(ILeafVoter.redeem, (_balance, _recipient, _gasLimit, address(_metarouter))),
      ''
    );
    // it should not transfer the receipt token at closure
    vm.mockCallRevert(
      _EMISSION_TOKEN, abi.encodeWithSelector(IERC20.transfer.selector), 'sweep must skip a zero balance'
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Pips, value: MAX_PIPS}),
        payerIsUser: false,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: address(0),
        messageFee: _messageFee
      })
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);

    // it should clear the transient execution slots at closure
    _assertTransientCleared(_EMISSION_TOKEN);
  }

  /// @notice A named refund recipient reaches the voter verbatim, so a caller that cannot receive native can keep the
  ///         transport's excess out of the batch and away from the closing refund.
  function test_RedeemWhenTheRefundRecipientIsNotTheZeroAddress(
    address _caller,
    address _recipient,
    address _refundRecipient,
    uint256 _amount,
    uint256 _gasLimit,
    uint256 _messageFee
  ) external {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _assumeFuzzable(_refundRecipient);
    _amount = bound(_amount, _MIN_REDEEM_AMOUNT, type(uint256).max);
    _gasLimit = bound(_gasLimit, 1, type(uint256).max);
    vm.deal(_caller, _messageFee);

    // The spend takes the whole balance, so closure re-reads zero and sweeps nothing.
    _mockAndExpectTokenBalancesTwice(_EMISSION_TOKEN, address(_metarouter), [_amount, 0]);
    // it should call redeem on the leaf voter with the supplied refund recipient
    _mockAndExpectWithValue(
      _VOTER, _messageFee, abi.encodeCall(ILeafVoter.redeem, (_amount, _recipient, _gasLimit, _refundRecipient)), ''
    );

    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.RedeemParams({
        spend: IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
        payerIsUser: false,
        recipient: _recipient,
        gasLimit: _gasLimit,
        refundRecipient: _refundRecipient,
        messageFee: _messageFee
      })
    );

    vm.prank(_caller);
    _metarouter.execute{value: _messageFee}(abi.encodePacked(bytes1(uint8(Commands.REDEEM))), _inputs, block.timestamp);
  }

  // --- helpers ---

  /// @notice ABI-encodes a `BRIDGE_TOKEN` input for `_DOMAIN` with an `Amount` spend of `_amount`.
  function _bridgeInput(
    address _token,
    address _bridge,
    uint256 _amount,
    uint256 _messageFee,
    uint256 _maxTokenFee
  ) private pure returns (bytes memory _input) {
    return _bridgeInputWithConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      _maxTokenFee,
      _emptyIcaConfig()
    );
  }

  /// @notice ABI-encodes a `BRIDGE_TOKEN` parameter struct for `_DOMAIN` with the supplied ICA configuration.
  /// @dev The zero recipient keeps the command on the derived-interchain-account path.
  function _bridgeInputWithConfig(
    address _token,
    address _bridge,
    IMetarouter.BalanceSpend memory _spend,
    uint256 _messageFee,
    uint256 _maxTokenFee,
    IMetarouter.IcaConfig memory _icaConfig
  ) private pure returns (bytes memory _input) {
    return _bridgeInputWithRecipientAndConfig(
      _token, _bridge, _spend, _messageFee, _maxTokenFee, address(0), _icaConfig
    );
  }

  /// @notice ABI-encodes a `BRIDGE_TOKEN` input for `_DOMAIN` delivering an `Amount` spend straight to `_recipient`.
  /// @dev The ICA configuration stays empty, the only shape the direct-recipient path accepts.
  function _bridgeInputWithRecipient(
    address _token,
    address _bridge,
    uint256 _amount,
    uint256 _messageFee,
    uint256 _maxTokenFee,
    address _recipient
  ) private pure returns (bytes memory _input) {
    return _bridgeInputWithRecipientAndConfig(
      _token,
      _bridge,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}),
      _messageFee,
      _maxTokenFee,
      _recipient,
      _emptyIcaConfig()
    );
  }

  /// @notice ABI-encodes a `BRIDGE_TOKEN` parameter struct for `_DOMAIN` with both an explicit recipient and an ICA
  ///         configuration.
  /// @dev The single struct literal in the suite; the contradictory combination is only encodable so the handler's
  ///      rejection of it can be exercised.
  function _bridgeInputWithRecipientAndConfig(
    address _token,
    address _bridge,
    IMetarouter.BalanceSpend memory _spend,
    uint256 _messageFee,
    uint256 _maxTokenFee,
    address _recipient,
    IMetarouter.IcaConfig memory _icaConfig
  ) private pure returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.BridgeTokenParams({
        token: _token,
        bridge: _bridge,
        spend: _spend,
        messageFee: _messageFee,
        maxFee: _maxTokenFee,
        domain: _DOMAIN,
        recipient: _recipient,
        icaConfig: _icaConfig
      })
    );
  }

  /// @notice ABI-encodes an `EXECUTE_CROSS_CHAIN` parameter struct with the supplied ICA configuration.
  function _executeInputWithConfig(
    uint32 _domain,
    bytes32 _commitment,
    uint256 _messageFee,
    uint256 _tokenFee,
    address _hook,
    bytes memory _hookMetadata,
    IMetarouter.IcaConfig memory _icaConfig
  ) private pure returns (bytes memory _input) {
    _input = abi.encode(
      IMetarouter.ExecuteCrosschainParams({
        domain: _domain,
        commitment: _commitment,
        messageFee: _messageFee,
        tokenFee: _tokenFee,
        hook: _hook,
        hookMetadata: _hookMetadata,
        icaConfig: _icaConfig
      })
    );
  }

  /// @notice Returns the all-zero ICA configuration that selects Hyperlane's enrolled defaults.
  function _emptyIcaConfig() private pure returns (IMetarouter.IcaConfig memory _icaConfig) {
    _icaConfig = IMetarouter.IcaConfig({router: address(0), ism: address(0)});
  }

  /// @notice Mocks and expects the recipient derivation for `_DOMAIN` with the logical sender as salt.
  function _mockDerivedRecipient(address _caller, address _recipientIca) private {
    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(uint32,address,bytes32)',
        _DOMAIN,
        address(_metarouter),
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
  }

  /// @notice Bounds the fuzz inputs of a six-decimal native ERC20 pull so every native quantity carries a nonzero sub-token
  ///         remainder while the batch still resolves at least one raw native ERC20 unit once the fee is reserved.
  /// @dev Composed here rather than inline so the calling test's own fuzz inputs keep the stack.
  /// @return _native Composed stranded pre-batch native, batch native and message fee.
  function _boundSixDecimalPull(
    uint256 _strandedWhole,
    uint256 _strandedRemainder,
    uint256 _batchWhole,
    uint256 _batchRemainder,
    uint256 _feeWhole,
    uint256 _feeRemainder
  ) private pure returns (NativeErc20PullNative memory _native) {
    // Every quantity keeps a nonzero sub-token remainder, so no conversion in the path is exact.
    _strandedRemainder = bound(_strandedRemainder, 1, _NATIVE_ERC20_SCALE - 1);
    _batchRemainder = bound(_batchRemainder, 1, _NATIVE_ERC20_SCALE - 1);
    _feeRemainder = bound(_feeRemainder, 1, _NATIVE_ERC20_SCALE - 1);
    _strandedWhole = bound(_strandedWhole, 1, type(uint64).max);
    // Two raw units of headroom over the fee leave at least one raw unit to resolve even when the batch's
    // remainder is the smaller of the two.
    _batchWhole = bound(_batchWhole, 2, type(uint64).max);
    _feeWhole = bound(_feeWhole, 0, _batchWhole - 2);
    _native = NativeErc20PullNative({
      stranded: _strandedWhole * _NATIVE_ERC20_SCALE + _strandedRemainder,
      batchNative: _batchWhole * _NATIVE_ERC20_SCALE + _batchRemainder,
      messageFee: _feeWhole * _NATIVE_ERC20_SCALE + _feeRemainder
    });
  }

  /// @notice Mocks and expects recipient derivation from a custom destination router and ISM.
  function _mockCustomDerivedRecipient(
    address _caller,
    address _recipientIca,
    IMetarouter.IcaConfig memory _icaConfig
  ) private {
    _mockAndExpect(
      _ICA_ROUTER,
      abi.encodeWithSignature(
        'getRemoteInterchainAccount(address,address,address,bytes32)',
        address(_metarouter),
        _icaConfig.router,
        _icaConfig.ism,
        bytes32(uint256(uint160(_caller)))
      ),
      abi.encode(_recipientIca)
    );
  }

  /// @notice Mocks the route's quote for `_amount`, filling Hyperlane's three entries: the interchain gas payment, the
  ///         internal warp-route entry, and the external bridging fee.
  /// @dev Only the last two are denominated in the bridged token, so only those reach the summed token total. The
  ///      entries are passed raw rather than as an amount plus a fee so a test can also mock a quote no honest route
  ///      reports, such as an internal entry below the delivered amount.
  function _mockQuote(
    address _bridge,
    address _token,
    bytes32 _recipient,
    uint256 _amount,
    uint256 _gasEntry,
    uint256 _internalEntry,
    uint256 _externalEntry
  ) private {
    ITokenRouter.Quote[] memory _quotes = new ITokenRouter.Quote[](3);
    _quotes[0] = ITokenRouter.Quote({token: address(0), amount: _gasEntry});
    _quotes[1] = ITokenRouter.Quote({token: _token, amount: _internalEntry});
    _quotes[2] = ITokenRouter.Quote({token: _token, amount: _externalEntry});
    _mockAndExpect(
      _bridge, abi.encodeCall(ITokenRouter.quoteTransferRemote, (_DOMAIN, _recipient, _amount)), abi.encode(_quotes)
    );
  }

  /// @notice Builds a `StandardHookMetadata` blob carrying `_refundAddress` and `_feeToken`, with `_custom` appended
  ///         as the trailing custom-metadata bytes.
  /// @dev Layout: variant(2) + msgValue(32) + gasLimit(32) + refundAddress(20) = `_HOOK_METADATA_PREFIX_LENGTH`, then the
  ///      fee token(20) and the custom tail. The handler reads the fee token from this field, so a zero value denotes a
  ///      native dispatch; the standard variant stays fixed while the value fields are supplied for tests to fuzz.
  function _hookMetadataWithFeeToken(
    uint256 _msgValue,
    uint256 _gasLimit,
    address _refundAddress,
    address _feeToken,
    bytes memory _custom
  ) private pure returns (bytes memory _metadata) {
    _metadata = abi.encodePacked(uint16(1), _msgValue, _gasLimit, _refundAddress, _feeToken, _custom);
  }

  /// @notice Mocks and expects the commit-reveal dispatch for `_DOMAIN` with the destination router and ISM constants,
  ///         the logical sender as salt, and the exact forwarded arguments.
  /// @dev Offloaded so the seven-argument expectation does not exceed the default-profile stack.
  function _mockCommitReveal(
    bytes memory _hookMetadata,
    address _hook,
    address _sender,
    bytes32 _commitment,
    uint256 _messageFee
  ) private {
    _mockCommitRevealWithConfig(_hookMetadata, _hook, _sender, _commitment, _messageFee, _REMOTE_ROUTER, _REMOTE_ISM);
  }

  /// @notice Mocks and expects a commit-reveal dispatch through a custom destination router and ISM.
  function _mockCommitRevealWithConfig(
    bytes memory _hookMetadata,
    address _hook,
    address _sender,
    bytes32 _commitment,
    uint256 _messageFee,
    bytes32 _router,
    bytes32 _ism
  ) private {
    _mockAndExpectWithValue(
      _ICA_ROUTER,
      _messageFee,
      abi.encodeCall(
        IInterchainAccountRouter.callRemoteCommitReveal,
        (_DOMAIN, _router, _ism, _hookMetadata, _hook, bytes32(uint256(uint160(_sender))), _commitment)
      ),
      abi.encode(bytes32(0), bytes32(0))
    );
  }
}
