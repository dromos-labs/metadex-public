// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {Ownable, Ownable2Step} from '@openzeppelin/contracts/access/Ownable2Step.sol';

import {IBasePoolTape} from 'V3/interfaces/pools/tape/IBasePoolTape.sol';

/// @title BasePoolTape
abstract contract BasePoolTape is Ownable2Step, IBasePoolTape {
  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IBasePoolTape
  uint32 public defaultCadenceInterval;

  /// @notice Each pool's authorized caller and cadence.
  mapping(address _pool => PoolConfig _config) internal _poolConfigs;

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Deploys the tape with an owner and a strictly positive default cadence.
  /// @param _initialOwner The initial owner.
  /// @param _defaultCadenceInterval The chain-wide default cadence in seconds
  constructor(address _initialOwner, uint32 _defaultCadenceInterval) Ownable(_initialOwner) {
    _setDefaultCadenceInterval(_defaultCadenceInterval);
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IBasePoolTape
  function setDefaultCadenceInterval(uint32 _cadenceInterval) external onlyOwner {
    _setDefaultCadenceInterval(_cadenceInterval);
  }

  /// @inheritdoc IBasePoolTape
  function setPoolCadence(address _pool, uint32 _cadence) external onlyOwner {
    if (_cadence == 0) _cadence = defaultCadenceInterval;
    _poolConfigs[_pool].cadence = _cadence;
    emit PoolCadenceSet(_pool, _cadence);
  }

  /// @inheritdoc IBasePoolTape
  function setAllowedCallerAndInitializePool(address _pool, address _caller) external onlyOwner {
    uint32 _cadence = _poolConfigs[_pool].cadence;

    if (_cadence == 0) {
      _cadence = defaultCadenceInterval;
      emit PoolCadenceSet(_pool, _cadence);
    }
    _poolConfigs[_pool] = PoolConfig(_caller, _cadence);

    // initialize the pool's slots so the first swap writes warm slots
    _initializePool(_pool);

    emit AllowedCallerSet(_pool, _caller);
  }

  /*////////////////////////////////////////////////////////////
                      EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IBasePoolTape
  function allowedCaller(address _pool) external view returns (address _caller) {
    _caller = _poolConfigs[_pool].caller;
  }

  /// @inheritdoc IBasePoolTape
  function poolCadence(address _pool) external view returns (uint32 _cadence) {
    _cadence = _poolConfigs[_pool].cadence;
  }

  /*////////////////////////////////////////////////////////////
                          INTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Validates and stores the chain-wide default cadence interval.
  /// @dev Reverts if the cadence interval is zero.
  /// @param _cadenceInterval The new default cadence in seconds.
  function _setDefaultCadenceInterval(uint32 _cadenceInterval) internal {
    if (_cadenceInterval == 0) revert ZeroCadenceInterval();
    defaultCadenceInterval = _cadenceInterval;
    emit DefaultCadenceIntervalSet(_cadenceInterval);
  }

  /// @notice Initialize a pool's accumulator and observation buffer so the first swap writes warm slots
  /// @param _pool The pool being initialized.
  function _initializePool(address _pool) internal virtual {}

  /// @notice Reads a pool's authorized caller and cadence.
  /// @param _pool The pool to read.
  /// @return _caller The authorized caller, or the zero address when none is set.
  /// @return _cadence The pool's cadence in seconds, zero when unregistered.
  function _poolConfig(address _pool) internal view returns (address _caller, uint32 _cadence) {
    PoolConfig memory _config = _poolConfigs[_pool];
    _caller = _config.caller;
    _cadence = _config.cadence;
  }
}
