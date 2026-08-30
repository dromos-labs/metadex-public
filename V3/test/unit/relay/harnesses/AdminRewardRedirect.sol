// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title AdminRewardRedirect
 * @notice A contract ADMIN that tries to re-point a Relay's leaf claim recipient to itself and claim
 *         in the same call, so a test can check whether anything stands between the two.
 * @dev Models the production shape of the role: ADMIN is held by a multisig, which batches calls
 *      atomically. Without a delay on the re-point this drains a leaf's accrued rewards in one
 *      transaction, leaving nothing to observe and nobody time to react.
 */
contract AdminRewardRedirect {
  /// @notice Propose, land and claim in a single call.
  /// @param _relay Relay this contract holds ADMIN on.
  /// @param _chainId Leaf chain whose accrued fees and incentives are claimed.
  /// @param _gasLimit Destination gas budget for the claim dispatch.
  /// @param _feeClaims Fee claim requests forwarded to the Voter.
  /// @param _incentiveClaims Incentive claim requests forwarded to the Voter.
  function redirectAndClaim(
    IRelay _relay,
    uint256 _chainId,
    uint256 _gasLimit,
    ILeafVoter.FeeClaim[] calldata _feeClaims,
    ILeafVoter.IncentiveClaim[] calldata _incentiveClaims
  ) external payable {
    _relay.proposeLeafRecipient(_chainId, address(this));
    _relay.executeLeafRecipient(_chainId);
    _relay.claimRewards{value: msg.value}(_chainId, _gasLimit, _feeClaims, _incentiveClaims);
  }
}
