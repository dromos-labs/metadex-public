// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {Clones} from '@openzeppelin/contracts/proxy/Clones.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MockWETH} from 'V3-test/mocks/MockWETH.sol';
import {TestERC20} from 'V3-test/mocks/TestERC20.sol';
import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {LeafMessageOrchestrator} from 'V3/bridge/LeafMessageOrchestrator.sol';
import {RootLocalAdapter} from 'V3/bridge/RootLocalAdapter.sol';
import {RootMessageOrchestrator} from 'V3/bridge/RootMessageOrchestrator.sol';
import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {MaxiRelay} from 'V3/relay/MaxiRelay.sol';
import {RelayBase} from 'V3/relay/RelayBase.sol';
import {VotingRewardsManager} from 'V3/rewards/VotingRewardsManager.sol';
import {LeafVoter} from 'V3/voter/LeafVoter.sol';
import {Voter} from 'V3/voter/Voter.sol';

/**
 * @title E2ERelayRootClaimFlow
 * @notice The composed root reward claim: an EIP-1167 Relay clone drives `claimRewards` through the
 *         real Voter, the root local messaging stack and the real VotingRewardsManager, whose
 *         wrapped-native leg is unwrapped, paid to the Relay in native and wrapped back by its
 *         `receive`. The leaf swallows a failed claim into `FeeClaimFailed`, so only a composed run
 *         proves the claim pays out instead of failing silently.
 */
contract E2ERelayRootClaimFlow is BaseRelay {
  uint48 internal constant _ALLOCATION_COOLDOWN = 1 days;
  uint48 internal constant _ALLOCATION_LIFETIME = 1 hours;
  uint48 internal constant _MESSAGE_LIFETIME = 2 hours;
  uint256 internal constant _MAX_GAUGES = 25;

  /// @dev Voting power the single staker holds for the whole window, so it owns every credited fee.
  uint128 internal constant _WEIGHT = 1000e18;

  /// @dev Fees the gauge reports and hands to the manager, one leg per reward token.
  uint256 internal constant _FEE = 2000e18;

  address internal immutable _MINTER = makeAddr('Minter');
  address internal immutable _EMISSIONS_TOKEN = makeAddr('EmissionsToken');
  address internal immutable _VOTER_GOVERNOR = makeAddr('VoterGovernor');
  address internal immutable _CONFIG_ADMIN = makeAddr('ConfigAdmin');
  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _RECEIPT_TOKEN = makeAddr('ReceiptToken');
  address internal immutable _GAUGE_MANAGER = makeAddr('GaugeManager');
  address internal immutable _EMISSIONS_HANDLER = makeAddr('EmissionsHandler');
  address internal immutable _EMERGENCY_COUNCIL = makeAddr('EmergencyCouncil');

  Voter internal _rootVoter;
  RootMessageOrchestrator internal _rootMessageOrchestrator;
  LeafVoter internal _leafVoter;
  LeafMessageOrchestrator internal _leafMessageOrchestrator;
  RootLocalAdapter internal _rootLocalAdapter;

  address internal _factoryRegistry;
  address internal _gauge;
  address internal _gaugeFactory;

  TestERC20 internal _otherToken;
  VotingRewardsManager internal _manager;

  function setUp() public override {
    super.setUp();

    _factoryRegistry = _mockContract('LeafFactoryRegistry');
    _gauge = _mockContract('VrmGauge');
    _gaugeFactory = _mockContract('VrmGaugeFactory');

    // The real root local messaging stack, wired as production does: the circular references are
    // resolved by precomputing the create addresses.
    uint256 _deployerNonce = vm.getNonce(address(this));
    address _expectedVoter = _computeCreate(address(this), _deployerNonce + 1);
    address _expectedLeafVoter = _computeCreate(address(this), _deployerNonce + 3);

    _rootMessageOrchestrator = new RootMessageOrchestrator(_expectedVoter);
    _rootVoter = new Voter({
      _orchestrator: address(_rootMessageOrchestrator),
      _votingEscrow: _votingEscrow,
      _minter: _MINTER,
      _token: _EMISSIONS_TOKEN,
      _adapterAuthority: _ADAPTER_AUTHORITY,
      _governor: _VOTER_GOVERNOR,
      _configAdmin: _CONFIG_ADMIN,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
    assertEq(address(_rootVoter), _expectedVoter);

    _leafMessageOrchestrator = new LeafMessageOrchestrator(_expectedLeafVoter, block.chainid);
    _leafVoter = new LeafVoter({
      _governor: _VOTER_GOVERNOR,
      _configAdmin: _CONFIG_ADMIN,
      _leafMessageOrchestrator: address(_leafMessageOrchestrator),
      _receiptToken: _RECEIPT_TOKEN,
      _factoryRegistry: _factoryRegistry,
      _gaugeManager: _GAUGE_MANAGER,
      _allocationCooldown: _ALLOCATION_COOLDOWN,
      _maxGauges: _MAX_GAUGES,
      _adapterAuthority: _ADAPTER_AUTHORITY,
      _emissionsHandler: _EMISSIONS_HANDLER,
      _emergencyCouncil: _EMERGENCY_COUNCIL
    });
    assertEq(address(_leafVoter), _expectedLeafVoter);

    _rootLocalAdapter = new RootLocalAdapter(address(_rootMessageOrchestrator), address(_leafMessageOrchestrator));

    vm.prank(_ADAPTER_AUTHORITY);
    _rootMessageOrchestrator.setAdapter(block.chainid, IMessageAdapter(address(_rootLocalAdapter)));
    vm.prank(_CONFIG_ADMIN);
    IAccessControl(address(_rootVoter)).grantRole(Roles.CHAIN_CONFIG_ROLE, _CONFIG_ADMIN);
    vm.prank(_CONFIG_ADMIN);
    _rootVoter.registerChain(block.chainid);
    vm.prank(_ADAPTER_AUTHORITY);
    _leafMessageOrchestrator.setAdapter(IMessageAdapter(address(_rootLocalAdapter)));

    // The Relay under test is a real EIP-1167 clone bound to the real Voter, so both the claim
    // dispatch and the native inflow run through the delegatecalling proxy.
    _voter = address(_rootVoter);
    MaxiRelay _implementation = new MaxiRelay(
      IVotingEscrow(_votingEscrow),
      IVoter(_voter),
      address(_principalTokenImplementation),
      address(_relayTokenImplementation),
      _weth
    );
    _relay = RelayBase(payable(Clones.clone(address(_implementation))));
    _initializeRelay(_defaultInitParams(true));

    // The Voter's access gate reads the escrow: the Relay operates its own sAERO.
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorized, (address(_relay), _RELAY_TOKEN_ID)), abi.encode(true)
    );

    // The real manager the leaf claim pays out from, owned by the real LeafVoter.
    _otherToken = new TestERC20('Other', 'OTHER', 18);
    address[] memory _rewards = new address[](2);
    _rewards[0] = _weth;
    _rewards[1] = address(_otherToken);
    _manager = new VotingRewardsManager(address(_leafVoter), _gauge, _gaugeFactory, _weth, _rewards);

    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.tokenRegistry, ()), abi.encode(_mockContract('TokenRegistry'))
    );
    vm.mockCall(_gauge, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(uint256(0), uint256(0)));
  }

  /// @dev The fixture's relays wrap into a real WETH here, so the unwrap and the rewrap both run.
  function _deployWrappedNative() internal override returns (address _wrappedNative) {
    _wrappedNative = address(new MockWETH());
  }

  /// @notice A root claim driven through `Relay.claimRewards` pays the Relay clone its
  ///         wrapped-native fee leg. The leaf converts a failed claim into a `FeeClaimFailed` event
  ///         instead of reverting, so the balances are the proof the claim paid out.
  function test_WhenARootClaimPaysWrappedNativeToARelayClone(address _caller) external {
    _assumeFreshHolder(_caller);
    _creditFees();

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: address(_manager), maxCheckpoints: 1});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    // it should pay the claim out instead of swallowing it into FeeClaimFailed
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.FeeClaimSucceeded(_RELAY_TOKEN_ID, address(_manager), address(_relay), 1);

    vm.prank(_caller);
    _relay.claimRewards(block.chainid, 0, _feeClaims, _incentiveClaims);

    // it should consume the outbound and inbound message nonces
    assertEq(_rootMessageOrchestrator.nonceOut(block.chainid), 1);
    assertTrue(_leafMessageOrchestrator.noncesUsed(1));

    // it should land the wrapped-native leg on the Relay clone as an ERC-20 balance, no native
    assertEq(IERC20(_weth).balanceOf(address(_relay)), _FEE);
    assertEq(address(_relay).balance, 0);

    // it should deliver the plain ERC-20 leg untouched
    assertEq(_otherToken.balanceOf(address(_relay)), _FEE);
  }

  /// @dev Runs the manager's fee cycle: two checkpoints around a reported accrual, then the flush
  ///      that credits it, funding the manager with the tokens a real gauge collection would send.
  ///      The checkpoints are pranked as the LeafVoter, the manager's voter.
  function _creditFees() private {
    vm.warp(_INITIAL_TIMESTAMP + 1 weeks);
    vm.prank(address(_leafVoter));
    _manager.checkpoint({_tokenId: _RELAY_TOKEN_ID, _allocated: _WEIGHT, _stakeEnd: 0, _data: ''});

    vm.warp(_INITIAL_TIMESTAMP + 2 weeks);
    vm.mockCall(_gauge, abi.encodeCall(IGauge.pendingFees, ()), abi.encode(_FEE, _FEE));
    vm.prank(address(_leafVoter));
    _manager.checkpoint({_tokenId: _RELAY_TOKEN_ID, _allocated: _WEIGHT, _stakeEnd: 0, _data: ''});

    vm.mockCall(_gauge, abi.encodeCall(IGauge.collectFees, ()), abi.encode(_FEE, _FEE));
    vm.deal(address(this), _FEE);
    MockWETH(payable(_weth)).deposit{value: _FEE}();
    MockWETH(payable(_weth)).transfer(address(_manager), _FEE);
    _otherToken.mint(address(_manager), _FEE);
    vm.prank(_gaugeFactory);
    _manager.flushFees();

    // The claim must not collect again; the flush already banked everything.
    vm.mockCallRevert(_gauge, abi.encodeCall(IGauge.collectFees, ()), '');

    // The leaf validates each manager against the registry before forwarding the claim.
    vm.mockCall(
      _factoryRegistry, abi.encodeCall(IFactoryRegistry.rewardsToGauge, (address(_manager))), abi.encode(_gauge)
    );
  }
}
