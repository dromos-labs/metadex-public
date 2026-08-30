// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowIsAuthorizedVPMForToken is BaseVotingEscrow {
  function test_WhenTheVpmHoldsTheVpmRoleAndTheOwnerApprovedIt(
    address _otherVpm,
    address _ownerAddr,
    uint256 _tokenId
  ) external {
    _assumeFuzzable(_otherVpm);
    _assumeFuzzable(_ownerAddr);
    vm.assume(_ownerAddr != _otherVpm);
    bytes32 _vpmRole = _ve.VPM_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _otherVpm);

    _setOwner(_tokenId, _ownerAddr);
    vm.prank(_ownerAddr);
    _ve.setApprovalForAll(_otherVpm, true);

    // it should return true
    assertTrue(_ve.isAuthorizedVPMForToken(_otherVpm, _tokenId));
  }

  function test_WhenTheVpmHoldsTheVpmRoleButTheOwnerHasNotApprovedIt(
    address _otherVpm,
    address _ownerAddr,
    uint256 _tokenId
  ) external {
    _assumeFuzzable(_otherVpm);
    _assumeFuzzable(_ownerAddr);
    vm.assume(_ownerAddr != _otherVpm);
    bytes32 _vpmRole = _ve.VPM_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _otherVpm);

    _setOwner(_tokenId, _ownerAddr);

    // it should return false
    assertFalse(_ve.isAuthorizedVPMForToken(_otherVpm, _tokenId));
  }

  function test_WhenTheVpmDoesNotHoldTheVpmRole(address _otherVpm, uint256 _tokenId) external view {
    _assumeFuzzable(_otherVpm);

    // it should return false
    assertFalse(_ve.isAuthorizedVPMForToken(_otherVpm, _tokenId));
  }

  function test_WhenTheTokenIdHasNotBeenMinted(address _otherVpm, uint256 _tokenId) external {
    _assumeFuzzable(_otherVpm);
    bytes32 _vpmRole = _ve.VPM_ROLE();
    vm.prank(_vpmAdmin);
    _ve.grantRole(_vpmRole, _otherVpm);

    // _tokenId has no owner (no _setOwner call); ownerOf would revert.
    // it should return false without reverting
    assertFalse(_ve.isAuthorizedVPMForToken(_otherVpm, _tokenId));
  }
}
