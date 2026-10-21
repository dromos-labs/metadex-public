// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

/**
 * @title  DenseQueue
 * @notice Unbounded FIFO bookkeeping shared by the Relay's deposit and withdraw queues. This
 *         library only stores the head, tail and count counters, packed into one slot. The caller
 *         stores the typed entries in a `mapping(uint256 id => Entry)`, keyed by the id `append`
 *         returns. Ids are never reused, so the queue has no size limit.
 * @dev    Ids run in sequence from one (zero is the null id) and are never reused, so every id up
 *         to `tail` was issued and the entry after an id is always that id plus one. The queue
 *         therefore stores no link between entries. A consumer may delete a consumed entry — the id
 *         keeps its place in the order — but a path that reused an id would break the derivation
 *         and must store an explicit link instead.
 */
library DenseQueue {
  /// @notice Queue bookkeeping, packed into one slot.
  /// @param head Earliest id that can still be live; zero exactly when the count is zero. On some
  ///        queues the head can point to an entry that was already consumed; see `nextHead`.
  /// @param tail Last issued id; it never decreases, so it also bounds which ids exist. Zero while
  ///        nothing was ever appended.
  /// @param count Live (not yet consumed) entries; the emptiness check.
  /// @dev `count` is derivable on a queue that is only consumed in order, but it shares the slot
  ///      that `head` and `tail` are written to anyway, so keeping it costs no extra store. On a
  ///      queue that also consumes entries out of order it is not derivable at all.
  struct Queue {
    uint40 head;
    uint40 tail;
    uint40 count;
  }

  /// @notice Issue the next id and count the new entry in. The caller writes the entry itself.
  /// @param _queue Queue bookkeeping to append to.
  /// @return _id Id the caller must store the new entry under.
  /// @dev An empty queue has no earlier entry to wait behind: point the head at the new one. The
  ///      count decides that, not the head, because the head can point at a deleted entry.
  function append(Queue storage _queue) internal returns (uint40 _id) {
    Queue memory _queueCache = _queue;
    _id = _queueCache.tail + 1;
    // Compute each field before the writes: three plain stores in a straight line let the
    // optimizer fold them into one store, because the struct fits one slot.
    uint40 _head = isEmpty(_queueCache) ? _id : _queueCache.head;
    uint40 _count = _queueCache.count + 1;
    _queue.head = _head;
    _queue.tail = _id;
    _queue.count = _count;
  }

  /// @notice Write the cached head and count back to storage after a processing pass.
  /// @param _queue Queue bookkeeping to write to.
  /// @param _queueCache Cache that holds the head and count to store.
  /// @dev This helper never writes the tail: `append` is the only place that moves it, and that is
  ///      what keeps the ids dense. Head and count share one slot, so the write-back is one store.
  ///      The head goes back to zero once the count reaches zero: a pass that consumes entries out
  ///      of order can leave it pointing at an entry that is already deleted.
  function store(Queue storage _queue, Queue memory _queueCache) internal {
    _queue.head = isEmpty(_queueCache) ? 0 : _queueCache.head;
    _queue.count = _queueCache.count;
  }

  /// @notice The head to store after a walk stopped on `_cursor`.
  /// @param _queue Queue bookkeeping the walk ran over.
  /// @param _cursor Id the walk stopped on; a cursor past the tail means the walk reached the end.
  /// @return _head The new head: the cursor, or zero once the walk passed the tail.
  /// @dev The cursor is wider than the id type because a walk that reaches the last id increments
  ///      past it, which must not revert on overflow. The cast is safe: a cursor above the tail
  ///      takes the zero branch.
  function nextHead(Queue memory _queue, uint256 _cursor) internal pure returns (uint40 _head) {
    _head = _cursor > _queue.tail ? 0 : uint40(_cursor);
  }

  /// @notice Whether `_id` was ever issued by this queue.
  /// @param _queue Queue bookkeeping to check against.
  /// @param _id Id to check.
  /// @return _exists True when the id is in range; the tail bounds existence because ids are
  ///         issued in sequence and never reused.
  function exists(Queue memory _queue, uint256 _id) internal pure returns (bool _exists) {
    _exists = _id != 0 && _id <= _queue.tail;
  }

  /// @notice Whether no live entry waits.
  /// @param _queue Queue bookkeeping to read.
  /// @return _empty True when the queue holds no live entry.
  /// @dev The count is the check, never the head: on a queue that also consumes entries out of
  ///      order, a non-zero head can point to an entry that was already consumed.
  function isEmpty(Queue memory _queue) internal pure returns (bool _empty) {
    _empty = _queue.count == 0;
  }
}
