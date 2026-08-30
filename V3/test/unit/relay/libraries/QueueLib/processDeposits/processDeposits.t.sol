// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseQueueLib} from 'V3-test/unit/relay/libraries/BaseQueueLib.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';

/// @notice Unit tests for `QueueLib.processDeposits`, the keeper's ordered walk over the deposit
///         list, driven through the storage-owning harness.
/// @dev Bounds: `totalSupply <= totalBacking` (a price below one is unreachable in production) and
///      `backing + seeded amounts` within uint128 (the staked-TOKEN cap). Callers are fuzzed even
///      though the library reads no sender.
contract UnitQueueLibProcessDeposits is BaseQueueLib {
  /// @notice A walk on an empty list must revert: the outstanding count is the only source of
  ///         emptiness, because a non-zero head can point to a consumed entry.
  function test_WhenTheListIsEmpty(
    address _caller,
    uint40 _issued,
    uint256 _maxEntries,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external {
    _assumeFuzzable(_caller);
    _queue.setDepositList(DenseQueue.Queue({head: 0, tail: _issued, count: 0}));

    // it should revert with NoPendingDeposits
    vm.expectRevert(IRelay.NoPendingDeposits.selector);
    vm.prank(_caller);
    _queue.processDeposits(_depositContext(_maxEntries, _totalBacking, _totalSupply));
  }

  /// @dev Seeds one to three fuzzed entries (consecutive token ids, per-index recipients,
  ///      per-entry amounts and request times — see `_seedFuzzedDepositQueue`).
  modifier givenTheListIsNotEmpty(DepositQueueSeed memory _seed) {
    _seedFuzzedDepositQueue(_seed);
    _;
  }

  /// @notice The core walk: pricing at the simulated ratio, stored-recipient crediting, deletion
  ///         and count bookkeeping, backing accumulation and one event per entry.
  /// @dev The expected shares replay the pricing recurrence; the known-example test below anchors
  ///      the numbers independently.
  function test_GivenTheListIsNotEmpty(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _listCount();
    uint256 _totalAmount = _totalSeededAmount();
    _totalBacking = bound(_totalBacking, 1, type(uint128).max - _totalAmount);
    _totalSupply = bound(_totalSupply, 1, _totalBacking);

    uint256[] memory _expectedShares = new uint256[](_seededCount);
    {
      uint256 _runningSupply = _totalSupply;
      uint256 _runningBacking = _totalBacking;
      for (uint256 _i; _i < _seededCount; ++_i) {
        IRelay.PendingDeposit memory _entry = _depositAt(_i);
        _expectedShares[_i] = (uint256(_entry.amount) * _runningSupply) / _runningBacking;
        // it should emit a DepositProcessed event per entry
        _expectDepositProcessed(_entry.tokenId, _entry.recipient, _entry.amount, _expectedShares[_i]);
        // it should credit the shares to the recipient stored at request
        // it should price each entry at amount times supply over backing
        _expectPairMint(_entry.recipient, _expectedShares[_i]);
        _runningSupply += _expectedShares[_i];
        _runningBacking += _entry.amount;
      }
    }

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processDeposits(_depositContext(type(uint256).max, _totalBacking, _totalSupply));

    // it should report every seeded entry in the result count
    assertEq(_result.count, _seededCount);
    // it should delete each settled entry
    for (uint256 _i; _i < _seededCount; ++_i) {
      assertTrue(_isConsumed(_i + 1));
    }
    // it should decrease the outstanding count for each settled entry
    assertEq(_listCount(), 0);
    // it should accumulate the entry amounts into the backing
    assertEq(_result.totalBacking, _totalBacking + _totalAmount);
    // it should set the head to zero when the walk reaches the end of the list
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, 0);
  }

  /// @notice The walk obeys its visit budget and processes strictly from the head, so the oldest
  ///         entries settle first; the head stays on the first unvisited id. A zero budget is a
  ///         no-op that does not move the head.
  function test_WhenTheBudgetIsBelowTheOutstandingCount(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _maxEntries,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _listCount();
    _maxEntries = bound(_maxEntries, 0, _seededCount - 1);
    _totalBacking = bound(_totalBacking, 1, type(uint128).max - _totalSeededAmount());
    _totalSupply = bound(_totalSupply, 1, _totalBacking);

    // it should process only the budgeted entries in request order and leave the head on the first unvisited id
    for (uint256 _i; _i < _maxEntries; ++_i) {
      vm.expectCall(_principalToken, abi.encodeWithSelector(IRelayToken.mint.selector, _recipientAt(_i)));
    }

    vm.prank(_caller);
    QueueLib.DepositResult memory _result =
      _queue.processDeposits(_depositContext(_maxEntries, _totalBacking, _totalSupply));

    assertEq(_result.count, _maxEntries);
    assertEq(_listCount(), _seededCount - _maxEntries);
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, _maxEntries + 1);
  }

  /// @notice The walk skips an entry that was already consumed by id, and the skip still costs one
  ///         unit of budget: with a budget of two, one live head plus one consumed entry use the
  ///         whole call before the walk reaches the live tail.
  function test_WhenConsumedEntriesSitBetweenLiveOnes(
    address _caller,
    DepositQueueSeed memory _seed
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit[] memory _entries = new IRelay.PendingDeposit[](3);
    for (uint256 _i; _i < 3; ++_i) {
      _entries[_i] =
        IRelay.PendingDeposit({recipient: _recipientAt(_i), requestedAt: 100, tokenId: uint128(_i + 1), amount: 10e18});
    }
    _seedDepositQueue(_entries);

    // the middle entry was consumed by id: delete it and remove it from the count
    _queue.setPendingDeposit(2, IRelay.PendingDeposit({recipient: address(0), requestedAt: 0, tokenId: 0, amount: 0}));
    _queue.setDepositList(DenseQueue.Queue({head: 1, tail: 3, count: 2}));

    // it should process only the live entries
    vm.expectCall(_principalToken, abi.encodeWithSelector(IRelayToken.mint.selector, _recipientAt(0)), 1);
    vm.expectCall(_principalToken, abi.encodeWithSelector(IRelayToken.mint.selector, _recipientAt(1)), 0);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result = _queue.processDeposits(_depositContext(2, 100e18, 100e18));

    // it should spend budget on each consumed entry it visits
    // the budget of two covered the live head and the consumed entry, so the live tail stays queued
    assertEq(_result.count, 1);
    assertEq(_listCount(), 1);
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, 3);
  }

  /// @notice The defensive bootstrap path: with no shares outstanding the head entry prices one to
  ///         one, whatever the backing (both-zero included). Only the first processed entry sits
  ///         on this branch (its mint makes the simulated supply non-zero), so the batch is capped
  ///         at one entry.
  function test_WhenTheSupplyIsZero(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit memory _entry = _headDeposit();
    _totalBacking = bound(_totalBacking, 0, type(uint128).max);

    // it should price the entry one to one
    _expectPairMint(_entry.recipient, _entry.amount);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result = _queue.processDeposits(_depositContext(1, _totalBacking, 0));

    assertEq(_result.count, 1);
    assertEq(_result.totalBacking, _totalBacking + _entry.amount);
  }

  /// @notice The other bootstrap arm: shares outstanding against zero backing also price one to
  ///         one instead of dividing by zero.
  function test_WhenTheBackingIsZeroAndTheSupplyIsNot(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalSupply
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit memory _entry = _headDeposit();
    _totalSupply = bound(_totalSupply, 1, type(uint128).max);

    // it should price the entry one to one
    _expectPairMint(_entry.recipient, _entry.amount);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result = _queue.processDeposits(_depositContext(1, 0, _totalSupply));

    assertEq(_result.count, 1);
    assertEq(_result.totalBacking, _entry.amount);
  }

  /// @notice Known example proving the intra-batch ratio simulation with hand-computed values: at
  ///         price two (a supply of one hundred backed by two hundred), staking fifty mints
  ///         twenty five shares; the second entry then prices at the post-mint ratio (one hundred
  ///         twenty five over two hundred fifty) and staking one hundred mints fifty shares. The
  ///         seeded fuzz list is overwritten with this two-entry example.
  function test_WhenTheRatioCarriesAcrossABatch(
    address _caller,
    DepositQueueSeed memory _seed
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    IRelay.PendingDeposit[] memory _entries = new IRelay.PendingDeposit[](2);
    _entries[0] = IRelay.PendingDeposit({recipient: _recipientAt(1), requestedAt: 100, tokenId: 1, amount: 50});
    _entries[1] = IRelay.PendingDeposit({recipient: _recipientAt(2), requestedAt: 100, tokenId: 2, amount: 100});
    _seedDepositQueue(_entries);

    // it should price a known two entry example at the simulated ratios
    _expectPairMint(_recipientAt(1), 25);
    _expectPairMint(_recipientAt(2), 50);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result = _queue.processDeposits(_depositContext(2, 200, 100));

    assertEq(_result.count, 2);
    assertEq(_result.totalBacking, 350);
  }

  /// @notice Characterization of a spec divergence: the pooling TD calls for a `MintsZeroShares`
  ///         guard, but the implementation floors silently — a small deposit on an appreciated
  ///         relay mints zero shares while its full amount still enters the backing, donating the
  ///         weight to existing holders.
  function test_WhenThePricingFloorsToZeroShares(
    address _caller,
    DepositQueueSeed memory _seed,
    uint256 _totalBacking,
    uint256 _totalSupply
  ) external givenTheListIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    // Force `amount * supply < backing` so the division floors to zero; both factors narrow so the
    // product stays below the reachable uint128 backing ceiling.
    IRelay.PendingDeposit memory _entry = _reboundHeadDepositAmount(1, type(uint32).max);
    _totalSupply = bound(_totalSupply, 1, type(uint32).max);
    _totalBacking = bound(_totalBacking, uint256(_entry.amount) * _totalSupply + 1, type(uint128).max);

    // it should mint zero shares
    _expectPairMint(_entry.recipient, 0);

    vm.prank(_caller);
    QueueLib.DepositResult memory _result = _queue.processDeposits(_depositContext(1, _totalBacking, _totalSupply));

    assertEq(_result.count, 1);
    // it should still admit the amount into the backing
    assertEq(_result.totalBacking, _totalBacking + _entry.amount);
  }
}
