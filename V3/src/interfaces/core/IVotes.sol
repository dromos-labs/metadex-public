// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @notice Modified votes interface for token ID based voting.
interface IVotes {
  /// @notice Emitted when an account changes its delegate.
  event DelegateChanged(address indexed _delegator, uint256 indexed _fromDelegate, uint256 indexed _toDelegate);

  /// @notice Emitted when a transfer or delegation changes a delegate's voting power.
  event DelegateVotesChanged(address indexed _delegate, uint256 _previousBalance, uint256 _newBalance);

  /// @notice Delegates a token ID's votes to another token ID.
  function delegate(uint256 _delegator, uint256 _delegatee) external;

  /// @notice Delegates votes using an owner signature.
  function delegateBySig(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _nonce,
    uint256 _expiry,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external;

  /// @notice Returns the votes a token ID had at a past timepoint for its owner.
  function getPastVotes(address _account, uint256 _tokenId, uint256 _timepoint) external view returns (uint256);

  /// @notice Returns the total voting power at a past timepoint.
  function getPastTotalSupply(uint256 _timepoint) external view returns (uint256);

  /// @notice Returns the delegate selected by a token ID.
  function delegates(uint256 _tokenId) external view returns (uint256);
}
