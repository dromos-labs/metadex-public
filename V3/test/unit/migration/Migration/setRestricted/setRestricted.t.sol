// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';

contract UnitMigrationSetRestricted is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller, uint256 _tokenId) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);
    uint256[] memory _tokenIds = new uint256[](1);
    _tokenIds[0] = _tokenId;

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.setRestricted(_tokenIds);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_WhenTheTokenIdsArrayIsEmpty() external whenTheCallerIsTheOwner {
    uint256[] memory _tokenIds = new uint256[](0);

    vm.recordLogs();
    vm.prank(_owner);
    _migration.setRestricted(_tokenIds);

    // it should not emit RestrictionsSet
    assertEq(vm.getRecordedLogs().length, 0);
  }

  function test_WhenTheTokenIdsAreUnrestricted(
    uint256 _tokenIdOne,
    uint256 _tokenIdTwo
  ) external whenTheCallerIsTheOwner {
    vm.assume(_tokenIdOne != _tokenIdTwo);
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = _tokenIdOne;
    _tokenIds[1] = _tokenIdTwo;

    vm.prank(_owner);
    // it should emit RestrictionsSet for every token id
    _expectEmit(address(_migration));
    emit IMigration.RestrictionsSet(_tokenIdOne);
    _expectEmit(address(_migration));
    emit IMigration.RestrictionsSet(_tokenIdTwo);
    _migration.setRestricted(_tokenIds);

    // it should mark every token id as restricted
    assertTrue(_migration.restricted(_tokenIdOne));
    assertTrue(_migration.restricted(_tokenIdTwo));
  }

  function test_WhenATokenIdAppearsMoreThanOnce(uint256 _tokenId) external whenTheCallerIsTheOwner {
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = _tokenId;
    _tokenIds[1] = _tokenId;

    vm.prank(_owner);
    _migration.setRestricted(_tokenIds);

    // it should leave the token id restricted
    assertTrue(_migration.restricted(_tokenId));
  }

  function test_WhenTheTokenIdsAreAlreadyRestricted(
    uint256 _tokenIdOne,
    uint256 _tokenIdTwo
  ) external whenTheCallerIsTheOwner {
    vm.assume(_tokenIdOne != _tokenIdTwo);
    _setRestricted(_tokenIdOne, true);
    _setRestricted(_tokenIdTwo, true);
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = _tokenIdOne;
    _tokenIds[1] = _tokenIdTwo;

    vm.prank(_owner);
    _migration.setRestricted(_tokenIds);

    // it should leave every token id restricted
    assertTrue(_migration.restricted(_tokenIdOne));
    assertTrue(_migration.restricted(_tokenIdTwo));
  }

  function test_GivenTheContractIsPaused(uint256 _tokenId) external whenTheCallerIsTheOwner {
    _setPaused(true);
    uint256[] memory _tokenIds = new uint256[](1);
    _tokenIds[0] = _tokenId;

    vm.prank(_owner);
    _migration.setRestricted(_tokenIds);

    // it should mark every token id as restricted
    assertTrue(_migration.restricted(_tokenId));
  }

  function testGas_setRestricted() external {
    uint256[] memory _tokenIds = new uint256[](2);
    _tokenIds[0] = 1;
    _tokenIds[1] = 2;

    vm.prank(_owner);
    _migration.setRestricted(_tokenIds);
    vm.snapshotGasLastCall('Migration_setRestricted');
  }
}
