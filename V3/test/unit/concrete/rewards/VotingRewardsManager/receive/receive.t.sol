// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingRewardsManager} from 'V3/interfaces/rewards/IVotingRewardsManager.sol';

import {UnitVotingRewardsManager} from 'V3-test/unit/concrete/rewards/VotingRewardsManager/VotingRewardsManager.t.sol';

contract UnitVotingRewardsManagerReceive is UnitVotingRewardsManager {
  function test_WhenTheSenderIsNotTheWrappedNative(address _sender, uint256 _amount) external {
    _assumeFuzzable(_sender);
    vm.assume(_sender != address(_weth));
    _amount = bound(_amount, 1, 100 ether);
    vm.deal(_sender, _amount);

    // it should revert with NotWrappedNative
    vm.prank(_sender);
    (bool _success, bytes memory _returnData) = address(votingRewardsManager).call{value: _amount}('');
    assertFalse(_success);
    assertEq(bytes4(_returnData), IVotingRewardsManager.NotWrappedNative.selector);
  }

  function test_WhenTheSenderIsTheWrappedNative(uint256 _amount) external {
    _amount = bound(_amount, 1, 100 ether);
    vm.deal(address(_weth), _amount);

    // it should accept the native token
    vm.prank(address(_weth));
    (bool _success,) = address(votingRewardsManager).call{value: _amount}('');
    assertTrue(_success);
    assertEq(address(votingRewardsManager).balance, _amount);
  }
}
