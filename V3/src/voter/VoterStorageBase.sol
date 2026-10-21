// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {VoterStorage} from 'V3/voter/VoterStorageLayout.sol';

import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title VoterStorageBase
 * @notice Declares the Voter's single storage holder — the `VoterStorage` struct — and
 *         the explicit getters over its fields. The Voter inherits this base and passes the struct to the
 *         library by reference, so both read and write the same state.
 * @dev `AccessControlEnumerable` takes slots 0 and 1, so the struct starts at slot 2. Adding state to any
 *      inherited contract, or inheriting a new one with state before this base, shifts it.
 */
abstract contract VoterStorageBase is IVoter {
  using EnumerableSet for EnumerableSet.UintSet;

  /*//////////////////////////////////////////////////////////////
                              VOTER STORAGE
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Every per-tokenId, per-chain and global field the allocation and settlement logic reads or
   *         writes, grouped in one struct so `AllocationLogicLibrary` entries take a single storage reference.
   * @dev Field order fixes each field's slot. Do not reorder the struct or declare storage above this holder.
   */
  VoterStorage internal _voterStorage;

  /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc IVoter
  function allocationChainAmounts(uint256 _tokenId, uint256 _chainId) external view returns (uint128 _allocated) {
    _allocated = _voterStorage.allocationChainAmounts[_tokenId][_chainId];
  }

  /// @inheritdoc IVoter
  function tokenStates(uint256 _tokenId)
    external
    view
    returns (uint128 _committed, uint48 _lastStakeEnd, uint48 _lastAllocated, bool _isPermanent)
  {
    TokenState storage _state = _voterStorage.tokenStates[_tokenId];
    _committed = _state.committed;
    _lastStakeEnd = _state.lastStakeEnd;
    _lastAllocated = _state.lastAllocated;
    _isPermanent = _state.isPermanent;
  }

  /// @inheritdoc IVoter
  function chainStates(uint256 _chainId)
    external
    view
    returns (
      Point memory _point,
      uint256 _ceiling,
      uint256 _totalRedeemed,
      uint256 _reportedSurplus,
      uint256 _cumulativeSuspendedSurplus,
      uint256 _surplusSpent,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      uint256 _donatedBuffer,
      ChainStatus _status
    )
  {
    ChainState storage _state = _voterStorage.chainStates[_chainId];
    _point = _state.point;
    _ceiling = _state.ceiling;
    _totalRedeemed = _state.totalRedeemed;
    _reportedSurplus = _state.reportedSurplus;
    _cumulativeSuspendedSurplus = _state.cumulativeSuspendedSurplus;
    _surplusSpent = _state.surplusSpent;
    _lastIndex = _state.lastIndex;
    _lastTimeIndex = _state.lastTimeIndex;
    _donatedBuffer = _state.donatedBuffer;
    _status = _state.status;
  }

  /// @inheritdoc IVoter
  function chainSlopeChanges(uint256 _chainId, uint48 _expiry) external view returns (int128 _slopeChange) {
    _slopeChange = _voterStorage.chainSlopeChanges[_chainId][_expiry];
  }

  /// @inheritdoc IVoter
  function emergencyDeallocationAllowed(uint256 _chainId) external view returns (bool _allowed) {
    _allowed = _voterStorage.emergencyDeallocationAllowed[_chainId];
  }

  /// @inheritdoc IVoter
  function totalPoint()
    external
    view
    returns (int128 _bias, int128 _slope, uint48 _ts, uint128 _permanentStakeBalance)
  {
    Point storage _point = _voterStorage.totalPoint;
    _bias = _point.bias;
    _slope = _point.slope;
    _ts = _point.ts;
    _permanentStakeBalance = _point.permanentStakeBalance;
  }

  /// @inheritdoc IVoter
  function totalSlopeChanges(uint48 _expiry) external view returns (int128 _slopeChange) {
    _slopeChange = _voterStorage.totalSlopeChanges[_expiry];
  }

  /// @inheritdoc IVoter
  function index() external view returns (uint256 _index) {
    _index = _voterStorage.index;
  }

  /// @inheritdoc IVoter
  function timeIndex() external view returns (uint256 _timeIndex) {
    _timeIndex = _voterStorage.timeIndex;
  }

  /// @inheritdoc IVoter
  function emissionsPerVP() external view returns (uint256 _emissionsPerVP) {
    _emissionsPerVP = _voterStorage.emissionsPerVP;
  }

  /// @inheritdoc IVoter
  function lastGlobalSettlement() external view returns (uint48 _lastGlobalSettlement) {
    _lastGlobalSettlement = _voterStorage.lastGlobalSettlement;
  }

  /// @inheritdoc IVoter
  function indexAtBoundary(uint48 _boundary) external view returns (uint256 _index) {
    _index = _voterStorage.indexAtBoundary[_boundary];
  }

  /// @inheritdoc IVoter
  function timeIndexAtBoundary(uint48 _boundary) external view returns (uint256 _timeIndex) {
    _timeIndex = _voterStorage.timeIndexAtBoundary[_boundary];
  }

  /// @inheritdoc IVoter
  function allocationChainIds(uint256 _tokenId) external view returns (uint256[] memory _chainIds) {
    _chainIds = _voterStorage.allocationChainIds[_tokenId].values();
  }

  /// @inheritdoc IVoter
  function chains() external view returns (uint256[] memory _chainIds) {
    _chainIds = _voterStorage.chains.values();
  }

  /// @inheritdoc IVoter
  function allocationLifetime() external view returns (uint48 _allocationLifetime) {
    _allocationLifetime = _voterStorage.allocationLifetime;
  }

  /// @inheritdoc IVoter
  function messageLifetime() external view returns (uint48 _messageLifetime) {
    _messageLifetime = _voterStorage.messageLifetime;
  }
}
