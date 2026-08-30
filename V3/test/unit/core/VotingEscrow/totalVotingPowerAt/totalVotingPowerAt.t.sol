// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowTotalVotingPowerAt is BaseVotingEscrow {
  /// @dev Current block timestamp for these tests; the seeded global point sits at 604800.
  uint48 internal constant _NOW = 604_900;

  function test_WhenTheTimestampIsAfterTheCurrentBlock(uint48 _future) external {
    vm.warp(_NOW);
    _future = uint48(bound(_future, uint256(_NOW) + 1, type(uint48).max));

    // it should revert with FutureLookup
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.FutureLookup.selector, uint256(_future), _NOW));
    _ve.totalVotingPowerAt(_future);
  }

  function test_WhenTheGlobalCurveIsSeeded() external {
    // Same seed as totalVotingPower. Query at t=604900: 6000 - 3*(604900-604800) + 1000 = 6700.
    vm.warp(_NOW);
    _setEpoch(1);
    _setPointHistory(1, 6000, 3, 604_800, 1000);

    // it should return the decayed bias plus permanent balance at the timestamp
    assertEq(_ve.totalVotingPowerAt(_NOW), 6700);
    // it should match getPastTotalSupply at the timestamp
    assertEq(_ve.totalVotingPowerAt(_NOW), _ve.getPastTotalSupply(_NOW));
  }
}
