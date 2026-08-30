// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {IGaugeFactory} from 'V3/interfaces/factories/IGaugeFactory.sol';
import {IGauge} from 'V3/interfaces/gauges/IGauge.sol';
import {IV2Gauge} from 'V3/interfaces/gauges/IV2Gauge.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {Commands} from 'V3/metarouter/libraries/Commands.sol';

import {BaseMetarouter} from 'V3-test/unit/metarouter/Metarouter/BaseMetarouter.sol';
import {MetarouterHarness} from 'V3-test/unit/metarouter/harnesses/MetarouterHarness.sol';
import {NftReturnProbe} from 'V3-test/unit/metarouter/harnesses/NftReturnProbe.sol';

/// @notice Staking module tests: the router validates gauge targets, funds or pulls stakes, and reuses positions
///         already in custody. Every external dependency is mocked; a custodied position is seeded by writing the
///         harness custody state directly, so no ERC721 double is deployed. The receiver hook and the batch-closure
///         NFT check are the router's own behaviors, covered by the Metarouter suite.
contract UnitStaking is BaseMetarouter {
  /// @notice Gauge target exercised by the handler tests.
  address internal immutable _GAUGE = _mockContract('Gauge');
  /// @notice V2 LP staking token the V2 gauge reports, funded and swept by the V2 staking tests.
  address internal immutable _LP_TOKEN = _mockContract('LpToken');

  // ============================== stakeGauge ==============================

  function test_StakeGaugeGivenALiteDeploymentWithNoLeafVoter(address _caller) external {
    _assumeFuzzable(_caller);
    // A lite deployment carries no voting system, so the gauge commands are gated off. The guard is the first
    // statement of the dispatch branch, so the command reverts before the input is decoded and before any gauge or
    // Voter read; the input can stay empty.
    MetarouterHarness _liteMetarouter = _deployLiteMetarouter();

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = '';

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.STAKE_GAUGE));
    _liteMetarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_StakeGaugeWhenTheGaugeIsNotRegistered(address _caller, uint256 _tokenId) external {
    // The Voter reports the gauge as never produced by an approved factory (isRegistered false).
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.gaugeStates, (_GAUGE)), _encodedGaugeState(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId));

    // it should revert with GaugeNotRegistered
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.GaugeNotRegistered.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheGaugeIsRegistered() {
    // The Voter reports the gauge as produced by an approved factory.
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.gaugeStates, (_GAUGE)), _encodedGaugeState(true));
    _;
  }

  modifier givenTheGaugeIsAClGauge() {
    // The gauge's factory reports the CL venue.
    _mockGaugeType(_GAUGE, 'cl');
    _;
  }

  function test_StakeGaugeWhenTheTokenIdIsTheInFlightSentinel(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // A zero token id in the command is the in-flight sentinel: seed the position the batch just produced, so the
    // handler resolves the sentinel to this concrete id and consumes it once the position leaves.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    _metarouter.setInFlightNft(_POSITION_MANAGER, _tokenId);
    // The stake reuses the in-flight position; the mocked deposit does not move it, so the closing ownership read
    // returns a new owner to model the position leaving.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    // it should not pull the position from the sender
    vm.mockCallRevert(_POSITION_MANAGER, abi.encodeWithSelector(IERC721.transferFrom.selector), bytes('no pull'));
    // it should approve the gauge
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.approve, (_GAUGE, _tokenId)), '');
    // it should deposit for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (_tokenId, _caller)), '');

    // The command carries the zero sentinel in place of the concrete id.
    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(uint256(0)));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the in flight slots at closure
    (address _collection,) = _metarouter.inFlightNft();
    assertEq(_collection, address(0), 'in-flight not cleared');
  }

  modifier givenThePositionIsAlreadyInCustody() {
    // The custody precondition is seeded per-test against the fuzzed token id, so it cannot be hoisted here.
    _;
  }

  function test_StakeGaugeWhenTheCustodiedPositionWasNotTrackedThisBatch(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge givenThePositionIsAlreadyInCustody {
    // A zero token id is the in-flight sentinel resolved before the custody check, so bound it away to hit this branch.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // The router already holds the position, but nothing brought it into custody this batch, so it may not be operated.
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId));

    // it should revert with NftNotInCustody
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotInCustody.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_StakeGaugeWhenTheCustodiedPositionWasTrackedThisBatch(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge givenThePositionIsAlreadyInCustody {
    _assumeFuzzable(_caller);
    // A zero token id is the in-flight sentinel; bound it away so the custodied id is a concrete position.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    _metarouter.trackNft(_POSITION_MANAGER, _tokenId);
    // The stake reuses the custodied position; the mocked deposit does not move it, so the closing ownership read
    // returns a new owner to model the position leaving.
    bytes[] memory _owners = new bytes[](2);
    _owners[0] = abi.encode(address(_metarouter));
    _owners[1] = abi.encode(makeAddr('newPositionOwner'));
    _mockAndExpectSequence(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), _owners);
    // it should not pull the position from the sender
    vm.mockCallRevert(_POSITION_MANAGER, abi.encodeWithSelector(IERC721.transferFrom.selector), bytes('no pull'));
    // it should approve the gauge
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.approve, (_GAUGE, _tokenId)), '');
    // it should deposit for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (_tokenId, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_StakeGaugeWhenThePositionIsNotAlreadyInCustody(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    // A zero token id is the in-flight sentinel; bound it away so this pulls a concrete position from the caller.
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    // The position is not yet held by the router, so it is pulled from the logical sender before the gauge deposit.
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_caller));
    // it should pull the position from _owner
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(IERC721.transferFrom, (_caller, address(_metarouter), _tokenId)), ''
    );
    // it should approve the gauge
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.approve, (_GAUGE, _tokenId)), '');
    // it should deposit for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (_tokenId, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheGaugeTargetIsAV2Gauge() {
    // The gauge's factory reports the V2 venue.
    _mockGaugeType(_GAUGE, 'v2');
    _;
  }

  function test_StakeGaugeWhenThePayerIsInternalAndTheSpendModeIsAmount(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered givenTheGaugeTargetIsAV2Gauge {
    _assumeFuzzable(_caller);
    // A V2 gauge stakes an ERC20 LP balance held by the execution address: the router funds it, grants an allowance
    // for the amount, then deposits for the logical sender. Any amount is valid, including zero.
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    _mockAndExpectTokenBalancesTwice(_LP_TOKEN, address(_metarouter), [_amount, uint256(0)]);
    // it should approve the gauge for the funded amount
    _mockAndExpect(_LP_TOKEN, abi.encodeCall(IERC20.approve, (_GAUGE, _amount)), abi.encode(true));
    // it should deposit the funded amount for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (_amount, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _amount), false));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_StakeGaugeWhenThePayerIsExternalAndTheTokenChargesAFeeOnTransfer(
    address _caller,
    uint256 _requested,
    uint256 _received
  ) external givenTheGaugeIsRegistered givenTheGaugeTargetIsAV2Gauge {
    _assumeFuzzable(_caller);
    _caller = _boundNotEq(_caller, address(_metarouter));
    _requested = bound(_requested, 2, type(uint256).max);
    _received = bound(_received, 1, _requested - 1);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    uint256[] memory _balances = new uint256[](3);
    _balances[0] = 0;
    _balances[1] = _received;
    _balances[2] = 0;
    _mockAndExpectTokenBalances(_LP_TOKEN, address(_metarouter), _balances);
    // it should pull the requested amount from _owner
    _mockAndExpect(
      _LP_TOKEN, abi.encodeCall(IERC20.transferFrom, (_caller, address(_metarouter), _requested)), abi.encode(true)
    );
    // it should approve the gauge for the measured received amount
    _mockAndExpect(_LP_TOKEN, abi.encodeCall(IERC20.approve, (_GAUGE, _received)), abi.encode(true));
    // it should deposit the measured received amount for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (_received, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] =
      abi.encode(_GAUGE, abi.encode(IMetarouter.BalanceSpend(IMetarouter.SpendMode.Amount, _requested), true));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_StakeGaugeWhenThePayerIsInternalAndTheSpendModeIsPips(address _caller)
    external
    givenTheGaugeIsRegistered
    givenTheGaugeTargetIsAV2Gauge
  {
    _assumeFuzzable(_caller);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    // 333333 pips of 1000 resolves to 333, which differs from the raw pip value and independently pins the amount
    // forwarded to both approval and deposit.
    _mockAndExpectTokenBalancesTwice(_LP_TOKEN, address(_metarouter), [uint256(1000), uint256(0)]);
    // it should approve the gauge for the resolved proportion
    _mockAndExpect(_LP_TOKEN, abi.encodeCall(IERC20.approve, (_GAUGE, 333)), abi.encode(true));
    // it should deposit the resolved proportion for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.depositFor, (333, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.STAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(IMetarouter.BalanceSpend(IMetarouter.SpendMode.Pips, 333_333), false));

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== unstakeGauge ==============================

  function test_UnstakeGaugeGivenALiteDeploymentWithNoLeafVoter(address _caller) external {
    _assumeFuzzable(_caller);
    // A lite deployment carries no voting system, so the gauge commands are gated off. The guard is the first
    // statement of the dispatch branch, so the command reverts before the input is decoded and before any gauge or
    // Voter read; the input can stay empty.
    MetarouterHarness _liteMetarouter = _deployLiteMetarouter();

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = '';

    // it should revert with CommandDisabled
    vm.prank(_caller);
    vm.expectRevert(abi.encodeWithSelector(IMetarouter.CommandDisabled.selector, Commands.UNSTAKE_GAUGE));
    _liteMetarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheGaugeIsNotRegistered(address _caller, uint256 _tokenId) external {
    // The Voter reports the gauge as never produced by an approved factory (isRegistered false).
    _mockAndExpect(_VOTER, abi.encodeCall(ILeafVoter.gaugeStates, (_GAUGE)), _encodedGaugeState(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    // it should revert with GaugeNotRegistered
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.GaugeNotRegistered.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheRouterCarriesClaimApproval(
    address _caller,
    uint256 _tokenId,
    uint256 _emissionAmount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // A CL unstake always returns the position NFT to the router (via `safeTransferFrom`, so it is tracked by
    // `onERC721Received` and must leave the router before batch closure; both are exercised in the Metarouter suite).
    // With claim approval it additionally auto-claims emissions to the router, so the emission token is tracked and
    // swept here. `withdrawFrom` is mocked, so the NFT return is not modelled.
    _emissionAmount = bound(_emissionAmount, 1, type(uint256).max);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(true));
    // it should track the emission token
    _mockAndExpectTokenBalance(_EMISSION_TOKEN, address(_metarouter), _emissionAmount);
    _mockAndExpectTokenTransfer(_EMISSION_TOKEN, _caller, _emissionAmount);
    // it should withdraw for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_tokenId, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheRouterLacksClaimApproval(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // Without claim approval a CL unstake returns only the position NFT to the router; no auto-claimed emissions reach
    // it, so the emission token is not tracked or swept. The returned-position tracking (`onERC721Received`) and closing
    // custody check are exercised in the Metarouter suite, so `withdrawFrom` is mocked and this test only asserts the
    // absence of an emission-token sweep.
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    // it should withdraw for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_tokenId, _caller)), '');
    // it should not sweep the emission token
    vm.mockCallRevert(_EMISSION_TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector), bytes('no emission sweep'));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheGaugeReturnsThePosition(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // `withdrawFrom` is left unmocked so the probe's own code runs in its place: it records the expected sender the
    // router set while it held control, then returns the position through the collection the way a real
    // `safeTransferFrom` would. The hook rejects a position it did not solicit, so the delivery landing at all is what
    // proves the gauge was set as the expected sender.
    _etchReturnProbe(_GAUGE);
    _etchReturnProbe(_POSITION_MANAGER);
    NftReturnProbe(_GAUGE).configure(_metarouter, _POSITION_MANAGER, _tokenId);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    // The returned position leaves the router before closure, so the closing ownership check passes; expecting the
    // call proves the delivered position was tracked.
    _mockAndExpect(
      _POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(makeAddr('newPositionOwner'))
    );

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should set the gauge and position as expected while withdrawing
    assertEq(NftReturnProbe(_GAUGE).expectedSenderDuringWithdrawal(), _GAUGE, 'gauge not set as expected sender');
    assertEq(NftReturnProbe(_GAUGE).expectedTokenIdDuringWithdrawal(), _tokenId, 'position not set as expected');
    // it should clear the expected nft after withdrawing
    (address _clearedSender,) = _metarouter.expectedNft();
    assertEq(_clearedSender, address(0), 'expected nft not cleared');
  }

  function test_UnstakeGaugeWhenTheReturnedPositionIsTransferredInTheSameBatch(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    _tokenId = bound(_tokenId, 1, type(uint256).max);
    address _recipient = makeAddr('recipient');
    _etchReturnProbe(_GAUGE);
    _etchReturnProbe(_POSITION_MANAGER);
    NftReturnProbe(_GAUGE).configure(_metarouter, _POSITION_MANAGER, _tokenId);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    // it should transfer the returned position to _recipient
    _mockAndExpect(
      _POSITION_MANAGER,
      abi.encodeWithSignature('safeTransferFrom(address,address,uint256)', address(_metarouter), _recipient, _tokenId),
      ''
    );
    // The transfer leaves the custody flag set until closure verifies the final owner.
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(_recipient));

    bytes memory _commands =
      abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)), bytes1(uint8(Commands.TRANSFER_NFT)));
    bytes[] memory _inputs = new bytes[](2);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);
    _inputs[1] = abi.encode(_POSITION_MANAGER, _tokenId, _recipient);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);

    // it should clear the expected nft after withdrawing
    (address _clearedSender,) = _metarouter.expectedNft();
    assertEq(_clearedSender, address(0), 'expected nft not cleared');
    // it should clear the nft tracking at closure
    assertEq(_metarouter.trackedNftLength(), 0, 'nft tracking not cleared');
  }

  function test_UnstakeGaugeWhenNoLaterCommandSendsTheReturnedPositionOnward(
    address _caller,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // A terminal CL unstake has no path back to the caller's wallet: the returned position is tracked into custody,
    // no command sends it onward, and the router is still its owner at closure, so the batch fails safe instead of
    // closing around a stranded position. Reclaiming to a wallet means unstaking through the gauge directly; the
    // router only supports routes that consume the position (restake or burn) in the same batch.
    _etchReturnProbe(_GAUGE);
    _etchReturnProbe(_POSITION_MANAGER);
    NftReturnProbe(_GAUGE).configure(_metarouter, _POSITION_MANAGER, _tokenId);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    // The delivered position never leaves, so the closing ownership check finds the router still owning it.
    _mockAndExpect(_POSITION_MANAGER, abi.encodeCall(IERC721.ownerOf, (_tokenId)), abi.encode(address(_metarouter)));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    // it should revert with NftNotCleared
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftNotCleared.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenAnExpectedSenderIsAlreadySet(
    address _caller,
    address _pendingSender,
    uint256 _tokenId
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAClGauge {
    _assumeFuzzable(_caller);
    // A pending authorization means an earlier operation never cleared its expected sender, so setting another one
    // would widen the window it left open.
    _pendingSender = _boundNotEq(_pendingSender, address(0));
    _metarouter.seedExpectedNft(_pendingSender, _tokenId);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_tokenId), false);

    // it should revert with NftSenderNotCleared
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.NftSenderNotCleared.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  modifier givenTheGaugeIsAV2Gauge() {
    // The gauge's factory reports the V2 venue for both claim-approval branches.
    _mockGaugeType(_GAUGE, 'v2');
    _;
  }

  function test_UnstakeGaugeWhenThePenaltyIsActiveAndThePenaltyIsNotAllowed(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAV2Gauge {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint256).max);
    vm.roll(100);
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(99)));
    // Keep the unguarded path executable so the regression fails specifically on the absent penalty check.
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    vm.mockCall(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    vm.mockCall(_LP_TOKEN, abi.encodeCall(IERC20.balanceOf, (address(_metarouter))), abi.encode(uint256(0)));
    vm.mockCall(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_amount, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_amount), false);

    // it should revert with PenaltyNotAccepted
    vm.prank(_caller);
    vm.expectRevert(IMetarouter.PenaltyNotAccepted.selector);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenThePenaltyIsActiveAndThePenaltyIsAllowed(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAV2Gauge {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint256).max);
    // Explicit consent skips the penalty reads entirely, so the live window is never even inspected.
    vm.mockCallRevert(
      _GAUGE_FACTORY, abi.encodeCall(IGaugeFactory.effectivePenaltyConfig, (_GAUGE)), bytes('no penalty config read')
    );
    vm.mockCallRevert(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), bytes('no deposit block read'));
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    _mockAndExpectTokenBalance(_LP_TOKEN, address(_metarouter), 0);
    // it should withdraw despite the active penalty
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_amount, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_amount), true);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenThePenaltyWindowHasElapsed(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAV2Gauge {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 1, type(uint256).max);
    vm.roll(100);
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(95)));
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    _mockAndExpectTokenBalance(_LP_TOKEN, address(_metarouter), 0);
    // it should withdraw after the penalty window
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_amount, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_amount), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheRouterHoldsClaimApproval(
    address _caller,
    uint256 _amount,
    uint256 _emissionAmount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAV2Gauge {
    _assumeFuzzable(_caller);
    // With claim approval the auto-claimed emissions also land in the router.
    _amount = bound(_amount, 1, type(uint256).max);
    // The gate runs on the default flag with an elapsed window, so the withdrawal proceeds with tracking.
    vm.roll(100);
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(95)));
    _emissionAmount = bound(_emissionAmount, 1, type(uint256).max);
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(true));
    // it should track the lp token
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    _mockAndExpectTokenBalance(_LP_TOKEN, address(_metarouter), _amount);
    _mockAndExpectTokenTransfer(_LP_TOKEN, _caller, _amount);
    // it should track the emission token
    _mockAndExpectTokenBalance(_EMISSION_TOKEN, address(_metarouter), _emissionAmount);
    _mockAndExpectTokenTransfer(_EMISSION_TOKEN, _caller, _emissionAmount);
    // it should withdraw for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_amount, _caller)), '');

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_amount), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  function test_UnstakeGaugeWhenTheRouterDoesNotHoldClaimApproval(
    address _caller,
    uint256 _amount
  ) external givenTheGaugeIsRegistered givenTheGaugeIsAV2Gauge {
    _assumeFuzzable(_caller);
    // Without claim approval the withdrawn LP returns to the router but the auto-claimed emissions do not.
    _amount = bound(_amount, 1, type(uint256).max);
    // The gate runs on the default flag with an elapsed window, so the withdrawal proceeds with tracking.
    vm.roll(100);
    _mockPenaltyConfig(_GAUGE, 5, 1_000_000);
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.depositBlock, (_caller)), abi.encode(uint256(95)));
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.approvedForClaim, (_caller, address(_metarouter))), abi.encode(false));
    // it should track the lp token
    _mockAndExpect(_GAUGE, abi.encodeCall(IV2Gauge.stakingToken, ()), abi.encode(_LP_TOKEN));
    _mockAndExpectTokenBalance(_LP_TOKEN, address(_metarouter), _amount);
    _mockAndExpectTokenTransfer(_LP_TOKEN, _caller, _amount);
    // it should withdraw for _owner
    _mockAndExpect(_GAUGE, abi.encodeCall(IGauge.withdrawFrom, (_amount, _caller)), '');
    // it should not sweep the emission token
    vm.mockCallRevert(_EMISSION_TOKEN, abi.encodeWithSelector(IERC20.balanceOf.selector), bytes('no emission sweep'));

    bytes memory _commands = abi.encodePacked(bytes1(uint8(Commands.UNSTAKE_GAUGE)));
    bytes[] memory _inputs = new bytes[](1);
    _inputs[0] = abi.encode(_GAUGE, abi.encode(_amount), false);

    vm.prank(_caller);
    _metarouter.execute(_commands, _inputs, block.timestamp);
  }

  // ============================== helpers ==============================

  /// @notice Replaces an address's code with the NFT-return probe, so a withdrawal call runs real code instead of a
  ///         mock and can observe the expected sender and return a position.
  /// @dev Mocked calls registered on the address keep taking precedence, so only the unmocked withdrawal entry points
  ///      reach the probe.
  /// @param _target Address whose code is replaced.
  function _etchReturnProbe(address _target) internal {
    vm.etch(_target, address(new NftReturnProbe()).code);
  }

  /// @notice Builds the ABI-encoded `gaugeStates` getter tuple with only the `isRegistered` field toggled.
  /// @param _registered Whether the gauge is reported as produced by an approved factory.
  /// @return _state Encoded `gaugeStates` getter tuple.
  function _encodedGaugeState(bool _registered) internal pure returns (bytes memory _state) {
    // isRegistered is the fourth field of the `gaugeStates` getter tuple; other fields are irrelevant here.
    _state = abi.encode(
      uint128(0),
      uint128(0),
      uint48(0),
      _registered,
      false,
      uint128(0),
      uint256(0),
      uint256(0),
      IVoterCommon.Point({bias: 0, slope: 0, ts: 0, permanentStakeBalance: 0})
    );
  }
}
