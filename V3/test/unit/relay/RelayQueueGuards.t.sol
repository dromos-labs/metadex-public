// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';

/// @notice Coverage of the guards on the deposit queue and the withdraw FIFO, and of the
///         permissionless by-id processing: the liveness fallback that keeps a sleeping keeper
///         (or a backlog before an entry) from blocking admission.
contract UnitRelayQueueGuards is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @dev Wrap one id into the array `processOverduePending` takes.
  function _ids(uint256 _id) internal pure returns (uint256[] memory _array) {
    _array = new uint256[](1);
    _array[0] = _id;
  }

  /// @notice Anyone can process a deposit by id after the keeper ignores it past `keeperWindow`,
  ///         and only overdue ids: a fresh entry stays the keeper's, whatever sits around it.
  function test_WhenProcessingOverdueDepositsById(address _caller) external {
    _assumeFuzzable(_caller);
    // it should revert on an empty ids array
    vm.expectRevert(IRelay.NoPendingDeposits.selector);
    vm.prank(_caller);
    _relay.processOverduePending(new uint256[](0));

    // two requests: A (id one) ages past the keeper window, B (id two) stays fresh
    // it should emit the request under its list id
    vm.expectEmit(address(_relay));
    emit IRelay.DepositRequested(2, users.alice, 10e18, 1);
    _requestDeposit(users.alice, 2, 10e18);
    vm.warp(block.timestamp + 1 days + 5);
    // it should advance the emitted id request by request
    vm.expectEmit(address(_relay));
    emit IRelay.DepositRequested(3, users.bob, 10e18, 2);
    _requestDeposit(users.bob, 3, 10e18);

    // it should revert on an id that was never issued
    vm.expectRevert(IRelay.DepositNotFound.selector);
    vm.prank(_caller);
    _relay.processOverduePending(_ids(3));

    // it should revert while the named entry is still fresh
    vm.expectRevert(IRelay.KeeperWindowNotElapsed.selector);
    vm.prank(_caller);
    _relay.processOverduePending(_ids(2));

    // it should process only the named overdue entries, permissionlessly
    vm.prank(_caller);
    _relay.processOverduePending(_ids(1));
    assertEq(_principalToken.balanceOf(users.alice), 10e18);
    assertEq(_principalToken.balanceOf(users.bob), 0);
    _assertPairInvariant();

    // it should not process the same entry twice
    vm.expectRevert(IRelay.DepositAlreadyProcessed.selector);
    vm.prank(_caller);
    _relay.processOverduePending(_ids(1));

    // it should let the keeper walk skip the processed entry and process the fresh tail
    _processPending(5);
    assertEq(_principalToken.balanceOf(users.bob), 10e18);
    (uint40 _head, uint40 _tail, uint40 _count) = _relay.depositList();
    assertEq(_head, 0);
    assertEq(_tail, 2);
    assertEq(_count, 0);
    _assertPairInvariant();
  }

  /// @notice The by-id gate admits an entry whose age equals `keeperWindow` exactly: the window is
  ///         a floor, not a strict threshold, so the fallback does not stall one second short.
  function test_WhenTheOldestDepositIsExactlyAtTheKeeperWindow(address _caller) external {
    _assumeFuzzable(_caller);
    uint256 _requestedAt = block.timestamp;
    _requestDeposit(users.alice, 2, 10e18);

    // age the entry to exactly the configured window: requestedAt == block.timestamp - 1 days
    vm.warp(_requestedAt + 1 days);

    // it should process the entry whose age equals the window
    vm.prank(_caller);
    _relay.processOverduePending(_ids(1));
    // genesis price per share is 1 (seed 100e18 backing 100e18 shares), so 10e18 of weight mints
    // 10e18 shares
    assertEq(_principalToken.balanceOf(users.alice), 10e18);
    _assertPairInvariant();
  }

  /// @notice The deposit-request guards, in the order the register runs them.
  function test_WhenRequestingAnInvalidDeposit() external {
    // it should revert when the caller is not authorized on the source sAERO
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorized, (users.alice, 2)), abi.encode(false));
    vm.prank(users.alice);
    vm.expectRevert(IRelay.NotAuthorized.selector);
    _relay.requestDeposit(2, 5e18, users.alice);

    // it should revert on a zero share recipient
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.isAuthorized, (users.alice, 2)), abi.encode(true));
    vm.prank(users.alice);
    vm.expectRevert(IRelay.ZeroAddress.selector);
    _relay.requestDeposit(2, 5e18, address(0));

    // it should ban the satellite clones and the relay itself as share recipients
    vm.prank(users.alice);
    vm.expectRevert(IRelayToken.InvalidRecipient.selector);
    _relay.requestDeposit(2, 5e18, address(_principalToken));
    vm.prank(users.alice);
    vm.expectRevert(IRelayToken.InvalidRecipient.selector);
    _relay.requestDeposit(2, 5e18, address(_yieldToken));
    vm.prank(users.alice);
    vm.expectRevert(IRelayToken.InvalidRecipient.selector);
    _relay.requestDeposit(2, 5e18, address(_relay));

    // it should revert when the net amount lands under the deposit floor
    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 0.5e18);
    _mockRelayStakedDelta(0.5e18);
    vm.prank(users.alice);
    vm.expectRevert(IRelay.BelowMinimumDeposit.selector);
    _relay.requestDeposit(2, 0.5e18);
  }

  /// @notice A deposit whose net amount would mint zero shares is rejected at request time, so it
  ///         can never wedge the FIFO or vanish into the backing silently.
  function test_WhenTheSharesWouldFloorToZero() external {
    // inflate the ratio: compound a huge amount so backing >> supply
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(1e38));
    vm.mockCall(_votingEscrow, abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, 1e38)), abi.encode());
    vm.prank(_compounder);
    _relay.compound(1e38);

    // it should revert with ZeroShares at the inflated ratio
    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 1e18);
    _mockRelayStakedDelta(1e18);
    vm.prank(users.alice);
    vm.expectRevert(IRelay.ZeroShares.selector);
    _relay.requestDeposit(2, 1e18);
  }

  /// @notice The ZeroShares guard rejects only what would truly floor to zero: a request that
  ///         prices to exactly one share is still admitted.
  function test_WhenTheDepositPricesToExactlyOneShare() external {
    // A supply of 100 wei against the 100e18 seed backing puts the request on the exact boundary:
    // 1e18 of net weight buys 1e18 * 100 / 100e18 == 1 share, the smallest amount that still mints.
    vm.mockCall(address(_principalToken), abi.encodeCall(IERC20.totalSupply, ()), abi.encode(100));

    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 1e18);
    _mockRelayStakedDelta(1e18);

    // it should admit the request sitting on the boundary
    vm.expectEmit(address(_relay));
    emit IRelay.DepositRequested(2, users.alice, 1e18, 1);
    vm.prank(users.alice);
    _relay.requestDeposit(2, 1e18);
    assertEq(_relay.pendingDepositWeight(), 1e18);
  }

  /// @notice A relay whose supply drained to zero is exempt from the pricing guard: the next drain
  ///         bootstraps the ratio 1:1, so no backing left behind can lock admission out.
  function test_WhenTheSupplyIsZero() external {
    // supply zero while the backing still holds the 100e18 seed
    vm.mockCall(address(_principalToken), abi.encodeCall(IERC20.totalSupply, ()), abi.encode(0));

    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 1e18);
    _mockRelayStakedDelta(1e18);

    // it should admit the request whatever the backing holds
    vm.expectEmit(address(_relay));
    emit IRelay.DepositRequested(2, users.alice, 1e18, 1);
    vm.prank(users.alice);
    _relay.requestDeposit(2, 1e18);
    assertEq(_relay.pendingDepositWeight(), 1e18);
  }

  /// @notice The deposit queue has no capacity: a request can never be blocked by other requests,
  ///         so the fill-the-queue denial of service has nothing to fill. The queue stores no link
  ///         to the next entry, so the ids must stay dense for the walk to reach every entry.
  function test_WhenRequestsKeepArriving() external {
    // it should admit every request, unbounded, with ids in sequence
    for (uint256 _i; _i < 25; ++_i) {
      _requestDeposit(users.alice, 2, 2e18);
    }
    assertEq(_relay.pendingDepositWeight(), 50e18);
    (uint40 _head, uint40 _tail, uint40 _count) = _relay.depositList();
    assertEq(_head, 1);
    assertEq(_tail, 25);
    assertEq(_count, 25);
    // every id up to the tail carries an entry, so no id in the range is skipped
    for (uint256 _i = 1; _i <= 25; ++_i) {
      (, uint48 _requestedAt,, uint128 _amount) = _relay.pendingDeposits(_i);
      assertEq(_requestedAt, uint48(block.timestamp));
      assertEq(_amount, 2e18);
    }
  }

  /// @notice The module takes a protocol fee out of the weight it moves, so what the Relay receives is
  ///         smaller than what the depositor asked for. The Relay never computes that fee: it measures the
  ///         net from its own staked balance across the move, and everything downstream, the queue entry,
  ///         the counters and the eventual mint, is priced on the net.
  function test_WhenTheModuleChargesADepositFee() external {
    uint256 _gross = 10e18;
    uint256 _net = 9e18;

    _requestDepositWithFee(users.alice, 2, _gross, _net);

    // it should queue the net weight the relay actually received
    assertEq(_relay.pendingDepositWeight(), _net);
    (,,, uint128 _queued) = _relay.pendingDeposits(1);
    assertEq(_queued, _net);

    // it should mint against the net rather than the request
    // Genesis is 1:1 (the seed mints against itself), so the net buys exactly its own weight in shares.
    _processPending(1);
    assertEq(_principalToken.balanceOf(users.alice), _net);
    assertEq(_relay.totalBacking(), _SEED + _net);
    assertEq(_relay.pendingDepositWeight(), 0);
    _assertPairInvariant();
  }

  /// @notice The floor is checked against the net, not the request, which is the only way it can be
  ///         checked: the fee is the module's to resolve and the Relay learns it after the weight moved.
  ///         So a request comfortably above the floor still fails when the fee drags it under.
  function test_WhenTheFeeDragsTheNetBelowTheFloor() external {
    // The configured floor is 1e18. The request clears it; what lands does not.
    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 2e18);
    _mockRelayStakedDelta(0.5e18);

    // it should revert with BelowMinimumDeposit
    vm.prank(users.alice);
    vm.expectRevert(IRelay.BelowMinimumDeposit.selector);
    _relay.requestDeposit(2, 2e18);
  }

  /// @notice The degenerate end of the same rule: a fee that keeps everything leaves a zero net, and the
  ///         floor rejects it before it can reach the queue as an entry that would mint nothing.
  function test_WhenTheFeeTakesTheWholeRequest() external {
    _mockDepositAuthorization(users.alice, 2);
    _mockDepositIntoNFT(2, 5e18);
    _mockRelayStakedDelta(0);

    // it should revert with BelowMinimumDeposit
    vm.prank(users.alice);
    vm.expectRevert(IRelay.BelowMinimumDeposit.selector);
    _relay.requestDeposit(2, 5e18);
  }

  /// @notice The exit-registration guards: the size floor and the free-pair requirement. The
  ///         destination is not among them, and neither is a queue size: the queue has no capacity,
  ///         so a backlog of exits can never refuse a new one.
  function test_WhenRegisteringAnInvalidExit() external {
    // it should revert under the withdrawal floor
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.BelowMinimumWithdrawal.selector);
    _relay.registerOnWithdrawQueue(0.5e18, _MINT_SENTINEL);

    // it should revert when the callers free pair cannot cover the escrow
    vm.prank(users.alice);
    vm.expectRevert(IRelay.InsufficientFreeShares.selector);
    _relay.registerOnWithdrawQueue(5e18, _MINT_SENTINEL);

    // it should admit an exit behind a long backlog, since the queue has no capacity
    vm.startPrank(_bootstrapOwner);
    for (uint256 _i; _i < 10; ++_i) {
      _relay.registerOnWithdrawQueue(1e18, _MINT_SENTINEL);
    }
    _relay.registerOnWithdrawQueue(1e18, _MINT_SENTINEL);
    vm.stopPrank();
    (uint40 _head, uint40 _tail, uint40 _count) = _relay.withdrawQueue();
    assertEq(_head, 1);
    assertEq(_tail, 11);
    assertEq(_count, 11);
  }

  /// @notice The two floors are denominated differently: `minDeposit` in weight, `minWithdrawal` in
  ///         shares. A repricing between request and admission can therefore mint a valid deposit
  ///         fewer shares than the exit floor asks for, so the floor drops to the whole free position
  ///         when that is smaller. Without this, the position could never leave.
  function test_WhenTheWholeFreePositionSitsUnderTheWithdrawalFloor() external {
    // Double the price per share: the backing grows, no share mints.
    _compound(100e18);
    // A valid 1e18 deposit at a price of two mints half the floor's worth of shares.
    _admitDeposit(users.alice, 2, 1e18);
    assertEq(_principalToken.balanceOf(users.alice), 0.5e18, 'the admission did not reprice the mint');

    // it should still refuse a partial exit under the floor
    vm.prank(users.alice);
    vm.expectRevert(IRelay.BelowMinimumWithdrawal.selector);
    _relay.registerOnWithdrawQueue(0.25e18, _MINT_SENTINEL);

    // it should still refuse a zero exit
    vm.prank(users.alice);
    vm.expectRevert(IRelay.BelowMinimumWithdrawal.selector);
    _relay.registerOnWithdrawQueue(0, _MINT_SENTINEL);

    // it should let the holder exit the entire free position
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(0.5e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.alice), 0.5e18, 'the full exit did not escrow');

    // it should hold the floor for a holder whose free position covers it
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.BelowMinimumWithdrawal.selector);
    _relay.registerOnWithdrawQueue(0.5e18, _MINT_SENTINEL);
  }

  /// @notice The strongest case: a Relay that closes before admission mints the principal alone, so
  ///         the holder cannot top up with a second deposit, cannot transfer the principal and holds
  ///         no yield side for a kick to eject. The exit is the only way out and it must open.
  function test_WhenAClosedRelayMintsAPrincipalUnderTheFloor() external {
    _compound(100e18);
    _requestDeposit(users.alice, 2, 1e18);
    vm.prank(_keeper);
    _relay.close();
    // The keeper drains directly: `_processPending` calls `allocate`, which a closed Relay rejects.
    vm.prank(_keeper);
    _relay.processPending(1);
    assertEq(_principalToken.balanceOf(users.alice), 0.5e18, 'the closed admission did not mint principal');
    assertEq(_yieldToken.balanceOf(users.alice), 0, 'the closed admission minted a yield side');

    // it should let the holder exit the principal in full
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(0.5e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(users.alice), 0.5e18, 'the principal-only exit did not escrow');
  }

  /// @notice The destination is taken as given, so an sAERO the caller does not own registers fine.
  /// @dev No `ownerOf` mock is armed for id 5, and the mocked escrow returns no data for an unmocked
  ///      call, so a registration that reads ownership would revert here. Passing is the proof that
  ///      it does not read it.
  function test_WhenTheNamedDestinationBelongsToSomeoneElse() external {
    // it should register the exit at the head slot
    vm.expectEmit(address(_relay));
    emit IRelay.WithdrawRegistered(_bootstrapOwner, 5e18, 5, 1);
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(5e18, 5);

    // it should escrow the registered shares
    assertEq(_relay.escrowedShares(_bootstrapOwner), 5e18);
    assertEq(_relay.pendingWithdrawalShares(), 5e18);

    // it should return the named destination from the withdrawals getter
    (,,, uint256 _destination) = _relay.withdrawals(1);
    assertEq(_destination, 5);
  }

  /// @notice The one banned destination: the Relay's own sAERO. Its source and destination legs
  ///         would net out at the drain, so the exit could never settle.
  function test_WhenTheNamedDestinationIsTheRelaySAERO(address _caller, uint256 _shares) external {
    _assumeFuzzable(_caller);
    _shares = bound(_shares, 1e18, type(uint128).max);

    // it should revert with InvalidDestination
    vm.prank(_caller);
    vm.expectRevert(IRelay.InvalidDestination.selector);
    _relay.registerOnWithdrawQueue(_shares, _RELAY_TOKEN_ID);
  }

  /// @notice The entry stores the destination in 72 bits, so a wider non-sentinel destination is
  ///         refused outright: truncating it would route the weight onto an unrelated sAERO.
  function test_WhenTheNamedDestinationDoesNotFitTheStoredDestinationField(
    address _caller,
    uint256 _shares,
    uint256 _destination
  ) external {
    _assumeFuzzable(_caller);
    _shares = bound(_shares, 1e18, type(uint128).max);
    _destination = bound(_destination, uint256(type(uint72).max) + 1, type(uint256).max - 1);

    // it should revert with InvalidDestination
    vm.prank(_caller);
    vm.expectRevert(IRelay.InvalidDestination.selector);
    _relay.registerOnWithdrawQueue(_shares, _destination);
  }

  /// @notice The sentinel lives only at the API boundary: the entry stores a flag and a zero
  ///         destination, and the getter rebuilds the published value.
  function test_WhenRegisteringAnExitWithTheMintSentinel() external {
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(5e18, _MINT_SENTINEL);

    // it should store the entry fields under the issued id
    (address _holder, uint48 _registeredAt, uint256 _shares, uint256 _destination) = _relay.withdrawals(1);
    assertEq(_holder, _bootstrapOwner);
    assertEq(_registeredAt, uint48(block.timestamp));
    assertEq(_shares, 5e18);

    // it should rebuild the sentinel on the withdrawals getter
    assertEq(_destination, _MINT_SENTINEL);
  }

  /// @notice Escrow accumulates across exits of one holder, and the free-pair floor prices the
  ///         running total, so a holder can never queue more than the pair they hold.
  function test_WhenRegisteringSuccessiveExits() external {
    // the bootstrap owner holds the 100e18 seed pair
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(1e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(_bootstrapOwner), 1e18);

    // it should add the second exit on top of the first
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(2e18, _MINT_SENTINEL);
    // 1e18 escrowed first plus 2e18 escrowed second is 3e18
    assertEq(_relay.escrowedShares(_bootstrapOwner), 3e18);
    assertEq(_relay.pendingWithdrawalShares(), 3e18);

    // it should revert once the running escrow no longer fits the free pair
    // 3e18 is already escrowed out of the 100e18 pair, so only 97e18 is still free
    vm.prank(_bootstrapOwner);
    vm.expectRevert(IRelay.InsufficientFreeShares.selector);
    _relay.registerOnWithdrawQueue(98e18, _MINT_SENTINEL);

    // it should measure the floor against the free remainder, not the whole balance
    // queuing 96.5e18 more leaves 0.5e18 free out of the 100e18 pair, under the 1e18 floor
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(96.5e18, _MINT_SENTINEL);
    vm.prank(_bootstrapOwner);
    _relay.registerOnWithdrawQueue(0.5e18, _MINT_SENTINEL);
    assertEq(_relay.escrowedShares(_bootstrapOwner), 100e18);
  }

  /// @dev Grow the backing with no share mint, which is what moves the price per share. Arms the
  ///      un-accounted TOKEN balance the guard prices against and the escrow's stake growth.
  function _compound(uint256 _amount) internal {
    vm.mockCall(_token, abi.encodeCall(IERC20.balanceOf, (address(_relay))), abi.encode(_amount));
    // forge-lint: disable-next-line(unsafe-typecast)
    vm.mockCall(
      _votingEscrow,
      abi.encodeCall(IVotingEscrow.increaseStakeAmount, (_RELAY_TOKEN_ID, uint128(_amount))),
      abi.encode()
    );
    vm.prank(_compounder);
    _relay.compound(_amount);
  }
}
