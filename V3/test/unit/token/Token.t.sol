// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@solady/tokens/ERC20.sol';

import {ProtocolTimeLibrary} from 'V3/libraries/ProtocolTimeLibrary.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';
import {IBaseTokenExtensions} from 'V3/interfaces/token/IBaseTokenExtensions.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';
import {Token} from 'V3/token/Token.sol';

contract UnitToken is TestHelpers {
  address internal constant _PERMIT_TWO = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
  uint256 internal constant _PERMIT_OWNER_PK = 0xA11CE;
  uint48 internal constant _MIGRATION_OPEN = 1 weeks;
  bool internal constant _UPDATE_SUPPLY = true;
  uint256 internal constant _WEEK = 1 weeks;
  string internal constant _TOKEN_NAME = 'Dromos Token';
  string internal constant _TOKEN_SYMBOL = 'DROM';

  address internal immutable _MINTER = makeAddr('Minter');
  address internal immutable _VOTING_ESCROW = makeAddr('Voting Escrow');
  address internal immutable _MIGRATION = makeAddr('Migration');
  address internal immutable _VELODROME_MIGRATION = makeAddr('Velodrome Migration');

  Token internal _token;
  address internal _permitOwner;

  function setUp() external {
    _token = new Token(
      _MINTER, _VOTING_ESCROW, _MIGRATION, _VELODROME_MIGRATION, _MIGRATION_OPEN, 0, 0, _TOKEN_NAME, _TOKEN_SYMBOL
    );
    vm.warp(_token.TRANSFERS_ENABLED_AT() + 1);
    _permitOwner = vm.addr(_PERMIT_OWNER_PK);
    vm.label(_permitOwner, 'Permit Owner');
  }

  function test_ConstructorWhenMinterIsZeroAddress(
    address _votingEscrow,
    string calldata _name,
    string calldata _symbol
  ) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    new Token(address(0), _votingEscrow, _MIGRATION, _VELODROME_MIGRATION, _MIGRATION_OPEN, 0, 0, _name, _symbol);
  }

  function test_ConstructorWhenVotingEscrowIsZeroAddress(string calldata _name, string calldata _symbol) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    new Token(_MINTER, address(0), _MIGRATION, _VELODROME_MIGRATION, _MIGRATION_OPEN, 0, 0, _name, _symbol);
  }

  function test_ConstructorWhenMigrationIsZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    new Token(
      _MINTER, _VOTING_ESCROW, address(0), _VELODROME_MIGRATION, _MIGRATION_OPEN, 0, 0, _TOKEN_NAME, _TOKEN_SYMBOL
    );
  }

  function test_ConstructorWhenVelodromeMigrationIsZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    new Token(_MINTER, _VOTING_ESCROW, _MIGRATION, address(0), _MIGRATION_OPEN, 0, 0, _TOKEN_NAME, _TOKEN_SYMBOL);
  }

  function test_ConstructorWhenTheMigrationOpeningTimestampIsNotWeekAligned(uint48 _week, uint48 _offset) external {
    uint48 _maxWeek = uint48(type(uint48).max / _WEEK - 1);
    _week = uint48(bound(_week, 0, _maxWeek));
    _offset = uint48(bound(_offset, 1, _WEEK - 1));
    uint48 _migrationOpen = _week * uint48(_WEEK) + _offset;

    // it should revert with InvalidMigrationOpen
    vm.expectRevert(ITokenExtensions.InvalidMigrationOpen.selector);
    new Token(
      _MINTER, _VOTING_ESCROW, _MIGRATION, _VELODROME_MIGRATION, _migrationOpen, 0, 0, _TOKEN_NAME, _TOKEN_SYMBOL
    );
  }

  function test_ConstructorWhenTheMigrationOpeningTimestampIsNotInTheFuture(
    uint48 _currentWeek,
    uint48 _migrationWeek
  ) external {
    uint48 _maxWeek = uint48(type(uint48).max / _WEEK);
    _currentWeek = uint48(bound(_currentWeek, 1, _maxWeek));
    _migrationWeek = uint48(bound(_migrationWeek, 0, _currentWeek));
    vm.warp(_currentWeek * _WEEK);
    uint48 _migrationOpen = _migrationWeek * uint48(_WEEK);

    // it should revert with InvalidMigrationOpen
    vm.expectRevert(ITokenExtensions.InvalidMigrationOpen.selector);
    new Token(
      _MINTER, _VOTING_ESCROW, _MIGRATION, _VELODROME_MIGRATION, _migrationOpen, 0, 0, _TOKEN_NAME, _TOKEN_SYMBOL
    );
  }

  // solhint-disable-next-line ordering
  function test_ConstructorWhenParametersAreValid(
    uint256 _migrationAllocation,
    uint256 _velodromeAllocation,
    uint48 _migrationOpen
  ) external {
    _velodromeAllocation = bound(_velodromeAllocation, 0, type(uint256).max - _migrationAllocation);
    _migrationOpen = uint48(
      ProtocolTimeLibrary.epochStart(
        bound(_migrationOpen, ProtocolTimeLibrary.epochNext(block.timestamp), type(uint48).max)
      )
    );

    address _expectedToken = _computeCreate(address(this), vm.getNonce(address(this)));

    // it should emit Transfer for the migration allocation
    _expectEmit(_expectedToken);
    emit IERC20.Transfer(address(0), _MIGRATION, _migrationAllocation);
    // it should emit Transfer for the Velodrome migration allocation
    _expectEmit(_expectedToken);
    emit IERC20.Transfer(address(0), _VELODROME_MIGRATION, _velodromeAllocation);

    Token _deployedToken = new Token(
      _MINTER,
      _VOTING_ESCROW,
      _MIGRATION,
      _VELODROME_MIGRATION,
      _migrationOpen,
      _migrationAllocation,
      _velodromeAllocation,
      _TOKEN_NAME,
      _TOKEN_SYMBOL
    );

    // it should set the MINTER immutable to _minter
    assertEq(_deployedToken.MINTER(), _MINTER);
    // it should set the VOTING_ESCROW immutable to _votingEscrow
    assertEq(_deployedToken.VOTING_ESCROW(), _VOTING_ESCROW);
    // it should set the MIGRATION immutable to _migration
    assertEq(_deployedToken.MIGRATION(), _MIGRATION);
    // it should set the VELODROME_MIGRATION immutable to _velodromeMigration
    assertEq(_deployedToken.VELODROME_MIGRATION(), _VELODROME_MIGRATION);
    // it should set TRANSFERS_ENABLED_AT to one week after _migrationOpen
    assertEq(_deployedToken.TRANSFERS_ENABLED_AT(), uint256(_migrationOpen) + _WEEK);
    // it should set the name to _name
    assertEq(_deployedToken.name(), _TOKEN_NAME);
    // it should set the symbol to _symbol
    assertEq(_deployedToken.symbol(), _TOKEN_SYMBOL);
    // it should set the name hash to a hash of _name bytes
    assertEq(_deployedToken.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(_deployedToken), _TOKEN_NAME));
    // it should mint _migrationAllocation to _migration
    assertEq(_deployedToken.balanceOf(_MIGRATION), _migrationAllocation);
    // it should mint _velodromeAllocation to _velodromeMigration
    assertEq(_deployedToken.balanceOf(_VELODROME_MIGRATION), _velodromeAllocation);
    // it should set total supply to the sum of both migration allocations
    assertEq(_deployedToken.totalSupply(), _migrationAllocation + _velodromeAllocation);
  }

  // solhint-disable-next-line ordering
  function test_MintWhenCallerIsNotMinter(address _caller, address _recipient, uint256 _amount) external {
    _caller = _boundNotEq(_caller, _MINTER);
    _assumeFuzzable(_caller);

    // it should revert with NotMinter
    vm.expectRevert(ITokenExtensions.NotMinter.selector);
    vm.prank(_caller);
    _token.mint(_recipient, _amount);
  }

  function test_MintWhenCallerIsMinterAndRecipientIsZeroAddress(uint256 _amount) external {
    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_MINTER);
    _token.mint(address(0), _amount);
  }

  function test_MintWhenCallerIsMinterAndTotalSupplyOverflows(address _recipient) external {
    _assumeFuzzable(_recipient);
    deal(address(_token), _recipient, type(uint256).max, _UPDATE_SUPPLY);

    // it should revert with TotalSupplyOverflow
    vm.expectRevert(ERC20.TotalSupplyOverflow.selector);
    vm.prank(_MINTER);
    _token.mint(_recipient, 1);
  }

  function test_MintWhenCallerIsMinterAndRecipientIsValid(
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, type(uint256).max - _balance);
    deal(address(_token), _recipient, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with address(0), _recipient, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(address(0), _recipient, _amount);

    vm.prank(_MINTER);
    _token.mint(_recipient, _amount);

    // it should mint tokens to the recipient
    assertEq(_token.balanceOf(_recipient), _balance + _amount);
    // it should increase total supply by the amount
    assertEq(_token.totalSupply(), _balance + _amount);
  }

  function test_BurnWhenCallerIsNotAnAuthorizedBurner(address _caller, uint256 _amount) external {
    _caller = _boundNotEq(_caller, _VOTING_ESCROW);
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);

    // it should revert with CallerNotBurner
    vm.expectRevert(ITokenExtensions.CallerNotBurner.selector);
    vm.prank(_caller);
    _token.burn(_amount);
  }

  function test_BurnWhenVotingEscrowHasInsufficientBalance(uint256 _amount) external {
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_VOTING_ESCROW);
    _token.burn(_amount);
  }

  function test_BurnWhenVotingEscrowHasEnoughBalance(uint256 _balance, uint256 _amount) external {
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _VOTING_ESCROW, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _VOTING_ESCROW, address(0), _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_VOTING_ESCROW, address(0), _amount);

    vm.prank(_VOTING_ESCROW);
    _token.burn(_amount);

    // it should burn tokens from voting escrow
    assertEq(_token.balanceOf(_VOTING_ESCROW), _balance - _amount);
    // it should decrease total supply by the amount
    assertEq(_token.totalSupply(), _balance - _amount);
  }

  function test_BurnWhenMigrationHasInsufficientBalance(uint256 _amount) external {
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_MIGRATION);
    _token.burn(_amount);
  }

  function test_BurnWhenMigrationHasEnoughBalance(uint256 _balance, uint256 _amount) external {
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _MIGRATION, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _MIGRATION, address(0), _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_MIGRATION, address(0), _amount);

    vm.prank(_MIGRATION);
    _token.burn(_amount);

    // it should burn tokens from migration
    assertEq(_token.balanceOf(_MIGRATION), _balance - _amount);
    // it should decrease total supply by the amount
    assertEq(_token.totalSupply(), _balance - _amount);
  }

  function test_BurnWhenVelodromeMigrationHasInsufficientBalance(uint256 _amount) external {
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_VELODROME_MIGRATION);
    _token.burn(_amount);
  }

  function test_BurnWhenVelodromeMigrationHasEnoughBalance(uint256 _balance, uint256 _amount) external {
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _VELODROME_MIGRATION, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _VELODROME_MIGRATION, address(0), _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_VELODROME_MIGRATION, address(0), _amount);

    vm.prank(_VELODROME_MIGRATION);
    _token.burn(_amount);

    // it should burn tokens from Velodrome migration
    assertEq(_token.balanceOf(_VELODROME_MIGRATION), _balance - _amount);
    // it should decrease total supply by the amount
    assertEq(_token.totalSupply(), _balance - _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndCallerIsNotAMigrationSender(
    address _caller,
    address _recipient,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transfer(_recipient, _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndCallerIsMigration(
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _recipient = _boundNotEq(_recipient, _MIGRATION);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _MIGRATION, _balance, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    _expectEmit(address(_token));
    emit IERC20.Transfer(_MIGRATION, _recipient, _amount);

    vm.prank(_MIGRATION);
    assertTrue(_token.transfer(_recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_MIGRATION), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndCallerIsVelodromeMigration(
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _recipient = _boundNotEq(_recipient, _VELODROME_MIGRATION);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _VELODROME_MIGRATION, _balance, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    _expectEmit(address(_token));
    emit IERC20.Transfer(_VELODROME_MIGRATION, _recipient, _amount);

    vm.prank(_VELODROME_MIGRATION);
    assertTrue(_token.transfer(_recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_VELODROME_MIGRATION), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndOnlyTheRecipientIsMigration(
    address _caller,
    uint256 _balance,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _caller, _balance, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transfer(_MIGRATION, _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndOnlyTheRecipientIsVelodromeMigration(
    address _caller,
    uint256 _balance,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _caller, _balance, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transfer(_VELODROME_MIGRATION, _amount);
  }

  function test_TransferWhenTransfersAreDisabledAndRecipientIsZeroAddress(address _caller, uint256 _amount) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transfer(address(0), _amount);
  }

  function test_TransferWhenCurrentTimestampEqualsTheTransferActivationTimestamp(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _caller, _balance, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT());

    _expectEmit(address(_token));
    emit IERC20.Transfer(_caller, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transfer(_recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_caller), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferWhenRecipientIsZeroAddress(address _caller, uint256 _amount) external {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_caller);
    _token.transfer(address(0), _amount);
  }

  function test_TransferWhenCallerHasInsufficientBalance(
    address _caller,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_caller);
    _token.transfer(_recipient, _amount);
  }

  function test_TransferWhenCallerHasEnoughBalance(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _caller, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _caller, _recipient, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_caller, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transfer(_recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_caller), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  function test_TransferWhenRecipientIsCaller(address _caller, uint256 _balance, uint256 _amount) external {
    _assumeFuzzable(_caller);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _caller, _balance, _UPDATE_SUPPLY);

    // it should emit Transfer with _caller, _caller, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_caller, _caller, _amount);

    vm.prank(_caller);
    assertTrue(_token.transfer(_caller, _amount));

    // it should keep the caller balance unchanged
    assertEq(_token.balanceOf(_caller), _balance);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  function test_TransferFromWhenTransfersAreDisabledAndFromIsNotAMigrationSender(
    address _caller,
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _from = _boundNotEq(_from, _MIGRATION);
    _from = _boundNotEq(_from, _VELODROME_MIGRATION);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenTransfersAreDisabledAndFromIsMigration(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _MIGRATION);
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _MIGRATION);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _MIGRATION, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _MIGRATION, _caller, _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    _expectEmit(address(_token));
    emit IERC20.Transfer(_MIGRATION, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_MIGRATION, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_MIGRATION), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferFromWhenTransfersAreDisabledAndFromIsVelodromeMigration(
    address _caller,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _caller = _boundNotEq(_caller, _VELODROME_MIGRATION);
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _VELODROME_MIGRATION);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _VELODROME_MIGRATION, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _VELODROME_MIGRATION, _caller, _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    _expectEmit(address(_token));
    emit IERC20.Transfer(_VELODROME_MIGRATION, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_VELODROME_MIGRATION, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_VELODROME_MIGRATION), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferFromWhenTransfersAreDisabledAndOnlyTheCallerIsMigration(
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _from = _boundNotEq(_from, _MIGRATION);
    _from = _boundNotEq(_from, _VELODROME_MIGRATION);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _MIGRATION, _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_MIGRATION);
    _token.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenTransfersAreDisabledAndOnlyTheRecipientIsMigration(
    address _caller,
    address _from,
    uint256 _balance,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _from = _boundNotEq(_from, _MIGRATION);
    _from = _boundNotEq(_from, _VELODROME_MIGRATION);
    _assumeFuzzable(_from);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, _MIGRATION, _amount);
  }

  function test_TransferFromWhenTransfersAreDisabledAndRecipientIsZeroAddress(
    address _caller,
    address _from,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _from = _boundNotEq(_from, _MIGRATION);
    _from = _boundNotEq(_from, _VELODROME_MIGRATION);
    _assumeFuzzable(_from);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    // it should revert with TransfersDisabled
    vm.expectRevert(ITokenExtensions.TransfersDisabled.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, address(0), _amount);
  }

  function test_TransferFromWhenCurrentTimestampEqualsTheTransferActivationTimestamp(
    address _caller,
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external {
    _from = _boundNotEq(_from, _MIGRATION);
    _from = _boundNotEq(_from, _VELODROME_MIGRATION);
    _assumeFuzzable(_from);
    _caller = _boundNotEq(_caller, _from);
    _assumeFuzzable(_caller);
    _recipient = _boundNotEq(_recipient, _from);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT());

    _expectEmit(address(_token));
    emit IERC20.Transfer(_from, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_from, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_from), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
  }

  function test_TransferFromWhenRecipientIsZeroAddress(address _caller, address _from, uint256 _amount) external {
    _assumeFuzzable(_caller);

    // it should revert with ZeroAddress
    vm.expectRevert(IBaseTokenExtensions.ZeroAddress.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, address(0), _amount);
  }

  function test_TransferFromWhenFromAddressHasInsufficientBalance(
    address _caller,
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);
    _mockApprove(address(_token), _from, _caller, _amount);

    // it should revert with InsufficientBalance
    vm.expectRevert(ERC20.InsufficientBalance.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenCallerHasInsufficientAllowance(
    address _caller,
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientAllowance
    vm.expectRevert(ERC20.InsufficientAllowance.selector);
    vm.prank(_caller);
    _token.transferFrom(_from, _recipient, _amount);
  }

  function test_TransferFromWhenCallerIsPermitTwoAndNoApprovalHasBeenGiven(
    address _from,
    address _recipient,
    uint256 _amount
  ) external {
    _assumeFuzzable(_recipient);
    _amount = bound(_amount, 1, type(uint256).max);

    // it should revert with InsufficientAllowance
    vm.expectRevert(ERC20.InsufficientAllowance.selector);
    vm.prank(_PERMIT_TWO);
    _token.transferFrom(_from, _recipient, _amount);
  }

  modifier whenCallerHasFiniteAllowance() {
    _;
  }

  function test_TransferFromWhenFiniteAllowanceRecipientIsNotFrom(
    address _caller,
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _allowance,
    uint256 _amount
  ) external whenCallerHasFiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _from);
    _allowance = bound(_allowance, 0, type(uint256).max - 1);
    uint256 _maxAmount = _balance < _allowance ? _balance : _allowance;
    _amount = bound(_amount, 0, _maxAmount);

    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, _allowance);

    // it should emit Transfer with _from, _recipient, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_from, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_from, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_from), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
    // it should decrease the caller allowance
    assertEq(_token.allowance(_from, _caller), _allowance - _amount);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  function test_TransferFromWhenFiniteAllowanceRecipientIsFrom(
    address _caller,
    address _from,
    uint256 _balance,
    uint256 _allowance,
    uint256 _amount
  ) external whenCallerHasFiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _allowance = bound(_allowance, 0, type(uint256).max - 1);
    uint256 _maxAmount = _balance < _allowance ? _balance : _allowance;
    _amount = bound(_amount, 0, _maxAmount);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, _allowance);

    // it should emit Transfer with _from, _from, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_from, _from, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_from, _from, _amount));

    // it should keep the from balance unchanged
    assertEq(_token.balanceOf(_from), _balance);
    // it should decrease the caller allowance
    assertEq(_token.allowance(_from, _caller), _allowance - _amount);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  modifier whenCallerHasInfiniteAllowance() {
    _;
  }

  function test_TransferFromWhenInfiniteAllowanceRecipientIsNotFrom(
    address _caller,
    address _from,
    address _recipient,
    uint256 _balance,
    uint256 _amount
  ) external whenCallerHasInfiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _assumeFuzzable(_recipient);
    vm.assume(_recipient != _from);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, type(uint256).max);

    // it should emit Transfer with _from, _recipient, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_from, _recipient, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_from, _recipient, _amount));

    // it should transfer tokens to the recipient
    assertEq(_token.balanceOf(_from), _balance - _amount);
    assertEq(_token.balanceOf(_recipient), _amount);
    // it should keep the caller allowance unchanged
    assertEq(_token.allowance(_from, _caller), type(uint256).max);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  function test_TransferFromWhenInfiniteAllowanceRecipientIsFrom(
    address _caller,
    address _from,
    uint256 _balance,
    uint256 _amount
  ) external whenCallerHasInfiniteAllowance {
    _assumeFuzzable(_caller);
    _assumeFuzzable(_from);
    _amount = bound(_amount, 0, _balance);
    deal(address(_token), _from, _balance, _UPDATE_SUPPLY);
    _mockApprove(address(_token), _from, _caller, type(uint256).max);

    // it should emit Transfer with _from, _from, _amount
    _expectEmit(address(_token));
    emit IERC20.Transfer(_from, _from, _amount);

    vm.prank(_caller);
    assertTrue(_token.transferFrom(_from, _from, _amount));

    // it should keep the from balance unchanged
    assertEq(_token.balanceOf(_from), _balance);
    // it should keep the caller allowance unchanged
    assertEq(_token.allowance(_from, _caller), type(uint256).max);
    // it should keep total supply unchanged
    assertEq(_token.totalSupply(), _balance);
  }

  function test_ApproveWhenCalled(address _owner, address _spender, uint256 _amount) external {
    _assumeFuzzable(_owner);

    // it should emit Approval with _owner, _spender, _amount
    _expectEmit(address(_token));
    emit IERC20.Approval(_owner, _spender, _amount);

    vm.prank(_owner);
    _token.approve(_spender, _amount);

    // it should approve the spender
    assertEq(_token.allowance(_owner, _spender), _amount);
  }

  function test_ApproveWhenSpenderIsPermitTwo(address _owner, uint256 _amount) external {
    _assumeFuzzable(_owner);

    // it should emit Approval with _owner, PermitTwo, _amount
    _expectEmit(address(_token));
    emit IERC20.Approval(_owner, _PERMIT_TWO, _amount);

    vm.prank(_owner);
    _token.approve(_PERMIT_TWO, _amount);

    // it should approve PermitTwo
    assertEq(_token.allowance(_owner, _PERMIT_TWO), _amount);
  }

  // solhint-disable-next-line ordering
  function test_AllowanceWhenSpenderIsPermitTwoAndNoApprovalHasBeenGiven(address _owner) external view {
    // it should return zero
    assertEq(_token.allowance(_owner, _PERMIT_TWO), 0);
  }

  function test_AllowanceWhenSpenderIsPermitTwoAndApprovalHasBeenGiven(address _owner, uint256 _amount) external {
    _mockApprove(address(_token), _owner, _PERMIT_TWO, _amount);

    // it should return its allowance
    assertEq(_token.allowance(_owner, _PERMIT_TWO), _amount);
  }

  function test_AllowanceWhenSpenderIsAnyNonPermitTwoAddressAndNoApprovalHasBeenGiven(
    address _owner,
    address _spender
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);

    // it should return zero
    assertEq(_token.allowance(_owner, _spender), 0);
  }

  function test_AllowanceWhenSpenderIsAnyNonPermitTwoAddressAndApprovalHasBeenGiven(
    address _owner,
    address _spender,
    uint256 _amount
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);
    _mockApprove(address(_token), _owner, _spender, _amount);

    // it should return its allowance
    assertEq(_token.allowance(_owner, _spender), _amount);
  }

  function test_PermitWhenDeadlineHasExpired(address _spender, uint256 _amount, uint256 _deadline) external {
    vm.warp(1 days);
    _deadline = bound(_deadline, 0, block.timestamp - 1);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_token), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should revert with PermitExpired
    vm.expectRevert(ERC20.PermitExpired.selector);
    _token.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSignatureIsInvalid(
    address _spender,
    address _invalidSpender,
    uint256 _amount,
    uint256 _deadline
  ) external {
    _invalidSpender = _boundNotEq(_invalidSpender, _spender);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_token), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should revert with InvalidPermit
    vm.expectRevert(ERC20.InvalidPermit.selector);
    _token.permit(_permitOwner, _invalidSpender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSignatureIsReplayed(address _spender, uint256 _amount, uint256 _deadline) external {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_token), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    _token.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);

    // it should revert with InvalidPermit
    vm.expectRevert(ERC20.InvalidPermit.selector);
    _token.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);
  }

  function test_PermitWhenSpenderIsPermitTwoAndSignatureIsValid(uint256 _amount, uint256 _deadline) external {
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_token), _PERMIT_OWNER_PK, _permitOwner, _PERMIT_TWO, _amount, _deadline);

    // it should emit Approval with _permitOwner, PermitTwo, _amount
    _expectEmit(address(_token));
    emit IERC20.Approval(_permitOwner, _PERMIT_TWO, _amount);

    _token.permit(_permitOwner, _PERMIT_TWO, _amount, _deadline, _v, _r, _s);

    // it should approve PermitTwo
    assertEq(_token.allowance(_permitOwner, _PERMIT_TWO), _amount);
    // it should increment the owner nonce
    assertEq(_token.nonces(_permitOwner), 1);
  }

  function test_PermitWhenSpenderIsNotPermitTwoAndSignatureIsValid(
    address _spender,
    uint256 _amount,
    uint256 _deadline
  ) external {
    _spender = _boundNotEq(_spender, _PERMIT_TWO);
    _deadline = bound(_deadline, block.timestamp, type(uint256).max);
    (uint8 _v, bytes32 _r, bytes32 _s) =
      _signedPermit(address(_token), _PERMIT_OWNER_PK, _permitOwner, _spender, _amount, _deadline);

    // it should emit Approval with _permitOwner, _spender, _amount
    _expectEmit(address(_token));
    emit IERC20.Approval(_permitOwner, _spender, _amount);

    _token.permit(_permitOwner, _spender, _amount, _deadline, _v, _r, _s);

    // it should approve the spender
    assertEq(_token.allowance(_permitOwner, _spender), _amount);
    // it should increment the owner nonce
    assertEq(_token.nonces(_permitOwner), 1);
  }

  function test_DOMAIN_SEPARATORWhenCalled() external view {
    // it should return the expected domain separator
    assertEq(_token.DOMAIN_SEPARATOR(), _expectedDomainSeparator(address(_token), _TOKEN_NAME));
  }

  function test_NameWhenCalled() external view {
    // it should return the token name
    assertEq(_token.name(), _TOKEN_NAME);
  }

  function test_SymbolWhenCalled() external view {
    // it should return the token symbol
    assertEq(_token.symbol(), _TOKEN_SYMBOL);
  }

  /*////////////////////////////////////////////////////////////
                              GAS
  ////////////////////////////////////////////////////////////*/

  function testGas_constructor() external {
    uint48 _migrationOpen = uint48(ProtocolTimeLibrary.epochNext(block.timestamp));
    new Token(
      _MINTER,
      _VOTING_ESCROW,
      _MIGRATION,
      _VELODROME_MIGRATION,
      _migrationOpen,
      100 ether,
      200 ether,
      _TOKEN_NAME,
      _TOKEN_SYMBOL
    );
    vm.snapshotGasLastCall('Token_constructor');
  }

  function testGas_burn() external {
    uint256 _amount = 100 ether;
    deal(address(_token), _VELODROME_MIGRATION, 2 * _amount, _UPDATE_SUPPLY);

    vm.prank(_VELODROME_MIGRATION);
    _token.burn(_amount);
    vm.snapshotGasLastCall('Token_burn');
  }

  function testGas_transfer() external {
    address _recipient = makeAddr('Recipient');
    uint256 _amount = 100 ether;
    deal(address(_token), _VELODROME_MIGRATION, 2 * _amount, _UPDATE_SUPPLY);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    vm.prank(_VELODROME_MIGRATION);
    _token.transfer(_recipient, _amount);
    vm.snapshotGasLastCall('Token_transfer');
  }

  function testGas_transferFrom() external {
    address _spender = makeAddr('Spender');
    address _recipient = makeAddr('Recipient');
    uint256 _amount = 100 ether;
    deal(address(_token), _VELODROME_MIGRATION, 2 * _amount, _UPDATE_SUPPLY);

    vm.prank(_VELODROME_MIGRATION);
    _token.approve(_spender, 2 * _amount);
    vm.warp(_token.TRANSFERS_ENABLED_AT() - 1);

    vm.prank(_spender);
    _token.transferFrom(_VELODROME_MIGRATION, _recipient, _amount);
    vm.snapshotGasLastCall('Token_transferFrom');
  }
}
