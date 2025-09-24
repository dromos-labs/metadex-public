// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVeArtProxy {
  /// @notice Generate a SVG based on live veNFT metadata.
  /// @param _tokenId Unique veNFT identifier.
  /// @return _output SVG document.
  function svg(uint256 _tokenId) external view returns (string memory _output);

  /// @notice Generate a token URI based on live veNFT metadata.
  /// @param _tokenId Unique veNFT identifier.
  /// @return _output Base64-encoded token URI JSON with embedded SVG image.
  function tokenURI(uint256 _tokenId) external view returns (string memory _output);
}
