// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {Metarouter} from 'V3/metarouter/Metarouter.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {ExecutionProbe} from 'V3-test/unit/metarouter/harnesses/ExecutionProbe.sol';
import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';

/// @notice Metarouter execution tests: control-flow commands, `receive`, and `msgSender`. Shares `BaseMetarouter`'s
///         `setUp` with the split `execute` suite.
contract UnitMetarouter is BaseMetarouter {
  // --- constructor ---

  /// @notice A chain without a wrapped-native token deploys with a zero WETH; the wrap and unwrap commands are
  ///         disabled at dispatch instead of rejecting the deployment.
  function test_ConstructorWhenTheWrappedNativeTokenIsTheZeroAddress() external {
    Metarouter _router = new Metarouter(
      IWETH(address(0)),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );

    // it should deploy with a zero WETH
    assertEq(address(_router.WETH()), address(0));
  }

  function test_ConstructorWhenTheVoterIsTheZeroAddress() external {
    // A lite deployment ships without the voting system, so a zero voter is accepted. No orchestrator or receipt-token
    // read is mocked for this deployment: the zero voter carries no code, so any constructor call into it would revert
    // construction, and success proves the voter is never dereferenced.
    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(address(0)),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    // it should deploy without reading the voter
    assertEq(address(_router.LEAF_VOTER()), address(0));
    // it should set IS_ROOT to false
    assertFalse(_router.IS_ROOT());
    // it should leave EMISSION_TOKEN, STAKING_ESCROW, STAKING_TOKEN and RELAY_FACTORY as zero
    assertEq(address(_router.EMISSION_TOKEN()), address(0));
    assertEq(address(_router.STAKING_ESCROW()), address(0));
    assertEq(address(_router.STAKING_TOKEN()), address(0));
    assertEq(address(_router.RELAY_FACTORY()), address(0));
  }

  function test_ConstructorWhenThePositionManagerIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMetarouter.ZeroAddress.selector);
    new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(address(0)),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  function test_ConstructorWhenTheInterchainAccountRouterIsTheZeroAddress() external {
    // A lite deployment ships without the cross-chain layer, so a zero interchain account router is accepted and the
    // cross-chain commands are gated off at dispatch instead of at construction.
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.RECEIPT_TOKEN, ()), abi.encode(_EMISSION_TOKEN));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(address(0)),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    // it should deploy with ICA_ROUTER as zero
    assertEq(address(_router.ICA_ROUTER()), address(0));
  }

  function test_ConstructorWhenTheFactoryRegistryIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMetarouter.ZeroAddress.selector);
    new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(address(0)),
      IERC20(address(0))
    );
  }

  /// @notice A chain without a native ERC20 deploys with a zero native ERC20: the scale stays zero and construction
  ///         never asks the zero address for decimals, which would revert the deployment.
  function test_ConstructorWhenTheNativeMirrorTokenIsTheZeroAddress() external {
    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );

    // it should leave the native mirror scale as zero
    assertEq(address(_router.NATIVE_ERC20()), address(0));
    assertEq(_router.NATIVE_ERC20_SCALE(), 0);
  }

  /// @notice The wrapped-native and native ERC20 roles are incompatible, so a deployment naming one address for
  ///         both is rejected instead of deploying a permanently broken router.
  function test_ConstructorWhenTheWrappedNativeTokenIsTheNativeMirrorToken() external {
    // it should revert with WethIsNativeErc20
    vm.expectRevert(IMetarouter.WethIsNativeErc20.selector);
    new Metarouter(
      IWETH(_NATIVE_ERC20),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_NATIVE_ERC20)
    );
  }

  /// @notice Native balances always carry eighteen decimals, so a native ERC20 claiming more cannot express the same asset
  ///         and the deployment is rejected instead of deriving a broken scale.
  function test_ConstructorWhenTheNativeMirrorTokenReportsMoreDecimalsThanNative(uint8 _decimals) external {
    _decimals = uint8(bound(_decimals, 19, type(uint8).max));
    vm.mockCall(_NATIVE_ERC20, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(_decimals));

    // it should revert with InvalidNativeErc20Decimals
    vm.expectRevert(IMetarouter.InvalidNativeErc20Decimals.selector);
    new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_NATIVE_ERC20)
    );
  }

  /// @notice A native ERC20 matching native's eighteen decimals shares raw units with `address.balance`, so the derived
  ///         scale is one and every conversion is the identity.
  function test_ConstructorWhenTheNativeMirrorTokenReportsTheNativeDecimals() external {
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(18)));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_NATIVE_ERC20)
    );

    // it should set the native mirror scale to one
    assertEq(address(_router.NATIVE_ERC20()), _NATIVE_ERC20);
    assertEq(_router.NATIVE_ERC20_SCALE(), 1);
  }

  /// @notice A native ERC20 expressing the native asset in fewer decimals derives the native units one token unit
  ///         represents from the decimals difference.
  function test_ConstructorWhenTheNativeMirrorTokenReportsFewerDecimalsThanNative(uint8 _decimals) external {
    _decimals = uint8(bound(_decimals, 0, 17));
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(_decimals));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_NATIVE_ERC20)
    );

    // it should derive the native mirror scale from the decimals difference
    assertEq(_router.NATIVE_ERC20_SCALE(), 10 ** (18 - uint256(_decimals)));
  }

  /// @notice Known example pinning the stablecoin-native shape: a six-decimal native ERC20 of an eighteen-decimal native
  ///         asset yields a hand-computed scale of one trillion native units per token unit.
  function test_ConstructorWhenTheNativeMirrorTokenReportsTheStablecoinSixDecimals() external {
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(uint8(6)));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_NATIVE_ERC20)
    );

    // it should set the native mirror scale to the known trillion factor
    assertEq(_router.NATIVE_ERC20_SCALE(), 1_000_000_000_000);
  }

  function test_ConstructorWhenTheLocalChainIsNotTheRootChain() external {
    // The orchestrator reports a root chain id that differs from the local chain id, so construction takes the leaf
    // branch and adopts the voter receipt token as the emission token.
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    address _receiptToken = _mockContract('ReceiptToken');
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.RECEIPT_TOKEN, ()), abi.encode(_receiptToken));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    // it should derive the emission token from the leaf voter receipt token
    assertEq(address(_router.EMISSION_TOKEN()), _receiptToken);
    // it should set IS_ROOT to false and STAKING_ESCROW, STAKING_TOKEN and RELAY_FACTORY to zero
    assertFalse(_router.IS_ROOT());
    assertEq(address(_router.STAKING_ESCROW()), address(0));
    assertEq(address(_router.STAKING_TOKEN()), address(0));
    assertEq(address(_router.RELAY_FACTORY()), address(0));
  }

  function test_ConstructorWhenTheLocalChainIdIsBelowTheRootChainId() external {
    // Exercise the opposite side of the root-chain boundary so root detection is pinned to equality, not ordering.
    vm.chainId(_ROOT_CHAIN_ID - 1);
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    address _receiptToken = _mockContract('LowerChainReceiptToken');
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.RECEIPT_TOKEN, ()), abi.encode(_receiptToken));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );

    // it should set IS_ROOT to false
    assertFalse(_router.IS_ROOT());
  }

  modifier givenTheLocalChainIsTheRootChain() {
    // Force the local chain id to the orchestrator root chain id so construction takes the root branch.
    vm.chainId(_ROOT_CHAIN_ID);
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    _;
  }

  function test_ConstructorWhenTheRootVoterIsTheZeroAddress() external givenTheLocalChainIsTheRootChain {
    // The root Voter is dereferenced to derive the emission token, so a zero root Voter is rejected before that call.
    // it should revert with ZeroAddress
    vm.expectRevert(IMetarouter.ZeroAddress.selector);
    new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(address(0)),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  modifier givenTheRootVoterIsAValidAddress() {
    _;
  }

  function test_ConstructorWhenTheRelayFactoryIsTheZeroAddress()
    external
    givenTheLocalChainIsTheRootChain
    givenTheRootVoterIsAValidAddress
  {
    // On root the relay factory authenticates deposit relays, so a zero factory is rejected before the emission token
    // is derived; the root Voter passes its own non-zero check and is never dereferenced.
    // it should revert with ZeroAddress
    vm.expectRevert(IMetarouter.ZeroAddress.selector);
    new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(address(0)),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  function test_ConstructorWhenTheRelayFactoryIsAValidAddress()
    external
    givenTheLocalChainIsTheRootChain
    givenTheRootVoterIsAValidAddress
  {
    address _minter = _mockContract('Minter');
    address _minterToken = _mockContract('MinterToken');
    address _stakingEscrow = _mockContract('StakingEscrow');
    address _stakingToken = _mockContract('StakingToken');
    _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.MINTER, ()), abi.encode(_minter));
    _mockAndExpect(_minter, abi.encodeCall(IMinter.TOKEN, ()), abi.encode(_minterToken));
    // The escrow is read from the root Voter, then its token for the staking-token immutable.
    _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.VOTING_ESCROW, ()), abi.encode(_stakingEscrow));
    _mockAndExpect(_stakingEscrow, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_stakingToken));

    Metarouter _router = new Metarouter(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
    // it should derive the emission token from the root voter minter
    assertEq(address(_router.EMISSION_TOKEN()), _minterToken);
    // it should set IS_ROOT to true
    assertTrue(_router.IS_ROOT());
    // it should derive STAKING_ESCROW from the root voter and STAKING_TOKEN from the escrow TOKEN
    assertEq(address(_router.STAKING_ESCROW()), _stakingEscrow);
    assertEq(address(_router.STAKING_TOKEN()), _stakingToken);
    // it should set RELAY_FACTORY to the relay factory
    assertEq(address(_router.RELAY_FACTORY()), _RELAY_FACTORY);
  }

  // --- executeSubPlan ---

  modifier givenTheSubPlanFails() {
    _;
  }

  function test_ExecuteSubPlanWhenTheSubPlanIsUnflagged(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheSubPlanFails {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    // A nested balance check below its minimum is a representative deterministic failure; any unflagged nested
    // revert bubbles identically because `_executeSubPlan` re-throws the child frame's revert data.
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _subCommands, bytes[] memory _subInputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.EXECUTE_SUB_PLAN), abi.encode(_subCommands, _subInputs));

    // it should revert the batch
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ExecuteSubPlanWhenTheSubPlanIsFlagged(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheSubPlanFails {
    _assumeFuzzable(_caller);
    address _trackedToken = _mockContract('trackedToken');
    address _failingToken = _mockContract('failingToken');
    address _passingToken = _mockContract('passingToken');
    // The flagged sub-plan first TRANSFER-tracks a token, then hits a failing balance check: the child frame reverts
    // atomically so the tracking is unwound, the failure is swallowed, and the batch continues with the next command.
    // The tracked token holds a positive balance, so a leaked (non-unwound) track would be swept at closure.
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    _mockAndExpectTokenBalance(_trackedToken, address(_metarouter), 1);
    _mockAndExpectTokenBalance(_failingToken, _owner, _balance);
    _mockAndExpectTokenBalance(_passingToken, _owner, _minBalance);
    // it should unwind the nested changes: the tracked token must not be swept at closure
    vm.mockCallRevert(_trackedToken, abi.encodeWithSelector(IERC20.transfer.selector), bytes('leaked tracked token'));

    bytes1[] memory _subCommandBytes = new bytes1[](2);
    _subCommandBytes[0] = _unflagged(Commands.TRANSFER);
    _subCommandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _subInputs = new bytes[](2);
    _subInputs[0] = abi.encode(
      _trackedToken, _caller, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: uint256(0)})
    );
    _subInputs[1] = _balanceCheckInput(_failingToken, _owner, _minBalance);
    (bytes memory _subCommands,) = _batch(_subCommandBytes, _subInputs);

    bytes1[] memory _commandBytes = new bytes1[](2);
    _commandBytes[0] = _flagged(Commands.EXECUTE_SUB_PLAN);
    _commandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _batchInputs = new bytes[](2);
    _batchInputs[0] = abi.encode(_subCommands, _subInputs);
    _batchInputs[1] = _balanceCheckInput(_passingToken, _owner, _minBalance);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    // it should unwind the nested changes and continue
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_ExecuteSubPlanWhenTheSubPlanIsFlaggedAfterTheOuterPlanFundsTheToken(
    address _caller,
    address _attemptedRecipient,
    address _fallbackRecipient,
    uint256 _amount
  ) external givenTheSubPlanFails {
    _assumeFuzzable(_caller);
    _attemptedRecipient = _boundNotEq(_attemptedRecipient, address(_metarouter));
    _fallbackRecipient = _boundNotEq(_fallbackRecipient, address(_metarouter));
    _fallbackRecipient = _boundNotEq(_fallbackRecipient, _attemptedRecipient);
    _amount = bound(_amount, 1, type(uint128).max);
    TestERC20 _token = new TestERC20('Funded token', 'FUND', 18);
    _token.mint(_caller, _amount);
    vm.prank(_caller);
    _token.approve(address(_metarouter), _amount);

    // The child first transfers the complete funded balance, then deliberately fails. Reverting the child frame must
    // restore that transfer so the outer fallback sweep can recover the complete amount.
    bytes1[] memory _subCommandBytes = new bytes1[](2);
    _subCommandBytes[0] = _unflagged(Commands.TRANSFER);
    _subCommandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _subInputs = new bytes[](2);
    _subInputs[0] = abi.encode(
      address(_token),
      _attemptedRecipient,
      IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount})
    );
    _subInputs[1] = _balanceCheckInput(address(_token), address(_metarouter), 1);
    (bytes memory _subCommands,) = _batch(_subCommandBytes, _subInputs);

    bytes1[] memory _commandBytes = new bytes1[](3);
    _commandBytes[0] = _unflagged(Commands.FUND_ERC20);
    _commandBytes[1] = _flagged(Commands.EXECUTE_SUB_PLAN);
    _commandBytes[2] = _unflagged(Commands.SWEEP);
    bytes[] memory _batchInputs = new bytes[](3);
    _batchInputs[0] =
      abi.encode(address(_token), IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}));
    _batchInputs[1] = abi.encode(_subCommands, _subInputs);
    _batchInputs[2] = abi.encode(address(_token), _fallbackRecipient, _amount);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should sweep the complete funded balance to the fallback recipient
    assertEq(_token.balanceOf(_fallbackRecipient), _amount);
    assertEq(_token.balanceOf(_attemptedRecipient), 0);
    assertEq(_token.balanceOf(address(_metarouter)), 0);
  }

  function test_ExecuteSubPlanWhenTheSubPlanSucceeds(address _caller, address _recipient, uint256 _amount) external {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    _amount = bound(_amount, 1, type(uint256).max);
    // The nested TRANSFER moves `_amount` to `_recipient`; the closure read then returns zero so no closing sweep runs.
    _mockAndExpectTokenBalancesTwice(_token, address(_metarouter), [_amount, uint256(0)]);
    // it should apply the nested command state changes
    _mockAndExpectTokenTransfer(_token, _recipient, _amount);

    bytes memory _transferInput =
      abi.encode(_token, _recipient, IMetarouter.BalanceSpend({mode: IMetarouter.SpendMode.Amount, value: _amount}));
    (bytes memory _subCommands, bytes[] memory _subInputs) =
      _singleCommand(_unflagged(Commands.TRANSFER), _transferInput);
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.EXECUTE_SUB_PLAN), abi.encode(_subCommands, _subInputs));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- msgSender ---

  function test_MsgSenderWhenABatchIsActive(address _caller) external {
    _assumeFuzzable(_caller);
    // SWEEP reaches the probe while the batch lock still holds the outer caller; the probe reads the public getter
    // from inside that callback and persists the observed value for the post-execution assertion.
    ExecutionProbe _probe = new ExecutionProbe(_metarouter, false);
    address _recipient = makeAddr('msgSenderRecipient');
    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.SWEEP), abi.encode(address(_probe), _recipient, uint256(1)));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should return the outer caller
    assertEq(_probe.observedSender(), _caller);
  }

  function test_MsgSenderWhenABatchIsNotActive() external view {
    // it should return the zero address
    assertEq(_metarouter.msgSender(), address(0));
  }

  // --- balanceCheck ---

  modifier givenTheAssetIsAToken() {
    _;
  }

  modifier givenTheBalanceIsBelowTheMinimum() {
    _;
  }

  function test_BalanceCheckWhenTheCommandIsUnflagged(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsAToken givenTheBalanceIsBelowTheMinimum {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));

    // it should revert the whole batch with InsufficientBalance for _token
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _token));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_BalanceCheckWhenTheCommandIsFlagged(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsAToken givenTheBalanceIsBelowTheMinimum {
    _assumeFuzzable(_caller);
    address _failingToken = _mockContract('failingToken');
    address _passingToken = _mockContract('passingToken');
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    // The flagged check reverts inside its own child frame; the following unflagged check must still run.
    _mockAndExpectTokenBalance(_failingToken, _owner, _balance);
    _mockAndExpectTokenBalance(_passingToken, _owner, _minBalance);

    bytes1[] memory _commandBytes = new bytes1[](2);
    _commandBytes[0] = _flagged(Commands.BALANCE_CHECK);
    _commandBytes[1] = _unflagged(Commands.BALANCE_CHECK);
    bytes[] memory _batchInputs = new bytes[](2);
    _batchInputs[0] = _balanceCheckInput(_failingToken, _owner, _minBalance);
    _batchInputs[1] = _balanceCheckInput(_passingToken, _owner, _minBalance);
    (bytes memory _commands, bytes[] memory _inputs) = _batch(_commandBytes, _batchInputs);

    // it should revert only the inner call
    // it should continue the batch
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_BalanceCheckWhenTheBalanceMeetsTheMinimum(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsAToken {
    _assumeFuzzable(_caller);
    address _token = _mockContract('token');
    _minBalance = bound(_minBalance, 0, _balance);
    _mockAndExpectTokenBalance(_token, _owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(_token, _owner, _minBalance));

    // it should pass
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  /// @notice The execution address's native ERC20 check derives from the batch's own native, never the native ERC20's
  ///         `balanceOf`, so it applies the same batch-only rule as the native branch: pre-batch native must not
  ///         satisfy the minimum, since no command can spend it.
  function test_BalanceCheckWhenTheCheckedTokenIsTheNativeMirrorTokenHeldByTheExecutionAddress(
    address _caller,
    uint256 _stranded,
    uint256 _batchNative,
    uint256 _minBalance
  ) external givenTheAssetIsAToken {
    _assumeFuzzable(_caller);
    MetarouterHarness _nativeErc20Metarouter = _deployNativeErc20Metarouter();
    _caller = _boundNotEq(_caller, address(_nativeErc20Metarouter));
    _stranded = bound(_stranded, 1, type(uint256).max - 1);
    _batchNative = bound(_batchNative, 0, type(uint256).max - _stranded);
    // Above the batch's own native, at or below the total the pre-batch funds would satisfy.
    _minBalance = bound(_minBalance, _batchNative + 1, _stranded + _batchNative);
    // The check reads the router's real native: the dealt pre-batch stranded native plus the batch value.
    vm.deal(address(_nativeErc20Metarouter), _stranded);
    vm.deal(_caller, _batchNative);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      _unflagged(Commands.BALANCE_CHECK),
      _balanceCheckInput(_NATIVE_ERC20, address(_nativeErc20Metarouter), _minBalance)
    );

    // it should revert even if the total balance meets the minimum through pre batch funds
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, _NATIVE_ERC20));
    _nativeErc20Metarouter.execute{value: _batchNative}(_commands, _inputs, block.timestamp);
  }

  modifier givenTheAssetIsNative() {
    _;
  }

  function test_BalanceCheckWhenTheOwnerIsTheExecutionAddressAndTheAvailableBalanceIsBelowTheMinimum(
    address _caller,
    uint256 _availableBalance,
    uint256 _preBatchBalance,
    uint256 _minBalance
  ) external givenTheAssetIsNative {
    _assumeFuzzable(_caller);
    _availableBalance = bound(_availableBalance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _availableBalance + 1, type(uint256).max);
    _preBatchBalance = bound(_preBatchBalance, _minBalance - _availableBalance, type(uint256).max - _availableBalance);
    vm.deal(address(_metarouter), _preBatchBalance);
    vm.deal(_caller, _availableBalance);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      _unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(address(0), address(_metarouter), _minBalance)
    );

    // it should revert even if the total balance meets the minimum through pre batch funds
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, address(0)));
    _metarouter.execute{value: _availableBalance}(_commands, _inputs, block.timestamp);
  }

  function test_BalanceCheckWhenTheOwnerIsTheExecutionAddressAndTheAvailableBalanceMeetsTheMinimum(
    address _caller,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsNative {
    _assumeFuzzable(_caller);
    vm.assume(_caller != address(_metarouter));
    // The router refunds leftover native to the caller and this test contract cannot receive it.
    vm.assume(_caller != address(this));
    _minBalance = bound(_minBalance, 0, _balance);
    vm.deal(_caller, _balance);

    (bytes memory _commands, bytes[] memory _inputs) = _singleCommand(
      _unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(address(0), address(_metarouter), _minBalance)
    );

    // it should pass
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute{value: _balance}(_commands, _inputs, block.timestamp);
  }

  function test_BalanceCheckWhenTheOwnerIsAnotherAccountAndTheLiveNativeBalanceIsBelowTheMinimum(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsNative {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);
    vm.assume(_owner != address(_metarouter));
    _balance = bound(_balance, 0, type(uint256).max - 1);
    _minBalance = bound(_minBalance, _balance + 1, type(uint256).max);
    vm.deal(_owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(address(0), _owner, _minBalance));

    // it should revert with InsufficientBalance
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.InsufficientBalance.selector, address(0)));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_BalanceCheckWhenTheOwnerIsAnotherAccountAndTheLiveNativeBalanceMeetsTheMinimum(
    address _caller,
    address _owner,
    uint256 _balance,
    uint256 _minBalance
  ) external givenTheAssetIsNative {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_owner);
    vm.assume(_owner != address(_metarouter));
    _minBalance = bound(_minBalance, 0, _balance);
    vm.deal(_owner, _balance);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.BALANCE_CHECK), _balanceCheckInput(address(0), _owner, _minBalance));

    // it should check the account's live native balance
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // --- receive ---

  function test_ReceiveWhenTheSenderIsUnexpectedAndNoBatchIsActive(address _sender, uint256 _value) external {
    _assumeFuzzable(_sender);
    _sender = _boundNotEq(_sender, _WETH);
    _value = bound(_value, 1, type(uint256).max);
    vm.deal(_sender, _value);

    // it should revert with InvalidEthSender
    vm.prank(_sender);
    (bool _success, bytes memory _data) = address(_metarouter).call{value: _value}('');
    assertFalse(_success);
    assertEq(_data, abi.encodeWithSelector(IMetarouter.InvalidEthSender.selector));
  }

  function test_ReceiveWhenTheSenderIsTheWrappedNativeToken(uint256 _value) external {
    _value = bound(_value, 1, type(uint256).max);
    vm.deal(_WETH, _value);

    // it should accept the native eth
    vm.prank(_WETH);
    (bool _success,) = address(_metarouter).call{value: _value}('');
    assertTrue(_success);
    assertEq(address(_metarouter).balance, _value);
  }

  function test_ReceiveWhenABatchIsActive(address _caller, address _recipient) external {
    _assumeFuzzable(_caller);
    // The caller receives the closure native refund, so it must be a code-less account that accepts ETH; deal it
    // zero so the post-refund balance assertion is exact.
    vm.assume(_caller.code.length == 0);
    vm.deal(_caller, 0);
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // A probe used as the SWEEP token forwards native ETH back into the router while the batch is active; its
    // `transfer` requires the forward to succeed, so a rejected inflow would bubble and fail the batch.
    ExecutionProbe _probe = new ExecutionProbe(_metarouter, false);
    vm.deal(address(_probe), 1);

    (bytes memory _commands, bytes[] memory _inputs) =
      _singleCommand(_unflagged(Commands.SWEEP), abi.encode(address(_probe), _recipient, uint256(0)));

    // it should accept the native eth
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
    // The forwarded wei is refunded to the caller at closure, proving the router received it during the batch.
    assertEq(_caller.balance, 1);
  }

  // --- onERC721Received ---

  function test_OnErc721ReceivedWhenNoBatchIsActive(address _sender, uint256 _tokenId) external {
    // Outside a batch the execution-active slot is zero, so an inbound position is rejected regardless of sender.
    // it should revert with BatchNotActive
    vm.prank(_sender);
    vm.expectRevert(IMetarouter.BatchNotActive.selector);
    _metarouter.onERC721Received(makeAddr('operator'), makeAddr('from'), _tokenId, '');
  }

  modifier givenABatchIsActive() {
    _metarouter.setExecutionActive(1);
    _;
  }

  function test_OnErc721ReceivedWhenTheSenderIsNotThePositionManager(
    address _sender,
    uint256 _tokenId
  ) external givenABatchIsActive {
    _sender = _boundNotEq(_sender, _POSITION_MANAGER);
    // it should revert with InvalidNftSender
    vm.prank(_sender);
    vm.expectRevert(IMetarouter.InvalidNftSender.selector);
    _metarouter.onERC721Received(makeAddr('operator'), makeAddr('from'), _tokenId, '');
  }

  function test_OnErc721ReceivedWhenNoExpectedNftIsSet(
    address _operator,
    address _from,
    uint256 _tokenId
  ) external givenABatchIsActive {
    // No command set an expected position, so the router solicited none. `_from` and `_tokenId` are fuzzed across the
    // whole range, zero included, because unset slots also read zero and must not be matched against.
    // it should revert with UnexpectedNftSender
    vm.prank(_POSITION_MANAGER);
    vm.expectRevert(IMetarouter.UnexpectedNftSender.selector);
    _metarouter.onERC721Received(_operator, _from, _tokenId, '');
  }

  modifier givenAnExpectedNftIsSet() {
    // The expected position is seeded per-test against the fuzzed values, so it cannot be hoisted here.
    _;
  }

  function test_OnErc721ReceivedWhenTheFromIsNotTheExpectedSender(
    address _operator,
    address _expectedSender,
    address _from,
    uint256 _tokenId
  ) external givenABatchIsActive givenAnExpectedNftIsSet {
    // A command set one expected sender; the position arrives from a different one.
    _expectedSender = _boundNotEq(_expectedSender, address(0));
    _from = _boundNotEq(_from, _expectedSender);
    _metarouter.seedExpectedNft(_expectedSender, _tokenId);

    // it should revert with UnexpectedNftSender
    vm.prank(_POSITION_MANAGER);
    vm.expectRevert(IMetarouter.UnexpectedNftSender.selector);
    _metarouter.onERC721Received(_operator, _from, _tokenId, '');
  }

  function test_OnErc721ReceivedWhenTheTokenIdIsNotTheExpectedOne(
    address _operator,
    address _from,
    uint256 _expectedTokenId,
    uint256 _tokenId
  ) external givenABatchIsActive givenAnExpectedNftIsSet {
    // The expected sender returns a different position than the one the command asked back.
    _from = _boundNotEq(_from, address(0));
    vm.assume(_tokenId != _expectedTokenId);
    _metarouter.seedExpectedNft(_from, _expectedTokenId);

    // it should revert with UnexpectedNftSender
    vm.prank(_POSITION_MANAGER);
    vm.expectRevert(IMetarouter.UnexpectedNftSender.selector);
    _metarouter.onERC721Received(_operator, _from, _tokenId, '');
  }

  function test_OnErc721ReceivedWhenTheFromAndTokenIdAreTheExpectedOnes(
    address _operator,
    address _from,
    uint256 _tokenId
  ) external givenABatchIsActive givenAnExpectedNftIsSet {
    // A withdrawal command sets the position it asked back and the sender it expects it from before the call.
    _from = _boundNotEq(_from, address(0));
    _metarouter.seedExpectedNft(_from, _tokenId);

    vm.prank(_POSITION_MANAGER);
    bytes4 _selector = _metarouter.onERC721Received(_operator, _from, _tokenId, '');

    // it should track the collection and token id
    assertEq(_metarouter.trackedNftLength(), 1);
    (address _collection, uint256 _trackedTokenId) = _metarouter.trackedNftAt(0);
    assertEq(_collection, _POSITION_MANAGER);
    assertEq(_trackedTokenId, _tokenId);
    // it should leave the expected nft for the setting command to clear
    (address _stillExpectedSender, uint256 _stillExpectedTokenId) = _metarouter.expectedNft();
    assertEq(_stillExpectedSender, _from);
    assertEq(_stillExpectedTokenId, _tokenId);
    // it should return the selector
    assertEq(_selector, IERC721Receiver.onERC721Received.selector);
  }
}
