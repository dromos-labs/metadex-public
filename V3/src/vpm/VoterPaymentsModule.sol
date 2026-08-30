// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {AccessControlEnumerable} from '@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';
import {Math} from '@openzeppelin/contracts/utils/math/Math.sol';

import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IVoterPaymentsModule} from 'V3/interfaces/vpm/IVoterPaymentsModule.sol';

import {GuardedAccessControlEnumerable} from 'V3/access/GuardedAccessControlEnumerable.sol';

/// @title VoterPaymentsModule
/// @notice A VoterPaymentsModule implementation: deployed standalone and granted VPM_ROLE on the VotingEscrow to call
///         `rebalanceUnderlying`. It mediates stake moves between sAEROs (`depositIntoNFT` / `withdrawToNFT`) and charges per-operation
///         protocol fees into the tokenId-0 accumulator. VotingEscrow mirrors every move onto the Voter's chain0
///         ledger internally on `rebalanceUnderlying`; the VPM only talks to VotingEscrow. Fee rates and restricted
///         mode are gated behind the FEE_MANAGER role, which is administered by FEE_MANAGER_ADMIN_ROLE.
contract VoterPaymentsModule is GuardedAccessControlEnumerable, ReentrancyGuardTransient, IVoterPaymentsModule {
  using SafeCastLibrary for uint256;

  /*//////////////////////////////////////////////////////////////
                                CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  bytes32 public constant FEE_MANAGER = keccak256('FEE_MANAGER');

  /// @inheritdoc IVoterPaymentsModule
  bytes32 public constant FEE_MANAGER_ADMIN_ROLE = keccak256('FEE_MANAGER_ADMIN_ROLE');

  /// @inheritdoc IVoterPaymentsModule
  /// @dev A VE tokenId, not a chain identifier; it happens to be 0.
  uint256 public constant FEE_ACCUMULATOR_ID = 0;

  /// @notice Sentinel destination id requesting VE to mint a fresh sAERO instead of crediting an
  ///         existing tokenId. Resolved to the assigned id after `rebalanceUnderlying`.
  uint256 internal constant _MINT_SENTINEL = type(uint256).max;

  /*//////////////////////////////////////////////////////////////
                               IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  IVotingEscrow public immutable VOTING_ESCROW;

  /*//////////////////////////////////////////////////////////////
                                 STORAGE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  mapping(bytes4 _sig => mapping(address _caller => CallerInfo _info)) public fees;

  /// @inheritdoc IVoterPaymentsModule
  mapping(bytes4 _sig => bool _restricted) public restricted;

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initialize the module with its VE and the fee-manager admin.
  /// @param _ve Address of the VotingEscrow. Not type-checked; the VE/VPM pair is mutually referential, so
  ///        each side trusts the deployer to wire the counterparty correctly.
  /// @param _feeManagerAdmin Address granted FEE_MANAGER_ADMIN_ROLE.
  constructor(address _ve, address _feeManagerAdmin) {
    if (_ve == address(0) || _feeManagerAdmin == address(0)) revert ZeroAddress();

    VOTING_ESCROW = IVotingEscrow(_ve);

    // FEE_MANAGER is gated by its own admin role, which is self-administering (admin of itself), so the
    // seeded admin can rotate membership without a higher authority.
    _setRoleAdmin({role: FEE_MANAGER, adminRole: FEE_MANAGER_ADMIN_ROLE});
    _setRoleAdmin({role: FEE_MANAGER_ADMIN_ROLE, adminRole: FEE_MANAGER_ADMIN_ROLE});

    // Seed the admin role with its initial holder.
    _grantRole({role: FEE_MANAGER_ADMIN_ROLE, account: _feeManagerAdmin});
  }

  /*//////////////////////////////////////////////////////////////
                           FEE / ROLE ADMIN
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  function setFee(bytes4 _sig, address _caller, uint128 _rateInPips) external onlyRole(FEE_MANAGER) {
    if (_rateInPips > MAX_PIPS) revert InvalidFeeRate();

    CallerInfo memory _existing = fees[_sig][_caller];
    if (_existing.registered && _existing.rateInPips == _rateInPips) return;

    // Every written record is registered; the flag only distinguishes a stored entry from an absent (zero) one.
    CallerInfo memory _entry = CallerInfo({registered: true, rateInPips: _rateInPips});

    // Update the fee record.
    fees[_sig][_caller] = _entry;

    emit FeeSet(_sig, _caller, _entry);
  }

  /// @inheritdoc IVoterPaymentsModule
  function setRestricted(bytes4 _sig, bool _value) external onlyRole(FEE_MANAGER) {
    if (restricted[_sig] == _value) return;

    restricted[_sig] = _value;

    emit RestrictedSet(_sig, _value);
  }

  /// @inheritdoc IVoterPaymentsModule
  function removeFee(bytes4 _sig, address _caller) external onlyRole(FEE_MANAGER) {
    // The default entry is the fallback every caller resolves against, so it can never be removed.
    if (_caller == address(0)) revert CannotRemoveDefault();

    // The caller must have a registered entry.
    if (!fees[_sig][_caller].registered) revert NotRegistered();

    // Delete the fee record.
    delete fees[_sig][_caller];

    emit FeeRemoved(_sig, _caller);
  }

  /*//////////////////////////////////////////////////////////////
                       USER-FACING OPERATIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  function depositIntoNFT(
    IVotingEscrow.SourceDelta[] calldata _sources,
    uint256 _destinationId,
    address _recipient
  ) external nonReentrant returns (uint256[] memory _mintedIds) {
    uint256 _sourcesLength = _sources.length;
    if (_sourcesLength == 0) revert NoSources();

    // Sum the stake being pulled in.
    uint256 _totalIn = 0;
    for (uint256 _i; _i < _sourcesLength; ++_i) {
      IVotingEscrow.SourceDelta calldata _source = _sources[_i];
      _requireSourceAuth(_source.tokenId);
      _totalIn += _source.amount;
    }

    // Take the protocol fee off the top of the moved total.
    uint256 _fee = _protocolFee({_sig: IVoterPaymentsModule.depositIntoNFT.selector, _amount: _totalIn});

    // Refuse minting a brand-new NFT with a zero net stake. The accumulator (tokenId 0) is exempt:
    // routing the full amount there is the intended burn path.
    if (_destinationId == _MINT_SENTINEL && _totalIn == _fee) revert ZeroMintAmount();

    // Build the destinations: the net amount to the destination, plus the protocol fee leg into the accumulator
    // only when a fee is actually charged. A zero-amount fee leg would route a no-op accumulate through VE (a
    // redundant tokenId-0 SSTORE and checkpoint walk), so the array is sized to drop it when `_fee == 0`.
    IVotingEscrow.DestinationDelta[] memory _destinations = new IVotingEscrow.DestinationDelta[](_fee > 0 ? 2 : 1);
    _destinations[0] = IVotingEscrow.DestinationDelta({
      tokenId: _destinationId,
      amount: (_totalIn - _fee).toUint128(),
      recipient: _destinationId == _MINT_SENTINEL ? _recipient : address(0)
    });
    if (_fee > 0) {
      _destinations[1] =
        IVotingEscrow.DestinationDelta({tokenId: FEE_ACCUMULATOR_ID, amount: _fee.toUint128(), recipient: address(0)});
    }

    // Deposit the sources into the destination; VE mirrors the moves onto the Voter's chain0 ledger internally.
    _mintedIds = VOTING_ESCROW.rebalanceUnderlying({_sources: _sources, _destinations: _destinations});

    // Resolve the mint sentinel to the assigned id for the event.
    uint256 _resolvedDestinationId = _destinationId == _MINT_SENTINEL ? _mintedIds[0] : _destinationId;

    emit DepositedIntoNFT(msg.sender, _sources, _resolvedDestinationId, _totalIn, _fee);
  }

  /// @inheritdoc IVoterPaymentsModule
  function withdrawToNFT(
    uint256 _sourceId,
    IVotingEscrow.DestinationDelta[] calldata _destinations
  ) external nonReentrant returns (uint256[] memory _mintedIds) {
    uint256 _destinationsLength = _destinations.length;
    if (_destinationsLength == 0) revert NoDestinations();

    _requireSourceAuth(_sourceId);

    // Sum the total amount being pulled out of the source.
    uint256 _totalOut = 0;
    for (uint256 _i; _i < _destinationsLength; ++_i) {
      IVotingEscrow.DestinationDelta calldata _destination = _destinations[_i];
      // Only the mint destination may have a recipient.
      // Check all destinations, including zero-amount ones removed by the fee trim.
      if (_destination.tokenId != _MINT_SENTINEL && _destination.recipient != address(0)) {
        revert IVotingEscrow.NonMintRecipientNotAllowed(_destination.tokenId);
      }
      _totalOut += _destination.amount;
    }
    // Refuse withdrawing a zero amount.
    if (_totalOut == 0) revert ZeroWithdraw();

    // Take the nominal protocol fee off the top; `_net` is the amount distributed across the destinations.
    uint256 _net = _totalOut - _protocolFee({_sig: IVoterPaymentsModule.withdrawToNFT.selector, _amount: _totalOut});

    // Build the source leg: the source id holding the full withdrawn total.
    IVotingEscrow.SourceDelta[] memory _sources = new IVotingEscrow.SourceDelta[](1);
    _sources[0] = IVotingEscrow.SourceDelta({tokenId: _sourceId, amount: _totalOut.toUint128()});

    // Trim each destination proportionally to `_net / _totalOut`, counting those with a nonzero trim.
    uint256 _trimmedSum = 0;
    uint256 _nonZeroDestinationCount = 0;
    for (uint256 _i; _i < _destinationsLength; ++_i) {
      uint256 _trimmed = (_destinations[_i].amount * _net) / _totalOut;
      _trimmedSum += _trimmed;
      if (_trimmed > 0) ++_nonZeroDestinationCount;
    }

    // Reject a withdrawal where every destination trims to zero.
    if (_nonZeroDestinationCount == 0) revert AllDestinationsTrimmedToZero();

    // Everything not routed to a nonzero destination is the protocol fee.
    uint256 _fee = _totalOut - _trimmedSum;
    bool _hasFee = _fee > 0;

    // Size the array to the nonzero destinations plus the optional fee leg; zero-trimmed destinations are dropped.
    IVotingEscrow.DestinationDelta[] memory _finalDest =
      new IVotingEscrow.DestinationDelta[](_nonZeroDestinationCount + (_hasFee ? 1 : 0));
    uint256 _writeIndex = 0;
    for (uint256 _i; _i < _destinationsLength; ++_i) {
      IVotingEscrow.DestinationDelta calldata _destination = _destinations[_i];
      uint256 _trimmed = (_destination.amount * _net) / _totalOut;
      if (_trimmed == 0) continue;
      _finalDest[_writeIndex++] = IVotingEscrow.DestinationDelta({
        tokenId: _destination.tokenId,
        amount: _trimmed.toUint128(),
        recipient: _destination.tokenId == _MINT_SENTINEL ? _destination.recipient : address(0)
      });
    }
    if (_hasFee) {
      // Append the dust as the protocol fee leg in the trailing slot.
      _finalDest[_writeIndex] =
        IVotingEscrow.DestinationDelta({tokenId: FEE_ACCUMULATOR_ID, amount: _fee.toUint128(), recipient: address(0)});
    }

    // Withdraw the source token to the destinations; VE mirrors the moves onto the Voter's chain0 ledger internally.
    _mintedIds = VOTING_ESCROW.rebalanceUnderlying({_sources: _sources, _destinations: _finalDest});

    emit WithdrawnToNFT(msg.sender, _sourceId, _destinations, _totalOut, _fee);
  }

  /*//////////////////////////////////////////////////////////////
                              STATE GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoterPaymentsModule
  function getFee(bytes4 _sig, address _caller) external view returns (uint128 _rateInPips) {
    return _effectiveRate({_sig: _sig, _caller: _caller});
  }

  /*//////////////////////////////////////////////////////////////
                              ERC-165
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc AccessControlEnumerable
  function supportsInterface(bytes4 _interfaceId)
    public
    view
    override(AccessControlEnumerable, IERC165)
    returns (bool _supported)
  {
    return _interfaceId == type(IVoterPaymentsModule).interfaceId || super.supportsInterface(_interfaceId);
  }

  /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
  //////////////////////////////////////////////////////////////*/

  /// @notice Source authorization: the caller must pass `VOTING_ESCROW.isAuthorized` for `_tokenId`.
  /// @param _tokenId Source tokenId being authorized.
  function _requireSourceAuth(uint256 _tokenId) internal view {
    if (!VOTING_ESCROW.isAuthorized({_spender: msg.sender, _tokenId: _tokenId})) {
      revert NotApprovedByOwner(_tokenId);
    }
  }

  /// @notice Resolve the effective rate for `_caller` against `_sig`.
  /// @dev Reverts NotRegistered when the operation is restricted and the caller has no registered entry.
  /// @param _sig Operation selector.
  /// @param _caller Caller whose effective rate is being computed.
  /// @return _rateInPips Effective rate the caller pays for the operation.
  function _effectiveRate(bytes4 _sig, address _caller) internal view returns (uint128 _rateInPips) {
    CallerInfo memory _info = fees[_sig][_caller];
    uint128 _defaultRate = fees[_sig][address(0)].rateInPips;

    // A registered caller pays the lesser of their negotiated rate and the default; the default is a
    // protocol-wide ceiling a caller can only come in under, never above.
    if (_info.registered) {
      return uint128(Math.min({a: _defaultRate, b: _info.rateInPips}));
    }

    // An unregistered caller is rejected when the operation is restricted, otherwise falls back to the default.
    if (restricted[_sig]) revert NotRegistered();

    return _defaultRate;
  }

  /// @notice Compute the protocol fee taken off the top of `_amount` for `_sig` and the current caller.
  /// @param _sig Operation selector whose effective rate applies.
  /// @param _amount Gross amount the fee is taken from.
  /// @return _fee Protocol fee, `(_amount * effectiveRate) / MAX_PIPS`.
  function _protocolFee(bytes4 _sig, uint256 _amount) internal view returns (uint256 _fee) {
    return (_amount * _effectiveRate({_sig: _sig, _caller: msg.sender})) / MAX_PIPS;
  }
}
