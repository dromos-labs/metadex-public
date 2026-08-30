// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {Ownable} from '@solady/auth/Ownable.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';
import {AdminRewardRedirect} from 'V3-test/unit/relay/harnesses/AdminRewardRedirect.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/// @notice Coverage of the reward machinery around the accumulator: the entrypoint feed (pull),
///         the appreciation lane (compound), the notify/claim guards, the registry growth rules,
///         donations and the cross-chain reward-claim lane.
contract UnitRelayRewardLanes is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @notice `pull` feeds either entrypoint, bounded to the un-accounted balance so rewards
  ///         already owed to claimants can never leave.
  function test_WhenPullingToAnEntrypoint() external {
    // it should revert for a caller holding neither entrypoint role
    vm.expectRevert(IRelay.NotAuthorized.selector);
    _relay.pull(_rewardToken, 1e18);

    // it should revert when the amount passes the un-accounted balance
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(100e18));
    vm.prank(_converter);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.pull(_rewardToken, 150e18);

    // it should transfer to the calling entrypoint, converter or compounder alike
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_converter, 60e18)), abi.encode(true));
    vm.expectCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_converter, 60e18)));
    vm.prank(_converter);
    _relay.pull(_rewardToken, 60e18);

    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_compounder, 10e18)), abi.encode(true));
    vm.expectCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_compounder, 10e18)));
    vm.prank(_compounder);
    _relay.pull(_rewardToken, 10e18);

    // it should allow the exact un-accounted balance, the inclusive bound of the guard
    // nothing is accounted yet, so the whole mocked 100e18 balance is free to leave
    _mockAndExpectTokenTransfer(_rewardToken, _converter, 100e18);
    vm.prank(_converter);
    _relay.pull(_rewardToken, 100e18);

    // it should subtract the accounted balance from the bound, never add it
    // 60e18 of the mocked 100e18 balance is now owed to claimants, so only 40e18 stays pullable
    _registerRewardToken();
    vm.prank(_converter);
    _relay.notifyReward(_rewardToken, 60e18);
    assertEq(_relay.accountedBalance(_rewardToken), 60e18);
    vm.prank(_converter);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.pull(_rewardToken, 50e18);
  }

  /// @notice `compound` stakes TOKEN into the Relay sAERO: the backing grows, no share mints, so
  ///         every existing share appreciates.
  function test_WhenCompoundingIntoTheStake() external {
    // it should revert for a caller without the COMPOUNDER role
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(users.alice);
    _relay.compound(1e18);

    // it should revert when the amount passes the un-accounted TOKEN balance
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(40e18));
    vm.prank(_compounder);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.compound(50e18);

    // it should stake into the sAERO and grow only the backing
    uint256 _supplyBefore = _principalToken.totalSupply();
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, 30e18)), abi.encode()
    );
    vm.expectCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, 30e18)));
    vm.expectEmit(address(_relay));
    emit IRelay.Compounded(30e18);
    vm.prank(_compounder);
    _relay.compound(30e18);

    assertEq(_relay.totalBacking(), _SEED + 30e18);
    assertEq(_principalToken.totalSupply(), _supplyBefore);
    _assertPairInvariant();

    // it should grow only the backing while a request sits in the queue
    // the queued 100e18 parks outside the backing, so the compound lands with the queue open
    _requestDeposit(users.alice, 2, 100e18);
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(100e18));
    vm.mockCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, 70e18)), abi.encode()
    );
    vm.prank(_compounder);
    _relay.compound(70e18);
    assertEq(_relay.totalBacking(), 200e18);

    // it should subtract the accounted TOKEN from the bound, never add it
    // the Hybrid case: TOKEN is also a reward target, so 60e18 of it is owed to claimants
    vm.prank(_keeper);
    _relay.addRewardToken(_token);
    vm.prank(_converter);
    _relay.notifyReward(_token, 60e18);
    assertEq(_relay.accountedBalance(_token), 60e18);
    vm.prank(_compounder);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.compound(50e18);
  }

  /// @notice Only the principal redeems backing, so compounding with none outstanding would add
  ///         weight nobody can claim: taken by whoever deposits next while the Relay is open, and
  ///         unrecoverable once it is closed. Both states are refused.
  /// @dev The amount is fuzzed and the escrow and TOKEN reads are armed, so the supply guard is the
  ///      only thing that can stop the call. The drained supply is mocked on the principal clone
  ///      rather than reached by exiting every holder; the full exit lifecycle lives in the
  ///      wind-down suite.
  function test_WhenCompoundingWithNoPrincipalOutstanding(uint256 _amount) external {
    _amount = bound(_amount, 1, type(uint128).max - _SEED);
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(_amount));
    // forge-lint: disable-next-line(unsafe-typecast)
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, uint128(_amount))),
      abi.encode()
    );
    // The state a Relay reaches once every holder has exited.
    vm.mockCall(address(_principalToken), abi.encodeCall(IERC20.totalSupply, ()), abi.encode(uint256(0)));

    // it should revert with NoPrincipalSupply while the relay is open
    vm.prank(_compounder);
    vm.expectRevert(IRelay.NoPrincipalSupply.selector);
    _relay.compound(_amount);

    vm.prank(_keeper);
    _relay.close();

    // it should revert with NoPrincipalSupply once the relay is closed
    vm.prank(_compounder);
    vm.expectRevert(IRelay.NoPrincipalSupply.selector);
    _relay.compound(_amount);

    // it should never reach the escrow with the stake growth
    // forge-lint: disable-next-line(unsafe-typecast)
    vm.expectCall(
      _votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, uint128(_amount))), 0
    );
    // it should leave the backing counter untouched
    assertEq(_relay.totalBacking(), _SEED, 'the rejected compound moved the backing');
  }

  /// @notice The notify guards: only registered tokens, only amounts that really arrived, and no
  ///         batch so small its per-share index delta floors to zero.
  function test_WhenNotifyingAnInvalidBatch() external {
    // it should revert for an unregistered token
    vm.prank(_converter);
    vm.expectRevert(IRelay.UnknownRewardToken.selector);
    _relay.notifyReward(_rewardToken, 1e18);

    _registerRewardToken();

    // it should revert when the batch passes the un-accounted balance that arrived
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(0.5e18));
    vm.prank(_converter);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.notifyReward(_rewardToken, 1e18);

    // it should revert when the index delta floors to zero
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(uint256(50)));
    vm.prank(_converter);
    vm.expectRevert(IRelay.RewardTooSmall.selector);
    _relay.notifyReward(_rewardToken, 50);

    // it should revert when no share supply exists to spread over
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(10e18));
    vm.mockCall(address(_yieldToken), abi.encodeWithSelector(_yieldToken.totalSupply.selector), abi.encode(0));
    vm.prank(_converter);
    vm.expectRevert(IRelay.NoSupply.selector);
    _relay.notifyReward(_rewardToken, 10e18);
  }

  /// @notice Notify accounts only what the floored index can pay out: the remainder stays
  ///         un-accounted, so the next notify recycles it instead of trapping it forever.
  function test_WhenTheNotifiedBatchDoesNotDivideEvenly() external {
    _registerRewardToken();

    // 100e18 + 55 wei arrive; over the 100e18 seed supply the index floors the 55 wei out
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(100e18 + 55));
    vm.expectEmit(address(_relay));
    emit IRelay.RewardNotified(_rewardToken, 100e18, 1e18);
    vm.prank(_converter);
    _relay.notifyReward(_rewardToken, 100e18 + 55);

    // it should account only the distributed amount
    assertEq(_relay.accountedBalance(_rewardToken), 100e18);

    // it should subtract the accounted balance from the notifiable bound, never add it
    // only the 55 wei remainder is un-accounted, so a 50e18 batch cannot have arrived
    vm.prank(_converter);
    vm.expectRevert(IRelay.RewardExceedsBalance.selector);
    _relay.notifyReward(_rewardToken, 50e18);

    // it should keep the remainder notifiable: before the fix this second batch reverted
    // RewardExceedsBalance, because the 55 wei sat trapped inside accountedBalance
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(200e18 + 55));
    vm.prank(_converter);
    _relay.notifyReward(_rewardToken, 100e18 + 55);
    assertEq(_relay.accountedBalance(_rewardToken), 200e18);
  }

  /// @notice A holder settling once across several batches claims the merged floor: the rounded-up
  ///         accounting of each notify covers every claim, leaving only dust behind.
  function test_WhenAMergedSettlementSpansRaggedBatches() external {
    // ragged supply: alice's 100e18 + 1 on top of the bootstrap 100e18 puts the YT supply at 200e18 + 1
    _admitDeposit(users.alice, 2, 100e18 + 1);
    _registerRewardToken();

    // each 380e18 batch advances the index by 1_899_999_999_999_999_999 and accounts the index's
    // payout capacity rounded up, 379_999_999_999_999_999_802
    _notifyReward(380e18);
    _notifyReward(380e18);
    assertEq(_relay.accountedBalance(_rewardToken), 759_999_999_999_999_999_604);

    // the two merged floors sum 1 wei below the accounted balance
    assertEq(_relay.claimable(_bootstrapOwner, _rewardToken), 379_999_999_999_999_999_800);
    assertEq(_relay.claimable(users.alice, _rewardToken), 379_999_999_999_999_999_803);

    vm.mockCall(_rewardToken, abi.encodeWithSelector(IERC20.transfer.selector), abi.encode(true));

    // it should cover every claim with the accounted balance
    vm.prank(_bootstrapOwner);
    assertEq(_relay.claim(_rewardToken, _bootstrapOwner), 379_999_999_999_999_999_800);
    vm.prank(users.alice);
    assertEq(_relay.claim(_rewardToken, users.alice), 379_999_999_999_999_999_803);
    assertEq(_relay.accountedBalance(_rewardToken), 1);
  }

  /// @notice A holder settled twice keeps both settlements: the second batch is added on top of
  ///         the balance the first one locked, never merged into it.
  function test_WhenAccrualSettlesAcrossTwoBatches() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, so alice's 100e18 balance earns 100e18.
    // The YT move settles her at the pre-transfer balance and leaves her holding 90e18.
    _notifyReward(200e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);

    // a second 200e18 over the same supply: index delta 1e18 again, now on her 90e18 balance
    _notifyReward(200e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));

    // it should hold the sum of both settlements, 100e18 plus 90e18
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 190e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 190e18);
    _assertPairInvariant();
  }

  /// @notice The claim guards: unknown tokens are rejected and an empty settled balance reverts
  ///         instead of transferring zero.
  function test_WhenClaimingWithNothingSettled() external {
    // it should revert for an unregistered token
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.UnknownRewardToken.selector);
    _relay.claim(_rewardToken, _bootstrapOwner);

    // it should revert when the caller has nothing settled to claim
    _registerRewardToken();
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.NothingToClaim.selector);
    _relay.claim(_rewardToken, _bootstrapOwner);
  }

  /// @notice The registry growth rules per tier: Maxi locks after the first token; an L2 Protocol
  ///         grows up to the hard cap, without duplicates.
  function test_WhenGrowingTheRewardRegistry() external {
    // it should reject the zero address
    vm.prank(_keeper);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.addRewardToken(address(0));

    // it should lock the Maxi registry after the first token
    _registerRewardToken();
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RewardRegistryLocked.selector);
    _relay.addRewardToken(_mockContract('secondToken'));

    // it should grow an L2 registry up to MAX_REWARD_TOKENS and no further
    _deployProtocolUninitialized();
    IRelay.InitParams memory _params = _defaultInitParams(false);
    _params.startAsLevel2 = true;
    // the L2-direct start seeds the allow list with the bootstrap owner
    vm.expectEmit(address(_relay));
    emit IRelay.AllowListSet(_bootstrapOwner, true);
    _initializeRelay(_params);
    for (uint256 _i; _i < 10; ++_i) {
      vm.prank(_keeper);
      _relay.addRewardToken(_mockContract(string(abi.encodePacked('reward', _i))));
    }
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RewardRegistryFull.selector);
    _relay.addRewardToken(_mockContract('eleventh'));

    // it should reject a duplicate on a growable registry
    _deployProtocolUninitialized();
    _params = _defaultInitParams(false);
    _params.startAsLevel2 = true;
    _initializeRelay(_params);
    vm.startPrank(_keeper);
    // it should emit the registry growth
    vm.expectEmit(address(_relay));
    emit IRelay.RewardTokenAdded(_rewardToken);
    _relay.addRewardToken(_rewardToken);
    vm.expectRevert(IRelay.RewardTokenAlreadyAdded.selector);
    _relay.addRewardToken(_rewardToken);
    vm.stopPrank();
  }

  /// @notice Three entries the registry could never pay a claim out from: an address holding no
  ///         code, the Relay itself, and its own satellites. The last two are what makes a
  ///         registered share token circular, since notifying it would distribute the very balances
  ///         the accumulator prices its claims against. On the single-slot tiers any of the three
  ///         also closes the registry for good.
  function test_WhenRegisteringARewardTokenNothingCanPayOut() external {
    vm.startPrank(_keeper);

    // it should reject an address holding no code
    vm.expectRevert(IRelay.RewardTokenNotAContract.selector);
    _relay.addRewardToken(makeAddr('codelessToken'));

    // it should reject the relay itself
    vm.expectRevert(IRelay.InvalidRewardToken.selector);
    _relay.addRewardToken(address(_relay));

    // it should reject the principal and the yield token
    vm.expectRevert(IRelay.InvalidRewardToken.selector);
    _relay.addRewardToken(address(_principalToken));
    vm.expectRevert(IRelay.InvalidRewardToken.selector);
    _relay.addRewardToken(address(_yieldToken));

    vm.stopPrank();
  }

  /// @notice The undo of a misregistration: a token that never distributed leaves and reopens its
  ///         slot, which on a single-slot tier is the only way back at all. One that already paid
  ///         stays, because the accumulator settles and claims registered tokens only, so dropping
  ///         it would freeze the rights it left behind.
  function test_WhenDroppingARewardToken() external {
    // it should refuse to drop one the registry does not hold
    vm.prank(_keeper);
    vm.expectRevert(IRelay.UnknownRewardToken.selector);
    _relay.removeRewardToken(_rewardToken);

    // it should hold the drop to the keeper
    _registerRewardToken();
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.removeRewardToken(_rewardToken);

    // it should drop the token and reopen the slot a locked tier closed
    vm.expectEmit(address(_relay));
    emit IRelay.RewardTokenRemoved(_rewardToken);
    vm.prank(_keeper);
    _relay.removeRewardToken(_rewardToken);
    assertFalse(_relay.isRewardToken(_rewardToken), 'the dropped token is still registered');
    assertEq(_relay.rewardTokens().length, 0, 'the registry did not shrink');
    address _secondToken = _mockContract('replacementReward');
    vm.prank(_keeper);
    _relay.addRewardToken(_secondToken);
    assertTrue(_relay.isRewardToken(_secondToken), 'the reopened slot refused the replacement');

    // it should refuse to drop one that already distributed
    vm.mockCall(_secondToken, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(50e18));
    vm.prank(_converter);
    _relay.notifyReward(_secondToken, 50e18);
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RewardTokenPaid.selector);
    _relay.removeRewardToken(_secondToken);
  }

  /// @notice Donations are recognized by the keeper as pure backing growth; recognizing nothing
  ///         reverts so the ordering signal cannot be faked.
  function test_WhenProcessingDonations() external {
    // it should revert when the staked amount holds no surplus
    vm.prank(_keeper);
    vm.expectRevert(IRelay.NoDonations.selector);
    _relay.processDonations();

    // it should fold the donated surplus into the backing and emit the amount
    _mockRelayStaked(_SEED + 5e18);
    vm.expectEmit(address(_relay));
    emit IRelay.DonationsProcessed(5e18);
    vm.prank(_keeper);
    _relay.processDonations();
    assertEq(_relay.totalBacking(), _SEED + 5e18);
    _assertPairInvariant();

    // it should leave the queued weight out of the surplus it recognizes
    _requestDeposit(users.alice, 2, 100e18);
    _mockRelayStaked(255e18); // 105e18 backing + 100e18 queued + 50e18 donated
    vm.prank(_keeper);
    _relay.processDonations();
    assertEq(_relay.totalBacking(), 155e18);
  }

  /// @notice The reward-claim lane: per-chain recipients are ADMIN config behind a delay, a root
  ///         claim carries no value and lands at the Relay itself, a leaf claim dispatches to the
  ///         configured recipient and is funded by the caller.
  function test_WhenClaimingRewardsAcrossChains() external {
    address _votingRewardsManager = makeAddr('votingRewardsManager');
    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: _votingRewardsManager, maxCheckpoints: 5});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] =
      ILeafVoter.IncentiveClaim({votingRewardsManager: _votingRewardsManager, programId: 7, maxCheckpoints: 5});

    // it should gate the recipient config to the owner
    vm.expectRevert(Ownable.Unauthorized.selector);
    vm.prank(users.alice);
    _relay.proposeLeafRecipient(10, users.alice);

    // it should reject a leaf claim while no recipient is configured
    vm.expectRevert(IRelay.RecipientNotSet.selector);
    _relay.claimRewards(10, 100_000, _feeClaims, _incentiveClaims);

    // it should treat a chain id above the local one as a leaf too, not as the root chain
    uint256 _highChainId = block.chainid + 1;
    vm.expectRevert(IRelay.RecipientNotSet.selector);
    _relay.claimRewards(_highChainId, 100_000, _feeClaims, _incentiveClaims);

    // it should reject a proposal for the zero recipient, which is the clear path instead
    vm.prank(_admin);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.proposeLeafRecipient(10, address(0));

    // it should reject an execution with nothing proposed for the chain
    vm.prank(_admin);
    vm.expectRevert(IRelay.LeafRecipientNotProposed.selector);
    _relay.executeLeafRecipient(10);

    // it should store the recipient and emit once the proposal has waited out the delay
    address _leafSafe = makeAddr('leafSafe');
    vm.prank(_admin);
    _relay.proposeLeafRecipient(10, _leafSafe);
    skip(_relay.relayConfig().entrypointTimelock);
    vm.expectEmit(address(_relay));
    emit IRelay.LeafRecipientSet(10, _leafSafe);
    vm.prank(_admin);
    _relay.executeLeafRecipient(10);

    // it should stay silent when clearing a chain that has no recipient: the early-return no-op branch
    vm.recordLogs();
    vm.prank(_admin);
    _relay.clearLeafRecipient(_highChainId);
    assertEq(vm.getRecordedLogs().length, 0);

    // it should reject value on a root claim
    hoax(users.alice, 1 ether);
    vm.expectRevert(IRelay.NoValueOnRootClaim.selector);
    _relay.claimRewards{value: 1}(block.chainid, 0, _feeClaims, _incentiveClaims);

    // it should dispatch a root claim to the relay itself, no value attached
    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](1);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: block.chainid,
      gasLimit: 0,
      value: 0,
      recipient: address(_relay),
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.claimRewards.selector), abi.encode());
    // the value overload pins the wei handed to the Voter, not only the calldata
    vm.expectCall(_voter, 0, abi.encodeCall(IVoter.claimRewards, (_RELAY_TOKEN_ID, _claimRewardsParams, users.alice)));
    vm.prank(users.alice);
    _relay.claimRewards(block.chainid, 0, _feeClaims, _incentiveClaims);

    // it should dispatch a leaf claim to the configured recipient, funded by the caller
    // it should forward both claim arrays untouched inside the per-chain params
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: 10,
      gasLimit: 100_000,
      value: 2,
      recipient: _leafSafe,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });
    // it should forward the caller's full value to the Voter, so no wei stays behind
    vm.expectCall(_voter, 2, abi.encodeCall(IVoter.claimRewards, (_RELAY_TOKEN_ID, _claimRewardsParams, users.alice)));
    hoax(users.alice, 1 ether);
    _relay.claimRewards{value: 2}(10, 100_000, _feeClaims, _incentiveClaims);

    // it should fund a leaf claim on a chain id above the local one, not reject its value
    _landLeafRecipient(_highChainId, _leafSafe);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: _highChainId,
      gasLimit: 100_000,
      value: 2,
      recipient: _leafSafe,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });
    vm.expectCall(_voter, 2, abi.encodeCall(IVoter.claimRewards, (_RELAY_TOKEN_ID, _claimRewardsParams, users.alice)));
    hoax(users.alice, 1 ether);
    _relay.claimRewards{value: 2}(_highChainId, 100_000, _feeClaims, _incentiveClaims);

    // it should disable the chain at once when the recipient is cleared, with no delay to wait
    vm.expectEmit(address(_relay));
    emit IRelay.LeafRecipientSet(10, address(0));
    vm.prank(_admin);
    _relay.clearLeafRecipient(10);
    vm.expectRevert(IRelay.RecipientNotSet.selector);
    _relay.claimRewards(10, 100_000, _feeClaims, _incentiveClaims);
  }

  /// @notice A re-point of a leaf claim recipient hands reward custody to a new address, so it waits
  ///         out the same delay an entrypoint attachment does. The claim wrapper is permissionless and
  ///         keeps resolving to the current recipient while a proposal waits, so anyone at all can
  ///         move the outstanding accrual to the honest custody before the re-point lands.
  /// @dev Without the delay this whole sequence was one transaction: the harness holds ADMIN and
  ///      batches the re-point and the claim, which is what a multisig ADMIN can do on chain.
  function test_WhenTheAdminRedirectsAnEarnedLeafClaim(uint256 _chainId, address _caller, uint256 _value) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_chainId != block.chainid);
    _value = bound(_value, 1, 10 ether);
    _assumeFreshHolder(_caller);
    address _leafSafe = makeAddr('leafSafe');
    ILeafVoter.FeeClaim[] memory _feeClaims = new ILeafVoter.FeeClaim[](1);
    _feeClaims[0] = ILeafVoter.FeeClaim({votingRewardsManager: makeAddr('votingRewardsManager'), maxCheckpoints: 5});
    ILeafVoter.IncentiveClaim[] memory _incentiveClaims = new ILeafVoter.IncentiveClaim[](1);
    _incentiveClaims[0] = ILeafVoter.IncentiveClaim({
      votingRewardsManager: makeAddr('votingRewardsManager'), programId: 7, maxCheckpoints: 5
    });

    // The Relay votes on that leaf's gauges and the honest transport custody is already configured.
    _landLeafRecipient(_chainId, _leafSafe);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.claimRewards.selector), abi.encode());

    // The ownership lands on a contract, which is what it looks like in production: a multisig.
    AdminRewardRedirect _rogueAdmin = new AdminRewardRedirect();
    vm.prank(_admin);
    _relay.transferOwnership(address(_rogueAdmin));
    vm.assume(_caller != address(_rogueAdmin));

    // it should refuse to land a re-point inside the delay, so the atomic redirect reverts
    deal(address(this), _value);
    vm.expectRevert(IRelay.LeafRecipientTimelockNotElapsed.selector);
    _rogueAdmin.redirectAndClaim{value: _value}(_relay, _chainId, 100_000, _feeClaims, _incentiveClaims);

    // The rogue admin settles for what it can do alone: stamp the proposal and wait for it.
    vm.prank(address(_rogueAdmin));
    _relay.proposeLeafRecipient(_chainId, address(_rogueAdmin));

    // it should leave the honest custody in place while the proposal waits
    assertEq(_relay.leafRecipient(_chainId), _leafSafe, 'the proposal moved custody before its delay');

    IVoter.ClaimRewardsParams[] memory _claimRewardsParams = new IVoter.ClaimRewardsParams[](1);
    _claimRewardsParams[0] = IVoter.ClaimRewardsParams({
      chainId: _chainId,
      gasLimit: 100_000,
      value: _value,
      recipient: _leafSafe,
      feeClaims: _feeClaims,
      incentiveClaims: _incentiveClaims
    });

    // it should let anyone rescue the accrued rewards to the honest custody inside the window
    vm.expectCall(_voter, _value, abi.encodeCall(IVoter.claimRewards, (_RELAY_TOKEN_ID, _claimRewardsParams, _caller)));
    hoax(_caller, _value);
    _relay.claimRewards{value: _value}(_chainId, 100_000, _feeClaims, _incentiveClaims);
  }

  /// @notice The delay is a window, not a wall: a proposal that waits it out lands, and lands exactly
  ///         at the boundary. What the window buys is an observable event plus the time for any party
  ///         to drain the accrual and for holders to exit.
  function test_WhenAProposedLeafRecipientWaitsOutTheDelay(uint256 _chainId, address _recipient) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_recipient != address(0));
    uint256 _timelock = _relay.relayConfig().entrypointTimelock;

    // it should stamp the proposal and announce when it becomes executable
    vm.expectEmit(address(_relay));
    emit IRelay.LeafRecipientProposed(_chainId, _recipient, block.timestamp + _timelock);
    vm.prank(_admin);
    _relay.proposeLeafRecipient(_chainId, _recipient);
    (address _pending, uint48 _proposedAt) = _relay.pendingLeafRecipient(_chainId);
    assertEq(_pending, _recipient, 'the proposal was not recorded');
    assertEq(_proposedAt, block.timestamp, 'the delay does not run from the proposal');

    // it should refuse to land one second before the delay elapses
    skip(_timelock - 1);
    vm.prank(_admin);
    vm.expectRevert(IRelay.LeafRecipientTimelockNotElapsed.selector);
    _relay.executeLeafRecipient(_chainId);

    // it should land exactly at the boundary, the inclusive end of the delay
    skip(1);
    vm.prank(_admin);
    _relay.executeLeafRecipient(_chainId);
    assertEq(_relay.leafRecipient(_chainId), _recipient, 'the elapsed proposal did not land');

    // it should consume the proposal, so the same one cannot land twice
    (_pending,) = _relay.pendingLeafRecipient(_chainId);
    assertEq(_pending, address(0), 'the executed proposal was not consumed');
    vm.prank(_admin);
    vm.expectRevert(IRelay.LeafRecipientNotProposed.selector);
    _relay.executeLeafRecipient(_chainId);
  }

  /// @notice The operator seat is reward custody by another route: an operator can call
  ///         `claimRewards` on the leaf naming any recipient it likes, and on its own schedule, so
  ///         it waits out the same delay `leafRecipient` does. Without that, the delay on
  ///         `leafRecipient` would be worth nothing.
  function test_WhenAProposedLeafOperatorWaitsOutTheDelay(
    uint256 _chainId,
    address _operator,
    uint256 _fee,
    uint256 _gasLimit
  ) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_operator != address(0));
    _fee = bound(_fee, 0, 10 ether);
    _gasLimit = bound(_gasLimit, 1, type(uint32).max);
    uint256 _timelock = _relay.relayConfig().entrypointTimelock;

    // it should gate every operator path to the owner
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.proposeOperator(_chainId, _operator);
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.executeOperator(_chainId, _gasLimit, users.alice);
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.revokeOperator(_chainId, _gasLimit, users.alice);

    // it should reject a proposal for the zero operator, which is the revoke path instead
    vm.prank(_admin);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.proposeOperator(_chainId, address(0));

    // it should reject an execution with nothing proposed for the chain
    vm.prank(_admin);
    vm.expectRevert(IRelay.OperatorNotProposed.selector);
    _relay.executeOperator(_chainId, _gasLimit, _admin);

    // it should stamp the proposal and announce when it becomes executable
    _expectEmit(address(_relay));
    emit IRelay.OperatorProposed(_chainId, _operator, block.timestamp + _timelock);
    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _operator);
    (address _pending, uint48 _proposedAt) = _relay.pendingOperator(_chainId);
    assertEq(_pending, _operator, 'the proposal was not recorded');
    assertEq(_proposedAt, block.timestamp, 'the delay does not run from the proposal');

    // it should refuse to land one second before the delay elapses
    skip(_timelock - 1);
    vm.prank(_admin);
    vm.expectRevert(IRelay.OperatorTimelockNotElapsed.selector);
    _relay.executeOperator(_chainId, _gasLimit, _admin);

    // it should dispatch the operator to the voter at the boundary, funded by the caller
    skip(1);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), abi.encode());
    // the value overload pins the wei handed to the Voter, not only the calldata
    vm.expectCall(
      _voter, _fee, abi.encodeCall(IVoter.setOperator, (_RELAY_TOKEN_ID, _chainId, _operator, _gasLimit, _admin))
    );
    _expectEmit(address(_relay));
    emit IRelay.OperatorDispatched(_chainId, _operator);
    hoax(_admin, _fee);
    _relay.executeOperator{value: _fee}(_chainId, _gasLimit, _admin);

    // it should consume the proposal, so the same one cannot land twice
    (_pending,) = _relay.pendingOperator(_chainId);
    assertEq(_pending, address(0), 'the executed proposal was not consumed');
    vm.prank(_admin);
    vm.expectRevert(IRelay.OperatorNotProposed.selector);
    _relay.executeOperator(_chainId, _gasLimit, _admin);
  }

  /// @notice Taking the seat away only removes a capability, so it lands with no delay. It is also
  ///         the cancel path for a proposal made in error.
  function test_WhenTheOperatorSeatIsRevoked(uint256 _chainId, address _operator, uint256 _gasLimit) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_operator != address(0));
    _gasLimit = bound(_gasLimit, 1, type(uint32).max);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), abi.encode());

    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _operator);

    // it should clear the seat on the leaf with no delay
    vm.expectCall(
      _voter, 0, abi.encodeCall(IVoter.setOperator, (_RELAY_TOKEN_ID, _chainId, address(0), _gasLimit, _admin))
    );
    _expectEmit(address(_relay));
    emit IRelay.OperatorDispatched(_chainId, address(0));
    vm.prank(_admin);
    _relay.revokeOperator(_chainId, _gasLimit, _admin);

    // it should cancel a proposal pending for the chain
    (address _pending,) = _relay.pendingOperator(_chainId);
    assertEq(_pending, address(0), 'the pending proposal survived the revoke');
  }

  /// @notice Cancelling a proposal is root-side work and must not depend on the Voter agreeing to
  ///         message the chain. The Voter refuses `CHAIN0`, unregistered chains and `Paused` ones,
  ///         and a proposal aimed at any of those could otherwise never be removed: executing it
  ///         reverts, and so does the revoke that would drop it.
  function test_WhenTheVoterRefusesToMessageTheChain(uint256 _chainId, address _operator, uint256 _gasLimit) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_operator != address(0));
    _gasLimit = bound(_gasLimit, 1, type(uint32).max);

    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _operator);
    vm.mockCallRevert(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), 'ChainPaused');

    // it should gate the cancel to the owner
    vm.prank(users.alice);
    vm.expectRevert(Ownable.Unauthorized.selector);
    _relay.cancelOperator(_chainId);

    // it should revert a revoke, which cannot reach the seat
    vm.prank(_admin);
    vm.expectRevert('ChainPaused');
    _relay.revokeOperator(_chainId, _gasLimit, _admin);
    (address _pending,) = _relay.pendingOperator(_chainId);
    assertEq(_pending, _operator, 'the reverted revoke should leave the proposal untouched');

    // it should drop the proposal anyway
    _expectEmit(address(_relay));
    emit IRelay.OperatorProposalCancelled(_chainId);
    vm.prank(_admin);
    _relay.cancelOperator(_chainId);
    (_pending,) = _relay.pendingOperator(_chainId);
    assertEq(_pending, address(0), 'the proposal survived the cancel');
  }

  /// @notice The proposal clears before the dispatch, so a Voter that reverts takes the whole call
  ///         with it: nothing is consumed, and the same proposal lands on a retry with no second
  ///         delay to wait.
  function test_WhenTheVoterRevertsAnExecution(uint256 _chainId, address _operator, uint256 _gasLimit) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_operator != address(0));
    _gasLimit = bound(_gasLimit, 1, type(uint32).max);
    uint256 _timelock = _relay.relayConfig().entrypointTimelock;

    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _operator);
    uint256 _stampedAt = block.timestamp;
    skip(_timelock);

    // it should revert the whole call and keep the proposal
    vm.mockCallRevert(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), 'ChainPaused');
    vm.prank(_admin);
    vm.expectRevert('ChainPaused');
    _relay.executeOperator(_chainId, _gasLimit, _admin);
    (address _pending, uint48 _proposedAt) = _relay.pendingOperator(_chainId);
    assertEq(_pending, _operator, 'the reverted execution should leave the proposal in place');
    assertEq(_proposedAt, _stampedAt, 'the reverted execution should not restamp the delay');

    // it should let the same proposal land on a retry
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), abi.encode());
    vm.expectCall(
      _voter, 0, abi.encodeCall(IVoter.setOperator, (_RELAY_TOKEN_ID, _chainId, _operator, _gasLimit, _admin))
    );
    vm.prank(_admin);
    _relay.executeOperator(_chainId, _gasLimit, _admin);
    (_pending,) = _relay.pendingOperator(_chainId);
    assertEq(_pending, address(0), 'the retried execution should consume the proposal');
  }

  /// @notice One live proposal per chain: proposing again replaces the operator and restarts the
  ///         delay. The first proposal rides out its whole delay before the replacement, the worst
  ///         case, and the replacement still waits its own delay in full.
  function test_WhenAPendingOperatorProposalIsReplaced(
    uint256 _chainId,
    address _firstOperator,
    address _secondOperator,
    uint256 _gasLimit
  ) external {
    _chainId = bound(_chainId, 1, type(uint64).max);
    vm.assume(_firstOperator != address(0));
    vm.assume(_secondOperator != address(0) && _secondOperator != _firstOperator);
    _gasLimit = bound(_gasLimit, 1, type(uint32).max);
    uint256 _timelock = _relay.relayConfig().entrypointTimelock;

    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _firstOperator);
    skip(_timelock);

    // it should overwrite the proposal with the new operator
    vm.prank(_admin);
    _relay.proposeOperator(_chainId, _secondOperator);
    (address _pending, uint48 _proposedAt) = _relay.pendingOperator(_chainId);
    assertEq(_pending, _secondOperator, 'the replacement was not recorded');

    // it should restart the delay from the replacement
    assertEq(_proposedAt, block.timestamp, 'the delay does not run from the replacement');
    skip(_timelock - 1);
    vm.prank(_admin);
    vm.expectRevert(IRelay.OperatorTimelockNotElapsed.selector);
    _relay.executeOperator(_chainId, _gasLimit, _admin);

    // it should dispatch the replacement once its own delay elapses
    skip(1);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.setOperator.selector), abi.encode());
    vm.expectCall(
      _voter, 0, abi.encodeCall(IVoter.setOperator, (_RELAY_TOKEN_ID, _chainId, _secondOperator, _gasLimit, _admin))
    );
    vm.prank(_admin);
    _relay.executeOperator(_chainId, _gasLimit, _admin);
  }

  /// @notice The small discovery views around the registry and the backing.
  function test_GivenTheDiscoveryViewsAreRead() external {
    // it should report registry membership and contents
    assertFalse(_relay.isRewardToken(_rewardToken));
    _registerRewardToken();
    assertTrue(_relay.isRewardToken(_rewardToken));
    address[] memory _tokens = _relay.rewardTokens();
    assertEq(_tokens.length, 1);
    assertEq(_tokens[0], _rewardToken);

    // it should mirror the backing counter through assetsBacking
    assertEq(_relay.assetsBacking(), _relay.totalBacking());

    // it should expose the PT's timestamp clock (ERC-6372, aligned with VotingEscrow)
    assertEq(_principalToken.clock(), uint48(block.timestamp));
    assertEq(_principalToken.CLOCK_MODE(), 'mode=timestamp');
  }
}
