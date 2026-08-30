// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ITokenNFT} from 'V3/interfaces/tokenRegistry/ITokenNFT.sol';

/// @notice ERC721 receiver that snapshots the record values visible during the mint hook, proving the write order.
contract RecordReadingReceiver {
  string[] internal _keys;
  string[] internal _seenValues;

  constructor(string[] memory _keysToRead) {
    _keys = _keysToRead;
  }

  /// @notice Reads the minted id's records from the calling NFT contract while control is handed over.
  function onERC721Received(address, address, uint256 _id, bytes calldata) external returns (bytes4 _selector) {
    _seenValues = ITokenNFT(msg.sender).records(_id, _keys);
    _selector = this.onERC721Received.selector;
  }

  /// @notice Values observed during `onERC721Received`, one per requested key.
  function seenValues() external view returns (string[] memory _values) {
    _values = _seenValues;
  }
}
