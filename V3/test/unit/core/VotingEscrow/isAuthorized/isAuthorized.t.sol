// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowIsAuthorized is BaseVotingEscrow {
  function test_WhenTheSpenderIsTheOwner(uint256 _tokenId, address _ownerAddr) external {
    _assumeFuzzable(_ownerAddr);
    _setOwner(_tokenId, _ownerAddr);

    // it should return true
    assertTrue(_ve.isAuthorized(_ownerAddr, _tokenId));
  }

  function test_WhenTheSpenderIsAnApprovedOperator(uint256 _tokenId, address _ownerAddr, address _operator) external {
    _assumeFuzzable(_ownerAddr);
    _assumeFuzzable(_operator);
    vm.assume(_ownerAddr != _operator);
    _setOwner(_tokenId, _ownerAddr);
    _setOperatorApproval(_ownerAddr, _operator, true);

    // it should return true
    assertTrue(_ve.isAuthorized(_operator, _tokenId));
  }

  function test_WhenTheSpenderIsThePerTokenApprovedAddress(
    uint256 _tokenId,
    address _ownerAddr,
    address _spender
  ) external {
    _assumeFuzzable(_ownerAddr);
    _assumeFuzzable(_spender);
    vm.assume(_ownerAddr != _spender);
    _setOwner(_tokenId, _ownerAddr);
    _setTokenApproval(_tokenId, _spender);

    // it should return true
    assertTrue(_ve.isAuthorized(_spender, _tokenId));
  }

  function test_WhenTheSpenderIsUnrelated(uint256 _tokenId, address _ownerAddr, address _spender) external {
    _assumeFuzzable(_ownerAddr);
    _assumeFuzzable(_spender);
    vm.assume(_ownerAddr != _spender);
    _setOwner(_tokenId, _ownerAddr);

    // it should return false
    assertFalse(_ve.isAuthorized(_spender, _tokenId));
  }

  function test_WhenTheTokenHasNotBeenMinted(uint256 _tokenId, address _spender) external view {
    _assumeFuzzable(_spender);
    // No _setOwner: ownerOf resolves to the zero address, so no spender is authorized.

    // it should return false
    assertFalse(_ve.isAuthorized(_spender, _tokenId));
  }
}
