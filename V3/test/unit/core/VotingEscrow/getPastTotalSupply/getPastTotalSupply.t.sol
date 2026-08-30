// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

contract UnitVotingEscrowGetPastTotalSupply is BaseVotingEscrow {
  /// @dev Current block timestamp for these tests; the seeded global point sits at 604800.
  uint48 internal constant _NOW = 604_900;

  function test_WhenTheTimestampIsAfterTheCurrentBlock(uint48 _future) external {
    vm.warp(_NOW);
    _future = uint48(bound(_future, uint256(_NOW) + 1, type(uint48).max));

    // it should revert with FutureLookup
    vm.expectRevert(abi.encodeWithSelector(IVotingEscrow.FutureLookup.selector, uint256(_future), _NOW));
    _ve.getPastTotalSupply(_future);
  }

  function test_WhenTheTimestampIsAtOrBeforeTheCurrentBlock() external {
    // Seed one global point (bias 6000, slope 3, ts 604800, permanent 1000). At t=604900 the decayed bias is
    // 6000 - 3*(604900-604800) = 5700, plus the 1000 permanent balance = 6700 (independent hand calculation).
    vm.warp(_NOW);
    _setEpoch(1);
    _setPointHistory(1, 6000, 3, 604_800, 1000);

    // it should return the total supply at the timestamp
    assertEq(_ve.getPastTotalSupply(_NOW), 6700);
  }
}
