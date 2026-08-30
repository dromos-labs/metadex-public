// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Base64} from '@solady/utils/Base64.sol';
import {BokkyPooBahsDateTimeLibrary} from 'V3/art/BokkyPooBahsDateTimeLibrary.sol';
import {IVeArtProxy} from 'V3/interfaces/art/IVeArtProxy.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/// @title sAERO Art Proxy
/// @notice Renders V3 sAERO token metadata from live VotingEscrow and Voter state.
contract VeArtProxy is IVeArtProxy {
  bytes16 private constant _SYMBOLS = '0123456789abcdef';

  IVotingEscrow private immutable _votingEscrow;
  IVoter private immutable _voter;

  /// @notice Configure the VotingEscrow and Voter state sources.
  /// @param _ve VotingEscrow contract used for stake state.
  /// @param _voterAddress Voter contract used for allocation state.
  constructor(address _ve, address _voterAddress) {
    _votingEscrow = IVotingEscrow(_ve);
    _voter = IVoter(_voterAddress);
  }

  /// @inheritdoc IVeArtProxy
  function tokenURI(uint256 _tokenId) external view returns (string memory _output) {
    string memory _image = svg(_tokenId);
    string memory _json = Base64.encode(
      bytes(
        string.concat(
          '{"name":"sAERO #',
          _toString(_tokenId),
          '","description":"sAERO voting escrow position","image":"data:image/svg+xml;base64,',
          Base64.encode(bytes(_image)),
          '"}'
        )
      )
    );

    _output = string.concat('data:application/json;base64,', _json);
  }

  /// @inheritdoc IVeArtProxy
  function svg(uint256 _tokenId) public view returns (string memory _output) {
    IVotingEscrow.StakedBalance memory _stake = _votingEscrow.staked(_tokenId);
    // slither-disable-next-line unused-return
    (uint128 _committed,,,) = _voter.tokenStates(_tokenId);

    _output = string.concat(
      '<svg width="400" height="400" viewBox="0 0 400 400" fill="none" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink">\n',
      '<rect width="400" height="400" fill="white"/>\n',
      '<rect width="400" height="400" fill="#090E1F"/>\n',
      '<rect x="101.5" y="101.5" width="197" height="197" rx="98.5" stroke="url(#ringGrad)" stroke-width="3"/>\n',
      '<path d="M120 200C120 155.817 155.817 120 200 120C244.183 120 280 155.817 280 200C280 244.183 244.183 280 200 280C155.817 280 120 244.183 120 200Z" fill="#DAEFFF"/>\n',
      '<path d="M182.553 179.601C201.646 160.508 224.862 152.769 234.409 162.315C235.372 163.278 236.159 164.381 236.777 165.604C225.876 160.103 205.376 168.091 188.21 185.258C171.043 202.424 163.055 222.924 168.556 233.825C167.333 233.207 166.231 232.42 165.267 231.457C155.721 221.91 163.46 198.693 182.553 179.601Z" fill="#1446EA"/>\n',
      '<path d="M175.461 235.966C180.976 236.62 187.576 235.397 194.572 232.515C194.57 232.515 194.569 232.515 194.567 232.514C201.135 229.811 208.051 225.645 214.744 220.193C214.747 220.19 214.749 220.188 214.752 220.186C215.035 219.955 215.318 219.722 215.6 219.487C217.805 217.649 219.984 215.671 222.115 213.56C222.232 213.444 222.35 213.327 222.468 213.209C227.479 208.198 231.757 202.911 235.215 197.62C235.026 205.101 231.122 213.82 224.046 221.071L224.047 221.076C223.873 221.249 223.7 221.421 223.526 221.593C223.514 221.604 223.502 221.615 223.491 221.627C223.319 221.795 223.148 221.963 222.976 222.129C222.967 222.137 222.959 222.146 222.951 222.154C207.136 237.453 188.396 244.651 176.809 240.709L175.461 235.966Z" fill="#1446EA"/>\n',
      '<path d="M171.866 168.915C190.959 149.822 214.176 142.084 223.722 151.63C224.686 152.593 225.473 153.696 226.09 154.919C215.189 149.418 194.69 157.406 177.523 174.572C160.357 191.739 152.369 212.239 157.87 223.139C156.647 222.522 155.544 221.735 154.581 220.771C145.034 211.225 152.773 188.008 171.866 168.915Z" fill="#1446EA"/>\n',
      '<path d="M176.608 224.264C178.963 223.669 181.399 222.854 183.885 221.83C183.884 221.83 183.882 221.83 183.881 221.829C190.448 219.126 197.364 214.959 204.057 209.507C204.06 209.505 204.063 209.503 204.065 209.501C204.348 209.27 204.631 209.037 204.913 208.802C207.119 206.964 209.297 204.986 211.428 202.875C211.546 202.759 211.664 202.642 211.781 202.524C216.792 197.513 221.07 192.226 224.529 186.935C224.34 194.416 220.435 203.135 213.359 210.386L213.36 210.391C213.187 210.564 213.013 210.736 212.839 210.907C212.827 210.919 212.816 210.93 212.804 210.942C212.633 211.11 212.461 211.278 212.289 211.444C212.281 211.452 212.272 211.46 212.264 211.469C200.304 223.039 186.671 229.976 175.724 230.965L176.608 224.264Z" fill="#1446EA"/>\n',
      '<path d="M193.437 190.286C212.529 171.193 235.746 163.454 245.293 173C246.256 173.964 247.043 175.066 247.661 176.29C236.76 170.788 216.26 178.776 199.094 195.943C181.927 213.109 173.939 233.609 179.44 244.51C178.217 243.892 177.114 243.105 176.151 242.142C166.605 232.595 174.344 209.379 193.437 190.286Z" fill="#1446EA"/>\n',
      '<path d="M179.441 244.51C185.821 248.082 195.215 247.42 205.456 243.201C205.455 243.201 205.453 243.2 205.451 243.2C212.019 240.497 218.935 236.33 225.628 230.878C225.631 230.876 225.633 230.874 225.636 230.871C225.919 230.641 226.202 230.408 226.484 230.173C228.69 228.334 230.868 226.357 232.999 224.246C233.117 224.129 233.234 224.012 233.352 223.895C238.363 218.884 242.641 213.596 246.099 208.306C245.911 215.786 242.006 224.505 234.93 231.756L234.931 231.761C234.758 231.935 234.584 232.107 234.41 232.278C234.398 232.289 234.387 232.301 234.375 232.312C234.204 232.481 234.032 232.648 233.86 232.815C233.852 232.823 233.843 232.831 233.835 232.839C214.932 251.126 191.849 257.84 181.797 247.788C180.839 246.83 180.099 245.69 179.441 244.51Z" fill="#1446EA"/>\n',
      '<g font-family="\'Roobert Mono\', ui-monospace, \'SF Mono\', Menlo, monospace" font-size="10" letter-spacing="0.2" fill="#EAEAEC">\n',
      '<text x="20" y="32"><tspan fill-opacity="0.5">STAKED:</tspan> <tspan>',
      _tokenAmountToString(_stake.amount),
      ' AERO</tspan></text>\n',
      '<text x="20" y="48"><tspan fill-opacity="0.5">ALLOCATION POWER:</tspan> <tspan>',
      _tokenAmountToString(_committed),
      ' sAERO</tspan></text>\n',
      '<text x="20" y="64"><tspan fill-opacity="0.5">UNSTAKE DATE:</tspan> <tspan>',
      _unstakeDate(_stake),
      '</tspan></text>\n',
      '<text x="20" y="80"><tspan fill-opacity="0.5">ID:</tspan> <tspan>#',
      _toString(_tokenId),
      'Z</tspan></text>\n',
      '</g>\n',
      '<path d="M368 20L377.75 20.0004L380 22.2504L380 32" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n',
      '<path d="M32 380L22.25 380L20 377.75L20 368" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n',
      '<path d="M380 368L380 377.75L377.75 380L368 380" stroke="#EAEAEC" stroke-width="1.5" stroke-miterlimit="16"/>\n\n',
      '<defs>\n',
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

  function _unstakeDate(IVotingEscrow.StakedBalance memory _stake) internal pure returns (string memory _date) {
    if (_stake.isPermanent) return 'PERMANENT';
    if (_stake.amount == 0 || _stake.end == 0) return 'WITHDRAWN / NO STAKE';

    (uint256 _year, uint256 _month, uint256 _day) = BokkyPooBahsDateTimeLibrary.timestampToDate(uint256(_stake.end));
    _date = string.concat(_toString(_day), ' ', _monthName(_month), ', ', _toString(_year));
  }

  function _tokenAmountToString(uint256 _value) internal pure returns (string memory _amount) {
    uint256 _whole = _value / 1e18;
    uint256 _cents = (_value % 1e18) / 1e16;

    _amount = string.concat(_formatWholeNumber(_whole), '.', _cents < 10 ? '0' : '', _toString(_cents));
  }

  function _formatWholeNumber(uint256 _value) internal pure returns (string memory _formatted) {
    string memory _digits = _toString(_value);
    bytes memory _raw = bytes(_digits);
    uint256 _commaCount = (_raw.length - 1) / 3;
    if (_commaCount == 0) return _digits;

    bytes memory _withCommas = new bytes(_raw.length + _commaCount);
    uint256 _readIndex = _raw.length;
    uint256 _writeIndex = _withCommas.length;
    uint256 _groupDigits;

    while (_readIndex != 0) {
      if (_groupDigits == 3) {
        _withCommas[--_writeIndex] = ',';
        _groupDigits = 0;
      }
      _withCommas[--_writeIndex] = _raw[--_readIndex];
      ++_groupDigits;
    }

    _formatted = string(_withCommas);
  }

  function _monthName(uint256 _month) internal pure returns (string memory _name) {
    if (_month == 1) return 'JAN';
    if (_month == 2) return 'FEB';
    if (_month == 3) return 'MAR';
    if (_month == 4) return 'APR';
    if (_month == 5) return 'MAY';
    if (_month == 6) return 'JUN';
    if (_month == 7) return 'JUL';
    if (_month == 8) return 'AUG';
    if (_month == 9) return 'SEP';
    if (_month == 10) return 'OCT';
    if (_month == 11) return 'NOV';
    return 'DEC';
  }

  function _toString(uint256 _value) internal pure returns (string memory _string) {
    unchecked {
      uint256 _length = _log10(_value) + 1;
      _string = new string(_length);
      uint256 _ptr;
      /// @solidity memory-safe-assembly
      assembly {
        _ptr := add(_string, add(32, _length))
      }
      while (true) {
        --_ptr;
        /// @solidity memory-safe-assembly
        assembly {
          mstore8(_ptr, byte(mod(_value, 10), _SYMBOLS))
        }
        _value /= 10;
        if (_value == 0) break;
      }
    }
  }

  function _log10(uint256 _value) internal pure returns (uint256 _result) {
    unchecked {
      if (_value >= 10 ** 64) {
        _value /= 10 ** 64;
        _result += 64;
      }
      if (_value >= 10 ** 32) {
        _value /= 10 ** 32;
        _result += 32;
      }
      if (_value >= 10 ** 16) {
        _value /= 10 ** 16;
        _result += 16;
      }
      if (_value >= 10 ** 8) {
        _value /= 10 ** 8;
        _result += 8;
      }
      if (_value >= 10 ** 4) {
        _value /= 10 ** 4;
        _result += 4;
      }
      if (_value >= 10 ** 2) {
        _value /= 10 ** 2;
        _result += 2;
      }
      if (_value >= 10) {
        ++_result;
      }
    }
  }
}
