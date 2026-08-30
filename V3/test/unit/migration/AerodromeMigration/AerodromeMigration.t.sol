// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IAerodromeMigration} from 'V3/interfaces/migration/IAerodromeMigration.sol';
import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2EpochGovernor} from 'V3/interfaces/migration/v2/IV2EpochGovernor.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {AerodromeMigration} from 'V3/migration/AerodromeMigration.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitAerodromeMigration is TestHelpers {
  uint256 internal constant _BUDGET_BASIS = 2_000_000_000 ether;
  uint256 internal constant _RESTRICTED_TOKEN_ID_1 = 1;
  uint256 internal constant _RESTRICTED_TOKEN_ID_2 = 2;
  uint256 internal constant _MIGRATION_TOKEN_ID = 3;

  address internal _owner = makeAddr('_owner');
  address internal _deployer = makeAddr('_deployer');
  address internal _v2Token = _mockContract('_v2Token');
  address internal _v2Voter = _mockContract('_v2Voter');
  address internal _v2Minter = _mockContract('_v2Minter');
  address internal _v2Escrow = _mockContract('_v2Escrow');
  address internal _v3Token = _mockContract('_v3Token');
  address internal _v3Escrow = _mockContract('_v3Escrow');
  uint48 internal _migrationOpen;

  /// @dev Default base migration constructor parameters
  IMigration.BaseParams internal _params;

  /// @dev Aerodrome migration instance used by non-constructor tests
  AerodromeMigration internal _migration;

  function setUp() public virtual {
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
  }

  function test_ConstructorWhenTheOwnerIsTheZeroAddress() external {
    // it should revert with OwnableInvalidOwner
    _params.owner = address(0);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheDeployerIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.deployer = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheV2TokenIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.v2Token = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheV2VotingEscrowIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.escrow = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheV2VoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    _params.voter = address(0);

    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheMigrationOpeningTimestampIsNotWeekAligned(uint48 _week, uint48 _offset) external {
    uint48 _maxWeek = type(uint48).max / WEEK - 1;
    _week = uint48(bound(_week, 0, _maxWeek));
    _offset = uint48(bound(_offset, 1, WEEK - 1));

    // it should revert with InvalidOpen
    _params.migrationOpen = _week * WEEK + _offset;

    vm.expectRevert(IMigration.InvalidOpen.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheMigrationOpeningTimestampIsNotInTheFuture(
    uint48 _currentWeek,
    uint48 _openWeek
  ) external {
    uint48 _maxWeek = type(uint48).max / WEEK;
    _currentWeek = uint48(bound(_currentWeek, 1, _maxWeek));
    _openWeek = uint48(bound(_openWeek, 0, _currentWeek));
    vm.warp(_currentWeek * WEEK);

    // it should revert with InvalidOpen
    _params.migrationOpen = _openWeek * WEEK;

    vm.expectRevert(IMigration.InvalidOpen.selector);
    new AerodromeMigration(_params, _v3Token, _v3Escrow);
  }

  function test_ConstructorWhenTheV3TokenIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, address(0), _v3Escrow);
  }

  function test_ConstructorWhenTheV3VotingEscrowIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IMigration.ZeroAddress.selector);
    new AerodromeMigration(_params, _v3Token, address(0));
  }

  function test_ConstructorWhenPassingValidParameters() external {
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

    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);

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

    // it should set the Aerodrome settlement immutables
    assertEq(address(_migration.V3_TOKEN()), _v3Token);
    assertEq(address(_migration.V3_ESCROW()), _v3Escrow);
  }

  function test_OnERC721ReceivedWhenTheCallerIsNotTheV3VotingEscrow(
    address _caller,
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external {
    _caller = _boundNotEq(_caller, _v3Escrow);
    _assumeFuzzable(_caller);
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);

    // it should revert with InvalidERC721Transfer
    vm.expectRevert(IAerodromeMigration.InvalidERC721Transfer.selector);
    vm.prank(_caller);
    _migration.onERC721Received(address(_migration), _from, _tokenId, _data);
  }

  modifier whenTheCallerIsTheV3VotingEscrow() {
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
    vm.startPrank(_v3Escrow);
    _;
    vm.stopPrank();
  }

  function test_OnERC721ReceivedWhenTheOperatorIsNotTheMigrationContract(
    address _operator,
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external whenTheCallerIsTheV3VotingEscrow {
    _operator = _boundNotEq(_operator, address(_migration));

    // it should revert with InvalidERC721Transfer
    vm.expectRevert(IAerodromeMigration.InvalidERC721Transfer.selector);
    _migration.onERC721Received(_operator, _from, _tokenId, _data);
  }

  function test_OnERC721ReceivedWhenTheOperatorIsTheMigrationContract(
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external whenTheCallerIsTheV3VotingEscrow {
    // it should return the ERC721 receiver selector
    bytes4 _selector = _migration.onERC721Received(address(_migration), _from, _tokenId, _data);
    assertEq(_selector, IERC721Receiver.onERC721Received.selector);
  }

  function test_RemainingWhenTheRemainingBalanceIsZero() external {
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), 0);

    // it should return zero
    assertEq(_migration.remaining(), 0);
  }

  function test_RemainingWhenTheRemainingBalanceIsPositive(uint256 _remaining) external {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _migration = new AerodromeMigration(_params, _v3Token, _v3Escrow);
    _mockAndExpectTokenBalance(_v3Token, address(_migration), _remaining);

    // it should return the remaining balance
    assertEq(_migration.remaining(), _remaining);
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

  function _setPaused(bool _isPaused) internal {
    vm.prank(_owner);
    if (_isPaused) {
      _migration.pause();
    } else {
      _migration.unpause();
    }
  }
}
