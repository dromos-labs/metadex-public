// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {RelayConfigLib} from 'V3/relay/libraries/RelayConfigLib.sol';
import {RelayRewardsLib} from 'V3/relay/libraries/RelayRewardsLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {RelayBase} from 'V3/relay/RelayBase.sol';

/**
 * @title  ProtocolRelay
 * @notice Protocol Relay tier (L1/L2): only allow-listed addresses can deposit and receive share
 *         transfers. A one-way `promoteToLevel2` hands the Relay's ownership to the L2 admin and
 *         unlocks the mutable reward registry, the timelocked entrypoint attachments and the
 *         `sweep` recovery function.
 */
contract ProtocolRelay is RelayBase {
  /// @notice Addresses permitted to deposit and to receive share transfers (both L1 and L2).
  /// @return isAllowed True when the account is permitted.
  mapping(address account => bool isAllowed) public allowList;

  /// @notice Whether the Relay is Protocol L2 (deployed as L2 or promoted from L1). One-way.
  /// @return True once the Relay is L2.
  bool public isLevel2;

  /// @notice Timestamp a (role, account) entrypoint attachment was proposed, gating its execution
  ///         by `entrypointTimelock`. Zero means no live proposal.
  /// @return proposedAt Block timestamp of the proposal, or zero when none is pending.
  mapping(uint256 role => mapping(address account => uint256 proposedAt)) public entrypointProposedAt;

  /// @notice Binds the protocol-wide dependencies; per-Relay state is set in `initialize`.
  /// @param _votingEscrow VotingEscrow address.
  /// @param _voter Voter address.
  /// @param _principalTokenImplementation Checkpointed RelayToken implementation cloned as the PT.
  /// @param _yieldTokenImplementation Plain RelayToken implementation cloned as the YT.
  /// @param _wrappedNative Wrapped native token every native inflow is wrapped into.
  constructor(
    IVotingEscrow _votingEscrow,
    IVoter _voter,
    address _principalTokenImplementation,
    address _yieldTokenImplementation,
    address _wrappedNative
  ) RelayBase(_votingEscrow, _voter, _principalTokenImplementation, _yieldTokenImplementation, _wrappedNative) {}

  /// @notice Add or remove an address from the deposit/transfer allow list.
  /// @param _account Address to permit or revoke.
  /// @param _allowed True to permit, false to revoke.
  function setAllowList(address _account, bool _allowed) external onlyOwner {
    if (allowList[_account] == _allowed) return;
    allowList[_account] = _allowed;
    emit AllowListSet(_account, _allowed);
  }

  /// @notice Forces an account out: removes it from the allow list, settles its rewards and sends
  ///         its entire free position to the withdraw queue.
  /// @param _account Account to remove and eject.
  function kick(address _account) external onlyOwner {
    if (allowList[_account]) {
      allowList[_account] = false;
      emit AllowListSet(_account, false);
    }
    uint256 _shares = _ejectHolder(_account);
    emit Kicked(_account, _shares);
  }

  /// @notice Promotes this L1 Relay to L2: hands the ownership to the L2 admin and unlocks the
  ///         mutable registry, the entrypoint attachments and `sweep`.
  /// @param _admin2 Address to receive the ownership.
  /// @dev One-way; existing depositors keep their shares but face the L2 trust model. A zero
  ///      admin2 is rejected by `transferOwnership`: promotion is one-way, so a vacant owner seat
  ///      would leave no account able to rotate any operator.
  function promoteToLevel2(address _admin2) external onlyOwner {
    if (isLevel2) _revert(uint32(NotPromotable.selector));
    isLevel2 = true;
    transferOwnership(_admin2);
    emit PromotedToLevel2(_admin2);
  }

  /// @notice Transfers ERC-20 tokens held by the Relay on root to caller-chosen recipients: the
  ///         L2-only recovery path. Each entry is capped at its token's un-accounted balance, so
  ///         rewards already owed to claimants can never leave through here.
  /// @param _legs ERC-20 sweep legs; each moves `amount` of `token` from the Relay to `recipient`.
  /// @dev L2-only: on L1 the Relay holds external user funds, so an unrestricted exit is forbidden.
  ///      Root-only: funds on leaf chains are moved out by the bridge transport.
  function sweep(ERC20Sweep[] calldata _legs) external onlyRoles(SWEEPER) {
    if (!isLevel2) _revert(uint32(NotLevel2.selector));
    RelayRewardsLib.sweep(accountedBalance, _legs);
  }

  /// @notice Proposes attaching an entrypoint to a role on an L2 Relay. The timelock before
  ///         execution gives depositors time to exit before the entrypoint can pull funds.
  /// @param _role Entrypoint role to grant — must be COMPOUNDER or CONVERTER.
  /// @param _account Entrypoint address to attach.
  /// @dev L2-only: an L1 Relay's entrypoints are fixed at initialization. Re-proposing the same
  ///      pair resets the timer.
  function proposeEntrypoint(uint256 _role, address _account) external onlyOwner {
    if (!isLevel2) _revert(uint32(NotLevel2.selector));
    _validateEntrypointRole(_role);
    RelayConfigLib.proposeEntrypoint(entrypointProposedAt, _role, _account, _relayConfig.entrypointTimelock);
  }

  /// @notice Executes a proposed entrypoint attachment once its timelock has elapsed.
  /// @param _role Entrypoint role proposed (COMPOUNDER or CONVERTER).
  /// @param _account Entrypoint address proposed for the role.
  /// @dev Reverts when nothing is proposed for the pair or the timelock has not elapsed.
  function executeEntrypoint(uint256 _role, address _account) external onlyOwner {
    RelayConfigLib.consumeEntrypointProposal(entrypointProposedAt, _role, _account, _relayConfig.entrypointTimelock);
    _grantRoles(_account, _role);
  }

  /// @notice Cancels a pending entrypoint proposal before it can be executed.
  /// @param _role Entrypoint role the pending proposal targets.
  /// @param _account Entrypoint address the pending proposal targets.
  /// @dev The veto sits on its own role so the timelock has a second party: an owner that held both
  ///      sides could propose, wait and execute with nobody able to stop it, which is the whole
  ///      point of the delay. No level gate: a proposal can only exist on L2.
  function vetoEntrypoint(uint256 _role, address _account) external onlyRoles(ENTRYPOINT_VETOER) {
    if (entrypointProposedAt[_role][_account] == 0) _revert(uint32(EntrypointNotProposed.selector));
    delete entrypointProposedAt[_role][_account];
    emit EntrypointVetoed(_role, _account);
  }

  /// @notice Hands the veto seat to a successor, named by the sitting vetoer.
  /// @param _vetoer Address receiving the seat.
  /// @dev The owner stays out of the rotation: the public role paths refuse the bit, so the party
  ///      the veto watches can neither seat nor unseat it.
  function transferVetoer(address _vetoer) external onlyRoles(ENTRYPOINT_VETOER) {
    if (_vetoer == address(0)) _revert(uint32(ZeroAddress.selector));
    _removeRoles(msg.sender, ENTRYPOINT_VETOER);
    _grantRoles(_vetoer, ENTRYPOINT_VETOER);
  }

  /// @notice Detaches an entrypoint immediately and cancels any pending proposal for it.
  /// @param _role Entrypoint role to revoke (COMPOUNDER or CONVERTER).
  /// @param _account Entrypoint address to detach.
  /// @dev Revoking only removes a capability, so a compromised entrypoint can be disabled without
  ///      delay.
  function revokeEntrypoint(uint256 _role, address _account) external onlyOwner {
    if (!isLevel2) _revert(uint32(NotLevel2.selector));
    _validateEntrypointRole(_role);
    delete entrypointProposedAt[_role][_account];
    _removeRoles(_account, _role);
  }

  /// @inheritdoc RelayBase
  function relayType() external view override returns (RelayType _relayType) {
    _relayType = isLevel2 ? RelayType.ProtocolL2 : RelayType.ProtocolL1;
  }

  /// @inheritdoc RelayBase
  /// @dev The transferable-YT rejection lives here rather than in the factory because anyone can
  ///      clone the public implementation and call `initialize` directly.
  function _initializeTier(InitParams memory _params) internal virtual override {
    // The tier depends on kicking, and a kicked holder that sold its YT would have no pair to burn.
    if (_params.ytTransferable) _revert(uint32(TransferableYieldTokenNotAllowed.selector));

    // L1 shares the base tiers' fixed-entrypoint rule; an L2 start is exempt, it attaches later.
    if (!_params.startAsLevel2 && _params.compounder == address(0) && _params.converter == address(0)) {
      _revert(uint32(MissingEntrypoint.selector));
    }

    // Allow-list the bootstrap-share owner so its seeded position is transferable from genesis.
    allowList[_params.bootstrapOwner] = true;
    emit AllowListSet(_params.bootstrapOwner, true);

    // The only seating of the veto: the public role paths refuse the bit, so the owner can neither
    // install nor remove the vetoer, and a Relay created without one runs the timelock bare.
    if (_params.entrypointVetoer != address(0)) _grantRoles(_params.entrypointVetoer, ENTRYPOINT_VETOER);

    // The owner is already the L2 admin here, so the promotion is only the flag.
    if (_params.startAsLevel2) isLevel2 = true;
  }

  /// @inheritdoc RelayBase
  function _authorizeTransfer(address _from, address _to) internal view virtual override {
    // Both ends must be listed, so a removed holder can only exit: full withdraw rights, no transfers.
    if (!allowList[_from] || !allowList[_to]) _revert(uint32(NotAllowed.selector));
  }

  /// @inheritdoc RelayBase
  function _authorizeDeposit(address _owner) internal view virtual override {
    if (!allowList[_owner]) _revert(uint32(NotAllowed.selector));
  }

  /// @inheritdoc RelayBase
  function _canGrowRegistry() internal view virtual override returns (bool _can) {
    _can = isLevel2;
  }

  /// @notice Reverts unless the role is COMPOUNDER or CONVERTER.
  /// @param _role Role to validate.
  function _validateEntrypointRole(uint256 _role) internal pure {
    if (_role != COMPOUNDER && _role != CONVERTER) _revert(uint32(InvalidEntrypointRole.selector));
  }
}
