// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';
import {LeafVoterHarness} from 'V3-test/unit/voter/LeafVoterHarness.sol';

import {IMessageAdapter, IMessageOrchestrator, LeafMessageOrchestrator} from 'V3/bridge/LeafMessageOrchestrator.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';
import {MAXTIME} from 'V3/libraries/ProtocolConstants.sol';

/**
 * @title UnitLeafMessageOrchestratorComposedRoute
 * @notice Composed (integration-style) unit test wiring a REAL `LeafMessageOrchestrator` to a REAL
 *         `LeafVoter`. The split unit suites mock one side of the pair (the orchestrator tests mock the
 *         voter, the voter tests mock the orchestrator), so neither proves the two halves compose. This
 *         suite drives inbound root messages end-to-end through `orchestrator.route` into the real voter
 *         to prove the per-token shape high-water (`lastShapeNonce`) closes the "stale gauge resurrects an
 *         outdated shape" bug: the orchestrator gate computes `_refreshShape` and the voter resolves the
 *         shape it books at from that flag, so a shape-stale message never re-shapes a downgraded token.
 */
contract UnitLeafMessageOrchestratorComposedRoute is BaseLeafVoter {
  /// @notice Root chain id the orchestrator binds to and the mocked adapter's `REMOTE_CHAIN_ID` returns.
  uint256 internal constant _ROOT_CHAIN_ID = 8453;

  /// @notice Registered root adapter; the only authenticated `route` caller. Its `REMOTE_CHAIN_ID` is mocked.
  address internal immutable _ADAPTER = makeAddr('ComposedAdapter');

  /// @notice The real orchestrator under test, wired to the real `_leafVoter` from `BaseLeafVoter`.
  LeafMessageOrchestrator internal _orchestrator;

  /**
   * @notice Deploy a real `LeafVoter`/`LeafMessageOrchestrator` pair and register the root adapter.
   * @dev The constructors are circular: the orchestrator takes the voter address, the voter takes the
   *      orchestrator address. Resolve it with CREATE address prediction — the orchestrator is the NEXT
   *      contract this test deploys after the voter, so its address is `_computeCreate(this, nonce + 1)`.
   *      Deploy the voter trusting that predicted address, then deploy the orchestrator so it lands on it.
   *      `ADAPTER_CONFIG_ROLE` is granted to `_ADAPTER_AUTHORITY` at construction, so `setAdapter` is
   *      exercised through its real authority path; the adapter's `REMOTE_CHAIN_ID` must equal `ROOT_CHAIN_ID`.
   */
  function _wireComposed() internal {
    address _predictedOrchestrator = _computeCreate(address(this), vm.getNonce(address(this)) + 1);
    _leafVoter = new LeafVoterHarness(
      _GOVERNOR,
      _CONFIG_ADMIN,
      _predictedOrchestrator,
      _RECEIPT_TOKEN,
      _GAUGE_FACTORY,
      _GAUGE_MANAGER,
      _VOTE_COOLDOWN,
      _MAX_GAUGES,
      _ADAPTER_AUTHORITY,
      _EMISSIONS_HANDLER,
      _EMERGENCY_COUNCIL
    );
    _orchestrator = new LeafMessageOrchestrator(address(_leafVoter), _ROOT_CHAIN_ID);

    // The circular deploy resolved: the orchestrator landed on the address the voter was told to trust.
    assertEq(address(_orchestrator), _predictedOrchestrator);
    assertEq(address(_leafVoter.ORCHESTRATOR()), address(_orchestrator));

    vm.mockCall(_ADAPTER, abi.encodeCall(IMessageAdapter.REMOTE_CHAIN_ID, ()), abi.encode(_ROOT_CHAIN_ID));
    vm.prank(_ADAPTER_AUTHORITY);
    _orchestrator.setAdapter(IMessageAdapter(_ADAPTER));
  }

  /**
   * @notice Build an `AllocateChain` route payload carrying `_snapshot` and a budget delta.
   * @param _nonce Inbound chain nonce.
   * @param _tokenId Token the allocation targets.
   * @param _delta Chain budget delta added on this leaf.
   * @param _snapshot VE shape carried by the message.
   * @return _payload Encoded route payload.
   */
  function _chainPayload(
    uint256 _nonce,
    uint256 _tokenId,
    uint128 _delta,
    IVoterCommon.TokenSnapshot memory _snapshot
  ) internal view returns (bytes memory _payload) {
    _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateChain),
      _nonce,
      uint48(block.timestamp),
      abi.encode(
        IVoterCommon.AllocateChainMessage({
          tokenId: _tokenId, allocationDelta: _delta, emissionsPerVP: 0, snapshot: _snapshot
        })
      )
    );
  }

  /**
   * @notice Build an `AllocateGauge` route payload carrying `_snapshot` and a gauge distribution.
   * @param _nonce Inbound chain nonce.
   * @param _tokenId Token the distribution targets.
   * @param _snapshot VE shape carried by the message.
   * @param _allocations Per-gauge distribution.
   * @return _payload Encoded route payload.
   */
  function _gaugePayload(
    uint256 _nonce,
    uint256 _tokenId,
    IVoterCommon.TokenSnapshot memory _snapshot,
    IVoterCommon.GaugeAllocation[] memory _allocations
  ) internal view returns (bytes memory _payload) {
    _payload = abi.encodePacked(
      uint8(IMessageOrchestrator.MessageType.AllocateGauge),
      _nonce,
      uint48(block.timestamp),
      abi.encode(
        IVoterCommon.AllocateGaugeMessage({
          tokenId: _tokenId,
          expiry: uint48(block.timestamp),
          emissionsPerVP: 0,
          tokenSnapshot: _snapshot,
          allocations: _allocations
        })
      )
    );
  }

  function test_WhenAShapeStaleGaugeVoteFollowsAHigherNonceChainAllocation() external {
    // it should book the gauge at the live decaying shape and not resurrect the stale permanent shape
    _wireComposed();

    uint256 _highNonce = 10;
    uint256 _lowNonce = 5;
    uint128 _maxtime = uint128(MAXTIME);
    // Floor the amount at MAXTIME so the decaying slope (`amount / MAXTIME`) is non-zero and really booked.
    uint128 _budget = 10 * _maxtime;

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _stakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;

    _mockRegisterGauge(_GAUGE_A, true);

    // 1) HIGH-nonce chain allocation carrying a DECAYING shape: sets the live shape and seeds the budget.
    IVoterCommon.TokenSnapshot memory _decaying =
      IVoterCommon.TokenSnapshot({staked: _budget, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0});
    vm.prank(_ADAPTER);
    _orchestrator.route(_ROOT_CHAIN_ID, _chainPayload(_highNonce, _TOKEN_ID, _budget, _decaying));

    // The chain message advanced the shape high-water but NOT the token-vote high-water, so a later
    // lower-nonce gauge is token-fresh yet shape-stale — the exact window the bug lived in.
    assertEq(_orchestrator.lastShapeNonce(_TOKEN_ID), _highNonce);
    assertEq(_orchestrator.lastTokenIdVoteNonce(_TOKEN_ID), 0);

    // 2) LOW-nonce gauge vote carrying a PERMANENT shape (stakeEnd 0) and the full allocation.
    address[] memory _gauges = new address[](1);
    _gauges[0] = _GAUGE_A;
    uint128[] memory _amounts = new uint128[](1);
    _amounts[0] = _budget;
    IVoterCommon.TokenSnapshot memory _permanent =
      IVoterCommon.TokenSnapshot({staked: _budget, stakeEnd: 0, isPermanent: (0) == 0});
    vm.prank(_ADAPTER);
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload(_lowNonce, _TOKEN_ID, _permanent, _list(_gauges, _amounts)));

    // The stale gauge advanced the token-vote high-water but never the shape high-water.
    assertEq(_orchestrator.lastTokenIdVoteNonce(_TOKEN_ID), _lowNonce);
    assertEq(_orchestrator.lastShapeNonce(_TOKEN_ID), _highNonce);

    // The gauge is booked at the DECAYING shape, not the permanent shape the stale message carried. Under
    // the bug the point would carry `permanentStakeBalance == _budget` and `bias == 0`; here it is the
    // reverse — zero permanent VP and a positive decaying bias/slope.
    int128 _expectedSlope = int128(_budget / _maxtime);
    int128 _expectedBias = _expectedSlope * int128(uint128(_stakeEnd - _settledAt));
    IVoterCommon.Point memory _point = _gaugeStateOf(_GAUGE_A).point;
    assertEq(_point.permanentStakeBalance, 0);
    assertTrue(_point.bias > 0);
    assertEq(_point.bias, _expectedBias);
    assertEq(_point.slope, _expectedSlope);

    // The real voter stored the allocation and added the gauge to the token's voted set.
    assertEq(_leafVoter.allocations(_TOKEN_ID, _GAUGE_A), _budget);
    assertTrue(_inVotedSet(_GAUGE_A));

    // The budget the chain message parked on ZERO_GAUGE was fully unwound by the gauge distribution.
    IVoterCommon.Point memory _zero = _gaugeStateOf(_ZERO_GAUGE).point;
    assertEq(_zero.bias, 0);
    assertEq(_zero.slope, 0);
    assertEq(_zero.permanentStakeBalance, 0);
  }

  function test_WhenAnOlderChainAllocationFollowsAHigherNonceGaugeShape() external {
    // it should park the chain delta at the live shape without reshaping it
    _wireComposed();

    uint256 _highNonce = 10;
    uint256 _lowNonce = 5;
    uint128 _maxtime = uint128(MAXTIME);
    // Floor the amount at MAXTIME so the decaying slope is non-zero.
    uint128 _budget = 7 * _maxtime;

    uint48 _settledAt = _leafVoter.lastSettlement();
    uint48 _stakeEnd = _nextWeekBoundary(_settledAt) + 52 * _WEEK;

    // 1) HIGH-nonce EMPTY gauge vote carrying a DECAYING shape: advances the shape high-water and adopts
    //    the decaying shape as the token's live shape.
    IVoterCommon.TokenSnapshot memory _decaying =
      IVoterCommon.TokenSnapshot({staked: _budget, stakeEnd: _stakeEnd, isPermanent: (_stakeEnd) == 0});
    IVoterCommon.GaugeAllocation[] memory _empty = new IVoterCommon.GaugeAllocation[](0);
    vm.prank(_ADAPTER);
    _orchestrator.route(_ROOT_CHAIN_ID, _gaugePayload(_highNonce, _TOKEN_ID, _decaying, _empty));

    assertEq(_orchestrator.lastShapeNonce(_TOKEN_ID), _highNonce);

    // 2) LOW-nonce chain allocation carrying a PERMANENT shape and a positive delta: shape-stale.
    IVoterCommon.TokenSnapshot memory _permanent =
      IVoterCommon.TokenSnapshot({staked: _budget, stakeEnd: 0, isPermanent: (0) == 0});
    vm.prank(_ADAPTER);
    _orchestrator.route(_ROOT_CHAIN_ID, _chainPayload(_lowNonce, _TOKEN_ID, _budget, _permanent));

    // The stale chain message never advanced the shape high-water, and its budget landed.
    assertEq(_orchestrator.lastShapeNonce(_TOKEN_ID), _highNonce);
    assertEq(_chainAllocationOf(_TOKEN_ID), _budget);

    // The delta parked on ZERO_GAUGE at the live DECAYING shape, not the permanent shape the stale message
    // carried. Under the bug the ZERO_GAUGE point would carry `permanentStakeBalance == _budget` and
    // `bias == 0`; here it is the reverse.
    int128 _expectedSlope = int128(_budget / _maxtime);
    int128 _expectedBias = _expectedSlope * int128(uint128(_stakeEnd - _settledAt));
    IVoterCommon.Point memory _zero = _gaugeStateOf(_ZERO_GAUGE).point;
    assertEq(_zero.permanentStakeBalance, 0);
    assertTrue(_zero.bias > 0);
    assertEq(_zero.bias, _expectedBias);
    assertEq(_zero.slope, _expectedSlope);
  }
}
