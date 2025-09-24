/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';

/**
 * @title IRootEmissionsHandler
 * @notice Root-side `EmissionsHandler`. Redeems each leg through `LeafVoter.redeem` in the same transaction. A leg
 * that would land the recipient below `LeafVoter.MIN_REDEEM_AMOUNT` is deferred instead: the handler keeps the
 * backing `ReceiptToken` and accumulates the amount per recipient, then redeems the whole pending total the first
 * time it reaches the floor.
 */
interface IRootEmissionsHandler is IEmissionsHandler {
  /**
   * @notice Emitted when a leg below the redeem floor is deferred instead of redeemed.
   * @param _recipient The recipient whose redemption is deferred.
   * @param _amount The deferred leg amount.
   * @param _pendingTotal The recipient's accumulated pending amount after the deferral.
   */
  event RedeemDeferred(address indexed _recipient, uint256 _amount, uint256 _pendingTotal);

  /**
   * @notice Accumulated sub-floor emissions awaiting redemption for a recipient.
   * @dev Always below `LeafVoter.MIN_REDEEM_AMOUNT`: a pending total that reaches the floor is redeemed in the
   *      same call that credited it.
   * @param _recipient The recipient being queried.
   * @return _pendingAmount The recipient's pending amount.
   */
  function pendingRedeems(address _recipient) external view returns (uint256 _pendingAmount);
}
