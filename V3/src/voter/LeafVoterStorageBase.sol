// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {EnumerableSet} from '@openzeppelin/contracts/utils/structs/EnumerableSet.sol';

import {LeafStorage} from 'V3/voter/LeafVoterStorageLayout.sol';

import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title LeafVoterStorageBase
 * @notice Declares the LeafVoter's single storage holder — the `LeafStorage` struct — and
 *         the explicit getters over its fields. The LeafVoter inherits this base and passes the struct to the
 *         library by reference, so both read and write the same state.
 * @dev `AccessControlEnumerable` takes slots 0 and 1, so the struct starts at slot 2. Adding state to any
 *      inherited contract, or inheriting a new one with state before this base, shifts it.
 */
abstract contract LeafVoterStorageBase is ILeafVoter {
  using EnumerableSet for EnumerableSet.AddressSet;

  /*//////////////////////////////////////////////////////////////
                              LEAF STORAGE
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Every chain, per-gauge and per-tokenId field the allocation and settlement logic reads or writes,
   *         grouped in one struct so `LeafAllocationLibrary` entries take a single storage reference.
   * @dev Field order fixes each field's slot. Do not reorder the struct or declare storage above this holder.
   */
  LeafStorage internal _leafStorage;

  /*//////////////////////////////////////////////////////////////
                            STORAGE GETTERS
  //////////////////////////////////////////////////////////////*/

  /// @inheritdoc ILeafVoter
  function emissionsPerVP() external view returns (uint256 _emissionsPerVP) {
    _emissionsPerVP = _leafStorage.emissionsPerVP;
  }

  /// @inheritdoc ILeafVoter
  function index() external view returns (uint256 _index) {
    _index = _leafStorage.index;
  }

  /// @inheritdoc ILeafVoter
  function timeIndex() external view returns (uint256 _timeIndex) {
    _timeIndex = _leafStorage.timeIndex;
  }

  /// @inheritdoc ILeafVoter
  function lastSettlement() external view returns (uint48 _ts) {
    _ts = _leafStorage.lastSettlement;
  }

  /// @inheritdoc ILeafVoter
  function indexAtBoundary(uint48 _boundary) external view returns (uint256 _indexSnapshot) {
    _indexSnapshot = _leafStorage.indexAtBoundary[_boundary];
  }

  /// @inheritdoc ILeafVoter
  function timeIndexAtBoundary(uint48 _boundary) external view returns (uint256 _timeIndexSnapshot) {
    _timeIndexSnapshot = _leafStorage.timeIndexAtBoundary[_boundary];
  }

  /// @inheritdoc ILeafVoter
  function gaugeStates(address _gauge)
    external
    view
    returns (
      uint128 _ceiling,
      uint128 _claimed,
      uint48 _lastSettlement,
      bool _isRegistered,
      bool _isActivated,
      uint128 _surplus,
      uint256 _lastIndex,
      uint256 _lastTimeIndex,
      Point memory _point
    )
  {
    GaugeState storage _state = _leafStorage.gaugeStates[_gauge];
    _ceiling = _state.ceiling;
    _claimed = _state.claimed;
    _lastSettlement = _state.lastSettlement;
    _isRegistered = _state.isRegistered;
    _isActivated = _state.isActivated;
    _surplus = _state.surplus;
    _lastIndex = _state.lastIndex;
    _lastTimeIndex = _state.lastTimeIndex;
    _point = _state.point;
  }

  /// @inheritdoc ILeafVoter
  function gaugeSlopeChanges(address _gauge, uint48 _expiry) external view returns (int128 _slopeDelta) {
    _slopeDelta = _leafStorage.gaugeSlopeChanges[_gauge][_expiry];
  }

  /// @inheritdoc ILeafVoter
  function tokenStates(uint256 _tokenId)
    external
    view
    returns (address _operator, uint48 _lastAllocated, bool _canVoteForZeroCapGauges, uint128 _chainAllocation)
  {
    TokenState storage _state = _leafStorage.tokenStates[_tokenId];
    _operator = _state.operator;
    _lastAllocated = _state.lastAllocated;
    _canVoteForZeroCapGauges = _state.canVoteForZeroCapGauges;
    _chainAllocation = _state.chainAllocation;
  }

  /// @inheritdoc ILeafVoter
  function tokenSnapshot(uint256 _tokenId)
    external
    view
    returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent)
  {
    TokenSnapshot storage _snapshot = _leafStorage.tokenSnapshot[_tokenId];
    _staked = _snapshot.staked;
    _stakeEnd = _snapshot.stakeEnd;
    _isPermanent = _snapshot.isPermanent;
  }

  /// @inheritdoc ILeafVoter
  function accumulatedCooldownReduction(uint256 _tokenId) external view returns (uint48 _reduction) {
    _reduction = _leafStorage.accumulatedCooldownReduction[_tokenId];
  }

  /// @inheritdoc ILeafVoter
  function allocations(uint256 _tokenId, address _gauge) external view returns (uint128 _allocated) {
    _allocated = _leafStorage.allocations[_tokenId][_gauge];
  }

  /// @inheritdoc ILeafVoter
  function allocatedGauges(uint256 _tokenId) external view returns (address[] memory _gauges) {
    _gauges = _leafStorage.allocatedGauges[_tokenId].values();
  }

  /// @inheritdoc ILeafVoter
  function surplusAccrued() external view returns (uint256 _surplus) {
    _surplus = _leafStorage.surplusAccrued;
  }

  /// @inheritdoc ILeafVoter
  function chainStatus() external view returns (ChainStatus _status) {
    _status = _leafStorage.chainStatus;
  }

  /// @inheritdoc ILeafVoter
  function localVotingEnabled() external view returns (bool _enabled) {
    _enabled = _leafStorage.localVotingEnabled;
  }

  /// @inheritdoc ILeafVoter
  function allocationCooldown() external view returns (uint48 _cooldown) {
    _cooldown = _leafStorage.allocationCooldown;
  }

  /// @inheritdoc ILeafVoter
  function maxAccumulatedCooldownReduction() external view returns (uint48 _maxAccumulatedCooldownReduction) {
    _maxAccumulatedCooldownReduction = _leafStorage.maxAccumulatedCooldownReduction;
  }

  /// @inheritdoc ILeafVoter
  function maxGauges() external view returns (uint256 _maxGauges) {
    _maxGauges = _leafStorage.maxGauges;
  }

  /// @inheritdoc ILeafVoter
  function latestTokenSnapshot(uint256 _tokenId)
    external
    view
    returns (uint128 _staked, uint48 _stakeEnd, bool _isPermanent)
  {
    TokenSnapshot storage _snapshot = _leafStorage.latestTokenSnapshot[_tokenId];
    _staked = _snapshot.staked;
    _stakeEnd = _snapshot.stakeEnd;
    _isPermanent = _snapshot.isPermanent;
  }
}
