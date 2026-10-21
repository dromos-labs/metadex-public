// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title ISplitter
 * @notice Interface for the V3 `Splitter`, which accrues the `Minter`'s team share across a configured recipient
 *         list and pays each recipient its slice on claim.
 */
interface ISplitter {
  /**
   * @notice Per-recipient accrual state.
   * @param sharePips Share in PIPS, zero when the recipient is not in the active list.
   * @param lastSettledIndex Value of `globalAccrualIndex` captured at the recipient's last settlement.
   * @param claimable Settled but unclaimed TOKEN owed to the recipient, persistent across list replacements.
   */
  struct RecipientState {
    uint256 sharePips;
    uint256 lastSettledIndex;
    uint256 claimable;
  }

  /**
   * @notice Emitted when the active recipient list is replaced.
   * @param _recipients New active recipient list, in insertion order.
   * @param _shares New shares in PIPS, aligned by index with `_recipients`.
   */
  event RecipientsSet(address[] _recipients, uint256[] _shares);

  /**
   * @notice Emitted when a recipient's claimable balance is paid out.
   * @param _recipient Recipient the TOKEN was sent to.
   * @param _amount Amount of TOKEN transferred.
   */
  event Claimed(address indexed _recipient, uint256 _amount);

  /// @notice Thrown when a privileged call is not made by an account holding `SPLITTER_CONFIG_ROLE` on the `Voter`.
  error UnauthorizedCaller();

  /// @notice Thrown when a required address argument is the zero address.
  error ZeroAddress();

  /// @notice Thrown when the recipient and share arrays have different lengths.
  error LengthMismatch();

  /// @notice Thrown when the proposed recipient list is empty.
  error EmptyRecipients();

  /// @notice Thrown when the proposed recipient list exceeds `MAX_RECIPIENTS`.
  error TooManyRecipients();

  /// @notice Thrown when a recipient is the zero address or the `Splitter` itself.
  error InvalidRecipient();

  /// @notice Thrown when a recipient is assigned a zero share.
  error ZeroShare();

  /// @notice Thrown when a recipient appears more than once in the proposed list.
  error DuplicateRecipient();

  /// @notice Thrown when the proposed shares do not sum to `MAX_PIPS`.
  error InvalidShareSum();

  /**
   * @notice Settles a recipient and transfers its claimable balance to the recipient address.
   * @dev Callable by anyone on behalf of any recipient. A claim that owes nothing makes no transfer and emits no
   *      event, though accrual and settlement still run.
   * @param _recipient Recipient to settle and pay.
   * @return _amount TOKEN transferred, zero when nothing is owed.
   */
  function claim(address _recipient) external returns (uint256 _amount);

  /**
   * @notice Replaces the entire recipient list. Callable only by accounts holding `SPLITTER_CONFIG_ROLE` on the
   *         `Voter`.
   * @dev Settles every current recipient at its existing share before writing the new list, so accrued balances
   *      are preserved even for recipients dropped from the list.
   * @param _newRecipients New recipient addresses, in insertion order.
   * @param _newShares New shares in PIPS, aligned by index with `_newRecipients` and summing to
   *        `MAX_PIPS`.
   */
  function setRecipients(address[] calldata _newRecipients, uint256[] calldata _newShares) external;

  /**
   * @notice Balance `claim(_recipient)` would pay right now, including inflow not yet folded into `globalAccrualIndex`.
   * @param _recipient Recipient to quote.
   * @return _earned Claimable TOKEN including pending inflow.
   */
  function earned(address _recipient) external view returns (uint256 _earned);

  /**
   * @notice Returns the entire active recipient list in one call.
   * @return _recipientList Active recipients in insertion order.
   */
  function allRecipients() external view returns (address[] memory _recipientList);

  /**
   * @notice Hard cap on the number of entries in the active recipient list.
   * @return _maxRecipients The constant `50`.
   */
  function MAX_RECIPIENTS() external view returns (uint256 _maxRecipients);

  /**
   * @notice ERC20 the `Minter` mints into the `Splitter` and the only token paid out on claim.
   * @return _token TOKEN address.
   */
  function TOKEN() external view returns (address _token);

  /**
   * @notice `Voter` whose `SPLITTER_CONFIG_ROLE` gates privileged calls.
   * @return _voter `Voter` address.
   */
  function VOTER() external view returns (address _voter);

  /**
   * @notice Scaled accumulator that advances on every inflow.
   * @return _globalAccrualIndex Current value of the global index.
   */
  function globalAccrualIndex() external view returns (uint256 _globalAccrualIndex);

  /**
   * @notice Portion of the live TOKEN balance already accounted into `globalAccrualIndex`; the baseline the accrual
   *         projection diffs against to detect new inflow. Rises on accrual, falls on claim payouts.
   * @return _accountedBalance Accounted portion of the live balance.
   */
  function accountedBalance() external view returns (uint256 _accountedBalance);

  /**
   * @notice Active recipient list, in insertion order.
   * @param _index Position in the list.
   * @return _recipient Recipient at that position.
   */
  function recipients(uint256 _index) external view returns (address _recipient);

  /**
   * @notice Accrual state for a recipient: its share, last-settlement index, and settled-but-unclaimed balance.
   * @param _recipient Recipient to read.
   * @return _sharePips Share in PIPS, zero when the recipient is not in the active list.
   * @return _lastSettledIndex Value of `globalAccrualIndex` captured at the recipient's last settlement.
   * @return _claimable Settled but unclaimed TOKEN owed to the recipient, persistent across list replacements.
   */
  function recipientState(address _recipient)
    external
    view
    returns (uint256 _sharePips, uint256 _lastSettledIndex, uint256 _claimable);
}
