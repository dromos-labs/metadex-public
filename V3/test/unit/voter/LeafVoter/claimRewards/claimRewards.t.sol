// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

contract UnitLeafVoterClaimRewards is BaseLeafVoter {
  address internal immutable _RECIPIENT = makeAddr('Recipient');
  address internal immutable _VOTING_REWARDS_MANAGER = makeAddr('VotingRewardsManager');
  address internal immutable _VOTING_REWARDS_MANAGER_2 = makeAddr('VotingRewardsManager2');
  address internal immutable _UNREGISTERED_VOTING_REWARDS_MANAGER = makeAddr('UnregisteredVotingRewardsManager');

  function test_WhenTheChainStatusIsNotActive(uint256 _tokenId, uint256 _feeMaxCheckpoints, uint8 _statusRaw) external {
    // Every non-Active status keeps claims open: earned rewards stay collectable under Paused, Suspended
    // and through a Sunset wind-down.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(IVoterCommon.ChainStatus.Sunset)));
    _mockChainStatus(IVoterCommon.ChainStatus(_statusRaw));
    _seedOperator(_tokenId);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    // it should claim rewards
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenTheCallerIsNeitherTheOperatorNorLeafMessageOrchestrator(
    uint256 _tokenId,
    address _caller
  ) external {
    _caller = _boundNotEq(_caller, _OPERATOR);
    vm.assume(_caller != _LEAF_MESSAGE_ORCHESTRATOR);

    _seedOperator(_tokenId);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    vm.prank(_caller);
    // it should revert with NotAuthorized
    vm.expectRevert(ILeafVoter.NotAuthorized.selector);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenTheRecipientIsTheZeroAddress(uint256 _tokenId) external {
    _seedOperator(_tokenId);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    vm.prank(_OPERATOR);
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    _leafVoter.claimRewards(_tokenId, address(0), _feeClaims, _incentiveClaims);
  }

  function test_WhenAFeeClaimTargetIsZero(uint256 _tokenId, uint256 _feeMaxCheckpoints) external {
    _seedOperator(_tokenId);
    _mockRewardsToGauge(address(0), address(0));
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](2);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: address(0), maxCheckpoints: _feeMaxCheckpoints});
    _feeClaims[1] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    // it should emit FeeClaimFailed for the zero voting rewards manager
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.FeeClaimFailed(_tokenId, address(0), _feeMaxCheckpoints);

    // it should continue claiming the remaining entries
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenAnIncentiveClaimTargetIsZero(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _seedOperator(_tokenId);
    _mockRewardsToGauge(address(0), address(0));
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER_2, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](2);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: address(0), programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });
    _incentiveClaims[1] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _VOTING_REWARDS_MANAGER_2, programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should emit IncentiveClaimFailed for the zero voting rewards manager
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.IncentiveClaimFailed({
      _tokenId: _tokenId,
      _votingRewardsManager: address(0),
      _programId: _programId,
      _maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should continue claiming the remaining entries
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER_2,
      abi.encodeCall(
        IVotingRewardsManager.claimIncentives, (_tokenId, _RECIPIENT, _programId, _incentiveMaxCheckpoints)
      ),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenAFeeClaimTargetIsNotRegisteredInTheFactoryRegistry(
    uint256 _tokenId,
    uint256 _feeMaxCheckpoints
  ) external {
    _seedOperator(_tokenId);
    vm.etch(_UNREGISTERED_VOTING_REWARDS_MANAGER, hex'69');
    assertGt(_UNREGISTERED_VOTING_REWARDS_MANAGER.code.length, 0);
    _mockRewardsToGauge(_UNREGISTERED_VOTING_REWARDS_MANAGER, address(0));
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](2);
    _feeClaims[0] = ILeafVoter.FeeClaim({
      votingRewardsManager: _UNREGISTERED_VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints
    });
    _feeClaims[1] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    // it should emit FeeClaimFailed for the unregistered voting rewards manager
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.FeeClaimFailed(_tokenId, _UNREGISTERED_VOTING_REWARDS_MANAGER, _feeMaxCheckpoints);

    // it should continue claiming the remaining entries
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenAnIncentiveClaimTargetIsNotRegisteredInTheFactoryRegistry(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _seedOperator(_tokenId);
    vm.etch(_UNREGISTERED_VOTING_REWARDS_MANAGER, hex'69');
    assertGt(_UNREGISTERED_VOTING_REWARDS_MANAGER.code.length, 0);
    _mockRewardsToGauge(_UNREGISTERED_VOTING_REWARDS_MANAGER, address(0));
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER_2, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](2);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _UNREGISTERED_VOTING_REWARDS_MANAGER,
      programId: _programId,
      maxCheckpoints: _incentiveMaxCheckpoints
    });
    _incentiveClaims[1] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _VOTING_REWARDS_MANAGER_2, programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should emit IncentiveClaimFailed for the unregistered voting rewards manager
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.IncentiveClaimFailed({
      _tokenId: _tokenId,
      _votingRewardsManager: _UNREGISTERED_VOTING_REWARDS_MANAGER,
      _programId: _programId,
      _maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should continue claiming the remaining entries
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER_2,
      abi.encodeCall(
        IVotingRewardsManager.claimIncentives, (_tokenId, _RECIPIENT, _programId, _incentiveMaxCheckpoints)
      ),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenARegisteredFeeClaimTargetReverts(uint256 _tokenId, uint256 _feeMaxCheckpoints) external {
    _seedOperator(_tokenId);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    bytes memory _revertData = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    vm.mockCallRevert(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      _revertData
    );

    vm.prank(_OPERATOR);
    // it should bubble the exact revert
    vm.expectRevert(_revertData);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenARegisteredIncentiveClaimTargetReverts(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _seedOperator(_tokenId);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _VOTING_REWARDS_MANAGER, programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    bytes memory _revertData = abi.encodeWithSelector(ReentrancyGuardTransient.ReentrancyGuardReentrantCall.selector);
    vm.mockCallRevert(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(
        IVotingRewardsManager.claimIncentives, (_tokenId, _RECIPIENT, _programId, _incentiveMaxCheckpoints)
      ),
      _revertData
    );

    vm.prank(_OPERATOR);
    // it should bubble the exact revert
    vm.expectRevert(_revertData);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenAllInputsAreValid(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _seedOperator(_tokenId);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER_2, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _VOTING_REWARDS_MANAGER_2, programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should emit FeeClaimSucceeded for the fee claim
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.FeeClaimSucceeded(_tokenId, _VOTING_REWARDS_MANAGER, _RECIPIENT, _feeMaxCheckpoints);

    // it should emit IncentiveClaimSucceeded for the incentive claim
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.IncentiveClaimSucceeded({
      _tokenId: _tokenId,
      _votingRewardsManager: _VOTING_REWARDS_MANAGER_2,
      _programId: _programId,
      _recipient: _RECIPIENT,
      _maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should claim fees and incentives in one call
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      ''
    );
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER_2,
      abi.encodeCall(
        IVotingRewardsManager.claimIncentives, (_tokenId, _RECIPIENT, _programId, _incentiveMaxCheckpoints)
      ),
      ''
    );

    vm.prank(_OPERATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function test_WhenAnInboundClaimIsDeliveredAfterTheChainBecomesInactive(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints,
    uint8 _statusRaw
  ) external {
    // The root accepted this claim while the chain was Active; emulate the Leaf becoming Paused, Suspended
    // or Sunset before the message is delivered.
    _statusRaw =
      uint8(bound(_statusRaw, uint8(IVoterCommon.ChainStatus.Paused), uint8(IVoterCommon.ChainStatus.Sunset)));
    _mockChainStatus(IVoterCommon.ChainStatus(_statusRaw));
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER, _GAUGE);
    _mockRewardsToGauge(_VOTING_REWARDS_MANAGER_2, _GAUGE);

    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] =
      ILeafVoter.FeeClaim({votingRewardsManager: _VOTING_REWARDS_MANAGER, maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: _VOTING_REWARDS_MANAGER_2, programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    // it should process the already-dispatched claim
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER,
      abi.encodeCall(IVotingRewardsManager.claimFees, (_tokenId, _RECIPIENT, _feeMaxCheckpoints)),
      ''
    );
    _mockAndExpect(
      _VOTING_REWARDS_MANAGER_2,
      abi.encodeCall(
        IVotingRewardsManager.claimIncentives, (_tokenId, _RECIPIENT, _programId, _incentiveMaxCheckpoints)
      ),
      ''
    );

    vm.prank(_LEAF_MESSAGE_ORCHESTRATOR);
    _leafVoter.claimRewards(_tokenId, _RECIPIENT, _feeClaims, _incentiveClaims);
  }

  function _seedOperator(uint256 _tokenId) private {
    bytes32 _tokenStateSlot = keccak256(abi.encode(_tokenId, _TOKEN_STATE_SLOT));
    vm.store(address(_leafVoter), _tokenStateSlot, bytes32(uint256(uint160(_OPERATOR))));
    assertEq(_leafVoter.operator(_tokenId), _OPERATOR);
  }

  function _mockRewardsToGauge(address _votingRewardsManager, address _gauge) private {
    _mockAndExpect(
      _GAUGE_FACTORY, abi.encodeCall(IFactoryRegistry.rewardsToGauge, (_votingRewardsManager)), abi.encode(_gauge)
    );
  }
}
