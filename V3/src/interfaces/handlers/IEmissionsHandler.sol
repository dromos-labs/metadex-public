/// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IEmissionsHandler
 * @notice Callback surface invoked by `LeafVoter.mintEmissions` after `ReceiptToken` is minted to the handler. Abstracts
 * chain-specific delivery: leaf transfers `ReceiptToken` to recipients, root redeems each leg through `LeafVoter.redeem`.
 * @dev `LeafVoter` completes all claim-time state effects before invoking the callback. Implementations MUST NOT rely
 * on `LeafVoter` state changing further inside. On root the handler intentionally re-enters `LeafVoter.redeem` per
 * recipient.
 */
interface IEmissionsHandler {
  /// @notice Reverts when `handleEmissions` is called by any address other than `LEAF_VOTER`.
  error CallerNotLeafVoter();

  /// @notice Reverts when a supplied address parameter is the zero address.
  error ZeroAddress();

  /**
   * @notice Delivers the freshly minted `ReceiptToken` to recipients in the chain-specific way.
   * @dev Only `LEAF_VOTER` may call. Recipient entries with a zero amount are skipped.
   * @param _recipients Recipient addresses for the per-leg delivery (LP, referral).
   * @param _amounts Per-leg amounts of `ReceiptToken` allocated to each recipient.
   */
  function handleEmissions(address[] calldata _recipients, uint128[] calldata _amounts) external;

  /**
   * @notice Local `LeafVoter` bound as the sole caller of `handleEmissions`. Immutable.
   * @return _leafVoter Local `LeafVoter`.
   */
  function LEAF_VOTER() external view returns (address _leafVoter);
}
