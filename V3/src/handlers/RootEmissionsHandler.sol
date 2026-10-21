/// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IEmissionsHandler} from 'V3/interfaces/handlers/IEmissionsHandler.sol';
import {IRootEmissionsHandler} from 'V3/interfaces/handlers/IRootEmissionsHandler.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title RootEmissionsHandler
 * @notice Root-side `EmissionsHandler`. Receives `ReceiptToken` minted by `LeafVoter.mintEmissions` (since `LeafVoter`
 * is also deployed on root) and immediately calls `LeafVoter.redeem` per recipient. That call burns the
 * `ReceiptToken` and dispatches through the local adapter to `Voter.processRedeem`.
 * @dev `redeem` reverts below `LeafVoter.MIN_REDEEM_AMOUNT`, and the claim that triggers this callback is forced on
 * gauge withdrawals, so a sub-floor leg must never revert. Such legs are deferred: the backing `ReceiptToken` stays
 * in the handler and the amount accumulates in `pendingRedeems` until the recipient's total reaches the floor, at
 * which point the whole total is redeemed. Passes `0` and `address(0)` for `_gasLimit` and `_refundRecipient`
 * because the local-adapter path takes no transport fee. Zero-amount entries are skipped.
 */
contract RootEmissionsHandler is IRootEmissionsHandler {
  /// @notice Zero gas limit for the local-adapter path, given there is no crosschain transport fee.
  uint256 internal constant _ZERO_GAS_LIMIT = 0;

  /// @notice Zero refund recipient for the local-adapter path, given there is no crosschain transport fee.
  address internal constant _NO_REFUND_RECIPIENT = address(0);

  /// @inheritdoc IEmissionsHandler
  address public immutable LEAF_VOTER;

  /// @inheritdoc IRootEmissionsHandler
  mapping(address _recipient => uint256 _pendingAmount) public pendingRedeems;

  /**
   * @notice Binds the handler to its `LeafVoter`.
   * @param _leafVoter Local `LeafVoter` permanently bound as the sole authorized caller of `handleEmissions`.
   */
  constructor(address _leafVoter) {
    if (_leafVoter == address(0)) revert ZeroAddress();
    LEAF_VOTER = _leafVoter;
  }

  /// @inheritdoc IEmissionsHandler
  function handleEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external {
    if (msg.sender != LEAF_VOTER) revert CallerNotLeafVoter();

    /// @dev Read at call time: the handler can deploy before its `LeafVoter` has code (circular immutables).
    uint256 _minRedeemAmount = ILeafVoter(LEAF_VOTER).MIN_REDEEM_AMOUNT();

    uint256 _recipientsLength = _recipients.length;
    for (uint256 _i; _i < _recipientsLength; ++_i) {
      uint256 _amount = _amounts[_i];
      if (_amount > 0) {
        address _recipient = _recipients[_i];
        uint256 _pendingTotal = pendingRedeems[_recipient] + _amount;

        if (_pendingTotal >= _minRedeemAmount) {
          if (_pendingTotal != _amount) delete pendingRedeems[_recipient];
          // slither-disable-next-line reentrancy-no-eth
          ILeafVoter(LEAF_VOTER).redeem(_pendingTotal, _recipient, _ZERO_GAS_LIMIT, _NO_REFUND_RECIPIENT);
        } else {
          pendingRedeems[_recipient] = _pendingTotal;
          emit RedeemDeferred(_recipient, _amount, _pendingTotal);
        }
      }
    }
  }
}
