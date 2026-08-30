// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseQueueLib} from 'V3-test/unit/relay/libraries/BaseQueueLib.sol';

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayToken} from 'V3/interfaces/relay/IRelayToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';
import {DenseQueue} from 'V3/relay/libraries/DenseQueue.sol';

/// @notice Unit tests for `QueueLib.requireUncoveredHead`, the permissionless closing gate, driven
///         through the harness — which also serves the library's Relay self-calls (`relayConfig`,
///         `totalBacking`, `principalToken`), since the delegatecall makes `address(this)` the
///         harness. Bounds keep the head pricing inside uint256: shares within the supply, backing
///         within uint96.
contract UnitQueueLibRequireUncoveredHead is BaseQueueLib {
  /// @dev Fixed evacuation window preset on the harness config.
  uint48 internal constant _EVACUATION_WINDOW = 7 days;

  /// @dev Mirrors QueueLib's `_CHAIN0`.
  uint256 internal constant _CHAIN0 = 0;

  /// @dev The Voter answering the free chain0 weight this gate prices the head against.
  address internal _voter;

  function setUp() public override {
    super.setUp();
    _voter = _mockContract('Voter');
    _queue.setPrincipalToken(IRelayToken(_principalToken));
    _queue.setEvacuationWindow(_EVACUATION_WINDOW);
  }

  /// @dev Mock (and expect) the Voter's free chain0 weight read.
  function _mockChainZeroFree(uint256 _free) internal {
    _mockAndExpect(
      // forge-lint: disable-next-line(unsafe-typecast)
      _voter,
      abi.encodeCall(IVoter.allocationChainAmounts, (_RELAY_TOKEN_ID, _CHAIN0)),
      abi.encode(uint128(_free))
    );
  }

  /// @dev Mock (and expect) the principal token supply read pricing the head exit.
  function _mockSupply(uint256 _supply) internal {
    _mockAndExpect(_principalToken, abi.encodeCall(IRelayToken.totalSupply, ()), abi.encode(_supply));
  }

  /// @dev Seed a one-entry withdraw queue whose head holds `_shares` registered at `_registeredAt`.
  function _seedHeadExit(uint256 _shares, uint48 _registeredAt) internal {
    _queue.setWithdrawQueue(DenseQueue.Queue({head: 1, tail: 1, count: 1}));
    _queue.setWithdrawal(
      1,
      IRelay.WithdrawEntry({
        holder: makeAddr('holder'),
        registeredAt: _registeredAt,
        mintFresh: true,
        shares: uint128(_shares),
        destination: 0
      })
    );
  }

  /// @notice With no exit waiting, there is nothing to leave uncovered and the gate must revert.
  function test_WhenTheWithdrawQueueIsEmpty(address _caller, uint256 _head) external {
    _assumeFuzzable(_caller);
    _head = bound(_head, 0, type(uint32).max);
    _queue.setWithdrawQueue(DenseQueue.Queue({head: uint40(_head), tail: uint40(_head), count: 0}));

    // it should revert with NoQueuedWithdrawal
    vm.expectRevert(IRelay.NoQueuedWithdrawal.selector);
    vm.prank(_caller);
    _queue.requireUncoveredHead(IVoter(_voter), _RELAY_TOKEN_ID);
  }

  /// @dev Seeds a one-entry queue registered at the current timestamp, bounding the head's shares
  ///      into the uint96 share range; each branch warps forward from there and re-derives the
  ///      same bound (bound is deterministic) wherever it prices the head.
  modifier givenTheWithdrawQueueHoldsAHeadExit(uint256 _shares) {
    // forge-lint: disable-next-line(unsafe-typecast)
    _seedHeadExit(bound(_shares, 1, type(uint96).max), uint48(block.timestamp));
    _;
  }

  /// @notice A head younger than the evacuation window cannot open the gate, whatever its coverage.
  function test_WhenTheEvacuationWindowHasNotElapsedSinceRegistration(
    address _caller,
    uint256 _shares,
    uint256 _elapsed
  ) external givenTheWithdrawQueueHoldsAHeadExit(_shares) {
    _assumeFuzzable(_caller);
    _elapsed = bound(_elapsed, 0, _EVACUATION_WINDOW - 1);
    vm.warp(block.timestamp + _elapsed);

    // it should revert with EvacuationWindowNotElapsed
    vm.expectRevert(IRelay.EvacuationWindowNotElapsed.selector);
    vm.prank(_caller);
    _queue.requireUncoveredHead(IVoter(_voter), _RELAY_TOKEN_ID);
  }

  /// @dev Ages the seeded head a full evacuation window past its registration.
  modifier givenTheEvacuationWindowHasElapsed() {
    vm.warp(block.timestamp + _EVACUATION_WINDOW);
    _;
  }

  /// @notice A head the free chain0 weight could pay is covered: the remedy is a
  ///         permissionless drain, not a shutdown.
  function test_WhenTheFreeChainZeroWeightCoversTheHeadExit(
    address _caller,
    uint256 _shares,
    uint256 _supply,
    uint256 _backing,
    uint256 _free
  ) external givenTheWithdrawQueueHoldsAHeadExit(_shares) givenTheEvacuationWindowHasElapsed {
    _assumeFuzzable(_caller);
    _shares = bound(_shares, 1, type(uint96).max);
    _supply = bound(_supply, _shares, type(uint96).max);
    _backing = bound(_backing, 0, type(uint96).max);
    _queue.setTotalBacking(_backing);
    _mockSupply(_supply);
    uint256 _amount = (_shares * _backing) / _supply;
    _free = bound(_free, _amount, type(uint128).max);
    _mockChainZeroFree(_free);

    // it should revert with HeadIsCovered
    vm.expectRevert(IRelay.HeadIsCovered.selector);
    vm.prank(_caller);
    _queue.requireUncoveredHead(IVoter(_voter), _RELAY_TOKEN_ID);
  }

  /// @notice An old AND unpayable head is the real failure the permissionless gate exists for.
  function test_WhenTheHeadExitIsUncovered(
    address _caller,
    uint256 _shares,
    uint256 _supply,
    uint256 _backing,
    uint256 _free
  ) external givenTheWithdrawQueueHoldsAHeadExit(_shares) givenTheEvacuationWindowHasElapsed {
    _assumeFuzzable(_caller);
    _shares = bound(_shares, 1, type(uint96).max);
    _supply = bound(_supply, _shares, type(uint96).max);
    _backing = bound(_backing, 1, type(uint96).max);
    _queue.setTotalBacking(_backing);
    _mockSupply(_supply);
    uint256 _amount = (_shares * _backing) / _supply;
    vm.assume(_amount != 0);
    _free = bound(_free, 0, _amount - 1);
    _mockChainZeroFree(_free);

    // it should price the head through the principal token supply and pass
    vm.prank(_caller);
    _queue.requireUncoveredHead(IVoter(_voter), _RELAY_TOKEN_ID);
  }

  /// @notice The window is a floor, not a single instant: a head older than the window stays
  ///         uncovered, so the gate still opens long after the window closed.
  function test_WhenTheHeadExitIsUncoveredWellPastTheWindow(
    address _caller,
    uint256 _shares,
    uint256 _supply,
    uint256 _backing,
    uint256 _free,
    uint256 _extra
  ) external givenTheWithdrawQueueHoldsAHeadExit(_shares) givenTheEvacuationWindowHasElapsed {
    _assumeFuzzable(_caller);
    // The modifier stops exactly on the window edge; move well past it.
    _extra = bound(_extra, 1, 365 days);
    vm.warp(block.timestamp + _extra);
    _shares = bound(_shares, 1, type(uint96).max);
    _supply = bound(_supply, _shares, type(uint96).max);
    _backing = bound(_backing, 1, type(uint96).max);
    _queue.setTotalBacking(_backing);
    _mockSupply(_supply);
    uint256 _amount = (_shares * _backing) / _supply;
    vm.assume(_amount != 0);
    _free = bound(_free, 0, _amount - 1);
    _mockChainZeroFree(_free);

    // it should pass once the window has elapsed with margin
    vm.prank(_caller);
    _queue.requireUncoveredHead(IVoter(_voter), _RELAY_TOKEN_ID);
  }
}
