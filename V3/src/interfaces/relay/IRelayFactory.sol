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
  /// @param compounder Entrypoint granted COMPOUNDER at deploy, or zero to skip. Must be bound to
  ///        the new Relay (see `predictRelay`).
  /// @param converter Entrypoint granted CONVERTER at deploy, or zero to skip (same address as
  ///        `compounder` for a Hybrid). Must be bound to the new Relay.
  /// @param bootstrapOwner Recipient of the bootstrap shares minted 1:1 against the seed stake at
  ///        initialization (genesis price/share is exactly 1, so the seed is not gifted to the first
  ///        depositor). Must be non-zero; allow-listed at genesis on whitelist-gated tiers.
  /// @param rewardToken First reward token to register at initialization, or zero to leave the registry
  ///        empty for KEEPER. The registry never drops a token and the single-slot tiers close on the
  ///        first one, so naming it here pins it in the same call that names the entrypoints.
  /// @param entrypointVetoer Holder of ENTRYPOINT_VETOER on the Protocol tiers, or zero to run the
  ///        entrypoint timelock without a veto. The public role paths refuse the bit, so an empty
  ///        seat can never be filled afterwards; other tiers ignore this field.
  /// @param rakeManagerAdmin Non-zero holder of RAKE_MANAGER_ADMIN.
  /// @param protocolRakePips Genesis protocol rake, at most the tier's `MAX_RAKE_PIPS`.
  /// @param allocatorRakePips Genesis allocator rake, at most the tier's `MAX_RAKE_PIPS`.
  /// @param seedAmount Initial TOKEN staked into the Relay sAERO; pulled from the caller. A uint128,
  ///        matching VotingEscrow's stake amount, so no narrowing happens at stake time. A seed below
  ///        `MIN_STAKE_AMOUNT` is rejected downstream, where `initialize` re-checks the staked seed
  ///        (the first-depositor inflation guard).
  /// @param isPermanent Whether the seed stake is permanent (true) or time-locked.
  /// @param ytTransferable True to deploy the yield token transferable; false makes it soulbound.
  ///        Immutable switch on the YT clone; tiers with an allow list reject true.
  /// @param stakingWeeks Lock length in weeks for a time-locked stake; must be zero when permanent.
  /// @param salt Caller-chosen salt deriving the clone's deterministic address. Hashed together
  ///        with the caller, so another account cannot occupy it; reusing a (caller, salt) pair on
  ///        the same tier reverts.
  /// @param config Relay configuration; its `tokenId` is overwritten with the freshly minted sAERO.
  ///        Its `entrypointTimelock` delays every timelocked change on the Relay, rake raises included.
  struct CreateParams {
    address admin;
    address keeper;
    address voter;
    address compounder;
    address converter;
    address bootstrapOwner;
    address rewardToken;
    address entrypointVetoer;
    address rakeManagerAdmin;
    uint256 protocolRakePips;
    uint256 allocatorRakePips;
    uint128 seedAmount;
    bool isPermanent;
    bool ytTransferable;
    uint48 stakingWeeks;
    bytes32 salt;
    IRelay.RelayConfig config;
  }

  /// @notice The entrypoints a Relay was created with.
  /// @param compounder Entrypoint granted COMPOUNDER at creation, or zero.
  /// @param converter Entrypoint granted CONVERTER at creation, or zero.
  struct InitialEntrypoints {
    address compounder;
    address converter;
  }

  /// @notice Emitted when a Relay is created.
  /// @param relay The deployed Relay address.
  /// @param tokenId The sAERO minted and bound to the Relay.
  /// @param relayType The tier of the created Relay.
  /// @param compounder Entrypoint granted COMPOUNDER at creation, or zero.
  /// @param converter Entrypoint granted CONVERTER at creation, or zero.
  event RelayCreated(
    address indexed relay, uint256 indexed tokenId, IRelay.RelayType relayType, address compounder, address converter
  );

  /// @notice Emitted when the rake treasury changes.
  /// @param treasury Address every Relay's protocol fees are collected to from here on.
  event RakeTreasurySet(address indexed treasury);

  /// @notice Emitted when the relay tape and its call gas limit are set.
  /// @param tape The tape observations are relayed to, or zero to stop recording.
  /// @param gasLimit Gas forwarded to each tape call.
  event RelayTapeSet(address indexed tape, uint32 gasLimit);

  /// @notice Thrown when a zero address is supplied for a protocol dependency.
  error ZeroAddress();

  /// @notice Thrown when the caller lacks the Voter role the call requires.
  error NotAuthorized();

  /// @notice Thrown when a tier implementation address holds no code, which would clone an inert
  ///         Relay and strand the seed sAERO transferred to its predicted address.
  error ImplementationNotAContract();

  /// @notice Thrown when a created Relay comes out of `initialize` with no satellite tokens, the
  ///         signature of a clone whose body never ran.
  error RelayInitializationFailed();

  /// @notice Thrown when a named entrypoint is bound to a different Relay.
  error EntrypointNotBound();

  /// @notice Thrown when the relay tape gas limit is set to zero.
  error ZeroGasLimit();

  /// @notice Thrown when the gas left cannot cover the configured tape call.
  error InsufficientGasForCall();

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

  /// @notice Sets the rake treasury. Restricted to GOVERNANCE_ROLE on the Voter.
  /// @param _treasury Non-zero address every Relay's protocol fees are collected to.
  function setRakeTreasury(address _treasury) external;

  /// @notice Relays a reward distribution to the tape, fail-open towards the tape.
  /// @dev Callable by anything, effectful only for relays this factory created: anything else
  ///      returns silently, as does an unset tape. The tape call is capped at the configured gas and
  ///      its revert is swallowed, so a broken tape can never block the distribution that reports it.
  ///      Too little gas for that call is the one failure that does reach the reporter, so a starved
  ///      transaction reverts rather than recording nothing in silence, which is what lets an
  ///      estimator price a recording operation. That holds as long as the configured gas exceeds
  ///      what a record costs by the 63/64 the call forwards: under a limit sized too tightly, a
  ///      record that runs out is swallowed like any other tape failure. The values travel with the
  ///      report because the reporter holds them exact at the moment of truth, sparing the tape every
  ///      read back into the relay.
  /// @param _token The reward token distributed.
  /// @param _distributed The amount distributed to holders, post rake.
  /// @param _index The relay's per-share index after the advance.
  function recordRewardTape(address _token, uint256 _distributed, uint256 _index) external;

  /// @notice Relays a compound to the tape, fail-open towards the tape.
  /// @dev Same contract as `recordRewardTape`.
  /// @param _net The amount staked into backing, post rake.
  /// @param _backing The relay's backing after the compound lands.
  /// @param _supply The principal supply that backing prices against.
  function recordBackingTape(uint256 _net, uint256 _backing, uint256 _supply) external;

  /// @notice Sets the relay tape and the gas forwarded to each tape call.
  /// @dev Zero tape stops recording; the gas limit must stay nonzero so a set tape is never starved.
  ///      With a tape set, the limit is a floor every compound and notify has to clear, so one set
  ///      beyond what a transaction can carry halts those flows on every relay of this factory until
  ///      governance lowers it again.
  /// @param _relayTape The tape to relay observations to, or zero to stop recording.
  /// @param _gasLimit Gas forwarded to each tape call.
  function setRelayTape(address _relayTape, uint32 _gasLimit) external;

  /// @notice The address a Relay will be created at.
  /// @param _deployer Account that will call the create function.
  /// @param _salt Salt it will pass in `CreateParams`.
  /// @param _relayType Tier it will create; both Protocol types share one implementation.
  /// @return _relay The predicted Relay address.
  /// @dev Entrypoints of a Maxi or L1 Relay are deployed against this address before the Relay exists.
  function predictRelay(
    address _deployer,
    bytes32 _salt,
    IRelay.RelayType _relayType
  ) external view returns (address _relay);

  /// @notice Whether an address is a Relay this factory created.
  /// @param _relay Address to check.
  /// @return _created True when this factory created `_relay`.
  /// @dev The membership check for consumers that gate a privileged path on being a Relay (the
  ///      MetaRouter reads it). Answers in one storage read. Because creation is role-gated, a true
  ///      answer means an authorized deployer created it.
  function isRelay(address _relay) external view returns (bool _created);

  /// @notice The entrypoints a Relay this factory created was initialized with.
  /// @param _relay Relay to read.
  /// @return _compounder Entrypoint granted COMPOUNDER at creation, or zero.
  /// @return _converter Entrypoint granted CONVERTER at creation, or zero.
  /// @dev A Maxi Relay can never change them, so for it this is the current pair. A Protocol Relay
  ///      can change them once it is L2, so read its roles for the current ones.
  function initialEntrypoints(address _relay) external view returns (address _compounder, address _converter);

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

  /// @notice Recipient of every Relay's protocol fees.
  /// @return _treasury The rake treasury address.
  function rakeTreasury() external view returns (address _treasury);

  /// @notice The tape observations are relayed to, or zero when recording is off.
  /// @return _tape The configured relay tape.
  function relayTape() external view returns (address _tape);

  /// @notice Gas forwarded to each tape call.
  /// @return _gasLimit The configured per-call gas.
  function relayTapeGasLimit() external view returns (uint32 _gasLimit);
}
