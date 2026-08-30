// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ICLFactory} from 'V3/interfaces/factories/ICLFactory.sol';

import {IMevTaxModule} from 'V3/interfaces/fees/IMevTaxModule.sol';
import {ISwapHook} from 'V3/interfaces/hooks/ISwapHook.sol';

interface IDynamicSwapFeeHook is ISwapHook {
  /*////////////////////////////////////////////////////////////
                              STRUCTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Configuration of dynamic fees for a specific pool.
  /// @param baseFee The static fee for the pool (0 means use the factory default, ZERO_FEE_INDICATOR means 0%).
  /// @param feeCap The maximum total fee (base + dynamic) allowed for this pool.
  /// @param scalingFactor The scaling factor (K) used to convert price deviation into a dynamic fee.
  /// @param initialFeeEnabled Whether the initial fee override is active for this pool.
  /// @param initialFee The fee to charge for the first swap in a new block (0 = use baseFee, ZERO_FEE_INDICATOR = 0%).
  struct DynamicFeeConfig {
    uint24 baseFee;
    uint24 feeCap;
    uint64 scalingFactor;
    bool initialFeeEnabled;
    uint24 initialFee;
  }

  /// @notice Cache struct to avoid stack-too-deep in afterSwap.
  /// @param inputAmount Amount of tokens paid by the swapper (positive).
  /// @param outputAmount Amount of tokens received by the swapper (positive).
  /// @param volume0 Volume for token0, derived from input/output and swap direction.
  /// @param volume1 Volume for token1, derived from input/output and swap direction.
  /// @param feeAmount The dynamic fee (excluding MEV) applied to the input amount.
  /// @param mevFeeAmount The MEV fee portion applied to the input amount.
  struct AfterSwapCache {
    uint256 inputAmount;
    uint256 outputAmount;
    uint128 volume0;
    uint128 volume1;
    uint256 feeAmount;
    uint256 mevFeeAmount;
  }

  /*////////////////////////////////////////////////////////////
                              EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when the scaling factor is updated for a pool.
  /// @param _pool The address of the pool whose scaling factor changed.
  /// @param _scalingFactor The new scaling factor.
  event ScalingFactorSet(address indexed _pool, uint256 _scalingFactor);

  /// @notice Emitted when the fee cap is updated for a pool.
  /// @param _pool The address of the pool whose fee cap changed.
  /// @param _feeCap The new fee cap.
  event FeeCapSet(address indexed _pool, uint256 _feeCap);

  /// @notice Emitted when all dynamic fee settings are reset to defaults for a pool.
  /// @param _pool The address of the pool whose dynamic fee was reset.
  event DynamicFeeReset(address indexed _pool);

  /// @notice Emitted when the global default scaling factor is changed.
  /// @param _defaultScalingFactor The new default scaling factor.
  event DefaultScalingFactorSet(uint256 _defaultScalingFactor);

  /// @notice Emitted when the global default fee cap is changed.
  /// @param _defaultFeeCap The new default fee cap.
  event DefaultFeeCapSet(uint256 _defaultFeeCap);

  /// @notice Emitted when the observation window (`secondsAgo`) is updated.
  /// @param _secondsAgo The new time window.
  event SecondsAgoSet(uint32 _secondsAgo);

  /// @notice Emitted when an initial fee is set and enabled for a pool.
  /// @param _pool The pool address.
  /// @param _initialFee The initial fee value.
  event InitialFeeSet(address indexed _pool, uint24 _initialFee);

  /// @notice Emitted when the initial fee is disabled for a pool.
  /// @param _pool The pool address.
  event InitialFeeDisabled(address indexed _pool);

  /// @notice Emitted when a custom (static) fee is set for a pool.
  /// @param _pool The pool address.
  /// @param _fee The custom fee value.
  event CustomFeeSet(address indexed _pool, uint24 _fee);

  /// @notice Emitted when the MEV tax module address is updated.
  /// @param _mevTaxModule The new MEV tax module contract address.
  event MevTaxModuleSet(address indexed _mevTaxModule);

  /*////////////////////////////////////////////////////////////
                              WRITE FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Sets a custom fee for a given pool
  /// @dev Can use default fee by setting the fee to 0, can set zero fee by setting default fee to ZERO_FEE_INDICATOR
  /// @dev Must be called by the current fee manager
  /// @param _pool The pool to set the custom fee for
  /// @param _fee The fee to set for the given pool
  function setCustomFee(address _pool, uint24 _fee) external;

  /// @notice Sets the new default scaling factor
  /// @dev Must be called by the current fee manager
  /// @param _defaultScalingFactor The new default scaling factor for dynamic fees
  function setDefaultScalingFactor(uint256 _defaultScalingFactor) external;

  /// @notice Sets the new default fee cap
  /// @dev Must be called by the current fee manager
  /// @param _defaultFeeCap The new default fee cap for dynamic fees
  function setDefaultFeeCap(uint256 _defaultFeeCap) external;

  /// @notice Sets the new scaling factor on the passed pool
  /// @dev Must be called by the current fee manager
  /// @dev Pool must exist
  /// @dev Must set feeCap first
  /// @param _pool The pool address
  /// @param _scalingFactor The new scaling factor for dynamic fees
  function setScalingFactor(address _pool, uint64 _scalingFactor) external;

  /// @notice Sets the new fee cap on the passed pool
  /// @dev Must be called by the current fee manager
  /// @dev Pool must exist
  /// @param _pool The pool address
  /// @param _feeCap The new fee cap for dynamic fees
  function setFeeCap(address _pool, uint24 _feeCap) external;

  /// @notice Resets the dynamic fee for a given pool
  /// @dev Must be called by the current fee manager
  /// @dev Pool must exist
  /// @param _pool The address of the pool for which the dynamic fee is being reset
  function resetDynamicFee(address _pool) external;

  /// @notice Sets the new secondsAgo
  /// @dev Must be called by the current fee manager
  /// @param _secondsAgo The new secondsAgo for price change calculation
  function setSecondsAgo(uint32 _secondsAgo) external;

  /// @notice Sets the MEV tax module address.
  /// @dev Must be called by the current fee manager.
  /// @param _mevTaxModule The new MEV tax module contract addres
  function setMevTaxModule(address _mevTaxModule) external;

  /// @notice Bulk updates the fee for the passed in pools
  /// @dev Must be called by the current fee manager
  /// @param _pools The pool addresses which are going to be updated (must be a valid pool)
  /// @param _fees The fees to be set on the pools
  function bulkUpdateFees(address[] calldata _pools, uint24[] calldata _fees) external;

  /// @notice Bulk updates the feeCaps for the passed in pools
  /// @dev Must be called by the current fee manager
  /// @param _pools The pool addresses which are going to be updated (must be a valid pool)
  /// @param _feeCaps The feeCaps to be set on the pools
  function bulkUpdateFeeCaps(address[] calldata _pools, uint24[] calldata _feeCaps) external;

  /// @notice Bulk updates the scaling factor for the passed in pools
  /// @dev Must be called by the current fee manager
  /// @dev Must set feeCap first
  /// @param _pools The pool addresses which are going to be updated (must be a valid pool)
  /// @param _scalingFactors The scaling factors to be set on the pools
  function bulkUpdateScalingFactors(address[] calldata _pools, uint64[] calldata _scalingFactors) external;

  /// @notice Sets a custom initial fee for a given pool and enables it
  /// @dev Must be called by the current fee manager
  /// @dev Pool must exist
  /// @param _pool The pool address
  /// @param _fee The initial fee to set (0 = use baseFee, ZERO_FEE_INDICATOR = explicit 0 fee)
  function setInitialFee(address _pool, uint24 _fee) external;

  /// @notice Disables the initial fee for a given pool
  /// @dev Must be called by the current fee manager
  /// @dev Pool must exist
  /// @param _pool The pool address
  function disableInitialFee(address _pool) external;

  /*////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/

  /// @notice Returns the custom fee for a given pool if set, otherwise returns 0
  /// @dev Can use default fee by setting the fee to 0, can set zero fee by setting default fee to ZERO_FEE_INDICATOR
  /// @param _pool The pool to get the custom fee for
  /// @return The custom fee for the given pool
  function customFee(address _pool) external view returns (uint24);

  /*////////////////////////////////////////////////////////////
                              STORAGE
  ////////////////////////////////////////////////////////////*/

  /// @notice The global default scaling factor used when a pool does not have its own.
  /// @return _defaultScalingFactor The current default scaling factor.
  function defaultScalingFactor() external view returns (uint256 _defaultScalingFactor);

  /// @notice The global default fee cap used when a pool does not have its own.
  /// @return _defaultFeeCap The current default fee cap.
  function defaultFeeCap() external view returns (uint256 _defaultFeeCap);

  /// @notice The time window (in seconds) used to calculate the price deviation for the dynamic fee.
  /// @return _secondsAgo The current `secondsAgo` value.
  function secondsAgo() external view returns (uint32 _secondsAgo);

  /// @notice Returns the complete dynamic fee configuration for a pool.
  /// @param _pool The address of the pool.
  /// @return _baseFee The static fee.
  /// _feeCap The maximum total fee.
  /// _scalingFactor The scaling factor K.
  /// _initialFeeEnabled Whether the initial fee override is active.
  /// _initialFee The initial fee value (0 = base, ZERO_FEE_INDICATOR = 0%).
  function dynamicFeeConfig(address _pool)
    external
    view
    returns (uint24 _baseFee, uint24 _feeCap, uint64 _scalingFactor, bool _initialFeeEnabled, uint24 _initialFee);

  /// @notice The total non-discounted fee for the given `_pool` for the current `_blockNumber`.
  /// @param _pool The address of the pool.
  /// @param _blockNumber The number of the block for which the fee is stored.
  /// @return _blockFee The appplied to all swaps in the pool in the block.
  function blockFee(address _pool, uint256 _blockNumber) external view returns (uint256 _blockFee);

  /// @notice Returns the current MEV tax module.
  /// @return _mevTaxModule The current MEV tax module contract.
  function mevTaxModule() external view returns (IMevTaxModule _mevTaxModule);

  /*////////////////////////////////////////////////////////////
                              CONSTANTS
  ////////////////////////////////////////////////////////////*/

  /// @notice The factory contract that manages pools.
  /// @return _factory The `ICLFactory` instance.
  function FACTORY() external view returns (ICLFactory _factory);

  /// @notice The minimum allowed time window for price observations (1 second).
  /// @return _minSecondsAgo The minimum seconds ago constant.
  function MIN_SECONDS_AGO() external pure returns (uint32 _minSecondsAgo);

  /// @notice The maximum allowed time window (65535 * MIN_SECONDS_AGO ≈ 18.2 hours).
  /// @return _maxSecondsAgo The maximum seconds ago constant.
  function MAX_SECONDS_AGO() external pure returns (uint32 _maxSecondsAgo);

  /// @notice The maximum allowed base fee (3% in pips).
  /// @return _maxBaseFee The maximum base fee constant (30_000).
  function MAX_BASE_FEE() external pure returns (uint256 _maxBaseFee);

  /// @notice Special indicator used to explicitly set a fee to 0%.
  /// @return _zeroFeeIndicator The zero-fee indicator value (55_555).
  function ZERO_FEE_INDICATOR() external pure returns (uint256 _zeroFeeIndicator);

  /// @notice The maximum allowed scaling factor (1e18).
  /// @return _maxScalingFactor The maximum scaling factor.
  function MAX_SCALING_FACTOR() external pure returns (uint256 _maxScalingFactor);

  /// @notice The precision used for scaling factor arithmetic (1e6).
  /// @return The scaling precision.
  function SCALING_PRECISION() external pure returns (uint256);

  /// @notice The maximum fee cap that can be set (5% in pips).
  /// @return _maxFeeCap The maximum fee cap (50_000).
  function MAX_FEE_CAP() external pure returns (uint256 _maxFeeCap);
}
