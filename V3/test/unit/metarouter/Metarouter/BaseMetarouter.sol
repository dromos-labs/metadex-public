// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';

import {ILeafMessageOrchestrator} from 'V3/interfaces/bridge/ILeafMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

/// @title BaseMetarouter
/// @notice Shared setup and command-building helpers for the Metarouter execution tests.
/// @dev The suites drive the real `execute` entrypoint so the whole lifecycle runs: context check, deadline,
///      length, active-slot branch, begin, commands, end, clear, emit.
abstract contract BaseMetarouter is TestHelpers {
  /// @notice Root chain id mocked onto the orchestrator; distinct from the local test chain id so construction takes
  ///         the leaf branch.
  uint256 internal constant _ROOT_CHAIN_ID = 999;

  /// @notice Wrapped native token wired into the deployed Metarouter; command suites mock its deposit/withdraw reads.
  address internal immutable _WETH = makeAddr('WETH');
  /// @notice Leaf Voter mocked into the Metarouter constructor; the constructor calls it to derive the emission token,
  ///         and command suites mock its gauge and registry reads.
  address internal immutable _VOTER = _mockContract('Voter');
  /// @notice Orchestrator the leaf Voter returns from `ORCHESTRATOR`; supplies the `ROOT_CHAIN_ID` used at construction.
  address internal immutable _ORCHESTRATOR = _mockContract('Orchestrator');
  /// @notice Root Voter wired into the Metarouter constructor; carries code so root-mode suites can mock its reads.
  address internal immutable _ROOT_VOTER = _mockContract('RootVoter');
  /// @notice Emission token the router derives from the leaf Voter receipt token; carries code so claim/stake suites
  ///         can transfer it.
  address internal immutable _EMISSION_TOKEN = _mockContract('EmissionToken');
  /// @notice CL position manager wired into the Metarouter; mocked, and recorded as the collection the NFT closure
  ///         tests seed into custody.
  address internal immutable _POSITION_MANAGER = _mockContract('PositionManager');
  /// @notice Interchain account router wired into the Metarouter constructor; carries code so cross-chain suites can
  ///         mock its derivation and dispatch reads.
  address internal immutable _ICA_ROUTER = _mockContract('IcaRouter');
  /// @notice Factory registry wired into the Metarouter constructor; swap/liquidity/claim suites mock its reads.
  address internal immutable _FACTORY_REGISTRY = _mockContract('FactoryRegistry');
  /// @notice Gauge factory the gauge-type and penalty mocks resolve against.
  address internal immutable _GAUGE_FACTORY = _mockContract('GaugeFactory');
  /// @notice RelayFactory wired into the Metarouter constructor; carries code so root-mode suites can mock its reads.
  address internal immutable _RELAY_FACTORY = _mockContract('RelayFactory');
  /// @notice Minter the root Voter reports on the root branch; supplies the emission token at construction. Unused on
  ///         the default leaf branch.
  address internal immutable _MINTER = _mockContract('Minter');
  /// @notice VotingEscrow the root Voter resolves on the root branch; `CREATE_STAKE` mints sAEROs through it. Zero on
  ///         a leaf, so it stays unused by the default deployment.
  address internal immutable _STAKING_ESCROW = _mockContract('StakingEscrow');
  /// @notice Staking token the escrow reports from `TOKEN` on the root branch. Unused on the default leaf branch.
  address internal immutable _STAKING_TOKEN = makeAddr('StakingToken');
  /// @notice ERC20 entry point of the native asset wired into the native ERC20 deployment; the closure sweep caps it at the
  ///         batch's own native. Zero on the default deployment, whose chain has no native ERC20.
  address internal immutable _NATIVE_ERC20 = _mockContract('NativeErc20');

  /// @notice Decimals a lower-precision native ERC20 reports, the stablecoin-native shape where the ERC20 entry point
  ///         expresses the eighteen-decimal native asset in six decimals.
  uint8 internal constant _NATIVE_ERC20_DECIMALS = 6;
  /// @notice Native value per raw native ERC20 unit the six-decimal native ERC20 derives at construction.
  uint256 internal constant _NATIVE_ERC20_SCALE = 1e12;

  /// @notice A command ID with no dispatch branch; its low seven bits stay unmapped so `_dispatch` reverts.
  uint256 internal constant _UNDEFINED_COMMAND = 0x7f;
  /// @notice An unassigned command ID between the CL and V2 swap command ranges.
  uint256 internal constant _UNDEFINED_GAP_COMMAND = 0x02;

  /// @notice Metarouter under test, deployed in setUp. The harness adds read-only views over the execution
  ///         transient slots so tests can assert the closure leaves no transient state behind.
  MetarouterHarness internal _metarouter;

  function setUp() public virtual {
    // The constructor always reads the voter orchestrator's `ROOT_CHAIN_ID` to decide the deployment branch.
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    if (_deployAsRoot()) {
      // Root deployment: force the local chain id to the orchestrator root chain id so construction takes the root
      // branch, deriving the emission token from the root Minter and the staking escrow and its token from the root
      // Voter.
      vm.chainId(_ROOT_CHAIN_ID);
      _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.MINTER, ()), abi.encode(_MINTER));
      _mockAndExpect(_MINTER, abi.encodeCall(IMinter.TOKEN, ()), abi.encode(_EMISSION_TOKEN));
      _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.VOTING_ESCROW, ()), abi.encode(_STAKING_ESCROW));
      _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_STAKING_TOKEN));
    } else {
      // Leaf deployment: the emission token is the leaf Voter `RECEIPT_TOKEN` (the local chain id stays distinct from
      // `ROOT_CHAIN_ID`), the staking immutables stay zero, and the root-only sAERO/relay commands are gated off.
      _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.RECEIPT_TOKEN, ()), abi.encode(_EMISSION_TOKEN));
    }
    _metarouter = new MetarouterHarness(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  /// @notice Deploys a second router as a lite deployment: no voting system and no cross-chain layer, so the leaf
  ///         Voter, the root Voter, the ICA router and the RelayFactory are all zero. The command-disabled suites use
  ///         it to assert the gauge and cross-chain commands revert instead of reaching their handlers.
  /// @dev The lite constructor never reads a voter or an orchestrator, so nothing is mocked here.
  /// @return _liteMetarouter Metarouter harness deployed without the voter and cross-chain dependencies.
  function _deployLiteMetarouter() internal returns (MetarouterHarness _liteMetarouter) {
    _liteMetarouter = new MetarouterHarness(
      IWETH(_WETH),
      ILeafVoter(address(0)),
      IVoter(address(0)),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(address(0)),
      IRelayFactory(address(0)),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  /// @notice Deploys a second router wired to `_NATIVE_ERC20` as the chain's native ERC20, the deployment shape
  ///         for a chain whose native asset also has an ERC20 entry point. The closure-sweep cap tests use it; every
  ///         other suite keeps the default deployment, whose `NATIVE_ERC20` is zero.
  /// @dev Deployed without a voting system since only native ERC20 accounting is under test, but with the suite's
  ///      ICA router so the cross-chain commands' native ERC20 caps stay exercisable. The constructor never reads the ICA
  ///      router, so nothing is mocked here.
  /// @return _nativeErc20Metarouter Metarouter harness deployed with the native ERC20 configured.
  function _deployNativeErc20Metarouter() internal returns (MetarouterHarness _nativeErc20Metarouter) {
    // Eighteen decimals matches native's precision, so both interfaces share raw units and the scale is one.
    _nativeErc20Metarouter = _deployNativeErc20Metarouter(18);
  }

  /// @notice Deploys a second router wired to `_NATIVE_ERC20` reporting the given decimals, the deployment shape for
  ///         a chain whose native asset carries a different precision per interface. The unit-scale suites use it;
  ///         `_deployNativeErc20Metarouter()` keeps the same-precision default.
  /// @dev The constructor derives the native-to-token unit scale from the native ERC20's reported decimals.
  /// @param _decimals Decimals the native ERC20 token reports at construction.
  /// @return _nativeErc20Metarouter Metarouter harness deployed with the native ERC20 configured.
  function _deployNativeErc20Metarouter(uint8 _decimals) internal returns (MetarouterHarness _nativeErc20Metarouter) {
    _mockAndExpect(_NATIVE_ERC20, abi.encodeCall(IERC20Metadata.decimals, ()), abi.encode(_decimals));
    _nativeErc20Metarouter = _deployNativeErc20Metarouter(_NATIVE_ERC20);
  }

  /// @notice Deploys a second router wired to `_nativeErc20` as the chain's native ERC20, for suites that need a
  ///         token contract of their own instead of the suite's mocked `_NATIVE_ERC20`.
  /// @dev Nothing is mocked here: the given token must answer `decimals` itself, since the constructor reads it to
  ///      derive the native-to-token unit scale.
  /// @param _nativeErc20 Native ERC20 token wired into the deployment.
  /// @return _nativeErc20Metarouter Metarouter harness deployed with the given native ERC20 configured.
  function _deployNativeErc20Metarouter(address _nativeErc20)
    internal
    returns (MetarouterHarness _nativeErc20Metarouter)
  {
    _nativeErc20Metarouter = new MetarouterHarness(
      IWETH(_WETH),
      ILeafVoter(address(0)),
      IVoter(address(0)),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(address(0)),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(_nativeErc20)
    );
  }

  /// @notice Deploys a second router with a zero wrapped-native token, the deployment shape for a chain with no
  ///         WETH. The wrap and unwrap command-disabled tests use it.
  /// @dev Deployed without a voting system and cross-chain layer since only the wrapped-native gating is under test.
  /// @return _wethlessMetarouter Metarouter harness deployed without a wrapped-native token.
  function _deployWethlessMetarouter() internal returns (MetarouterHarness _wethlessMetarouter) {
    _wethlessMetarouter = new MetarouterHarness(
      IWETH(address(0)),
      ILeafVoter(address(0)),
      IVoter(address(0)),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(address(0)),
      IRelayFactory(address(0)),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  /// @notice Deploys a second router on the root branch: the local chain id becomes the orchestrator's root chain id,
  ///         so `IS_ROOT` is true and the emission token is the root Minter's `TOKEN` instead of the leaf receipt
  ///         token. The leaf-only `REDEEM` gate test uses it, in a suite whose own router is a leaf.
  /// @dev The chain id stays overridden for the rest of the test, which is the scenario: a batch running on root.
  /// @return _rootMetarouter Metarouter harness deployed on the root branch.
  function _deployRootMetarouter() internal returns (MetarouterHarness _rootMetarouter) {
    vm.chainId(_ROOT_CHAIN_ID);
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.ORCHESTRATOR, ()), abi.encode(_ORCHESTRATOR));
    _mockAndExpect(
      _ORCHESTRATOR, abi.encodeCall(ILeafMessageOrchestrator.ROOT_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID)
    );
    _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.MINTER, ()), abi.encode(_MINTER));
    _mockAndExpect(_MINTER, abi.encodeCall(IMinter.TOKEN, ()), abi.encode(_EMISSION_TOKEN));
    _mockAndExpect(_ROOT_VOTER, abi.encodeCall(IVoter.VOTING_ESCROW, ()), abi.encode(_STAKING_ESCROW));
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.TOKEN, ()), abi.encode(_STAKING_TOKEN));
    _rootMetarouter = new MetarouterHarness(
      IWETH(_WETH),
      ILeafVoter(_VOTER),
      IVoter(_ROOT_VOTER),
      INonfungiblePositionManager(_POSITION_MANAGER),
      IInterchainAccountRouter(_ICA_ROUTER),
      IRelayFactory(_RELAY_FACTORY),
      IFactoryRegistry(_FACTORY_REGISTRY),
      IERC20(address(0))
    );
  }

  /// @notice Whether the router deploys on the root branch, where the `VotingEscrow` and the Relay exist. Leaf by
  ///         default; the sTOKEN/relay suite overrides it to exercise the root-only `CREATE_STAKE` and `DEPOSIT_RELAY`.
  /// @return _isRoot True to deploy on the root branch, false for a leaf deployment.
  function _deployAsRoot() internal pure virtual returns (bool _isRoot) {
    return false;
  }

  /// @notice Asserts the execution closed leaving every scalar transient slot cleared: the logical sender (`LOCKER`),
  ///         the pre-batch native-balance snapshot, and the tracked-ERC20 array length.
  function _assertTransientCleared() internal view {
    assertEq(_metarouter.msgSender(), address(0), 'locker slot not cleared');
    assertEq(_metarouter.nativeBalanceBefore(), 0, 'native-balance-before slot not cleared');
    assertEq(_metarouter.trackedLength(), 0, 'tracked-array length not cleared');
  }

  /// @notice Asserts every scalar transient slot is cleared and `_token`'s tracked flag was untracked at closure.
  /// @param _token Token whose tracked-flag slot must be cleared.
  function _assertTransientCleared(address _token) internal view {
    _assertTransientCleared();
    assertEq(_metarouter.tracked(_token), 0, 'tracked flag not cleared');
  }

  /// @notice Builds a single-command batch from a command byte and its ABI-encoded input.
  /// @param _commandByte One-byte command string, optionally OR-ed with the allow-revert flag.
  /// @param _input ABI-encoded arguments for the command.
  /// @return _commands One-byte command string.
  /// @return _inputs Single-element input array aligned with `_commands`.
  function _singleCommand(
    bytes1 _commandByte,
    bytes memory _input
  ) internal pure returns (bytes memory _commands, bytes[] memory _inputs) {
    _commands = abi.encodePacked(_commandByte);
    _inputs = new bytes[](1);
    _inputs[0] = _input;
  }

  /// @notice Packs index-aligned command bytes and inputs into a batch of any length.
  /// @param _commandBytes One entry per command, each optionally OR-ed with the allow-revert flag.
  /// @param _inputs ABI-encoded arguments index-aligned with `_commandBytes`.
  /// @return _commands Packed command string.
  /// @return _batchInputs The `_inputs` array, returned for call-site symmetry with `_singleCommand`.
  function _batch(
    bytes1[] memory _commandBytes,
    bytes[] memory _inputs
  ) internal pure returns (bytes memory _commands, bytes[] memory _batchInputs) {
    for (uint256 _i; _i < _commandBytes.length; ++_i) {
      _commands = bytes.concat(_commands, _commandBytes[_i]);
    }
    _batchInputs = _inputs;
  }

  /// @notice Returns the command byte for `_commandId` with the allow-revert flag set.
  /// @param _commandId Command ID to encode.
  /// @return _commandByte Command byte OR-ed with `FLAG_ALLOW_REVERT`.
  function _flagged(uint256 _commandId) internal pure returns (bytes1 _commandByte) {
    _commandByte = bytes1(uint8(_commandId)) | Commands.FLAG_ALLOW_REVERT;
  }

  /// @notice Returns the plain command byte for `_commandId` with no flags set.
  /// @param _commandId Command ID to encode.
  /// @return _commandByte Command byte with the allow-revert flag cleared.
  function _unflagged(uint256 _commandId) internal pure returns (bytes1 _commandByte) {
    _commandByte = bytes1(uint8(_commandId));
  }

  /// @notice Builds a `BALANCE_CHECK` input.
  /// @param _token Asset whose balance is asserted, address zero selects native ETH.
  /// @param _owner Account whose balance is read.
  /// @param _minBalance Minimum balance the owner must hold.
  /// @return _input ABI-encoded balance-check arguments.
  function _balanceCheckInput(
    address _token,
    address _owner,
    uint256 _minBalance
  ) internal pure returns (bytes memory _input) {
    _input = abi.encode(_token, _owner, _minBalance);
  }

  /// @notice Mocks and expects the gauge-factory type resolution used to pick the V2 or CL venue.
  /// @param _gauge Gauge whose factory reports the type.
  /// @param _gaugeType Gauge type returned by the factory.
  function _mockGaugeType(address _gauge, string memory _gaugeType) internal {
    _mockAndExpect(_gauge, abi.encodeCall(IGauge.gaugeFactory, ()), abi.encode(_GAUGE_FACTORY));
    _mockAndExpect(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.GAUGE_TYPE, ()), abi.encode(_gaugeType));
  }

  /// @notice Mocks the effective penalty configuration the gauge factory reports for a gauge.
  /// @param _gauge Gauge the configuration applies to.
  /// @param _minStakeBlocks Blocks the stake must remain before the penalty window closes.
  /// @param _penaltyRate Penalty rate applied inside the window.
  function _mockPenaltyConfig(address _gauge, uint256 _minStakeBlocks, uint256 _penaltyRate) internal {
    IGaugeFactory.PenaltyConfig memory _config =
      IGaugeFactory.PenaltyConfig({minStakeBlocks: _minStakeBlocks, penaltyRate: _penaltyRate});
    _mockAndExpect(_GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.effectivePenaltyConfig, (_gauge)), abi.encode(_config));
  }
}
