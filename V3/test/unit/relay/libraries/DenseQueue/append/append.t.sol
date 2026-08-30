// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {QueueLibHarness} from 'V3-test/unit/relay/harnesses/QueueLibHarness.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';

/**
 * @notice Unit tests for `DenseQueue.append`, the only path that issues an id and moves the tail.
 * @dev Every case seeds the bookkeeping directly on the harness, so `append` is the only production
 *      code an assertion can depend on. Driving these through a processing pass instead would let
 *      that pass repair the state under test before `append` ever sees it.
 */
contract UnitDenseQueueAppend is TestHelpers {
  QueueLibHarness internal _queue;

  function setUp() external {
    _queue = new QueueLibHarness();
  }

  /// @notice With live entries waiting, the head is still the earliest of them, so a new entry
  ///         joins the back of the line and leaves the head alone.
  function test_WhenTheQueueHoldsLiveEntries(uint40 _head, uint40 _tail, uint40 _count) external {
    _tail = uint40(bound(_tail, 1, type(uint40).max - 1));
    _head = uint40(bound(_head, 1, _tail));
    // The count can never exceed the ids ever issued.
    _count = uint40(bound(_count, 1, _tail));
    _queue.setDepositList(DenseQueue.Queue({head: _head, tail: _tail, count: _count}));

    uint40 _id = _queue.appendDeposit();

    // it should issue the id after the tail
    assertEq(_id, _tail + 1, 'the id follows the tail');
    (uint40 _newHead, uint40 _newTail, uint40 _newCount) = _queue.depositList();
    assertEq(_newTail, _id, 'the tail moves to the new id');
    // it should count the new entry in
    assertEq(_newCount, _count + 1, 'the new entry is counted');
    // it should leave the head where it is
    assertEq(_newHead, _head, 'the head still waits on the earliest live entry');
  }

  /// @notice Nothing waits: a queue never appended to, or one drained in order. The new entry is
  ///         the earliest live one, so it becomes the head.
  function test_WhenTheQueueIsEmptyAndTheHeadIsZero(uint40 _tail) external {
    _tail = uint40(bound(_tail, 0, type(uint40).max - 1));
    _queue.setDepositList(DenseQueue.Queue({head: 0, tail: _tail, count: 0}));

    uint40 _id = _queue.appendDeposit();

    // it should point the head at the new entry
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, _id, 'the new entry becomes the head');
  }

  /// @notice The state a by-id pass can leave behind: it steps the head only off the ids it names,
  ///         so the head can sit on a deleted entry while nothing live remains. The count says the
  ///         queue is empty, and that is what decides, so the new entry becomes the head. Reading
  ///         the head instead would keep it on the tombstone and make the next walk pay for every
  ///         deleted id in front of the new entry.
  function test_WhenTheQueueIsEmptyAndTheHeadWasLeftOnAConsumedEntry(uint40 _staleHead, uint40 _tail) external {
    _tail = uint40(bound(_tail, 1, type(uint40).max - 1));
    _staleHead = uint40(bound(_staleHead, 1, _tail));
    _queue.setDepositList(DenseQueue.Queue({head: _staleHead, tail: _tail, count: 0}));

    uint40 _id = _queue.appendDeposit();

    // it should point the head at the new entry
    (uint40 _head,,) = _queue.depositList();
    assertEq(_head, _id, 'the new entry becomes the head, not the tombstone');
  }
}
