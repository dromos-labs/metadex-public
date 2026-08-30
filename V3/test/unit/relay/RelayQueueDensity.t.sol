// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';

/// @notice Locks the invariant both queues rest on: ids run in sequence with no gaps, so neither
///         queue stores a link to the next entry and a walk reaches every entry by adding one.
/// @dev These tests drive the real registration and processing paths rather than seeding storage,
///      because the invariant under test is a property OF those paths: a gap can only ever come
///      from the code that issues an id or consumes an entry. Seeding the queue directly would
///      assert the seeder instead, and the assertion would hold whatever the writers did.
contract UnitRelayQueueDensity is BaseRelay {
  /// @dev Upper bound on seeded requests and exits; keeps the escrow inside the seeded position.
  uint256 internal constant _MAX_SEEDED = 6;

  /// @dev Shares each seeded exit escrows, against a hundred-unit position.
  uint256 internal constant _EXIT_SHARES = 10e18;

  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @dev Wrap one id into the array `processOverduePending` takes.
  function _ids(uint256 _id) internal pure returns (uint256[] memory _array) {
    _array = new uint256[](1);
    _array[0] = _id;
  }

  /// @dev Seed a queue both processing paths have run over: one entry settled out of order by id,
  ///      which is the only thing that can leave a processed entry in the middle, then a bounded
  ///      keeper walk across part of the rest. The by-id caller is fuzzed because that path takes
  ///      no role.
  modifier whenDepositRequestsInterleaveWithProcessing(
    address _caller,
    uint256 _requests,
    uint256 _byId,
    uint256 _walked
  ) {
    _assumeFuzzable(_caller);
    uint256 _seeded = bound(_requests, 2, _MAX_SEEDED);
    for (uint256 _i; _i < _seeded; ++_i) {
      _requestDeposit(users.alice, 2, 2e18);
    }

    // Never the head, so the by-id settlement leaves the head on a live entry and the walk has to
    // step over a consumed one.
    vm.warp(block.timestamp + 1 days + 1);
    vm.prank(_caller);
    _relay.processOverduePending(_ids(bound(_byId, 2, _seeded)));

    _processPending(bound(_walked, 1, _seeded));
    _;
  }

  /// @dev Seed a queue the keeper walk drained to the end, so the head is back to zero while the
  ///      tail keeps the last id issued.
  modifier whenTheDepositWalkReachesTheEndAndARequestFollows(uint256 _requests) {
    uint256 _seeded = bound(_requests, 1, _MAX_SEEDED);
    for (uint256 _i; _i < _seeded; ++_i) {
      _requestDeposit(users.alice, 2, 2e18);
    }
    _processPending(_seeded);
    _;
  }

  /// @dev Seed a withdraw queue with a bounded run of exits against one admitted position.
  modifier whenExitsAreRegistered(uint256 _exits) {
    _admitDeposit(users.alice, 2, 100e18);
    uint256 _seeded = bound(_exits, 1, _MAX_SEEDED - 1);
    for (uint256 _i; _i < _seeded; ++_i) {
      vm.prank(users.alice);
      _relay.registerOnWithdrawQueue(_EXIT_SHARES, _MINT_SENTINEL);
    }
    _;
  }

  /// @dev Seed a withdraw queue the drain emptied. The drain caller is fuzzed because that path
  ///      takes no role, and the exit size is fuzzed with the routing mock following it.
  modifier whenTheDrainEmptiesTheWithdrawQueueAndAnExitFollows(address _caller, uint256 _shares) {
    _assumeFuzzable(_caller);
    _admitDeposit(users.alice, 2, 100e18);
    // Leave room for the exit that follows the drain: the burn takes these shares out of the pair.
    uint256 _escrowed = bound(_shares, 1e18, 50e18);
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(_escrowed, _MINT_SENTINEL);

    // Genesis prices one for one, so the weight leaving equals the shares burned.
    _mockWithdrawRoute(users.alice, _escrowed, 777);
    vm.prank(_caller);
    _relay.processWithdrawals(1);
    _;
  }

  /// @notice Whatever order the two deposit paths settle entries in, every id from one to the
  ///         tail stays addressable: a live id keeps its entry and a consumed id reads back
  ///         deleted. The walk reaches the next id by adding one rather than by reading a link,
  ///         so the tail bounds the walk and the count tracks exactly the live entries.
  function test_WhenDepositRequestsInterleaveWithProcessing(
    address _caller,
    uint256 _requests,
    uint256 _byId,
    uint256 _walked
  ) external whenDepositRequestsInterleaveWithProcessing(_caller, _requests, _byId, _walked) {
    (, uint40 _tail, uint40 _count) = _relay.depositList();

    uint256 _live;
    for (uint256 _id = 1; _id <= _tail; ++_id) {
      (address _recipient, uint48 _requestedAt,, uint128 _amount) = _relay.pendingDeposits(_id);
      if (_requestedAt != 0) {
        // it should keep every live entry under its issued id up to the tail
        assertEq(_amount, 2e18);
        ++_live;
      } else {
        // it should read the consumed ids as deleted entries
        assertEq(_recipient, address(0));
        assertEq(_amount, 0);
      }
    }

    // it should leave nothing above the tail
    (, uint48 _pastTail,,) = _relay.pendingDeposits(uint256(_tail) + 1);
    assertEq(_pastTail, 0);

    // it should keep the count equal to the live entries
    assertEq(_count, _live);
  }

  /// @notice A drained queue does not restart its ids. The head is repointed at the fresh entry
  ///         instead, so an id is never reused and the tail keeps bounding which ids exist.
  function test_WhenTheDepositWalkReachesTheEndAndARequestFollows(uint256 _requests)
    external
    whenTheDepositWalkReachesTheEndAndARequestFollows(_requests)
  {
    (uint40 _drainedHead, uint40 _drainedTail, uint40 _drainedCount) = _relay.depositList();
    assertEq(_drainedHead, 0);
    assertEq(_drainedCount, 0);

    // it should issue the id after the tail rather than restart
    vm.expectEmit(address(_relay));
    emit IRelay.DepositRequested(2, users.alice, 2e18, uint256(_drainedTail) + 1);
    _requestDeposit(users.alice, 2, 2e18);

    // it should point the head at the new entry
    (uint40 _head, uint40 _tail,) = _relay.depositList();
    assertEq(_head, uint256(_drainedTail) + 1);
    assertEq(_tail, uint256(_drainedTail) + 1);
  }

  /// @notice The withdraw queue holds the same shape. It is only ever consumed from the head, so a
  ///         gap cannot appear at all, and the ids stay dense across repeated registrations.
  function test_WhenExitsAreRegistered(uint256 _exits) external whenExitsAreRegistered(_exits) {
    (uint40 _head, uint40 _tail, uint40 _count) = _relay.withdrawQueue();

    // it should keep an entry under every id up to the tail
    assertEq(_head, 1);
    for (uint256 _id = 1; _id <= _tail; ++_id) {
      (address _holder,,,) = _relay.withdrawals(_id);
      assertEq(_holder, users.alice);
    }

    // it should leave nothing above the tail
    (address _pastTail,,,) = _relay.withdrawals(uint256(_tail) + 1);
    assertEq(_pastTail, address(0));

    // it should keep the count equal to the undrained exits
    assertEq(_count, _tail);
  }

  /// @notice The drain leaves the same trace as the deposit walk: a fully drained queue zeroes its
  ///         head and keeps its tail, so the next exit continues the sequence.
  function test_WhenTheDrainEmptiesTheWithdrawQueueAndAnExitFollows(
    address _caller,
    uint256 _shares
  ) external whenTheDrainEmptiesTheWithdrawQueueAndAnExitFollows(_caller, _shares) {
    (uint40 _drainedHead, uint40 _drainedTail, uint40 _drainedCount) = _relay.withdrawQueue();
    assertEq(_drainedHead, 0);
    assertEq(_drainedCount, 0);

    // it should issue the id after the tail rather than restart
    vm.expectEmit(address(_relay));
    emit IRelay.WithdrawRegistered(users.alice, 1e18, _MINT_SENTINEL, uint256(_drainedTail) + 1);
    vm.prank(users.alice);
    _relay.registerOnWithdrawQueue(1e18, _MINT_SENTINEL);

    // it should point the head at the new entry
    (uint40 _head, uint40 _tail,) = _relay.withdrawQueue();
    assertEq(_head, uint256(_drainedTail) + 1);
    assertEq(_tail, uint256(_drainedTail) + 1);
  }
}
