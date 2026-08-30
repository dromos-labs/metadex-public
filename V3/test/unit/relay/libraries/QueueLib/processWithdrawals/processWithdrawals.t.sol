// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseQueueLib} from 'V3-test/unit/relay/libraries/BaseQueueLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';
import {QueueLib} from 'V3/relay/libraries/QueueLib.sol';

/// @notice Unit tests for `QueueLib.processWithdrawals`, driven through the storage-owning harness with a mocked VotingEscrow and VPM.
contract UnitQueueLibProcessWithdrawals is BaseQueueLib {
  /// @dev Id the VPM returns for a freshly minted sAERO on the fallback path. Deliberately above the
  ///      uint128 destination fuzz range so it can never collide with a named destination's mock.
  uint256 internal constant _FRESH_MINT_ID = uint256(type(uint128).max) + 1;

  /// @dev Supply bounded by the affordable trunk, recorded for the test bodies.
  uint256 internal _ctxSupply;
  /// @dev Backing bounded by the affordable trunk, recorded for the test bodies.
  uint256 internal _ctxBacking;
  /// @dev Source unlock pinned by `whenTheSourceStakeIsNotPermanent`, read back by its tests.
  uint48 internal _seededSourceEnd;

  /// @notice An empty queue is a no-op, not a revert.
  function test_WhenTheQueueIsEmpty(
    address _caller,
    uint256 _head,
    uint256 _maxEntries,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _freeWeight
  ) external {
    _assumeFuzzable(_caller);
    _head = bound(_head, 0, type(uint32).max);
    _queue.setWithdrawQueue(DenseQueue.Queue({head: uint40(_head), tail: uint40(_head), count: 0}));
    _totalBacking = bound(_totalBacking, 0, type(uint128).max);
    _freeWeight = bound(_freeWeight, 0, _totalBacking);

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(_maxEntries, _totalSupply, _totalBacking, _freeWeight, 0)
    );

    // it should settle nothing
    assertEq(_result.count, 0);
    // it should pass the counters through
    assertEq(_result.totalBacking, _totalBacking);
    assertEq(_result.pendingWithdrawalShares, 0);
  }

  /// @dev Seeds one to three fuzzed exits (see `_seedFuzzedWithdrawQueue`); affordability and
  ///      destination shapes are derived per branch.
  modifier givenTheQueueIsNotEmpty(WithdrawQueueSeed memory _seed) {
    _seedFuzzedWithdrawQueue(_seed);
    _;
  }

  /// @notice When the free chain0 weight cannot cover even the head exit, the drain is a no-op.
  function test_WhenTheIdleWeightCannotCoverTheHeadExit(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _freeWeight
  ) external givenTheQueueIsNotEmpty(_seed) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _queueCount();
    uint256 _queuedShares = _totalSeededWithdrawShares();
    uint256 _escrowBefore = _queue.escrowedShares(_holderAt(0));
    _totalSupply = bound(_totalSupply, _queuedShares, type(uint128).max);
    _totalBacking = bound(_totalBacking, _totalSupply, type(uint128).max);
    _freeWeight = bound(_freeWeight, 0, _withdrawAt(0).shares - 1);

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(_MAX_DRAIN_ENTRIES, _totalSupply, _totalBacking, _freeWeight, _queuedShares)
    );

    // it should settle nothing
    assertEq(_result.count, 0);
    assertEq(_result.totalBacking, _totalBacking);
    assertEq(_result.pendingWithdrawalShares, _queuedShares);
    // it should leave the queue untouched
    assertEq(_queueCount(), _seededCount);
    assertEq(_queue.escrowedShares(_holderAt(0)), _escrowBefore);
  }

  /// @dev Bounds the reachable domain `sum of queued shares <= totalSupply <= totalBacking`: escrowed shares
  ///      stay in the supply until this drain burns them; genesis price is one and compounds only appreciate.
  modifier givenTheQueuedExitsAreAffordable(uint256 _totalSupply, uint256 _totalBacking) {
    _ctxSupply = bound(_totalSupply, _totalSeededWithdrawShares(), type(uint128).max);
    _ctxBacking = bound(_totalBacking, _ctxSupply, type(uint128).max);
    _;
  }

  /// @notice The core drain path: post-burn-ratio pricing, counter debits, one event per exit, the
  ///         escrow release and the pair burn per settled exit.
  function test_GivenTheQueuedExitsAreAffordable(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _queueCount();
    uint256 _queuedShares = _totalSeededWithdrawShares();

    uint256 _feeBps = bound(_seed.feeBps, 0, 10_000);
    uint256[] memory _expectedAmounts = new uint256[](_seededCount);
    uint256[] memory _escrowsBefore = new uint256[](_seededCount);
    uint256[] memory _sharesAt = new uint256[](_seededCount);
    {
      uint256 _runningSupply = _ctxSupply;
      uint256 _runningBacking = _ctxBacking;
      for (uint256 _i; _i < _seededCount; ++_i) {
        IRelay.WithdrawEntry memory _entry = _withdrawAt(_i);
        _escrowsBefore[_i] = _queue.escrowedShares(_entry.holder);
        _sharesAt[_i] = _entry.shares;
        _expectedAmounts[_i] = (_entry.shares * _runningBacking) / _runningSupply;
        _mockWithdrawToNFT(_MINT_SENTINEL, _expectedAmounts[_i], _entry.holder, _i);
        // The VPM fee shaves the gross weight down to the net the fresh sAERO actually receives.
        uint256 _net = _expectedAmounts[_i] - (_expectedAmounts[_i] * _feeBps) / 10_000;
        _mockSettledStake(_i, _net);
        // it should emit a WithdrawProcessed event per exit
        _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _i);
        // it should pair burn each settled exit's shares on the holder
        _expectPairBurn(_entry.holder, _entry.shares);
        _runningSupply -= _entry.shares;
        _runningBacking -= _expectedAmounts[_i];
      }
    }

    (uint40 _headBefore,,) = _queue.withdrawQueue();

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(type(uint256).max, _ctxSupply, _ctxBacking, _ctxBacking, _queuedShares)
    );

    // it should price each exit at shares times backing over supply
    assertEq(_result.count, _seededCount);
    uint256 _settledWeight;
    for (uint256 _i; _i < _seededCount; ++_i) {
      _settledWeight += _expectedAmounts[_i];
      // it should release exactly the entry's escrow, leaving any surplus banked
      assertEq(_queue.escrowedShares(_holderAt(_i)), _escrowsBefore[_i] - _sharesAt[_i]);
      // it should delete each settled entry
      (address _storedHolder,,,,) = _queue.withdrawals(uint256(_headBefore) + _i);
      assertEq(_storedHolder, address(0));
    }
    // it should debit the backing and the pending shares
    assertEq(_result.totalBacking, _ctxBacking - _settledWeight);
    assertEq(_result.pendingWithdrawalShares, 0);
    assertEq(_queueCount(), 0);
  }

  /// @notice The batch clamps to `maxEntries` and settles strictly from the head (zero folds in as a no-op).
  function test_WhenMaxEntriesIsBelowTheQueueSize(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _maxEntries
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _queueCount();
    uint256 _queuedShares = _totalSeededWithdrawShares();
    _maxEntries = bound(_maxEntries, 0, _seededCount - 1);
    {
      uint256 _runningSupply = _ctxSupply;
      uint256 _runningBacking = _ctxBacking;
      for (uint256 _i; _i < _maxEntries; ++_i) {
        uint256 _amount = (_withdrawAt(_i).shares * _runningBacking) / _runningSupply;
        _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _holderAt(_i), _i);
        _mockSettledStake(_i, _amount);
        // it should pair burn the head holders in FIFO order
        _expectPairBurn(_holderAt(_i), _withdrawAt(_i).shares);
        _runningSupply -= _withdrawAt(_i).shares;
        _runningBacking -= _amount;
      }
    }

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(_maxEntries, _ctxSupply, _ctxBacking, _ctxBacking, _queuedShares)
    );

    // it should settle only max entries in FIFO order
    assertEq(_result.count, _maxEntries);
    assertEq(_queueCount(), _seededCount - _maxEntries);
  }

  /// @notice Once the idle weight is exhausted, the first unaffordable exit ends the batch and stays queued.
  function test_WhenALaterExitIsUnaffordable(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _queueCount();
    uint256 _queuedShares = _totalSeededWithdrawShares();
    // The appended exit is priced (though never settled), so the simulated supply must outlast the
    // seeded batch by at least one to keep that pricing division defined.
    _ctxSupply = bound(_ctxSupply, _queuedShares + 1, type(uint128).max);
    _ctxBacking = bound(_ctxBacking, _ctxSupply, type(uint128).max);
    {
      // Append one more exit behind the seeded ones; any positive price makes it unaffordable
      // against a free-weight reading sized exactly for the seeded batch.
      (uint40 _queueHead, uint40 _queueTail, uint40 _queueCountBefore) = _queue.withdrawQueue();
      _queue.setWithdrawQueue(DenseQueue.Queue({head: _queueHead, tail: _queueTail + 1, count: _queueCountBefore + 1}));
      _queue.setWithdrawal(
        uint256(_queueTail) + 1,
        IRelay.WithdrawEntry({
          holder: _holderAt(_seededCount),
          registeredAt: uint48(block.timestamp),
          mintFresh: true,
          shares: 1,
          destination: 0
        })
      );
      _queue.setEscrowedShares(_holderAt(_seededCount), 1);
    }

    uint256 _settledWeight;
    {
      uint256 _runningSupply = _ctxSupply;
      uint256 _runningBacking = _ctxBacking;
      for (uint256 _i; _i < _seededCount; ++_i) {
        uint256 _amount = (_withdrawAt(_i).shares * _runningBacking) / _runningSupply;
        _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _holderAt(_i), _i);
        _mockSettledStake(_i, _amount);
        _runningSupply -= _withdrawAt(_i).shares;
        _runningBacking -= _amount;
        _settledWeight += _amount;
      }
    }

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(_MAX_DRAIN_ENTRIES, _ctxSupply, _ctxBacking, _settledWeight, _queuedShares + 1)
    );

    // it should stop the drain at the first unaffordable exit
    assertEq(_result.count, _seededCount);
    assertEq(_queueCount(), 1);
    assertEq(_withdrawAt(0).holder, _holderAt(_seededCount));
    assertEq(_result.pendingWithdrawalShares, 1);
    assertEq(_queue.escrowedShares(_holderAt(_seededCount)), 1);
  }

  /// @notice A closed Relay burns only the principal: every settled exit leaves its yield side whole.
  /// @dev Closure ends the reward stream but not its tail — the final votes' fees arrive an epoch
  ///      later and `notifyReward` divides them by the yield supply. Burning at exit would size each
  ///      holder's slice of that tail by how late it left the queue, and a fully drained queue would
  ///      retire the denominator and strand the tail behind `NoSupply`. The zero-count expectation is
  ///      the half that matters: it fails on any drain that still touches the yield satellite.
  function test_GivenTheRelayIsClosed(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    uint256 _seededCount = _queueCount();
    uint256 _queuedShares = _totalSeededWithdrawShares();
    {
      uint256 _runningSupply = _ctxSupply;
      uint256 _runningBacking = _ctxBacking;
      for (uint256 _i; _i < _seededCount; ++_i) {
        uint256 _amount = (_withdrawAt(_i).shares * _runningBacking) / _runningSupply;
        _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _holderAt(_i), _i);
        _mockSettledStake(_i, _amount);
        // it should burn each settled exits principal in full
        vm.expectCall(_principalToken, abi.encodeCall(IRelayToken.burn, (_holderAt(_i), _withdrawAt(_i).shares)));
        _runningSupply -= _withdrawAt(_i).shares;
        _runningBacking -= _amount;
      }
    }
    // it should skip the yield burn entirely
    vm.expectCall(_yieldToken, abi.encodeWithSelector(IRelayToken.burn.selector), 0);

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(type(uint256).max, _ctxSupply, _ctxBacking, _ctxBacking, _queuedShares, true)
    );

    // it should settle the whole batch
    assertEq(_result.count, _seededCount);
    assertEq(_result.pendingWithdrawalShares, 0);
    assertEq(_queueCount(), 0);
  }

  /// @notice A sentinel destination routes straight to a fresh sAERO without consulting the lock rule.
  function test_WhenTheDestinationIsTheMintSentinel(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _mintedId
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    uint256 _queuedShares = _totalSeededWithdrawShares();
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _entry.holder, _mintedId);
    _mockSettledStake(_mintedId, _net);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _mintedId);

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _queuedShares)
    );

    // it should route the weight to a freshly minted token and pair burn the holder
    assertEq(_result.count, 1);
  }

  /// @dev Names a fuzzed destination on the head exit and pins the relay stake permanent. The relay's own
  ///      id is excluded: a holder can never name the relay sAERO, and reusing it would overwrite the source's mock.
  modifier whenTheSourceStakeIsPermanent(uint256 _destinationId) {
    _destinationId = bound(_destinationId, 1, type(uint72).max);
    vm.assume(_destinationId != _RELAY_TOKEN_ID);
    _setHeadWithdrawalDestination(_destinationId);
    _mockStaked(_RELAY_TOKEN_ID, 0, true);
    _;
  }

  /// @notice A permanent relay may hand weight to another permanent stake: the named destination survives.
  function test_WhenTheDestinationStakeIsAlsoPermanent(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _destinationId
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking)
    whenTheSourceStakeIsPermanent(_destinationId)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockStakedSurviving(_entry.destination, 0, true, _net);
    _mockWithdrawToNFT(_entry.destination, _amount, _entry.holder, 0);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _entry.destination);

    // it should route the weight to the named destination
    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _totalSeededWithdrawShares())
    );
  }

  /// @notice A permanent relay cannot hand weight to a decaying stake; the drain falls back to minting.
  function test_WhenTheDestinationStakeIsNotPermanent(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _destinationId,
    uint48 _destinationEnd
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking)
    whenTheSourceStakeIsPermanent(_destinationId)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    _mockStaked(_entry.destination, _destinationEnd, false);
    uint256 _queuedShares = _totalSeededWithdrawShares();
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _entry.holder, _FRESH_MINT_ID);
    _mockSettledStake(_FRESH_MINT_ID, _net);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _FRESH_MINT_ID);

    // it should fall back to minting a fresh token
    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _queuedShares)
    );
  }

  /// @notice A surviving destination that already holds weight reports only what this exit added to it.
  function test_WhenTheSurvivingDestinationAlreadyHoldsStake(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking,
    uint256 _destinationId,
    uint256 _destinationBaseline
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking)
    whenTheSourceStakeIsPermanent(_destinationId)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    // Keep one unit of headroom under the uint128 stake ceiling so the baseline has room above the delta.
    _ctxSupply = bound(_ctxSupply, _totalSeededWithdrawShares(), type(uint128).max - 1);
    _ctxBacking = bound(_ctxBacking, _ctxSupply, type(uint128).max - 1);
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    uint256 _baseline = bound(_destinationBaseline, 1, type(uint128).max - _net);
    // The destination reads `_baseline` before the move and `_baseline + _net` after it. The weight it
    // already held belongs to earlier exits, so this settlement must report the difference only.
    _mockStakedSurvivingWithBaseline(_entry.destination, _baseline, _net);
    _mockWithdrawToNFT(_entry.destination, _amount, _entry.holder, 0);
    // it should emit the weight delivered above the previous stake
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _entry.destination);

    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _totalSeededWithdrawShares())
    );
  }

  /// @dev Names a fuzzed destination on the head exit and pins the relay stake decaying at a recorded fuzzed
  ///      unlock. The relay's own id is excluded: a holder can never name it, and reusing it would overwrite the source's mock.
  modifier whenTheSourceStakeIsNotPermanent(uint256 _destinationId, uint48 _sourceEnd) {
    _destinationId = bound(_destinationId, 1, type(uint72).max);
    vm.assume(_destinationId != _RELAY_TOKEN_ID);
    _setHeadWithdrawalDestination(_destinationId);
    _seededSourceEnd = uint48(bound(_sourceEnd, 1, type(uint48).max));
    _mockStaked(_RELAY_TOKEN_ID, _seededSourceEnd, false);
    _;
  }

  /// @notice A permanent destination satisfies any source lock: the named destination survives.
  function test_WhenTheDestinationStakeIsPermanent(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _destinationId,
    uint48 _sourceEnd,
    uint256 _totalSupply,
    uint256 _totalBacking
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking)
    whenTheSourceStakeIsNotPermanent(_destinationId, _sourceEnd)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockStakedSurviving(_entry.destination, 0, true, _net);
    _mockWithdrawToNFT(_entry.destination, _amount, _entry.holder, 0);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _entry.destination);

    // it should route the weight to the named destination
    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _totalSeededWithdrawShares())
    );
  }

  /// @notice A destination unlocking with (or after) the source satisfies the monotonic unlock rule and survives.
  function test_WhenTheDestinationUnlockIsNotEarlierThanTheSourceUnlock(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _destinationId,
    uint48 _sourceEnd,
    uint256 _destinationEnd,
    uint256 _totalSupply
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalSupply)
    whenTheSourceStakeIsNotPermanent(_destinationId, _sourceEnd)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    _destinationEnd = bound(_destinationEnd, _seededSourceEnd, type(uint48).max);
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockStakedSurviving(_entry.destination, uint48(_destinationEnd), false, _net);
    _mockWithdrawToNFT(_entry.destination, _amount, _entry.holder, 0);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _entry.destination);

    // it should route the weight to the named destination
    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _totalSeededWithdrawShares())
    );
  }

  /// @notice A destination unlocking before the source violates the monotonic unlock rule; the drain falls back to minting.
  function test_WhenTheDestinationUnlockIsEarlierThanTheSourceUnlock(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _destinationId,
    uint48 _sourceEnd,
    uint256 _destinationEnd,
    uint256 _totalSupply
  )
    external
    givenTheQueueIsNotEmpty(_seed)
    givenTheQueuedExitsAreAffordable(_totalSupply, _totalSupply)
    whenTheSourceStakeIsNotPermanent(_destinationId, _sourceEnd)
  {
    _assumeFuzzable(_caller);
    IRelay.WithdrawEntry memory _entry = _withdrawAt(0);
    _destinationEnd = bound(_destinationEnd, 0, _seededSourceEnd - 1);
    _mockStaked(_entry.destination, uint48(_destinationEnd), false);
    uint256 _amount = (_entry.shares * _ctxBacking) / _ctxSupply;
    uint256 _net = _amount - (_amount * bound(_seed.feeBps, 0, 10_000)) / 10_000;
    _mockWithdrawToNFT(_MINT_SENTINEL, _amount, _entry.holder, _FRESH_MINT_ID);
    _mockSettledStake(_FRESH_MINT_ID, _net);
    _expectWithdrawProcessed(_entry.holder, _entry.shares, _net, _FRESH_MINT_ID);

    // it should fall back to minting a fresh token
    vm.prank(_caller);
    _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow),
      IVoterPaymentsModule(_vpm),
      _withdrawContext(1, _ctxSupply, _ctxBacking, _ctxBacking, _totalSeededWithdrawShares())
    );
  }

  /// @notice Hand-computed known example: at price two (supply 100, backing 200) a 25-share exit frees 50;
  ///         the second exit prices at the post-burn ratio (150/75) so its 30 shares free 60.
  function test_WhenTheRatioCarriesAcrossABatch(
    address _caller,
    WithdrawQueueSeed memory _seed,
    uint256 _totalSupply,
    uint256 _totalBacking
  ) external givenTheQueueIsNotEmpty(_seed) givenTheQueuedExitsAreAffordable(_totalSupply, _totalBacking) {
    _assumeFuzzable(_caller);
    _queue.setWithdrawQueue(DenseQueue.Queue({head: 1, tail: 2, count: 2}));
    _queue.setWithdrawal(
      1,
      IRelay.WithdrawEntry({
        holder: _holderAt(0), registeredAt: uint48(block.timestamp), mintFresh: true, shares: 25, destination: 0
      })
    );
    _queue.setWithdrawal(
      2,
      IRelay.WithdrawEntry({
        holder: _holderAt(1), registeredAt: uint48(block.timestamp), mintFresh: true, shares: 30, destination: 0
      })
    );
    _queue.setEscrowedShares(_holderAt(0), 25);
    _queue.setEscrowedShares(_holderAt(1), 30);
    _mockWithdrawToNFT(_MINT_SENTINEL, 50, _holderAt(0), 11);
    _mockWithdrawToNFT(_MINT_SENTINEL, 60, _holderAt(1), 12);
    _mockSettledStake(11, 50);
    _mockSettledStake(12, 60);

    vm.prank(_caller);
    QueueLib.WithdrawResult memory _result = _queue.processWithdrawals(
      IVotingEscrow(_votingEscrow), IVoterPaymentsModule(_vpm), _withdrawContext(2, 100, 200, 200, 55)
    );

    // it should price a known two exit example at the simulated ratios
    assertEq(_result.count, 2);
    assertEq(_result.totalBacking, 90);
    assertEq(_result.pendingWithdrawalShares, 0);
  }

  /// @dev Mock the three `staked(_tokenId)` reads a surviving permanent destination takes when it already
  ///      holds weight: the lock check and the pre-move baseline answer `_baseline`, the post-move read
  ///      answers `_baseline + _net`.
  function _mockStakedSurvivingWithBaseline(uint256 _tokenId, uint256 _baseline, uint256 _net) private {
    bytes memory _calldata = abi.encodeCall(IVotingEscrow.staked, (_tokenId));
    bytes[] memory _returns = new bytes[](3);
    // forge-lint: disable-next-line(unsafe-typecast)
    _returns[0] = abi.encode(IVotingEscrow.StakedBalance({amount: uint128(_baseline), end: 0, isPermanent: true}));
    _returns[1] = _returns[0];
    // forge-lint: disable-next-line(unsafe-typecast)
    _returns[2] =
      abi.encode(IVotingEscrow.StakedBalance({amount: uint128(_baseline + _net), end: 0, isPermanent: true}));
    vm.mockCalls(_votingEscrow, _calldata, _returns);
    vm.expectCall(_votingEscrow, _calldata);
  }
}
