// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {SafeCast} from '@openzeppelin/contracts/utils/math/SafeCast.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';

/// @notice sTOKEN / relays module tests: `CREATE_STAKE` mints and either delivers or retains a fresh sAERO, and
///         `DEPOSIT_RELAY` passes an existing or in-flight sAERO through a relay deposit. The commands run through the
///         real `execute` entrypoint on a router deployed as root; every dependency is mocked, including the escrow, so
///         no ERC721 double is deployed.
contract UnitStakeRelay is BaseMetarouter {
  /// @notice Caller-selected relay the deposit-relay tests encode into the command input and drive `requestDeposit` on.
  address internal immutable _RELAY = _mockContract('Relay');
  /// @notice VoterPaymentsModule the relay reports from `VPM`; the escrow vouches for it before the operator grant.
  address internal immutable _VPM = _mockContract('Vpm');

  /// @inheritdoc BaseMetarouter
  function _deployAsRoot() internal pure override returns (bool _isRoot) {
    return true;
  }

  /// @notice Encodes a call to the three-argument `requestDeposit`. `IRelay` overloads that name, so
  ///         `abi.encodeCall` cannot reference it and the signature is written out instead.
  function _requestDepositCalldata(
    uint256 _tokenId,
    uint256 _amount,
    address _recipient
  ) internal pure returns (bytes memory _data) {
    _data = abi.encodeWithSignature('requestDeposit(uint256,uint256,address)', _tokenId, _amount, _recipient);
  }

  // ============================== createStake ==============================

  function test_CreateStakeWhenTheRecipientIsTheZeroAddress(
    address _caller,
    uint128 _amount,
    uint48 _stakingWeeks,
    bool _isPermanent
  ) external {
    // The recipient guard runs before funding, so no token mocks are needed.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount), false, _stakingWeeks, _isPermanent, address(0)
    );

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRecipientIsValid(address _recipient) {
    _assumeFuzzable(_recipient);
    _;
  }

  modifier givenTheRelayRecipientIsValid(address _recipient) {
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != address(_metarouter));
    _;
  }

  function test_CreateStakeWhenTheFundedAmountExceedsTheEscrowStakeWidth(
    address _caller,
    uint256 _amount,
    uint48 _stakingWeeks,
    bool _isPermanent,
    address _recipient
  ) external givenTheRecipientIsValid(_recipient) {
    // The caller does not affect the SafeCast revert, so it is fuzzed unconstrained to prove that invariance.
    // The escrow stakes a uint128 amount, so a funded amount above that width overflows the downcast, which runs
    // before the escrow approval.
    _amount = bound(_amount, uint256(type(uint128).max) + 1, type(uint256).max);
    // Funding resolves the amount against the router balance.
    _mockAndExpectTokenBalance(_STAKING_TOKEN, address(_metarouter), _amount);

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount), false, _stakingWeeks, _isPermanent, _recipient
    );

    // it should revert with SafeCastOverflowedUintDowncast for _amount
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(SafeCast.SafeCastOverflowedUintDowncast.selector, 128, _amount));
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CreateStakeWhenTheFundedAmountFitsTheEscrowStakeWidth(
    address _caller,
    uint128 _amount,
    uint48 _stakingWeeks,
    bool _isPermanent,
    address _recipient,
    uint256 _tokenId
  ) external givenTheRecipientIsValid(_recipient) {
    _assumeFuzzable(_caller);
    // This branch exercises direct delivery. The router address selects the in-flight path instead, which is covered
    // by the combined CREATE_STAKE -> DEPOSIT_RELAY test below.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // `_amount` spans the full uint128 range, including zero: the zero-amount guard belongs to the escrow, so the
    // router forwards any width-fitting amount faithfully.

    // Fund the staking token from the router balance; the closure read then returns zero so no closing sweep runs.
    _mockAndExpectTokenBalancesTwice(_STAKING_TOKEN, address(_metarouter), [uint256(_amount), uint256(0)]);
    // it should fund _stakingToken and call createStake with _amount, _stakingWeeks and _isPermanent
    _mockAndExpect(_STAKING_TOKEN, abi.encodeCall(IERC20.approve, (_STAKING_ESCROW, _amount)), abi.encode(true));
    _mockAndExpect(
      _STAKING_ESCROW,
      abi.encodeCall(IVotingEscrow.createStake, (_amount, _stakingWeeks, _isPermanent)),
      abi.encode(_tokenId)
    );
    // it should deliver the minted sAERO to _recipient
    _mockAndExpect(
      _STAKING_ESCROW,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount), false, _stakingWeeks, _isPermanent, _recipient
    );

    // it should emit BatchExecuted with _sender
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CreateStakeWhenThePayerIsTheUserAndTheSpendModeIsPips(
    address _caller,
    uint256 _pips,
    uint48 _stakingWeeks,
    bool _isPermanent,
    address _recipient
  ) external givenTheRecipientIsValid(_recipient) {
    // A user-paid stake accepts only `Amount`: the pull is bounded by the caller's ERC20 approval, so a share of the
    // wallet has no meaning. The guard runs before any balance read, so no token mocks are needed. `_pips` is fuzzed
    // unconstrained, including in-range values, to prove the mode is rejected before its value is ever validated.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Pips, _pips), true, _stakingWeeks, _isPermanent, _recipient
    );

    // it should revert with InvalidSpendMode
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidSpendMode.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_CreateStakeWhenThePayerIsTheUserAndTheSpendModeIsAnAmount(
    address _caller,
    uint256 _spendValue,
    uint256 _received,
    uint48 _stakingWeeks,
    bool _isPermanent,
    address _recipient,
    uint256 _tokenId
  ) external givenTheRecipientIsValid(_recipient) {
    _assumeFuzzable(_caller);
    // The router address selects the in-flight path; this branch exercises direct delivery of a user-funded stake.
    _recipient = _boundNotEq(_recipient, address(_metarouter));
    // The escrow stakes a uint128, so the pulled value stays within that width. `_received` is bounded at or below it
    // so the staked amount is the measured delta, not the requested value: that is what keeps fee-on-transfer staking
    // tokens usable, and it is the property this branch exists to pin.
    _spendValue = bound(_spendValue, 0, type(uint128).max);
    _received = bound(_received, 0, _spendValue);

    // Balances are read three times: before the pull, after it to measure the delta, and once at closure. The token is
    // tracked by the pull, so the closing read returns zero and no sweep transfer runs.
    uint256[] memory _balances = new uint256[](3);
    _balances[1] = _received;
    _mockAndExpectTokenBalances(_STAKING_TOKEN, address(_metarouter), _balances);
    // it should pull the spend value from the logical sender into the execution address
    _mockAndExpect(
      _STAKING_TOKEN,
      abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _spendValue)),
      abi.encode(true)
    );
    // it should stake the received delta and deliver the minted sAERO to _recipient
    _mockAndExpect(
      _STAKING_TOKEN, abi.encodeCall(IERC20.approve, (_STAKING_ESCROW, uint128(_received))), abi.encode(true)
    );
    _mockAndExpect(
      _STAKING_ESCROW,
      abi.encodeCall(IVotingEscrow.createStake, (uint128(_received), _stakingWeeks, _isPermanent)),
      abi.encode(_tokenId)
    );
    _mockAndExpect(
      _STAKING_ESCROW,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _spendValue), true, _stakingWeeks, _isPermanent, _recipient
    );

    // it should emit BatchExecuted with _sender
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== depositRelay ==============================

  function test_DepositRelayWhenTheRecipientIsTheZeroAddress(
    address _caller,
    uint256 _tokenId,
    uint256 _amount
  ) external {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, address(0));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DepositRelayWhenTheRecipientIsTheMetarouter(
    address _caller,
    uint256 _tokenId,
    uint256 _amount
  ) external {
    // A router recipient would receive the deposit shares at keeper settlement, outside any batch, where the
    // permissionless SWEEP takes them.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, address(_metarouter));

    // it should revert with InvalidRecipient
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.InvalidRecipient.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DepositRelayWhenTheRelayIsNotRegisteredWithTheFactory(
    address _caller,
    uint256 _tokenId,
    uint256 _amount,
    address _recipient
  ) external givenTheRelayRecipientIsValid(_recipient) {
    // The relay is authenticated before anything it reports is trusted, so an unregistered relay reverts before the
    // VPM read or any custody move. The caller cannot affect the revert, so it is fuzzed unconstrained.
    _mockAndExpect(_RELAY_FACTORY, abi.encodeCall(IRelayFactory.isRelay, (_RELAY)), abi.encode(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, _recipient);

    // it should revert with UnauthorizedRelay
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.UnauthorizedRelay.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRelayIsRegisteredWithTheFactory() {
    // The factory vouches for the relay, so the router proceeds to vet its VPM and take custody.
    _mockAndExpect(_RELAY_FACTORY, abi.encodeCall(IRelayFactory.isRelay, (_RELAY)), abi.encode(true));
    _;
  }

  function test_DepositRelayWhenTheRelayReportsAVpmTheEscrowDoesNotRecognize(
    address _caller,
    uint256 _tokenId,
    uint256 _amount,
    address _vpm,
    address _recipient
  ) external givenTheRelayRecipientIsValid(_recipient) givenTheRelayIsRegisteredWithTheFactory {
    // The VPM is vetted before custody is taken, so the command reverts without pulling the sAERO in. The caller
    // cannot affect the revert, so it is fuzzed unconstrained to prove that invariance.
    _mockAndExpect(_RELAY, abi.encodeCall(IRelay.VPM, ()), abi.encode(_vpm));
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_vpm)), abi.encode(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, _recipient);

    // it should revert with UnauthorizedRelayVpm
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.UnauthorizedRelayVpm.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheRelayVpmIsRecognizedByTheEscrow() {
    // The relay names its VPM and the escrow recognizes it, so the router grants it the operator approval.
    _mockAndExpect(_RELAY, abi.encodeCall(IRelay.VPM, ()), abi.encode(_VPM));
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_VPM)), abi.encode(true));
    _;
  }

  function test_DepositRelayWhenTheTokenIdIsTheInFlightSentinelWithoutAnInFlightPosition(
    address _caller,
    uint256 _amount,
    address _recipient
  )
    external
    givenTheRelayRecipientIsValid(_recipient)
    givenTheRelayIsRegisteredWithTheFactory
    givenTheRelayVpmIsRecognizedByTheEscrow
  {
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(uint256(0), _amount, _RELAY, _recipient);

    // it should revert with NoInFlightNft
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NoInFlightNft.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DepositRelayWhenTheRouterOwnsThePositionButItWasNotTrackedThisBatch(
    address _caller,
    uint256 _tokenId,
    uint256 _amount,
    address _recipient
  )
    external
    givenTheRelayRecipientIsValid(_recipient)
    givenTheRelayIsRegisteredWithTheFactory
    givenTheRelayVpmIsRecognizedByTheEscrow
  {
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, _recipient);

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DepositRelayWhenTheCallerRequestsARelayDeposit(
    address _caller,
    uint256 _tokenId,
    uint256 _amount,
    address _recipient
  )
    external
    givenTheRelayRecipientIsValid(_recipient)
    givenTheRelayIsRegisteredWithTheFactory
    givenTheRelayVpmIsRecognizedByTheEscrow
  {
    // The pull and the return move the sAERO between the caller and the router, so their calldata must differ: exclude
    // a caller equal to the router, which would collapse both transfers onto the same call.
    _caller = _boundNotEq(_caller, address(_metarouter));
    // Token id zero is reserved for the in-flight sentinel; this branch exercises an existing caller-owned sAERO.
    _tokenId = bound(_tokenId, 1, type(uint256).max);

    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_caller));
    // it should pull the sAERO from the caller with transferFrom
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.transferFrom, (_caller, address(_metarouter), _tokenId)), '');
    // it should grant the vpm operator approval and approve the relay for _tokenId
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, true)), '');
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.approve, (_RELAY, _tokenId)), '');
    // it should request the deposit with _tokenId, _amount and the selected share recipient
    _mockAndExpect(_RELAY, _requestDepositCalldata(_tokenId, _amount, _recipient), '');
    // it should revoke the vpm operator approval and return the sAERO to the caller
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, false)), '');
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.transferFrom, (address(_metarouter), _caller, _tokenId)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_tokenId, _amount, _RELAY, _recipient);

    // it should emit BatchExecuted with _sender
    _expectEmit(address(_metarouter));
    emit IMetarouter.BatchExecuted(_caller);
    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_DepositRelayWhenTheTokenIdIsTheInFlightSentinel(
    address _caller,
    uint128 _stakeAmount,
    uint48 _stakingWeeks,
    bool _isPermanent,
    uint256 _tokenId,
    uint256 _relayAmount,
    address _recipient
  )
    external
    givenTheRelayRecipientIsValid(_recipient)
    givenTheRelayIsRegisteredWithTheFactory
    givenTheRelayVpmIsRecognizedByTheEscrow
  {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _tokenId = bound(_tokenId, 1, type(uint256).max);

    _mockAndExpectTokenBalancesTwice(_STAKING_TOKEN, address(_metarouter), [uint256(_stakeAmount), uint256(0)]);
    _mockAndExpect(_STAKING_TOKEN, abi.encodeCall(IERC20.approve, (_STAKING_ESCROW, _stakeAmount)), abi.encode(true));
    _mockAndExpect(
      _STAKING_ESCROW,
      abi.encodeCall(IVotingEscrow.createStake, (_stakeAmount, _stakingWeeks, _isPermanent)),
      abi.encode(_tokenId)
    );

    // it should resolve the in flight sAERO without pulling it from the caller
    // it should request the deposit with the resolved token id and selected share recipient
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, true)), '');
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.approve, (_RELAY, _tokenId)), '');
    _mockAndExpect(_RELAY, _requestDepositCalldata(_tokenId, _relayAmount, _recipient), '');
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, false)), '');
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.transferFrom, (address(_metarouter), _caller, _tokenId)), '');
    _mockOwnerTransition(_tokenId, _caller);

    bytes memory _commands =
      abi.encodePacked(bytes1(uint8(Commands.CREATE_STAKE)), bytes1(uint8(Commands.DEPOSIT_RELAY)));
    bytes[] memory _inputs = new bytes[](2);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _stakeAmount),
      false,
      _stakingWeeks,
      _isPermanent,
      address(_metarouter)
    );
    _inputs[1] = abi.encode(uint256(0), _relayAmount, _RELAY, _recipient);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should consume the in flight sAERO
    (address _inFlightCollection, uint256 _inFlightTokenId) = _metarouter.inFlightNft();
    assertEq(_inFlightCollection, address(0));
    assertEq(_inFlightTokenId, 0);
  }

  function test_DepositRelayWhenTheInFlightPositionIsDepositedTwice() external {
    address _caller = makeAddr('doubleDepositCaller');
    address _firstRecipient = makeAddr('firstShareRecipient');
    address _secondRecipient = makeAddr('secondShareRecipient');
    uint256 _tokenId = 1;

    _mockAndExpectTokenBalancesTwice(_STAKING_TOKEN, address(_metarouter), [uint256(1), uint256(0)]);
    _mockAndExpect(_STAKING_TOKEN, abi.encodeCall(IERC20.approve, (_STAKING_ESCROW, 1)), abi.encode(true));
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.createStake, (1, 1, false)), abi.encode(_tokenId));

    _mockAndExpectWithTimes(_RELAY_FACTORY, abi.encodeCall(IRelayFactory.isRelay, (_RELAY)), abi.encode(true), 2);
    _mockAndExpectWithTimes(_RELAY, abi.encodeCall(IRelay.VPM, ()), abi.encode(_VPM), 2);
    _mockAndExpectWithTimes(_STAKING_ESCROW, abi.encodeCall(IVotingEscrow.isAuthorizedVPM, (_VPM)), abi.encode(true), 2);

    // The first deposit sees the router as owner, the second sees the returned position at the caller, and closure
    // checks that it left the router again.
    _mockOwnerSequence(_tokenId, _caller);

    _mockAndExpectWithTimes(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, true)), '', 2);
    _mockAndExpectWithTimes(_STAKING_ESCROW, abi.encodeCall(IERC721.approve, (_RELAY, _tokenId)), '', 2);
    // it should request both deposits with the selected share recipients
    _mockAndExpect(_RELAY, _requestDepositCalldata(_tokenId, 1, _firstRecipient), '');
    _mockAndExpect(_RELAY, _requestDepositCalldata(_tokenId, 2, _secondRecipient), '');
    _mockAndExpectWithTimes(_STAKING_ESCROW, abi.encodeCall(IERC721.setApprovalForAll, (_VPM, false)), '', 2);
    _mockAndExpectWithTimes(
      _STAKING_ESCROW, abi.encodeCall(IERC721.transferFrom, (address(_metarouter), _caller, _tokenId)), '', 2
    );
    // it should reacquire the returned sAERO before the second deposit
    _mockAndExpect(_STAKING_ESCROW, abi.encodeCall(IERC721.transferFrom, (_caller, address(_metarouter), _tokenId)), '');

    bytes memory _commands = abi.encodePacked(
      bytes1(uint8(Commands.CREATE_STAKE)), bytes1(uint8(Commands.DEPOSIT_RELAY)), bytes1(uint8(Commands.DEPOSIT_RELAY))
    );
    bytes[] memory _inputs = new bytes[](3);
    _inputs[0] = abi.encode(
      IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, 1), false, uint48(1), false, address(_metarouter)
    );
    _inputs[1] = abi.encode(uint256(0), uint256(1), _RELAY, _firstRecipient);
    _inputs[2] = abi.encode(_tokenId, uint256(2), _RELAY, _secondRecipient);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should leave the in flight slots cleared
    (address _inFlightCollection, uint256 _inFlightTokenId) = _metarouter.inFlightNft();
    assertEq(_inFlightCollection, address(0));
    assertEq(_inFlightTokenId, 0);
  }

  /// @notice Mocks router ownership during the deposit and caller ownership at closure.
  function _mockOwnerTransition(uint256 _tokenId, address _caller) internal {
    bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_tokenId));
    bytes[] memory _ownerResponses = new bytes[](2);
    _ownerResponses[0] = abi.encode(address(_metarouter));
    _ownerResponses[1] = abi.encode(_caller);
    vm.mockCalls(_STAKING_ESCROW, _ownerOfCall, _ownerResponses);
    vm.expectCall(_STAKING_ESCROW, _ownerOfCall, 2);
  }

  /// @notice Mocks ownership across both deposits and the closing custody check.
  function _mockOwnerSequence(uint256 _tokenId, address _caller) internal {
    bytes memory _ownerOfCall = abi.encodeCall(IERC721.ownerOf, (_tokenId));
    bytes[] memory _ownerResponses = new bytes[](3);
    _ownerResponses[0] = abi.encode(address(_metarouter));
    _ownerResponses[1] = abi.encode(_caller);
    _ownerResponses[2] = abi.encode(_caller);
    vm.mockCalls(_STAKING_ESCROW, _ownerOfCall, _ownerResponses);
    vm.expectCall(_STAKING_ESCROW, _ownerOfCall, 3);
  }
}
