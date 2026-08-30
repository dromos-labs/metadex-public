// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

import {QueueLibHarness} from 'V3-test/unit/relay/harnesses/QueueLibHarness.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';

/**
 * @notice Unit tests for `DenseQueue.nextHead`, which turns the cursor a walk stopped on into the
 *         head the queue stores.
 * @dev Read directly rather than through a processing pass. Every caller hands the result to
 *      `store`, which zeroes the head on an emptied queue, so a pass would settle both branches to
 *      the same stored value and hide which one ran.
 */
contract UnitDenseQueueNextHead is TestHelpers {
  QueueLibHarness internal _queue;

  function setUp() external {
    _queue = new QueueLibHarness();
  }

  /// @notice The walk ran past the last id ever issued, so nothing is left to wait on.
  function test_WhenTheCursorIsPastTheTail(uint40 _tail, uint256 _cursor, uint256 _wideCursor) external {
    _tail = uint40(bound(_tail, 0, type(uint40).max - 1));
    _queue.setDepositList(DenseQueue.Queue({head: 0, tail: _tail, count: 0}));

    // it should return zero
    _cursor = bound(_cursor, uint256(_tail) + 1, type(uint40).max);
    assertEq(_queue.nextDepositHead(_cursor), 0, 'a cursor past the tail leaves no head');

    // it should return zero for a cursor wider than the id type
    // The cursor is wider than an id so the increment past the last one cannot overflow. The zero
    // branch runs first, which is what keeps the narrowing cast safe.
    _wideCursor = bound(_wideCursor, uint256(type(uint40).max) + 1, type(uint256).max);
    assertEq(_queue.nextDepositHead(_wideCursor), 0, 'a cursor wider than an id still leaves no head');
  }

  /// @notice The walk stopped on an id the queue issued, and that id becomes the head.
  function test_WhenTheCursorIsAtOrBeforeTheTail(uint40 _tail, uint256 _cursor) external {
    _tail = uint40(bound(_tail, 1, type(uint40).max));
    _cursor = bound(_cursor, 1, _tail);
    _queue.setDepositList(DenseQueue.Queue({head: 0, tail: _tail, count: 0}));

    // it should return the cursor
    assertEq(_queue.nextDepositHead(_cursor), uint40(_cursor), 'the cursor becomes the head');
  }
}
