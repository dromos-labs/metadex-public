// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayGovernanceHost} from 'V3/interfaces/relay/IRelayGovernanceHost.sol';
import {IRelayTokenVotes} from 'V3/interfaces/relay/IRelayTokenVotes.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';

/// @dev Fractional support marker mirroring the Governor's counting module: `params` carries three
///      packed `uint128` weights (against, for, abstain) instead of a single direction.
uint8 constant VOTE_TYPE_FRACTIONAL = type(uint8).max;

/**
 * @title  RelayGovernanceLib
 * @notice The Relay's Flexible Voting logic: principal-token holders express a preference and the
 *         Relay casts a fractional vote matching their share of its governance weight at the
 *         proposal snapshot.
 * @dev    Holds two kinds of function, with opposite calling conventions. The vote path is
 *         delegatecalled by the Relay (EIP-170) and reads the Relay's own storage. The three views
 *         (`votingPower`, `remainingVotingPower`, `getPastTotalSupply`) take the Relay as a
 *         parameter and are called at this library's own address, never through the Relay, so a
 *         front end gets the slice formula without the Relay paying bytecode for it.
 * @dev    Delegatecall is what makes the vote path work: the Governor credits weight to the (caller, sAERO) pair, and under delegatecall the
 *         cast reaches it from the Relay itself while `msg.sender` stays the holder. Weight comes
 *         from the PRINCIPAL token's checkpoints, never the yield token: a holder who sells their
 *         YT keeps every vote. The consumption ledger lives in the Relay's storage, so relinking
 *         this library cannot reset what a holder spent.
 */
library RelayGovernanceLib {
  /// @notice The Relay-side values needed to compute a cast, bundled to stay under the legacy
  ///         pipeline's stack limit.
  /// @param relay The Relay whose sAERO governance weight is being spent (`address(this)`).
  /// @param principalToken Checkpointed principal token (PT) every slice is measured against.
  /// @param governor Governor the fractional cast is forwarded to.
  /// @param voteAdapter Adapter speaking the Governor's dialect, consulted by STATICCALL only.
  /// @param votingEscrow VotingEscrow the Relay's snapshot weight is read from.
  /// @param relayTokenId The Relay's sAERO. Holder slices are taken from its voting weight.
  struct Context {
    address relay;
    IRelayTokenVotes principalToken;
    IGovernor governor;
    IRelayVoteAdapter voteAdapter;
    IVotingEscrow votingEscrow;
    uint256 relayTokenId;
  }

  /// @notice Expresses a per-proposal preference and casts it as a fractional vote scaled to the
  ///         caller's snapshot slice of the Relay's governance weight.
  /// @param _usedWeight Per-(governor, proposal, holder) consumption ledger (the Relay's storage).
  ///        The governor dimension keeps a rotation from inheriting a colliding proposal id's spend.
  /// @param _ctx The Relay-side values used to compute the slice.
  /// @param _proposalId Proposal being voted on. The Governor enforces that it is active.
  /// @param _support Preference: 0 Against, 1 For, 2 Abstain (empty params, spends the whole
  ///        remaining slice), or 255 fractional (params carry three packed `uint128` weights).
  /// @param _params Counting-module params matching `_support`.
  /// @param _reason Free-form reason string forwarded to the Governor.
  /// @dev Reads everything at the proposal snapshot, so principal moved after it carries no rights
  ///      for that proposal. The spent weight is recorded before the external cast (CEI).
  function expressVote(
    mapping(
      address governor => mapping(uint256 proposalId => mapping(address holder => uint256 used))
    ) storage _usedWeight,
    Context memory _ctx,
    uint256 _proposalId,
    uint8 _support,
    bytes calldata _params,
    string calldata _reason
  ) external {
    uint256 _slice = _sliceAt(_ctx, _ctx.voteAdapter.proposalSnapshot(address(_ctx.governor), _proposalId), msg.sender);
    if (_slice == 0) revert IRelay.NoVotingPower();

    mapping(address holder => uint256 used) storage _ledger = _usedWeight[address(_ctx.governor)][_proposalId];
    uint256 _used = _ledger[msg.sender];
    if (_slice <= _used) revert IRelay.AlreadyVoted();

    (uint256 _requested, uint256 _against, uint256 _for, uint256 _abstain) =
      _decodeRequested(_support, _params, _slice - _used);

    // Record the spent weight before the external cast (CEI).
    _ledger[msg.sender] = _used + _requested;

    _cast(_ctx, _proposalId, _against, _for, _abstain, _reason);

    emit IRelay.VoteExpressed(_proposalId, msg.sender, _support, _requested, _params);
  }

  /// @notice Weight `_holder` can still spend on `_proposalId`: their slice minus what they already
  ///         consumed. Zero once the slice is exhausted, so a UI can disable the action.
  /// @param _relay Relay being queried.
  /// @param _proposalId Proposal being queried.
  /// @param _holder Principal-token holder whose voting weight is computed.
  /// @return _remaining Unspent weight from the holder's slice.
  function remainingVotingPower(
    address _relay,
    uint256 _proposalId,
    address _holder
  ) external view returns (uint256 _remaining) {
    IRelayGovernanceHost _host = IRelayGovernanceHost(_relay);
    uint256 _slice = votingPower(_relay, _proposalId, _holder);
    uint256 _used = _host.usedGovernanceWeight(address(_host.governor()), _proposalId, _holder);
    _remaining = _slice > _used ? _slice - _used : 0;
  }

  /// @notice Principal-token total supply at a past timepoint, from its voting checkpoints.
  /// @param _relay Relay being queried.
  /// @param _timepoint Past timestamp to read (must be strictly before the current clock).
  /// @return _supply The checkpointed total supply at `_timepoint`.
  function getPastTotalSupply(address _relay, uint256 _timepoint) external view returns (uint256 _supply) {
    _supply = IRelayTokenVotes(IRelayGovernanceHost(_relay).principalToken()).getPastVotesTotalSupply(_timepoint);
  }

  /// @notice Total voting weight `_holder` may spend on `_proposalId`: their principal share of the
  ///         Relay's governance weight, all read at the proposal snapshot. This is the function a
  ///         voting UI should call, so a front end never needs to reproduce the slice formula.
  /// @param _relay Relay being queried.
  /// @param _proposalId Proposal being queried.
  /// @param _holder Principal-token holder whose voting weight is computed.
  /// @return _slice The holder's total weight budget for the proposal; zero when they held no
  ///         principal at the snapshot, rather than reverting.
  /// @dev Called directly at this library's own address, never through the Relay, so the view
  ///      helpers add no bytecode to the Relay. Every input is read back from `_relay`, so the
  ///      answer matches what `expressVote` would compute in the same block.
  function votingPower(address _relay, uint256 _proposalId, address _holder) public view returns (uint256 _slice) {
    Context memory _ctx = _contextOf(_relay);
    _slice = _sliceAt(_ctx, _ctx.voteAdapter.proposalSnapshot(address(_ctx.governor), _proposalId), _holder);
  }

  /// @notice Send one decoded cast to the Governor, encoded by the adapter.
  /// @param _ctx The Relay-side values used to compute the slice.
  /// @param _proposalId Proposal being voted on.
  /// @param _against Weight cast against.
  /// @param _for Weight cast in favor.
  /// @param _abstain Weight cast as abstention.
  /// @param _reason Free-form reason string forwarded to the Governor.
  /// @dev Runs under the Relay's delegatecall, so the cast reaches the Governor with the Relay as
  ///      `msg.sender` (the pair it credits weight to). The adapter never names the target: the
  ///      calldata it returns is sent to the Relay's stored Governor, and a failed cast rebubbles
  ///      the Governor's revert data verbatim.
  function _cast(
    Context memory _ctx,
    uint256 _proposalId,
    uint256 _against,
    uint256 _for,
    uint256 _abstain,
    string calldata _reason
  ) private {
    bytes memory _callData =
      _ctx.voteAdapter.encodeCast(_proposalId, _ctx.relayTokenId, _against, _for, _abstain, _reason);

    // The Relay owns the pooled sAERO and its clones, so a call leaving its own context is
    // authority-bearing. A rotated Governor and adapter can only ever be a fractional cast: pin the
    // selector before the send, so a malicious adapter cannot smuggle a `transferFrom` of the NFT or
    // a clone mint through the Governor slot.
    // Under four bytes there is no selector to read: the load would pull in whatever sits past the
    // array, so reject the payload instead of comparing against unallocated memory.
    if (_callData.length < 4) revert IRelay.UnexpectedCastSelector();

    bytes4 _selector;
    assembly ('memory-safe') {
      _selector := mload(add(_callData, 0x20))
    }
    if (_selector != IGovernor.castVoteWithReasonAndParams.selector) revert IRelay.UnexpectedCastSelector();

    (bool _ok, bytes memory _returnData) = address(_ctx.governor).call(_callData);
    if (!_ok) {
      assembly ('memory-safe') {
        revert(add(_returnData, 0x20), mload(_returnData))
      }
    }
  }

  /// @notice The slice of the Relay's sAERO governance weight that `_holder` may spend on a
  ///         proposal: the Relay's snapshot weight multiplied by the holder's share of the
  ///         checkpointed principal supply, both read at `_snapshot`.
  /// @param _ctx The Relay-side values used to compute the slice.
  /// @param _snapshot Timepoint every read anchors to (the proposal's snapshot).
  /// @param _holder Principal-token holder whose slice is computed.
  /// @return _slice The holder's proportional weight budget, or zero when they hold no checkpointed
  ///         principal at `_snapshot`.
  /// @dev The numerator is the Relay sAERO's VE governance weight, NOT `totalBacking`: it is the
  ///      weight the Governor itself credits, so the two sides cannot drift, and flooring keeps the
  ///      sum of every slice at or below it. A deposit still queued at the snapshot holds no
  ///      principal, so its weight is divided among the holders already in (the gauge side treats
  ///      queued weight the same way). Weight delegated to the Relay's sAERO by other stakes is
  ///      included and divided too, deliberately: delegating to the Relay means accepting what its
  ///      holders decide together.
  function _sliceAt(Context memory _ctx, uint256 _snapshot, address _holder) private view returns (uint256 _slice) {
    uint256 _holderPrincipal = _ctx.principalToken.getPastVotes(_holder, _snapshot);
    if (_holderPrincipal == 0) return 0;

    uint256 _relayWeight = _ctx.votingEscrow.getPastVotes(_ctx.relay, _ctx.relayTokenId, _snapshot);
    _slice = (_relayWeight * _holderPrincipal) / _ctx.principalToken.getPastVotesTotalSupply(_snapshot);
  }

  /// @notice Rebuilds the slice context from the Relay's public getters, for the view helpers.
  /// @param _relay Relay to read.
  /// @return _ctx The same context `expressVote` receives from the Relay itself.
  function _contextOf(address _relay) private view returns (Context memory _ctx) {
    IRelayGovernanceHost _host = IRelayGovernanceHost(_relay);
    _ctx = Context({
      relay: _relay,
      principalToken: IRelayTokenVotes(_host.principalToken()),
      governor: _host.governor(),
      voteAdapter: _host.voteAdapter(),
      votingEscrow: _host.VOTING_ESCROW(),
      relayTokenId: _host.relayConfig().tokenId
    });
  }

  /// @notice Map a holder's `(_support, _params)` request onto the canonical cast: a single
  ///         requested weight plus its (against, for, abstain) split.
  /// @param _support Requested support: 0 Against, 1 For, 2 Abstain or 255 fractional.
  /// @param _params Holder-supplied params: empty for nominal support, three packed `uint128`
  ///        weights (against, for, abstain) for fractional.
  /// @param _remaining Weight still unspent from the caller's snapshot slice.
  /// @return _requested Weight this call consumes: the sum of the three components.
  /// @return _against Weight cast against.
  /// @return _for Weight cast in favor.
  /// @return _abstain Weight cast as abstention.
  /// @dev The cast is ALWAYS forwarded as a split, never as a nominal 0/1/2: the Governor cannot
  ///      see the holder's slice, so a nominal support would consume the Relay's entire remaining
  ///      weight. The payload is the Relay's own ABI and does not move when an adapter re-encodes
  ///      the Governor-facing leg. A nominal request spends the whole remaining slice in one
  ///      direction, capped at `type(uint128).max` per call.
  function _decodeRequested(
    uint8 _support,
    bytes calldata _params,
    uint256 _remaining
  ) private pure returns (uint256 _requested, uint256 _against, uint256 _for, uint256 _abstain) {
    if (_support == VOTE_TYPE_FRACTIONAL) {
      // Exactly three packed uint128s: against, for, abstain.
      if (_params.length != 0x30) revert IRelay.InvalidSupport();

      _against = uint128(bytes16(_params[0:16]));
      _for = uint128(bytes16(_params[16:32]));
      _abstain = uint128(bytes16(_params[32:48]));
      _requested = _against + _for + _abstain;

      if (_requested > _remaining) revert IRelay.ExceedsRemainingSlice();
      return (_requested, _against, _for, _abstain);
    }

    // Nominal Against (0) / For (1) / Abstain (2): empty params, whole slice in one direction.
    if (_support > 2 || _params.length != 0) revert IRelay.InvalidSupport();

    _requested = _remaining > type(uint128).max ? type(uint128).max : _remaining;

    if (_support == 0) _against = _requested;
    else if (_support == 1) _for = _requested;
    else _abstain = _requested;
  }
}
