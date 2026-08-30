// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowSetApprovalForAll is BaseVotingEscrow {
  function test_WhenTheOperatorIsTheZeroAddress(address _caller) external {
    _assumeFuzzable(_caller);

    // it should revert with ERC721InvalidOperator
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidOperator.selector, address(0)));
    vm.prank(_caller);
    _ve.setApprovalForAll(address(0), true);
  }

  function test_WhenTheOperatorIsAnotherAddress(address _ownerAddr, address _operator, bool _approved) external {
    _assumeFuzzable(_ownerAddr);
    _assumeFuzzable(_operator);
    vm.assume(_ownerAddr != _operator);

    // it should emit the ApprovalForAll event
    _expectEmit(address(_ve));
    emit IERC721.ApprovalForAll(_ownerAddr, _operator, _approved);

    vm.prank(_ownerAddr);
    _ve.setApprovalForAll(_operator, _approved);

    // it should mark the operator as approved
    assertEq(_ve.isApprovedForAll(_ownerAddr, _operator), _approved);
  }
}
