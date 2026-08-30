// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

contract UnitMigrationVote is BaseMigration {
  function test_WhenTheCallerIsNotTheOwner(address _caller, address _pool, uint256 _weight) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);
    address[] memory _pools = new address[](1);
    _pools[0] = _pool;
    uint256[] memory _weights = new uint256[](1);
    _weights[0] = _weight;

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.vote(_pools, _weights);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_WhenPoolsAndWeightsAreProvided(
    address _poolOne,
    address _poolTwo,
    uint256 _weightOne,
    uint256 _weightTwo
  ) external whenTheCallerIsTheOwner {
    address[] memory _pools = new address[](2);
    _pools[0] = _poolOne;
    _pools[1] = _poolTwo;
    uint256[] memory _weights = new uint256[](2);
    _weights[0] = _weightOne;
    _weights[1] = _weightTwo;

    // it should forward the pools weights and migration token id
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.vote, (_MIGRATION_TOKEN_ID, _pools, _weights)), '');
    vm.prank(_owner);
    _migration.vote(_pools, _weights);
  }

  function test_WhenThePoolsAndWeightsArraysAreEmpty() external whenTheCallerIsTheOwner {
    address[] memory _pools = new address[](0);
    uint256[] memory _weights = new uint256[](0);

    // it should forward the empty arrays
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.vote, (_MIGRATION_TOKEN_ID, _pools, _weights)), '');
    vm.prank(_owner);
    _migration.vote(_pools, _weights);
  }

  function test_WhenThePoolsAndWeightsLengthsDiffer(
    address _pool,
    uint256 _weightOne,
    uint256 _weightTwo
  ) external whenTheCallerIsTheOwner {
    address[] memory _pools = new address[](1);
    _pools[0] = _pool;
    uint256[] memory _weights = new uint256[](2);
    _weights[0] = _weightOne;
    _weights[1] = _weightTwo;

    // it should forward the arrays without local validation
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.vote, (_MIGRATION_TOKEN_ID, _pools, _weights)), '');
    vm.prank(_owner);
    _migration.vote(_pools, _weights);
  }

  function test_GivenTheContractIsPaused(address _pool, uint256 _weight) external whenTheCallerIsTheOwner {
    _setPaused(true);
    address[] memory _pools = new address[](1);
    _pools[0] = _pool;
    uint256[] memory _weights = new uint256[](1);
    _weights[0] = _weight;

    // it should forward the pools weights and migration token id
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.vote, (_MIGRATION_TOKEN_ID, _pools, _weights)), '');
    vm.prank(_owner);
    _migration.vote(_pools, _weights);
  }

  function testGas_vote() external {
    address[] memory _pools = new address[](2);
    _pools[0] = makeAddr('PoolOne');
    _pools[1] = makeAddr('PoolTwo');
    uint256[] memory _weights = new uint256[](2);
    _weights[0] = 1e18;
    _weights[1] = 2e18;
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.vote, (_MIGRATION_TOKEN_ID, _pools, _weights)), '');

    vm.prank(_owner);
    _migration.vote(_pools, _weights);
    vm.snapshotGasLastCall('Migration_vote');
  }
}
