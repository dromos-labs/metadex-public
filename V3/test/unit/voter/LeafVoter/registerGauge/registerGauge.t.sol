// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Vm} from 'forge-std/Vm.sol';

import {BaseLeafVoter} from 'V3-test/unit/voter/BaseLeafVoter.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoterCommon} from 'V3/interfaces/voter/IVoterCommon.sol';

contract UnitLeafVoterRegisterGauge is BaseLeafVoter {
  /// @dev Upper bound for the fuzzed chain rate and index seeds.
  uint256 internal constant _MAX_INDEX = 1e24;

  /// @dev Seed the chain accumulator with `_weight` equal to PRECISION so the index
  ///      advance over a lagging window is exactly `rate * duration`, a hand model
  ///      independent of the contract's normalization.
  function _seedLaggingChain(uint256 _rate, uint256 _index) internal {
    _mockChainAccumulator({_emissionsPerVP: _rate, _index: _index});
  }

  function test_WhenTheCallerIsNotTheGaugeManager(address _caller, address _gauge) external {
    _caller = _boundNotEq(_caller, _GAUGE_MANAGER);

    // it should revert with NotGaugeManager
    vm.expectRevert(ILeafVoter.NotGaugeManager.selector);
    vm.prank(_caller);
    _leafVoter.registerGauge(_gauge, false);
  }

  modifier whenTheCallerIsTheGaugeManager() {
    vm.startPrank(_GAUGE_MANAGER);
    _;
    vm.stopPrank();
  }

  function test_WhenTheGaugeIsTheZeroAddress() external whenTheCallerIsTheGaugeManager {
    // The zero address is also the constructor-registered ZERO_GAUGE, but the
    // zero check fires before the registration check.
    // it should revert with ZeroAddress
    vm.expectRevert(IVoterCommon.ZeroAddress.selector);
    _leafVoter.registerGauge(address(0), false);
  }

  function test_WhenTheGaugeIsAlreadyRegistered(address _gauge) external whenTheCallerIsTheGaugeManager {
    _assumeFuzzable(_gauge);
    _mockGaugeState(
      _gauge,
      _buildGaugeState({
        _ceiling: 0,
        _claimed: 0,
        _lastSettlement: _SEED_TIMESTAMP,
        _isRegistered: true,
        _surplus: 0,
        _lastIndex: 0,
        _point: _buildPoint({_bias: 0, _slope: 0, _ts: _SEED_TIMESTAMP, _permanentStakeBalance: 0})
      })
    );

    // it should revert with GaugeAlreadyRegistered
    vm.expectRevert(ILeafVoter.GaugeAlreadyRegistered.selector);
    _leafVoter.registerGauge(_gauge, false);
  }

  modifier whenTheGaugeIsNotRegistered() {
    _;
  }

  function test_WhenTheChainCursorLagsTheCurrentTimestamp(
    address _gauge,
    uint256 _rateRaw,
    uint256 _indexRaw,
    uint48 _aheadRaw
  ) external whenTheCallerIsTheGaugeManager whenTheGaugeIsNotRegistered {
    _assumeFuzzable(_gauge);
    // Held under the next weekly boundary so the settle walk stays a single segment.
    uint48 _ahead = uint48(bound(_aheadRaw, 1 hours, 2 days));
    uint256 _rate = bound(_rateRaw, 1, _MAX_INDEX);
    uint256 _seedIndex = bound(_indexRaw, 0, _MAX_INDEX);
    _seedLaggingChain(_rate, _seedIndex);

    uint48 _now = _SEED_TIMESTAMP + _ahead;
    vm.warp(_now);

    _leafVoter.registerGauge(_gauge, false);

    // it should settle the chain index to the current timestamp
    uint256 _expectedIndex = _seedIndex + _rate * _ahead;
    assertEq(_leafVoter.lastSettlement(), _now);
    assertEq(_leafVoter.index(), _expectedIndex);

    // it should seed the gauge cursor from the settled chain cursor
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    assertTrue(_state.isRegistered);
    assertEq(_state.lastSettlement, _now);
    assertEq(_state.lastIndex, _expectedIndex);
    assertEq(_state.point.ts, _now);
  }

  function test_WhenTheChainWasPreSettledPastTheCurrentTimestamp(
    address _gauge,
    uint256 _indexRaw,
    uint48 _aheadRaw
  ) external whenTheCallerIsTheGaugeManager whenTheGaugeIsNotRegistered {
    _assumeFuzzable(_gauge);
    // A prior message settled the chain past block.timestamp, so _settleIndex no-ops.
    uint48 _preSettled = _SEED_TIMESTAMP + uint48(bound(_aheadRaw, 1, 2 days));
    uint256 _seedIndex = bound(_indexRaw, 0, _MAX_INDEX);
    _mockChainSettlement(_preSettled);
    _mockChainAccumulator({_emissionsPerVP: 1, _index: _seedIndex});

    _leafVoter.registerGauge(_gauge, false);

    // it should keep the pre settled chain cursor
    assertEq(_leafVoter.lastSettlement(), _preSettled);
    assertEq(_leafVoter.index(), _seedIndex);

    // it should seed the gauge cursor from the existing logical cursor
    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    assertTrue(_state.isRegistered);
    assertEq(_state.lastSettlement, _preSettled);
    assertEq(_state.lastIndex, _seedIndex);
    assertEq(_state.point.ts, _preSettled);
  }

  function test_WhenTheRegistrationActivatesTheGauge(address _gauge)
    external
    whenTheCallerIsTheGaugeManager
    whenTheGaugeIsNotRegistered
  {
    _assumeFuzzable(_gauge);

    // it should emit GaugeRegistered with the settlement cursor
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugeRegistered(_gauge, true, _SEED_TIMESTAMP);

    // it should emit GaugeActivated with the settlement cursor
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugeActivated(_gauge, _SEED_TIMESTAMP);

    _leafVoter.registerGauge(_gauge, true);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    // it should mark the gauge registered
    assertTrue(_state.isRegistered);
    // it should set the activation flag
    assertTrue(_state.isActivated);
  }

  function test_WhenTheRegistrationLeavesTheGaugeInactive(address _gauge)
    external
    whenTheCallerIsTheGaugeManager
    whenTheGaugeIsNotRegistered
  {
    _assumeFuzzable(_gauge);

    // it should emit GaugeRegistered with the settlement cursor
    _expectEmit(address(_leafVoter));
    emit ILeafVoter.GaugeRegistered(_gauge, false, _SEED_TIMESTAMP);

    vm.recordLogs();
    _leafVoter.registerGauge(_gauge, false);

    ILeafVoter.GaugeState memory _state = _gaugeStateOf(_gauge);
    // it should mark the gauge registered
    assertTrue(_state.isRegistered);
    // it should leave the activation flag unset
    assertFalse(_state.isActivated);

    // it should not emit GaugeActivated
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertNotEq(_logs[_i].topics[0], ILeafVoter.GaugeActivated.selector);
    }
  }
}
