// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowTotalSupply is BaseVotingEscrow {
  function test_WhenTokensHaveBeenMinted(uint128 _value, uint8 _count) external {
    // Enumerable totalSupply tracks the live NFT count (ERC721Enumerable `_allTokens.length`), so drive real
    // mints for the array to populate. Cap the per-stake value so the aggregate supply cannot overflow uint128.
    _value = uint128(bound(_value, 1, uint128(type(int128).max) / 5));
    uint256 _minted = bound(_count, 1, 5);
    _mockTransferFrom(_owner, address(_ve), _value);
    for (uint256 _i; _i < _minted; ++_i) {
      vm.prank(_owner);
      _ve.createStake(_value, 0, true);
    }

    // it should return the live minted token count
    assertEq(_ve.totalSupply(), _minted);
  }
}
