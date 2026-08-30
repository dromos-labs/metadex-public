// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IGovernor} from 'V3/interfaces/governor/IGovernor.sol';
import {IRelay} from 'V3/interfaces/relay/IRelay.sol';
import {IRelayVoteAdapter} from 'V3/interfaces/relay/IRelayVoteAdapter.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

/// @title  IRelayFactory
/// @notice Creates Maxi and Protocol Relays as deterministic EIP-1167 minimal proxies over
///         per-tier implementations. Each create call seeds a fresh sAERO with the initial
///         deposit, transfers it to the clone's predicted address, then clones and initializes the
///         Relay there — so initialization finds the sAERO already bound. Creation is restricted to
///         RELAY_DEPLOYER_ROLE on the Voter; using a Relay is governed by the Relay's own tier.
interface IRelayFactory {
  /// @notice Inputs to create a Relay. The protocol dependencies (VotingEscrow/VPM/Voter) are factory
  ///         immutables, so they are not repeated here.
  /// @param admin Initial owner: it holds the admin gates and manages every role bit.
  /// @param keeper Initial KEEPER operator.
  /// @param voter Initial VOTER_ROLE operator granted at deploy, or zero to skip; the owner can grant
  ///        or rotate it later.
  /// @param compounder Entrypoint granted COMPOUNDER at deploy, or zero to skip.
  /// @param converter Entrypoint granted CONVERTER at deploy, or zero to skip (same address as
  ///        `compounder` for a Hybrid).
  /// @param bootstrapOwner Recipient of the bootstrap shares minted 1:1 against the seed stake at
  ///        initialization (genesis price/share is exactly 1, so the seed is not gifted to the first
  ///        depositor). Must be non-zero; allow-listed at genesis on whitelist-gated tiers.
  /// @param rewardToken First reward token to register at initialization, or zero to leave the registry
  ///        empty for KEEPER. The registry never drops a token and the single-slot tiers close on the
  ///        first one, so naming it here pins it in the same call that names the entrypoints.
  /// @param entrypointVetoer Holder of ENTRYPOINT_VETOER on the Protocol tiers, or zero to run the
  ///        entrypoint timelock without a veto. The public role paths refuse the bit, so an empty
  ///        seat can never be filled afterwards; other tiers ignore this field.
  /// @param seedAmount Initial TOKEN staked into the Relay sAERO; pulled from the caller. A uint128,
  ///        matching VotingEscrow's stake amount, so no narrowing happens at stake time. A zero
  ///        seed is rejected downstream: VotingEscrow refuses a zero stake and `initialize`
  ///        re-checks the staked seed (the first-depositor inflation guard).
  /// @param isPermanent Whether the seed stake is permanent (true) or time-locked.
  /// @param ytTransferable True to deploy the yield token transferable; false makes it soulbound.
  ///        Immutable switch on the YT clone; tiers with an allow list reject true.
  /// @param stakingWeeks Lock length in weeks for a time-locked stake; must be zero when permanent.
  /// @param salt Caller-chosen salt deriving the clone's deterministic address. Hashed together
  ///        with the caller, so another account cannot occupy it; reusing a (caller, salt) pair on
  ///        the same tier reverts.
  /// @param config Relay configuration; its `tokenId` is overwritten with the freshly minted sAERO.
  struct CreateParams {
    address admin;
    address keeper;
    address voter;
    address compounder;
    address converter;
    address bootstrapOwner;
    address rewardToken;
    address entrypointVetoer;
    uint128 seedAmount;
    bool isPermanent;
    bool ytTransferable;
    uint48 stakingWeeks;
    bytes32 salt;
    IRelay.RelayConfig config;
  }

  /// @notice Emitted when a Relay is created.
  /// @param relay The deployed Relay address.
  /// @param tokenId The sAERO minted and bound to the Relay.
  /// @param relayType The tier of the created Relay.
  event RelayCreated(address indexed relay, uint256 indexed tokenId, IRelay.RelayType relayType);

  /// @notice Thrown when a zero address is supplied for a protocol dependency.
  error ZeroAddress();

  /// @notice Thrown when the caller lacks RELAY_DEPLOYER_ROLE on the Voter.
  error NotAuthorized();

  /// @notice Thrown when a tier implementation address holds no code, which would clone an inert
  ///         Relay and strand the seed sAERO transferred to its predicted address.
  error ImplementationNotAContract();

  /// @notice Thrown when a created Relay comes out of `initialize` with no satellite tokens, the
  ///         signature of a clone whose body never ran.
  error RelayInitializationFailed();

  /// @notice Creates a Maxi Relay: deposits into it are permissionless, creating it is not.
  /// @param _params Creation inputs.
  /// @return _relay The deployed Relay address.
  /// @return _tokenId The sAERO bound to the Relay.
  /// @dev Restricted to RELAY_DEPLOYER_ROLE: the gate says who may run a Maxi, not who may use one.
  function createMaxiRelay(CreateParams calldata _params) external returns (address _relay, uint256 _tokenId);

  /// @notice Creates a Protocol Relay, starting as L1 or directly as L2.
  /// @param _params Creation inputs.
  /// @param _startAsLevel2 True to deploy directly as Protocol L2; false to start as L1.
  /// @return _relay The deployed Relay address.
  /// @return _tokenId The sAERO bound to the Relay.
  /// @dev Restricted to RELAY_DEPLOYER_ROLE, which is what makes `_startAsLevel2` safe to take from
  ///      the caller.
  function createProtocolRelay(
    CreateParams calldata _params,
    bool _startAsLevel2
  ) external returns (address _relay, uint256 _tokenId);

  /// @notice Whether an address is a Relay this factory created.
  /// @param _relay Address to check.
  /// @return _created True when this factory created `_relay`.
  /// @dev The membership check for consumers that gate a privileged path on being a Relay (the
  ///      MetaRouter reads it). Answers in one storage read. Because creation is role-gated, a true
  ///      answer means an authorized deployer created it.
  function isRelay(address _relay) external view returns (bool _created);

  /// @notice The number of Relays this factory has created.
  /// @return _length The total count, which only ever grows.
  function allRelaysLength() external view returns (uint256 _length);

  /// @notice A page of created Relays, in creation order.
  /// @param _start First index to read, inclusive.
  /// @param _end Index to stop at, exclusive.
  /// @return _relays The Relays in that range.
  /// @dev Out-of-range input is clamped rather than rejected, so a caller can walk fixed-size pages
  ///      off the end without checking the length first.
  function allRelays(uint256 _start, uint256 _end) external view returns (address[] memory _relays);

  /// @notice The VotingEscrow every Relay this factory creates binds to; also mints the seed sAERO.
  /// @return _votingEscrow The VotingEscrow contract.
  function VOTING_ESCROW() external view returns (IVotingEscrow _votingEscrow);

  /// @notice The underlying protocol TOKEN, read from VotingEscrow; pulled from callers to seed stakes.
  /// @return _token The protocol TOKEN address.
  function TOKEN() external view returns (address _token);

  /// @notice The Voter whose role registry says who may create Relays here.
  /// @return _voter The Voter address.
  function VOTER() external view returns (address _voter);

  /// @notice MaxiRelay implementation every Maxi clone delegates to.
  /// @return _implementation The implementation address.
  function MAXI_IMPLEMENTATION() external view returns (address _implementation);

  /// @notice ProtocolRelay implementation every Protocol clone delegates to.
  /// @return _implementation The implementation address.
  function PROTOCOL_IMPLEMENTATION() external view returns (address _implementation);

  /// @notice VoterPaymentsModule every created Relay starts on.
  /// @return _vpm The VoterPaymentsModule contract.
  function VPM() external view returns (IVoterPaymentsModule _vpm);

  /// @notice Governor every created Relay starts casting into.
  /// @return _governor The Governor contract.
  function GOVERNOR() external view returns (IGovernor _governor);

  /// @notice Adapter every created Relay's casts start encoded by.
  /// @return _voteAdapter The vote adapter contract.
  function VOTE_ADAPTER() external view returns (IRelayVoteAdapter _voteAdapter);
}
