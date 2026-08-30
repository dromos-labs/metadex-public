// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {StdStorage, stdStorage} from 'forge-std/Test.sol';

import {MAXTIME, PRECISION, WEEK} from 'V3/libraries/ProtocolConstants.sol';

import {IMigration} from 'V3/interfaces/migration/IMigration.sol';
import {IV2Voter} from 'V3/interfaces/migration/v2/IV2Voter.sol';
import {IV2VotingEscrow} from 'V3/interfaces/migration/v2/IV2VotingEscrow.sol';

import {Migration} from 'V3/migration/Migration.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract MigrationForTest is Migration {
  using SafeERC20 for IERC20;

  constructor(IMigration.BaseParams memory _params) Migration(_params) {}

  function _transferClaimed(address[] calldata, address[][] calldata _tokens, address _recipient) internal override {
    uint256 _outerLength = _tokens.length;
    for (uint256 _i; _i < _outerLength; ++_i) {
      uint256 _innerLength = _tokens[_i].length;
      for (uint256 _j; _j < _innerLength; ++_j) {
        IERC20 _token = IERC20(_tokens[_i][_j]);
        uint256 _balance = _token.balanceOf(address(this));
        if (_balance > 0) _token.safeTransfer(_recipient, _balance);
      }
    }
  }

  function _settleStake(address, uint256 _out, uint256, bool) internal pure override returns (bool, uint256) {
    return (false, _out);
  }

  function _settleLiquid(address, uint256 _out) internal pure override returns (uint256) {
    return _out;
  }

  function _computeMigrationAmount(uint256 _basis) internal pure override returns (uint256) {
    return _basis;
  }

  function _checkValue() internal pure override {}

  function _checkBudget(uint256) internal pure override {}
}

abstract contract BaseMigration is TestHelpers {
  using stdStorage for StdStorage;

  uint256 internal constant _MIGRATION_TOKEN_ID = 42;

  address internal _owner = makeAddr('Owner');
  address internal _deployer = makeAddr('Deployer');
  address internal _v2Token;
  address internal _v2Voter;
  address internal _v2Minter;
  address internal _v2Escrow;
  uint48 internal _migrationOpen;

  IMigration.BaseParams internal _params;
  MigrationForTest internal _migration;

  function setUp() external virtual {
    _v2Token = _mockContract('V2Token');
    _v2Voter = _mockContract('V2Voter');
    _v2Minter = _mockContract('V2Minter');
    _v2Escrow = _mockContract('V2Escrow');
    _migrationOpen = uint48(((block.timestamp / WEEK) + 1) * WEEK);

    _params = IMigration.BaseParams({
      owner: _owner,
      deployer: _deployer,
      v2Token: _v2Token,
      escrow: _v2Escrow,
      voter: _v2Voter,
      migrationOpen: _migrationOpen,
      restricted: new uint256[](0)
    });

    vm.mockCall(_v2Token, abi.encodeWithSelector(IERC20.transferFrom.selector), abi.encode(true));
    vm.mockCall(_v2Token, abi.encodeCall(IERC20.approve, (_v2Escrow, PRECISION)), abi.encode(true));
    vm.mockCall(_v2Voter, abi.encodeCall(IV2Voter.minter, ()), abi.encode(_v2Minter));
    vm.mockCall(
      _v2Escrow, abi.encodeCall(IV2VotingEscrow.createLock, (PRECISION, MAXTIME)), abi.encode(_MIGRATION_TOKEN_ID)
    );
    vm.mockCall(_v2Escrow, abi.encodeCall(IV2VotingEscrow.lockPermanent, (_MIGRATION_TOKEN_ID)), abi.encode());

    _migration = new MigrationForTest(_params);
  }

  function _setPaused(bool _isPaused) internal {
    vm.prank(_owner);
    if (_isPaused) {
      _migration.pause();
    } else {
      _migration.unpause();
    }
  }

  function _setRestricted(uint256 _tokenId, bool _isRestricted) internal {
    stdstore.target(address(_migration)).sig(_migration.restricted.selector).with_key(_tokenId)
      .checked_write(_isRestricted);
  }
}
