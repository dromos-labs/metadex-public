// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IPoolTape} from 'V3/interfaces/pools/tape/IPoolTape.sol';

/**
 * @title IPoolFactory
 * @notice Interface for the PoolFactory contract, the abstract base shared by the Aerodrome V2 volatile and stable pool factories
 */
interface IPoolFactory {
  /*////////////////////////////////////////////////////////////
                            EVENTS
  ////////////////////////////////////////////////////////////*/
  event SetFeeManager(address indexed feeManager);
  event SetPauser(address indexed pauser);
  event SetPauseState(bool indexed state);
  event SetPoolAdmin(address indexed poolAdmin);
  event PoolCreated(address indexed token0, address indexed token1, address pool, uint256);
  event SetDefaultFee(uint256 defaultFee);
  /// @notice Emitted when the fee module and the gas limit forwarded to it are set.
  /// @param feeModule The new fee module address.
  /// @param gasLimit The gas limit forwarded to the module on each read.
  event SetFeeModule(address indexed feeModule, uint32 gasLimit);
  event SetDiscountRegistryManager(address indexed discountRegistryManager);
  event SetDiscountRegistry(address indexed discountRegistry);

  /// @notice Emitted when the pool tape module and the gas limit forwarded to it are set.
  /// @param poolTape The new pool tape address. The zero address disables the pool tape.
  /// @param gasLimit The gas limit forwarded to the tape on each record.
  event SetPoolTape(address indexed poolTape, uint32 gasLimit);

  /// @notice Emitted when the pool tape manager is set.
  /// @param poolTapeManager The new pool tape manager.
  event SetPoolTapeManager(address indexed poolTapeManager);

  /// @notice Emitted when the MEV tax module and the gas limit forwarded to it are set.
  /// @param mevTaxModule The new MEV tax module address. The zero address disables the MEV tax.
  /// @param gasLimit The gas limit forwarded to the module on each read.
  event SetMevTaxModule(address indexed mevTaxModule, uint32 gasLimit);

  /// @notice Emitted when the exact output fee quoter is set.
  /// @param exactOutFeeQuoter The new quoter address.
  event SetExactOutFeeQuoter(address indexed exactOutFeeQuoter);

  /*////////////////////////////////////////////////////////////
                            ERRORS
  ////////////////////////////////////////////////////////////*/
  error FeeTooHigh();
  /// @notice Reverts when the gas left in the frame is equal to or below the gas limit set for the external call.
  /// @dev EIP-150 forwards `min(_gasLimit, gasleft() - gasleft() / 64)`, so a transaction that sets its own gas
  ///      limit too low would leave the callee short. Stopping here keeps the outcome of the call independent of
  ///      the gas the caller supplied.
  error InsufficientGasForCall();
  /// @notice Thrown when the exact output fee quoter being set belongs to another factory.
  error InvalidExactOutFeeQuoter();
  error InvalidFeeModule();
  /// @notice Thrown when an exact output quote is requested while no exact output fee quoter is set.
  error NoExactOutFeeQuoter();
  error NotDiscountRegistryManager();
  error NotFeeManager();
  error NotPauser();
  error NotPoolAdmin();
  /// @notice Thrown when the caller is not the pool tape manager.
  error NotPoolTapeManager();
  error PoolAlreadyExists();
  error SameAddress();
  error ZeroFee();
  error ZeroAddress();
  /// @notice Thrown when a gas limit is set to zero.
  error ZeroGasLimit();

  /*////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/
  /// @notice Set pool administrator
  /// @dev Allowed to change the name and symbol of any pool created by this factory
  /// @param _poolAdmin Address of the pool administrator
  function setPoolAdmin(address _poolAdmin) external;

  /// @notice Set the pauser for the factory contract
  /// @dev The pauser can pause swaps on pools associated with the factory. Liquidity will always be withdrawable.
  /// @dev Must be called by the pauser
  /// @param _pauser Address of the pauser
  function setPauser(address _pauser) external;

  /// @notice Set discount registry manager
  /// @dev The discount registry manager can update the `discountRegistry` variable
  /// @param _discountRegistryManager Address of the discount registry manager
  function setDiscountRegistryManager(address _discountRegistryManager) external;

  /// @notice Set the discount registry for the factory contract
  /// @param _discountRegistry Address of the discount registry
  function setDiscountRegistry(address _discountRegistry) external;

  /// @notice Pause or unpause swaps on pools associated with the factory
  /// @param _state True to pause, false to unpause
  function setPauseState(bool _state) external;

  /// @notice Set the fee manager for the factory contract
  /// @dev The fee manager can set fees on pools associated with the factory.
  /// @dev Must be called by the fee manager
  /// @param _feeManager Address of the fee manager
  function setFeeManager(address _feeManager) external;

  /// @notice Updates the feeModule of the factory and the gas limit forwarded to it
  /// @dev Must be called by the current fee manager. Reverts if the gas limit set is zero.
  /// @param _feeModule The new feeModule of the factory
  /// @param _gasLimit The gas limit forwarded to the module on each read. Calculated as
  ///        `(usage + buffer) * 64 / 63` where `usage` is the most gas the module can spend and `buffer` is what
  ///        this factory spends checking the gas and dispatching the call. The `64 / 63` covers the share
  ///        EIP-150 withholds from the callee.
  function setFeeModule(address _feeModule, uint32 _gasLimit) external;

  /// @notice Set the default fee for pools created by this factory.
  /// @dev Throws if higher than maximum fee.
  ///      Throws if fee is zero.
  /// @param _defaultFee .
  function setDefaultFee(uint256 _defaultFee) external;

  /// @notice Create a pool for the given pair of tokens
  /// @dev token order does not matter
  /// @param tokenA .
  /// @param tokenB .
  function createPool(address tokenA, address tokenB) external returns (address pool);

  /// @notice Sets the pool tape manager role that controls the pool tape configuration.
  /// @dev Must be called by the current pool tape manager. The initial manager is set in the constructor.
  /// @param _poolTapeManager Address of the new pool tape manager.
  function setPoolTapeManager(address _poolTapeManager) external;

  /// @notice Sets or clears the pool tape module that the pool records data into, and the gas limit sent to it.
  /// @dev Must be called by the pool tape manager. The zero address disables the pool tape recording.
  /// @dev Reverts if the gas limit set is zero.
  /// @param _poolTape Address of the pool tape module.
  /// @param _gasLimit The gas limit forwarded to the tape on each record. Calculated as
  ///        `(usage + buffer) * 64 / 63` where `usage` is the most gas the tape can spend and `buffer` is what
  ///        this factory spends checking the gas and dispatching the call. The `64 / 63` covers the share
  ///        EIP-150 withholds from the callee.
  function setPoolTape(address _poolTape, uint32 _gasLimit) external;

  /// @notice Sets or clears the MEV tax module queried for the MEV tax on swaps, and the gas limit sent to it.
  /// @dev Must be called by the fee manager. The zero address disables the MEV tax.
  /// @dev Reverts if the gas limit set is zero.
  /// @param _mevTaxModule Address of the MEV tax module.
  /// @param _gasLimit The gas limit forwarded to the module on each read. Calculated as
  ///        `(usage + buffer) * 64 / 63` where `usage` is the most gas the module can spend and `buffer` is what
  ///        this factory spends checking the gas and dispatching the call. The `64 / 63` covers the share
  ///        EIP-150 withholds from the callee.
  function setMevTaxModule(address _mevTaxModule, uint32 _gasLimit) external;

  /// @notice Sets the quoter that resolves the fee of exact output quotes.
  /// @dev Must be called by the fee manager. Reverts on the zero address and when the quoter belongs to another
  ///      factory. Exact output quotes revert until a quoter is set.
  /// @param _exactOutFeeQuoter Address of the exact output fee quoter.
  function setExactOutFeeQuoter(address _exactOutFeeQuoter) external;

  /// @notice Forwards a pool's per-swap deltas to the pool tape, if one is set.
  /// @param _data The per-swap deltas to record.
  function recordPoolTape(IPoolTape.PoolTapeData calldata _data) external;

  /*////////////////////////////////////////////////////////////
                      PURE AND VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/
  /// @notice Return a single pool created by this factory
  /// @return Address of pool
  function allPools(uint256 index) external view returns (address);

  /// @notice Returns all pools created by this factory
  /// @return Array of pool addresses
  function allPools() external view returns (address[] memory);

  /// @notice Returns the number of pools created from this factory
  function allPoolsLength() external view returns (uint256);

  /// @notice Is a valid pool created by this factory.
  /// @param pool .
  function isPool(address pool) external view returns (bool);

  /// @notice Return address of pool created by this factory
  /// @param tokenA .
  /// @param tokenB .
  function getPool(address tokenA, address tokenB) external view returns (address);

  /// @notice Returns the base fee for a pool swap, accounting for custom fees set via the fee module.
  /// @dev A fee module value above `MAX_BASE_FEE` is ignored, falling back to `defaultFee`.
  /// @param _pool The pool to get the base fee for.
  /// @param _caller The swap initiator.
  /// @param _amount0In The token0 input amount of the swap, zero when token0 is not an input.
  /// @param _amount1In The token1 input amount of the swap, zero when token1 is not an input.
  /// @param _reserve0 The pre-swap token0 reserve of the pool.
  /// @param _reserve1 The pre-swap token1 reserve of the pool.
  /// @return The base fee in basis points.
  function getBaseFee(
    address _pool,
    address _caller,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256);

  /// @notice Returns the swap fee data for a pool swap, including the MEV tax.
  /// @dev The MEV tax is clamped so the total stays at or below `MAX_FEE`.
  /// @param _pool The pool to get the fee for.
  /// @param _sender The swap caller, the pool's msg.sender.
  /// @param _amount0In The token0 input amount of the swap, zero when token0 is not an input.
  /// @param _amount1In The token1 input amount of the swap, zero when token1 is not an input.
  /// @param _reserve0 The pre-swap token0 reserve of the pool.
  /// @param _reserve1 The pre-swap token1 reserve of the pool.
  /// @return _fee The combined swap fee in basis points.
  /// @return _mevFee The MEV share of the fee in basis points, rounded up.
  /// @return _toxic True when the swap is classified as toxic flow.
  function getFee(
    address _pool,
    address _sender,
    uint256 _amount0In,
    uint256 _amount1In,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee, uint256 _mevFee, bool _toxic);

  /// @notice Returns the total fee to gross up an exact output quote with, given the input the curve requires.
  /// @dev Reverts with `NoExactOutFeeQuoter` while no quoter is set and with `FeeTooHigh` when the quoter
  ///      answers above `MAX_FEE`.
  /// @param _pool The pool to get the fee for.
  /// @param _caller The swap initiator.
  /// @param _amount0InAfterFee The token0 input the curve requires after the fee, zero when token0 is not an input.
  /// @param _amount1InAfterFee The token1 input the curve requires after the fee, zero when token1 is not an input.
  /// @param _reserve0 The pre-swap token0 reserve of the pool.
  /// @param _reserve1 The pre-swap token1 reserve of the pool.
  /// @return _fee The total fee in basis points.
  function getFeeForAmountIn(
    address _pool,
    address _caller,
    uint256 _amount0InAfterFee,
    uint256 _amount1InAfterFee,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256 _fee);

  /// @notice The pool implementation used to create pools
  /// @return Address of pool implementation
  function implementation() external view returns (address);

  /// @notice The factory registry every created pool is recorded in as a target.
  /// @dev Set at construction. createPool reverts until this factory is an approved
  ///      target factory in the registry.
  /// @return Address of the factory registry.
  function factoryRegistry() external view returns (address);

  /// @notice Whether the pools associated with the factory are paused or not.
  /// @dev Pause only pauses swaps, liquidity will always be withdrawable.
  function isPaused() external view returns (bool);

  /// @notice The address of the pauser, can pause swaps on pools associated with factory.
  /// @return Address of the pauser
  function pauser() external view returns (address);

  /// @notice The default fee for pools created by this factory.
  /// @return Default fee
  function defaultFee() external view returns (uint256);

  /// @notice Hard-coded default fee value the factory variant is initialized with
  /// @dev Constant per variant. The mutable current value lives in `defaultFee()`.
  function DEFAULT_FEE() external view returns (uint256);

  /// @notice Maximum default fee the fee manager can set
  /// @return 3% in bips
  function MAX_DEFAULT_FEE() external view returns (uint256);

  /// @notice Maximum base fee the factory accepts from the fee module
  /// @return 10% in bips
  function MAX_BASE_FEE() external view returns (uint256);

  /// @notice Maximum total fee a swap can be charged, base fee plus MEV tax
  /// @return 20% in bips
  function MAX_FEE() external view returns (uint256);

  /// @notice Address of the fee manager, can set fees on pools associated with factory.
  /// @notice This overrides the default fee for that pool.
  /// @return Address of the fee manager
  function feeManager() external view returns (address);

  /// @notice Address of the fee module of the factory
  /// @dev Can be changed by the current fee manager via setFeeModule
  /// @return Address of the fee module
  function feeModule() external view returns (address);

  /// @notice The gas limit forwarded to the fee module on each read.
  /// @return _gasLimit The gas limit.
  function feeModuleGasLimit() external view returns (uint32 _gasLimit);

  /// @notice Address of the pool administrator, can change the name and symbol of pools created by factory.
  /// @return Address of the pool administrator
  function poolAdmin() external view returns (address);

  /// @notice Address of the discount registry manager, can update the `discountRegistry` variable
  /// @return Address of the discount registry manager
  function discountRegistryManager() external view returns (address);

  /// @notice Address of the discount registry, that allows querying swap fee discounts
  /// @return Address of the discount registry
  function discountRegistry() external view returns (address);

  /// @notice The pool tape module that pools record into. The zero address means recording is disabled.
  /// @return Address of the pool tape module.
  function poolTape() external view returns (address);

  /// @notice The gas limit forwarded to the pool tape on each record.
  /// @return _gasLimit The gas limit.
  function poolTapeGasLimit() external view returns (uint32 _gasLimit);

  /// @notice The pool tape manager, which controls the pool tape configuration.
  /// @return Address of the pool tape manager.
  function poolTapeManager() external view returns (address);

  /// @notice The MEV tax module queried to get the mev tax for a swap. The zero address means the MEV tax is disabled.
  /// @return Address of the MEV tax module.
  function mevTaxModule() external view returns (address);

  /// @notice The gas limit forwarded to the MEV tax module on each read.
  /// @return _gasLimit The gas limit.
  function mevTaxModuleGasLimit() external view returns (uint32 _gasLimit);

  /// @notice The quoter that resolves the fee of exact output quotes. Exact output quotes revert while unset.
  /// @return Address of the exact output fee quoter.
  function exactOutFeeQuoter() external view returns (address);
}
