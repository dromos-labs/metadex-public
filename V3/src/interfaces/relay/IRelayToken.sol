// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title  IRelayToken
 * @notice Satellite ERC-20 the Relay clones twice at initialization: once as the principal token
 *         (PT, the priced position carrying the withdraw right) and once as the yield token (YT,
 *         the balance the reward accumulator reads). Mint and burn are Relay-only; holder transfers
 *         are gated by the per-clone `transferable` switch.
 * @dev    Includes the duplicated ERC-20 slice the Relay consumes (`balanceOf`, `totalSupply`) —
 *         duplicated-slice interfaces are accepted repo precedent, see IRelayEntrypoint's dev note.
 */
interface IRelayToken {
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                  CUSTOM ERRORS                                     __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Thrown when `mint` or `burn` is called by anyone other than the bound Relay.
  error NotRelay();

  /// @notice Thrown on `transfer`/`transferFrom` when the clone was initialized as
  ///         non-transferable (soulbound).
  error TokenNotTransferable();

  /// @notice Thrown when a transfer names the zero address, or a share mint names the Relay or a satellite.
  error InvalidRecipient();

  /// @notice Thrown when `initialize` runs a second time, or on the implementation itself.
  error AlreadyInitialized();

  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    FUNCTIONS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @notice Initialize a freshly cloned satellite: bind the calling Relay and store the metadata.
  /// @param _name ERC-20 name, stored per clone; no setter.
  /// @param _symbol ERC-20 symbol, stored per clone; no setter.
  /// @param _transferable Whether holder-to-holder transfers are allowed. Immutable switch: set
  ///        once here, no setter.
  /// @dev The Relay clones the token inside its own `initialize`, so `msg.sender` is the Relay by
  ///      construction. Callable once; the implementation's constructor marks itself initialized.
  function initialize(string calldata _name, string calldata _symbol, bool _transferable) external;

  /// @notice Mint `_amount` tokens to `_to`. Relay-only.
  /// @param _to Recipient of the minted tokens.
  /// @param _amount Token amount to mint.
  function mint(address _to, uint256 _amount) external;

  /// @notice Burn `_amount` tokens from `_from`. Relay-only.
  /// @param _from Holder whose tokens burn.
  /// @param _amount Token amount to burn.
  function burn(address _from, uint256 _amount) external;

  /// @notice The Relay this satellite is bound to: the only authorized mint/burn caller, the
  ///         target of the balance-change hook and a banned transfer recipient.
  /// @return _relay The Relay address.
  function relay() external view returns (address _relay);

  /// @notice Whether holder-to-holder transfers are allowed. Immutable switch: set once at
  ///         initialization, no setter.
  /// @return _transferable True when the token is transferable, false when soulbound.
  function transferable() external view returns (bool _transferable);

  /// @notice The token balance of `_owner`.
  /// @param _owner Holder to read.
  /// @return _balance The holder's current balance.
  function balanceOf(address _owner) external view returns (uint256 _balance);

  /// @notice The total token supply.
  /// @return _totalSupply The current total supply.
  function totalSupply() external view returns (uint256 _totalSupply);
}

/**
 * @title  IRelayTokenHook
 * @notice The Relay-side callback every RelayToken balance change reports to, fired BEFORE any
 *         balance mutates so the Relay's reward settle reads pre-change balances.
 * @dev    Declared alongside IRelayToken as the token's minimal expectation of its Relay; the
 *         Relay implements it and authenticates the caller against its own satellite addresses.
 */
interface IRelayTokenHook {
  /// @notice Reacts to an imminent balance change on a satellite token: authorizes the move and
  ///         settles reward accrual against the pre-change balances.
  /// @dev The tier seam behind this hook can narrow the recipients further, as Protocol does.
  /// @param _from Sender (zero on mint).
  /// @param _to Recipient (zero on burn).
  /// @param _amount Token amount about to move.
  function onRelayTokenTransfer(address _from, address _to, uint256 _amount) external;
}
