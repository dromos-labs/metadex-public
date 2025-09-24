// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC20} from '@solady/tokens/ERC20.sol';

import {IBaseTokenExtensions} from 'V3/interfaces/token/IBaseTokenExtensions.sol';

/// @title Base Token
/// @notice Shared ERC20 behavior for protocol tokens: stored metadata, precomputed permit name hash, and
///         zero-address guards on mint and transfers.
abstract contract BaseToken is ERC20 {
  /// @notice Hash of the token name used by Solady's EIP-712 domain separator.
  bytes32 internal immutable _NAME_HASH;

  /// @notice Stored token name returned by ERC20 metadata.
  string internal _tokenName;

  /// @notice Stored token symbol returned by ERC20 metadata.
  string internal _tokenSymbol;

  /// @notice Initializes the token metadata.
  /// @param _name The token name.
  /// @param _symbol The token symbol.
  constructor(string memory _name, string memory _symbol) {
    _tokenName = _name;
    _tokenSymbol = _symbol;
    _NAME_HASH = keccak256(bytes(_name));
  }

  /// @inheritdoc ERC20
  function transfer(address _to, uint256 _amount) public virtual override returns (bool _success) {
    if (_to == address(0)) revert IBaseTokenExtensions.ZeroAddress();
    _success = super.transfer(_to, _amount);
  }

  /// @inheritdoc ERC20
  function transferFrom(address _from, address _to, uint256 _amount) public virtual override returns (bool _success) {
    if (_to == address(0)) revert IBaseTokenExtensions.ZeroAddress();
    _success = super.transferFrom(_from, _to, _amount);
  }

  /// @inheritdoc ERC20
  function name() public view override returns (string memory _name) {
    _name = _tokenName;
  }

  /// @inheritdoc ERC20
  function symbol() public view override returns (string memory _symbol) {
    _symbol = _tokenSymbol;
  }

  /// @inheritdoc ERC20
  /// @dev Guards every mint path, including the constructor pre-mints of inheriting tokens.
  function _mint(address _to, uint256 _amount) internal override {
    if (_to == address(0)) revert IBaseTokenExtensions.ZeroAddress();
    super._mint(_to, _amount);
  }

  /// @inheritdoc ERC20
  /// @dev Returns the precomputed token name hash to avoid hashing the stored name on each permit path.
  function _constantNameHash() internal view override returns (bytes32 _result) {
    _result = _NAME_HASH;
  }

  /// @inheritdoc ERC20
  /// @dev Keeps Permit2 allowances user-controlled instead of granting the canonical Permit2 address infinity.
  function _givePermit2InfiniteAllowance() internal pure override returns (bool _success) {
    _success = false;
  }
}
