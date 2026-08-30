// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

import {DEALLOC_GAUGE} from 'V3/libraries/ProtocolConstants.sol';

/// @notice Coverage of the wind-down lanes: the permissionless closing gate (an uncovered head exit),
///         the KEEPER voluntary close, the terminal closed state, the per-chain evacuation
///         dispatch and the emergency deallocation path.
contract UnitRelayWindDown is BaseRelay {
  using stdStorage for StdStorage;

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @dev Mock the gauge-lane Voter cast an evacuation dispatch ends in AND pin its exact payload
  ///      with an expectCall: one full-amount `DEALLOC_GAUGE` overwrite carrying the given gas
  ///      limit, so a mutation in the argument forwarding fails the test.
  function _mockAndExpectEvacuationDispatch(uint256 _chainId, uint128 _booked, uint256 _gasLimit) internal {
    IVoterCommon.GaugeAllocation[] memory _gauges = new IVoterCommon.GaugeAllocation[](1);
    _gauges[0] = IVoterCommon.GaugeAllocation({gauge: DEALLOC_GAUGE, allocated: _booked, data: ''});
    _mockAndExpect(
      _voter,
      abi.encodeCall(IVoter.allocateGauges, (_RELAY_TOKEN_ID, _chainId, _gauges, _gasLimit, address(0))),
      abi.encode()
    );
  }

  /// @dev Mock the named chain's booked weight the dispatch pulls back.
  function _mockBookedWeight(uint256 _chainId, uint128 _booked) internal {
    vm.mockCall(_voter, abi.encodeCall(IVoter.allocationChainAmounts, (_RELAY_TOKEN_ID, _chainId)), abi.encode(_booked));
  }

  /// @dev Mock the free chain0 weight the gate and the drains price against.
  function _mockFreeWeight(uint128 _amount) internal {
    _mockBookedWeight(0, _amount);
  }

  /// @dev Build the one-chain dispatch array a vote grows with.
  function _chainDelta(uint128 _delta) internal pure returns (IVoter.ChainAllocationDispatch[] memory _dispatches) {
    _dispatches = new IVoter.ChainAllocationDispatch[](1);
    _dispatches[0] = IVoter.ChainAllocationDispatch({chainId: 10, delta: _delta, gasLimit: 0, value: 0});
  }

  /// @notice The permissionless close only opens for an uncovered head: old enough AND unpayable.
  ///         A payable head is a drain away from settling, never a reason to shut down. KEEPER is
  ///         the only role above the gate, so the admin waits like anyone else.
  function test_WhenClosingWithoutAnUncoveredHead() external {
    // it should revert when no exit is waiting
    vm.expectRevert(IRelay.NoQueuedWithdrawal.selector);
    _relay.close();

    // it should hold the admin to the same gate
    vm.prank(_admin);
    vm.expectRevert(IRelay.NoQueuedWithdrawal.selector);
    _relay.close();

    // it should revert while the head exit is younger than the evacuation window
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(50e18, _MINT_SENTINEL);
    vm.expectRevert(IRelay.EvacuationWindowNotElapsed.selector);
    _relay.close();

    // it should revert when the free chain0 weight covers the head (the remedy is a drain)
    vm.warp(block.timestamp + 7 days);
    _mockFreeWeight(type(uint128).max);
    vm.expectRevert(IRelay.HeadIsCovered.selector);
    _relay.close();
  }

  /// @notice An uncovered head lets ANYONE close the Relay permanently; once closed, nothing new
  ///         enters and allocation stops. Closing takes no dispatch.
  function test_WhenTheHeadExitIsUncovered() external {
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(50e18, _MINT_SENTINEL);
    vm.warp(block.timestamp + 7 days);
    _mockFreeWeight(0);

    // it should close the relay and emit the closure
    vm.expectEmit(address(_relay));
    emit IRelay.Closed(address(this));
    _relay.close();
    assertTrue(_relay.closed());

    // it should reject new deposit requests once closed
    vm.mockCall(_votingEscrow, abi.encodeCall(IERC721.ownerOf, (2)), abi.encode(users.alice));
    vm.prank(users.alice);
    vm.expectRevert(IRelay.RelayClosed.selector);
    _relay.requestDeposit(2, 5e18);

    // it should reject new allocations once closed
    vm.prank(_allocator);
    vm.expectRevert(IRelay.RelayClosed.selector);
    _relay.allocate(new IVoter.ChainAllocationDispatch[](0), new IVoter.GaugeAllocationDispatch[](0), address(0));

    // it should reject a second close
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RelayClosed.selector);
    _relay.close();
  }

  /// @notice KEEPER closes voluntarily, skipping the starvation gate; no queue state is needed.
  function test_WhenTheKeeperClosesAtWill() external {
    // it should close skipping the starvation gate
    vm.expectEmit(address(_relay));
    emit IRelay.Closed(_keeper);
    vm.prank(_keeper);
    _relay.close();
    assertTrue(_relay.closed());
  }

  /// @notice A deposit registered in the very block of the close is still admitted, and mints the
  ///         principal alone.
  /// @dev The amount is fuzzed over its whole valid range: what the case turns on is the ordering of
  ///      `requestDeposit` and `close()`, which holds for any admitted amount.
  function test_WhenADepositLandsInTheSameBlockAsTheClose(uint256 _amount) external {
    // At or above the dust floor, capped so the seed plus the net still fits the uint128 stake.
    _amount = bound(_amount, _defaultConfig().minDeposit, type(uint128).max - _SEED);

    // `_requestDeposit` does not warp, so `requestedAt == block.timestamp`.
    _requestDeposit(users.alice, 2, _amount);
    vm.prank(_keeper);
    _relay.close();

    vm.prank(_keeper);
    _relay.processPending(1);

    // it should admit the same block deposit and mint its principal at the seed ratio
    assertEq(_principalToken.balanceOf(users.alice), _amount, 'the same-block deposit did not mint principal');
    // it should mint no yield on a closed relay
    assertEq(_yieldToken.balanceOf(users.alice), 0, 'a closed-Relay deposit minted yield');
    // it should drain the pending counter into the backing
    assertEq(_relay.pendingDepositWeight(), 0, 'the admitted weight stayed in the pending counter');
    assertEq(_relay.totalBacking(), _SEED + _amount, 'the backing did not absorb the admitted weight');
  }

  /// @notice A request registered before the close and drained after it is admitted just the same, and
  ///         its principal-only mint keeps it out of the fee-tail denominator.
  /// @dev A 100e18 seed and a 50e18 late deposit leave the YT supply at 100e18, so a 100e18 fee batch
  ///      advances the index by `100e18 * 1e18 / 100e18 = 1e18` and the sole yield holder collects the
  ///      whole batch. A concrete example, so the tail split is exact.
  function test_WhenADepositIsRequestedBeforeTheCloseAndDrainedAfterIt() external {
    _registerRewardToken();

    // Alice requests before the close and is deliberately left pending.
    _requestDeposit(users.alice, 2, 50e18);
    assertEq(_relay.pendingDepositWeight(), 50e18, 'the request did not park in the pending counter');

    // Close a block later, so the cutoff lands strictly after alice's `requestedAt`.
    vm.warp(block.timestamp + 1 hours);
    vm.prank(_keeper);
    _relay.close();

    // it should admit the request registered before the close
    vm.prank(_keeper);
    _relay.processPending(1);
    assertEq(_principalToken.balanceOf(users.alice), 50e18, 'the late deposit did not mint principal');

    // it should leave the fee tail denominator at the seed supply
    assertEq(_yieldToken.balanceOf(users.alice), 0, 'the late deposit minted a diluting yield side');
    assertEq(_yieldToken.totalSupply(), _SEED, 'the yield supply grew past the seed');

    // The fee tail of the final pre-close allocation lands, spread over the un-inflated supply.
    _notifyReward(100e18);

    // it should hand the late depositor nothing
    assertEq(_relay.claimable(users.alice, _rewardToken), 0, 'the late depositor captured a fee slice');
    // it should pay the whole tail to the genuine holder
    assertEq(_relay.claimable(_bootstrapOwner, _rewardToken), 100e18, 'the genuine holder was diluted');
  }

  /// @notice The evacuation dispatch requires the terminal state: closing decides, evacuating
  ///         executes, and no role shortcuts the order.
  function test_WhenEvacuatingAnOpenRelay() external {
    // it should revert with RelayNotClosed
    vm.expectRevert(IRelay.RelayNotClosed.selector);
    _relay.evacuate(10, 100_000, address(0));

    // it should hold the keeper to the same rule
    vm.prank(_keeper);
    vm.expectRevert(IRelay.RelayNotClosed.selector);
    _relay.evacuate(10, 100_000, address(0));
  }

  /// @notice Once closed, anyone pulls the allocated chains home one call each, and a chain whose
  ///         message never applied can be re-dispatched.
  function test_WhenEvacuatingAClosedRelay() external {
    vm.prank(_keeper);
    _relay.close();

    // it should revert when the chain holds nothing to evacuate
    _mockBookedWeight(10, 0);
    vm.expectRevert(IRelay.NothingToEvacuate.selector);
    _relay.evacuate(10, 100_000, address(0));

    // it should dispatch the chain's full weight and stay open for a re-dispatch
    _mockBookedWeight(10, 1000e18);
    _mockAndExpectEvacuationDispatch(10, 1000e18, 100_000);
    vm.expectEmit(address(_relay));
    emit IRelay.Evacuated(address(this));
    _relay.evacuate(10, 100_000, address(0));
    _relay.evacuate(10, 100_000, address(0));
  }

  /// @notice A holder that sold its yield side is trapped while the Relay is open and let out once it
  ///         closes. The exit the closure opens is the whole point of the evacuation: a Relay that dies
  ///         must not keep anybody's principal, and a holder who sold their YT cannot buy it back at a
  ///         fair price once nothing accrues to it but the reward tail.
  /// @dev The two halves are deliberately in one test. Refusing while open is not a bug to be fixed
  ///      later, it is the rule that makes the pair mean something: the yield side is a live claim on the
  ///      distributions, so exiting without it would let a holder sell the stream and still walk away with
  ///      the principal that funds it. What changes at closure is that the stream stops growing, so the
  ///      requirement stops protecting anything and starts trapping people.
  function test_WhenAHolderThatSoldItsWholeYieldSideExitsAClosedRelay() external {
    // The holder sells its whole yield side. Legal on a Maxi deployed with a transferable YT, which is
    // what `_deployMaxi(true)` gives this suite.
    uint256 _sold = _yieldToken.balanceOf(_bootstrapOwner);
    vm.prank(_bootstrapOwner);
    _yieldToken.transfer(users.alice, _sold);
    assertEq(_yieldToken.balanceOf(_bootstrapOwner), 0, 'the holder kept part of its yield side');
    assertEq(_yieldToken.balanceOf(users.alice), _sold, 'the yield side did not move');

    // it should refuse the exit while the relay is open
    uint256 _principalHeld = _principalToken.balanceOf(_bootstrapOwner);
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.InsufficientFreeShares.selector);
    _relay.registerOnWithdrawQueue(_principalHeld, _MINT_SENTINEL);

    // Close the Relay through the voluntary shutdown, which skips the starvation gate.
    vm.prank(_keeper);
    _relay.close();
    assertTrue(_relay.closed(), 'the relay did not close');

    // it should accept the exit once the relay is closed
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(_principalHeld, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(_bootstrapOwner), _principalHeld, 'the exit did not escrow');

    // it should burn the principal and leave the sold yield outstanding
    uint256 _yieldSupplyBefore = _yieldToken.totalSupply();
    _mockFreeWeight(type(uint128).max);
    _mockWithdrawRoute(_bootstrapOwner, (_principalHeld * _relay.totalBacking()) / _principalToken.totalSupply(), 99);
    _relay.processWithdrawals(1);

    assertEq(_principalToken.balanceOf(_bootstrapOwner), 0, 'the principal was not burned');
    assertEq(_relay.escrowedShares(_bootstrapOwner), 0, 'the escrow was not released');
    // The sold yield belongs to whoever bought it and is not the Relay's to take. Past closure the
    // drain does not burn the yield side at all, so it stays outstanding and the supplies diverge.
    assertEq(_yieldToken.totalSupply(), _yieldSupplyBefore, 'the sold yield was confiscated');
    assertEq(_yieldToken.balanceOf(users.alice), _sold, 'the buyer lost its yield side');
    assertGt(_yieldToken.totalSupply(), _principalToken.totalSupply(), 'the supplies did not diverge');
  }

  /// @notice A holder that kept both sides exits a closed Relay with its principal alone: the yield
  ///         side stays in its hands, carrying its claim on whatever rewards still trail in.
  /// @dev The closure does not merely relax the cover check — it turns the yield-side burn off. The
  ///      final votes' fees arrive an epoch later, and the yield supply is what `notifyReward` divides
  ///      them by, so an exit that burned the yield side would hand the tail to whoever leaves last
  ///      and, once the queue fully drained, strand it behind `NoSupply`.
  function test_WhenAHolderThatKeptItsYieldSideExitsAClosedRelay() external {
    vm.prank(_keeper);
    _relay.close();

    uint256 _yieldHeld = _yieldToken.balanceOf(_bootstrapOwner);
    uint256 _yieldSupplyBefore = _yieldToken.totalSupply();
    uint256 _principalHeld = _principalToken.balanceOf(_bootstrapOwner);
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(_principalHeld, _MINT_SENTINEL);

    _mockFreeWeight(type(uint128).max);
    _mockWithdrawRoute(_bootstrapOwner, (_principalHeld * _relay.totalBacking()) / _principalToken.totalSupply(), 99);
    _relay.processWithdrawals(1);

    // it should burn only the principal
    assertEq(_principalToken.balanceOf(_bootstrapOwner), 0, 'the principal was not burned');
    // it should leave the holders yield side untouched
    assertEq(_yieldToken.balanceOf(_bootstrapOwner), _yieldHeld, 'the yield side moved');
    assertEq(_yieldToken.totalSupply(), _yieldSupplyBefore, 'the yield supply moved');
  }

  /// @notice Once closed the yield side is out of the withdrawal entirely — not required to
  ///         register, not burned at settlement — so a queued exit no longer freezes it: the holder
  ///         can sell the receipt for the fee tail while the principal exit waits in the FIFO.
  /// @dev The pre-state is seeded directly (closed flag, escrow, YT balance) so this test reaches
  ///      only the transfer hook; the register and drain sides of the closure have their own tests.
  ///      The escrow bound deliberately reaches above the balance: a closed-relay register needs no
  ///      YT, so the ledger can exceed what the holder still holds.
  function test_WhenTransferringTheYieldSideWithAQueuedExitOnAClosedRelay(
    address _holder,
    address _recipient,
    uint256 _balance,
    uint256 _escrowed
  ) external {
    _assumeFuzzable(_holder);
    _assumeFuzzable(_recipient);
    vm.assume(_holder != _recipient);
    // The satellite bans the protocol addresses as recipients (itself, the Relay, the sibling
    // PT) — separate branches with their own tests.
    vm.assume(
      _recipient != address(_principalToken) && _recipient != address(_yieldToken) && _recipient != address(_relay)
    );
    _balance = bound(_balance, 1, type(uint128).max);
    _escrowed = bound(_escrowed, 1, type(uint128).max);

    // `closed` is a packed bool, so the probe must handle the packing.
    stdstore.enable_packed_slots().target(address(_relay)).sig('closed()').checked_write(true);
    stdstore.target(address(_relay)).sig('escrowedShares(address)').with_key(_holder).checked_write(_escrowed);
    stdstore.target(address(_yieldToken)).sig('balanceOf(address)').with_key(_holder).checked_write(_balance);
    uint256 _recipientBefore = _yieldToken.balanceOf(_recipient);

    // it should let the whole yield balance move while the exit waits
    vm.prank(_holder);
    assertTrue(_yieldToken.transfer(_recipient, _balance));
    assertEq(_yieldToken.balanceOf(_recipient), _recipientBefore + _balance, 'the yield side did not move');
    assertEq(_yieldToken.balanceOf(_holder), 0, 'the holder kept part of its yield side');

    // it should keep the escrow intact for the drain
    assertEq(_relay.escrowedShares(_holder), _escrowed, 'the escrow moved with the transfer');
  }

  /// @notice The reward lane outlives the closure: a fee batch notified after every exit settled still
  ///         distributes, and the exited holder collects its slice with a plain claim.
  /// @dev This is the case the skipped burn exists for. The last votes' fees arrive an epoch after the
  ///      closure, and had the drain burned the yield side, the full exit below would zero the supply
  ///      and the notify would revert with `NoSupply`, stranding the tail on a dead Relay forever.
  function test_WhenARewardArrivesAfterTheClosure() external {
    _registerRewardToken();
    vm.prank(_keeper);
    _relay.close();

    // The whole principal exits before the reward lands.
    uint256 _principalHeld = _principalToken.balanceOf(_bootstrapOwner);
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(_principalHeld, _MINT_SENTINEL);
    _mockFreeWeight(type(uint128).max);
    _mockWithdrawRoute(_bootstrapOwner, (_principalHeld * _relay.totalBacking()) / _principalToken.totalSupply(), 99);
    _relay.processWithdrawals(1);
    assertEq(_principalToken.totalSupply(), 0, 'some principal stayed behind');

    // it should distribute over the surviving yield supply
    _notifyReward(90e18);

    // it should pay the exited holder in full
    assertEq(_relay.claimable(_bootstrapOwner, _rewardToken), 90e18, 'the tail did not accrue to the exited holder');
    vm.mockCall(_rewardToken, abi.encodeCall(IERC20.transfer, (_bootstrapOwner, 90e18)), abi.encode(true));
    vm.prank(_bootstrapOwner);
    assertEq(_relay.claim(_rewardToken, _bootstrapOwner), 90e18, 'the claim paid the wrong amount');
  }

  /// @notice Emergency deallocation is an operator decision while the Relay is open, and
  ///         permissionless once closed so the wind-down never depends on a privileged caller.
  function test_WhenEmergencyDeallocating() external {
    // it should revert for a random caller while the relay is open
    vm.expectRevert(IRelay.NotAuthorized.selector);
    _relay.emergencyDeallocate(10, 100_000, address(0));

    // it should revert for the admin while the relay is open
    vm.prank(_admin);
    vm.expectRevert(IRelay.NotAuthorized.selector);
    _relay.emergencyDeallocate(10, 100_000, address(0));

    // it should forward the keeper's call to the Voter's emergency path, funded by the whole msg.value
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.emergencyDeallocate.selector), abi.encode());
    vm.expectCall(
      _voter, 3 ether, abi.encodeCall(IVoter.emergencyDeallocate, (_RELAY_TOKEN_ID, 10, 100_000, address(0)))
    );
    hoax(_keeper, 3 ether);
    _relay.emergencyDeallocate{value: 3 ether}(10, 100_000, address(0));

    // it should open the path to anyone once the relay is closed
    vm.prank(_keeper);
    _relay.close();
    _relay.emergencyDeallocate(10, 100_000, address(0));
  }

  /// @notice An allocation carrying no dispatches at all is rejected.
  function test_WhenAllocatingWithNoDispatches() external {
    vm.prank(_allocator);
    vm.expectRevert(IRelay.EmptyAllocation.selector);
    _relay.allocate(new IVoter.ChainAllocationDispatch[](0), new IVoter.GaugeAllocationDispatch[](0), address(0));
  }

  /// @notice A donation lands on the Relay sAERO's chain0 weight before it counts as backing, so a
  ///         vote priced on the backing counter alone spends weight the queue is about to be owed.
  ///         The queued exit here holds half the shares, so it owns half of everything the Relay
  ///         holds, the donation included, and the vote may only spend the other half. Priced the
  ///         other way, recognizing the donation raises the price per share over weight the vote
  ///         already sent away, the exit can no longer be paid, and the permissionless close opens.
  /// @dev The Voter is mocked, so the chain0 reading is re-mocked by hand after the accepted vote,
  ///      mirroring the debit the real Voter applies to chain0 within that same call.
  function test_WhenADonationIsRecognizedAfterTheKeeperVoted(uint256 _donation) external {
    // Even donations only: the queue owns exactly half the supply, so half the donation has to be a
    // whole number of wei for the hand-computed halves below to be exact.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 _idle = uint128(_SEED + 2 * bound(_donation, 1e18, 500e18));

    // The bootstrap owner queues half of its seed position; the whole stake is still idle.
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(_SEED / 2, _MINT_SENTINEL);

    // A third party moves weight into the Relay sAERO. VE mirrors the move onto chain0, so the
    // Voter offers it as free weight, but the Relay does not count it as backing until the keeper
    // recognizes it.
    _mockRelayStaked(_idle);
    _mockFreeWeight(_idle);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.allocate.selector), abi.encode());

    // Half the shares are queued, so half of everything the Relay holds is owed to that exit.
    uint128 _owed = _idle / 2;

    // it should refuse a vote that spends the weight the queue is about to be owed
    vm.prank(_allocator);
    vm.expectRevert(IRelay.InsufficientFreeWeight.selector);
    _relay.allocate(_chainDelta(_owed + 1), new IVoter.GaugeAllocationDispatch[](0), address(0));

    // it should let the vote spend everything above the donation priced reserve
    vm.prank(_allocator);
    _relay.allocate(_chainDelta(_idle - _owed), new IVoter.GaugeAllocationDispatch[](0), address(0));
    _mockFreeWeight(_owed);

    // The keeper recognizes the donation: the price per share rises for every holder, the queued
    // exit included.
    vm.prank(_keeper);
    _relay.processDonations();
    assertEq(_relay.totalBacking(), _idle, 'the donation did not reach the backing');

    // it should refuse the permissionless close once the donation is recognized
    vm.warp(block.timestamp + 7 days);
    vm.expectRevert(IRelay.HeadIsCovered.selector);
    _relay.close();

    // it should settle the exit at the recognized price
    _mockWithdrawRoute(_bootstrapOwner, _owed, 2);
    _relay.processWithdrawals(1);
    assertEq(_principalToken.balanceOf(_bootstrapOwner), _SEED / 2, 'the settle did not burn the principal');
    assertEq(_relay.pendingWithdrawalShares(), 0, 'the escrow survived the settle');
    _assertPairInvariant();
  }

  /// @notice The mirror of the case above: recognizing the donation first has to leave the vote with
  ///         the same budget it has when the donation is still pending. The reserve is priced on the
  ///         stake, and `processDonations` moves weight from unrecognized to backing without moving
  ///         the stake, so the boundary lands on the same wei in both orders.
  function test_WhenTheKeeperRecognizesTheDonationBeforeVoting(uint256 _donation) external {
    // forge-lint: disable-next-line(unsafe-typecast)
    uint128 _idle = uint128(_SEED + 2 * bound(_donation, 1e18, 500e18));

    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(_SEED / 2, _MINT_SENTINEL);

    _mockRelayStaked(_idle);
    _mockFreeWeight(_idle);
    vm.mockCall(_voter, abi.encodeWithSelector(IVoter.allocate.selector), abi.encode());

    // This time the keeper recognizes the surplus before casting anything.
    vm.prank(_keeper);
    _relay.processDonations();
    assertEq(_relay.totalBacking(), _idle, 'the donation did not reach the backing');

    // Half the shares are queued, so half of everything the Relay holds is owed to that exit.
    uint128 _owed = _idle / 2;

    // it should refuse the vote that reaches past it
    vm.prank(_allocator);
    vm.expectRevert(IRelay.InsufficientFreeWeight.selector);
    _relay.allocate(_chainDelta(_owed + 1), new IVoter.GaugeAllocationDispatch[](0), address(0));

    // it should price the queue against the same weight either way
    vm.expectEmit(address(_relay));
    emit IRelay.Allocated(_allocator);
    vm.prank(_allocator);
    _relay.allocate(_chainDelta(_idle - _owed), new IVoter.GaugeAllocationDispatch[](0), address(0));
  }
}
