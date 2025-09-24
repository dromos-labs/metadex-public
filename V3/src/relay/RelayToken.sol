// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC20} from '@solady/tokens/ERC20.sol';

import {IRelayToken, IRelayTokenHook} from 'V3/interfaces/relay/IRelayToken.sol';

/**
 * @title  RelayToken
 * @notice ERC-20 companion token of the Relay. The Relay clones it twice at initialization: once
 *         as the principal token (PT) and once as the yield token (YT). The PT is the priced
 *         position and carries the withdraw right. The YT is the balance that the reward
 *         accumulator reads. Only the Relay can mint and burn. Holder transfers are gated by the
 *         per-clone `transferable` switch.
 * @dev    Every balance change calls the Relay's hook BEFORE any balance write, so the Relay
 *         settles on pre-change balances. `_constantNameHash` stays un-overridden on purpose: one
 *         pinned hash would have to serve both clones, and the PT and the YT have different names.
 *         Decimals (18) and Permit2 keep Solady's defaults.
 */
contract RelayToken is ERC20, IRelayToken {
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                     STORAGE                                        __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc IRelayToken
  address public relay;

  /// @inheritdoc IRelayToken
  bool public transferable;

  /// @notice Set by the implementation's constructor, so `initialize` only runs on clones. Packed
  ///         with `relay` and `transferable`, so the transfer gate costs one SLOAD.
  bool internal _initialized;

  /// @notice Per-clone ERC-20 name, set once at initialization; no setter.
  string internal _tokenName;

  /// @notice Per-clone ERC-20 symbol, set once at initialization; no setter.
  string internal _tokenSymbol;

  /// @notice Locks the implementation, so `initialize` only runs on clones.
  constructor() {
    _initialized = true;
  }

  /// @inheritdoc IRelayToken
  function initialize(string calldata _name, string calldata _symbol, bool _transferable) external {
    if (_initialized) revert AlreadyInitialized();

    // The Relay clones this token inside its own `initialize`, so `msg.sender` is always the Relay.
    relay = msg.sender;
    transferable = _transferable;
    _initialized = true;

    _tokenName = _name;
    _tokenSymbol = _symbol;
  }

  /// @inheritdoc IRelayToken
  function mint(address _to, uint256 _amount) external {
    if (msg.sender != relay) revert NotRelay();
    _mint(_to, _amount);
  }

  /// @inheritdoc IRelayToken
  function burn(address _from, uint256 _amount) external {
    if (msg.sender != relay) revert NotRelay();
    _burn(_from, _amount);
  }

  /// @inheritdoc ERC20
  /// @dev Holder-initiated transfer with the transfer gate. The gate is here (and in
  ///      `transferFrom`) instead of in the transfer hook, because inside the hook a burn and a
  ///      transfer to the zero address look the same.
  function transfer(address _to, uint256 _amount) public virtual override returns (bool _success) {
    _gateTransfer(_to);
    _success = super.transfer(_to, _amount);
  }

  /// @inheritdoc ERC20
  /// @dev Same gate as `transfer`. Together the two overrides cover every transfer a holder can
  ///      start, including through Permit2. Solady grants Permit2 a fixed infinite allowance, so
  ///      limiting allowances cannot block those transfers.
  function transferFrom(address _from, address _to, uint256 _amount) public virtual override returns (bool _success) {
    _gateTransfer(_to);
    _success = super.transferFrom(_from, _to, _amount);
  }

  /// @inheritdoc ERC20
  /// @dev Gated because letting it through is not harmless: Solady keeps one nonce counter per
  ///      owner for both `permit` and `delegateBySig`, so a permit signed for a soulbound clone
  ///      would burn the nonce an outstanding delegation needs — a phishing lever on a signature
  ///      that looks inert. `approve` stays open: a dead allowance has no side effect.
  function permit(
    address _owner,
    address _spender,
    uint256 _value,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) public virtual override {
    if (!transferable) revert TokenNotTransferable();
    super.permit(_owner, _spender, _value, _deadline, _v, _r, _s);
  }

  /// @inheritdoc ERC20
  /// @dev Reads the per-clone storage set at initialization; no setter.
  function name() public view override returns (string memory) {
    return _tokenName;
  }

  /// @inheritdoc ERC20
  /// @dev Reads the per-clone storage set at initialization; no setter.
  function symbol() public view override returns (string memory) {
    return _tokenSymbol;
  }

  /// @inheritdoc IRelayToken
  function balanceOf(address _owner) public view virtual override(ERC20, IRelayToken) returns (uint256 _balance) {
    _balance = super.balanceOf(_owner);
  }

  /// @inheritdoc IRelayToken
  function totalSupply() public view virtual override(ERC20, IRelayToken) returns (uint256 _totalSupply) {
    _totalSupply = super.totalSupply();
  }

  /// @notice Reports the imminent balance change to the Relay, which authorizes and settles.
  /// @param _from Sender (zero on mint).
  /// @param _to Recipient (zero on burn).
  /// @param _amount Token amount about to move.
  /// @dev Runs on every Solady path BEFORE any balance write, so the Relay settles on pre-change
  ///      balances.
  function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal virtual override {
    IRelayTokenHook(relay).onRelayTokenTransfer(_from, _to, _amount);
  }

  /// @notice Gates a holder-initiated move: the clone must be transferable and the recipient valid.
  /// @param _to Recipient of the transfer.
  /// @dev Solady moves to `address(0)` without reducing `totalSupply`, and the hook reads a zero
  ///      recipient as a burn.
  function _gateTransfer(address _to) private view {
    if (!transferable) revert TokenNotTransferable();
    if (_to == address(0)) revert InvalidRecipient();
  }
}
