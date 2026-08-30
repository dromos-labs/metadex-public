// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {LeafAllocationLibrary} from 'V3/libraries/LeafAllocationLibrary.sol';
import {LeafVoter} from 'V3/voter/LeafVoter.sol';

/**
 * @title LeafVoterHarness
 * @notice Test harness exposing the contribution math LeafVoter delegates to
 *         `LeafAllocationLibrary` so unit tests can drive `contribution`,
 *         `applyContribution`, and `unwindContribution` against the voter's
 *         `_leafStorage` and read back the resulting gauge point and slope
 *         schedule. Adds no state, so the storage layout matches LeafVoter and
 *         the storage-slot cheats in the tests stay valid.
 */
contract LeafVoterHarness is LeafVoter {
  constructor(
    address _governor,
    address _configAdmin,
    address _leafMessageOrchestrator,
    address _receiptToken,
    address _factoryRegistry,
    address _gaugeManager,
    uint48 _allocationCooldown,
    uint256 _maxGauges,
    address _adapterAuthority,
    address _emissionsHandler,
    address _emergencyCouncil
  )
    LeafVoter(
      _governor,
      _configAdmin,
      _leafMessageOrchestrator,
      _receiptToken,
      _factoryRegistry,
      _gaugeManager,
      _allocationCooldown,
      _maxGauges,
      _adapterAuthority,
      _emissionsHandler,
      _emergencyCouncil
    )
  {}

  /**
   * @notice Expose `LeafAllocationLibrary.applyContribution` for direct assertions.
   * @param _gauge Gauge whose state is mutated.
   * @param _allocated AERO amount allocated.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   * @return _bias Bias delta applied.
   * @return _slope Slope delta applied.
   * @return _perm Permanent-balance delta applied.
   */
  function applyContribution(
    address _gauge,
    uint128 _allocated,
    uint48 _stakeEnd,
    bool _isPermanent
  ) external returns (int128 _bias, int128 _slope, int128 _perm) {
    (_bias, _slope, _perm) = LeafAllocationLibrary.contribution(_leafStorage, _allocated, _stakeEnd, _isPermanent);
    LeafAllocationLibrary.applyContribution(_leafStorage, _gauge, _allocated, _stakeEnd, _isPermanent);
  }

  /**
   * @notice Expose `LeafAllocationLibrary.unwindContribution` for direct assertions.
   * @param _gauge Gauge whose state is mutated.
   * @param _allocated AERO amount previously allocated.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   */
  function unwindContribution(address _gauge, uint128 _allocated, uint48 _stakeEnd, bool _isPermanent) external {
    LeafAllocationLibrary.unwindContribution(_leafStorage, _gauge, _allocated, _stakeEnd, _isPermanent);
  }

  /**
   * @notice Expose `LeafAllocationLibrary.contribution` for direct assertions.
   * @param _allocated AERO amount allocated.
   * @param _stakeEnd Stake expiry; `0` for a permanent stake.
   * @param _isPermanent True for a permanent stake.
   * @return _bias Time-decaying contribution.
   * @return _slope Decay rate contribution.
   * @return _perm Permanent contribution.
   */
  function contribution(
    uint128 _allocated,
    uint48 _stakeEnd,
    bool _isPermanent
  ) external view returns (int128 _bias, int128 _slope, int128 _perm) {
    return LeafAllocationLibrary.contribution(_leafStorage, _allocated, _stakeEnd, _isPermanent);
  }
}
