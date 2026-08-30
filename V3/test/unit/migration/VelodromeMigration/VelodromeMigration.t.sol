// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {VelodromeMigration} from 'V3/migration/VelodromeMigration.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitVelodromeMigration is TestHelpers {
  uint256 internal constant _BUDGET_BASIS = 2_500_000_000 ether;
  uint256 internal constant _RESTRICTED_TOKEN_ID_1 = 1;
  uint256 internal constant _RESTRICTED_TOKEN_ID_2 = 2;
  uint256 internal constant _MIGRATION_TOKEN_ID = 3;
  uint32 internal constant _ROOT_DOMAIN = 8453;

  address internal _owner = makeAddr('_owner');
  address internal _deployer = makeAddr('_deployer');
  address internal _v2Token = _mockContract('_v2Token');
  address internal _v2Voter = _mockContract('_v2Voter');
  address internal _v2Minter = _mockContract('_v2Minter');
  address internal _v2Escrow = _mockContract('_v2Escrow');
  address internal _v2EmergencyCouncil;
  address internal _v2RootVotingRewardsFactory;
  address internal _mailbox = _mockContract('_mailbox');
  address internal _recipient = makeAddr('_recipient');
  uint48 internal _migrationOpen;

  /// @dev Default base migration constructor parameters
  IMigration.BaseParams internal _params;

  /// @dev Velodrome migration instance
  VelodromeMigration internal _migration;

  function setUp() public virtual {
    _v2EmergencyCouncil = _mockContract('_v2EmergencyCouncil');
    _v2RootVotingRewardsFactory = _mockContract('_v2RootVotingRewardsFactory');
    _migrationOpen = uint48(((block.timestamp / WEEK) + 1) * WEEK);
    _params = _baseParams();

    /// @dev Mock the v2 token calls required to seed the migration veNFT
    vm.mockCall(_v2Token, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
    vm.mockCall(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, PRECISION)), abi.encode(true));
    vm.mockCall(_v2Voter, abi.encodeCall(IV2Voter.minter, ()), abi.encode(_v2Minter));

    /// @dev Mock the v2 VotingEscrow calls required to create the permanent migration veNFT
    vm.mockCall(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.createLock, (PRECISION, MAXTIME)), abi.encode(_MIGRATION_TOKEN_ID)
    );
    vm.mockCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.lockPermanent, (_MIGRATION_TOKEN_ID)), abi.encode());

    /// @dev Mock the mailbox local domain required to validate the root domain
    vm.mockCall(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(uint32(10)));

    /// @dev Mock the v2 voter emergency council used for gauge management
    vm.mockCall(_v2Voter, abi.encodeCall(IV2Voter.emergencyCouncil, ()), abi.encode(_v2EmergencyCouncil));
  }

  function _deployMigration() internal {
    _migration = new VelodromeMigration(_params, _mailbox, _ROOT_DOMAIN, _v2RootVotingRewardsFactory);
  }

  function _setPaused(bool _isPaused) internal {
    vm.prank(_owner);
    if (_isPaused) {
      _migration.pause();
    } else {
      _migration.unpause();
    }
  }

  function _singleClaim(
    address _rewardContract,
    address _token
  ) internal pure returns (address[] memory _rewardContracts, address[][] memory _tokens) {
    _rewardContracts = new address[](1);
    _rewardContracts[0] = _rewardContract;
    _tokens = new address[][](1);
    _tokens[0] = new address[](1);
    _tokens[0][0] = _token;
  }

  /// @dev Encodes a Velodrome migration settlement message
  function _encodeMigrationMessage(
    uint64 _nonce,
    address _recipientAddress,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(_nonce, _recipientAddress, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);
  }

  /// @dev Builds the default base migration constructor parameters
  function _baseParams() internal view returns (IMigration.BaseParams memory) {
    uint256[] memory _restricted = new uint256[](2);
    _restricted[0] = _RESTRICTED_TOKEN_ID_1;
    _restricted[1] = _RESTRICTED_TOKEN_ID_2;

    return IMigration.BaseParams({
      owner: _owner,
      deployer: _deployer,
      v2Token: _v2Token,
      escrow: _v2Escrow,
      voter: _v2Voter,
      migrationOpen: _migrationOpen,
      restricted: _restricted
    });
  }
}
