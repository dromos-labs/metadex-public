// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMessageOrchestrator} from 'V3/interfaces/bridge/IMessageOrchestrator.sol';
import {IRootMessageOrchestrator} from 'V3/interfaces/bridge/IRootMessageOrchestrator.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {BaseVoter, IVoter, IVoterCommon, IVotingEscrow} from 'V3-test/unit/voter/BaseVoter.sol';

contract UnitVoterClaimRewards is BaseVoter {
  function _buildClaimRewardsParams(
    uint256 _chainId,
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints,
    uint256 _transportNativeFee
  )
    internal
    view
    returns (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    )
  {
    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: address(0xfee), maxCheckpoints: _feeMaxCheckpoints});

    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: address(0x1ee), programId: _programId, maxCheckpoints: _incentiveMaxCheckpoints
    });

    _claimRewardsParams = new IVoter.ClaimRewardsParams[](1);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: _chainId,
      gasLimit: _GAS_LIMIT,
      value: _transportNativeFee,
      recipient: _recipient,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });

    _expectedDispatches = new IRootMessageOrchestrator.ChainDispatch[](1);
    _expectedDispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _chainId,
      gasLimit: _GAS_LIMIT,
      nativeValue: _transportNativeFee,
      chargeDeallocationReturn: false,
      payload: abi.encode(
        _tokenId, uint48(block.timestamp) + _MESSAGE_LIFETIME, _recipient, _feeClaims, _incentiveClaims
      )
    });
  }

  function test_WhenCallerIsNotAuthorizedForAToken(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(false));

    vm.prank(_CALLER);
    // it should revert with NotAuthorized
    vm.expectRevert(IVoter.NotAuthorized.selector);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenClaimRewardsParamsAreEmpty(uint256 _tokenId, uint256 _msgValue) external {
    _msgValue = bound(_msgValue, 0, type(uint128).max);
    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](0);

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.deal(_CALLER, _msgValue);
    vm.prank(_CALLER);
    // it should revert with EmptyClaimRewardsParams
    vm.expectRevert(IVoter.EmptyClaimRewardsParams.selector);
    _voter.claimRewards{value: _msgValue}(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenAClaimRewardsParamContainsNoFeeOrIncentiveClaims(uint256 _tokenId, address _recipient) external {
    _recipient = _excludingAddressZero(_recipient);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) =
      _buildClaimRewardsParams(_CHAIN_ID_1, _tokenId, _recipient, 0, 0, 0, 0);
    _claimRewardsParams[0].feeClaims = new ILeafVoter.FeeClaim[](0);
    _claimRewardsParams[0].incentiveClaims = new ILeafVoter.IncentiveClaim[](0);

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with EmptyClaimRewardsParams
    vm.expectRevert(IVoter.EmptyClaimRewardsParams.selector);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenAClaimRewardsParamContainsOnlyFeeClaims(
    uint256 _tokenId,
    address _recipient,
    uint256 _feeMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    ) = _buildClaimRewardsParams(_CHAIN_ID_1, _tokenId, _recipient, 0, _feeMaxCheckpoints, 0, 0);
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](0);
    _claimRewardsParams[0].incentiveClaims = _incentiveClaims;
    _expectedDispatches[0].payload = abi.encode(
      _tokenId,
      uint48(block.timestamp) + _MESSAGE_LIFETIME,
      _recipient,
      _claimRewardsParams[0].feeClaims,
      _incentiveClaims
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should dispatch ClaimRewards with the fee claims
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      0,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenAClaimRewardsParamContainsOnlyIncentiveClaims(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    ) = _buildClaimRewardsParams(_CHAIN_ID_1, _tokenId, _recipient, _programId, 0, _incentiveMaxCheckpoints, 0);
    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](0);
    _claimRewardsParams[0].feeClaims = _feeClaims;
    _expectedDispatches[0].payload = abi.encode(
      _tokenId,
      uint48(block.timestamp) + _MESSAGE_LIFETIME,
      _recipient,
      _feeClaims,
      _claimRewardsParams[0].incentiveClaims
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should dispatch ClaimRewards with the incentive claims
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      0,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenADestinationChainIsNotRegistered(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _UNREGISTERED_CHAIN_ID, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));
    vm.mockCall(_ORCHESTRATOR, abi.encodeWithSelector(IRootMessageOrchestrator.dispatch.selector), '');

    vm.prank(_CALLER);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _UNREGISTERED_CHAIN_ID));
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenARegisteredDestinationChainIsPaused(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Paused);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN_ID_1));
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenARegisteredDestinationChainIsSuspended(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Suspended);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with ChainNotActiveOrSunset
    vm.expectRevert(abi.encodeWithSelector(IVoter.ChainNotActiveOrSunset.selector, _CHAIN_ID_1));
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenARegisteredDestinationChainIsSunset(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints,
    uint256 _transportNativeFee
  ) external {
    // A sunset chain keeps claims open so holders can collect rewards while exiting.
    _recipient = _excludingAddressZero(_recipient);
    _transportNativeFee = bound(_transportNativeFee, 0, type(uint128).max);
    _mockChainStatus(_CHAIN_ID_1, IVoterCommon.ChainStatus.Sunset);
    (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    ) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, _transportNativeFee
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should dispatch ClaimRewards to the sunset chain
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      _transportNativeFee,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.deal(_CALLER, _transportNativeFee);
    vm.prank(_CALLER);
    _voter.claimRewards{value: _transportNativeFee}(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenTheRecipientIsTheZeroAddress(
    uint256 _tokenId,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, address(0), _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenClaimRewardsParamsChainIdsAreNotStrictlyAscending(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);

    (IVoter.ClaimRewardsParams[] memory _firstParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_2, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    (IVoter.ClaimRewardsParams[] memory _secondParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](2);
    _claimRewardsParams[0] = _firstParams[0];
    _claimRewardsParams[1] = _secondParams[0];

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with ClaimRewardsParamsNotStrictlyAscending
    vm.expectRevert(IVoter.ClaimRewardsParamsNotStrictlyAscending.selector);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenANonRootChainGasLimitIsZero(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (IVoter.ClaimRewardsParams[] memory _claimRewardsParams,) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    _claimRewardsParams[0].gasLimit = 0;

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    vm.prank(_CALLER);
    // it should revert with MissingDestinationGasLimit
    vm.expectRevert(abi.encodeWithSelector(IVoter.MissingDestinationGasLimit.selector, _CHAIN_ID_1));
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenTheRootChainInputIsValid(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    ) = _buildClaimRewardsParams(
      block.chainid, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    _claimRewardsParams[0].gasLimit = 0;
    _expectedDispatches[0].gasLimit = 0;

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should dispatch ClaimRewards through the root chain entry without forwarding native value
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      0,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenRootAndNonRootChainInputsAreValid(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    (IVoter.ClaimRewardsParams[] memory _leafParams, IRootMessageOrchestrator.ChainDispatch[] memory _leafDispatches) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    (IVoter.ClaimRewardsParams[] memory _rootParams, IRootMessageOrchestrator.ChainDispatch[] memory _rootDispatches) = _buildClaimRewardsParams(
      block.chainid, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, 0
    );
    _rootParams[0].gasLimit = 0;
    _rootDispatches[0].gasLimit = 0;

    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](2);
    _claimRewardsParams[0] = _leafParams[0];
    _claimRewardsParams[1] = _rootParams[0];
    IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches =
      new IRootMessageOrchestrator.ChainDispatch[](2);
    _expectedDispatches[0] = _leafDispatches[0];
    _expectedDispatches[1] = _rootDispatches[0];

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      0,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.prank(_CALLER);
    _voter.claimRewards(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenMultipleChainInputsAreValid(
    uint256 _tokenId,
    uint256 _transportNativeFeeOne,
    uint256 _transportNativeFeeTwo
  ) external {
    _transportNativeFeeOne = bound(_transportNativeFeeOne, 0, type(uint128).max);
    _transportNativeFeeTwo = bound(_transportNativeFeeTwo, 0, type(uint128).max);
    uint256 _totalValue = _transportNativeFeeOne + _transportNativeFeeTwo;

    address _recipientOne = address(0xA11CE);
    address _recipientTwo = address(0xB0B);

    ILeafVoter.FeeClaim[] memory _chainOneFeeClaims = new ILeafVoter.FeeClaim[](2);
    _chainOneFeeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: address(0xFEE1), maxCheckpoints: 11});
    _chainOneFeeClaims[1] = ILeafVoter.FeeClaim({votingRewardsManager: address(0xFEE2), maxCheckpoints: 12});

    ILeafVoter.IncentiveClaim[] memory _chainOneIncentiveClaims = new ILeafVoter.IncentiveClaim[](2);
    _chainOneIncentiveClaims[0] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: address(0x1EE1), programId: 21, maxCheckpoints: 31});
    _chainOneIncentiveClaims[1] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: address(0x1EE2), programId: 22, maxCheckpoints: 32});

    ILeafVoter.FeeClaim[] memory _chainTwoFeeClaims = new ILeafVoter.FeeClaim[](2);
    _chainTwoFeeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: address(0xFEE3), maxCheckpoints: 13});
    _chainTwoFeeClaims[1] = ILeafVoter.FeeClaim({votingRewardsManager: address(0xFEE4), maxCheckpoints: 14});

    ILeafVoter.IncentiveClaim[] memory _chainTwoIncentiveClaims = new ILeafVoter.IncentiveClaim[](2);
    _chainTwoIncentiveClaims[0] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: address(0x1EE3), programId: 23, maxCheckpoints: 33});
    _chainTwoIncentiveClaims[1] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: address(0x1EE4), programId: 24, maxCheckpoints: 34});

    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](2);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: _CHAIN_ID_1,
      gasLimit: _GAS_LIMIT,
      value: _transportNativeFeeOne,
      recipient: _recipientOne,
      feeClaims: _chainOneFeeClaims,
      incentiveClaims: _chainOneIncentiveClaims
    });
    _claimRewardsParams[1] = IVoter.ClaimRewardsParams({
      chainId: _CHAIN_ID_2,
      gasLimit: _GAS_LIMIT + 1,
      value: _transportNativeFeeTwo,
      recipient: _recipientTwo,
      feeClaims: _chainTwoFeeClaims,
      incentiveClaims: _chainTwoIncentiveClaims
    });

    IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches =
      new IRootMessageOrchestrator.ChainDispatch[](2);
    _expectedDispatches[0] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _CHAIN_ID_1,
      gasLimit: _GAS_LIMIT,
      nativeValue: _transportNativeFeeOne,
      chargeDeallocationReturn: false,
      payload: abi.encode(
        _tokenId,
        uint48(block.timestamp) + _MESSAGE_LIFETIME,
        _recipientOne,
        _chainOneFeeClaims,
        _chainOneIncentiveClaims
      )
    });
    _expectedDispatches[1] = IRootMessageOrchestrator.ChainDispatch({
      chainId: _CHAIN_ID_2,
      gasLimit: _GAS_LIMIT + 1,
      nativeValue: _transportNativeFeeTwo,
      chargeDeallocationReturn: false,
      payload: abi.encode(
        _tokenId,
        uint48(block.timestamp) + _MESSAGE_LIFETIME,
        _recipientTwo,
        _chainTwoFeeClaims,
        _chainTwoIncentiveClaims
      )
    });

    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should emit RewardsClaimDispatched for each destination
    _expectEmit(address(_voter));
    emit IVoter.RewardsClaimDispatched(_tokenId, _CHAIN_ID_1, _recipientOne);
    _expectEmit(address(_voter));
    emit IVoter.RewardsClaimDispatched(_tokenId, _CHAIN_ID_2, _recipientTwo);

    // it should encode each chain with all fee and incentive claims in one dispatch call
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      _totalValue,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.deal(_CALLER, _totalValue);
    vm.prank(_CALLER);
    _voter.claimRewards{value: _totalValue}(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }

  function test_WhenAllInputsAreValid(
    uint256 _tokenId,
    address _recipient,
    uint256 _programId,
    uint256 _feeMaxCheckpoints,
    uint256 _incentiveMaxCheckpoints,
    uint256 _transportNativeFee
  ) external {
    _recipient = _excludingAddressZero(_recipient);
    _transportNativeFee = bound(_transportNativeFee, 0, type(uint128).max);
    (
      IVoter.ClaimRewardsParams[] memory _claimRewardsParams,
      IRootMessageOrchestrator.ChainDispatch[] memory _expectedDispatches
    ) = _buildClaimRewardsParams(
      _CHAIN_ID_1, _tokenId, _recipient, _programId, _feeMaxCheckpoints, _incentiveMaxCheckpoints, _transportNativeFee
    );

    // it should check authorization for the tokenId
    _mockAndExpect(_VOTING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorized, (_CALLER, _tokenId)), abi.encode(true));

    // it should encode and dispatch ClaimRewards with the supplied params and refund recipient forwarding msg value
    _mockAndExpectWithValue(
      _ORCHESTRATOR,
      _transportNativeFee,
      abi.encodeCall(
        IRootMessageOrchestrator.dispatch,
        (IMessageOrchestrator.MessageType.ClaimRewards, _expectedDispatches, _REFUND_RECIPIENT)
      ),
      ''
    );

    vm.deal(_CALLER, _transportNativeFee);
    vm.prank(_CALLER);
    _voter.claimRewards{value: _transportNativeFee}(_tokenId, _claimRewardsParams, _REFUND_RECIPIENT);
  }
}
