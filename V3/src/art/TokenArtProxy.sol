// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ExcessivelySafeCall} from '@nomad-xyz/src/ExcessivelySafeCall.sol';
import {IAccessControl} from '@openzeppelin/contracts/access/IAccessControl.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {Base64} from '@solady/utils/Base64.sol';
import {LibString} from '@solady/utils/LibString.sol';

import {Roles} from 'V3/libraries/Roles.sol';

import {ITokenArtProxy} from 'V3/interfaces/art/ITokenArtProxy.sol';
import {ITokenRegistry} from 'V3/interfaces/tokenRegistry/ITokenRegistry.sol';

/// @title Token Registry Art Proxy
/// @notice Renders token registry NFT metadata from the registered token's live ERC20 symbol and its logo, fetched
///         from a governance-configurable base URI and layered over a placeholder shown when the logo is missing.
contract TokenArtProxy is ITokenArtProxy {
  using ExcessivelySafeCall for address;

  /// @dev Gas forwarded when reading an untrusted token symbol.
  uint256 internal constant _SYMBOL_CALL_GAS_LIMIT = 100_000;
  /// @dev Longest token symbol rendered, in bytes.
  uint256 internal constant _MAX_SYMBOL_LENGTH = 64;
  /// @dev Maximum copied returndata for a dynamic symbol no longer than `_MAX_SYMBOL_LENGTH`.
  uint16 internal constant _MAX_SYMBOL_RETURN_DATA = 128;

  /// @inheritdoc ITokenArtProxy
  address public immutable LEAF_VOTER;
  /// @inheritdoc ITokenArtProxy
  address public immutable TOKEN_REGISTRY;

  /// @inheritdoc ITokenArtProxy
  string public logoBaseURI = 'https://assets.smold.app/token/';

  /// @notice Configure the LeafVoter read for the governance role and the registry resolving NFT ids to tokens.
  /// @param _leafVoter LeafVoter contract.
  /// @param _tokenRegistry TokenRegistry contract.
  constructor(address _leafVoter, address _tokenRegistry) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (_tokenRegistry == address(0)) revert ZeroAddress();
    LEAF_VOTER = _leafVoter;
    TOKEN_REGISTRY = _tokenRegistry;
  }

  /// @inheritdoc ITokenArtProxy
  function setLogoBaseURI(string calldata _logoBaseURI) external {
    if (!IAccessControl(LEAF_VOTER).hasRole(Roles.GOVERNANCE_ROLE, msg.sender)) revert NotGovernance();
    logoBaseURI = _logoBaseURI;
    emit LogoBaseURIUpdated(_logoBaseURI);
  }

  /// @inheritdoc ITokenArtProxy
  function tokenURI(uint256 _tokenId) external view returns (string memory _output) {
    string memory _image = svg(_tokenId);
    string memory _json = Base64.encode(
      bytes(
        string.concat(
          '{"name":"AERO Token Registry #',
          LibString.toString(_tokenId),
          '","description":"AERO token registry entry","image":"data:image/svg+xml;base64,',
          Base64.encode(bytes(_image)),
          '"}'
        )
      )
    );

    _output = string.concat('data:application/json;base64,', _json);
  }

  /// @notice Reads bounded raw symbol returndata and decodes standard string or legacy fixed-bytes responses.
  /// @dev May revert for malformed dynamic returndata so `_symbol` calls this function through an external `try/catch`.
  /// @param _token Token whose symbol is read.
  /// @return _symbolValue Decoded symbol, or an empty string when the call fails or returns no data.
  function readSymbol(address _token) external view returns (string memory _symbolValue) {
    (bool _success, bytes memory _returnData) = _token.excessivelySafeStaticCall(
      _SYMBOL_CALL_GAS_LIMIT, _MAX_SYMBOL_RETURN_DATA, abi.encodeCall(IERC20Metadata.symbol, ())
    );
    if (!_success || _returnData.length == 0) return '';
    if (_returnData.length == 32) return _parseFixedSymbol(_returnData);
    _symbolValue = abi.decode(_returnData, (string));
  }

  /// @inheritdoc ITokenArtProxy
  function svg(uint256 _tokenId) public view returns (string memory _output) {
    address _token = ITokenRegistry(TOKEN_REGISTRY).idToToken(_tokenId);

    _output = string.concat(
      '<svg width="400" height="400" viewBox="0 0 400 400" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n',
      '<rect width="400" height="400" fill="white"/>\n',
      '<rect width="400" height="400" fill="#090E1F"/>\n',
      '<path d="M20 32L20.0004 22.25L22.2504 20L32 20" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n',
      '<path d="M368 20L377.75 20.0004L380 22.2504L380 32" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n',
      '<rect x="101.5" y="101.5" width="197" height="197" rx="98.5" stroke="url(#ringGrad)" stroke-width="3"/>\n',
      '<path d="M200 280C244.183 280 280 244.183 280 200C280 155.817 244.183 120 200 120C155.817 120 120 155.817 120 200C120 244.183 155.817 280 200 280Z" fill="#181D37"/>\n',
      '<path d="M200 174L208.273 191.727L226 200L208.273 208.273L200 226L191.727 208.273L174 200L191.727 191.727L200 174Z" fill="#8C9FFF"/>\n',
      '<image x="120" y="120" width="160" height="160" clip-path="url(#logoClip)" href="',
      _logoURI(_token),
      '"/>\n',
      '<g font-family="\'Roobert Mono\', ui-monospace, \'SF Mono\', Menlo, monospace" font-size="12" letter-spacing="0.24" fill="#EAEAEC">\n',
      '<text x="20" y="359">AERO TOKEN REGISTRY:</text>\n',
      '<text x="20" y="377">$',
      _symbol(_token),
      '</text>\n',
      '</g>\n',
      '<path d="M380 368L380 377.75L377.75 380L368 380" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n\n',
      '<defs>\n',
      '<clipPath id="logoClip"><circle cx="200" cy="200" r="80"/></clipPath>\n',
      '<linearGradient id="ringGrad" gradientUnits="objectBoundingBox" x1="0" y1="0" x2="1" y2="1">\n',
      '<stop offset="0" stop-color="#0B1233"/>\n',
      '<stop offset="0.20" stop-color="#1446EA"/>\n',
      '<stop offset="0.45" stop-color="#FF2D12"/>\n',
      '<stop offset="0.62" stop-color="#FF6A3D"/>\n',
      '<stop offset="0.80" stop-color="#DCEBFF"/>\n',
      '<stop offset="1" stop-color="#0B1233"/>\n',
      '<animateTransform attributeName="gradientTransform" type="rotate" from="0 0.5 0.5" to="360 0.5 0.5" dur="7s" repeatCount="indefinite"/>\n',
      '</linearGradient>\n',
      '</defs>\n',
      '</svg>\n'
    );
  }

  /// @notice Builds the logo URL as `{logoBaseURI}{chainId}/{checksummedTokenAddress}/logo-128.png`.
  /// @param _token Registered token.
  /// @return _uri Logo URL.
  function _logoURI(address _token) internal view returns (string memory _uri) {
    // smoldapp keys token assets by the EIP-55 checksummed address, so the casing must match for the logo to resolve.
    _uri = string.concat(
      logoBaseURI, LibString.toString(block.chainid), '/', LibString.toHexStringChecksummed(_token), '/logo-128.png'
    );
  }

  /// @notice Reads the registered token's symbol, HTML-escaped so a token cannot inject markup into the SVG.
  /// @dev Falls back to `UNKNOWN` when the bounded call fails or returns an unsupported, oversized or invalid symbol.
  /// @param _token Registered token.
  /// @return _escaped Escaped symbol rendered after the `$` prefix.
  function _symbol(address _token) internal view returns (string memory _escaped) {
    try this.readSymbol{gas: _SYMBOL_CALL_GAS_LIMIT}(_token) returns (string memory _raw) {
      uint256 _length = bytes(_raw).length;
      _escaped = _length != 0 && _length <= _MAX_SYMBOL_LENGTH && _isValidXMLString(_raw)
        ? LibString.escapeHTML(_raw)
        : 'UNKNOWN';
    } catch {
      _escaped = 'UNKNOWN';
    }
  }

  /// @notice Converts a null-padded legacy `bytes32` symbol response into a string.
  /// @param _returnData Fixed-bytes symbol returndata.
  /// @return _symbolValue Parsed symbol.
  function _parseFixedSymbol(bytes memory _returnData) internal pure returns (string memory _symbolValue) {
    uint256 _length = 0;
    while (_length < 32 && _returnData[_length] != 0) {
      ++_length;
    }

    bytes memory _raw = new bytes(_length);
    for (uint256 _i; _i < _length; ++_i) {
      _raw[_i] = _returnData[_i];
    }
    _symbolValue = string(_raw);
  }

  /// @notice Checks whether a string is well-formed UTF-8 containing only XML-valid code points.
  /// @param _value String to validate.
  /// @return _valid Whether the string can be embedded in an XML text node.
  function _isValidXMLString(string memory _value) internal pure returns (bool _valid) {
    bytes memory _bytes = bytes(_value);
    uint256 _length = _bytes.length;

    for (uint256 _index; _index < _length;) {
      uint8 _leadingByte = uint8(_bytes[_index]);
      uint256 _sequenceLength;
      uint32 _minimumCodePoint = 0;
      uint32 _codePoint;

      if (_leadingByte < 0x80) {
        _sequenceLength = 1;
        _codePoint = _leadingByte;
      } else if ((_leadingByte & 0xe0) == 0xc0) {
        _sequenceLength = 2;
        _minimumCodePoint = 0x80;
        _codePoint = uint32(_leadingByte & 0x1f);
      } else if ((_leadingByte & 0xf0) == 0xe0) {
        _sequenceLength = 3;
        _minimumCodePoint = 0x800;
        _codePoint = uint32(_leadingByte & 0x0f);
      } else if ((_leadingByte & 0xf8) == 0xf0) {
        _sequenceLength = 4;
        _minimumCodePoint = 0x10000;
        _codePoint = uint32(_leadingByte & 0x07);
      } else {
        return false;
      }

      if (_index + _sequenceLength > _length) return false;
      for (uint256 _offset = 1; _offset < _sequenceLength; ++_offset) {
        uint8 _continuationByte = uint8(_bytes[_index + _offset]);
        if ((_continuationByte & 0xc0) != 0x80) return false;
        _codePoint = (_codePoint << 6) | uint32(_continuationByte & 0x3f);
      }

      if (_codePoint < _minimumCodePoint) return false;
      if (
        _codePoint != 0x09 && _codePoint != 0x0a && _codePoint != 0x0d && !(_codePoint >= 0x20 && _codePoint <= 0xd7ff)
          && !(_codePoint >= 0xe000 && _codePoint <= 0xfffd) && !(_codePoint >= 0x10000 && _codePoint <= 0x10ffff)
      ) return false;

      _index += _sequenceLength;
    }

    _valid = true;
  }
}
