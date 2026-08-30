// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC721Errors} from '@openzeppelin/contracts/interfaces/draft-IERC6093.sol';
import {Vm} from 'forge-std/Vm.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

import {TokenNFT} from 'V3/tokenRegistry/TokenNFT.sol';

import {RecordReadingReceiver} from 'V3-test/mocks/RecordReadingReceiver.sol';
import {RevertingReceiver} from 'V3-test/mocks/RevertingReceiver.sol';
import {TestHelpers} from 'V3-test/utils/TestHelpers.sol';

contract UnitTokenNFT is TestHelpers {
  string internal constant _NAME = 'Token NFT';
  string internal constant _SYMBOL = 'TNFT';

  // ERC721 base storage slots, followed by `TokenNFT`'s own `_recordOf` mapping. `LEAF_VOTER` and `TOKEN_REGISTRY` are
  // immutable, so they hold no slot: `_name` (0), `_symbol` (1), `_owners` (2), `_balances` (3), `_tokenApprovals` (4),
  // `_operatorApprovals` (5), then `_recordOf` (6).
  uint256 internal constant _OWNERS_SLOT = 2;
  uint256 internal constant _BALANCES_SLOT = 3;
  uint256 internal constant _TOKEN_APPROVALS_SLOT = 4;
  uint256 internal constant _OPERATOR_APPROVALS_SLOT = 5;
  uint256 internal constant _RECORD_OF_SLOT = 6;

  address internal _leafVoter;
  address internal immutable _REGISTRY = makeAddr('registry');
  address internal immutable _SEIZER = makeAddr('seizer');

  TokenNFT internal _nft;

  function setUp() external {
    _leafVoter = _mockContract('LeafVoter');
    _nft = new TokenNFT(_NAME, _SYMBOL, _leafVoter, _REGISTRY);
  }

  // --- constructor ---

  function test_ConstructorWhenTheLeafVoterIsTheZeroAddress() external {
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenNFT.ZeroAddress.selector);
    new TokenNFT(_NAME, _SYMBOL, address(0), _REGISTRY);
  }

  function test_ConstructorWhenTheTokenRegistryIsTheZeroAddress(address _newLeafVoter) external {
    _assumeFuzzable(_newLeafVoter);
    // it should revert with ZeroAddress
    vm.expectRevert(ITokenNFT.ZeroAddress.selector);
    new TokenNFT(_NAME, _SYMBOL, _newLeafVoter, address(0));
  }

  function test_ConstructorWhenTheParametersAreValid(address _newLeafVoter, address _newRegistry) external {
    _assumeFuzzable(_newLeafVoter);
    _assumeFuzzable(_newRegistry);
    TokenNFT _fresh = new TokenNFT(_NAME, _SYMBOL, _newLeafVoter, _newRegistry);

    // it should set the name
    assertEq(_fresh.name(), _NAME);
    // it should set the symbol
    assertEq(_fresh.symbol(), _SYMBOL);
    // it should set the LEAF VOTER immutable
    assertEq(_fresh.LEAF_VOTER(), _newLeafVoter);
    // it should set the TOKEN REGISTRY immutable
    assertEq(_fresh.TOKEN_REGISTRY(), _newRegistry);
  }

  // --- mint ---

  function test_MintWhenTheCallerIsNotTheRegistry(address _caller, uint256 _id, address _to) external {
    _caller = _boundNotEq(_caller, _REGISTRY);

    // it should revert with NotRegistry
    vm.expectRevert(ITokenNFT.NotRegistry.selector);
    vm.prank(_caller);
    _nft.mint(_id, _to, new ITokenNFT.TextRecord[](0));
  }

  modifier givenTheCallerIsTheRegistry() {
    vm.startPrank(_REGISTRY);
    _;
    vm.stopPrank();
  }

  function test_MintWhenThereAreNoRecords(uint256 _id, address _to) external givenTheCallerIsTheRegistry {
    _assumeFuzzable(_to);
    vm.assume(_to.code.length == 0);

    vm.recordLogs();
    _nft.mint(_id, _to, new ITokenNFT.TextRecord[](0));

    // it should mint the id to the recipient
    assertEq(_nft.ownerOf(_id), _to);
    // it should not emit RecordChanged
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    bytes32 _recordChangedTopic = keccak256('RecordChanged(uint256,string,string,string)');
    for (uint256 _i; _i < _logs.length; ++_i) {
      assertTrue(_logs[_i].topics[0] != _recordChangedTopic);
    }
  }

  function test_MintWhenThereAreRecords(
    uint256 _id,
    address _to,
    uint8 _count,
    string memory _key,
    string memory _value
  ) external givenTheCallerIsTheRegistry {
    _assumeFuzzable(_to);
    vm.assume(_to.code.length == 0);
    _count = uint8(bound(_count, 1, 10));
    // Index-suffixed keys stay distinct, proving one `RecordChanged` per record and one stored value per key.
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _records[_i] = ITokenNFT.TextRecord({
        key: string.concat(_key, vm.toString(_i)), value: string.concat(_value, vm.toString(_i))
      });
    }

    // it should emit RecordChanged with _id, _indexedKey, _key, _value for each record
    for (uint256 _i; _i < _count; ++_i) {
      _expectEmit(address(_nft));
      emit ITokenNFT.RecordChanged(_id, _records[_i].key, _records[_i].key, _records[_i].value);
    }

    _nft.mint(_id, _to, _records);

    // it should mint the id to the recipient
    assertEq(_nft.ownerOf(_id), _to);
    // it should write each record value
    string[] memory _keys = new string[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _keys[_i] = _records[_i].key;
    }
    string[] memory _readValues = _nft.records(_id, _keys);
    for (uint256 _i; _i < _count; ++_i) {
      assertEq(_readValues[_i], _records[_i].value);
    }
  }

  function test_MintWhenTheRecipientIsAReceiverContract(
    uint256 _id,
    uint8 _count,
    string memory _key,
    string memory _value
  ) external givenTheCallerIsTheRegistry {
    _count = uint8(bound(_count, 1, 10));
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](_count);
    string[] memory _keys = new string[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _records[_i] = ITokenNFT.TextRecord({
        key: string.concat(_key, vm.toString(_i)), value: string.concat(_value, vm.toString(_i))
      });
      _keys[_i] = _records[_i].key;
    }
    RecordReadingReceiver _receiver = new RecordReadingReceiver(_keys);

    _nft.mint(_id, address(_receiver), _records);

    // it should mint the id to the recipient
    assertEq(_nft.ownerOf(_id), address(_receiver));
    // it should write the records before invoking the receiver
    string[] memory _seenValues = _receiver.seenValues();
    for (uint256 _i; _i < _count; ++_i) {
      assertEq(_seenValues[_i], _records[_i].value);
    }
  }

  // --- setRecord ---

  function test_SetRecordWhenTheIdDoesNotExist(
    uint256 _id,
    address _caller,
    string memory _key,
    string memory _value
  ) external {
    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id));
    vm.prank(_caller);
    _nft.setRecord(_id, _key, _value);
  }

  /// @notice Seeds the fuzzed owner for the id, which is what makes the id exist.
  modifier givenTheIdExists(uint256 _id, address _owner) {
    _assumeFuzzable(_owner);
    _seedOwner(_id, _owner);
    _;
  }

  function test_SetRecordWhenTheCallerIsNotAuthorized(
    uint256 _id,
    address _owner,
    address _caller,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _caller = _boundNotEq(_caller, _owner);

    // it should revert with NotAuthorized
    vm.expectRevert(ITokenNFT.NotAuthorized.selector);
    vm.prank(_caller);
    _nft.setRecord(_id, _key, _value);
  }

  /// @notice Pranks the write in the test body as the id's owner.
  modifier givenTheCallerIsTheOwner(address _owner) {
    vm.prank(_owner);
    _;
  }

  function test_SetRecordWhenTheKeyIsUnset(
    uint256 _id,
    address _owner,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) givenTheCallerIsTheOwner(_owner) {
    // it should emit RecordChanged with _id, _indexedKey, _key, _value
    _expectEmit(address(_nft));
    emit ITokenNFT.RecordChanged(_id, _key, _key, _value);

    _nft.setRecord(_id, _key, _value);

    // it should write the record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_SetRecordWhenTheKeyAlreadyHoldsAValue(
    uint256 _id,
    address _owner,
    string memory _key,
    bytes32 _previousSeed,
    uint256 _previousLengthSeed,
    string memory _value
  ) external givenTheIdExists(_id, _owner) givenTheCallerIsTheOwner(_owner) {
    _seedRecord(_id, _key, _boundedShortText(_previousSeed, _previousLengthSeed));

    // it should emit RecordChanged with _id, _indexedKey, _key, _value
    _expectEmit(address(_nft));
    emit ITokenNFT.RecordChanged(_id, _key, _key, _value);

    _nft.setRecord(_id, _key, _value);

    // it should overwrite the previous value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_SetRecordWhenTheCallerIsApprovedForTheToken(
    uint256 _id,
    address _owner,
    address _approved,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _approved = _boundNotEq(_approved, _owner);
    // Seed a per-token approval directly, so the approved address is authorized without calling the contract.
    vm.store(address(_nft), keccak256(abi.encode(_id, _TOKEN_APPROVALS_SLOT)), bytes32(uint256(uint160(_approved))));

    // it should emit RecordChanged with _id, _indexedKey, _key, _value
    _expectEmit(address(_nft));
    emit ITokenNFT.RecordChanged(_id, _key, _key, _value);

    vm.prank(_approved);
    _nft.setRecord(_id, _key, _value);

    // it should write the record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_SetRecordWhenTheCallerIsApprovedForAll(
    uint256 _id,
    address _owner,
    address _operator,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _operator = _boundNotEq(_operator, _owner);
    // Seed an operator approval (owner => operator => true) directly, so the operator is authorized for every id.
    bytes32 _ownerSlot = keccak256(abi.encode(_owner, _OPERATOR_APPROVALS_SLOT));
    vm.store(address(_nft), keccak256(abi.encode(_operator, _ownerSlot)), bytes32(uint256(1)));

    // it should emit RecordChanged with _id, _indexedKey, _key, _value
    _expectEmit(address(_nft));
    emit ITokenNFT.RecordChanged(_id, _key, _key, _value);

    vm.prank(_operator);
    _nft.setRecord(_id, _key, _value);

    // it should write the record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  // --- setRecords ---

  function test_SetRecordsWhenTheIdDoesNotExist(
    uint256 _id,
    address _caller,
    string memory _key,
    string memory _value
  ) external {
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](1);
    _records[0] = ITokenNFT.TextRecord({key: _key, value: _value});

    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id));
    vm.prank(_caller);
    _nft.setRecords(_id, _records);
  }

  function test_SetRecordsWhenTheCallerIsNotAuthorized(
    uint256 _id,
    address _owner,
    address _caller,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _caller = _boundNotEq(_caller, _owner);
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](1);
    _records[0] = ITokenNFT.TextRecord({key: _key, value: _value});

    // it should revert with NotAuthorized
    vm.expectRevert(ITokenNFT.NotAuthorized.selector);
    vm.prank(_caller);
    _nft.setRecords(_id, _records);
  }

  function test_SetRecordsWhenThereAreRecords(
    uint256 _id,
    address _owner,
    uint8 _count,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) givenTheCallerIsTheOwner(_owner) {
    _count = uint8(bound(_count, 1, 10));
    // Index-suffixed keys stay distinct, proving one `RecordChanged` per record and one stored value per key.
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _records[_i] = ITokenNFT.TextRecord({
        key: string.concat(_key, vm.toString(_i)), value: string.concat(_value, vm.toString(_i))
      });
    }

    // it should emit RecordChanged with _id, _indexedKey, _key, _value for each record
    for (uint256 _i; _i < _count; ++_i) {
      _expectEmit(address(_nft));
      emit ITokenNFT.RecordChanged(_id, _records[_i].key, _records[_i].key, _records[_i].value);
    }

    _nft.setRecords(_id, _records);

    // it should write each record value
    string[] memory _keys = new string[](_count);
    for (uint256 _i; _i < _count; ++_i) {
      _keys[_i] = _records[_i].key;
    }
    string[] memory _readValues = _nft.records(_id, _keys);
    for (uint256 _i; _i < _count; ++_i) {
      assertEq(_readValues[_i], _records[_i].value);
    }
  }

  function test_SetRecordsWhenThereAreNoRecords(
    uint256 _id,
    address _owner
  ) external givenTheIdExists(_id, _owner) givenTheCallerIsTheOwner(_owner) {
    vm.recordLogs();
    _nft.setRecords(_id, new ITokenNFT.TextRecord[](0));

    // it should not emit RecordChanged
    Vm.Log[] memory _logs = vm.getRecordedLogs();
    assertEq(_logs.length, 0);
  }

  function test_SetRecordsWhenTheBatchContainsDuplicateKeys(
    uint256 _id,
    address _owner,
    string memory _key,
    string memory _firstValue,
    string memory _lastValue
  ) external givenTheIdExists(_id, _owner) givenTheCallerIsTheOwner(_owner) {
    // Both records share one key, so only the later write may survive.
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](2);
    _records[0] = ITokenNFT.TextRecord({key: _key, value: _firstValue});
    _records[1] = ITokenNFT.TextRecord({key: _key, value: _lastValue});

    _nft.setRecords(_id, _records);

    // it should store the last value for the duplicated key
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _lastValue);
  }

  function test_SetRecordsWhenTheCallerIsApprovedForTheToken(
    uint256 _id,
    address _owner,
    address _approved,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _approved = _boundNotEq(_approved, _owner);
    vm.store(address(_nft), keccak256(abi.encode(_id, _TOKEN_APPROVALS_SLOT)), bytes32(uint256(uint160(_approved))));
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](1);
    _records[0] = ITokenNFT.TextRecord({key: _key, value: _value});

    vm.prank(_approved);
    _nft.setRecords(_id, _records);

    // it should write each record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_SetRecordsWhenTheCallerIsApprovedForAll(
    uint256 _id,
    address _owner,
    address _operator,
    string memory _key,
    string memory _value
  ) external givenTheIdExists(_id, _owner) {
    _operator = _boundNotEq(_operator, _owner);
    bytes32 _ownerSlot = keccak256(abi.encode(_owner, _OPERATOR_APPROVALS_SLOT));
    vm.store(address(_nft), keccak256(abi.encode(_operator, _ownerSlot)), bytes32(uint256(1)));
    ITokenNFT.TextRecord[] memory _records = new ITokenNFT.TextRecord[](1);
    _records[0] = ITokenNFT.TextRecord({key: _key, value: _value});

    vm.prank(_operator);
    _nft.setRecords(_id, _records);

    // it should write each record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  // --- seize ---

  function test_SeizeWhenTheCallerIsNotASeizer(uint256 _id, address _caller, address _to) external {
    _mockAndExpect(_leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.SEIZER_ROLE, _caller)), abi.encode(false));

    // it should revert with NotSeizer
    vm.expectRevert(ITokenNFT.NotSeizer.selector);
    vm.prank(_caller);
    _nft.seize(_id, _to);
  }

  /// @notice Grants the seizer role to `_SEIZER`, the caller every seize in the test body uses.
  modifier givenTheCallerIsASeizer() {
    _mockAndExpect(_leafVoter, abi.encodeCall(IAccessControl.hasRole, (Roles.SEIZER_ROLE, _SEIZER)), abi.encode(true));
    _;
  }

  function test_SeizeWhenTheIdDoesNotExist(uint256 _id, address _to) external givenTheCallerIsASeizer {
    // `ownerOf` is read to source the transfer, so an unminted id reverts before the recipient is checked.
    // it should revert with ERC721NonexistentToken
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, _id));
    vm.prank(_SEIZER);
    _nft.seize(_id, _to);
  }

  function test_SeizeWhenTheRecipientIsTheZeroAddress(
    uint256 _id,
    address _owner
  ) external givenTheCallerIsASeizer givenTheIdExists(_id, _owner) {
    // it should revert with ERC721InvalidReceiver
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
    vm.prank(_SEIZER);
    _nft.seize(_id, address(0));
  }

  /// @notice Each test seizes to a fuzzed non-zero recipient, satisfying the branch.
  modifier givenTheRecipientIsNotTheZeroAddress() {
    _;
  }

  function test_SeizeWhenTheRecipientIsANewOwner(
    uint256 _id,
    address _owner,
    address _to,
    string memory _key,
    bytes32 _valueSeed,
    uint256 _lengthSeed
  ) external givenTheCallerIsASeizer givenTheIdExists(_id, _owner) givenTheRecipientIsNotTheZeroAddress {
    // A seizure confiscates from the owner to a different party, so the receiver must not be the current owner.
    _to = _boundNotEq(_to, _owner);
    string memory _value = _boundedShortText(_valueSeed, _lengthSeed);
    _seedRecord(_id, _key, _value);

    // it should emit Seized with _id, _to
    _expectEmit(address(_nft));
    emit ITokenNFT.Seized(_id, _to);

    vm.prank(_SEIZER);
    _nft.seize(_id, _to);

    // it should transfer the nft to the new owner
    assertEq(_nft.ownerOf(_id), _to);
    // it should preserve the records
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_SeizeWhenThePreviousOwnerSetsARecordAfterASeize(
    uint256 _id,
    address _owner,
    address _to,
    string memory _key,
    string memory _value
  ) external givenTheCallerIsASeizer givenTheIdExists(_id, _owner) givenTheRecipientIsNotTheZeroAddress {
    _to = _boundNotEq(_to, _owner);
    vm.prank(_SEIZER);
    _nft.seize(_id, _to);

    // it should revert with NotAuthorized
    vm.expectRevert(ITokenNFT.NotAuthorized.selector);
    vm.prank(_owner);
    _nft.setRecord(_id, _key, _value);
  }

  function test_SeizeWhenAnAddressThePreviousOwnerApprovedSetsARecordAfterASeize(
    uint256 _id,
    address _owner,
    address _approved,
    address _to,
    string memory _key,
    string memory _value
  ) external givenTheCallerIsASeizer givenTheIdExists(_id, _owner) givenTheRecipientIsNotTheZeroAddress {
    _approved = _boundNotEq(_approved, _owner);
    // The seizure must hand the NFT to someone other than the approved address, which would otherwise become the
    // new owner and keep write access legitimately.
    _to = _boundNotEq(_to, _owner);
    _to = _boundNotEq(_to, _approved);
    // The seizure must strip the approval the confiscated owner had granted, not just the ownership.
    vm.store(address(_nft), keccak256(abi.encode(_id, _TOKEN_APPROVALS_SLOT)), bytes32(uint256(uint160(_approved))));
    vm.prank(_SEIZER);
    _nft.seize(_id, _to);

    // it should revert with NotAuthorized
    vm.expectRevert(ITokenNFT.NotAuthorized.selector);
    vm.prank(_approved);
    _nft.setRecord(_id, _key, _value);
  }

  // --- transferFrom ---

  function test_TransferFromWhenTransferringToANewOwner(
    uint256 _id,
    address _owner,
    address _newOwner,
    string memory _key,
    bytes32 _valueSeed,
    uint256 _lengthSeed
  ) external {
    _assumeFuzzable(_owner);
    // The owner's own address is a valid target among all others, so a self-transfer is an allowed path.
    _assumeFuzzable(_newOwner);
    string memory _value = _boundedShortText(_valueSeed, _lengthSeed);
    _seedOwner(_id, _owner);
    _seedRecord(_id, _key, _value);

    vm.prank(_owner);
    _nft.transferFrom(_owner, _newOwner, _id);

    // it should move ownership to the new owner
    assertEq(_nft.ownerOf(_id), _newOwner);
    // it should preserve the records
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_TransferFromWhenTheNewOwnerSetsARecordAfterATransfer(
    uint256 _id,
    address _owner,
    address _newOwner,
    string memory _key,
    string memory _value
  ) external {
    _assumeFuzzable(_owner);
    // The owner's own address is a valid target among all others, so a self-transfer is an allowed path.
    _assumeFuzzable(_newOwner);
    _seedOwner(_id, _owner);
    vm.prank(_owner);
    _nft.transferFrom(_owner, _newOwner, _id);

    _expectEmit(address(_nft));
    emit ITokenNFT.RecordChanged(_id, _key, _key, _value);
    vm.prank(_newOwner);
    _nft.setRecord(_id, _key, _value);

    // it should write the record value
    string[] memory _keys = new string[](1);
    _keys[0] = _key;
    assertEq(_nft.records(_id, _keys)[0], _value);
  }

  function test_TransferFromWhenThePreviousOwnerSetsARecordAfterATransfer(
    uint256 _id,
    address _owner,
    address _newOwner,
    string memory _key,
    string memory _value
  ) external {
    _assumeFuzzable(_owner);
    // The receiver must differ from the owner here: a self-transfer would leave the previous owner still owning the
    // token, so `setRecord` would succeed instead of reverting.
    _newOwner = _boundNotEq(_newOwner, _owner);
    _seedOwner(_id, _owner);
    vm.prank(_owner);
    _nft.transferFrom(_owner, _newOwner, _id);

    // it should revert with NotAuthorized
    vm.expectRevert(ITokenNFT.NotAuthorized.selector);
    vm.prank(_owner);
    _nft.setRecord(_id, _key, _value);
  }

  // --- safeTransferFrom ---

  function test_SafeTransferFromWhenTheRecipientDoesNotImplementTheReceiverInterface(
    uint256 _id,
    address _owner
  ) external {
    _assumeFuzzable(_owner);
    // Carries code but no `onERC721Received`, so the safe transfer's receiver probe rejects it.
    RevertingReceiver _recipient = new RevertingReceiver();
    _seedOwner(_id, _owner);

    // it should revert with ERC721InvalidReceiver
    vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(_recipient)));
    vm.prank(_owner);
    _nft.safeTransferFrom(_owner, address(_recipient), _id);
  }

  function test_SafeTransferFromWhenTransferringToANewOwner(uint256 _id, address _owner, address _newOwner) external {
    _assumeFuzzable(_owner);
    // The owner's own address is a valid target among all others, so a self-transfer is an allowed path.
    _assumeFuzzable(_newOwner);
    // A safe transfer probes `onERC721Received`, so the recipient must carry no code to be treated as a valid holder.
    vm.assume(_newOwner.code.length == 0);
    _seedOwner(_id, _owner);

    vm.prank(_owner);
    _nft.safeTransferFrom(_owner, _newOwner, _id);

    // it should move ownership to the new owner
    assertEq(_nft.ownerOf(_id), _newOwner);
  }

  // --- records ---

  function test_RecordsWhenThereAreNoKeys(uint256 _id) external view {
    // it should return an empty array
    assertEq(_nft.records(_id, new string[](0)).length, 0);
  }

  function test_RecordsWhenCalled(
    uint256 _id,
    string memory _setKey,
    bytes32 _valueSeed,
    uint256 _lengthSeed
  ) external {
    string memory _value = _boundedShortText(_valueSeed, _lengthSeed);
    _seedRecord(_id, _setKey, _value);

    string[] memory _keys = new string[](2);
    _keys[0] = _setKey;
    _keys[1] = string.concat(_setKey, 'unset');
    string[] memory _values = _nft.records(_id, _keys);

    // it should return the stored value for a set key
    assertEq(_values[0], _value);
    // it should return an empty value for an unset key
    assertEq(_values[1], '');
  }

  // --- helpers ---

  /// @notice Seeds ERC721 ownership of `_id` to `_owner` directly in storage.
  function _seedOwner(uint256 _id, address _owner) internal {
    vm.store(address(_nft), keccak256(abi.encode(_id, _OWNERS_SLOT)), bytes32(uint256(uint160(_owner))));
    vm.store(address(_nft), keccak256(abi.encode(_owner, _BALANCES_SLOT)), bytes32(uint256(1)));
  }

  /// @notice Seeds a short (`< 32` bytes) text record directly: bytes packed high to low, `length * 2` in the low byte.
  function _seedRecord(uint256 _id, string memory _key, string memory _value) internal {
    bytes32 _valueSlot = keccak256(abi.encodePacked(bytes(_key), keccak256(abi.encode(_id, _RECORD_OF_SLOT))));
    bytes memory _valueBytes = bytes(_value);
    bytes32 _packed;
    for (uint256 _i; _i < _valueBytes.length; ++_i) {
      _packed |= bytes32(uint256(uint8(_valueBytes[_i])) << (8 * (31 - _i)));
    }
    _packed |= bytes32(_valueBytes.length * 2);
    vm.store(address(_nft), _valueSlot, _packed);
  }

  /// @notice Builds a non-empty, short (`< 32` bytes) text value from fuzz seeds, bounding the length instead of
  ///         discarding runs, since `_seedRecord` only packs short strings.
  function _boundedShortText(bytes32 _seed, uint256 _lengthSeed) internal pure returns (string memory _text) {
    uint256 _length = bound(_lengthSeed, 1, 31);
    bytes memory _bytes = new bytes(_length);
    for (uint256 _i; _i < _length; ++_i) {
      _bytes[_i] = _seed[_i];
    }
    _text = string(_bytes);
  }
}
