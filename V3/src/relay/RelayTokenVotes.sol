// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {ERC20} from '@solady/tokens/ERC20.sol';
import {ERC20Votes} from '@solady/tokens/ERC20Votes.sol';

import {IRelayTokenVotes} from 'V3/interfaces/relay/IRelayTokenVotes.sol';

import {RelayToken} from 'V3/relay/RelayToken.sol';

/**
 * @title  RelayTokenVotes
 * @notice The implementation that every principal token (PT) clone runs: a RelayToken that also
 *         checkpoints its balances, so a governance module can read a holder's voting weight at a
 *         past timepoint. The yield token (YT) keeps the plain RelayToken, which has no checkpoints.
 * @dev    The PT is soulbound, so the Relay's `mint` and `burn` are the only writers of this
 *         history: a deposit/withdraw history, never a trading one. A holder who sells their YT
 *         keeps every checkpointed vote. Checkpoints record from deployment, so a governance
 *         module attached later can still read history written before it existed.
 */
contract RelayTokenVotes is RelayToken, ERC20Votes, IRelayTokenVotes {
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~*/
  /*                                                    FUNCTIONS                                       __|__         */
  /*~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~  --@--@--(_)--@--@--  */

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only: RelayToken and ERC20Votes share the ERC20 base, so solc
  ///      requires the most-derived contract to name the override. `super` resolves to RelayToken's
  ///      gated implementation.
  function transfer(address _to, uint256 _amount) public override(RelayToken, ERC20) returns (bool _success) {
    _success = super.transfer(_to, _amount);
  }

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only; `super` resolves to RelayToken's gated implementation.
  function transferFrom(
    address _from,
    address _to,
    uint256 _amount
  ) public override(RelayToken, ERC20) returns (bool _success) {
    _success = super.transferFrom(_from, _to, _amount);
  }

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only; `super` resolves to RelayToken's gated implementation.
  function permit(
    address _owner,
    address _spender,
    uint256 _value,
    uint256 _deadline,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) public override(RelayToken, ERC20) {
    super.permit(_owner, _spender, _value, _deadline, _v, _r, _s);
  }

  /// @inheritdoc IRelayTokenVotes
  function getPastVotes(
    address _account,
    uint256 _timepoint
  ) public view override(ERC20Votes, IRelayTokenVotes) returns (uint256 _votes) {
    _votes = super.getPastVotes(_account, _timepoint);
  }

  /// @inheritdoc IRelayTokenVotes
  function getPastVotesTotalSupply(uint256 _timepoint)
    public
    view
    override(ERC20Votes, IRelayTokenVotes)
    returns (uint256 _totalVotes)
  {
    _totalVotes = super.getPastVotesTotalSupply(_timepoint);
  }

  /// @inheritdoc IRelayTokenVotes
  function delegates(address _delegator)
    public
    view
    override(ERC20Votes, IRelayTokenVotes)
    returns (address _delegatee)
  {
    _delegatee = super.delegates(_delegator);
  }

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only.
  function balanceOf(address _owner) public view override(RelayToken, ERC20) returns (uint256 _balance) {
    _balance = super.balanceOf(_owner);
  }

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only.
  function totalSupply() public view override(RelayToken, ERC20) returns (uint256 _totalSupply) {
    _totalSupply = super.totalSupply();
  }

  /// @notice ERC-6372 clock for the checkpoints. It uses timestamps, the same clock as VotingEscrow,
  ///         so one Governor proposal snapshot is a valid input to both contracts.
  /// @return _timepoint The current block timestamp.
  function clock() public view override returns (uint48 _timepoint) {
    _timepoint = uint48(block.timestamp);
  }

  /// @notice ERC-6372 clock mode descriptor matching `clock()`.
  /// @return _mode The timestamp clock mode string.
  function CLOCK_MODE() public pure override returns (string memory _mode) {
    _mode = 'mode=timestamp';
  }

  /// @notice Post-transfer hook: advance the checkpoints, then self-delegate a first-time recipient.
  ///         Without this, a depositor who never called `delegate` would have zero voting power.
  /// @param _from Sender (zero on mint).
  /// @param _to Recipient (zero on burn).
  /// @param _amount Token amount moved.
  /// @dev Runs after all balance writes, which is what `ERC20Votes` requires. The self-delegation
  ///      only fires while `delegates(_to)` is unset, so a holder who delegated elsewhere is never
  ///      overridden.
  function _afterTokenTransfer(address _from, address _to, uint256 _amount) internal override(ERC20, ERC20Votes) {
    super._afterTokenTransfer(_from, _to, _amount);
    if (_to != address(0) && delegates(_to) == address(0)) _delegate(_to, _to);
  }

  /// @inheritdoc RelayToken
  /// @dev Diamond disambiguation only; `super` resolves to RelayToken's Relay-hook implementation,
  ///      which must keep firing BEFORE any balance write so the Relay settles on pre-change
  ///      balances.
  function _beforeTokenTransfer(address _from, address _to, uint256 _amount) internal override(RelayToken, ERC20) {
    super._beforeTokenTransfer(_from, _to, _amount);
  }
}
