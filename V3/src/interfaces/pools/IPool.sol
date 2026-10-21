// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IPool
 * @notice Interface for the Pool contract, the abstract base shared by the Aerodrome V2 volatile and stable pools
 */
interface IPool {
  /*////////////////////////////////////////////////////////////
                            EVENTS
  ////////////////////////////////////////////////////////////*/

  /// @notice Emitted when fees are claimed by a liquidity provider
  /// @param sender Address that triggered the fee claim
  /// @param amount0 Amount of token0 fees collected
  /// @param amount1 Amount of token1 fees collected
  event Fees(address indexed sender, uint256 amount0, uint256 amount1);
  /// @notice Emitted when liquidity is minted
  /// @param sender Address that initiated the mint
  /// @param to Address that received the LP tokens
  /// @param amount0 Amount of token0 deposited
  /// @param amount1 Amount of token1 deposited
  event Mint(address indexed sender, address indexed to, uint256 amount0, uint256 amount1);
  /// @notice Emitted when liquidity is burned
  /// @param sender Address that initiated the burn
  /// @param to Address that received the underlying tokens
  /// @param amount0 Amount of token0 returned
  /// @param amount1 Amount of token1 returned
  event Burn(address indexed sender, address indexed to, uint256 amount0, uint256 amount1);
  /// @notice Emitted on every swap executed through the pool
  /// @param sender Address that initiated the swap
  /// @param to Address that received the output tokens
  /// @param amount0In Amount of token0 provided as input
  /// @param amount1In Amount of token1 provided as input
  /// @param amount0Out Amount of token0 sent as output
  /// @param amount1Out Amount of token1 sent as output
  event Swap(
    address indexed sender,
    address indexed to,
    uint256 amount0In,
    uint256 amount1In,
    uint256 amount0Out,
    uint256 amount1Out
  );
  /// @notice Emitted when reserves are synced to the current balances
  /// @param reserve0 Updated reserve of token0
  /// @param reserve1 Updated reserve of token1
  event Sync(uint256 reserve0, uint256 reserve1);

  /// @notice Emitted when accumulated fee tokens are claimed
  /// @param caller Address that triggered the claim
  /// @param account Address whose accumulated fees were claimed
  /// @param recipient Address that received the fee tokens
  /// @param amount0 Amount of token0 claimed
  /// @param amount1 Amount of token1 claimed
  event Claim(
    address indexed caller, address indexed account, address indexed recipient, uint256 amount0, uint256 amount1
  );
  /// @notice Emitted when an account grants or revokes claim approval for an operator
  /// @param account Account whose approval state changed
  /// @param operator Operator being approved or revoked
  /// @param approved New approval state
  event ClaimApproval(address indexed account, address indexed operator, bool approved);
  /// @notice Emitted whenever `observationCardinalityNext` is increased
  /// @param caller Address that triggered the cardinality growth
  /// @param observationCardinalityNextOld Previous value of `observationCardinalityNext`
  /// @param observationCardinalityNextNew New value of `observationCardinalityNext`
  event IncreaseObservationCardinalityNext(
    address indexed caller, uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew
  );

  /*////////////////////////////////////////////////////////////
                            ERRORS
  ////////////////////////////////////////////////////////////*/

  /// @notice Thrown when the factory address has already been set and cannot be changed
  error FactoryAlreadySet();
  /// @notice Thrown when the input amount provided to a swap is zero or insufficient
  error InsufficientInputAmount();
  /// @notice Thrown when the pool does not have enough liquidity to fulfil the operation
  error InsufficientLiquidity();
  /// @notice Thrown when burning LP tokens would return zero of at least one underlying token
  error InsufficientLiquidityBurned();
  /// @notice Thrown when minting would produce zero LP tokens
  error InsufficientLiquidityMinted();
  /// @notice Thrown when the output amount of a swap is zero or below the requested minimum
  error InsufficientOutputAmount();
  /// @notice Thrown when the `to` address supplied to swap or burn is one of the pool's tokens
  error InvalidTo();
  /// @notice Thrown when an operation is attempted while the pool is paused
  error IsPaused();
  /// @notice Thrown when the invariant K check fails after a swap
  error K();
  /// @notice Thrown when the caller is neither the account nor an approved claim operator
  error NotAuthorized();
  /// @notice Thrown when a zero address is supplied where a non-zero address is required
  error ZeroAddress();
  /*////////////////////////////////////////////////////////////
                        EXTERNAL FUNCTIONS
  ////////////////////////////////////////////////////////////*/
  /// @notice Grants or revokes an operator's permission to claim the caller's accumulated fees
  /// @param _operator Operator whose approval is updated
  /// @param _approved Whether the operator is approved
  function approveForClaim(address _operator, bool _approved) external;

  /// @notice Claims the caller's accumulated fees
  /// @param _recipient Address that receives the claimed fee tokens
  /// @return _amount0 Amount of token0 claimed
  /// @return _amount1 Amount of token1 claimed
  function claimFees(address _recipient) external returns (uint256 _amount0, uint256 _amount1);

  /// @notice Claims an account's accumulated fees
  /// @dev The caller must be `_account` or an operator approved by `_account`
  /// @param _account Account whose accumulated fees are claimed
  /// @param _recipient Address that receives the claimed fee tokens
  /// @return _amount0 Amount of token0 claimed
  /// @return _amount1 Amount of token1 claimed
  function claimFees(address _account, address _recipient) external returns (uint256 _amount0, uint256 _amount1);

  /// @notice Returns the value of K in the Pool, based on its reserves.
  function getK() external returns (uint256);

  /// @notice Set pool name
  ///         Only callable by IPoolFactory(factory).poolAdmin()
  /// @param __name String of new name
  function setName(string calldata __name) external;

  /// @notice Set pool symbol
  ///         Only callable by IPoolFactory(factory).poolAdmin()
  /// @param __symbol String of new symbol
  function setSymbol(string calldata __symbol) external;

  /// @notice This low-level function should be called from a contract which performs important safety checks
  /// @param amount0Out Amount of token0 to send to `to`
  /// @param amount1Out Amount of token1 to send to `to`
  /// @param to Address to recieve the swapped output
  /// @param data Additional calldata for flashloans
  function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;

  /// @notice This low-level function should be called from a contract which performs important safety checks
  ///         standard uniswap v2 implementation
  /// @param to Address to receive token0 and token1 from burning the pool token
  /// @return amount0 Amount of token0 returned
  /// @return amount1 Amount of token1 returned
  function burn(address to) external returns (uint256 amount0, uint256 amount1);

  /// @notice This low-level function should be called by addLiquidity functions in Router.sol, which performs important safety checks
  ///         standard uniswap v2 implementation
  /// @param to Address to receive the minted LP token
  /// @return liquidity Amount of LP token minted
  function mint(address to) external returns (uint256 liquidity);

  /// @notice Force balances to match reserves
  /// @param to Address to receive any skimmed rewards
  function skim(address to) external;

  /// @notice Force reserves to match balances
  function sync() external;

  /// @notice Called on pool creation by the owning PoolFactory
  /// @param _token0 Address of token0
  /// @param _token1 Address of token1
  function initialize(address _token0, address _token1) external;

  /// @notice Pre-allocates buffer slots increasing the buffer capacity
  /// @param _observationCardinalityNext New target capacity. At most 65,535.
  function increaseObservationCardinalityNext(uint16 _observationCardinalityNext) external;

  /*////////////////////////////////////////////////////////////
                      PURE AND VIEW FUNCTIONS
  ////////////////////////////////////////////////////////////*/
  /// @notice Returns the decimal (dec), reserves (r), and tokens (t) of token0 and token1
  function metadata() external view returns (uint256 dec0, uint256 dec1, uint256 r0, uint256 r1, address t0, address t1);

  /// @notice Returns [token0, token1]
  function tokens() external view returns (address, address);

  /// @notice Returns accumulated but unclaimed fees for an account.
  /// @param _account Address to query.
  /// @return _amount0 Pending token0 fees.
  /// @return _amount1 Pending token1 fees.
  function pendingFees(address _account) external view returns (uint256 _amount0, uint256 _amount1);

  /// @notice Address of token in the pool with the lower address value
  function token0() external view returns (address);

  /// @notice Address of token in the pool with the higher address value
  function token1() external view returns (address);

  /// @notice Address of linked PoolFees.sol
  function poolFees() external view returns (address);

  /// @notice Address of PoolFactory that created this contract
  function factory() external view returns (address);

  /// @notice Period gate for new observations, in seconds. A new observation is written when more
  ///         than `PERIOD_SIZE` seconds have passed since the last one, so the smallest possible
  ///         spacing between two stored observations is `PERIOD_SIZE + 1` (i.e. 61 seconds at the
  ///         default value of 60).
  function PERIOD_SIZE() external view returns (uint256);

  /// @notice The pool type identifier
  /// @return The pool type label to be able to identify the type of pool
  function POOL_TYPE() external view returns (bytes32);

  /// @notice Amount of token0 in pool
  function reserve0() external view returns (uint256);

  /// @notice Amount of token1 in pool
  function reserve1() external view returns (uint256);

  /// @notice Timestamp of last update to pool
  function blockTimestampLast() external view returns (uint256);

  /// @notice Cumulative of reserve0 factoring in time elapsed
  function reserve0CumulativeLast() external view returns (uint256);

  /// @notice Cumulative of reserve1 factoring in time elapsed
  function reserve1CumulativeLast() external view returns (uint256);

  /// @notice Accumulated fees of token0 (global)
  function index0() external view returns (uint256);

  /// @notice Accumulated fees of token1 (global)
  function index1() external view returns (uint256);

  /// @notice Get an LP's relative index0 to index0
  function supplyIndex0(address) external view returns (uint256);

  /// @notice Get an LP's relative index1 to index1
  function supplyIndex1(address) external view returns (uint256);

  /// @notice Amount of unclaimed, but claimable tokens from fees of token0 for an LP
  function claimable0(address) external view returns (uint256);

  /// @notice Amount of unclaimed, but claimable tokens from fees of token1 for an LP
  function claimable1(address) external view returns (uint256);

  /// @notice Whether an operator may claim an account's accumulated fees
  /// @param _account Account that owns the accumulated fees
  /// @param _operator Operator whose approval is queried
  /// @return _approved Whether the operator is approved
  function approvedForClaim(address _account, address _operator) external view returns (bool _approved);

  /// @notice Produces the cumulative price using counterfactuals to save gas and avoid a call to sync.
  function currentCumulativePrices()
    external
    view
    returns (uint256 reserve0Cumulative, uint256 reserve1Cumulative, uint256 blockTimestamp);

  /// @notice Update reserves and, on the first call per block, price accumulators
  /// @return _reserve0 .
  /// @return _reserve1 .
  /// @return _blockTimestampLast .
  function getReserves() external view returns (uint256 _reserve0, uint256 _reserve1, uint256 _blockTimestampLast);

  /// @notice Get the amount of tokenOut given the amount of tokenIn, charging only the base fee
  /// @dev Does not charge the MEV tax, so the result can be higher than what `swap` pays out.
  ///      Use `getAmountOutWithTotalFee` to quote a swap.
  /// @param amountIn Amount of token in
  /// @param tokenIn Address of token
  /// @return Amount out
  function getAmountOut(uint256 amountIn, address tokenIn) external view returns (uint256);

  /// @notice Get the amount of tokenOut given the amount of tokenIn, charging the total fees
  /// @param amountIn Amount of token in
  /// @param tokenIn Address of token in
  /// @return Amount out
  function getAmountOutWithTotalFee(uint256 amountIn, address tokenIn) external view returns (uint256);

  /// @notice Get the amount of tokenIn required to receive the amount of tokenOut, charging the total fees
  /// @dev Reverts if the exact output cannot be calculated
  /// @param amountOut Amount of token out to receive
  /// @param tokenOut Address of token out
  /// @return Amount in, fee included
  function getAmountInWithTotalFee(uint256 amountOut, address tokenOut) external view returns (uint256);

  /// @notice Returns the cumulative reserves as of each requested `secondsAgo`. Reverts when any
  ///         `secondsAgos[i]` predates the oldest stored observation.
  /// @dev Offsets between two stored observations are linearly interpolated. Observations are
  ///      period-gated, so reserve changes within an interval may go unrecorded, making the
  ///      interpolation an approximation. Read from the pool directly when an exact value is required.
  /// @dev A point newer than the newest stored observation is estimated from the current cumulative
  ///      instead of two stored ones, so a trade after that point can change what it reads. It stops
  ///      changing once an observation is stored at or after that point. Points that already fall
  ///      between two stored observations read the same on every call.
  /// @param secondsAgos Array of seconds offsets from `block.timestamp` to query
  /// @return reserve0Cumulatives Cumulative reserve0 values at each requested point
  /// @return reserve1Cumulatives Cumulative reserve1 values at each requested point
  function observe(uint32[] calldata secondsAgos)
    external
    view
    returns (uint256[] memory reserve0Cumulatives, uint256[] memory reserve1Cumulatives);

  /// @notice Quote `amountIn` of `tokenIn` against a custom reserve snapshot
  /// @dev Subtracts the base fee from `amountIn` before applying the curve. Does not charge the MEV
  ///      tax, so use `getAmountOutWithTotalFee` to quote a swap.
  /// @param amountIn Input amount in the smallest unit of `tokenIn`
  /// @param tokenIn Address of the input token
  /// @param _reserve0 Reserve of token0 to quote against
  /// @param _reserve1 Reserve of token1 to quote against
  /// @return Output amount the swap would produce against the supplied reserves
  function getAmountOut(
    uint256 amountIn,
    address tokenIn,
    uint256 _reserve0,
    uint256 _reserve1
  ) external view returns (uint256);

  /// @notice TWAP circular buffer metadata
  /// @return index Index of the most recent observation in the buffer
  /// @return cardinality Number of populated slots in the buffer
  /// @return cardinalityNext Number of slots that can be written
  function observationBuffer() external view returns (uint16 index, uint16 cardinality, uint16 cardinalityNext);

  /// @notice Returns the observation at the given index
  /// @param index Index of the observation to return
  /// @return timestamp Timestamp of the observation
  /// @return reserve0Cumulative Cumulative reserve0 of the observation
  /// @return reserve1Cumulative Cumulative reserve1 of the observation
  function observations(uint256 index)
    external
    view
    returns (uint32 timestamp, uint256 reserve0Cumulative, uint256 reserve1Cumulative);
}
