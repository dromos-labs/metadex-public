// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IMailbox} from '@hyperlane/contracts/interfaces/IMailbox.sol';
import {Ownable} from '@openzeppelin/contracts/access/Ownable.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {IVelodromeMigrationEntrypoint} from 'V3/interfaces/migration/IVelodromeMigrationEntrypoint.sol';
import {ITokenExtensions} from 'V3/interfaces/token/ITokenExtensions.sol';

import {VelodromeMigrationEntrypoint} from 'V3/migration/VelodromeMigrationEntrypoint.sol';

import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitVelodromeMigrationEntrypoint is TestHelpers {
  /// @dev TOKEN budget equal to 5.5% of the 2.5 billion VELO basis budget used in VelodromeMigration tests
  uint256 internal constant _BUDGET = 137_500_000 ether;
  uint32 internal constant _LOCAL_DOMAIN = 8453;
  uint32 internal constant _OP_DOMAIN = 10;

  address internal _owner = makeAddr('_owner');
  address internal _v3Token;
  address internal _v3Escrow;
  address internal _mailbox;

  /// @dev Default Velodrome migration entrypoint constructor parameters
  IVelodromeMigrationEntrypoint.EntrypointParams internal _params;

  /// @dev Velodrome migration entrypoint instance
  VelodromeMigrationEntrypoint internal _entrypoint;

  function setUp() public virtual {
    _v3Token = _mockContract('_v3Token');
    _v3Escrow = _mockContract('_v3Escrow');
    _mailbox = _mockContract('_mailbox');

    _params = IVelodromeMigrationEntrypoint.EntrypointParams({
      owner: _owner, token: _v3Token, v3Escrow: _v3Escrow, mailbox: _mailbox, opDomain: _OP_DOMAIN
    });

    vm.mockCall(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_LOCAL_DOMAIN));
    _entrypoint = new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheOwnerIsTheZeroAddress() external {
    // it should revert with OwnableInvalidOwner
    _params.owner = address(0);

    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheV3TokenIsTheZeroAddress() external {
    _params.token = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVelodromeMigrationEntrypoint.ZeroAddress.selector);
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheV3VotingEscrowIsTheZeroAddress() external {
    _params.v3Escrow = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVelodromeMigrationEntrypoint.ZeroAddress.selector);
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheHyperlaneMailboxIsTheZeroAddress() external {
    _params.mailbox = address(0);

    // it should revert with ZeroAddress
    vm.expectRevert(IVelodromeMigrationEntrypoint.ZeroAddress.selector);
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheOPDomainIsZero() external {
    _params.opDomain = 0;

    // it should revert with InvalidDomain
    vm.expectRevert(IVelodromeMigrationEntrypoint.InvalidDomain.selector);
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenTheOPDomainIsEqualToTheMailboxLocalDomain(uint32 _localDomain) external {
    _localDomain = uint32(bound(_localDomain, 1, type(uint32).max));
    _params.opDomain = _localDomain;
    _mockAndExpect(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_localDomain));

    // it should revert with InvalidDomain
    vm.expectRevert(IVelodromeMigrationEntrypoint.InvalidDomain.selector);
    new VelodromeMigrationEntrypoint(_params);
  }

  function test_ConstructorWhenPassingValidParameters() external {
    // it should call localDomain on the Hyperlane mailbox
    _mockAndExpect(_mailbox, abi.encodeCall(IMailbox.localDomain, ()), abi.encode(_LOCAL_DOMAIN));

    _entrypoint = new VelodromeMigrationEntrypoint(_params);

    // it should set the owner
    assertEq(_entrypoint.owner(), _owner);

    // it should set the entrypoint configuration
    assertEq(address(_entrypoint.V3_TOKEN()), _v3Token);
    assertEq(address(_entrypoint.V3_ESCROW()), _v3Escrow);
    assertEq(address(_entrypoint.MAILBOX()), _mailbox);
    assertEq(_entrypoint.OP_DOMAIN(), _OP_DOMAIN);
  }

  function test_OnERC721ReceivedWhenTheCallerIsNotTheV3VotingEscrow(
    address _caller,
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external {
    _caller = _boundNotEq(_caller, _v3Escrow);
    _assumeFuzzable(_caller);

    // it should revert with InvalidERC721Transfer
    vm.expectRevert(IVelodromeMigrationEntrypoint.InvalidERC721Transfer.selector);
    vm.prank(_caller);
    _entrypoint.onERC721Received(address(_entrypoint), _from, _tokenId, _data);
  }

  modifier whenTheCallerIsTheV3VotingEscrow() {
    vm.startPrank(_v3Escrow);
    _;
    vm.stopPrank();
  }

  function test_OnERC721ReceivedWhenTheOperatorIsNotTheEntrypointContract(
    address _operator,
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external whenTheCallerIsTheV3VotingEscrow {
    _operator = _boundNotEq(_operator, address(_entrypoint));

    // it should revert with InvalidERC721Transfer
    vm.expectRevert(IVelodromeMigrationEntrypoint.InvalidERC721Transfer.selector);
    _entrypoint.onERC721Received(_operator, _from, _tokenId, _data);
  }

  function test_OnERC721ReceivedWhenTheOperatorIsTheEntrypointContract(
    address _from,
    uint256 _tokenId,
    bytes calldata _data
  ) external whenTheCallerIsTheV3VotingEscrow {
    // it should return the ERC721 receiver selector
    bytes4 _selector = _entrypoint.onERC721Received(address(_entrypoint), _from, _tokenId, _data);
    assertEq(_selector, IERC721Receiver.onERC721Received.selector);
  }

  function test_BurnRemainingWhenTheCallerIsNotTheOwner(address _caller) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _entrypoint.burnRemaining();
  }

  function test_BurnRemainingWhenTheRemainingBalanceIsZero() external {
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_entrypoint), [uint256(0), 0]);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (uint256(0))), abi.encode());

    // it should return zero from remaining
    assertEq(_entrypoint.remaining(), 0);

    // it should burn zero

    // it should emit RemainingBurned with zero
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.RemainingBurned(0);

    vm.prank(_owner);
    _entrypoint.burnRemaining();
  }

  function test_BurnRemainingWhenTheRemainingBalanceIsPositive(uint256 _remaining) external {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_entrypoint), [_remaining, _remaining]);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    // it should return the remaining balance
    assertEq(_entrypoint.remaining(), _remaining);

    // it should burn the full remaining balance

    // it should emit RemainingBurned with the remaining balance
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.RemainingBurned(_remaining);

    vm.prank(_owner);
    _entrypoint.burnRemaining();
  }

  function test_BurnRemainingWhenBurnRemainingIsCalledRepeatedly(uint256 _remaining) external {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _mockAndExpectTokenBalancesTwice(_v3Token, address(_entrypoint), [_remaining, 0]);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    vm.prank(_owner);
    _entrypoint.burnRemaining();

    // it should burn zero on the repeated call
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (uint256(0))), abi.encode());

    // it should emit RemainingBurned with zero on the repeated call
    _expectEmit(address(_entrypoint));
    emit IVelodromeMigrationEntrypoint.RemainingBurned(0);

    vm.prank(_owner);
    _entrypoint.burnRemaining();
  }

  function testGas_burnRemaining() external {
    uint256 _remaining = 100 ether;
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _remaining);
    _mockAndExpect(_v3Token, abi.encodeCall(ITokenExtensions.burn, (_remaining)), abi.encode());

    vm.prank(_owner);
    _entrypoint.burnRemaining();
    vm.snapshotGasLastCall('UnitVelodromeMigrationEntrypoint', 'VelodromeMigrationEntrypoint_burnRemaining');
  }

  function test_RenounceOwnershipWhenTheCallerIsNotTheOwner(address _caller) external {
    _caller = _boundNotEq(_caller, _owner);
    _assumeFuzzable(_caller);

    // it should revert with OwnableUnauthorizedAccount
    vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, _caller));
    vm.prank(_caller);
    _entrypoint.renounceOwnership();
  }

  function test_RenounceOwnershipWhenTheRemainingBalanceIsPositive(uint256 _remaining) external {
    _remaining = bound(_remaining, 1, type(uint256).max);
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), _remaining);

    // it should revert with RemainingBalance
    vm.expectRevert(IVelodromeMigrationEntrypoint.RemainingBalance.selector);
    vm.prank(_owner);
    _entrypoint.renounceOwnership();
  }

  function test_RenounceOwnershipWhenTheRemainingBalanceIsZero() external {
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), 0);

    // it should emit OwnershipTransferred
    _expectEmit(address(_entrypoint));
    emit Ownable.OwnershipTransferred(_owner, address(0));

    vm.prank(_owner);
    _entrypoint.renounceOwnership();

    // it should renounce ownership
    assertEq(_entrypoint.owner(), address(0));
  }

  function testGas_renounceOwnership() external {
    _mockAndExpectTokenBalance(_v3Token, address(_entrypoint), 0);

    vm.prank(_owner);
    _entrypoint.renounceOwnership();
    vm.snapshotGasLastCall('UnitVelodromeMigrationEntrypoint', 'VelodromeMigrationEntrypoint_renounceOwnership');
  }

  /// @dev Encodes a Velodrome migration settlement message
  function _encodeMigrationMessage(
    uint64 _nonce,
    address _recipient,
    uint256 _tokenAmount,
    bool _isLiquid,
    bool _isPermanent,
    uint48 _durationWeeks
  ) internal pure returns (bytes memory) {
    return abi.encodePacked(_nonce, _recipient, _tokenAmount, _isLiquid, _isPermanent, _durationWeeks);
  }
}
