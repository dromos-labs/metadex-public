/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';

import {IEmissionsHandler, ILeafEmissionsHandler} from 'V3/interfaces/handlers/ILeafEmissionsHandler.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';

/**
 * @title LeafEmissionsHandler
 * @notice Leaf-side `EmissionsHandler`. Receives `ReceiptToken` minted by `LeafVoter.mintEmissions` and forwards it to
 * the per-leg recipients in the same transaction. LPs hold `ReceiptToken` locally until redeeming for `TOKEN` on root.
 * @dev `LeafVoter` credits the aggregate to this handler before invoking `handleEmissions`. The handler then issues
 * per-recipient `SafeERC20.safeTransfer`. Zero-amount entries are skipped.
 */
contract LeafEmissionsHandler is ILeafEmissionsHandler {
  using SafeERC20 for IERC20;

  /// @inheritdoc ILeafEmissionsHandler
  IReceiptToken public immutable RECEIPT_TOKEN;

  /// @inheritdoc IEmissionsHandler
  address public immutable LEAF_VOTER;

  /**
   * @notice Binds the handler to its `LeafVoter` and the `ReceiptToken` it delivers.
   * @param _leafVoter Local `LeafVoter` permanently bound as the sole authorized caller of `handleEmissions`.
   * @param _receiptToken `ReceiptToken` this handler transfers to recipients.
   */
  constructor(address _leafVoter, address _receiptToken) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    if (_receiptToken == address(0)) revert ZeroAddress();
    LEAF_VOTER = _leafVoter;
    RECEIPT_TOKEN = IReceiptToken(_receiptToken);
  }

  /// @inheritdoc IEmissionsHandler
  function handleEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external {
    if (msg.sender != LEAF_VOTER) revert CallerNotLeafVoter();

    uint256 _recipientsLength = _recipients.length;
    for (uint256 _i; _i < _recipientsLength; ++_i) {
      uint256 _amount = _amounts[_i];
      if (_amount > 0) IERC20(address(RECEIPT_TOKEN)).safeTransfer(_recipients[_i], _amount);
    }
  }
}
