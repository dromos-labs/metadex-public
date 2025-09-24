// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

interface ITokenArtProxy {
  /// @notice Emitted when the logo base URI is updated.
  /// @param _logoBaseURI New logo base URI.
  event LogoBaseURIUpdated(string _logoBaseURI);

  /// @notice Thrown when the LeafVoter or token registry address is the zero address at deploy.
  error ZeroAddress();

  /// @notice Thrown when the caller does not hold the governance role read from the LeafVoter.
  error NotGovernance();

  /// @notice Update the base URI the token logo is fetched from.
  /// @dev Only the governance role read from the LeafVoter. The rendered logo URL is
  ///      `{logoBaseURI}{chainId}/{checksummedTokenAddress}/logo-128.png`.
  /// @param _logoBaseURI New logo base URI, including the trailing slash.
  function setLogoBaseURI(string calldata _logoBaseURI) external;

  /// @notice Generate a SVG based on the registered token behind a registry NFT.
  /// @param _tokenId Unique registry NFT identifier.
  /// @return _output SVG document.
  function svg(uint256 _tokenId) external view returns (string memory _output);

  /// @notice Generate a token URI based on the registered token behind a registry NFT.
  /// @param _tokenId Unique registry NFT identifier.
  /// @return _output Base64-encoded token URI JSON with embedded SVG image.
  function tokenURI(uint256 _tokenId) external view returns (string memory _output);

  /// @notice Source of the governance role, checked on `setLogoBaseURI`.
  /// @return _leafVoter LeafVoter address.
  function LEAF_VOTER() external view returns (address _leafVoter);

  /// @notice Token registry resolving registry NFT ids to the registered token.
  /// @return _tokenRegistry TokenRegistry address.
  function TOKEN_REGISTRY() external view returns (address _tokenRegistry);

  /// @notice Base URI the token logo is fetched from.
  /// @return _logoBaseURI Logo base URI, including the trailing slash.
  function logoBaseURI() external view returns (string memory _logoBaseURI);
}
