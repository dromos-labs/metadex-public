// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title  RelayConfigLib
 * @notice The Relay's mutable configuration: the display name, the module and governor rotations, and
 *         the three proposal flows that pay an exit-window delay before they land (the leaf claim
 *         recipient, the leaf operator and the L2 entrypoint attachment). The Relay keeps the access
 *         checks and the role grants, which OwnableRoles only exposes unguarded internally.
 * @dev    EXTERNAL (linked) library, delegatecalled (EIP-170), so every write and every event lands
 *         on the Relay itself.
 */
library RelayConfigLib {
  /// @notice Replaces the Relay's display name, emitting both values.
  /// @param _config The Relay's configuration (its storage).
  /// @param _name The new name.
  function setName(IRelay.RelayConfig storage _config, string calldata _name) external {
    emit IRelay.NameChanged(_config.name, _name);
    _config.name = _name;
  }

  /// @notice Points the Relay at another VoterPaymentsModule and hands it the sAERO spending right.
  /// @param _votingEscrow VotingEscrow holding both the authorization set and the approval.
  /// @param _vpm Module to move to.
  /// @param _tokenId The Relay's sAERO.
  /// @dev The escrow's approval holds a single address, so this takes the spending right off the
  ///      outgoing module in the same call.
  function rotateModule(IVotingEscrow _votingEscrow, address _vpm, uint256 _tokenId) external {
    if (_vpm == address(0)) revert IRelay.ZeroAddress();
    if (!_votingEscrow.isAuthorizedVPM(_vpm)) revert IRelay.ModuleNotAuthorized();

    _votingEscrow.approve(_vpm, _tokenId);
    emit IRelay.VoterPaymentsModuleSet(_vpm);
  }

  /// @notice Zero-checks and event for `setGovernor` (delegatecalled; the writes stay on the Relay).
  /// @param _governor Governor being rotated to.
  /// @param _voteAdapter Adapter being rotated to.
  function rotateGovernor(address _governor, address _voteAdapter) external {
    if (_governor == address(0) || _voteAdapter == address(0)) revert IRelay.ZeroAddress();
    emit IRelay.GovernorSet(_governor, _voteAdapter);
  }

  /// @notice Stamps a proposed leaf claim recipient, starting its exit-window delay.
  /// @param _pendingLeafRecipient Per-chain pending proposals (the Relay's storage).
  /// @param _chainId Leaf chain the recipient applies to.
  /// @param _recipient Proposed claim recipient; zero is rejected (disabling is the clear path).
  /// @param _timelock Delay the proposal has to wait out, in seconds.
  /// @dev One live proposal per chain: proposing again replaces it and restarts the delay.
  function proposeLeafRecipient(
    mapping(uint256 chainId => IRelay.PendingRecipient pending) storage _pendingLeafRecipient,
    uint256 _chainId,
    address _recipient,
    uint256 _timelock
  ) external {
    if (_recipient == address(0)) revert IRelay.ZeroAddress();
    _pendingLeafRecipient[_chainId] =
      IRelay.PendingRecipient({recipient: _recipient, proposedAt: uint48(block.timestamp)});
    emit IRelay.LeafRecipientProposed(_chainId, _recipient, block.timestamp + _timelock);
  }

  /// @notice Lands a proposed leaf claim recipient once its delay has elapsed.
  /// @param _leafRecipient Per-chain claim recipients (the Relay's storage).
  /// @param _pendingLeafRecipient Per-chain pending proposals (the Relay's storage).
  /// @param _chainId Leaf chain whose proposal is executed.
  /// @param _timelock Delay the proposal had to wait out, in seconds.
  function executeLeafRecipient(
    mapping(uint256 chainId => address recipient) storage _leafRecipient,
    mapping(uint256 chainId => IRelay.PendingRecipient pending) storage _pendingLeafRecipient,
    uint256 _chainId,
    uint256 _timelock
  ) external {
    IRelay.PendingRecipient memory _pending = _pendingLeafRecipient[_chainId];
    if (_pending.recipient == address(0)) revert IRelay.LeafRecipientNotProposed();
    if (block.timestamp < uint256(_pending.proposedAt) + _timelock) revert IRelay.LeafRecipientTimelockNotElapsed();
    delete _pendingLeafRecipient[_chainId];
    _leafRecipient[_chainId] = _pending.recipient;
    emit IRelay.LeafRecipientSet(_chainId, _pending.recipient);
  }

  /// @notice Disables claims for a leaf chain and cancels any proposal pending for it.
  /// @param _leafRecipient Per-chain claim recipients (the Relay's storage).
  /// @param _pendingLeafRecipient Per-chain pending proposals (the Relay's storage).
  /// @param _chainId Leaf chain to disable.
  /// @dev No delay: it only removes a capability. It is also the cancel path for a proposal made in
  ///      error, which is why it clears the pending slot even when no recipient is configured.
  function clearLeafRecipient(
    mapping(uint256 chainId => address recipient) storage _leafRecipient,
    mapping(uint256 chainId => IRelay.PendingRecipient pending) storage _pendingLeafRecipient,
    uint256 _chainId
  ) external {
    delete _pendingLeafRecipient[_chainId];
    if (_leafRecipient[_chainId] == address(0)) return;
    delete _leafRecipient[_chainId];
    emit IRelay.LeafRecipientSet(_chainId, address(0));
  }

  /// @notice Stamps a proposed leaf operator, starting its exit-window delay.
  /// @param _pendingOperator Per-chain pending proposals (the Relay's storage).
  /// @param _chainId Leaf chain the operator would act on.
  /// @param _operator Proposed operator; zero is rejected (clearing the seat is the revoke path).
  /// @param _config The Relay's configuration (its storage), read for the delay.
  /// @dev One live proposal per chain: proposing again replaces it and restarts the delay.
  function proposeOperator(
    mapping(uint256 chainId => IRelay.PendingOperator pending) storage _pendingOperator,
    uint256 _chainId,
    address _operator,
    IRelay.RelayConfig storage _config
  ) external {
    if (_operator == address(0)) revert IRelay.ZeroAddress();
    _pendingOperator[_chainId] = IRelay.PendingOperator({operator: _operator, proposedAt: uint48(block.timestamp)});
    emit IRelay.OperatorProposed(_chainId, _operator, block.timestamp + _config.entrypointTimelock);
  }

  /// @notice Sends a proposed leaf operator to its chain once the delay has elapsed.
  /// @param _pendingOperator Per-chain pending proposals (the Relay's storage).
  /// @param _voter Voter the update is dispatched through.
  /// @param _chainId Leaf chain whose proposal is executed.
  /// @param _gasLimit Destination gas budget for the leaf call.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  /// @param _config The Relay's configuration (its storage), read for the sAERO and the delay.
  /// @dev The proposal clears before the dispatch, so a Voter that reverts takes the whole call
  ///      with it and the proposal survives to be retried.
  function executeOperator(
    mapping(uint256 chainId => IRelay.PendingOperator pending) storage _pendingOperator,
    IVoter _voter,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient,
    IRelay.RelayConfig storage _config
  ) external {
    IRelay.PendingOperator memory _pending = _pendingOperator[_chainId];
    if (_pending.operator == address(0)) revert IRelay.OperatorNotProposed();
    if (block.timestamp < uint256(_pending.proposedAt) + _config.entrypointTimelock) {
      revert IRelay.OperatorTimelockNotElapsed();
    }

    delete _pendingOperator[_chainId];
    emit IRelay.OperatorDispatched(_chainId, _pending.operator);
    _voter.setOperator{value: msg.value}(_config.tokenId, _chainId, _pending.operator, _gasLimit, _refundRecipient);
  }

  /// @notice Clears the operator on a leaf chain and cancels any proposal pending for it.
  /// @param _pendingOperator Per-chain pending proposals (the Relay's storage).
  /// @param _voter Voter the update is dispatched through.
  /// @param _chainId Leaf chain to clear the seat on.
  /// @param _gasLimit Destination gas budget for the leaf call.
  /// @param _refundRecipient Recipient of any unused dispatch value.
  /// @param _config The Relay's configuration (its storage), read for the sAERO.
  /// @dev No delay: it only removes a capability. It always dispatches, even with nothing pending
  ///      and no operator seated, because the seat lives on the leaf and root does not mirror it.
  function revokeOperator(
    mapping(uint256 chainId => IRelay.PendingOperator pending) storage _pendingOperator,
    IVoter _voter,
    uint256 _chainId,
    uint256 _gasLimit,
    address _refundRecipient,
    IRelay.RelayConfig storage _config
  ) external {
    delete _pendingOperator[_chainId];
    emit IRelay.OperatorDispatched(_chainId, address(0));
    _voter.setOperator{value: msg.value}(_config.tokenId, _chainId, address(0), _gasLimit, _refundRecipient);
  }

  /// @notice Stamps a proposed entrypoint attachment, starting its exit-window delay.
  /// @param _entrypointProposedAt Per-(role, account) proposal stamps (the Relay's storage).
  /// @param _role Entrypoint role being proposed; the Relay validates which roles are eligible.
  /// @param _account Entrypoint address proposed for the role.
  /// @param _timelock Delay the proposal has to wait out, in seconds.
  /// @dev Re-proposing the same pair resets the timer.
  function proposeEntrypoint(
    mapping(uint256 role => mapping(address account => uint256 proposedAt)) storage _entrypointProposedAt,
    uint256 _role,
    address _account,
    uint256 _timelock
  ) external {
    if (_account == address(0)) revert IRelay.ZeroAddress();
    _entrypointProposedAt[_role][_account] = block.timestamp;
    emit IRelay.EntrypointProposed(_role, _account, block.timestamp + _timelock);
  }

  /// @notice Consumes an entrypoint proposal whose delay has elapsed, so the caller can grant the role.
  /// @param _entrypointProposedAt Per-(role, account) proposal stamps (the Relay's storage).
  /// @param _role Entrypoint role proposed.
  /// @param _account Entrypoint address proposed for the role.
  /// @param _timelock Delay the proposal had to wait out, in seconds.
  /// @dev Reverts when nothing is proposed for the pair or the delay has not elapsed. The grant stays
  ///      on the Relay: OwnableRoles exposes its unguarded grant only internally.
  function consumeEntrypointProposal(
    mapping(uint256 role => mapping(address account => uint256 proposedAt)) storage _entrypointProposedAt,
    uint256 _role,
    address _account,
    uint256 _timelock
  ) external {
    uint256 _proposedAt = _entrypointProposedAt[_role][_account];
    if (_proposedAt == 0) revert IRelay.EntrypointNotProposed();
    if (block.timestamp < _proposedAt + _timelock) revert IRelay.EntrypointTimelockNotElapsed();
    delete _entrypointProposedAt[_role][_account];
  }
}
