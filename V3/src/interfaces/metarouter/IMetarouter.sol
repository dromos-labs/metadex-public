// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';

/**
 * @title IMetarouter
 * @notice External surface, errors and events for the Metarouter and its command groups.
 */
interface IMetarouter {
  // ============================== Types ==============================

  /**
   * @notice How a command spends an asset balance available to the execution address.
   * @param Amount Spend an exact asset amount.
   * @param Pips Spend a fraction of the current balance expressed in millionths.
   */
  enum SpendMode {
    Amount,
    Pips
  }

  /**
   * @notice Selects how much of an execution-address asset balance a command spends.
   * @param mode Balance-resolution mode.
   * @param value Exact asset amount for `Amount`, or pip value for `Pips`.
   */
  struct BalanceSpend {
    SpendMode mode;
    uint256 value;
  }

  /**
   * @notice Inputs for an exact-input V2 or CL swap command.
   * @param pools Forward-ordered pools in the swap route.
   * @param tokenIn Input token for the first pool.
   * @param amountIn Input balance specification.
   * @param payerIsUser Whether the execution owner funds the route input.
   * @param minAmountOut Minimum output the recipient must receive. On V2 routes the bound is enforced against both
   *        the router's own quote of the final hop and the recipient's balance delta; on CL routes it is enforced
   *        against the pool-reported output.
   * @param recipient Address that receives the final output.
   */
  struct SwapExactInParams {
    address[] pools;
    address tokenIn;
    BalanceSpend amountIn;
    bool payerIsUser;
    uint256 minAmountOut;
    address recipient;
  }

  /**
   * @notice Inputs for an exact-output V2 or CL swap command.
   * @param pools Forward-ordered pools in the swap route.
   * @param tokenIn Input token for the first pool.
   * @param amountOut Exact output the recipient must receive.
   * @param payerIsUser Whether the execution owner funds the route input.
   * @param maxAmountIn Maximum input the payer may spend.
   * @param recipient Address that receives the final output.
   */
  struct SwapExactOutParams {
    address[] pools;
    address tokenIn;
    uint256 amountOut;
    bool payerIsUser;
    uint256 maxAmountIn;
    address recipient;
  }

  /**
   * @notice Settlement authorization forwarded to the active CL swap callback.
   * @dev With no remaining pools the payer settles the invoice directly; otherwise the callback swaps the previous
   *      route pool for the exact invoiced amount, recursing hop by hop until the first pool is paid.
   * @param pools Route pools, of which only the first `remaining` are still unexecuted.
   * @param zeroForOne Whether token0 is exchanged for token1 for each route pool.
   * @param remaining Number of unexecuted route pools left before the payer settles directly.
   * @param tokenIn Token the payer owes.
   * @param payer Address authorized to pay.
   * @param maxAmountIn Maximum token input the payer may transfer.
   */
  struct ClSwapCallbackData {
    address[] pools;
    bool[] zeroForOne;
    uint256 remaining;
    address tokenIn;
    address payer;
    uint256 maxAmountIn;
  }

  /**
   * @notice Selects the destination Hyperlane interchain account configuration used by a cross-chain command.
   * @dev An empty configuration (`router == address(0)` and `ism == address(0)`) resolves both values from the
   *      interchain account router's enrolled defaults. A non-zero `router` selects a custom preserved
   *      configuration, where a zero `ism` intentionally delegates verification to Hyperlane's default ISM while
   *      remaining zero in the account derivation.
   * @param router Custom destination interchain account router, or zero to use the enrolled configuration.
   * @param ism Custom destination interchain security module; may be zero when `router` is non-zero.
   */
  struct IcaConfig {
    address router;
    address ism;
  }

  /**
   * @notice Inputs for the `BRIDGE_TOKEN` command.
   * @param token Token being bridged, or zero for native.
   * @param bridge Caller-selected Warp Route.
   * @param spend Balance selection funding the bridge.
   * @param messageFee Native message fee for an ERC20 bridge.
   * @param maxFee Maximum accepted token-denominated bridge fee: an absolute token amount for `Amount`, or a fraction
   *        of the resolved bridge amount in millionths, rounded up, for `Pips`.
   * @param domain Destination Hyperlane domain.
   * @param recipient Destination recipient, the zero address derives the logical sender's interchain account.
   * @param icaConfig Optional custom destination ICA router and ISM.
   */
  struct BridgeTokenParams {
    address token;
    address bridge;
    BalanceSpend spend;
    uint256 messageFee;
    BalanceSpend maxFee;
    uint32 domain;
    address recipient;
    IcaConfig icaConfig;
  }

  /**
   * @notice Inputs for the `EXECUTE_CROSS_CHAIN` command.
   * @param domain Destination Hyperlane domain.
   * @param commitment Commitment to the destination calls.
   * @param messageFee Native message fee forwarded to Hyperlane.
   * @param tokenFee Maximum fee-token approval granted to Hyperlane.
   * @param hook Post-dispatch hook.
   * @param hookMetadata Metadata forwarded to the post-dispatch hook.
   * @param icaConfig Optional custom destination ICA router and ISM.
   */
  struct ExecuteCrosschainParams {
    uint32 domain;
    bytes32 commitment;
    uint256 messageFee;
    uint256 tokenFee;
    address hook;
    bytes hookMetadata;
    IcaConfig icaConfig;
  }

  /**
   * @notice Inputs for the `REDEEM` command.
   * @param spend Balance selection funding the redeem from the held `ReceiptToken`.
   * @param payerIsUser Whether to pull an exact `ReceiptToken` amount from the logical sender instead of the execution
   *        balance.
   * @param recipient Address that receives the minted `TOKEN` on root. The leaf cannot inspect that address on root or
   *        determine whether it safely accounts for deposits. In particular, `TOKEN` sent to a permissionless
   *        Metarouter can be swept by any caller, with no privileged recovery right for the redeemer.
   * @param gasLimit Execution gas reserved for the destination handler; the transport rejects zero.
   * @param refundRecipient Address the transport refunds the unspent `messageFee` to, or zero to name the Metarouter,
   *        which returns the excess with the batch's other unused funds. Name an address instead when the batch caller
   *        cannot receive native, since the closing refund reverts the batch in that case.
   * @param messageFee Native message fee forwarded to the dispatch.
   */
  struct RedeemParams {
    BalanceSpend spend;
    bool payerIsUser;
    address recipient;
    uint256 gasLimit;
    address refundRecipient;
    uint256 messageFee;
  }

  /**
   * @notice Arguments of a `MINT_CL_POSITION` command; the two pool tokens are funded independently before the mint.
   * @dev `token0`/`token1` must be sorted ascending, the ordering the position manager expects.
   * @param token0 First pool token, sorted ascending.
   * @param token1 Second pool token, sorted ascending.
   * @param tickSpacing Tick spacing identifying the pool alongside its tokens.
   * @param tickLower Lower tick of the position range.
   * @param tickUpper Upper tick of the position range.
   * @param spend0 Selection applied when funding `token0`.
   * @param spend1 Selection applied when funding `token1`.
   * @param payerIsUser0 Whether to pull an exact `token0` amount from the logical sender instead of the execution
   *        balance.
   * @param payerIsUser1 Whether to pull an exact `token1` amount from the logical sender instead of the execution
   *        balance.
   * @param amount0Min Minimum `token0` contributed, as a slippage bound.
   * @param amount1Min Minimum `token1` contributed, as a slippage bound.
   * @param recipient Address the minted position goes to; set it to the metarouter to keep the position in flight for a
   *        later command.
   * @param sqrtPriceX96 Price to initialize the pool with when it does not yet exist; ignored when zero.
   * @param deadline Timestamp after which the mint reverts.
   */
  struct MintClParams {
    address token0;
    address token1;
    int24 tickSpacing;
    int24 tickLower;
    int24 tickUpper;
    BalanceSpend spend0;
    BalanceSpend spend1;
    bool payerIsUser0;
    bool payerIsUser1;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
    uint160 sqrtPriceX96;
    uint256 deadline;
  }

  /**
   * @notice Arguments of an `INCREASE_CL_LIQUIDITY` command; the position's tokens are funded independently before the
   *         increase.
   * @dev The position's `token0`/`token1` are read from the position manager, so only the funding selection is passed.
   * @param tokenId Position to add liquidity to, or zero to use the in-flight position.
   * @param spend0 Selection applied when funding the position's `token0`.
   * @param spend1 Selection applied when funding the position's `token1`.
   * @param payerIsUser0 Whether to pull an exact `token0` amount from the logical sender instead of the execution
   *        balance.
   * @param payerIsUser1 Whether to pull an exact `token1` amount from the logical sender instead of the execution
   *        balance.
   * @param amount0Min Minimum `token0` contributed, as a slippage bound.
   * @param amount1Min Minimum `token1` contributed, as a slippage bound.
   * @param deadline Timestamp after which the increase reverts.
   */
  struct IncreaseClParams {
    uint256 tokenId;
    BalanceSpend spend0;
    BalanceSpend spend1;
    bool payerIsUser0;
    bool payerIsUser1;
    uint256 amount0Min;
    uint256 amount1Min;
    uint256 deadline;
  }

  /**
   * @notice Inputs for the ADD_LIQUIDITY command.
   * @param factory Approved pool factory that resolves, or creates, the pair's stable or volatile pool.
   * @param tokenA First token supplied by the caller. All fields ending in `A` refer to this token, regardless of the
   *        pool's canonical token order.
   * @param tokenB Second token supplied by the caller. All fields ending in `B` refer to this token.
   * @param createPool Whether a missing pool may be created; when false a pair with no pool reverts with
   *        `PoolNotFound`.
   * @param spendA Balance selection funding tokenA.
   * @param spendB Balance selection funding tokenB.
   * @param payerAIsUser Whether tokenA is pulled from the logical sender as an exact amount instead of the execution
   *        balance.
   * @param payerBIsUser Whether tokenB is pulled from the logical sender as an exact amount instead of the execution
   *        balance.
   * @param amountAMin Minimum tokenA the router commits to the pool after the optimal-amount trim. A fee-on-transfer
   *        token is not rejected, but the minimum bounds what the router commits, not what the pool receives, so the
   *        guarantee does not hold for it.
   * @param amountBMin Minimum tokenB the router commits to the pool after the optimal-amount trim. A fee-on-transfer
   *        token is not rejected, but the minimum bounds what the router commits, not what the pool receives, so the
   *        guarantee does not hold for it.
   * @param recipient Address the minted LP tokens are sent to.
   * @param liquidityMin Minimum LP tokens the pool must mint for the deposit. The pool mints from its received
   *        balances, so unlike the per-token minimums this bound holds even for a fee-on-transfer token. Zero disables
   *        this router-level bound; the pool still rejects a zero-liquidity mint.
   */
  struct AddLiquidityParams {
    address factory;
    address tokenA;
    address tokenB;
    bool createPool;
    BalanceSpend spendA;
    BalanceSpend spendB;
    bool payerAIsUser;
    bool payerBIsUser;
    uint256 amountAMin;
    uint256 amountBMin;
    address recipient;
    uint256 liquidityMin;
  }

  /**
   * @notice Inputs for the REMOVE_LIQUIDITY command.
   * @param pool Registered V2 pool whose LP tokens are burned; the pool contract is its own LP token.
   * @param lpSpend Balance selection funding the LP amount to burn.
   * @param payerIsUser Whether the LP is pulled from the logical sender as an exact amount instead of the execution
   *        balance.
   * @param amount0Min Minimum token0 the burn reports returning. A fee-on-transfer token is not rejected, but the
   *        minimum bounds what the burn reports, not what the recipient receives, so the guarantee does not hold
   *        for it.
   * @param amount1Min Minimum token1 the burn reports returning. A fee-on-transfer token is not rejected, but the
   *        minimum bounds what the burn reports, not what the recipient receives, so the guarantee does not hold
   *        for it.
   * @param recipient Address the underlying token0/token1 are sent to.
   */
  struct RemoveLiquidityParams {
    address pool;
    BalanceSpend lpSpend;
    bool payerIsUser;
    uint256 amount0Min;
    uint256 amount1Min;
    address recipient;
  }

  // ============================== Events ==============================

  /**
   * @notice Emitted when the outermost frame of a batch completes.
   * @param _sender Logical sender that owned the completed batch.
   */
  event BatchExecuted(address indexed _sender);

  // ============================== Errors ==============================

  /// @notice Thrown when an inbound asset reaches the router outside a batch.
  error BatchNotActive();

  /**
   * @notice Thrown when a command depends on a protocol contract this deployment was built without.
   * @param _commandType Command ID that is disabled on this deployment.
   */
  error CommandDisabled(uint256 _commandType);

  /// @notice Thrown when an external caller enters `execute()` while a batch is running.
  error ContractLocked();

  /// @notice Thrown when Metarouter is reached through delegatecall instead of a direct call.
  error DirectCallRequired();

  /// @notice Thrown when the batch deadline has passed.
  error Expired();

  /**
   * @notice Thrown when a command byte decodes to an undefined command ID.
   * @param _commandType Undefined command ID that was dispatched.
   */
  error InvalidCommandType(uint256 _commandType);

  /// @notice Thrown when ETH arrives from an unexpected sender outside a batch.
  error InvalidEthSender();

  /// @notice Thrown when a batch spends native ETH held before that batch started.
  error PreBatchNativeBalanceSpent();

  /// @notice Thrown when the router's native balance differs from its pre-batch balance after the closing refund.
  error NativeBalanceNotCleared();

  /**
   * @notice Thrown when a native ETH transfer fails, bubbling the callee's revert data.
   * @param _data Revert data returned by the failed low-level call.
   */
  error NativeTransferFailed(bytes _data);

  /**
   * @notice Thrown when the execution-address balance cannot cover a spend or minimum floor.
   * @param _asset ERC20 address, or address(0) for native ETH.
   */
  error InsufficientBalance(address _asset);

  /// @notice Thrown when a liquidity command's resolved token0 amount falls below its minimum.
  error InsufficientAmount0();

  /// @notice Thrown when a liquidity command's resolved token1 amount falls below its minimum.
  error InsufficientAmount1();

  /// @notice Thrown when an add-liquidity command's resolved tokenA amount falls below its minimum.
  error InsufficientAmountA();

  /// @notice Thrown when an add-liquidity command's resolved tokenB amount falls below its minimum.
  error InsufficientAmountB();

  /**
   * @notice Thrown when an add-liquidity command mints fewer LP tokens than requested.
   * @param _minimum Minimum LP tokens requested by the caller.
   * @param _minted LP tokens minted by the pool.
   */
  error InsufficientLiquidityMinted(uint256 _minimum, uint256 _minted);

  /// @notice Thrown when the commands and inputs arrays differ in length.
  error LengthMismatch();

  /// @notice Thrown when an external pull uses a router-balance spend mode.
  error InvalidSpendMode();

  /**
   * @notice Thrown when a pip spend exceeds 100%.
   * @param _pips Pip value that exceeded the 100% denominator.
   */
  error InvalidPips(uint256 _pips);

  /// @notice Thrown when a payment command names an invalid recipient.
  error InvalidRecipient();

  /// @notice Thrown when a claim or stake targets a gauge not registered with the Voter.
  error GaugeNotRegistered();

  /// @notice Thrown when a routed V2 gauge claim or withdrawal would incur a penalty without explicit user consent.
  error PenaltyNotAccepted();

  /// @notice Thrown when position ids are supplied for a gauge that does not support position-level claims.
  error InvalidGaugeType();

  /// @notice Thrown when an NFT arrives from a collection other than the canonical position manager.
  error InvalidNftSender();

  /// @notice Thrown when a position arrives from a sender the active command did not solicit it from.
  error UnexpectedNftSender();

  /// @notice Thrown when a command would arm an expected NFT sender while another authorization is still pending.
  error NftSenderNotCleared();

  /// @notice Thrown when a command would operate a router-held NFT that did not enter custody during the active batch.
  error NftNotInCustody();

  /// @notice Thrown when a tracked NFT still belongs to the router at batch closure.
  error NftNotCleared();

  /**
   * @notice Thrown when a producer command would leave a second NFT in flight before the first is consumed.
   */
  error InFlightNftPresent();

  /// @notice Thrown when a command references the in-flight NFT but none of the expected collection is in flight.
  error NoInFlightNft();

  /// @notice Thrown when a CL position command targets a position the logical sender does not own.
  error NotPositionOwner();

  /// @notice Thrown when a V2 fee claim targets a pool not registered with the FactoryRegistry.
  error PoolNotRegistered();

  /// @notice Thrown when a liquidity command selects a pool factory the FactoryRegistry has not approved.
  error FactoryNotApproved();

  /**
   * @notice Thrown when the factory resolves a pool that does not hold the requested token pair.
   * @param _pool Resolved pool address.
   */
  error PoolTokenMismatch(address _pool);

  /// @notice Thrown when the pair has no pool and the command may not create one.
  error PoolNotFound();

  /**
   * @notice Thrown when a root-only command (sAERO creation or relay deposit) runs on a leaf deployment.
   * @param _commandType Command ID that is root-only.
   */
  error NotRoot(uint256 _commandType);

  /**
   * @notice Thrown when a leaf-only command (redeem) runs on the root deployment.
   * @param _commandType Command ID that is leaf-only.
   */
  error NotLeaf(uint256 _commandType);

  /// @notice Thrown when a relay deposit targets an address the RelayFactory did not deploy, so it is not a real relay.
  error UnauthorizedRelay();

  /**
   * @notice Thrown when a relay reports a VoterPaymentsModule the staking escrow does not recognize (it lacks
   *         `VPM_ROLE`), so the router refuses to grant it the operator approval a deposit needs.
   */
  error UnauthorizedRelayVpm();

  /// @notice Thrown when a constructor dependency is the zero address.
  error ZeroAddress();

  /// @notice Thrown when the native ERC20 reports more decimals than the native asset's eighteen.
  error InvalidNativeErc20Decimals();

  /// @notice Thrown when the wrapped native token and the native ERC20 are the same address.
  error WethIsNativeErc20();

  /// @notice Thrown when a command resolves a zero asset amount to act on.
  error ZeroAmount();

  /// @notice Thrown when a cross-chain dispatch targets a domain with no interchain account router enrolled.
  error UnregisteredDomain();

  /// @notice Thrown when an interchain account configuration names an ISM without a custom destination router.
  error InvalidInterchainAccountConfig();

  /// @notice Thrown when a warp route's token fee exceeds the caller's accepted maximum.
  error TokenFeeExceedsMax();

  /**
   * @notice Thrown when a warp route's token fee equals or exceeds the amount being bridged, leaving nothing to
   *         deliver.
   */
  error TokenFeeExceedsAmount();

  /**
   * @notice Thrown when a caller-selected warp route quotes a total charge below the amount being bridged, which no
   *         honest route reports because the charge covers the delivered amount itself.
   */
  error InvalidBridgeQuote();

  /**
   * @notice Thrown when the caller-selected warp route does not manage the token being bridged: the route's `token()`
   *         does not equal the command's token, so it would pull or burn a different asset than the router approved.
   *         Guards an honest token/route mismatch; an untrusted route can still misreport, so this is not route trust.
   */
  error BridgeTokenMismatch();

  /// @notice Thrown when a cross-chain dispatch's hook metadata carries no refund address.
  error InvalidHookMetadata();

  /// @notice Thrown when an amount cannot be represented as a signed CL swap amount.
  error AmountOverflow();

  /**
   * @notice Thrown when a CL pool returns without consuming its callback authorization.
   * @param _pool Pool still stored as the expected callback caller.
   */
  error CallbackNotCleared(address _pool);

  /// @notice Thrown when an exact-output swap delivers a different output than the requested amount.
  error InvalidAmountOut();

  /// @notice Thrown when a callback does not contain exactly one positive token delta.
  error InvalidCallbackDeltas();

  /**
   * @notice Thrown when a caller is not the currently authorized CL pool.
   * @param _caller Unauthorized callback caller.
   */
  error InvalidCallbackCaller(address _caller);

  /// @notice Thrown when a pool path is empty or its adjacent tokens do not connect.
  error InvalidPath();

  /// @notice Thrown when a payer is neither the execution address nor the logical sender.
  error InvalidPayer();

  /**
   * @notice Thrown when a pool has no recorded factory or its recorded factory does not authenticate it.
   * @param _pool Invalid pool address.
   */
  error InvalidPool(address _pool);

  /**
   * @notice Thrown when a V2 pool's token balance is below its recorded input reserve.
   * @param _pool Pool with invalid reserves.
   */
  error InvalidReserves(address _pool);

  /// @notice Thrown when a CL swap reports a positive output-token delta.
  error InvalidSwapDeltas();

  /**
   * @notice Thrown when an exact-input swap receives less than its minimum.
   * @param _minimum Minimum output requested.
   * @param _received Actual output received.
   */
  error TooLittleReceived(uint256 _minimum, uint256 _received);

  /// @notice Thrown when a swap requires more input than the command authorized.
  error TooMuchRequested();

  // ============================== Functions ==============================

  /**
   * @notice Runs an ordered command batch as one atomic call.
   * @param _commands One byte per command, index-aligned with `_inputs`.
   * @param _inputs ABI-encoded arguments for each command.
   * @param _deadline Timestamp after which the batch reverts.
   */
  function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable;

  /**
   * @notice Pays the input token owed to the currently authenticated CL pool.
   * @param _amount0Delta Signed token0 amount owed to or sent by the pool.
   * @param _amount1Delta Signed token1 amount owed to or sent by the pool.
   * @param _data Callback payer and input authorization encoded by the active swap command.
   */
  function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data) external;

  /**
   * @notice Returns the account whose positions and approvals commands act for.
   * @return _sender Logical sender for the current batch.
   */
  function msgSender() external view returns (address _sender);

  // ============================== Variable getters ==============================

  /**
   * @notice Wrapped native token used by wrap and unwrap commands.
   * @return _weth The wrapped native token, or the zero address on a chain with no wrapped-native token, where
   *         `WRAP_ETH` and `UNWRAP_WETH` are disabled.
   */
  function WETH() external view returns (IWETH _weth);

  /**
   * @notice Leaf Voter used to validate gauge targets and resolve their reward contracts.
   * @dev The zero address on a lite deployment with no voting system, where the gauge staking and claim commands
   *      revert with `CommandDisabled`.
   * @return _leafVoter The leaf Voter.
   */
  function LEAF_VOTER() external view returns (ILeafVoter _leafVoter);

  /**
   * @notice Token delivered to recipients by a gauge-emissions claim on this chain: the `ReceiptToken` on leaf
   *         deployments, or the canonical `TOKEN` on root, where the receipt is redeemed for `TOKEN` in the same
   *         transaction.
   * @return _emissionToken The gauge-emissions token this router custodies and sweeps.
   */
  function EMISSION_TOKEN() external view returns (IERC20 _emissionToken);

  /**
   * @notice Canonical position manager for the CL positions the router stakes, unstakes, and holds.
   * @return _positionManager The concentrated-liquidity position manager.
   */
  function POSITION_MANAGER() external view returns (INonfungiblePositionManager _positionManager);

  /**
   * @notice Interchain account router used by the cross-chain commands to derive accounts and dispatch commitments.
   * @dev The zero address on a lite deployment with no cross-chain layer, where every command that derives an
   *      interchain account reverts with `CommandDisabled`. A `BRIDGE_TOKEN` naming a direct recipient never reads
   *      this router, so it stays available there.
   * @return _icaRouter The interchain account router.
   */
  function ICA_ROUTER() external view returns (IInterchainAccountRouter _icaRouter);

  /**
   * @notice Registry used to authenticate recorded swap pools and approved liquidity factories.
   * @return _factoryRegistry Factory registry used by swap commands.
   */
  function FACTORY_REGISTRY() external view returns (IFactoryRegistry _factoryRegistry);

  /**
   * @notice ERC20 entry point of the chain's native asset, on chains where one exists; the zero address elsewhere.
   * @dev The token's balance is the account's native balance expressed in the token's own decimals, so spend
   *      resolution caps it at the batch's own native converted through `NATIVE_ERC20_SCALE`: spending the full
   *      balance would drain the pre-batch native the batch must preserve and revert the closure.
   *      The closing sweep skips its entry point entirely and returns the batch's portion through the native refund,
   *      since some implementations reject a zero-value `transfer`; a recipient that rejects that refund is paid
   *      through this entry point instead. On implementations that reject value-less transfers the ERC20-style
   *      commands on this token revert mid-batch too; that is the token's own behavior, not the router's.
   *      Never transfer or pre-fund this token ahead of `execute`: provide it as `msg.value` or pull it through
   *      `FUND_ERC20` during the active batch. Value the router already holds when a batch opens counts as pre-batch
   *      native, is excluded from batch custody, and cannot be recovered.
   * @return _nativeErc20 The native ERC20, or the zero address when the chain has none.
   */
  function NATIVE_ERC20() external view returns (IERC20 _nativeErc20);

  /**
   * @notice Native value represented by one raw unit of the native ERC20, derived from the token's decimals.
   * @dev Some chains express the same native asset in different precisions per interface: eighteen decimals for
   *      `address.balance` and `msg.value`, the token's own decimals for `balanceOf` and `transfer`. Every place
   *      that mixes the two representations converts through this factor: the batch's spendable native — less any
   *      committed message fee — converts to the native ERC20 decimals rounding down, so a full spend can never reach the
   *      pre-batch native; a native refund paid through the native ERC20 also floors, leaving dust the token cannot
   *      express. One on an eighteen-decimal native ERC20, where both interfaces share raw values.
   * @return _nativeErc20Scale Native value per raw native ERC20 unit, or zero when the chain has no native ERC20.
   */
  function NATIVE_ERC20_SCALE() external view returns (uint256 _nativeErc20Scale);

  /**
   * @notice Whether this deployment is the root chain, where `VotingEscrow` and the Relay exist.
   * @dev Gates the root-only `CREATE_STAKE` and `DEPOSIT_RELAY` commands; derived at construction from whether the
   *      local chain id equals the orchestrator's `ROOT_CHAIN_ID`.
   * @return _isRoot True on the root deployment, false on a leaf.
   */
  function IS_ROOT() external view returns (bool _isRoot);

  /**
   * @notice VotingEscrow that `CREATE_STAKE` and `DEPOSIT_RELAY` act on, resolved from the root Voter's
   *         `VOTING_ESCROW()`; the zero address on a leaf deployment.
   * @return _stakingEscrow The VotingEscrow, or the zero address on a leaf.
   */
  function STAKING_ESCROW() external view returns (IVotingEscrow _stakingEscrow);

  /**
   * @notice Token `CREATE_STAKE` stakes into a new sAERO, resolved from `STAKING_ESCROW.TOKEN()`; zero on a leaf.
   * @return _stakingToken The staking token, or the zero address on a leaf.
   */
  function STAKING_TOKEN() external view returns (IERC20 _stakingToken);

  /**
   * @notice RelayFactory that `DEPOSIT_RELAY` authenticates a caller-selected relay against; the zero address on a
   *         leaf deployment, where the command is gated off.
   * @return _relayFactory The RelayFactory, or the zero address on a leaf.
   */
  function RELAY_FACTORY() external view returns (IRelayFactory _relayFactory);
}
