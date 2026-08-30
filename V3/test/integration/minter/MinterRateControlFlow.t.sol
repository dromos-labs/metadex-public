// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {IMinter} from 'V3/interfaces/minter/IMinter.sol';
import {MAX_PIPS, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {Minter} from 'V3/minter/Minter.sol';

import {IntegrationFixture} from 'V3-test/integration/IntegrationFixture.sol';

/// @notice Integration coverage for repeated Minter base rate updates.
contract IntegrationMinterRateControlFlow is IntegrationFixture {
  uint232 internal constant _INITIAL_BASE_RATE = 100 ether;
  uint24 internal constant _MAX_WEEKLY_RATE_CHANGE_PIPS = 50_000;
  uint24 internal constant _WEEKLY_LOG_BUDGET_PIPS = 48_790;
  uint48 internal constant _MIN_BASE_RATE_UPDATE_COOLDOWN = 1 hours;
  uint48 internal constant _MAX_BASE_RATE_UPDATE_COOLDOWN = 1 weeks;
  uint24 internal constant _MAX_BAND_PIPS = 250_000;

  /// @notice Fuzzes every allowed cooldown and bounds compounded growth over an open weekly window.
  function test_BaseRateUpdatesStayWithinWeeklyCompoundingBound(uint48 _cooldown) public {
    _cooldown = uint48(bound(_cooldown, _MIN_BASE_RATE_UPDATE_COOLDOWN, _MAX_BASE_RATE_UPDATE_COOLDOWN));

    uint256 _updatesPerWeek = (WEEK - 1) / _cooldown + 1;
    uint24 _maxBaseRateChangePips =
      _updatesPerWeek == 1 ? _MAX_WEEKLY_RATE_CHANGE_PIPS : uint24(uint256(_WEEKLY_LOG_BUDGET_PIPS) / _updatesPerWeek);
    address _operator = _createActor('Operator');
    Minter _minter = _deployMinter(_operator, _cooldown, _maxBaseRateChangePips);

    vm.warp(_minter.ACTIVATION_TIMESTAMP());
    uint256 _windowStart = block.timestamp;

    for (uint256 i; i < _updatesPerWeek; ++i) {
      uint232 _oldRate = _minter.baseRate();
      uint232 _maxDelta = uint232(Math.mulDiv(_oldRate, _maxBaseRateChangePips, MAX_PIPS, Math.Rounding.Ceil));

      vm.prank(_operator);
      _minter.setBaseRate(_oldRate + _maxDelta);

      if (i + 1 < _updatesPerWeek) vm.warp(_minter.nextBaseRateUpdate());
    }

    uint232 _finalRate = _minter.baseRate();
    assertLt(block.timestamp, _windowStart + WEEK);
    assertLe(_finalRate, 105 ether);
    assertEq(_minter.emissionRate(), _finalRate);
  }

  function _deployMinter(
    address _operator,
    uint48 _cooldown,
    uint24 _maxBaseRateChangePips
  ) internal returns (Minter _minter) {
    uint48 _migrationOpen = uint48((block.timestamp / WEEK + 1) * WEEK);

    _minter = new Minter(
      IMinter.ConstructorParams({
        token: _createActor('Token'),
        voter: _createActor('Voter'),
        splitter: _createActor('Splitter'),
        operator: _operator,
        migrationOpen: _migrationOpen,
        initialBaseRate: _INITIAL_BASE_RATE,
        maxBaseRateChangePips: _maxBaseRateChangePips,
        baseRateUpdateCooldown: _cooldown,
        teamRate: 0,
        maxBaseRateChangePipsCap: _MAX_WEEKLY_RATE_CHANGE_PIPS,
        minBaseRateUpdateCooldown: _MIN_BASE_RATE_UPDATE_COOLDOWN,
        maxBaseRateUpdateCooldown: _MAX_BASE_RATE_UPDATE_COOLDOWN,
        maxBandFloorPips: _MAX_BAND_PIPS,
        maxBandCeilingPips: _MAX_BAND_PIPS
      })
    );
  }
}
