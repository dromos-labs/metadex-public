// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';

import {BaseMigration} from 'V3-test/unit/migration/BaseMigration.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

contract UnitMigrationClaimFees is BaseMigration {
  address internal _recipient = makeAddr('Recipient');

  function test_WhenTheCallerIsNotTheOwner(address _caller, address _feeContract, address _token) external {
    // it should revert with OwnableUnauthorizedAccount
    _assumeFuzzable(_caller);
    vm.assume(_caller != _owner);
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  modifier whenTheCallerIsTheOwner() {
    _;
  }

  function test_GivenTheRecipientIsTheZeroAddress(
    address _feeContract,
    address _token
  ) external whenTheCallerIsTheOwner {
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, address(0));
  }

  modifier givenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_WhenFeeContractsAndTokenArraysAreProvided(
    address _feeContractOne,
    address _feeContractTwo,
    address _tokenOne,
    address _tokenTwo
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_tokenOne);
    _assumeFuzzable(_tokenTwo);
    vm.assume(_tokenOne != _tokenTwo);

    address[] memory _feeContracts = new address[](2);
    _feeContracts[0] = _feeContractOne;
    _feeContracts[1] = _feeContractTwo;
    address[][] memory _tokens = new address[][](2);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _tokenOne;
    _tokens[1] = new address[](1);
    _tokens[1][0] = _tokenTwo;

    // it should forward the arrays and migration token id
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    // it should transfer the requested token balances to the recipient
    _mockTokenBalance(_tokenOne, 111);
    _mockTokenBalance(_tokenTwo, 222);
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_WhenTheOuterArraysAreEmpty() external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    address[] memory _feeContracts = new address[](0);
    address[][] memory _tokens = new address[][](0);

    // it should forward the empty arrays
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_WhenTheOuterArrayLengthsDiffer(
    address _feeContractOne,
    address _feeContractTwo,
    address _token
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_token);

    address[] memory _feeContracts = new address[](2);
    _feeContracts[0] = _feeContractOne;
    _feeContracts[1] = _feeContractTwo;
    address[][] memory _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;

    // it should forward the arrays without local validation
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockTokenBalance(_token, 0);
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_GivenTheContractIsPaused(
    address _feeContract,
    address _token
  ) external whenTheCallerIsTheOwner givenTheRecipientIsNotTheZeroAddress {
    _assumeFuzzable(_token);
    vm.prank(_owner);
    _migration.pause();
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    // it should forward the arrays and migration token id
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockTokenBalance(_token, 0);
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function testGas_claimFees() external {
    address[] memory _feeContracts = new address[](2);
    _feeContracts[0] = makeAddr('FeeContractOne');
    _feeContracts[1] = makeAddr('FeeContractTwo');
    address[][] memory _tokens = new address[][](2);
    _tokens[0] = new address[](1);
    _tokens[0][0] = makeAddr('TokenOne');
    _tokens[1] = new address[](1);
    _tokens[1][0] = makeAddr('TokenTwo');
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockTokenBalance(_tokens[0][0], 11);
    _mockTokenBalance(_tokens[1][0], 22);

    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
    vm.snapshotGasLastCall('Migration_claimFees');
  }

  function _mockTokenBalance(address _token, uint256 _balance) internal {
    _mockAndExpectTokenBalance(_token, address(_migration), _balance);
    if (_balance > 0) _mockAndExpectTokenTransfer(_token, _recipient, _balance);
  }

  function _singleClaim(
    address _feeContract,
    address _token
  ) internal pure returns (address[] memory _feeContracts, address[][] memory _tokens) {
    _feeContracts = new address[](1);
    _feeContracts[0] = _feeContract;
    _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;
  }
}
