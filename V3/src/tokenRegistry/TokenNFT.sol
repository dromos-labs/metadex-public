// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ITokenArtProxy} from 'V3/interfaces/art/ITokenArtProxy.sol';
import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

/**
 * @title TokenNFT
 * @notice Transferable ERC721 that stores each token's metadata as text records following ENS conventions. Its minter
 *         is the `TokenRegistry`, set as an immutable at deployment. It reads the seizer role from the `LeafVoter`
 *         to gate seizing.
 */
contract TokenNFT is ERC721, ITokenNFT {
  /// @inheritdoc ITokenNFT
  address public immutable LEAF_VOTER;
  /// @inheritdoc ITokenNFT
  address public immutable TOKEN_REGISTRY;
  /// @inheritdoc ITokenNFT
  address public immutable ART_PROXY;

  /**
   * @notice Metadata value of an id under a key.
   * @dev Read through `records`. Keys follow the recommended namespace, none enforced on-chain.
   */
  mapping(uint256 _id => mapping(string _key => string _value)) internal _recordOf;

  /**
   * @notice Restricts a record write to the NFT owner or an address it approved, per token or as an operator.
   * @param _id NFT whose records are written.
   */
  modifier onlyAuthorized(uint256 _id) {
    if (!_isAuthorized(ownerOf(_id), msg.sender, _id)) revert NotAuthorized();
    _;
  }

  /**
   * @notice Sets the ERC721 name and symbol, the LeafVoter read for the seizer role, the minting registry and the
   *         art proxy rendering `tokenURI`.
   * @param _name ERC721 name.
   * @param _symbol ERC721 symbol.
   * @param _leafVoter LeafVoter read for the seizer role.
   * @param _tokenRegistry TokenRegistry allowed to mint.
   * @param _artProxy Art proxy rendering the token URI.
   */
  constructor(
    string memory _name,
    string memory _symbol,
    address _leafVoter,
    address _tokenRegistry,
    address _artProxy
  ) ERC721(_name, _symbol) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (_tokenRegistry == address(0)) revert ZeroAddress();
    if (_artProxy == address(0)) revert ZeroAddress();

    LEAF_VOTER = _leafVoter;
    TOKEN_REGISTRY = _tokenRegistry;
    ART_PROXY = _artProxy;
  }

  /// @inheritdoc ITokenNFT
  function mint(uint256 _id, address _to, TextRecord[] calldata _records) external {
    if (msg.sender != TOKEN_REGISTRY) revert NotRegistry();

    // Write the records before the mint: `_safeMint` hands control to a contract recipient through the receiver
    // hook, which must already observe the new token's metadata.
    _writeRecords(_id, _records);

    _safeMint(_to, _id);
  }

  /// @inheritdoc ITokenNFT
  function setRecord(uint256 _id, string calldata _key, string calldata _value) external onlyAuthorized(_id) {
    _recordOf[_id][_key] = _value;
    emit RecordChanged(_id, _key, _key, _value);
  }

  /// @inheritdoc ITokenNFT
  function setRecords(uint256 _id, TextRecord[] calldata _records) external onlyAuthorized(_id) {
    _writeRecords(_id, _records);
  }

  /// @inheritdoc ITokenNFT
  function seize(uint256 _id, address _to) external {
    if (!IAccessControl(LEAF_VOTER).hasRole(Roles.SEIZER_ROLE, msg.sender)) revert NotSeizer();

    _transfer(ownerOf(_id), _to, _id);
    emit Seized(_id, _to);
  }

  /// @inheritdoc ITokenNFT
  function records(uint256 _id, string[] calldata _keys) external view returns (string[] memory _values) {
    uint256 _length = _keys.length;
    _values = new string[](_length);
    for (uint256 _i; _i < _length; ++_i) {
      _values[_i] = _recordOf[_id][_keys[_i]];
    }
  }

  /// @inheritdoc ITokenNFT
  function tokenURI(uint256 _id) public view override(ERC721, ITokenNFT) returns (string memory _uri) {
    _requireOwned(_id);
    _uri = ITokenArtProxy(ART_PROXY).tokenURI(_id);
  }

  /**
   * @notice Writes each record's value under its key and emits `RecordChanged` per record.
   * @param _id NFT the records belong to.
   * @param _records Records to write.
   */
  function _writeRecords(uint256 _id, TextRecord[] calldata _records) internal {
    uint256 _length = _records.length;
    for (uint256 _i; _i < _length; ++_i) {
      _recordOf[_id][_records[_i].key] = _records[_i].value;
      emit RecordChanged(_id, _records[_i].key, _records[_i].key, _records[_i].value);
    }
  }
}
