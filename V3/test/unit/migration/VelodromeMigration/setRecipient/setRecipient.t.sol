// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {IV2RootVotingRewardsFactory} from 'V3/interfaces/migration/v2/IV2RootVotingRewardsFactory.sol';

import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationSetRecipient is UnitVelodromeMigration {
  function setUp() public override {
    super.setUp();
    _deployMigration();
  }

  function test_WhenTheCallerIsNotTheOwner(address _caller, uint256 _chainId, address _recipient) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.setRecipient(_chainId, _recipient);
  }

  function test_WhenTheCallerIsTheOwner(uint256 _chainId, address _recipient) external {
    // it should set the recipient through the V2 root voting rewards factory
    _mockAndExpect(
      _v2RootVotingRewardsFactory, abi.encodeCall(IV2RootVotingRewardsFactory.setRecipient, (_chainId, _recipient)), ''
    );
    vm.prank(_owner);
    _migration.setRecipient(_chainId, _recipient);
  }

  function testGas_setRecipient() external {
    uint256 _chainId = 10;
    _mockAndExpect(
      _v2RootVotingRewardsFactory, abi.encodeCall(IV2RootVotingRewardsFactory.setRecipient, (_chainId, _recipient)), ''
    );

    vm.prank(_owner);
    _migration.setRecipient(_chainId, _recipient);
    vm.snapshotGasLastCall('VelodromeMigration_setRecipient');
  }
}
