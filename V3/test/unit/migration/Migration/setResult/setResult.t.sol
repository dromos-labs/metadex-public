// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';

contract UnitMigrationSetResult is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller, uint8 _result) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);
    _result = uint8(bound(_result, 0, uint8(IV2EpochGovernor.ProposalState.Executed)));

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.setResult(IV2EpochGovernor.ProposalState(_result));
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_WhenTheContractIsUnpaused(uint8 _result) external whenTheCallerIsTheOwner {
    _result = uint8(bound(_result, 0, uint8(IV2EpochGovernor.ProposalState.Executed)));
    IV2EpochGovernor.ProposalState _proposalState = IV2EpochGovernor.ProposalState(_result);

    vm.prank(_owner);
    // it should emit the ResultSet event
    _expectEmit(address(_migration));
    emit IMigration.ResultSet(_proposalState);
    _migration.setResult(_proposalState);

    // it should set the V2 epoch governor result
    assertEq(uint8(_migration.result()), _result);
  }

  function test_WhenTheContractIsPaused(uint8 _result) external whenTheCallerIsTheOwner {
    _result = uint8(bound(_result, 0, uint8(IV2EpochGovernor.ProposalState.Executed)));
    IV2EpochGovernor.ProposalState _proposalState = IV2EpochGovernor.ProposalState(_result);
    _setPaused(true);

    vm.prank(_owner);
    // it should emit the ResultSet event
    _expectEmit(address(_migration));
    emit IMigration.ResultSet(_proposalState);
    _migration.setResult(_proposalState);

    // it should set the V2 epoch governor result
    assertEq(uint8(_migration.result()), _result);
  }
}
