/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';
import {IReceiptTokenExtensions as IReceiptToken} from 'V3/interfaces/token/IReceiptTokenExtensions.sol';

/**
 * @title ILeafEmissionsHandler
 * @notice Leaf-side `EmissionsHandler`. Transfers `ReceiptToken` to recipients after `LeafVoter.mintEmissions` credits
 * the total into this handler. LPs hold `ReceiptToken` locally until redeeming it for `TOKEN` on root.
 */
interface ILeafEmissionsHandler is IEmissionsHandler {
  /**
   * @notice `ReceiptToken` bound to this handler. Immutable.
   * @return _receiptToken Local `ReceiptToken`.
   */
  function RECEIPT_TOKEN() external view returns (IReceiptToken _receiptToken);
}
