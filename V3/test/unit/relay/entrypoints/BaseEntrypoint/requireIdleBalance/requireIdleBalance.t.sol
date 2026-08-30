// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseEntrypoints} from 'V3-test/unit/relay/entrypoints/BaseEntrypoints.sol';
import {BaseEntrypointHarness} from 'V3-test/unit/relay/entrypoints/harnesses/BaseEntrypointHarness.sol';

import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IBaseEntrypoint} from 'V3/interfaces/relay/entrypoints/IBaseEntrypoint.sol';

/// @notice Unit tests for `BaseEntrypoint._requireIdleBalance` (through the harness): the read
///         behind every swap-free path. It measures what the Relay can still spend, which is its
///         balance minus the part already owed to claimants, and refuses an empty result.
contract UnitBaseEntrypointRequireIdleBalance is BaseEntrypoints {
  BaseEntrypointHarness internal _harness;

  function setUp() public override {
    super.setUp();
    _harness = new BaseEntrypointHarness(IFactoryRegistry(_factoryRegistry));
  }

  /// @notice Every unit of the balance is already promised to claimants, so there is nothing idle.
  function test_WhenTheWholeBalanceIsOwedToClaimants(uint256 _balance) external {
    _mockIdleBalance(_relayAddr, _tokenIn, _balance, _balance);

    // it should revert with NoIdleBalance
    vm.expectRevert(IBaseEntrypoint.NoIdleBalance.selector);
    _harness.requireIdleBalance(_relayAddr, _tokenIn);
  }

  /// @notice What the path may process is the surplus over the accounted part, never the whole balance.
  function test_WhenTheRelayHoldsMoreThanItOwes(uint256 _balance, uint256 _accounted) external {
    _balance = bound(_balance, 1, type(uint128).max);
    _accounted = bound(_accounted, 0, _balance - 1);
    _mockIdleBalance(_relayAddr, _tokenIn, _balance, _accounted);

    uint256 _amount = _harness.requireIdleBalance(_relayAddr, _tokenIn);

    // it should return the unaccounted part
    assertEq(_amount, _balance - _accounted);
  }

  /// @notice The Relay's own invariant is `balanceOf >= accountedBalance`; a break underflows here
  ///         rather than handing out an amount the Relay would refuse.
  function test_RevertWhen_TheAccountedAmountExceedsTheBalance(uint256 _balance, uint256 _accounted) external {
    _balance = bound(_balance, 0, type(uint128).max);
    _accounted = bound(_accounted, _balance + 1, type(uint256).max);
    _mockIdleBalance(_relayAddr, _tokenIn, _balance, _accounted);

    // it should revert
    vm.expectRevert();
    _harness.requireIdleBalance(_relayAddr, _tokenIn);
  }
}
