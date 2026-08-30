// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {UnitAerodromeMigration} from 'V3-test/unit/migration/AerodromeMigration/AerodromeMigration.t.sol';

contract UnitAerodromeMigrationClaimFees is UnitAerodromeMigration {
  function setUp() public override {
    super.setUp();

    _v3Token = _mockContract('V3Token');
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_WhenARewardTokenIsTheMigrationOutputToken(
    uint256 _migrationBalance,
    uint256 _recipientBalance
  ) external {
    address[] memory _feeContracts = new address[](1);
    _feeContracts[0] = makeAddr('FeeContract');
    address[][] memory _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _v3Token;
    address _recipient = makeAddr('Recipient');
    uint256[2] memory _migrationBalances = [_migrationBalance, _migrationBalance];
    uint256[2] memory _recipientBalances = [_recipientBalance, _recipientBalance];

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_migration), _migrationBalances);
    _mockAndExpectTokenBalancesTwice(_v3Token, _recipient, _recipientBalances);

    uint256 _migrationBalanceBefore = IERC20(_v3Token).balanceOf(address(_migration));
    uint256 _recipientBalanceBefore = IERC20(_v3Token).balanceOf(_recipient);

    // it should revert with InvalidRewardToken
    vm.expectRevert(abi.encodeWithSelector(IAerodromeMigration.InvalidRewardToken.selector, _v3Token));
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);

    // it should leave the migration and recipient balances unchanged
    assertEq(IERC20(_v3Token).balanceOf(address(_migration)), _migrationBalanceBefore);
    assertEq(IERC20(_v3Token).balanceOf(_recipient), _recipientBalanceBefore);
  }

  function test_GivenTheClaimedTokenBalanceIsPositive(uint256 _balance) external {
    _balance = bound(_balance, 1, type(uint256).max);
    address _feeContract = makeAddr('FeeContract');
    address _token = _mockContract('Token');
    address[] memory _feeContracts = new address[](1);
    _feeContracts[0] = _feeContract;
    address[][] memory _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;
    address _recipient = makeAddr('Recipient');

    assertNotEq(_token, address(_migration.V3_TOKEN()));

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpectTokenBalance(_token, address(_migration), _balance);
    _mockAndExpectTokenTransfer(_token, _recipient, _balance);

    // it should transfer the claimed token balance
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }
}
