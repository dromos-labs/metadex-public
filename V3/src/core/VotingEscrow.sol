// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {AccessControlEnumerable} from '@openzeppelin/contracts/access/extensions/AccessControlEnumerable.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {ERC721} from '@openzeppelin/contracts/token/ERC721/ERC721.sol';
import {ERC721Enumerable} from '@openzeppelin/contracts/token/ERC721/extensions/ERC721Enumerable.sol';
import {ReentrancyGuardTransient} from '@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol';
import {EIP712} from '@openzeppelin/contracts/utils/cryptography/EIP712.sol';

import {IERC5267} from '@openzeppelin/contracts/interfaces/IERC5267.sol';
import {IERC6372} from '@openzeppelin/contracts/interfaces/IERC6372.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC721Metadata} from '@openzeppelin/contracts/token/ERC721/extensions/IERC721Metadata.sol';
import {IERC165} from '@openzeppelin/contracts/utils/introspection/IERC165.sol';

import {BalanceLogicLibrary} from 'V3/libraries/BalanceLogicLibrary.sol';
import {CheckpointLogicLibrary} from 'V3/libraries/CheckpointLogicLibrary.sol';
import {DelegationLogicLibrary} from 'V3/libraries/DelegationLogicLibrary.sol';
import {MAXTIME, WEEK} from 'V3/libraries/ProtocolConstants.sol';
import {SafeCastLibrary} from 'V3/libraries/SafeCastLibrary.sol';

import {IVeArtProxy} from 'V3/interfaces/art/IVeArtProxy.sol';
import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IToken} from 'V3/interfaces/token/IToken.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

import {GuardedAccessControlEnumerable} from 'V3/access/GuardedAccessControlEnumerable.sol';

/// @title Voting Escrow V3
/// @notice sAERO implementation that escrows ERC-20 tokens in the form of an ERC-721 NFT
/// @notice Votes have a weight depending on time, so that users are committed to the future of (whatever they are voting for)
/// @author Modified from Solidly (https://github.com/solidlyexchange/solidly/blob/master/contracts/ve.sol)
/// @author Modified from Curve (https://github.com/curvefi/curve-dao-contracts/blob/master/contracts/VotingEscrow.vy)
/// @author velodrome.finance, Solidly, @figs999, @pegahcarter, Wonderland
/// @dev Staking weight decays linearly over time. Staking period cannot be more than `_MAXTIME` (4 years).
contract VotingEscrow is
  ERC721Enumerable,
  GuardedAccessControlEnumerable,
  ReentrancyGuardTransient,
  EIP712,
  IVotingEscrow
{
  using SafeERC20 for IToken;
  using SafeCastLibrary for uint256;

  /*//////////////////////////////////////////////////////////////
                              CONSTANTS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVotingEscrow
  bytes32 public constant VPM_ROLE = keccak256('VPM_ROLE');

  /// @inheritdoc IVotingEscrow
  bytes32 public constant VPM_ADMIN_ROLE = keccak256('VPM_ADMIN_ROLE');

  /// @inheritdoc IVotingEscrow
  bytes32 public constant BURN_FEES_ROLE = keccak256('BURN_FEES_ROLE');

  /// @inheritdoc IVotingEscrow
  bytes32 public constant BURN_FEES_ADMIN_ROLE = keccak256('BURN_FEES_ADMIN_ROLE');

  /// @inheritdoc IVotingEscrow
  bytes32 public constant ART_PROXY_ADMIN_ROLE = keccak256('ART_PROXY_ADMIN_ROLE');

  /// @inheritdoc IVotingEscrow
  string public constant VERSION = '3.0.0';

  /// @inheritdoc IVotingEscrow
  bytes32 public constant DELEGATION_TYPEHASH =
    keccak256('Delegation(uint256 delegator,uint256 delegatee,uint256 nonce,uint256 expiry)');

  /*//////////////////////////////////////////////////////////////
                              IMMUTABLES
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVotingEscrow
  IToken public immutable TOKEN;

  /// @inheritdoc IVotingEscrow
  IVoter public immutable VOTER;

  /*//////////////////////////////////////////////////////////////
                                STORAGE
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVotingEscrow
  address public artProxy;

  /// @inheritdoc IVotingEscrow
  uint256 public tokenId;

  /// @inheritdoc IVotingEscrow
  uint256 public epoch;

  /// @inheritdoc IVotingEscrow
  uint128 public supply;

  /// @inheritdoc IVotingEscrow
  uint128 public permanentStakeBalance;

  /// @inheritdoc IVotingEscrow
  mapping(uint48 _timestamp => int128 _slopeChange) public slopeChanges;

  /// @inheritdoc IVotingEscrow
  mapping(uint256 _tokenId => uint256 _epoch) public userPointEpoch;

  /// @inheritdoc IVotingEscrow
  mapping(uint256 _tokenId => uint48 _numCheckpoints) public numCheckpoints;

  /// @inheritdoc IVotingEscrow
  mapping(address _account => uint256 _nonce) public nonces;

  /// @notice Global checkpoint history indexed by epoch.
  mapping(uint256 _epoch => GlobalPoint _point) internal _pointHistory;

  /// @notice Per-tokenId staked balance (amount, end, isPermanent).
  mapping(uint256 _tokenId => StakedBalance _staked) internal _staked;

  /// @notice Per-tokenId user checkpoint history.
  mapping(uint256 _tokenId => UserPoint[1_000_000_000] _points) internal _userPointHistory;

  /// @inheritdoc IVotingEscrow
  mapping(uint256 _tokenId => uint256 _block) public ownershipChange;

  /// @notice A record of each accounts delegate
  mapping(uint256 _delegator => uint256 _delegatee) private _delegates;

  /// @notice A record of delegated token checkpoints for each tokenId, by index
  mapping(uint256 _tokenId => mapping(uint48 _index => Checkpoint _checkpoint)) private _checkpoints;

  /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  //////////////////////////////////////////////////////////////*/

  /// @notice Initialize the escrow with its contract dependencies and role admins.
  /// @dev Each admin manages only its own role: VPM_ADMIN_ROLE grants and revokes VPM_ROLE, BURN_FEES_ADMIN_ROLE
  ///      grants and revokes BURN_FEES_ROLE, ART_PROXY_ADMIN_ROLE is self-administered. Every address must be
  ///      non-zero (`_requireNonZero`).
  /// @param _contracts Contract dependencies (token, voter, artProxy).
  /// @param _admins Initial holders of the role-admin roles (vpmAdmin, artProxyAdmin, burnFeesAdmin).
  constructor(Contracts memory _contracts, Admins memory _admins) ERC721('sAERO', 'sAERO') EIP712('sAERO', VERSION) {
    TOKEN = IToken(_requireNonZero(_contracts.token));
    VOTER = IVoter(_requireNonZero(_contracts.voter));
    artProxy = _requireNonZero(_contracts.artProxy);

    _pointHistory[0].ts = _blockTimestamp();

    _setRoleAdmin(VPM_ROLE, VPM_ADMIN_ROLE);
    _setRoleAdmin(VPM_ADMIN_ROLE, VPM_ADMIN_ROLE);
    _setRoleAdmin(ART_PROXY_ADMIN_ROLE, ART_PROXY_ADMIN_ROLE);
    _setRoleAdmin(BURN_FEES_ROLE, BURN_FEES_ADMIN_ROLE);
    _setRoleAdmin(BURN_FEES_ADMIN_ROLE, BURN_FEES_ADMIN_ROLE);

    _grantRole(VPM_ADMIN_ROLE, _requireNonZero(_admins.vpmAdmin));
    _grantRole(ART_PROXY_ADMIN_ROLE, _requireNonZero(_admins.artProxyAdmin));
    _grantRole(BURN_FEES_ADMIN_ROLE, _requireNonZero(_admins.burnFeesAdmin));
  }

  /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVotingEscrow
  function setArtProxy(address _proxy) external onlyRole(ART_PROXY_ADMIN_ROLE) {
    if (_proxy == address(0)) _revert(uint32(ZeroAddress.selector));
    if (_proxy == artProxy) return;
    emit ArtProxyUpdated(_proxy);
    artProxy = _proxy;
    emit BatchMetadataUpdate(0, type(uint256).max);
  }

  /// @inheritdoc IVotingEscrow
  function checkpoint() external nonReentrant {
    _checkpoint(
      0, StakedBalance({amount: 0, end: 0, isPermanent: false}), StakedBalance({amount: 0, end: 0, isPermanent: false})
    );
  }

  /// @inheritdoc IVotingEscrow
  function createStake(
    uint128 _value,
    uint48 _stakingWeeks,
    bool _isPermanent
  ) external nonReentrant returns (uint256 _tokenId) {
    uint48 _stakeEnd = _resolveNewStakeEnd(_value, _stakingWeeks, _isPermanent);

    // Mint the next sequential sToken to the caller.
    _tokenId = ++tokenId;
    _mint(msg.sender, _tokenId);

    // Pull in the deposit and record the stake. The freshly minted _tokenId has never been staked, so its
    // StakedBalance slot is known-zero and is passed as a literal rather than read back from storage.
    _depositFor({
      _tokenId: _tokenId,
      _oldStaked: StakedBalance({amount: 0, end: 0, isPermanent: false}),
      _newStaked: StakedBalance({amount: _value, end: _stakeEnd, isPermanent: _isPermanent}),
      _value: _value,
      _depositType: DepositType.CREATE_STAKE_TYPE
    });
  }

  /// @inheritdoc IVotingEscrow
  function reviveStake(
    uint256 _tokenId,
    uint128 _value,
    uint48 _stakingWeeks,
    bool _isPermanent
  ) external nonReentrant {
    // Only an empty shell whose stake is over can be rebuilt: a funded position keeps its committed shape and
    // moves through the increase and upgrade paths instead, and a live or permanent shell keeps its end.
    // No delegatee checkpoint: delegation is permanent-only and every exit from permanence clears it, so an
    // admissible shell is never delegated.
    (, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    uint48 _stakeEnd = _resolveNewStakeEnd(_value, _stakingWeeks, _isPermanent);
    if (_oldStaked.amount != 0) _revert(uint32(StakeAlreadyFunded.selector));
    _requireStakeOver(_oldStaked);

    _depositFor({
      _tokenId: _tokenId,
      _oldStaked: _oldStaked,
      _newStaked: StakedBalance({amount: _value, end: _stakeEnd, isPermanent: _isPermanent}),
      _value: _value,
      _depositType: DepositType.REVIVE_STAKE_TYPE
    });

    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function increaseStakeAmount(uint256 _tokenId, uint128 _value) external nonReentrant {
    // Reject empty top-ups and expired decay stakes.
    (, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    if (_value == 0) _revert(uint32(ZeroAmount.selector));
    if (_oldStaked.end <= block.timestamp && !_oldStaked.isPermanent) _revert(uint32(StakeExpired.selector));

    // Propagate the added weight to the stake's delegatee (a no-op when it has none).
    _checkpointDelegatee(_delegates[_tokenId], _value, true);

    // Pull in the added amount, keeping the existing end and mode.
    _depositFor({
      _tokenId: _tokenId,
      _oldStaked: _oldStaked,
      _newStaked: StakedBalance({
        amount: _oldStaked.amount + _value, end: _oldStaked.end, isPermanent: _oldStaked.isPermanent
      }),
      _value: _value,
      _depositType: DepositType.INCREASE_STAKE_AMOUNT
    });

    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function increaseStakingPeriod(uint256 _tokenId, uint48 _stakingWeeks) external nonReentrant {
    // Permanent stakes have no end to extend, and an empty shell has no period at all: `reviveStake` rebuilds it.
    (, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    if (_oldStaked.isPermanent) _revert(uint32(PermanentStake.selector));
    if (_oldStaked.amount == 0) _revert(uint32(StakeNotFunded.selector));

    // The new end must strictly exceed the later of the current end and now.
    uint48 _minRequired = _oldStaked.end > _blockTimestamp() ? _oldStaked.end : _blockTimestamp();
    uint48 _stakeEnd = _computeStakeEnd(_stakingWeeks, _minRequired);

    // Extend the staking period with no added amount.
    _depositFor({
      _tokenId: _tokenId,
      _oldStaked: _oldStaked,
      _newStaked: StakedBalance({amount: _oldStaked.amount, end: _stakeEnd, isPermanent: false}),
      _value: 0,
      _depositType: DepositType.INCREASE_STAKING_PERIOD
    });

    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function withdraw(uint256 _tokenId, address _recipient) external nonReentrant {
    // Only an expired, non-permanent stake can be withdrawn.
    (address _owner, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    _requireStakeOver(_oldStaked);

    // The whole stake must sit on the Voter's CHAIN0 before it is cleared: voting power still booked on a remote
    // chain has to be returned first (a `DEALLOC_GAUGE` return through the root or leaf `allocateGauges`, or
    // `emergencyDeallocate` for a suspended chain). This keeps root and every leaf agreeing the token holds
    // nothing on their chain.
    _requireFullyOnChain0(_tokenId, _oldStaked.amount);

    // Zero the stake and drop supply by the released amount.
    uint128 _value = _oldStaked.amount;
    uint128 _supplyBefore = supply;
    supply = _supplyBefore - _value;
    _commit(_tokenId, _oldStaked, StakedBalance({amount: 0, end: 0, isPermanent: false}));

    // Drop the Voter's ledger for this token so a later `reviveStake` of the same id starts clean. Weight needs no
    // unwinding: the stake is expired, so it already decayed out of the Voter's points.
    VOTER.clearToken(_tokenId);

    // Release the escrowed TOKEN to the caller-chosen recipient (transfer last for CEI).
    TOKEN.safeTransfer(_recipient, _value);

    emit Withdraw(_owner, _tokenId, _value, block.timestamp);
    emit Supply(_supplyBefore - _value);
    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function upgradeToPermanentStake(uint256 _tokenId) external nonReentrant {
    // Only a funded, non-expired decay stake can become permanent.
    (address _owner, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    if (_oldStaked.isPermanent) _revert(uint32(PermanentStake.selector));
    if (_oldStaked.end <= block.timestamp) _revert(uint32(StakeExpired.selector));

    // Clear the end and flip to permanent; the amount is unchanged.
    _commit(_tokenId, _oldStaked, StakedBalance({amount: _oldStaked.amount, end: 0, isPermanent: true}));

    // Re-anchor the Voter to the permanent shape. The amount is unchanged, so nothing is parked; without this the
    // Voter would keep the stale decaying expiry and reject the token's next gauge vote as `StaleShape`.
    VOTER.parkOnChain0(_tokenId);

    emit UpgradeToPermanentStake(_owner, _tokenId, _oldStaked.amount, block.timestamp);
    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function downgradeFromPermanentStake(uint256 _tokenId) external nonReentrant {
    // Only a permanent stake can be downgraded.
    (address _owner, StakedBalance memory _oldStaked) = _authorizedStake(_tokenId);
    if (!_oldStaked.isPermanent) _revert(uint32(NotPermanentStake.selector));

    // The full balance must sit idle on the Voter's chain0 (no cross-chain allocations remain) before reshaping
    // the stake; the caller deallocates with an empty `Voter.vote` beforehand and re-votes afterwards.
    _requireFullyOnChain0(_tokenId, _oldStaked.amount);

    // Clear delegation (permanent-only), then flip to decay with a fresh max-duration end.
    _delegate(_tokenId, 0);
    uint48 _newEnd = ((_blockTimestamp() + MAXTIME) / WEEK) * WEEK;
    _commit(_tokenId, _oldStaked, StakedBalance({amount: _oldStaked.amount, end: _newEnd, isPermanent: false}));

    // Re-anchor the Voter's chain0 booking from the permanent shape to the new decaying one, so the power starts
    // decaying and the stored shape matches the live stake. Nothing is parked: the balance is already booked.
    VOTER.parkOnChain0(_tokenId);

    emit DowngradeFromPermanentStake(_owner, _tokenId, _oldStaked.amount, block.timestamp);
    emit MetadataUpdate(_tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function rebalanceUnderlying(
    SourceDelta[] calldata _sources,
    DestinationDelta[] calldata _destinations
  ) external nonReentrant returns (uint256[] memory _mintedIds) {
    // Access control: only a VPM_ROLE holder can rebalance.
    if (!_isAuthorizedVPM(msg.sender)) _revert(uint32(NotVoterPaymentsModule.selector));

    uint256 _sourcesLength = _sources.length;

    // The VPM must hold owner authorization (operator or token approval) for every source it drains. Reject the
    // accumulator (tokenId 0) here: it is burn-only and never a source, and its zero owner would otherwise surface a
    // less specific `ERC721NonexistentToken` from the auth check below.
    for (uint256 i; i < _sourcesLength; ++i) {
      if (_sources[i].tokenId == 0) _revert(uint32(AccumulatorCannotBeSource.selector));
      _checkAuthorized(_ownerOf(_sources[i].tokenId), msg.sender, _sources[i].tokenId);
    }

    // Process sources: drain each source, accumulate the total moved, and track the latest source unlock so the
    //    monotonic-unlock rule can be checked against the destinations below.
    uint256 _totalIn = 0;
    uint48 _maxSourceEnd = 0;
    for (uint256 i; i < _sourcesLength; ++i) {
      uint48 _srcEnd = _applySource(_sources[i]);
      if (_srcEnd > _maxSourceEnd) _maxSourceEnd = _srcEnd;
      _totalIn += _sources[i].amount;
      emit MetadataUpdate(_sources[i].tokenId);
    }

    // Pre-count mint destinations so mintedIds can be allocated at the right size in one shot.
    uint256 _destinationsLength = _destinations.length;
    uint256 _mintCount = 0;
    for (uint256 i; i < _destinationsLength; ++i) {
      if (_destinations[i].tokenId == type(uint256).max) ++_mintCount;
    }
    _mintedIds = new uint256[](_mintCount);
    uint256 _mintIdx = 0;

    // Process destinations: route each delta by mode — accumulator (tokenId 0), mint (type(uint256).max), or add
    //    to an existing sToken — accumulate the total moved out, and track the earliest add-destination unlock.
    //    `_resolvedDestinations` mirrors the input legs with the concrete tokenId each one resolved to (mint
    //    sentinels replaced by the assigned id) so the chain0 mirror below credits real tokenIds.
    uint256 _totalOut = 0;
    uint48 _minDestEnd = type(uint48).max;
    DestinationDelta[] memory _resolvedDestinations = new DestinationDelta[](_destinationsLength);
    for (uint256 i; i < _destinationsLength; ++i) {
      DestinationDelta calldata _destination = _destinations[i];
      uint256 _destTokenId = _destination.tokenId;
      _totalOut += _destination.amount;
      // Only a mint leg may carry a recipient; every other leg must leave it zero so events stay canonical.
      if (_destTokenId != type(uint256).max && _destination.recipient != address(0)) {
        revert NonMintRecipientNotAllowed(_destTokenId);
      }
      uint256 _resolvedId;
      if (_destTokenId == 0) {
        // Accumulator: exempt from the unlock rule because the TOKEN is slated for burn.
        _applyDestinationAccumulate(_destination.amount);
        _resolvedId = 0;
      } else if (_destTokenId == type(uint256).max) {
        // Mint: inherits the unlock from the sources, so it satisfies the unlock rule by construction.
        _resolvedId = _applyDestinationMint(_destination, _maxSourceEnd);
        _mintedIds[_mintIdx++] = _resolvedId;
      } else {
        // Add: existing sToken; its unlock must not be earlier than the latest source unlock (checked below).
        uint48 _dstEnd = _applyDestinationAdd(_destination);
        if (_dstEnd < _minDestEnd) _minDestEnd = _dstEnd;
        _resolvedId = _destTokenId;
        emit MetadataUpdate(_destTokenId);
      }
      _resolvedDestinations[i] =
        DestinationDelta({tokenId: _resolvedId, amount: _destination.amount, recipient: _destination.recipient});
    }

    // Invariants: balance conservation and the monotonic-unlock rule across the whole call.
    if (_totalIn != _totalOut) _revert(uint32(BalanceMismatch.selector));
    if (_maxSourceEnd > _minDestEnd) _revert(uint32(UnlockTimeReduction.selector));

    // Mirror the underlying moves onto the Voter's chain0 ledger in a single batched call. Source legs are
    // forwarded as-is; destination legs carry the resolved tokenIds.
    VOTER.rebalanceChain0(_sources, _resolvedDestinations);

    emit Rebalance(_sources, _destinations);
  }

  /// @inheritdoc IVotingEscrow
  function burnFees(uint128 _amount) external nonReentrant onlyRole(BURN_FEES_ROLE) {
    if (_amount == 0) _revert(uint32(ZeroAmount.selector));

    // Cannot burn more than the accumulator holds.
    StakedBalance memory _oldStaked = _staked[0];
    if (_amount > _oldStaked.amount) _revert(uint32(AmountExceedsAccumulator.selector));

    // Drop supply, shrink the accumulator, and destroy the underlying TOKEN.
    uint128 _supplyBefore = supply;
    supply = _supplyBefore - _amount;

    // The tokenId-0 accumulator is a permanent position; `_commit` derives the permanentStakeBalance decrement.
    uint128 _newAmount = _oldStaked.amount - _amount;
    _commit(0, _oldStaked, StakedBalance({amount: _newAmount, end: 0, isPermanent: true}));
    TOKEN.burn(_amount);

    // The accumulator's voting power is always parked on the Voter's chain0; burn it there to stay in sync.
    VOTER.burn(_amount);

    emit Supply(_supplyBefore - _amount);
    emit Burn(_amount);
  }

  /// @inheritdoc IVotingEscrow
  function delegate(uint256 _delegator, uint256 _delegatee) external {
    _checkAuthorized(_ownerOf(_delegator), msg.sender, _delegator);
    return _delegate(_delegator, _delegatee);
  }

  /// @inheritdoc IVotingEscrow
  function delegateBySig(
    uint256 _delegator,
    uint256 _delegatee,
    uint256 _nonce,
    uint256 _expiry,
    uint8 _v,
    bytes32 _r,
    bytes32 _s
  ) external {
    // Reject malleable signatures (upper-half s-values), per EIP-2 / Yellow Paper Appendix F.
    // EIP-2 still allows signature malleability for ecrecover(). Remove this possibility and make the signature
    // unique. Appendix F in the Ethereum Yellow paper (https://ethereum.github.io/yellowpaper/paper.pdf), defines
    // the valid range for s in (301): 0 < s < secp256k1n ÷ 2 + 1, and for v in (302): v ∈ {27, 28}. Most
    // signatures from current libraries generate a unique signature with an s-value in the lower half order.
    //
    // If your library generates malleable signatures, such as s-values in the upper range, calculate a new s-value
    // with 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - s1 and flip v from 27 to 28 or
    // vice versa. If your library also generates signatures with 0/1 for v instead 27/28, add 27 to v to accept
    // these malleable signatures as well.
    if (uint256(_s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) {
      _revert(uint32(InvalidSignatureS.selector));
    }

    // Recover the signatory from the EIP-712 delegation digest.
    bytes32 _structHash = keccak256(abi.encode(DELEGATION_TYPEHASH, _delegator, _delegatee, _nonce, _expiry));
    bytes32 _digest = _hashTypedDataV4(_structHash);
    address _signatory = ecrecover(_digest, _v, _r, _s);
    if (_signatory == address(0)) _revert(uint32(InvalidSignature.selector));

    // Authorize the signatory over the delegator, then enforce nonce and expiry.
    _checkAuthorized(_ownerOf(_delegator), _signatory, _delegator);
    if (_nonce != nonces[_signatory]++) _revert(uint32(InvalidNonce.selector));
    if (block.timestamp > _expiry) _revert(uint32(SignatureExpired.selector));

    // Apply the delegation.
    return _delegate(_delegator, _delegatee);
  }

  /// @inheritdoc IVotingEscrow
  function isAuthorized(address _spender, uint256 _tokenId) external view returns (bool) {
    return _isAuthorized(_ownerOf(_tokenId), _spender, _tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function isAuthorizedVPM(address _account) external view returns (bool _authorized) {
    return _isAuthorizedVPM(_account);
  }

  /// @inheritdoc IVotingEscrow
  function isAuthorizedVPMForToken(address _vpm, uint256 _tokenId) external view returns (bool _authorized) {
    return _isAuthorizedVPM(_vpm) && _isAuthorized(_ownerOf(_tokenId), _vpm, _tokenId);
  }

  /// @inheritdoc IVotingEscrow
  function staked(uint256 _tokenId) external view returns (StakedBalance memory) {
    return _staked[_tokenId];
  }

  /// @inheritdoc IVotingEscrow
  function userPointHistory(uint256 _tokenId, uint256 _loc) external view returns (UserPoint memory) {
    return _userPointHistory[_tokenId][_loc];
  }

  /// @inheritdoc IVotingEscrow
  function pointHistory(uint256 _loc) external view returns (GlobalPoint memory) {
    return _pointHistory[_loc];
  }

  /// @inheritdoc IVotingEscrow
  function balanceOfNFTAt(uint256 _tokenId, uint256 _t) external view returns (uint256) {
    return _balanceOfNFTAt(_tokenId, _t);
  }

  /// @inheritdoc IVotingEscrow
  function totalVotingPower() external view returns (uint256) {
    return _supplyAt(block.timestamp);
  }

  /// @inheritdoc IVotingEscrow
  function totalVotingPowerAt(uint256 _timestamp) external view returns (uint256) {
    return _supplyAt(_timestamp);
  }

  /// @inheritdoc IVotingEscrow
  function delegates(uint256 _delegator) external view returns (uint256) {
    return _delegates[_delegator];
  }

  /// @inheritdoc IVotingEscrow
  function checkpoints(uint256 _tokenId, uint48 _index) external view returns (Checkpoint memory) {
    return _checkpoints[_tokenId][_index];
  }

  /// @inheritdoc IVotingEscrow
  function getPastVotes(address _account, uint256 _tokenId, uint256 _timestamp) external view returns (uint256) {
    return DelegationLogicLibrary.getPastVotes(numCheckpoints, _checkpoints, _account, _tokenId, _timestamp);
  }

  /// @inheritdoc IVotingEscrow
  function getPastTotalSupply(uint256 _timestamp) external view returns (uint256) {
    return _supplyAt(_timestamp);
  }

  /// @inheritdoc IVotingEscrow
  function clock() external view returns (uint48) {
    return _blockTimestamp();
  }

  /// @inheritdoc IVotingEscrow
  function CLOCK_MODE() external pure returns (string memory) {
    return 'mode=timestamp';
  }

  /*//////////////////////////////////////////////////////////////
                             PUBLIC FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVotingEscrow
  /// @dev Public (not external) to resolve the diamond between IVotingEscrow and ERC721Enumerable. Returns the
  ///      live NFT count (`_allTokens.length`); since sAERO is never burned this equals the `tokenId` counter.
  function totalSupply() public view override(ERC721Enumerable, IVotingEscrow) returns (uint256) {
    return super.totalSupply();
  }

  /// @inheritdoc IERC721Metadata
  function tokenURI(uint256 _tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
    _requireOwned(_tokenId);
    return IVeArtProxy(artProxy).tokenURI(_tokenId);
  }

  /// @inheritdoc IERC165
  /// @dev IVotingEscrow, ERC4906, ERC5267 and ERC6372 are advertised on top of the IDs that ERC721Enumerable
  ///      (including IERC721Enumerable) and AccessControlEnumerable already register through `super`.
  function supportsInterface(bytes4 _interfaceID)
    public
    view
    override(ERC721Enumerable, AccessControlEnumerable, IERC165)
    returns (bool)
  {
    return _interfaceID == 0x49064906 // ERC4906
      || _interfaceID == type(IERC5267).interfaceId || _interfaceID == type(IERC6372).interfaceId
      || _interfaceID == type(IVotingEscrow).interfaceId || super.supportsInterface(_interfaceID);
  }

  /// @inheritdoc IVotingEscrow
  function balanceOfNFT(uint256 _tokenId) public view returns (uint256) {
    return _balanceOfNFTAt(_tokenId, block.timestamp);
  }

  /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
  //////////////////////////////////////////////////////////////*/

  /// @notice Hook called by OZ ERC721 on every mint, burn, and transfer.
  /// @dev `super._update` runs ERC721Enumerable's owner/global enumeration bookkeeping; this override then
  ///      updates the ownership-change mapping on transfers and re-checkpoints delegation on every path.
  /// @param _to Recipient of the token (zero on burn).
  /// @param _tokenId tokenId being updated.
  /// @param _auth Address authorized to operate on the token.
  /// @return _from Previous owner of the token (zero on mint).
  function _update(address _to, uint256 _tokenId, address _auth) internal override returns (address _from) {
    // Run the standard ERC721 + enumeration ownership update.
    _from = super._update(_to, _tokenId, _auth);

    // Tag real transfers (not mint/burn) for the same-block guard in `_checkpointDelegator`.
    if (_from != address(0) && _to != address(0)) {
      ownershipChange[_tokenId] = block.number;
    }

    // Record the delegation checkpoint for the new owner.
    _checkpointDelegator(_tokenId, 0, _to);
    return _from;
  }

  /// @notice Record global and per-user data to checkpoints. Used by VotingEscrow system.
  /// @param _tokenId NFT token ID. No user checkpoint if 0
  /// @param _oldStaked Previous staked amount / end timestamp for the user.
  /// @param _newStaked New staked amount / end timestamp for the user.
  function _checkpoint(uint256 _tokenId, StakedBalance memory _oldStaked, StakedBalance memory _newStaked) internal {
    epoch = CheckpointLogicLibrary.checkpoint(
      _pointHistory,
      slopeChanges,
      userPointEpoch,
      _userPointHistory,
      CheckpointLogicLibrary.CheckpointInput({
        epoch: epoch,
        permanentStakeBalance: permanentStakeBalance,
        tokenId: _tokenId,
        oldStaked: _oldStaked,
        newStaked: _newStaked
      })
    );
  }

  /// @notice Apply a deposit transition: bump supply, commit the pre-built `_newStaked`, pull in the tokens, emit.
  /// @dev Shared by createStake / increaseStakeAmount / increaseStakingPeriod. `supply` rises by `_value` here (one
  ///      of the three VE-boundary inbound-flow sites); the transfer runs after the state change (CEI).
  /// @param _tokenId NFT that holds the stake.
  /// @param _oldStaked Previous StakedBalance for `_tokenId`.
  /// @param _newStaked Target StakedBalance to commit.
  /// @param _value Amount of TOKEN deposited (0 for an end-only change); transferred in when non-zero.
  /// @param _depositType The type of deposit, tagged on the Deposit event.
  function _depositFor(
    uint256 _tokenId,
    StakedBalance memory _oldStaked,
    StakedBalance memory _newStaked,
    uint128 _value,
    DepositType _depositType
  ) internal {
    // Update the supply.
    uint128 _supplyBefore = supply;
    supply = _supplyBefore + _value;

    // Commit the pre-built balance, then pull the tokens in.
    _commit(_tokenId, _oldStaked, _newStaked);
    if (_value != 0) {
      TOKEN.safeTransferFrom(msg.sender, address(this), _value);
    }

    // The one place the deposit paths tell the Voter about the new stake: `createStake`, `increaseStakeAmount`
    // and `reviveStake` book the fresh voting power onto `CHAIN0` so it is immediately allocable, while
    // `increaseStakingPeriod` (`_value == 0`) parks nothing and instead re-anchors the token's position to the
    // new shape — which the Voter would otherwise need a separate empty `allocateChains` for.
    VOTER.parkOnChain0(_tokenId);

    emit Deposit(msg.sender, _tokenId, _depositType, _value, _newStaked.end, block.timestamp);
    emit Supply(_supplyBefore + _value);
  }

  /// @notice Sole chokepoint for stake-balance mutations: commit an `_old` → `_new` transition for `_tokenId`.
  /// @dev Enforces the amount cap, keeps `permanentStakeBalance` conserved (derived from the actual permanent
  ///      transition rather than asserted per caller), persists the new balance, and checkpoints. Does NOT touch
  ///      `supply` — that changes only at the VE boundary (`_depositFor`, `withdraw`, `burnFees`), nor does it move
  ///      ERC-20s or emit lifecycle events. The protocol-owned tokenId-0 accumulator is always a permanent
  ///      position; permanence is forced here so the conservation below cannot be desynced by a caller.
  /// @param _tokenId tokenId being mutated (0 for the protocol-owned accumulator).
  /// @param _old Previous StakedBalance for `_tokenId`.
  /// @param _new Target StakedBalance to persist.
  function _commit(uint256 _tokenId, StakedBalance memory _old, StakedBalance memory _new) internal {
    if (_new.amount > uint128(type(int128).max)) _revert(uint32(AmountExceedsCap.selector));

    // The accumulator (tokenId 0) is always permanent.
    if (_tokenId == 0) _new.isPermanent = true;

    // Conserve permanentStakeBalance as the diff of the permanent side of the transition.
    uint128 _oldPermanent = _old.isPermanent ? _old.amount : 0;
    uint128 _newPermanent = _new.isPermanent ? _new.amount : 0;
    permanentStakeBalance = permanentStakeBalance - _oldPermanent + _newPermanent;

    // Persist the new balance and checkpoint.
    _staked[_tokenId] = _new;
    _checkpoint(_tokenId, _old, _new);
  }

  /// @notice Process one source entry of a rebalance: decrement the stake amount, update permanentStakeBalance, checkpoint.
  /// @dev Reverts AmountExceedsStake when the source delta exceeds the staked amount. The accumulator (tokenId 0) is
  ///      burn-only and rejected upstream in `rebalanceUnderlying`, so it never reaches this helper.
  /// @param _s Source delta entry.
  /// @return _srcEnd The source's effective unlock, with permanent stakes treated as type(uint48).max.
  function _applySource(SourceDelta calldata _s) internal returns (uint48 _srcEnd) {
    // Capture the source's effective unlock (permanent counts as the max) and reject over-draining.
    StakedBalance memory _oldStaked = _staked[_s.tokenId];
    _srcEnd = _oldStaked.isPermanent ? type(uint48).max : _oldStaked.end;
    if (_s.amount > _oldStaked.amount) revert AmountExceedsStake(_s.tokenId);

    // Drain the amount, keeping the end and mode; a permanent source releases its delegated weight.
    uint128 _newAmount = _oldStaked.amount - _s.amount;
    StakedBalance memory _newStaked =
      StakedBalance({amount: _newAmount, end: _oldStaked.end, isPermanent: _oldStaked.isPermanent});
    if (_oldStaked.isPermanent) {
      // A permanent source can only feed permanent destinations (the accumulator, an existing permanent stake, or a
      // mint that inherits permanence), each of which adds `_s.amount` back to permanentStakeBalance, so the global
      // permanent balance nets out unchanged. `_commit` derives this stake's matching decrement from the diff.
      _checkpointDelegatee(_delegates[_s.tokenId], _s.amount, false);
    }

    _commit(_s.tokenId, _oldStaked, _newStaked);
  }

  /// @notice Route the moved amount into the protocol-owned accumulator at tokenId zero.
  /// @dev Exempt from the monotonic unlock rule. Stored as a permanent position so `_commit` accounts it in
  ///      `permanentStakeBalance` and enforces the cap; `_checkpoint` only writes the global point for tokenId 0.
  /// @param _amount Amount routed to the accumulator.
  function _applyDestinationAccumulate(uint128 _amount) internal {
    StakedBalance memory _oldStaked = _staked[0];
    uint128 _newAmount = _oldStaked.amount + _amount;
    _commit(0, _oldStaked, StakedBalance({amount: _newAmount, end: 0, isPermanent: true}));
  }

  /// @notice Mint a new sToken that inherits its unlock from the latest source unlock.
  /// @dev Permanent when any source is permanent (maxSourceEnd == type(uint48).max), otherwise decay with end = maxSourceEnd.
  ///      Uses `_mint` (no ERC721 receiver hook) so a VPM can predict the assigned IDs without reentrancy.
  /// @param _d Destination entry. `recipient` is the owner of the freshly minted sToken.
  /// @param _maxSourceEnd Latest source unlock observed during source processing.
  /// @return _newTokenId tokenId assigned to the newly minted sToken.
  function _applyDestinationMint(
    DestinationDelta calldata _d,
    uint48 _maxSourceEnd
  ) internal returns (uint256 _newTokenId) {
    _newTokenId = ++tokenId;

    // Credit the moved amount, inheriting permanence and unlock from the sources, then mint to the recipient.
    bool _newPermanent = _maxSourceEnd == type(uint48).max;
    uint48 _newEnd = _newPermanent ? 0 : _maxSourceEnd;
    _commit(
      _newTokenId,
      StakedBalance({amount: 0, end: 0, isPermanent: false}),
      StakedBalance({amount: _d.amount, end: _newEnd, isPermanent: _newPermanent})
    );
    _mint(_d.recipient, _newTokenId);
  }

  /// @notice Add the moved amount to an existing sToken (permanent or decay).
  /// @dev Reverts ERC721NonexistentToken (via `_requireOwned`) when the destination tokenId has never been minted;
  ///      without the check a VPM could credit a non-existent slot and strand funds.
  /// @param _d Destination entry. `recipient` is ignored for the Add mode.
  /// @return _dstEnd The destination's effective unlock, with permanent stakes treated as type(uint48).max.
  function _applyDestinationAdd(DestinationDelta calldata _d) internal returns (uint48 _dstEnd) {
    // The destination must already exist, else funds would strand on an unminted slot.
    _requireOwned(_d.tokenId);

    // Capture the destination's effective unlock; a permanent destination gains delegated weight.
    StakedBalance memory _oldStaked = _staked[_d.tokenId];
    _dstEnd = _oldStaked.isPermanent ? type(uint48).max : _oldStaked.end;
    if (_oldStaked.isPermanent) {
      _checkpointDelegatee(_delegates[_d.tokenId], _d.amount, true);
    }

    // Credit the moved amount, keeping the end and mode.
    uint128 _newAmount = _oldStaked.amount + _d.amount;
    _commit(
      _d.tokenId,
      _oldStaked,
      StakedBalance({amount: _newAmount, end: _oldStaked.end, isPermanent: _oldStaked.isPermanent})
    );
  }

  /// @notice Record a delegation checkpoint for the delegator side of a delegation change.
  /// @param _delegator tokenId whose delegate is changing.
  /// @param _delegatee New delegatee tokenId.
  /// @param _owner Owner of the delegator tokenId.
  function _checkpointDelegator(uint256 _delegator, uint256 _delegatee, address _owner) internal {
    DelegationLogicLibrary.checkpointDelegator(
      _staked, numCheckpoints, _checkpoints, _delegates, _delegator, _delegatee, _owner
    );
  }

  /// @notice Record a delegation checkpoint for the delegatee side of a delegation change.
  /// @param _delegatee tokenId receiving (or releasing) delegated balance.
  /// @param _balance Balance amount being delegated.
  /// @param _increase True to add, false to subtract from the delegatee balance.
  function _checkpointDelegatee(uint256 _delegatee, uint256 _balance, bool _increase) internal {
    DelegationLogicLibrary.checkpointDelegatee(numCheckpoints, _checkpoints, _delegatee, _balance, _increase);
  }

  /// @notice Record user delegation checkpoints. Used by voting system.
  /// @dev Skips delegation if already delegated to `_delegatee`. Reverts when the delegator is not a permanent stake.
  /// @param _delegator tokenId whose delegate is being updated.
  /// @param _delegatee New delegatee tokenId (0 to clear delegation).
  function _delegate(uint256 _delegator, uint256 _delegatee) internal {
    // Only a permanent stake can delegate; the delegatee must exist and the delegator can't have changed owner
    //    this block. Self-delegation is treated as a clear.
    StakedBalance memory delegateStaked = _staked[_delegator];
    if (!delegateStaked.isPermanent) _revert(uint32(NotPermanentStake.selector));
    if (_delegatee != 0) _requireOwned(_delegatee);
    if (ownershipChange[_delegator] == block.number) _revert(uint32(OwnershipChange.selector));
    if (_delegatee == _delegator) _delegatee = 0;

    // Nothing to do if the delegate is unchanged.
    uint256 currentDelegate = _delegates[_delegator];
    if (currentDelegate == _delegatee) return;

    // Record both sides of the delegation change and emit.
    address _delegatorOwner = _ownerOf(_delegator);
    uint256 delegatedBalance = delegateStaked.amount;
    _checkpointDelegator(_delegator, _delegatee, _delegatorOwner);
    _checkpointDelegatee(_delegatee, delegatedBalance, true);

    emit DelegateChanged(_delegatorOwner, currentDelegate, _delegatee);
  }

  /// @notice Authorize the caller on a token and load its stake in one step.
  /// @param _tokenId tokenId being modified.
  /// @return _owner Current owner of the token.
  /// @return _oldStaked Current staked balance of the token.
  function _authorizedStake(uint256 _tokenId) internal view returns (address _owner, StakedBalance memory _oldStaked) {
    _owner = _ownerOf(_tokenId);
    _checkAuthorized(_owner, msg.sender, _tokenId);
    return (_owner, _staked[_tokenId]);
  }

  /// @notice Voting power for a tokenId at a given timestamp.
  /// @param _tokenId tokenId to query.
  /// @param _t Timestamp to query voting power at.
  /// @return _balance Voting power at the given timestamp.
  function _balanceOfNFTAt(uint256 _tokenId, uint256 _t) internal view returns (uint256 _balance) {
    return BalanceLogicLibrary.balanceOfNFTAt(userPointEpoch, _userPointHistory, _tokenId, _t);
  }

  /// @notice Total supply of voting power at a given timestamp, computed from global checkpoints.
  /// @param _timestamp Timestamp to query.
  /// @return _supply Total voting power at the given timestamp.
  function _supplyAt(uint256 _timestamp) internal view returns (uint256 _supply) {
    return BalanceLogicLibrary.supplyAt(slopeChanges, _pointHistory, epoch, _timestamp);
  }

  /// @notice Current block timestamp narrowed to uint48 via SafeCastLibrary.
  /// @dev Use only when the value flows into a uint48 destination (struct field assignment,
  ///      uint48 arithmetic chain, or external returning uint48). For comparisons against
  ///      uint48 storage or arguments expecting uint256, use block.timestamp directly to
  ///      avoid the redundant cast check.
  /// @return _timestamp block.timestamp safely cast to uint48.
  function _blockTimestamp() internal view returns (uint48 _timestamp) {
    return block.timestamp.toUint48();
  }

  /// @notice Compute a week-aligned stake-end timestamp and validate it.
  /// @dev Single source of truth for stake-end derivation. Callers must pass a `_minRequired` that the new end
  ///      has to strictly exceed: `block.timestamp` for new stakes, the existing end for extensions.
  /// @param _stakingWeeks Whole-week stake duration requested by the caller.
  /// @param _minRequired Minimum stake-end that the result must strictly exceed.
  /// @return _stakeEnd Validated week-aligned stake-end timestamp.
  function _computeStakeEnd(uint48 _stakingWeeks, uint48 _minRequired) internal view returns (uint48 _stakeEnd) {
    _stakeEnd = (_blockTimestamp() / WEEK) * WEEK + _stakingWeeks * WEEK;
    if (_stakeEnd <= _minRequired) _revert(uint32(StakingPeriodNotInFuture.selector));
    if (_stakeEnd > block.timestamp + MAXTIME) _revert(uint32(StakingPeriodTooLong.selector));
  }

  /// @notice Validate and resolve a from-scratch stake shape: funded, permanent mode exclusive with a staking
  ///         period, and a week-aligned end for decay stakes.
  /// @dev Single source for the input rules `createStake` and `reviveStake` share.
  /// @param _value Amount being staked; must be non-zero.
  /// @param _stakingWeeks Whole-week stake duration. Must be zero when `_isPermanent` is true.
  /// @param _isPermanent True to resolve a permanent stake with no end.
  /// @return _stakeEnd Validated week-aligned end, or zero for a permanent stake.
  function _resolveNewStakeEnd(
    uint128 _value,
    uint48 _stakingWeeks,
    bool _isPermanent
  ) internal view returns (uint48 _stakeEnd) {
    if (_value == 0) _revert(uint32(ZeroAmount.selector));
    if (_isPermanent && _stakingWeeks > 0) _revert(uint32(StakingPeriodNotAllowed.selector));
    _stakeEnd = _isPermanent ? 0 : _computeStakeEnd(_stakingWeeks, _blockTimestamp());
  }

  /// @notice Require a staked balance whose life is over: non-permanent and past its end.
  /// @dev Single source for the predicate `withdraw` and `reviveStake` share.
  /// @param _stakedBalance Staked balance to check.
  function _requireStakeOver(StakedBalance memory _stakedBalance) internal view {
    if (_stakedBalance.isPermanent) _revert(uint32(PermanentStake.selector));
    if (_stakedBalance.end > _blockTimestamp()) _revert(uint32(StakeNotExpired.selector));
  }

  /// @notice Whether `_account` holds VPM_ROLE.
  /// @dev Internal counterpart of the public `isAuthorizedVPM`, backing the `isAuthorizedVPM` and `isAuthorizedVPMForToken` view helpers.
  /// @param _account Address to check.
  /// @return _authorized True when `_account` is recognized as a VPM caller.
  function _isAuthorizedVPM(address _account) internal view returns (bool _authorized) {
    return hasRole(VPM_ROLE, _account);
  }

  /// @notice Revert unless at least `_amount` of the token's allocation sits idle on the Voter's chain0, i.e. no
  ///         cross-chain allocations remain to cover it. The caller returns remote budget through the
  ///         `DEALLOC_GAUGE` sentinel beforehand.
  /// @dev Same chain0-coverage predicate the Voter enforces on `rebalanceChain0` / `burn`, reusing its
  ///      `InsufficientChain0Allocation` error. Used by `withdraw` and `downgradeFromPermanentStake`.
  /// @param _tokenId Token whose chain0 allocation is checked.
  /// @param _amount Allocation amount that must be fully covered on chain0.
  function _requireFullyOnChain0(uint256 _tokenId, uint128 _amount) internal view {
    if (VOTER.allocationChainAmounts(_tokenId, VOTER.CHAIN0()) < _amount) {
      _revert(uint32(IVoter.InsufficientChain0Allocation.selector));
    }
  }

  /// @notice Revert with a four-byte custom-error selector.
  /// @dev Size-only funnel for the contract's no-argument reverts: one shared revert block instead of an
  ///      inlined copy at each site. Return data is byte-identical to `revert Err()`.
  /// @param _selector Four-byte selector of the error to revert with.
  function _revert(uint32 _selector) private pure {
    assembly ('memory-safe') {
      mstore(0x00, _selector)
      revert(0x1c, 0x04)
    }
  }

  /// @notice Revert ZeroAddress when `_address` is the zero address; otherwise return it unchanged.
  /// @dev Used at construction to validate each dependency/admin inline at its assignment site.
  /// @param _address Address to validate.
  /// @return _checked The same address, guaranteed non-zero.
  function _requireNonZero(address _address) private pure returns (address _checked) {
    if (_address == address(0)) revert ZeroAddress();
    return _address;
  }
}
