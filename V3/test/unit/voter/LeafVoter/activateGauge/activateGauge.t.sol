// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

contract UnitLeafVoterActivateGauge is BaseLeafVoter {
  /// @dev Upper bound for the fuzzed chain rate and index seeds.
  uint256 internal constant _MAX_INDEX = 1e24;

  /// @dev Upper bound for the fuzzed chain rate in the weighted settle test,
  ///      held so the settled share stays within uint128.
  uint256 internal constant _MAX_RATE = 1e18;

  /// @dev Seed `_gauge` as registered and inactive with a permanent stake of
  ///      `_permanentStakeBalance`, anchored at `_cursor`.
  function _seedInactiveGauge(
    address _gauge,
    uint48 _cursor,
    uint256 _lastIndex,
    uint128 _permanentStakeBalance
  ) internal {
    _mockGaugeState(
      _gauge,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _cursor,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: _lastIndex,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _cursor, _permanentStakeBalance: _permanentStakeBalance})
      })
    );
  }

  function test_WhenTheCallerIsNotTheGaugeManager(address _caller, address _gauge) external {
    _caller = _boundNotEq(_caller, _GAUGE_MANAGER);

    // it should revert with NotGaugeManager
    vm.expectRevert(ILeafVoter.NotGaugeManager.selector);
    vm.prank(_caller);
    _leafVoter.activateGauge(_gauge);
  }

  modifier whenTheCallerIsTheGaugeManager() {
    vm.startPrank(_GAUGE_MANAGER);
    _;
    vm.stopPrank();
  }

  function test_WhenTheGaugeIsNotRegistered(address _gauge) external whenTheCallerIsTheGaugeManager {
    _assumeFuzzable(_gauge);

    // it should revert with GaugeNotRegistered
    vm.expectRevert(ILeafVoter.GaugeNotRegistered.selector);
    _leafVoter.activateGauge(_gauge);
  }

  function test_WhenTheGaugeIsTheZeroGauge() external whenTheCallerIsTheGaugeManager {
    // The constructor registers the sink, but the zero gauge is never activatable.
    // it should revert with GaugeNotRegistered
    vm.expectRevert(ILeafVoter.GaugeNotRegistered.selector);
    _leafVoter.activateGauge(_ZERO_GAUGE);
  }

  function test_WhenTheGaugeIsAlreadyActivated(address _gauge) external whenTheCallerIsTheGaugeManager {
    _assumeFuzzable(_gauge);
    ILeafVoter.GaugeState memory _state = _buildGaugeState({
      _ceiling: 0,
      _claimed: 0,
      _lastSettlement: _SEED_TIMESTAMP,
      _isRegistered: true,
      _surplus: 0,
      _lastIndex: 0,
      _point: _buildPoint({_bias: 0, _slope: 0, _ts: _SEED_TIMESTAMP, _permanentStakeBalance: 0})
    });
    _state.isActivated = true;
    _mockGaugeState(_gauge, _state);

    // it should revert with GaugeAlreadyActivated
    vm.expectRevert(ILeafVoter.GaugeAlreadyActivated.selector);
    _leafVoter.activateGauge(_gauge);
  }

  modifier whenTheGaugeIsRegisteredAndInactive() {
    _;
  }

  function test_WhenTheChainCursorLagsTheCurrentTimestamp(
    address _gauge,
    uint256 _rateRaw,
    uint256 _indexRaw,
    uint48 _aheadRaw
  ) external whenTheCallerIsTheGaugeManager whenTheGaugeIsRegisteredAndInactive {
    _assumeFuzzable(_gauge);
    vm.assume(_gauge != _GAUGE_FACTORY);
    uint256 _seedIndex = bound(_indexRaw, 0, _MAX_INDEX);
    _seedInactiveGauge(_gauge, _SEED_TIMESTAMP, _seedIndex, 0);

    // Held under the next weekly boundary so the settle walk stays a single segment.
    // Weight equal to PRECISION makes the expected advance exactly rate times duration.
    uint48 _ahead = uint48(bound(_aheadRaw, 1 hours, 2 days));
    uint256 _rate = bound(_rateRaw, 1, _MAX_INDEX);
    _mockChainAccumulator({_emissionsPerVP: _rate, _index: _seedIndex});
    _mockEmissionCap(_gauge, type(uint128).max);

    uint48 _now = _SEED_TIMESTAMP + _ahead;
    vm.warp(_now);

    _leafVoter.activateGauge(_gauge);

    // it should settle the chain index to the current timestamp
    uint256 _expectedIndex = _seedIndex + _rate * _ahead;
    assertEq(_leafVoter.lastSettlement(), _now);
    assertEq(_leafVoter.index(), _expectedIndex);

    // it should advance the gauge cursor to the settled chain cursor
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    assertEq(_state.lastSettlement, _now);
    assertEq(_state.lastIndex, _expectedIndex);
    assertEq(_state.point.ts, _now);
    assertTrue(_state.isActivated);
  }

  function test_WhenTheChainWasPreSettledPastTheCurrentTimestamp(
    address _gauge,
    uint256 _indexRaw,
    uint48 _aheadRaw
  ) external whenTheCallerIsTheGaugeManager whenTheGaugeIsRegisteredAndInactive {
    _assumeFuzzable(_gauge);
    vm.assume(_gauge != _GAUGE_FACTORY);
    _seedInactiveGauge(_gauge, _SEED_TIMESTAMP, 0, 0);

    // A prior message settled the chain past block.timestamp, so _settleIndex no-ops.
    uint48 _preSettled = _SEED_TIMESTAMP + uint48(bound(_aheadRaw, 1, 2 days));
    uint256 _seedIndex = bound(_indexRaw, 0, _MAX_INDEX);
    _mockChainSettlement(_preSettled);
    _mockChainAccumulator({_emissionsPerVP: 1, _index: _seedIndex});
    _mockEmissionCap(_gauge, type(uint128).max);

    _leafVoter.activateGauge(_gauge);

    // it should advance the gauge cursor to the existing logical cursor
    assertEq(_leafVoter.lastSettlement(), _preSettled);
    assertEq(_leafVoter.index(), _seedIndex);
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    assertEq(_state.lastSettlement, _preSettled);
    assertEq(_state.lastIndex, _seedIndex);
    assertEq(_state.point.ts, _preSettled);
    assertTrue(_state.isActivated);
  }

  function test_WhenTheInactiveGaugeCarriesWeight(
    address _gauge,
    uint256 _rateRaw,
    uint48 _aheadRaw
  ) external whenTheCallerIsTheGaugeManager whenTheGaugeIsRegisteredAndInactive {
    _assumeFuzzable(_gauge);
    vm.assume(_gauge != _GAUGE_FACTORY);

    // A permanent stake equal to PRECISION makes the settled share exactly
    // rate times duration: indexDelta = rate * ahead * PRECISION / PRECISION,
    // share = indexDelta * PRECISION / PRECISION.
    _seedInactiveGauge(_gauge, _SEED_TIMESTAMP, 0, uint128(_PRECISION));

    // Held under the next weekly boundary so the settle walk stays a single segment.
    uint48 _ahead = uint48(bound(_aheadRaw, 1 hours, 2 days));
    uint256 _rate = bound(_rateRaw, 1, _MAX_RATE);
    _mockChainAccumulator({_emissionsPerVP: _rate, _index: 0});
    _mockEmissionCap(_gauge, type(uint128).max);

    uint48 _now = _SEED_TIMESTAMP + _ahead;
    vm.warp(_now);

    uint128 _expectedShare = uint128(_rate * _ahead);

    _leafVoter.activateGauge(_gauge);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    // it should credit the settled share to the gauge ceiling
    assertEq(_state.ceiling, _expectedShare);
    // it should set the activation flag
    assertTrue(_state.isActivated);
  }

  function test_WhenTheGaugeCarriesNoWeight(address _gauge)
    external
    whenTheCallerIsTheGaugeManager
    whenTheGaugeIsRegisteredAndInactive
  {
    _assumeFuzzable(_gauge);
    vm.assume(_gauge != _GAUGE_FACTORY);
    _seedInactiveGauge(_gauge, _SEED_TIMESTAMP, 0, 0);

    // Wire a rewards contract so a regression that checkpoints on activation
    // would reach it and fail the count zero expectation.
    _mockGaugeRewards(_gauge, _REWARD_A);

    // it should not checkpoint a reward
    vm.expectCall(_REWARD_A, abi.encodeWithSelector(IVotingRewardsManager.checkpoint.selector), 0);

    // it should emit GaugeActivated with the activation cursor
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugeActivated(_gauge, _SEED_TIMESTAMP);

    _leafVoter.activateGauge(_gauge);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    // it should set the activation flag
    assertTrue(_state.isActivated);
    // it should not create emission ceiling
    assertEq(_state.ceiling, 0);
  }
}
