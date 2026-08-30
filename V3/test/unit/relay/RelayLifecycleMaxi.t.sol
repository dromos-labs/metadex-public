// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC20} from '@solady/tokens/ERC20.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/// @notice Lifecycle over a MaxiRelay deployed with a transferable yield token: the bootstrap
///         pair mint, ratio-priced admissions, holder-to-holder YT moves settling seller and buyer,
///         the escrow lock, the fully-escrowed drain regression, the burn-path settle, the
///         recipient bans on both sides (token and hook) and the mint/burn/initialize/hook
///         negative auth gates.
/// @dev    Concrete stateful stories on purpose: each step's expected values are hand-computed from
///         the seeded 1:1 genesis (seed 100e18), so fuzzing would replace known examples with a
///         re-derivation of the contract's own pricing formula. `_assertPairInvariant` runs after
///         every step (the admission helper embeds it).
contract UnitRelayLifecycleMaxi is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @notice Genesis: initialize clones the two satellites and pair-mints the bootstrap 1:1
  ///         against the seed to the bootstrap owner.
  function test_GivenAFreshlyInitializedMaxiRelay() external view {
    // it should clone two distinct satellites bound to the relay
    assertTrue(address(_principalToken) != address(0));
    assertTrue(address(_yieldToken) != address(0));
    assertTrue(address(_principalToken) != address(_yieldToken));
    assertEq(_principalToken.relay(), address(_relay));
    assertEq(_yieldToken.relay(), address(_relay));

    // it should derive the satellite names and symbols from the config stems
    assertEq(_principalToken.name(), 'Test Relay PT');
    assertEq(_principalToken.symbol(), 'tREL-PT');
    assertEq(_yieldToken.name(), 'Test Relay YT');
    assertEq(_yieldToken.symbol(), 'tREL-YT');

    // it should deploy the PT soulbound and the YT transferable (the deploy switch)
    assertFalse(_principalToken.transferable());
    assertTrue(_yieldToken.transferable());

    // it should pair mint the bootstrap one-to-one against the seed
    assertEq(_principalToken.balanceOf(_bootstrapOwner), _SEED);
    assertEq(_yieldToken.balanceOf(_bootstrapOwner), _SEED);
    assertEq(_principalToken.totalSupply(), _SEED);
    assertEq(_relay.totalBacking(), _SEED);
    _assertPairInvariant();
  }

  /// @notice Admission prices against the live ratio: after a donation doubles the backing, a
  ///         50e18 deposit pair-mints 25e18 to the depositor.
  function test_WhenTheKeeperProcessesAPendingDeposit() external {
    // Donation: backing 100e18 -> 200e18 against the unchanged 100e18 supply (ratio 2:1).
    _mockRelayStaked(200e18);
    vm.prank(_keeper);
    _relay.processDonations();
    assertEq(_relay.totalBacking(), 200e18);
    _assertPairInvariant();

    uint256 _shares = _admitDeposit(users.alice, 2, 50e18);

    // it should pair mint at the 2:1 ratio: 50e18 backing buys 25e18 shares
    assertEq(_shares, 25e18);
    assertEq(_principalToken.balanceOf(users.alice), 25e18);
    assertEq(_yieldToken.balanceOf(users.alice), 25e18);
    assertEq(_principalToken.totalSupply(), 125e18);
    assertEq(_relay.totalBacking(), 250e18);
    _assertPairInvariant();
  }

  /// @notice A pair mint fires the hook twice, PT first then YT, and the PT leg returns early. The
  ///         settle is therefore run once, by the YT leg. The early return is not observable in
  ///         storage (a second settle in the same frame is a zero-delta no-op), so it is pinned
  ///         here by the external read it saves: the balance lookup `_settleAll` opens with.
  function test_WhenThePrincipalTokenFiresTheHookOnAPairMint() external {
    _requestDeposit(users.alice, 2, 50e18);

    // it should read the recipient's yield balance exactly once across both hook calls
    vm.expectCall(address(_yieldToken), abi.encodeCall(IRelayToken.balanceOf, (users.alice)), 1);
    _processPending(1);

    // it should pair mint at the genesis one to one ratio
    assertEq(_principalToken.balanceOf(users.alice), 50e18);
    _assertPairInvariant();
  }

  /// @notice The pending-deposit counter accumulates across requests and gives back exactly the
  ///         weight each admission moves into the backing, so a partial drain leaves the rest
  ///         pending. The counter is what keeps un-admitted weight from reading as a donation.
  function test_WhenOnlyTheFirstOfTwoPendingDepositsIsAdmitted() external {
    _requestDeposit(users.alice, 2, 2e18);
    _requestDeposit(users.bob, 3, 3e18);

    // it should accumulate both requests into the pending counter (2e18 + 3e18)
    assertEq(_relay.pendingDepositWeight(), 5e18);
    // it should keep the pending weight out of the backing until admission
    assertEq(_relay.totalBacking(), _SEED);

    _processPending(1);

    // it should hand back only the head's weight (5e18 - 2e18 pending, seed + 2e18 backing)
    assertEq(_relay.pendingDepositWeight(), 3e18);
    assertEq(_relay.totalBacking(), 102e18);
    // it should pair mint the head at the genesis one to one ratio and leave the tail queued
    assertEq(_principalToken.balanceOf(users.alice), 2e18);
    assertEq(_yieldToken.balanceOf(users.alice), 2e18);
    assertEq(_principalToken.balanceOf(users.bob), 0);
    _assertPairInvariant();
  }

  /// @notice A holder-to-holder YT transfer settles both ends against pre-transfer balances: the
  ///         seller keeps the accrual to date, the buyer only accrues from the next batch on.
  function test_WhenTheYieldTokenIsTransferredAroundANotify() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, alice accrues 100e18.
    _notifyReward(200e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);

    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 50e18));
    _assertPairInvariant();

    // it should lock the seller's accrual to date into pendingReward at the pre-transfer balance
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);
    // it should checkpoint the buyer at the current index with nothing accrued
    assertEq(_relay.claimable(users.bob, _rewardToken), 0);
    assertEq(_relay.userCheckpoint(users.bob, _rewardToken), 1e18);
    // it should move YT only; the PT position stays with the seller
    assertEq(_yieldToken.balanceOf(users.alice), 50e18);
    assertEq(_yieldToken.balanceOf(users.bob), 50e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);
    assertEq(_principalToken.balanceOf(users.bob), 0);

    // 100e18 over 200e18 supply: index delta 0.5e18, accruing to the post-transfer balances.
    _notifyReward(100e18);
    // it should accrue the next batch to the post-transfer balances (seller 50, buyer 50)
    assertEq(_relay.claimable(users.alice, _rewardToken), 125e18);
    assertEq(_relay.claimable(users.bob, _rewardToken), 25e18);
    _assertPairInvariant();
  }

  /// @notice A holder-to-holder YT transferFrom settles both ends exactly like `transfer` — the
  ///         seller keeps the accrual to date at the pre-transfer balance, the buyer accrues from
  ///         the next batch on — and decrements the spender's allowance.
  function test_WhenTheYieldTokenMovesThroughAnAllowance() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, alice accrues 100e18.
    _notifyReward(200e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);

    vm.prank(users.alice);
    assertTrue(_yieldToken.approve(users.bob, 60e18));
    vm.prank(users.bob);
    assertTrue(_yieldToken.transferFrom(users.alice, users.bob, 50e18));
    _assertPairInvariant();

    // it should decrement the spender's allowance by exactly the moved amount
    assertEq(_yieldToken.allowance(users.alice, users.bob), 10e18);
    // it should lock the seller's accrual to date into pendingReward at the pre-transfer balance
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);
    // it should checkpoint the buyer at the current index with nothing accrued
    assertEq(_relay.claimable(users.bob, _rewardToken), 0);
    assertEq(_relay.userCheckpoint(users.bob, _rewardToken), 1e18);
    // it should move YT only; the PT position stays with the seller
    assertEq(_yieldToken.balanceOf(users.alice), 50e18);
    assertEq(_yieldToken.balanceOf(users.bob), 50e18);
    assertEq(_principalToken.balanceOf(users.alice), 100e18);
    assertEq(_principalToken.balanceOf(users.bob), 0);

    // 100e18 over 200e18 supply: index delta 0.5e18, accruing to the post-transfer balances.
    _notifyReward(100e18);
    // it should accrue the next batch to the post-transfer balances (seller 50, buyer 50)
    assertEq(_relay.claimable(users.alice, _rewardToken), 125e18);
    assertEq(_relay.claimable(users.bob, _rewardToken), 25e18);
    _assertPairInvariant();
  }

  /// @notice Two settles with no claim in between add up: the second one banks the new accrual on
  ///         top of what the first one banked, it never replaces it.
  function test_WhenAHolderSettlesTwiceWithoutClaiming() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, on alice's 100e18 that is 100e18.
    _notifyReward(200e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);

    // A second 200e18 over the unchanged 200e18 supply: another 1e18 of index, now on 90e18.
    _notifyReward(200e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));

    // it should bank the second settle on top of the first (100e18 + 90e18)
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 190e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 190e18);
    // it should bank the buyer's own accrual from the batch he held through (10e18 x 1e18)
    assertEq(_relay.pendingReward(users.bob, _rewardToken), 10e18);
    _assertPairInvariant();
  }

  /// @notice Claim pays out the settled accrual and de-accounts it, without touching the pair.
  function test_WhenAHolderClaims() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();
    _notifyReward(200e18);

    _mockAndExpectTokenTransfer(_rewardToken, users.alice, 100e18);
    // it should emit the claim payout
    vm.expectEmit(address(_relay));
    emit IRelay.RewardClaimed(users.alice, _rewardToken, users.alice, 100e18);
    vm.prank(users.alice);
    uint256 _amount = _relay.claim(_rewardToken, users.alice);

    // it should pay out the full accrual and zero the claimable balance
    assertEq(_amount, 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 0);
    assertEq(_relay.accountedBalance(_rewardToken), 100e18);
    _assertPairInvariant();

    // The bootstrap owner holds the other half of the 200e18 YT supply, so the same 200e18 batch
    // owes him the same 100e18. His claim is the last one the batch can pay.
    _mockAndExpectTokenTransfer(_rewardToken, _bootstrapOwner, 100e18);
    vm.prank(_bootstrapOwner);
    uint256 _ownerAmount = _relay.claim(_rewardToken, _bootstrapOwner);

    // it should de-account every payout, so the batch's ledger empties (200e18 - 100e18 - 100e18)
    assertEq(_ownerAmount, 100e18);
    assertEq(_relay.accountedBalance(_rewardToken), 0);
  }

  /// @notice A claim adds the fresh accrual since the last checkpoint ON TOP of the pending balance
  ///         an earlier settle already locked in. Hand-computed: 100e18 settled by the transfer plus
  ///         50e18 accrued on the post-transfer balance, never one of the two alone.
  function test_WhenClaimingWithPendingAndFreshAccrual() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, alice accrues 100e18 unsettled.
    _notifyReward(200e18);
    // The transfer settles alice at the pre-transfer balance: pending 100e18, checkpoint 1e18.
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 50e18));
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);

    // Second batch: 200e18 over the unchanged 200e18 supply, the index reaches 2e18.
    _notifyReward(200e18);

    // it should pay the carried pending plus the fresh accrual on the post-transfer balance
    _mockAndExpectTokenTransfer(_rewardToken, users.alice, 150e18);
    vm.prank(users.alice);
    uint256 _amount = _relay.claim(_rewardToken, users.alice);
    assertEq(_amount, 150e18);

    // it should zero the claimable balance and advance the checkpoint to the live index
    assertEq(_relay.claimable(users.alice, _rewardToken), 0);
    assertEq(_relay.userCheckpoint(users.alice, _rewardToken), 2e18);
    assertEq(_relay.accountedBalance(_rewardToken), 250e18);
    _assertPairInvariant();
  }

  /// @notice A pair mint settles the recipient at the PRE-mint YT balance: the accrual to date is
  ///         locked in before the new shares land, so a fresh mint never captures a batch notified
  ///         before it. (The pair mint fires the hook twice — PT then YT — but an "exactly once"
  ///         settle is not falsifiable through state: once the first settle advances the
  ///         checkpoint, a second settle in the same frame is a zero-delta no-op by construction.)
  function test_WhenAPairMintsToAnAccruingHolder() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();
    // Index delta 1e18 over the 200e18 supply; alice's 100e18 accrual is not yet settled.
    _notifyReward(200e18);

    uint256 _shares = _admitDeposit(users.alice, 3, 50e18);
    assertEq(_shares, 50e18);

    // it should settle at the pre-mint balance: 100e18 x 1e18 locked in, the checkpoint advanced,
    // and the fresh 50e18 minted without capturing the earlier batch
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);
    assertEq(_relay.userCheckpoint(users.alice, _rewardToken), 1e18);
    assertEq(_yieldToken.balanceOf(users.alice), 150e18);
    // it should never settle the zero address on a mint (the hook skips the zero end)
    assertEq(_relay.userCheckpoint(address(0), _rewardToken), 0);
    _assertPairInvariant();
  }

  /// @notice Registering an exit needs free balance on BOTH satellites: a holder who sold YT
  ///         cannot escrow more than the YT leg covers, even though the PT leg would.
  function test_WhenRegisteringAnExitAfterSellingTheYield() external {
    _admitDeposit(users.alice, 2, 100e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 50e18));

    // it should revert with InsufficientFreeShares: PT covers 60e18 but YT holds only 50e18
    vm.expectRevert(IRelay.InsufficientFreeShares.selector);
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(60e18, _MINT_SENTINEL);
  }

  /// @notice The register guard checks the PT leg independently: a pure YT buyer (no PT) cannot
  ///         queue a withdrawal at all. Without this clause the entry would permanently stall the
  ///         withdraw FIFO — the drain's PT burn would underflow at the head, with no cancel or
  ///         skip to route around it.
  function test_WhenRegisteringAnExitWithoutPrincipal() external {
    _admitDeposit(users.alice, 2, 100e18);
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 50e18));

    // it should revert with InsufficientFreeShares: bob's YT covers 50e18 but he holds zero PT
    vm.expectRevert(IRelay.InsufficientFreeShares.selector);
    vm.prank(users.bob);
    _relay.registerOnWithdrawQueue(50e18, _MINT_SENTINEL);
  }

  /// @notice The escrow locks the pair in place: YT transfers only move what the balance covers
  ///         beyond the escrowed units.
  function test_WhenTransferringPastTheEscrowedBalance() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should emit the exit registration at the tail slot
    vm.expectEmit(address(_relay));
    emit IRelay.WithdrawRegistered(users.alice, 80e18, _MINT_SENTINEL, 1);
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(80e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.alice), 80e18);
    _assertPairInvariant();

    // it should block a transfer the escrow no longer covers (100e18 < 80e18 + 30e18)
    vm.expectRevert(IRelay.EscrowedSharesLocked.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(users.bob, 30e18);

    // it should let a move the balance covers with room to spare through (100e18 > 80e18 + 10e18)
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));
    assertEq(_yieldToken.balanceOf(users.alice), 90e18);
    _assertPairInvariant();

    // it should still move exactly the free 10e18 that is left (90e18 == 80e18 + 10e18)
    vm.prank(users.alice);
    assertTrue(_yieldToken.transfer(users.bob, 10e18));
    assertEq(_yieldToken.balanceOf(users.alice), 80e18);
    _assertPairInvariant();

    // it should lock a fully escrowed balance completely
    vm.expectRevert(IRelay.EscrowedSharesLocked.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(users.bob, 1);
  }

  /// @notice With nothing escrowed the hook skips the escrow clause outright, so an oversized
  ///         transfer falls through to the token's own balance check. The clause must not turn a
  ///         plain overdraft into an escrow revert for a holder who has queued no exit.
  function test_WhenTransferringMoreYieldThanTheBalance() external {
    _admitDeposit(users.alice, 2, 100e18);
    assertEq(_relay.escrowedShares(users.alice), 0);

    // it should revert with the token's InsufficientBalance, not with the escrow lock
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(users.bob, 101e18);
  }

  /// @notice THE queue-stalling regression: a FULL drain of a FULLY escrowed holder must pass —
  ///         the escrow pre-decrement makes the burn-side checks hold arithmetically.
  function test_WhenDrainingAFullyEscrowedHolder() external {
    _admitDeposit(users.alice, 2, 100e18);

    // A second depositor's weight sits pending across the drain, so the counters carry a nonzero
    // pending leg the whole way through and the burn side cannot lean on an empty queue.
    _requestDeposit(users.bob, 3, 100e18);
    assertEq(_relay.pendingDepositWeight(), 100e18);

    // Escrow the ENTIRE position: balances 100e18, escrow 100e18, zero free.
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(100e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.alice), 100e18);
    assertEq(_yieldToken.balanceOf(users.alice), 100e18);
    _assertPairInvariant();

    _mockWithdrawRoute(users.alice, 100e18, 777);
    _relay.processWithdrawals(1);

    // it should pair burn the full escrowed position
    assertEq(_principalToken.balanceOf(users.alice), 0);
    assertEq(_yieldToken.balanceOf(users.alice), 0);
    // it should zero the escrow and the pending withdrawal counter
    assertEq(_relay.escrowedShares(users.alice), 0);
    assertEq(_relay.pendingWithdrawalShares(), 0);
    // it should debit the supply and the counters back to the seed
    assertEq(_principalToken.totalSupply(), 100e18);
    assertEq(_relay.totalBacking(), 100e18);
    _assertPairInvariant();
  }

  /// @notice One escrow counter carries every exit a holder queues, and a drain releases exactly
  ///         the head entry's shares. The tail stays escrowed and stays locked in place.
  function test_WhenDrainingOnlyTheFirstOfTwoQueuedExits() external {
    _admitDeposit(users.alice, 2, 100e18);

    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(2e18, _MINT_SENTINEL);
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(3e18, _MINT_SENTINEL);

    // it should accumulate both entries into the escrow and the pending counter (2e18 + 3e18)
    assertEq(_relay.escrowedShares(users.alice), 5e18);
    assertEq(_relay.pendingWithdrawalShares(), 5e18);

    // Backing 200e18 over a 200e18 supply: the head's 2e18 of shares route 2e18 of weight out.
    _mockWithdrawRoute(users.alice, 2e18, 777);
    _relay.processWithdrawals(1);

    // it should release only the head's shares, leaving the tail escrowed (5e18 - 2e18)
    assertEq(_relay.escrowedShares(users.alice), 3e18);
    assertEq(_relay.pendingWithdrawalShares(), 3e18);
    // it should pair burn only the head's shares (100e18 - 2e18)
    assertEq(_principalToken.balanceOf(users.alice), 98e18);
    assertEq(_yieldToken.balanceOf(users.alice), 98e18);
    assertEq(_relay.totalBacking(), 198e18);
    _assertPairInvariant();

    // it should keep the tail locked in place: only 95e18 of the 98e18 left is free
    vm.expectRevert(IRelay.EscrowedSharesLocked.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(users.bob, 96e18);
  }

  /// @notice The drain's pair burn settles the holder at the PRE-burn YT balance: accrual never
  ///         settled before a full exit survives it as pendingReward and pays out afterwards.
  ///         This pins settle-at-pre-burn-balance on the burn path, alongside the transfer and
  ///         mint paths pinned above.
  function test_WhenDrainingAnAccruingExit() external {
    _admitDeposit(users.alice, 2, 100e18);
    _registerRewardToken();

    // 200e18 over the 200e18 YT supply: index delta 1e18, alice accrues 100e18 — NOT settled.
    _notifyReward(200e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 0);

    // Full exit: escrow the entire position, then drain it (pair burn).
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(100e18, _MINT_SENTINEL);
    _mockWithdrawRoute(users.alice, 100e18, 777);
    _relay.processWithdrawals(1);
    _assertPairInvariant();

    // it should lock the accrual into pendingReward at the pre-burn balance
    assertEq(_yieldToken.balanceOf(users.alice), 0);
    assertEq(_relay.pendingReward(users.alice, _rewardToken), 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 100e18);

    // it should pay the accrual out after the full exit
    _mockAndExpectTokenTransfer(_rewardToken, users.alice, 100e18);
    vm.prank(users.alice);
    uint256 _amount = _relay.claim(_rewardToken, users.alice);
    assertEq(_amount, 100e18);
    assertEq(_relay.claimable(users.alice, _rewardToken), 0);
    assertEq(_relay.accountedBalance(_rewardToken), 100e18);
  }

  /// @notice The zero address is the only banned recipient; the protocol addresses are not.
  function test_WhenTransferringYieldToTheZeroAddress() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should revert with InvalidRecipient for the zero address
    vm.expectRevert(IRelayToken.InvalidRecipient.selector);
    vm.prank(users.alice);
    _yieldToken.transfer(address(0), 1e18);

    // it should accept the relay, the token itself and the sibling satellite alike
    vm.startPrank(users.alice);
    _yieldToken.transfer(address(_relay), 1e18);
    _yieldToken.transfer(address(_yieldToken), 1e18);
    _yieldToken.transfer(address(_principalToken), 1e18);
    vm.stopPrank();

    // it should leave the supply and the pair invariant untouched, so nothing was burned in passing
    assertEq(_yieldToken.balanceOf(users.alice), 97e18);
    assertEq(_yieldToken.totalSupply(), _SEED + 100e18);
    _assertPairInvariant();
  }

  /// @notice The PT never transfers holder-to-holder, even on a relay whose YT is transferable.
  function test_WhenTransferringThePrincipalToken() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should revert with TokenNotTransferable on transfer
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.alice);
    _principalToken.transfer(users.bob, 1e18);

    // it should revert with TokenNotTransferable on transferFrom
    vm.expectRevert(IRelayToken.TokenNotTransferable.selector);
    vm.prank(users.bob);
    _principalToken.transferFrom(users.alice, users.bob, 1e18);
  }

  /// @notice Mint is relay-only: any other caller bounces off the satellite before any balance
  ///         changes.
  function test_WhenMintingFromOutsideTheRelay() external {
    // it should revert with NotRelay
    vm.expectRevert(IRelayToken.NotRelay.selector);
    vm.prank(users.alice);
    _yieldToken.mint(users.alice, 1e18);
  }

  /// @notice Burn is relay-only: not even the holder can burn their own balance directly.
  function test_WhenBurningFromOutsideTheRelay() external {
    _admitDeposit(users.alice, 2, 100e18);

    // it should revert with NotRelay
    vm.expectRevert(IRelayToken.NotRelay.selector);
    vm.prank(users.alice);
    _yieldToken.burn(users.alice, 1e18);
  }

  /// @notice A live satellite clone can never be re-initialized: re-binding the relay or flipping
  ///         the transferable switch is off the table.
  function test_WhenInitializingASatelliteTwice() external {
    // it should revert with AlreadyInitialized
    vm.expectRevert(IRelayToken.AlreadyInitialized.selector);
    _yieldToken.initialize('Evil Token', 'EVL', true);
  }

  /// @notice The hook authenticates its caller against the two satellite addresses: a direct call
  ///         from anyone else reverts before any settle or authorization runs.
  function test_WhenTheHookCallerIsNotASatellite() external {
    // it should revert with NotAuthorized
    vm.expectRevert(IRelay.NotAuthorized.selector);
    vm.prank(users.alice);
    _relay.onRelayTokenTransfer(users.alice, users.bob, 1e18);
  }
}
