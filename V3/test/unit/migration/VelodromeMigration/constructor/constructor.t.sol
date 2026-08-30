// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IVelodromeMigration} from 'V3/interfaces/migration/IVelodromeMigration.sol';
import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {UnitVelodromeMigration} from 'V3-test/unit/migration/VelodromeMigration/VelodromeMigration.t.sol';

contract UnitVelodromeMigrationConstructor is UnitVelodromeMigration {
  function test_WhenTheOwnerIsTheZeroAddress() external {
    // it should revert with OwnableInvalidOwner
    _params.owner = address(0);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheDeployerIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.deployer = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheV2TokenIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.v2Token = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheV2VotingEscrowIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.escrow = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheV2VoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.voter = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheMigrationOpeningTimestampIsNotWeekAligned(uint48 _week, uint48 _offset) external {
    uint48 _maxWeek = type(uint48).max / WEEK - 1;
    _week = uint48(bound(_week, 0, _maxWeek));
    _offset = uint48(bound(_offset, 1, WEEK - 1));

    // it should revert with InvalidOpen
    _params.migrationOpen = _week * WEEK + _offset;

    vm.expectRevert(IMigration.InvalidOpen.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheMigrationOpeningTimestampIsNotInTheFuture(uint48 _currentWeek, uint48 _openWeek) external {
    uint48 _maxWeek = type(uint48).max / WEEK;
    _currentWeek = uint48(bound(_currentWeek, 1, _maxWeek));
    _openWeek = uint48(bound(_openWeek, 0, _currentWeek));
    vm.warp(_currentWeek * WEEK);

    // it should revert with InvalidOpen
    _params.migrationOpen = _openWeek * WEEK;

    vm.expectRevert(IMigration.InvalidOpen.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheHyperlaneMailboxIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, address(0), _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheRootDomainIsZero() external {
    // it should revert with InvalidDomain
    vm.expectRevert(IVelodromeMigration.InvalidDomain.selector);
    new VelodromeMigration(_params, _mailbox, 0, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheRootDomainIsEqualToTheMailboxLocalDomain(uint32 _localDomain) external {
    _localDomain = uint32(bound(_localDomain, 1, type(uint32).max));
    _mockAndExpect(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_localDomain));

    // it should revert with InvalidDomain
    vm.expectRevert(IVelodromeMigration.InvalidDomain.selector);
    new VelodromeMigration(_params, _mailbox, _localDomain, _v2RootVotingRewardsFactory);
  }

  function test_WhenTheLegacyRootVotingRewardsFactoryIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, address(0));
  }

  function test_WhenTheVoterEmergencyCouncilIsTheZeroAddress() external {
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.emergencyCouncil, ()), abi.encode(address(0)));

    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function test_WhenPassingValidParameters() external {
    address _expectedMigration = _computeCreate(address(this), vm.getNonce(address(this)));
    // it should emit RestrictionsSet for each configured v2 veNFT
    _expectEmit(_expectedMigration);
    emit IMigration.RestrictionsSet(_RESTRICTED_TOKEN_ID_1);
    _expectEmit(_expectedMigration);
    emit IMigration.RestrictionsSet(_RESTRICTED_TOKEN_ID_2);
    // it should transfer the migration veNFT seed amount from the deployer
    _mockAndExpect(
      _v2Token, abi.encodeCall(IERC20.transferFrom, (_deployer, _expectedMigration, PRECISION)), abi.encode(true)
    );
    _mockAndExpect(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, PRECISION)), abi.encode(true));
    _mockAndExpect(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.createLock, (PRECISION, MAXTIME)), abi.encode(_MIGRATION_TOKEN_ID)
    );
    // it should permanently lock the v2 migration veNFT
    _mockAndExpect(_v2Escrow, abi.encodeCall(IV2VotingEscrow.lockPermanent, (_MIGRATION_TOKEN_ID)), abi.encode());
    // it should query the V2 voter emergency council
    _mockAndExpect(_v2Voter, abi.encodeCall(IV2Voter.emergencyCouncil, ()), abi.encode(address(_v2EmergencyCouncil)));

    _migration = new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);

    // it should set the owner
    assertEq(_migration.owner(), _owner);

    // it should set the shared migration configuration
    assertEq(address(_migration.V2_TOKEN()), _v2Token);
    assertEq(address(_migration.V2_VOTER()), _v2Voter);
    assertEq(address(_migration.V2_ESCROW()), _v2Escrow);
    assertEq(_migration.MIGRATION_OPEN(), _migrationOpen);
    assertEq(_migration.ACTIVATION(), _migrationOpen + WEEK);

    // it should set the V2 Minter
    assertEq(address(_migration.V2_MINTER()), _v2Minter);

    // it should return Defeated as the epoch governor result
    assertEq(uint8(_migration.result()), uint8(IV2EpochGovernor.ProposalState.Defeated));

    // it should restrict each configured v2 veNFT
    assertTrue(_migration.restricted(_RESTRICTED_TOKEN_ID_1));
    assertTrue(_migration.restricted(_RESTRICTED_TOKEN_ID_2));

    // it should create the v2 migration veNFT
    assertEq(_migration.MIGRATION_TOKEN_ID(), _MIGRATION_TOKEN_ID);

    // it should set the Velodrome settlement immutables
    assertEq(address(_migration.MAILBOX()), _mailbox);
    assertEq(_migration.ROOT_DOMAIN(), _ROOT_DOMAIN);

    // it should cache the V2 emergency council
    assertEq(address(_migration.V2_EMERGENCY_COUNCIL()), _v2EmergencyCouncil);

    // it should cache the V2 root voting rewards factory
    assertEq(address(_migration.V2_ROOT_VOTING_REWARDS_FACTORY()), _v2RootVotingRewardsFactory);
  }
}
