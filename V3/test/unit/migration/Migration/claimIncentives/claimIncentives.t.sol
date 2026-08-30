// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

contract UnitMigrationClaimIncentives is BaseMigration {
  address internal _recipient = makeAddr('Recipient');

  function test_WhenTheCallerIsNotTheOwner(address _caller, address _incentiveContract, address _token) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);
    (address[] memory _incentiveContracts, address[][] memory _tokens) = _singleClaim(_incentiveContract, _token);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheRecipientIsTheZeroAddress(
    address _incentiveContract,
    address _token
  ) external whenTheCallerIsTheOwner {
    (address[] memory _incentiveContracts, address[][] memory _tokens) = _singleClaim(_incentiveContract, _token);

    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, address(0));
  }

  modifier givenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenIncentiveContractsAndTokenArraysAreProvided(
    address _incentiveContractOne,
    address _incentiveContractTwo,
    address _tokenOne,
    address _tokenTwo
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_tokenOne);
    _assumeFuzzable(_tokenTwo);
    vm.assume(_tokenOne != _tokenTwo);

    address[] memory _incentiveContracts = new address[](2);
    _incentiveContracts[0] = _incentiveContractOne;
    _incentiveContracts[1] = _incentiveContractTwo;
    address[][] memory _tokens = new address[][](2);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _tokenOne;
    _tokens[1] = new address[](1);
    _tokens[1][0] = _tokenTwo;

    // it should call claim bribes with the arrays and migration token id
    _mockAndExpect(
      _v2Voter, abi.encodeCall(IV2Voter.claimBribes, (_incentiveContracts, _tokens, _MIGRATION_TOKEN_ID)), ''
    );
    // it should transfer the requested token balances to the recipient
    _mockTokenBalance(_tokenOne, 111);
    _mockTokenBalance(_tokenTwo, 222);
    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
  }

  function test_WhenTheOuterArraysAreEmpty() external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    address[] memory _incentiveContracts = new address[](0);
    address[][] memory _tokens = new address[][](0);

    // it should call claim bribes with empty arrays
    _mockAndExpect(
      _v2Voter, abi.encodeCall(IV2Voter.claimBribes, (_incentiveContracts, _tokens, _MIGRATION_TOKEN_ID)), ''
    );
    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
  }

  function test_WhenTheOuterArrayLengthsDiffer(
    address _incentiveContractOne,
    address _incentiveContractTwo,
    address _token
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_token);

    address[] memory _incentiveContracts = new address[](2);
    _incentiveContracts[0] = _incentiveContractOne;
    _incentiveContracts[1] = _incentiveContractTwo;
    address[][] memory _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;

    // it should forward the arrays without local validation
    _mockAndExpect(
      _v2Voter, abi.encodeCall(IV2Voter.claimBribes, (_incentiveContracts, _tokens, _MIGRATION_TOKEN_ID)), ''
    );
    _mockTokenBalance(_token, 0);
    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
  }

  function test_GivenTheContractIsPaused(
    address _incentiveContract,
    address _token
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_token);
    vm.prank(_owner);
    _migration.pause();
    (address[] memory _incentiveContracts, address[][] memory _tokens) = _singleClaim(_incentiveContract, _token);

    // it should call claim bribes with the arrays and migration token id
    _mockAndExpect(
      _v2Voter, abi.encodeCall(IV2Voter.claimBribes, (_incentiveContracts, _tokens, _MIGRATION_TOKEN_ID)), ''
    );
    _mockTokenBalance(_token, 0);
    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
  }

  function testGas_claimIncentives() external {
    address[] memory _incentiveContracts = new address[](2);
    _incentiveContracts[0] = makeAddr('IncentiveContractOne');
    _incentiveContracts[1] = makeAddr('IncentiveContractTwo');
    address[][] memory _tokens = new address[][](2);
    _tokens[0] = new address[](1);
    _tokens[0][0] = makeAddr('TokenOne');
    _tokens[1] = new address[](1);
    _tokens[1][0] = makeAddr('TokenTwo');
    _mockAndExpect(
      _v2Voter, abi.encodeCall(IV2Voter.claimBribes, (_incentiveContracts, _tokens, _MIGRATION_TOKEN_ID)), ''
    );
    _mockTokenBalance(_tokens[0][0], 11);
    _mockTokenBalance(_tokens[1][0], 22);

    vm.prank(_owner);
    _migration.claimIncentives(_incentiveContracts, _tokens, _recipient);
    vm.snapshotGasLastCall('Migration_claimIncentives');
  }

  function _mockTokenBalance(address _token, uint256 _balance) internal {
    _mockAndExpectTokenBalance(_token, address(_migration), _balance);
    if (_balance > 0) _mockAndExpectTokenTransfer(_token, _recipient, _balance);
  }

  function _singleClaim(
    address _incentiveContract,
    address _token
  ) internal pure returns (address[] memory _incentiveContracts, address[][] memory _tokens) {
    _incentiveContracts = new address[](1);
    _incentiveContracts[0] = _incentiveContract;
    _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;
  }
}
