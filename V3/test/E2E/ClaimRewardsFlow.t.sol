// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {LeafMessageOrchestrator} from 'V3/bridge/LeafMessageOrchestrator.sol';
import {RootLocalAdapter} from 'V3/bridge/RootLocalAdapter.sol';
import {RootMessageOrchestrator} from 'V3/bridge/RootMessageOrchestrator.sol';
import {IMessageAdapter} from 'V3/interfaces/bridge/IMessageAdapter.sol';
import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {Roles} from 'V3/libraries/Roles.sol';
import {LeafVoter} from 'V3/voter/LeafVoter.sol';
import {Voter} from 'V3/voter/Voter.sol';

contract E2EClaimRewardsFlowClaimRewards is TestHelpers {
  uint256 internal constant _TOKEN_ID = 42;
  uint48 internal constant _ALLOCATION_COOLDOWN = 1 days;
  uint48 internal constant _ALLOCATION_LIFETIME = 1 hours;
  uint48 internal constant _MESSAGE_LIFETIME = 2 hours;
  uint256 internal constant _MAX_GAUGES = 25;

  address internal immutable _CALLER = makeAddr('Caller');
  address internal immutable _RECIPIENT = makeAddr('Recipient');
  address internal immutable _REFUND_RECIPIENT = makeAddr('RefundRecipient');
  address internal immutable _VOTING_ESCROW = makeAddr('VotingEscrow');
  address internal immutable _MINTER = makeAddr('Minter');
  address internal immutable _TOKEN = makeAddr('Token');
  address internal immutable _GOVERNOR = makeAddr('Governor');
  address internal immutable _CONFIG_ADMIN = makeAddr('ConfigAdmin');
  address internal immutable _ADAPTER_AUTHORITY = makeAddr('AdapterAuthority');
  address internal immutable _RECEIPT_TOKEN = makeAddr('ReceiptToken');
  address internal immutable _FACTORY_REGISTRY = makeAddr('FactoryRegistry');
  address internal immutable _GAUGE = makeAddr('Gauge');
  address internal immutable _GAUGE_MANAGER = makeAddr('GaugeManager');
  address internal immutable _EMISSIONS_HANDLER = makeAddr('EmissionsHandler');
  address internal immutable _EMERGENCY_COUNCIL = makeAddr('EmergencyCouncil');

  Voter internal _voter;
  RootMessageOrchestrator internal _rootMessageOrchestrator;
  LeafVoter internal _leafVoter;
  LeafMessageOrchestrator internal _leafMessageOrchestrator;
  RootLocalAdapter internal _rootLocalAdapter;

  function setUp() public {
    uint256 _deployerNonce = vm.getNonce(address(this));
    address _expectedRootMessageOrchestrator = _computeCreate(address(this), _deployerNonce);
    address _expectedVoter = _computeCreate(address(this), _deployerNonce + 1);
    address _expectedLeafMessageOrchestrator = _computeCreate(address(this), _deployerNonce + 2);
    address _expectedLeafVoter = _computeCreate(address(this), _deployerNonce + 3);

    _rootMessageOrchestrator = new RootMessageOrchestrator(_expectedVoter);
    assertEq(address(_rootMessageOrchestrator), _expectedRootMessageOrchestrator);

    _voter = new Voter({
      _orchestrator: address(_rootMessageOrchestrator),
      _votingEscrow: _VOTING_ESCROW,
      _minter: _MINTER,
      _token: _TOKEN,
      _adapterAuthority: _ADAPTER_AUTHORITY,
      _governor: _GOVERNOR,
      _configAdmin: _CONFIG_ADMIN,
      _allocationLifetime: _ALLOCATION_LIFETIME,
      _messageLifetime: _MESSAGE_LIFETIME
    });
    assertEq(address(_voter), _expectedVoter);

    _leafMessageOrchestrator = new LeafMessageOrchestrator(_expectedLeafVoter, block.chainid);
    assertEq(address(_leafMessageOrchestrator), _expectedLeafMessageOrchestrator);

    _leafVoter = new LeafVoter({
      _governor: _GOVERNOR,
      _configAdmin: _CONFIG_ADMIN,
      _leafMessageOrchestrator: address(_leafMessageOrchestrator),
      _receiptToken: _RECEIPT_TOKEN,
      _factoryRegistry: _FACTORY_REGISTRY,
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
    IAccessControl(address(_voter)).grantRole(Roles.CHAIN_CONFIG_ROLE, _CONFIG_ADMIN);

    vm.prank(_CONFIG_ADMIN);
    _voter.registerChain(block.chainid);

    vm.prank(_ADAPTER_AUTHORITY);
    _leafMessageOrchestrator.setAdapter(IMessageAdapter(address(_rootLocalAdapter)));

    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
  }

  function test_WhenMixedFeeAndIncentiveClaimsSucceed() external {
    address _feeManagerOne = _mockContract('FeeManagerOne');
    address _feeManagerTwo = _mockContract('FeeManagerTwo');
    address _incentiveManagerOne = _mockContract('IncentiveManagerOne');
    address _incentiveManagerTwo = _mockContract('IncentiveManagerTwo');
    _mockRegisteredVotingRewardsManager(_feeManagerOne);
    _mockRegisteredVotingRewardsManager(_feeManagerTwo);
    _mockRegisteredVotingRewardsManager(_incentiveManagerOne);
    _mockRegisteredVotingRewardsManager(_incentiveManagerTwo);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](2);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: _feeManagerOne, maxCheckpoints: 11});
    _feeClaims[1] = ILeafVoter.FeeClaim({votingRewardsManager: _feeManagerTwo, maxCheckpoints: 12});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](2);
    _incentiveClaims[0] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: _incentiveManagerOne, programId: 21, maxCheckpoints: 31});
    _incentiveClaims[1] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: _incentiveManagerTwo, programId: 22, maxCheckpoints: 32});

    IVoter.ClaimRewardsParams[] memory _params = _claimRewardsParams(_feeClaims, _incentiveClaims);

    // it should forward every claim through the root local messaging stack
    _mockAndExpect(_feeManagerOne, abi.encodeCall(IVotingRewardsManager.claimFees, (_TOKEN_ID, _RECIPIENT, 11)), '');
    _mockAndExpect(_feeManagerTwo, abi.encodeCall(IVotingRewardsManager.claimFees, (_TOKEN_ID, _RECIPIENT, 12)), '');
    _mockAndExpect(
      _incentiveManagerOne, abi.encodeCall(IVotingRewardsManager.claimIncentives, (_TOKEN_ID, _RECIPIENT, 21, 31)), ''
    );
    _mockAndExpect(
      _incentiveManagerTwo, abi.encodeCall(IVotingRewardsManager.claimIncentives, (_TOKEN_ID, _RECIPIENT, 22, 32)), ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_TOKEN_ID, _params, _REFUND_RECIPIENT);

    // it should consume the outbound and inbound nonces
    _assertFirstNonceConsumed();
  }

  function test_WhenFeeAndIncentiveClaimsRevert() external {
    address _revertingFeeManager = _mockContract('RevertingFeeManager');
    address _revertingIncentiveManager = _mockContract('RevertingIncentiveManager');
    _mockRegisteredVotingRewardsManager(_revertingFeeManager);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: _revertingFeeManager, maxCheckpoints: 11});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: _revertingIncentiveManager, programId: 21, maxCheckpoints: 31});

    IVoter.ClaimRewardsParams[] memory _params = _claimRewardsParams(_feeClaims, _incentiveClaims);

    bytes memory _revertData = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    vm.mockCallRevert(
      _revertingFeeManager, abi.encodeCall(IVotingRewardsManager.claimFees, (_TOKEN_ID, _RECIPIENT, 11)), _revertData
    );

    // it should bubble the exact fee revert from the leaf voter
    vm.expectRevert(_revertData);
    vm.prank(_CALLER);
    _voter.claimRewards(_TOKEN_ID, _params, _REFUND_RECIPIENT);

    // it should roll back the nonces when the fee claim reverts
    assertEq(_rootMessageOrchestrator.nonceOut(block.chainid), 0);
    assertFalse(_leafMessageOrchestrator.noncesUsed(1));

    vm.clearMockedCalls();
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _mockRegisteredVotingRewardsManager(_revertingFeeManager);
    _mockRegisteredVotingRewardsManager(_revertingIncentiveManager);
    _mockAndExpect(
      _revertingFeeManager, abi.encodeCall(IVotingRewardsManager.claimFees, (_TOKEN_ID, _RECIPIENT, 11)), ''
    );
    vm.mockCallRevert(
      _revertingIncentiveManager,
      abi.encodeCall(IVotingRewardsManager.claimIncentives, (_TOKEN_ID, _RECIPIENT, 21, 31)),
      _revertData
    );

    // it should bubble the exact incentive revert after the fee manager recovers
    vm.expectRevert(_revertData);
    vm.prank(_CALLER);
    _voter.claimRewards(_TOKEN_ID, _params, _REFUND_RECIPIENT);

    // it should roll back the nonces when the incentive claim reverts
    assertEq(_rootMessageOrchestrator.nonceOut(block.chainid), 0);
    assertFalse(_leafMessageOrchestrator.noncesUsed(1));

    vm.clearMockedCalls();
    vm.mockCall(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _TOKEN_ID)), abi.encode(true));
    _mockRegisteredVotingRewardsManager(_revertingFeeManager);
    _mockRegisteredVotingRewardsManager(_revertingIncentiveManager);
    _mockAndExpect(
      _revertingFeeManager, abi.encodeCall(IVotingRewardsManager.claimFees, (_TOKEN_ID, _RECIPIENT, 11)), ''
    );
    _mockAndExpect(
      _revertingIncentiveManager,
      abi.encodeCall(IVotingRewardsManager.claimIncentives, (_TOKEN_ID, _RECIPIENT, 21, 31)),
      ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_TOKEN_ID, _params, _REFUND_RECIPIENT);

    // it should deliver the same nonce after both managers recover
    _assertFirstNonceConsumed();
  }

  function test_WhenTheEncodedClaimRewardsRecipientIsTheZeroAddress() external {
    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);
    bytes memory _payload =
      abi.encode(_TOKEN_ID, uint48(block.timestamp) + _MESSAGE_LIFETIME, address(0), _feeClaims, _incentiveClaims);

    IRootMessageOrchestrator.ChainDispatch[] memory _dispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _dispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: block.chainid, gasLimit: 0, nativeValue: 0, chargeDeallocationReturn: false, payload: _payload
    });

    // it should revert with ZeroAddress at the leaf voter
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    vm.prank(address(_voter));
    _rootMessageOrchestrator.dispatch(IMessageOrchestrator.MessageType.ClaimRewards, _dispatches, _REFUND_RECIPIENT);

    // it should roll back the outbound and inbound nonces
    assertEq(_rootMessageOrchestrator.nonceOut(block.chainid), 0);
    assertFalse(_leafMessageOrchestrator.noncesUsed(1));
  }

  function _claimRewardsParams(
    ILeafVoter.FeeClaim[] memory _feeClaims,
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims
  ) internal view returns (IVoter.ClaimRewardsParams[] memory _params) {
    _params = new IVoter.ClaimRewardsParams[](1);
    _params[0] = IVoter.ClaimRewardsParams({
      chainId: block.chainid,
      gasLimit: 0,
      value: 0,
      recipient: _RECIPIENT,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });
  }

  function _assertFirstNonceConsumed() internal view {
    assertEq(_rootMessageOrchestrator.nonceOut(block.chainid), 1);
    assertTrue(_leafMessageOrchestrator.noncesUsed(1));
  }

  function _mockRegisteredVotingRewardsManager(address _votingRewardsManager) private {
    _mockAndExpect(
      _FACTORY_REGISTRY, abi.encodeCall(IFactoryRegistry.rewardsToGauge, (_votingRewardsManager)), abi.encode(_GAUGE)
    );
  }
}
