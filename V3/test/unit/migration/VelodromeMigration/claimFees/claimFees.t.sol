// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IV2RootVotingReward} from 'V3/interfaces/migration/v2/IV2RootVotingReward.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';

import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationClaimFees is UnitVelodromeMigration {
  function setUp() public override {
    super.setUp();
    _deployMigration();
  }

  modifier whenTheRewardContractReportsTheOptimismChainIdentifier() {
    _;
  }

  function test_GivenTheClaimedTokenBalanceIsPositive(uint256 _balance)
    external
    whenTheRewardContractReportsTheOptimismChainIdentifier
  {
    _balance = bound(_balance, 1, type(uint256).max);
    address _feeContract = _mockContract('FeeContract');
    address _token = _mockContract('Token');
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_feeContract, abi.encodeCall(IV2RootVotingReward.chainid, ()), abi.encode(uint256(10)));
    _mockAndExpectTokenBalance(_token, address(_migration), _balance);
    _mockAndExpectTokenTransfer(_token, _recipient, _balance);

    // it should transfer the locally claimed token balance
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_GivenTheClaimedTokenBalanceIsZero() external whenTheRewardContractReportsTheOptimismChainIdentifier {
    address _feeContract = _mockContract('FeeContract');
    address _token = _mockContract('Token');
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_feeContract, abi.encodeCall(IV2RootVotingReward.chainid, ()), abi.encode(uint256(10)));
    _mockAndExpectTokenBalance(_token, address(_migration), 0);
    vm.expectCall(_token, abi.encodeWithSelector(IERC20.transfer.selector), 0);

    // it should query the token balance without transferring
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_WhenTheRewardContractReportsAnotherChainIdentifier(uint256 _chainId) external {
    vm.assume(_chainId != 10);
    address _feeContract = _mockContract('FeeContract');
    address _token = _mockContract('Token');
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    _mockAndExpect(_feeContract, abi.encodeCall(IV2RootVotingReward.chainid, ()), abi.encode(_chainId));

    // it should skip token calls for the remote reward
    vm.expectCall(_token, abi.encodeWithSelector(IERC20.balanceOf.selector), 0);
    vm.expectCall(_token, abi.encodeWithSelector(IERC20.transfer.selector), 0);
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }

  function test_WhenTheRewardContractChainIdentifierCallReverts(uint256 _balance) external {
    _balance = bound(_balance, 1, type(uint256).max);
    address _feeContract = _mockContract('FeeContract');
    address _token = _mockContract('Token');
    (address[] memory _feeContracts, address[][] memory _tokens) = _singleClaim(_feeContract, _token);
    bytes memory _chainIdCall = abi.encodeCall(IV2RootVotingReward.chainid, ());

    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.claimFees, (_feeContracts, _tokens, _MIGRATION_TOKEN_ID)), '');
    vm.mockCallRevert(_feeContract, _chainIdCall, 'chain identifier reverted');
    vm.expectCall(_feeContract, _chainIdCall);
    _mockAndExpectTokenBalance(_token, address(_migration), _balance);
    _mockAndExpectTokenTransfer(_token, _recipient, _balance);

    // it should transfer the locally claimed token balance
    vm.prank(_owner);
    _migration.claimFees(_feeContracts, _tokens, _recipient);
  }
}
