// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseRelay} from 'V3-test/unit/relay/BaseRelay.sol';

import {IWETH} from 'V3/interfaces/external/IWETH.sol';

/// @notice The Relay wraps every native inflow. A root reward claim pays the Relay itself and the
///         VotingRewardsManager unwraps a wrapped-native payout, so the Relay has to take native
///         and turn it back into the ERC-20 balance the reward lanes account.
contract UnitRelayWrappedNative is BaseRelay {
  function setUp() public override {
    super.setUp();
    _deployMaxi(true);
  }

  /// @notice Any sender's native inflow is wrapped, not held.
  function test_WhenTheRelayReceivesNative(address _sender, uint256 _amount) external {
    _assumeFreshHolder(_sender);
    _amount = bound(_amount, 1, 100 ether);

    // it should wrap the whole inflow into the wrapped native
    _mockAndExpect(_weth, abi.encodeCall(IWETH.deposit, ()), '');

    hoax(_sender, _amount);
    // solhint-disable-next-line avoid-low-level-calls
    (bool _success,) = address(_relay).call{value: _amount}('');
    assertTrue(_success);

    // it should keep no native balance
    assertEq(address(_relay).balance, 0);
    assertEq(_weth.balance, _amount);
  }
}
