// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {IGuardedAccessControlEnumerable} from 'V3/interfaces/access/IGuardedAccessControlEnumerable.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';

/// @title VoterPaymentsModule interface
/// @notice Full surface of a VoterPaymentsModule: the user-facing operations VotingEscrow gates on, plus the fee map,
///         restricted map, role management, and admin entry points. Implementations advertise this interface via
///         ERC-165 and are granted VPM_ROLE on the VotingEscrow to be authorized.
interface IVoterPaymentsModule is IERC165, IGuardedAccessControlEnumerable {
  /*//////////////////////////////////////////////////////////////
                                 STRUCTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-caller fee record for a given operation signature.
  /// @param registered Always true for a written record; distinguishes a stored entry from an absent (zero) one.
  /// @param rateInPips Caller's rate in pips. Honored only when `registered` is true and the value is
  ///                   below the default rate stored at `fees[sig][address(0)]`.
  struct CallerInfo {
    bool registered;
    uint128 rateInPips;
  }

  /*//////////////////////////////////////////////////////////////
                                 EVENTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Emitted at the end of `depositIntoNFT`.
  /// @param caller Address that invoked the operation.
  /// @param sources Source deltas submitted to VE.
  /// @param destinationId Resolved destination token id (mint sentinels replaced by the assigned id).
  /// @param totalIn Sum of source amounts before fee.
  /// @param fee Amount routed to the protocol accumulator.
  event DepositedIntoNFT(
    address indexed caller,
    IVotingEscrow.SourceDelta[] sources,
    uint256 indexed destinationId,
    uint256 totalIn,
    uint256 fee
  );

  /// @notice Emitted at the end of `withdrawToNFT`.
  /// @param caller Address that invoked the operation.
  /// @param sourceId Source token id whose stake was reduced.
  /// @param destinations Destination deltas as supplied by the caller (before fee trim).
  /// @param totalOut Sum of caller-supplied destination amounts.
  /// @param fee Amount routed to the protocol accumulator.
  event WithdrawnToNFT(
    address indexed caller,
    uint256 indexed sourceId,
    IVotingEscrow.DestinationDelta[] destinations,
    uint256 totalOut,
    uint256 fee
  );

  /// @notice Emitted whenever a fee record is written via `setFee`.
  /// @param sig Operation selector that the entry applies to.
  /// @param caller Address whose record was updated. address(0) is the default slot.
  /// @param info Stored CallerInfo built from the supplied rate; `registered` is always true for a written record.
  event FeeSet(bytes4 indexed sig, address indexed caller, CallerInfo info);

  /// @notice Emitted when a caller's fee record is cleared via `removeFee`.
  /// @param sig Operation selector whose record was cleared.
  /// @param caller Address whose record was removed.
  event FeeRemoved(bytes4 indexed sig, address indexed caller);

  /// @notice Emitted whenever the restricted mode of an operation is toggled via `setRestricted`.
  /// @param sig Operation selector that was toggled.
  /// @param value New value of the restricted flag.
  event RestrictedSet(bytes4 indexed sig, bool value);

  /*//////////////////////////////////////////////////////////////
                                 ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when a constructor argument is the zero address.
  error ZeroAddress();

  /// @notice Thrown when the caller is not authorized over a source tokenId.
  /// @param tokenId Token id whose authorization check failed.
  error NotApprovedByOwner(uint256 tokenId);

  /// @notice Thrown when `depositIntoNFT` is called with an empty sources array.
  error NoSources();

  /// @notice Thrown when `withdrawToNFT` is called with an empty destinations array.
  error NoDestinations();

  /// @notice Thrown when `withdrawToNFT` is called with destination amounts summing to zero.
  error ZeroWithdraw();

  /// @notice Thrown when `withdrawToNFT` has a nonzero total but every destination trims to zero.
  error AllDestinationsTrimmedToZero();

  /// @notice Thrown when `setFee` is called with a rate higher than `MAX_PIPS` (100%).
  error InvalidFeeRate();

  /// @notice Thrown when an operation is restricted and the caller is not registered.
  error NotRegistered();

  /// @notice Thrown when `removeFee` targets the default slot (address(0)), which is managed only via `setFee`.
  error CannotRemoveDefault();

  /// @notice Thrown when a `depositIntoNFT` mint-sentinel destination would mint a zero-stake NFT.
  error ZeroMintAmount();

  /*//////////////////////////////////////////////////////////////
                       USER-FACING OPERATIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Move staking weight from one or more source sAEROs into a destination sAERO.
  /// @dev A zero-amount source is skipped on the Voter chain0 mirror, but VE still folds its unlock into the
  ///      source-end check: a zero-amount permanent source forces `type(uint48).max` and reverts `UnlockTimeReduction`
  ///      against any non-permanent destination, so it is not a universal no-op.
  /// @dev Every source must have voted at least once and hold at least its delta amount idle on chain0,
  ///      or the Voter reverts `InsufficientChain0Allocation`. Vote or reset the source first.
  /// @param _sources Per-source deltas describing the amount taken from each source tokenId.
  /// @param _destinationId Destination tokenId, or type(uint256).max to mint a fresh sAERO to _recipient.
  /// @param _recipient Owner of the freshly minted sAERO when _destinationId is the mint sentinel; ignored otherwise.
  /// @return _mintedIds Token ids assigned by VE for each mint sentinel resolved during the call.
  function depositIntoNFT(
    IVotingEscrow.SourceDelta[] calldata _sources,
    uint256 _destinationId,
    address _recipient
  ) external returns (uint256[] memory _mintedIds);

  /// @notice Move staking weight from a single source sAERO into one or more destinations.
  /// @dev The source must have voted at least once and hold at least the total withdrawn amount idle on
  ///      chain0, or the Voter reverts `InsufficientChain0Allocation`. Vote or reset the source first.
  /// @dev A destination equal to the source is not rejected: its source and destination legs net out on both VE
  ///      and the Voter's chain0 ledger, leaving only the fee leg as a real move; a trim that rounds to zero is a
  ///      no-op whose amount falls into the fee leg. Either way the caller burns gas (and the fee) for no net change.
  /// @dev Only a mint leg (`tokenId == type(uint256).max`) may carry a nonzero `recipient`; every other destination
  ///      must leave it zero, or the call reverts `IVotingEscrow.NonMintRecipientNotAllowed`. This keeps the emitted
  ///      `WithdrawnToNFT` destinations canonical, mirroring the guard `rebalanceUnderlying` already enforces.
  /// @param _sourceId Source tokenId from which weight is removed.
  /// @param _destinations Per-destination deltas, including any caller-supplied accumulator entries.
  /// @return _mintedIds Token ids assigned by VE for each mint sentinel resolved during the call.
  function withdrawToNFT(
    uint256 _sourceId,
    IVotingEscrow.DestinationDelta[] calldata _destinations
  ) external returns (uint256[] memory _mintedIds);

  /*//////////////////////////////////////////////////////////////
                            FEE / ROLE ADMIN
  //////////////////////////////////////////////////////////////*/

  /// @notice Write a fee record for an operation.
  /// @dev Stores `{registered: true, rateInPips: _rateInPips}`; reverts `InvalidFeeRate` when `_rateInPips > MAX_PIPS`.
  /// @param _sig Operation selector that the record applies to.
  /// @param _caller Caller address whose record is updated. address(0) targets the operation default.
  /// @param _rateInPips Rate in pips to store for the caller.
  function setFee(bytes4 _sig, address _caller, uint128 _rateInPips) external;

  /// @notice Toggle whether unregistered callers can initiate an operation.
  /// @param _sig Operation selector whose restricted flag is updated.
  /// @param _value New value of the flag.
  function setRestricted(bytes4 _sig, bool _value) external;

  /// @notice Clear a caller's fee record for an operation, dropping the caller back to the default rate.
  /// @dev Fee-override cleanup only, not an access lever. Reverts `CannotRemoveDefault` for the default
  ///      slot (address(0)) and `NotRegistered` when there is no record; succeeds regardless of the
  ///      operation's restricted flag.
  /// @param _sig Operation selector whose record is cleared.
  /// @param _caller Caller address whose record is removed.
  function removeFee(bytes4 _sig, address _caller) external;

  /*//////////////////////////////////////////////////////////////
                                CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @notice Role required to write the fee map and toggle restricted mode.
  function FEE_MANAGER() external view returns (bytes32 _role);

  /// @notice Role-admin for FEE_MANAGER.
  function FEE_MANAGER_ADMIN_ROLE() external view returns (bytes32 _role);

  /// @notice VE tokenId of the protocol-owned accumulator that collects fees on the chain0 ledger.
  function FEE_ACCUMULATOR_ID() external view returns (uint256 _tokenId);

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @notice Voting escrow this VPM mediates.
  function VOTING_ESCROW() external view returns (IVotingEscrow _votingEscrow);

  /*//////////////////////////////////////////////////////////////
                              STATE GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @notice Per-operation, per-caller fee record.
  /// @param _sig Operation selector.
  /// @param _caller Caller address. address(0) is the default slot.
  /// @return _registered True if the caller has a stored record.
  /// @return _rateInPips Caller's stored rate.
  function fees(bytes4 _sig, address _caller) external view returns (bool _registered, uint128 _rateInPips);

  /// @notice Per-operation restricted flag. When true, only registered callers can initiate the operation.
  /// @param _sig Operation selector.
  /// @return _restricted Current value of the flag.
  function restricted(bytes4 _sig) external view returns (bool _restricted);

  /// @notice Resolve the effective rate a caller would pay for an operation.
  /// @dev Reverts with NotRegistered when the operation is restricted and the caller is not registered.
  /// @param _sig Operation selector.
  /// @param _caller Caller address.
  /// @return _rateInPips Effective rate the caller would be charged.
  function getFee(bytes4 _sig, address _caller) external view returns (uint128 _rateInPips);
}
