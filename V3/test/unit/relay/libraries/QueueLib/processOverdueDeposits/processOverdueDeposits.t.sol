// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseQueueLib} from 'V3-test/unit/relay/libraries/BaseQueueLib.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';

/// @notice Unit tests for `QueueLib.processOverdueDeposits`, the permissionless by-id path,
///         driven through the storage-owning harness.
/// @dev The guards revert (never skip) since the caller controls the ids array. Callers are
///      fuzzed even though the library reads no sender.
contract UnitQueueLibProcessOverdueDeposits is BaseQueueLib {
  /// @dev Keeper window every test prices ages against; bounded well under the warped timestamp.
  uint256 internal constant _KEEPER_WINDOW = 1 days;

  /// @dev Timestamp every test runs at, far past the window and comfortably inside uint48 so the
  ///      re-stamps around the boundary stay representable.
  uint256 internal constant _NOW = 1e12;

  function setUp() public override {
    super.setUp();
    vm.warp(_NOW);
  }

  /// @notice An empty ids array is a caller error, not a no-op.
  function test_WhenTheIdsArrayIsEmpty(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _seedFuzzedDepositQueue(_seed);

    // it should revert with NoPendingDeposits
    vm.expectRevert(IRelay.NoPendingDeposits.selector);
    vm.prank(_caller);
    _queue.processOverdueDeposits(new uint256[](0), _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));
  }

  /// @notice Id zero is the null sentinel, never an entry.
  function test_WhenAnIdIsZero(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _seedFuzzedDepositQueue(_seed);
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = 0;

    // it should revert with DepositNotFound
    vm.expectRevert(IRelay.DepositNotFound.selector);
    vm.prank(_caller);
    _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));
  }

  /// @notice Ids are issued in sequence and never reused, so anything past the last issued id
  ///         does not exist.
  function test_WhenAnIdWasNeverIssued(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _unissuedId,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _seedFuzzedDepositQueue(_seed);
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = bound(_unissuedId, _listCount() + 1, type(uint256).max);

    // it should revert with DepositNotFound
    vm.expectRevert(IRelay.DepositNotFound.selector);
    vm.prank(_caller);
    _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));
  }

  /// @notice A consumed entry cannot process twice; the deletion marker also protects the
  ///         pending-weight counter against a double debit.
  function test_WhenANamedEntryIsAlreadyProcessed(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _seedFuzzedDepositQueue(_seed);
    // Processing deletes the entry, so consumption is seeded as the zeroed entry itself.
    _queue.setPendingDeposit(1, IRelay.PendingDeposit({recipient: address(0), requestedAt: 0, tokenId: 0, amount: 0}));
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = 1;

    // it should revert with DepositAlreadyProcessed
    vm.expectRevert(IRelay.DepositAlreadyProcessed.selector);
    vm.prank(_caller);
    _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));
  }

  /// @notice Before the window elapses the entry is still the keeper's alone.
  function test_WhenANamedEntryIsStillWithinTheKeeperWindow(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _requestedAt,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _seedFuzzedDepositQueue(_seed);
    // Re-stamp the head strictly inside the window: age < keeperWindow.
    IRelay.PendingDeposit memory _entry = _depositById(1);
    _entry.requestedAt = uint48(bound(_requestedAt, _NOW - _KEEPER_WINDOW + 1, _NOW));
    _queue.setPendingDeposit(1, _entry);
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = 1;

    // it should revert with KeeperWindowNotElapsed
    vm.expectRevert(IRelay.KeeperWindowNotElapsed.selector);
    vm.prank(_caller);
    _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));
  }

  /// @dev Seeds one to three fuzzed entries, then clamps every request time at least a full window
  ///      behind the warped timestamp, so the whole list is overdue.
  modifier givenEveryNamedEntryIsOverdue(DepositQueueSeed memory _seed) {
    _seedFuzzedDepositQueue(_seed);
    for (uint256 _i; _i < _listCount(); ++_i) {
      IRelay.PendingDeposit memory _entry = _depositById(_i + 1);
      _entry.requestedAt = uint48(bound(_entry.requestedAt, 1, _NOW - _KEEPER_WINDOW));
      _queue.setPendingDeposit(_i + 1, _entry);
    }
    _;
  }

  /// @notice The by-id trunk: ids in request order run the walk's exact pricing, bookkeeping and
  ///         events, and the single head steps add up to the same full advance.
  function test_GivenEveryNamedEntryIsOverdue(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenEveryNamedEntryIsOverdue(_seed) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _listCount();
    uint256 _totalAmount = _totalSeededAmount();
    _totalBacking = bound(_totalBacking, 1, type(uint128).max - _totalAmount);
    _totalSupply = bound(_totalSupply, 1, _totalBacking);

    uint256[] memory _ids = new uint256[](_seededCount);
    {
      uint256 _runningSupply = _totalSupply;
      uint256 _runningBacking = _totalBacking;
      for (uint256 _i; _i < _seededCount; ++_i) {
        _ids[_i] = _i + 1;
        IRelay.PendingDeposit memory _entry = _depositById(_i + 1);
        uint256 _shares = (uint256(_entry.amount) * _runningSupply) / _runningBacking;
        // it should emit a DepositProcessed event per entry
        _expectDepositProcessed(_entry.tokenId, _entry.recipient, _entry.amount, _shares);
        // it should credit the shares to the recipient stored at request
        // it should price each entry at amount times supply over backing
        _expectPairMint(_entry.recipient, _shares);
        _runningSupply += _shares;
        _runningBacking += _entry.amount;
      }
    }

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));

    assertEq(_result.count, _seededCount);
    // it should delete each settled entry
    for (uint256 _i; _i < _seededCount; ++_i) {
      assertTrue(_isConsumed(_i + 1));
    }
    // it should decrease the outstanding count for each settled entry
    assertEq(_listCount(), 0);
    // it should accumulate the entry amounts into the backing
    assertEq(_result.totalBacking, _totalBacking + _totalAmount);
    // it should set the head to zero when the ids process every entry in order
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, 0);
  }

  /// @notice A non-head entry processes alone: the head and each entry before the named id stay
  ///         as they were, and wait for the keeper or their own turn.
  function test_WhenAProcessedIdIsNotTheHead(
    address _caller,
    DepositQueueSeed memory _seed,
    uint48 _lateRequestedAt,
    uint256 _lateAmount,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenEveryNamedEntryIsOverdue(_seed) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _listCount();
    uint256 _totalAmount = _totalSeededAmount();
    _lateAmount = bound(_lateAmount, 1, uint256(type(uint128).max) / 4);
    // Append the named entry behind the seeded ones, overdue like everything else here.
    _appendDeposit(
      IRelay.PendingDeposit({
        recipient: _recipientAt(_seededCount),
        requestedAt: uint48(bound(_lateRequestedAt, 1, _NOW - _KEEPER_WINDOW)),
        tokenId: uint128(_seededCount + 1),
        amount: uint128(_lateAmount)
      })
    );
    _totalBacking = bound(_totalBacking, 1, type(uint128).max - _totalAmount - _lateAmount);
    _totalSupply = bound(_totalSupply, 1, _totalBacking);
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = _seededCount + 1;

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));

    // it should not change the head or the earlier entries
    assertEq(_result.count, 1);
    assertEq(_listCount(), _seededCount);
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, 1);
    for (uint256 _i; _i < _seededCount; ++_i) {
      assertFalse(_isConsumed(_i + 1));
    }
    assertTrue(_isConsumed(_seededCount + 1));
  }

  /// @notice Order independence of the pricing, on the known example: processing the hundred
  ///         before the fifty at price two mints fifty then twenty five — the same pair of share
  ///         amounts the in-order walk mints, because every entry prices at the running fixed
  ///         point. Hand-computed: 100*100/200 = 50, then 50*150/300 = 25.
  function test_WhenTheIdsArriveOutOfRequestOrder(
    address _caller,
    DepositQueueSeed memory _seed
  ) external givenEveryNamedEntryIsOverdue(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit[] memory _entries = new IRelay.PendingDeposit[](2);
    _entries[0] = IRelay.PendingDeposit({recipient: _recipientAt(1), requestedAt: 100, tokenId: 1, amount: 50});
    _entries[1] = IRelay.PendingDeposit({recipient: _recipientAt(2), requestedAt: 100, tokenId: 2, amount: 100});
    _seedDepositQueue(_entries);
    uint256[] memory _ids = new uint256[](2);
    _ids[0] = 2;
    _ids[1] = 1;

    // it should price the entries in the order given
    _expectPairMint(_recipientAt(2), 50);
    _expectPairMint(_recipientAt(1), 25);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, 200, 100));

    assertEq(_result.count, 2);
    assertEq(_result.totalBacking, 350);
    assertEq(_listCount(), 0);

    // it should clear the head once the drain empties the queue
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, 0);
  }

  /// @notice A reverse drain is what leaves the head stale. Only the id that is the head moves it,
  ///         and that id is processed last, so the head lands on entries the earlier ids deleted.
  ///         An emptied queue has no live entry to point at, so the head goes back to zero and the
  ///         next deposit becomes the head. Otherwise the next walk pays for the deleted ids first.
  function test_WhenAReverseDrainIsFollowedByANewDeposit(
    address _caller,
    DepositQueueSeed memory _seed
  ) external givenEveryNamedEntryIsOverdue(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit[] memory _entries = new IRelay.PendingDeposit[](2);
    _entries[0] = IRelay.PendingDeposit({recipient: _recipientAt(1), requestedAt: 100, tokenId: 1, amount: 50});
    _entries[1] = IRelay.PendingDeposit({recipient: _recipientAt(2), requestedAt: 100, tokenId: 2, amount: 100});
    _seedDepositQueue(_entries);
    uint256[] memory _ids = new uint256[](2);
    _ids[0] = 2;
    _ids[1] = 1;

    vm.prank(_caller);
    _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, 200, 100));

    _appendDeposit(
      IRelay.PendingDeposit({recipient: _recipientAt(3), requestedAt: uint48(_NOW), tokenId: 3, amount: 50})
    );

    // it should point the head at the new entry
    (uint40 _head, uint40 _tail,) = _queue.depositList();
    assertEq(_tail, 3);
    assertEq(_head, 3);

    // it should let the next walk reach it within one entry of budget
    vm.prank(_caller);
    QueueLib.DepositResult memory _walk = _queue.processDeposits(_depositContext(1, 350, 175));
    assertEq(_walk.count, 1);
    assertTrue(_isConsumed(3));
  }

  /// @notice The window is a floor, not a strict threshold: an entry whose age equals it exactly
  ///         is already processable, so the path does not stall one second short.
  function test_WhenANamedEntryAgedExactlyTheKeeperWindow(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenEveryNamedEntryIsOverdue(_seed) {
    _assumeFuzzable(_caller);
    uint256 _totalAmount = _totalSeededAmount();
    _totalBacking = bound(_totalBacking, 1, type(uint128).max - _totalAmount);
    _totalSupply = bound(_totalSupply, 1, _totalBacking);
    // Re-stamp the head exactly one window ago: requestedAt == block.timestamp - keeperWindow.
    IRelay.PendingDeposit memory _entry = _depositById(1);
    _entry.requestedAt = uint48(_NOW - _KEEPER_WINDOW);
    _queue.setPendingDeposit(1, _entry);
    uint256[] memory _ids = new uint256[](1);
    _ids[0] = 1;

    // it should process the entry that sits on the boundary
    _expectPairMint(_entry.recipient, (uint256(_entry.amount) * _totalSupply) / _totalBacking);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processOverdueDeposits(_ids, _depositContext(0, _KEEPER_WINDOW, _totalBacking, _totalSupply));

    assertEq(_result.count, 1);
    assertTrue(_isConsumed(1));
  }
}
