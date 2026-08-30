// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title  IRelayEntrypoint
/// @notice The slice of the Relay surface an entrypoint drives: pull the input token, then either
///         compound or notify the swap output, plus the reads needed to gate and target the flow.
/// @dev Entrypoints cast a Relay address to this interface. Kept separate from IRelay so the Relay's
///      own NatSpec style is untouched; the Relay implements every member (pull, compound,
///      notifyReward, the TOKEN/KEEPER getters and OwnableRoles' owner and hasAnyRole).
interface IRelayEntrypoint {
  /// @notice Pull `_amount` of `_token` from the Relay to the caller (entrypoint role gated).
  /// @param _token Token to pull.
  /// @param _amount Amount to pull.
  function pull(address _token, uint256 _amount) external;

  /// @notice Stake `_amount` of TOKEN held by the Relay into its sAERO (COMPOUNDER gated).
  /// @param _amount TOKEN amount to compound.
  function compound(uint256 _amount) external;

  /// @notice Distribute `_amount` of `_token` to holders via the accumulator (CONVERTER gated).
  /// @param _token Reward token being distributed.
  /// @param _amount Amount to distribute.
  function notifyReward(address _token, uint256 _amount) external;

  /// @notice The Relay's underlying protocol TOKEN (the Compounder's swap target).
  /// @return _token The protocol TOKEN address.
  function TOKEN() external view returns (address _token);

  /// @notice Balance of `_token` already notified to holders and not yet claimed. The Relay's own
  ///         bound for `pull`, `compound` and `notifyReward` is `balanceOf - accountedBalance`, so
  ///         an idle-balance path has to subtract this to leave claimants whole.
  /// @param _token Token to read.
  /// @return _accounted Amount owed to reward claimants.
  function accountedBalance(address _token) external view returns (uint256 _accounted);

  /// @notice The KEEPER role bit, checked against the entrypoint caller.
  /// @return _role The KEEPER role bit.
  function KEEPER() external view returns (uint256 _role);

  /// @notice The Relay's owner; a bound Multi entrypoint checks it to gate its config, so the
  ///         Relay's single L2 admin governs both the Relay and its entrypoint config.
  /// @return _owner The owner address.
  function owner() external view returns (address _owner);

  /// @notice Whether `_account` holds any of the `_roles` bits on the Relay.
  /// @param _account Account to check.
  /// @param _roles Role bits to check.
  /// @return _has True when the account holds at least one of the bits.
  function hasAnyRole(address _account, uint256 _roles) external view returns (bool _has);
}
