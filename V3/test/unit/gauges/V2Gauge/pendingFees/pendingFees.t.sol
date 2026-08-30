// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

import {UnitV2Gauge} from 'V3-test/unit/gauges/V2Gauge.t.sol';

contract UnitV2GaugePendingFees is UnitV2Gauge {
  function test_WhenTheGaugeIsNotAPool() external {
    _gauge = _newGauge(false);

    (uint256 _amount0, uint256 _amount1) = _gauge.pendingFees();

    // it should return zero amounts
    assertEq(_amount0, 0);
    assertEq(_amount1, 0);
  }

  function test_WhenTheEmissionCapIsZero() external {
    _expectActivation(true);
    _expectEmissionCap(0);

    (uint256 _amount0, uint256 _amount1) = _gauge.pendingFees();

    // it should return zero amounts
    assertEq(_amount0, 0);
    assertEq(_amount1, 0);
  }

  function test_WhenTheGaugeIsNotActivated() external {
    _expectActivation(false);

    (uint256 _amount0, uint256 _amount1) = _gauge.pendingFees();

    // it should return zero amounts
    assertEq(_amount0, 0);
    assertEq(_amount1, 0);
  }

  function test_WhenThePoolHasNoPendingFees() external {
    _expectActivation(true);
    _expectEmissionCap(1);
    _expectPoolPendingFees(0, 0);

    (uint256 _amount0, uint256 _amount1) = _gauge.pendingFees();

    // it should return zero amounts
    assertEq(_amount0, 0);
    assertEq(_amount1, 0);
  }

  function test_WhenThePoolHasPendingFees(uint128 _pending0, uint128 _pending1, uint128 _emissionCap) external {
    _emissionCap = uint128(bound(_emissionCap, 1, type(uint128).max));
    _expectActivation(true);
    _expectEmissionCap(_emissionCap);
    _expectPoolPendingFees(_pending0, _pending1);

    (uint256 _amount0, uint256 _amount1) = _gauge.pendingFees();

    // it should return the pool pending fees
    assertEq(_amount0, _pending0);
    assertEq(_amount1, _pending1);
  }

  function testGas_pendingFees() external {
    _expectActivation(true);
    _expectEmissionCap(1);
    _expectPoolPendingFees(10e18, 20e18);

    _gauge.pendingFees();

    vm.snapshotGasLastCall('V2Gauge_pendingFees');
  }

  function _expectPoolPendingFees(uint256 _pending0, uint256 _pending1) internal {
    _mockAndExpect(
      _stakingToken, abi.encodeCall(IPool.pendingFees, (address(_gauge))), abi.encode(_pending0, _pending1)
    );
  }

  function _expectActivation(bool _isActivated) internal {
    _mockAndExpect(_voter, abi.encodeCall(ILeafVoter.isActivated, (address(_gauge))), abi.encode(_isActivated));
  }
}
