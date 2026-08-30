// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

import {IVeArtProxy} from 'V3/interfaces/art/IVeArtProxy.sol';

contract UnitVotingEscrowTokenURI is BaseVotingEscrow {
  function test_WhenTheTokenHasNotBeenMinted(uint256 _tokenId) external {
    // No _setOwner: the token has no owner, so _requireOwned reverts.
    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _tokenId));
    _ve.tokenURI(_tokenId);
  }

  function test_WhenTheTokenIsOwned(uint256 _tokenId, address _ownerAddr) external {
    _assumeFuzzable(_ownerAddr);
    _setOwner(_tokenId, _ownerAddr);

    string memory _sentinel = 'data:application/json;sentinel';
    // it should return the art proxy token uri
    vm.mockCall(_artProxy, abi.encodeCall(IVeArtProxy.tokenURI, (_tokenId)), abi.encode(_sentinel));
    vm.expectCall(_artProxy, abi.encodeCall(IVeArtProxy.tokenURI, (_tokenId)));
    assertEq(_ve.tokenURI(_tokenId), _sentinel);
  }
}
