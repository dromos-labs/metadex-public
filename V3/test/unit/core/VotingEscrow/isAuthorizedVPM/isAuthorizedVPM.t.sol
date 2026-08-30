// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {BaseVotingEscrow} from 'V3-test/unit/core/BaseVotingEscrow.sol';

contract UnitVotingEscrowIsAuthorizedVPM is BaseVotingEscrow {
  function test_WhenTheAccountHoldsTheVpmRole() external view {
    // it should return true
    assertTrue(_ve.isAuthorizedVPM(_vpm));
  }

  function test_WhenTheAccountDoesNotHoldTheVpmRole(address _account) external view {
    _assumeFuzzable(_account);
    vm.assume(_account != _vpm);

    // it should return false
    assertFalse(_ve.isAuthorizedVPM(_account));
  }
}
