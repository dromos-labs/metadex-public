// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity ^0.8.4;

/**
 * @title ITokenNFT
 * @notice Interface for the `TokenNFT`, a transferable ERC721 that stores each token's metadata as text records
 *         following ENS conventions. Its minter is the `TokenRegistry`, set as an immutable at deployment. It reads
 *         the seizer role from the `LeafVoter` to gate seizing.
 */
interface ITokenNFT {
  /**
   * @notice A metadata record, following ENS text record conventions.
   * @param key Record key.
   * @param value Record value.
   */
  struct TextRecord {
    string key;
    string value;
  }

  /**
   * @notice Emitted when a record's value is written, at mint or through `setRecord` / `setRecords`.
   * @param _id NFT the record belongs to.
   * @param _indexedKey Record key that was written, indexed so consumers filter by key through the log topics. The
   *        topic holds `keccak256(bytes(_key))`, not the readable string, following the ENS `TextChanged` convention.
   * @param _key Same record key in plain text, kept unindexed so consumers decode the key from the log data.
   * @param _value New record value.
   */
  event RecordChanged(uint256 indexed _id, string indexed _indexedKey, string _key, string _value);

  /**
   * @notice Emitted when a seizer forcibly transfers an NFT through `seize`.
   * @param _id NFT that was seized.
   * @param _to Address the NFT was transferred to.
   */
  event Seized(uint256 indexed _id, address indexed _to);

  /// @notice Thrown when the LeafVoter, registry or art proxy address is the zero address at deploy.
  error ZeroAddress();

  /// @notice Thrown when a mint is not made by the `TokenRegistry`.
  error NotRegistry();

  /// @notice Thrown when a record write is not made by the NFT's owner or an address it approved.
  error NotAuthorized();

  /// @notice Thrown when a seize is not made by the seizer role read from the LeafVoter.
  error NotSeizer();

  /**
   * @notice Mints an NFT for a token and writes its initial metadata records.
   * @dev Only the `TokenRegistry` mints, supplying the id from its own sequence.
   * @param _id Id to mint.
   * @param _to Owner of the new NFT.
   * @param _records Initial metadata records written at mint.
   */
  function mint(uint256 _id, address _to, TextRecord[] calldata _records) external;

  /**
   * @notice Writes one metadata record on an NFT.
   * @dev The NFT owner or an address it approved, per token or as an operator, writes its records.
   * @param _id NFT to update.
   * @param _key Record key.
   * @param _value Record value.
   */
  function setRecord(uint256 _id, string calldata _key, string calldata _value) external;

  /**
   * @notice Writes several metadata records on an NFT in one call.
   * @dev The NFT owner or an address it approved, per token or as an operator, writes its records.
   * @param _id NFT to update.
   * @param _records Records to write.
   */
  function setRecords(uint256 _id, TextRecord[] calldata _records) external;

  /**
   * @notice Forcibly transfers an NFT to an address the seizer names.
   * @dev Only the seizer role, for a holder that set misleading metadata or acted against protocol integrity.
   * @param _id NFT to seize.
   * @param _to New owner.
   */
  function seize(uint256 _id, address _to) external;

  /**
   * @notice Token URI rendered by the art proxy from the registered token behind the NFT.
   * @dev Reverts with `ERC721NonexistentToken` when the id is not minted.
   * @param _id NFT to render.
   * @return _uri Base64-encoded token URI JSON with embedded SVG image.
   */
  function tokenURI(uint256 _id) external view returns (string memory _uri);

  /**
   * @notice Reads several metadata records of an NFT at once.
   * @param _id NFT to read.
   * @param _keys Record keys to read.
   * @return _values Record values, aligned by index with `_keys`, empty for any unset key.
   */
  function records(uint256 _id, string[] calldata _keys) external view returns (string[] memory _values);

  /**
   * @notice Source of the seizer role, checked on privileged calls.
   * @return _leafVoter LeafVoter address.
   */
  function LEAF_VOTER() external view returns (address _leafVoter);

  /**
   * @notice TokenRegistry allowed to mint, set at deployment.
   * @return _tokenRegistry TokenRegistry address.
   */
  function TOKEN_REGISTRY() external view returns (address _tokenRegistry);

  /**
   * @notice Art proxy rendering `tokenURI`, set at deployment.
   * @return _artProxy Art proxy address.
   */
  function ART_PROXY() external view returns (address _artProxy);
}
