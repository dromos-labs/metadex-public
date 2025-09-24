// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {FixedPointMathLib} from '@solady/utils/FixedPointMathLib.sol';
import {LibTransient} from '@solady/utils/LibTransient.sol';

import {ICLPoolConstants} from 'V3/interfaces/pools/ICLPoolConstants.sol';
import {ICLPoolDerivedState} from 'V3/interfaces/pools/ICLPoolDerivedState.sol';
import {ICLPoolState} from 'V3/interfaces/pools/ICLPoolState.sol';

import {ICLFactory} from 'V3/interfaces/factories/ICLFactory.sol';

import {TransientMevTaxLib} from 'V3/hooks/dynamic/libraries/TransientMevTaxLib.sol';
import {MAX_PIPS} from 'V3/libraries/ProtocolConstants.sol';

import {IDiscountRegistry} from 'V3/interfaces/fees/IDiscountRegistry.sol';
import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';
import {IDynamicSwapFeeHook, ISwapHook} from 'V3/interfaces/hooks/dynamic/IDynamicSwapFeeHook.sol';
import {ICLPoolTape} from 'V3/interfaces/pools/tape/ICLPoolTape.sol';

contract DynamicSwapFeeHook is IDynamicSwapFeeHook {
  using TransientMevTaxLib for mapping(address => LibTransient.TBytes32);
  using TransientMevTaxLib for IMevTaxModule;
  using LibTransient for LibTransient.TUint256;
  using FixedPointMathLib for uint256;

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @dev It must be set to the block time.
  /// @inheritdoc IDynamicSwapFeeHook
  uint32 public constant MIN_SECONDS_AGO = 1;

  /// @dev 65535 is the maximum number of slots available in the oracle
  /// @inheritdoc IDynamicSwapFeeHook
  uint32 public constant MAX_SECONDS_AGO = 65_535 * MIN_SECONDS_AGO;

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public constant MAX_BASE_FEE = 30_000; // 3%

  /// @dev Override to indicate there is custom 0% fee - as a 0 value
  ///      in the customFee mapping indicates that no custom fee rate has been set.
  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public constant ZERO_FEE_INDICATOR = 55_555;

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public constant MAX_SCALING_FACTOR = 1e18;

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public constant SCALING_PRECISION = 1e6;

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public constant MAX_FEE_CAP = 50_000; // 5%

  /// @inheritdoc IDynamicSwapFeeHook
  ICLFactory public immutable FACTORY;

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public defaultScalingFactor; // default K

  /// @inheritdoc IDynamicSwapFeeHook
  uint256 public defaultFeeCap;

  /// @inheritdoc IDynamicSwapFeeHook
  uint32 public secondsAgo = 600; // 10 minutes

  /// @inheritdoc IDynamicSwapFeeHook
  mapping(address _pool => DynamicFeeConfig _config) public dynamicFeeConfig;

  /// @notice pool => block.number => totalFee = min((baseFee + dynamicFee), feeCap) || ZERO_FEE_INDICATOR
  /// @dev The block number is assumed to be chain's own block number.
  /// @inheritdoc IDynamicSwapFeeHook
  mapping(address _pool => mapping(uint256 _blockNumber => uint256 _blockFee)) public blockFee;

  /// @inheritdoc IDynamicSwapFeeHook
  IMevTaxModule public mevTaxModule;

  /*////////////////////////////////////////////////////////////
                              TRANSIENT STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @notice Transient storage mapping for per-pool MEV fee and toxic flag.
  /// @dev As of now, solc does not support transient composite types.
  ///      To work around this, we store packed `uint24 + bool` data
  ///      as a `bytes32` using `LibTransient.TBytes32`. It computes the transient storage
  ///      slot dynamically and provides get/set operations via TLOAD/TSTORE.
  mapping(address _pool => LibTransient.TBytes32 _mevData) internal _transientMevData;

  /// @notice Transient storage mapping to store inital fee for ALL swaps of the first tx.
  /// @dev Possible values of _initialFee:
  ///       - 0 => no first tx-wide fee is set - the block-wide fee is applied.
  ///       - ZERO_FEE_INDICATOR => use zero first tx-wide fee
  ///       - (>0 & !ZERO_FEE_INDICATOR) => use non-zero first tx-wide fee.
  mapping(address _pool => LibTransient.TUint256 _initialFee) internal _transientFirstTxInitialFee;

  /*////////////////////////////////////////////////////////////
                              MODIFIERS
  ////////////////////////////////////////////////////////////*/

  /// @dev Reverts when the caller isn't factory-set swap fee manager.
  modifier onlySwapFeeManager() {
    require(msg.sender == FACTORY.swapFeeManager(), 'NFM');
    _;
  }

  /// @dev Reverts when the caller isn't factory-registered pool.
  modifier onlyPool() {
    require(FACTORY.isPool(msg.sender), 'CNP');
    _;
  }

  /*////////////////////////////////////////////////////////////
                              CONSTRUCTOR
  ////////////////////////////////////////////////////////////*/

  /// @notice Initializes the dynamic swap fee hook contract.
  /// @param _factory The address of the CL factory contract.
  /// @param _defaultScalingFactor The initial default scaling factor (K).
  /// @param _defaultFeeCap The initial default fee cap.
  /// @param _pools Array of pool addresses for bulk fee initialisation.
  /// @param _fees Array of fees corresponding to the pools.
  constructor(
    address _factory,
    uint256 _defaultScalingFactor,
    uint256 _defaultFeeCap,
    address[] memory _pools,
    uint24[] memory _fees
  ) {
    require(_defaultScalingFactor <= MAX_SCALING_FACTOR, 'ISF');
    require(_defaultFeeCap <= MAX_FEE_CAP, 'MFC');
    require(_defaultFeeCap > 0, 'FC0');

    require(_factory != address(0), 'FZA');

    FACTORY = ICLFactory(_factory);
    defaultScalingFactor = _defaultScalingFactor;
    defaultFeeCap = _defaultFeeCap;

    emit DefaultScalingFactorSet(_defaultScalingFactor);
    emit DefaultFeeCapSet(_defaultFeeCap);

    _bulkUpdateFees(ICLFactory(_factory), _pools, _fees);
  }

  /*////////////////////////////////////////////////////////////
                              GLOBAL SETTERS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDynamicSwapFeeHook
  function setDefaultScalingFactor(uint256 _defaultScalingFactor) external onlySwapFeeManager {
    require(_defaultScalingFactor <= MAX_SCALING_FACTOR, 'ISF');

    defaultScalingFactor = _defaultScalingFactor;
    emit DefaultScalingFactorSet(_defaultScalingFactor);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setDefaultFeeCap(uint256 _defaultFeeCap) external onlySwapFeeManager {
    require(_defaultFeeCap <= MAX_FEE_CAP, 'MFC');
    require(_defaultFeeCap > 0, 'FC0');

    defaultFeeCap = _defaultFeeCap;
    emit DefaultFeeCapSet(_defaultFeeCap);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setInitialFee(address _pool, uint24 _fee) external onlySwapFeeManager {
    require(FACTORY.isPool(_pool), 'PNP');
    require(_fee <= MAX_FEE_CAP || _fee == ZERO_FEE_INDICATOR, 'MIF');

    dynamicFeeConfig[_pool].initialFeeEnabled = true;
    dynamicFeeConfig[_pool].initialFee = _fee;
    emit InitialFeeSet(_pool, _fee);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function disableInitialFee(address _pool) external onlySwapFeeManager {
    require(FACTORY.isPool(_pool), 'PNP');

    dynamicFeeConfig[_pool].initialFeeEnabled = false;
    delete dynamicFeeConfig[_pool].initialFee;
    emit InitialFeeDisabled(_pool);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setSecondsAgo(uint32 _secondsAgo) external onlySwapFeeManager {
    require(_secondsAgo >= MIN_SECONDS_AGO && _secondsAgo < MAX_SECONDS_AGO, 'ISA');

    secondsAgo = _secondsAgo;
    emit SecondsAgoSet(_secondsAgo);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setMevTaxModule(address _mevTaxModule) external onlySwapFeeManager {
    mevTaxModule = IMevTaxModule(_mevTaxModule);

    emit MevTaxModuleSet(_mevTaxModule);
  }

  /*////////////////////////////////////////////////////////////
                              PER-POOL SETTERS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDynamicSwapFeeHook
  function setCustomFee(address _pool, uint24 _fee) external onlySwapFeeManager {
    _setCustomFee(FACTORY, _pool, _fee);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setScalingFactor(address _pool, uint64 _scalingFactor) external onlySwapFeeManager {
    _setScalingFactor(_pool, _scalingFactor);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function setFeeCap(address _pool, uint24 _feeCap) external onlySwapFeeManager {
    _setFeeCap(_pool, _feeCap);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function resetDynamicFee(address _pool) external onlySwapFeeManager {
    require(FACTORY.isPool(_pool), 'PNP');

    delete dynamicFeeConfig[_pool].feeCap;
    delete dynamicFeeConfig[_pool].scalingFactor;
    delete dynamicFeeConfig[_pool].initialFeeEnabled;
    delete dynamicFeeConfig[_pool].initialFee;
    emit DynamicFeeReset(_pool);
  }

  /*////////////////////////////////////////////////////////////
                              BULK SETTERS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDynamicSwapFeeHook
  function bulkUpdateFees(address[] calldata _pools, uint24[] calldata _fees) external onlySwapFeeManager {
    _bulkUpdateFees(FACTORY, _pools, _fees);
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function bulkUpdateFeeCaps(address[] calldata _pools, uint24[] calldata _feeCaps) external onlySwapFeeManager {
    uint256 _poolsLength = _pools.length;
    require(_poolsLength == _feeCaps.length, 'LMM');

    address _pool;
    uint24 _feeCap;
    for (uint256 _i = 0; _i < _poolsLength; ++_i) {
      (_pool, _feeCap) = (_pools[_i], _feeCaps[_i]);
      _setFeeCap(_pool, _feeCap);
    }
  }

  /// @inheritdoc IDynamicSwapFeeHook
  function bulkUpdateScalingFactors(
    address[] calldata _pools,
    uint64[] calldata _scalingFactors
  ) external onlySwapFeeManager {
    uint256 _poolsLength = _pools.length;
    require(_poolsLength == _scalingFactors.length, 'LMM');

    address _pool;
    uint64 _scalingFactor;
    for (uint256 _i = 0; _i < _poolsLength; ++_i) {
      (_pool, _scalingFactor) = (_pools[_i], _scalingFactors[_i]);
      _setScalingFactor(_pool, _scalingFactor);
    }
  }

  /*////////////////////////////////////////////////////////////
                              HOOK METHODS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc ISwapHook
  /// @dev Replaces previous IFeeModule.getFee function.
  function beforeSwap(ISwapHook.SwapParams memory _swapParams) external onlyPool returns (uint24 _fee) {
    address _pool = msg.sender;

    _fee = _getFeeAndStore(_pool, _swapParams.caller);

    (uint24 _mevFee, bool _toxic) = mevTaxModule.mevTax();
    _transientMevData.write(_pool, _fee, _toxic);

    /// @dev Final fee is capped dynamic fee + raw MEV fee.
    _fee = _fee + _mevFee;
  }

  /// @inheritdoc ISwapHook
  /// @dev This hook charges no post-swap fee.
  function afterSwap(
    ISwapHook.SwapParams memory _swapParams,
    ISwapHook.AfterSwapParams memory _afterSwapParams
  ) external onlyPool returns (uint24) {
    address _clPoolTape = FACTORY.clPoolTape();

    if (_clPoolTape != address(0)) {
      // slither-disable-next-line uninitialized-local
      AfterSwapCache memory _cache;

      _cache.inputAmount = uint256(
        _swapParams.amountSpecified > 0
          ? (_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining)
          : _afterSwapParams.amountCalculated
      );

      _cache.outputAmount = uint256(
        -(_swapParams.amountSpecified > 0
            ? _afterSwapParams.amountCalculated
            : (_swapParams.amountSpecified - _afterSwapParams.amountSpecifiedRemaining))
      );

      /// @dev TLOADs MEV data from {beforeSwap}.
      (uint24 _dynamicFee, bool _toxic) = _transientMevData.read({_pool: msg.sender});

      /// @dev Cap the dynamic fee, by the total fee, in case it's gt the total.
      ///      That should be impossible, but if `SwapHookLib._SWAP_FEE_CEIL`
      ///      will ever be lowered then this check is needed.
      _dynamicFee = _dynamicFee > _afterSwapParams.fee ? _afterSwapParams.fee : _dynamicFee;

      /// @dev fee = min(dynamicFee + mevFee, SwapHookLib._SWAP_FEE_CEIL)
      ///      fee ≥ dynamicFee
      ///      => mevFee = fee - dynamicFee
      uint24 _mevFee = _afterSwapParams.fee - _dynamicFee;

      if (_mevFee == 0) {
        _cache.feeAmount = _cache.inputAmount.mulDivUp(_afterSwapParams.fee, MAX_PIPS);
      } else {
        _cache.feeAmount = _cache.inputAmount.mulDivUp(_dynamicFee, MAX_PIPS);
        _cache.mevFeeAmount = _cache.inputAmount.mulDivUp(_mevFee, MAX_PIPS);
      }

      (_cache.volume0, _cache.volume1) = _swapParams.zeroForOne
        ? (uint128(_cache.inputAmount), uint128(_cache.outputAmount))
        : (uint128(_cache.outputAmount), uint128(_cache.inputAmount));

      /// @dev Neither success of the call, nor return data matter here.
      // slither-disable-next-line unused-return
      try ICLPoolTape(_clPoolTape)
        .record({
        _pool: msg.sender,
        _data: ICLPoolTape.CLPoolTapeData({
        /// @dev Fee is always paid on the input amount.
        fee0: _swapParams.zeroForOne ? uint128(_cache.feeAmount + _cache.mevFeeAmount) : 0,
        fee1: _swapParams.zeroForOne ? 0 : uint128(_cache.feeAmount + _cache.mevFeeAmount),
        volume0: _cache.volume0,
        volume1: _cache.volume1,
        /// @dev MEV attribution
        mevFee0: _swapParams.zeroForOne ? uint128(_cache.mevFeeAmount) : 0,
        mevFee1: _swapParams.zeroForOne ? 0 : uint128(_cache.mevFeeAmount),
        mevVolume0: _toxic ? _cache.volume0 : 0,
        mevVolume1: _toxic ? _cache.volume1 : 0,
        tick: _swapParams.tick
      })
      }) {}
        catch {}
    }

    /// @dev Clears transient storage jic.
    _transientMevData.write({_pool: msg.sender, _dynamicFee: 0, _toxic: false});
  }

  /// @inheritdoc ISwapHook
  function beforeFlash(ISwapHook.FlashParams memory _flashParams) external view onlyPool returns (uint24 _fee) {
    _fee = getFlashFee(msg.sender, _flashParams);
  }

  /*////////////////////////////////////////////////////////////
                              EXTERNAL VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @inheritdoc IDynamicSwapFeeHook
  function customFee(address _pool) external view returns (uint24) {
    return dynamicFeeConfig[_pool].baseFee;
  }

  /// @inheritdoc ISwapHook
  function getBeforeSwapFee(
    address _pool,
    ISwapHook.SwapParams memory _swapParams
  ) external view returns (uint24 _fee) {
    // slither-disable-next-line unused-return
    (_fee,) = _getFee(_pool, _swapParams.caller);

    // slither-disable-next-line unused-return
    (uint24 _mevFee,) = mevTaxModule.mevTax();
    _fee = _fee + _mevFee;
  }

  /// @inheritdoc ISwapHook
  /// @dev There is no after-swap fee.
  function getAfterSwapFee(
    address,
    ISwapHook.SwapParams memory,
    ISwapHook.AfterSwapParams memory
  ) external pure returns (uint24 _fee) {
    _fee = 0;
  }

  /// @inheritdoc ISwapHook
  function getFlashFee(address _pool, ISwapHook.FlashParams memory) public view returns (uint24) {
    uint24 _baseFee = dynamicFeeConfig[_pool].baseFee;

    if (_baseFee == ZERO_FEE_INDICATOR) return 0;
    else if (_baseFee == 0) return FACTORY.tickSpacingToFee(ICLPoolConstants(_pool).tickSpacing());
    else return _baseFee;
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL SETTERS
  ////////////////////////////////////////////////////////////*/

  /// @notice Bulk update custom fees for multiple pools.
  /// @param _factory The factory contract used to validate pools.
  /// @param _pools Array of pool addresses.
  /// @param _fees Array of fee values corresponding to each pool.
  function _bulkUpdateFees(ICLFactory _factory, address[] memory _pools, uint24[] memory _fees) internal {
    uint256 _poolsLength = _pools.length;
    require(_poolsLength == _fees.length, 'LMM');

    address _pool;
    uint24 _fee;
    for (uint256 _i = 0; _i < _poolsLength; ++_i) {
      (_pool, _fee) = (_pools[_i], _fees[_i]);
      _setCustomFee(_factory, _pool, _fee);
    }
  }

  /// @notice Sets the new fee cap on the passed pool.
  function _setFeeCap(address _pool, uint24 _feeCap) internal {
    require(FACTORY.isPool(_pool), 'PNP');
    require(_feeCap > 0, 'FC0');
    require(_feeCap <= MAX_FEE_CAP, 'MFC');

    dynamicFeeConfig[_pool].feeCap = _feeCap;
    emit FeeCapSet(_pool, _feeCap);
  }

  /// @notice Sets a custom fee for a given pool.
  function _setCustomFee(ICLFactory _factory, address _pool, uint24 _fee) internal {
    require(_fee <= MAX_BASE_FEE || _fee == ZERO_FEE_INDICATOR, 'MBF');
    require(_factory.isPool(_pool), 'PNP');

    dynamicFeeConfig[_pool].baseFee = _fee;
    emit CustomFeeSet(_pool, _fee);
  }

  /// @notice Sets the new scaling factor on the passed pool.
  function _setScalingFactor(address _pool, uint64 _scalingFactor) internal {
    require(FACTORY.isPool(_pool), 'PNP');
    require(dynamicFeeConfig[_pool].feeCap != 0 && _scalingFactor <= MAX_SCALING_FACTOR, 'ISF');

    dynamicFeeConfig[_pool].scalingFactor = _scalingFactor;
    emit ScalingFactorSet(_pool, _scalingFactor);
  }

  /*////////////////////////////////////////////////////////////
                              INTERNAL HELPERS
  ////////////////////////////////////////////////////////////*/

  /// @notice Gets the current dynamic fee and stores the block-wide fee if
  ///         the swap is the first in the block.
  ///         Sets the first tx-wide fee on the first swap in the block.
  /// @param _pool The pool contract.
  /// @param _caller The msg.sender in the swap call context.
  /// @return _fee The fee to charge for this swap (discounted if applicable).
  function _getFeeAndStore(address _pool, address _caller) internal returns (uint24 _fee) {
    (uint24 _feeToUse, uint256 _feeToStore) = _getFee(_pool, _caller);

    // Fee to store is not zero only in the first swap in the block.
    // First swap in the block also means that the current tx is the first
    // tx that executes this first swap in the given `_pool`. Therefore, if initial fee is
    // enabled, we use it for all subsequent swaps in that same tx in that same `_pool`.
    if (_feeToStore != 0) {
      blockFee[_pool][block.number] = _feeToStore;

      if (dynamicFeeConfig[_pool].initialFeeEnabled) {
        _transientFirstTxInitialFee[_pool].set(_feeToUse == 0 ? ZERO_FEE_INDICATOR : _feeToUse);
      }
    }
    _fee = _feeToUse;
  }

  /// @notice Returns the fee for the current swap and the fee to store and
  ///         apply for all subsequent swaps in the current block.
  /// @dev The first swap in the first swap tx in the block sets the block-wide fee.
  ///      If initial fee is enabled - all subsequent swaps in the first swap tx use tx-wide fee.
  ///      If initial fee is disabled - all subsequent swaps in the first swap tx use block-wide fee.
  ///      All swaps in subsequent txs use block-wide fee.
  /// @param _pool The pool contract.
  /// @param _caller The msg.sender in the swap call context.
  /// @return _feeToUse The fee to charge for this swap (discounted if applicable).
  /// @return _feeToStore The fee to store and use for the current block (0 if already stored, otherwise the raw total fee or ZERO_FEE_INDICATOR).
  function _getFee(address _pool, address _caller) internal view returns (uint24 _feeToUse, uint256 _feeToStore) {
    uint256 _blockFee = blockFee[address(_pool)][block.number];
    uint256 _firstTxInitialFee = _transientFirstTxInitialFee[_pool].get();

    /// @dev First swap in the block.
    if (_blockFee == 0) {
      (_feeToUse, _feeToStore) = _getFirstSwapFee(_pool, _caller);
    }
    /// @dev The first tx, but not the first swap.
    else if (_firstTxInitialFee != 0) {
      if (_firstTxInitialFee == ZERO_FEE_INDICATOR) _feeToUse = 0;
      else _feeToUse = uint24(_firstTxInitialFee);
    }
    /// @dev Block-wide fee is already set.
    else if (_blockFee != ZERO_FEE_INDICATOR) {
      _feeToUse = _applyDiscount(address(_pool), _caller, _blockFee);
    }
  }

  /// @notice Callable only on the first swap in the block.
  /// @dev The fee-resolution rules are:
  ///      - If `baseFee` is `ZERO_FEE_INDICATOR`, all swaps in the block use `ZERO_FEE_INDICATOR`.
  ///        The `SwapHookLib` resolves returned zero fee into a tick-spacing fee.
  ///      - If `baseFee` is zero, the default tick-spacing fee is used as a base component to
  ///        which the dynamic component is added.
  ///      - Both the fee cap and scaling factor fall back to default values if `scalingFactor` is zero.
  ///        If `scalingFactor` is non-zero, the configured cap and scaling factor are used.
  ///      - The dynamic component is computed based on TWAVG tick in the past `secondsAgo` of the given pool.
  ///      - The raw total fee is `min(baseFee + dynamicFee, feeCap)` and is returned as `_feeToStore`
  ///        that is keyed and stored by the current block number in the storage.
  ///      - If `initialFeeEnabled` is set:
  ///          - `initialFee == 0` => use the effective `baseFee`.
  ///          - `initialFee == ZERO_FEE_INDICATOR` => use 0.
  ///          - otherwise => charge the exact `initialFee` value (this bypasses the fee cap).
  ///        The initial fee is not a subject to discount from the `DiscountRegistry`.
  ///      - If `initialFeeEnabled` is disabled, the first swap pays the discounted total fee.
  /// @param _pool The pool contract.
  /// @param _caller The msg.sender in the swap call context.
  /// @return _feeToUse The fee to apply to the current first swap.
  /// @return _feeToStore The fee to apply on all subsequent swaps in the block.
  function _getFirstSwapFee(
    address _pool,
    address _caller
  ) internal view returns (uint24 _feeToUse, uint256 _feeToStore) {
    // Reading this struct is 1 SLOAD.
    DynamicFeeConfig memory _config = dynamicFeeConfig[_pool];

    uint256 _baseFee = _config.baseFee;
    uint256 _scalingFactor = _config.scalingFactor;
    uint256 _feeCap = _config.feeCap;

    /// @dev Zero scaling factor falls back to use default values
    ///      for BOTH the fee cap and scaling factor.
    if (_scalingFactor == 0) {
      (_scalingFactor, _feeCap) = (defaultScalingFactor, defaultFeeCap);
    }

    /// @dev Use fee=0, but store 0 indicator, so that all swaps
    ///      in the block would pay the same zero fee.
    if (_baseFee == ZERO_FEE_INDICATOR) return (0, ZERO_FEE_INDICATOR);

    if (_baseFee == 0) _baseFee = FACTORY.tickSpacingToFee(ICLPoolConstants(_pool).tickSpacing());

    // First swap in the block always recomputes the dynamic component.
    uint256 _dynamicFee = _getDynamicFee(_pool, _scalingFactor);

    // The stored fee can't exceed 50_000 value.
    _feeToStore = FixedPointMathLib.min(_baseFee + _dynamicFee, _feeCap);

    /// @dev If there's a fee for the first swap in the block - use it.
    ///      If set - the initial fee is used for ALL swaps in the first tx in a given pool.
    if (_config.initialFeeEnabled) {
      uint256 _initialFee = _config.initialFee;

      if (_initialFee == 0) _feeToUse = uint24(_baseFee);
      else if (_initialFee == ZERO_FEE_INDICATOR) _feeToUse = 0;
      else _feeToUse = uint24(_initialFee);
    }
    /// @dev Use discounted dynamic fee.
    else {
      _feeToUse = _applyDiscount(address(_pool), _caller, _feeToStore);
    }
  }

  /// @notice Computes the dynamic fee component based on recent volatility.
  /// @dev Uses the time-weighted average tick from the pool's oracle.
  /// @param _pool The pool contract.
  /// @param _scalingFactor The scaling factor (K) for this pool.
  /// @return The dynamic fee.
  function _getDynamicFee(address _pool, uint256 _scalingFactor) internal view returns (uint256) {
    // slither-disable-next-line unused-return
    (, int24 _currentTick, uint16 _observationIndex, uint16 _observationCardinality,,) = ICLPoolState(_pool).slot0();

    if (_observationCardinality == 0) return 0;

    // slither-disable-next-line unused-return
    (uint32 _oldestObservationTimestamp,,, bool _initialized) =
      ICLPoolState(_pool).observations((_observationIndex + 1) % _observationCardinality);

    // slither-disable-next-line unused-return
    if (!_initialized) (_oldestObservationTimestamp,,,) = ICLPoolState(_pool).observations(0);

    uint32 _secondsAgo = secondsAgo;
    if (_secondsAgo > (uint32(block.timestamp) - _oldestObservationTimestamp)) return 0;

    uint32[] memory _secondsAgos = new uint32[](2);
    _secondsAgos[0] = _secondsAgo; // (oldest)
    // _secondsAgos[1] = 0; default is 0 (newest)

    int24 _twAvgTick = 0;

    // slither-disable-next-line unused-return
    try ICLPoolDerivedState(_pool).observe(_secondsAgos) returns (int56[] memory _tickCumulatives, uint160[] memory) {
      int56 _tickCumulativeDelta = _tickCumulatives[1] - _tickCumulatives[0];

      _twAvgTick = int24(_tickCumulativeDelta / int256(uint256(_secondsAgo)));

      // Round down toward negative Inf.
      if (_tickCumulativeDelta < 0 && (_tickCumulativeDelta % int256(uint256(_secondsAgo)) != 0)) {
        _twAvgTick -= 1;
      }
    } catch {
      return 0;
    }

    int24 _tickDelta = _currentTick - _twAvgTick;
    uint24 _absTickDelta = _tickDelta < 0 ? uint24(-_tickDelta) : uint24(_tickDelta);

    return _absTickDelta * _scalingFactor / SCALING_PRECISION;
  }

  /// @notice Applies a discount from the discount registry to a raw fee.
  /// @param _pool The pool address.
  /// @param _caller The msg.sender in the swap call context.
  /// @param _rawFee The fee before discount (in pips).
  /// @return _discountedFee The final fee after applying the discount (in pips).
  function _applyDiscount(
    address _pool,
    address _caller,
    uint256 _rawFee
  ) internal view returns (uint24 _discountedFee) {
    IDiscountRegistry _discountRegistry = IDiscountRegistry(FACTORY.discountRegistry());

    _discountedFee = uint24(_rawFee);

    /// @dev No discounts if DR isn't set.
    if (address(_discountRegistry) != address(0)) {
      // It doesn't use try/catch here, since the Discount Registry
      // is a trusted singleton set by the Governance.
      // Moreover {getDiscount} is a view function with no revert path.
      // The only theoretical revert would be OOG, which is unlikely
      // to happen given that the DR mainly executes a mapping lookup.
      uint24 _discount = _discountRegistry.getDiscount(address(_pool), _caller);
      if (_discount > 0) _rawFee = _rawFee.mulDivUp((MAX_PIPS - _discount), MAX_PIPS);

      _discountedFee = uint24(_rawFee);
    }
  }
}
