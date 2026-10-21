// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';

import {VOTE_TYPE_FRACTIONAL} from 'V3/relay/libraries/RelayGovernanceLib.sol';

/**
 * @title  RelayVoteAdapter
 * @notice The canonical adapter every Relay is born with: the tokenId-keyed GovernorSimple with
 *         fractional counting. Also the template a future Governor's adapter starts from.
 */
contract RelayVoteAdapter is IRelayVoteAdapter {
  /// @inheritdoc IRelayVoteAdapter
  function proposalSnapshot(address _governor, uint256 _proposalId) external view returns (uint256 _timestamp) {
    _timestamp = IGovernor(_governor).proposalSnapshot(_proposalId);
  }

  /// @inheritdoc IRelayVoteAdapter
  /// @dev Refuses components beyond uint128 rather than truncating; pure, but the interface stays
  ///      `view` so other dialects may read their Governor to encode.
  function encodeCast(
    uint256 _proposalId,
    uint256 _tokenId,
    uint256 _against,
    uint256 _for,
    uint256 _abstain,
    string calldata _reason
  ) external pure returns (bytes memory _callData) {
    if (_against > type(uint128).max || _for > type(uint128).max || _abstain > type(uint128).max) {
      revert UnrepresentableWeight();
    }

    // forge-lint: disable-start(unsafe-typecast)
    bytes memory _params = abi.encodePacked(uint128(_against), uint128(_for), uint128(_abstain));
    // forge-lint: disable-end(unsafe-typecast)
    _callData = abi.encodeCall(
      IGovernor.castVoteWithReasonAndParams, (_proposalId, _tokenId, VOTE_TYPE_FRACTIONAL, _reason, _params)
    );
  }
}
