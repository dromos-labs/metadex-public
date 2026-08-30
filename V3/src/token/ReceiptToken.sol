// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';
import {BaseToken} from 'V3/token/BaseToken.sol';

/// @title Leaf Chain Receipt Token
/// @notice Leaf chain receipt token minted and burned by the local LeafVoter.
contract ReceiptToken is BaseToken, IReceiptToken {
  /// @inheritdoc IReceiptToken
  address public immutable LEAF_VOTER;

  /// @notice Initializes the receipt token.
  /// @param _leafVoter The address allowed to mint and burn receipt tokens.
  /// @param _name The token name.
  /// @param _symbol The token symbol.
  constructor(address _leafVoter, string memory _name, string memory _symbol) BaseToken(_name, _symbol) {
    if (_leafVoter == address(0)) revert ZeroAddress();

    LEAF_VOTER = _leafVoter;
  }

  /// @inheritdoc IReceiptToken
  function mint(address _to, uint256 _amount) external {
    if (msg.sender != LEAF_VOTER) revert NotLeafVoter();
    _mint(_to, _amount);
  }

  /// @inheritdoc IReceiptToken
  function burn(address _from, uint256 _amount) external {
    if (msg.sender != LEAF_VOTER) revert NotLeafVoter();
    _burn(_from, _amount);
  }
}
