// SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0
pragma solidity 0.8.36;

import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {IERC20Metadata} from '@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol';
import {SafeERC20} from '@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol';
import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {IERC721Receiver} from '@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol';

import {TransientTracking} from 'V3/metarouter/TransientTracking.sol';
import {ClPositionLib} from 'V3/metarouter/libraries/ClPositionLib.sol';
import {ClaimsLib} from 'V3/metarouter/libraries/ClaimsLib.sol';
import {Commands} from 'V3/metarouter/libraries/Commands.sol';
import {CrosschainLib} from 'V3/metarouter/libraries/CrosschainLib.sol';
import {FundsLib} from 'V3/metarouter/libraries/FundsLib.sol';
import {LiquidityLib} from 'V3/metarouter/libraries/LiquidityLib.sol';
import {MetarouterState} from 'V3/metarouter/libraries/MetarouterState.sol';
import {PaymentsLib} from 'V3/metarouter/libraries/PaymentsLib.sol';
import {StakeRelayLib} from 'V3/metarouter/libraries/StakeRelayLib.sol';
import {StakingLib} from 'V3/metarouter/libraries/StakingLib.sol';

import {IVotingEscrow} from 'V3/interfaces/core/IVotingEscrow.sol';
import {IInterchainAccountRouter} from 'V3/interfaces/external/IInterchainAccountRouter.sol';
import {INonfungiblePositionManager} from 'V3/interfaces/external/INonfungiblePositionManager.sol';
import {IWETH} from 'V3/interfaces/external/IWETH.sol';
import {IFactoryRegistry} from 'V3/interfaces/factories/IFactoryRegistry.sol';
import {IPoolFactory} from 'V3/interfaces/factories/IPoolFactory.sol';
import {IMetarouter} from 'V3/interfaces/metarouter/IMetarouter.sol';
import {ICLPool} from 'V3/interfaces/pools/ICLPool.sol';
import {IPool} from 'V3/interfaces/pools/IPool.sol';
import {IRelayFactory} from 'V3/interfaces/relay/IRelayFactory.sol';
import {ILeafVoter} from 'V3/interfaces/voter/ILeafVoter.sol';
import {IVoter} from 'V3/interfaces/voter/IVoter.sol';

/**
 * @title Metarouter
 * @notice Permissionless router for executing composable command batches with temporary asset custody,
 *         returning remaining batch ERC20 and native balances to the original caller when execution ends. Positions
 *         are not returned: one brought into custody must be sent onward by a later command, or closure reverts.
 * @dev Virtual functions allow future variants to inherit from this contract and override selected behavior.
 */
contract Metarouter is IMetarouter, IERC721Receiver {
  using SafeERC20 for IERC20;

  /// @notice Canonical pool-type label reported by V2 stable pools.
  bytes32 internal constant _V2_STABLE_POOL_TYPE = 'V2_STABLE';
  /// @notice Canonical pool-type label reported by V2 volatile pools.
  bytes32 internal constant _V2_VOLATILE_POOL_TYPE = 'V2_VOLATILE';
  /// @notice Canonical pool-type label reported by CL pools.
  bytes32 internal constant _CL_POOL_TYPE = 'CL';
  /// @notice Lowest usable CL square-root price, one unit above the pool boundary.
  uint160 internal constant _MIN_SQRT_RATIO_PLUS_ONE = 4_295_128_740;
  /// @notice Highest usable CL square-root price, one unit below the pool boundary.
  uint160 internal constant _MAX_SQRT_RATIO_MINUS_ONE =
    1_461_446_703_485_210_103_287_273_052_203_988_822_378_723_970_341;

  /// @notice Address this router was deployed at; `_checkExecutionContext` uses it to reject delegatecalls.
  address internal immutable _IMPLEMENTATION = address(this);

  /// @inheritdoc IMetarouter
  IWETH public immutable WETH;
  /// @inheritdoc IMetarouter
  ILeafVoter public immutable LEAF_VOTER;
  /// @inheritdoc IMetarouter
  IERC20 public immutable EMISSION_TOKEN;
  /// @inheritdoc IMetarouter
  INonfungiblePositionManager public immutable POSITION_MANAGER;
  /// @inheritdoc IMetarouter
  IInterchainAccountRouter public immutable ICA_ROUTER;
  /// @inheritdoc IMetarouter
  IFactoryRegistry public immutable FACTORY_REGISTRY;
  /// @inheritdoc IMetarouter
  bool public immutable IS_ROOT;
  /// @inheritdoc IMetarouter
  IVotingEscrow public immutable STAKING_ESCROW;
  /// @inheritdoc IMetarouter
  IERC20 public immutable STAKING_TOKEN;
  /// @inheritdoc IMetarouter
  IRelayFactory public immutable RELAY_FACTORY;
  /// @inheritdoc IMetarouter
  IERC20 public immutable NATIVE_ERC20;
  /// @inheritdoc IMetarouter
  uint256 public immutable NATIVE_ERC20_SCALE;

  /**
   * @notice Initializes the Metarouter.
   * @dev The emission token and the staking escrow are derived from the protocol, not passed. On root (this chain
   *      equals the leaf voter's orchestrator `ROOT_CHAIN_ID`) the emission token is the root Voter's `MINTER().TOKEN()`
   *      and the staking escrow is the root Voter's `VOTING_ESCROW()`, the canonical escrow `CREATE_STAKE` and
   *      `DEPOSIT_RELAY` act on; on leaf the emission token is the leaf voter's `RECEIPT_TOKEN` and the staking
   *      immutables stay zero. Derived values come from protocol contracts that validate them at their own
   *      construction, so only the constructor's own inputs are zero-checked here.
   *
   *      A lite deployment ships without the voting system and without the cross-chain layer, so `_leafVoter` and
   *      `_icaRouter` may be zero. A zero voter makes `IS_ROOT` false, leaves the emission token zero, and disables the
   *      gauge staking and claim commands; a zero ICA router disables `EXECUTE_CROSS_CHAIN` and the `BRIDGE_TOKEN`
   *      path that derives a destination interchain account. Those revert with `CommandDisabled` when dispatched,
   *      while a `BRIDGE_TOKEN` naming a direct recipient stays available.
   * @param _weth Wrapped native token used by payment commands. Zero on a chain with no wrapped-native token, where
   *        `WRAP_ETH` and `UNWRAP_WETH` revert with `CommandDisabled`. Never the native ERC20.
   * @param _leafVoter Leaf Voter used to validate gauge targets and, on leaf, to resolve the emission `ReceiptToken`.
   *        Zero on a lite deployment with no voting system, where the gauge staking and claim commands are disabled.
   * @param _rootVoter Root Voter used only on root to resolve the emission token and the staking escrow; unused on leaf.
   * @param _positionManager Canonical CL position manager the router stakes, unstakes, and holds positions through.
   * @param _icaRouter Interchain account router used by the cross-chain commands. Zero on a lite deployment with no
   *        cross-chain layer, where every command that derives an interchain account is disabled.
   * @param _relayFactory RelayFactory used only on root to authenticate `DEPOSIT_RELAY` relays; unused on leaf.
   * @param _factoryRegistry Registry used to authenticate recorded swap pools and approved liquidity factories.
   * @param _nativeErc20 ERC20 entry point of the chain's native asset, whose spend resolution and closing sweep are
   *        capped so they cannot drain the pre-batch native balance. Zero on a chain whose native asset has no ERC20
   *        entry point. A nonzero native ERC20 must report its decimals: the native-to-token scale is derived from
   *        them, so a native ERC20 expressing the native asset in fewer decimals than native's eighteen converts correctly.
   */
  constructor(
    IWETH _weth,
    ILeafVoter _leafVoter,
    IVoter _rootVoter,
    INonfungiblePositionManager _positionManager,
    IInterchainAccountRouter _icaRouter,
    IRelayFactory _relayFactory,
    IFactoryRegistry _factoryRegistry,
    IERC20 _nativeErc20
  ) {
    if (address(_positionManager) == address(0)) revert ZeroAddress();
    if (address(_factoryRegistry) == address(0)) revert ZeroAddress();
    WETH = _weth;
    LEAF_VOTER = _leafVoter;
    POSITION_MANAGER = _positionManager;
    ICA_ROUTER = _icaRouter;
    FACTORY_REGISTRY = _factoryRegistry;
    NATIVE_ERC20 = _nativeErc20;
    if (address(_nativeErc20) != address(0)) {
      // The two roles are incompatible: wrap and unwrap would drive `deposit`/`withdraw` on the native ERC20 while the
      // closing sweep treats the two tokens differently, so a collision is a misdeployment.
      if (address(_weth) == address(_nativeErc20)) revert WethIsNativeErc20();
      // Native balances always carry eighteen decimals; a native ERC20 may expose the same asset in fewer. Deriving the
      // scale from the token's own decimals keeps the two unit systems convertible without a separate parameter.
      uint8 _nativeErc20Decimals = IERC20Metadata(address(_nativeErc20)).decimals();
      if (_nativeErc20Decimals > 18) revert InvalidNativeErc20Decimals();
      NATIVE_ERC20_SCALE = 10 ** (18 - _nativeErc20Decimals);
    }
    // A lite deployment has no voter to ask, so it is never the root: the root-only commands stay gated off.
    IS_ROOT = address(_leafVoter) != address(0) && block.chainid == _leafVoter.ORCHESTRATOR().ROOT_CHAIN_ID();

    if (IS_ROOT) {
      if (address(_rootVoter) == address(0)) revert ZeroAddress();
      if (address(_relayFactory) == address(0)) revert ZeroAddress();
      EMISSION_TOKEN = IERC20(_rootVoter.MINTER().TOKEN());
      STAKING_ESCROW = _rootVoter.VOTING_ESCROW();
      STAKING_TOKEN = IERC20(address(STAKING_ESCROW.TOKEN()));
      RELAY_FACTORY = _relayFactory;
    } else {
      // Leaf: no VotingEscrow or Relay, so the staking immutables stay zero and IS_ROOT gates their commands off.
      // A lite deployment has no voter to resolve the receipt token from, so the emission token stays zero too.
      if (address(_leafVoter) != address(0)) EMISSION_TOKEN = IERC20(address(_leafVoter.RECEIPT_TOKEN()));
    }
  }

  /// @notice Accepts WETH withdrawals and native refunds received during an active batch.
  receive() external payable virtual {
    // WETH withdrawals are always accepted. Other native inflows are accepted only while an
    // outer batch is active and are returned at closure.
    if (msg.sender != address(WETH) && TransientTracking.load(MetarouterState.LOCKER_SLOT) == 0) {
      revert InvalidEthSender();
    }
  }

  /**
   * @inheritdoc IERC721Receiver
   * @dev Accepts a position only while a batch is active, only from the canonical position manager, and only when both
   *      the sender and the position match what the active command set through `MetarouterState.setExpectedNft`, then
   *      records the `(collection, tokenId)` pair for the closing ownership check. A CL gauge returns unstaked
   *      positions through `safeTransferFrom`, which is why the router implements the receiver.
   *
   *      This check is the custody boundary. A tracked position is one later commands may operate, so accepting an
   *      unsolicited transfer would let a third party hand the active batch authority over a position it never asked
   *      for. An unset slot reads zero and is rejected outright rather than compared, so a hook call reporting a zero
   *      `_from` cannot slip through while the router expects nothing. Matching the token id too keeps a misbehaving
   *      gauge from returning a different position than the one the command asked back.
   */
  function onERC721Received(
    address,
    address _from,
    uint256 _tokenId,
    bytes calldata
  ) external virtual returns (bytes4 _selector) {
    if (TransientTracking.load(MetarouterState.LOCKER_SLOT) == 0) revert BatchNotActive();
    if (msg.sender != address(POSITION_MANAGER)) revert InvalidNftSender();
    (address _expectedSender, uint256 _expectedTokenId) = MetarouterState.expectedNft();
    if (_expectedSender == address(0) || _from != _expectedSender || _tokenId != _expectedTokenId) {
      revert UnexpectedNftSender();
    }
    MetarouterState.trackNft(msg.sender, _tokenId);
    return IERC721Receiver.onERC721Received.selector;
  }

  // ============================== Execution ==============================

  /// @inheritdoc IMetarouter
  function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable virtual {
    _checkExecutionContext();
    if (_commands.length != _inputs.length) revert LengthMismatch();
    if (block.timestamp > _deadline) revert Expired();

    if (TransientTracking.load(MetarouterState.LOCKER_SLOT) != 0) {
      // While a batch is active, only the router's own self-called child frames may reenter.
      if (msg.sender != address(this)) revert ContractLocked();
      _executeCommands(_commands, _inputs);
      return;
    }

    _beginExecution();
    address _sender = MetarouterState.msgSender();
    _executeCommands(_commands, _inputs);
    _endExecution(_sender);
    emit BatchExecuted(_sender);
  }

  /// @inheritdoc IMetarouter
  function uniswapV3SwapCallback(int256 _amount0Delta, int256 _amount1Delta, bytes calldata _data) external virtual {
    _checkExecutionContext();
    // No locker check needed: the expected callback caller slot can only be armed while a batch swap is executing.
    address _expectedCaller = address(uint160(TransientTracking.load(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT)));
    if (msg.sender != _expectedCaller) revert InvalidCallbackCaller(msg.sender);
    TransientTracking.store(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT, 0);

    // Exactly one delta is positive: the token owed to the pool.
    bool _amount0Positive = _amount0Delta > 0;
    bool _amount1Positive = _amount1Delta > 0;
    if (_amount0Positive == _amount1Positive) revert InvalidCallbackDeltas();

    uint256 _amountToPay = uint256(_amount0Positive ? _amount0Delta : _amount1Delta);
    ClSwapCallbackData memory _callback = abi.decode(_data, (ClSwapCallbackData));

    // Settle the invoice by swapping the previous route pool's exact output straight to the caller.
    if (_callback.remaining > 0) {
      uint256 _hop = --_callback.remaining;
      // The caller pool verifies its own balance afterwards, so a partial inner fill makes it revert.
      _clSwap(
        _callback.pools[_hop], _callback.zeroForOne[_hop], -int256(_amountToPay), msg.sender, abi.encode(_callback)
      );
      return;
    }

    // Reverts if the pool requests more than the authorized maximum.
    if (_amountToPay > _callback.maxAmountIn) revert TooMuchRequested();
    FundsLib.pay(_callback.tokenIn, _callback.payer, msg.sender, _amountToPay);
  }

  /// @inheritdoc IMetarouter
  function msgSender() external view virtual override returns (address _sender) {
    return MetarouterState.msgSender();
  }

  /**
   * @notice Executes commands without opening or closing another custody frame.
   * @param _commands One command byte per input.
   * @param _inputs ABI-encoded arguments corresponding to each command byte.
   */
  function _executeCommands(bytes calldata _commands, bytes[] calldata _inputs) internal virtual {
    uint256 _length = _commands.length;
    for (uint256 _i; _i < _length; ++_i) {
      (uint256 _commandType, bool _allowRevert) = _decode(_commands[_i]);
      if (!_allowRevert) {
        _dispatch(_commandType, _inputs[_i]);
      } else {
        bytes memory _childCommands = abi.encodePacked(bytes1(uint8(_commandType)));
        bytes[] memory _childInputs = new bytes[](1);
        _childInputs[0] = _inputs[_i];
        // Run in a fresh frame so a failure rolls back the command's state changes while the batch continues.
        try this.execute(_childCommands, _childInputs, type(uint256).max) {} catch {}
      }
    }
  }

  /**
   * @notice Opens the batch: records the outer caller as locker, snapshots the pre-batch native balance, and
   *         publishes the native ERC20 for balance resolution.
   */
  function _beginExecution() internal virtual {
    TransientTracking.store(MetarouterState.LOCKER_SLOT, uint256(uint160(msg.sender)));
    TransientTracking.store(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT, address(this).balance - msg.value);
    // The command libraries run via delegatecall and cannot read the immutables, so `availableErc20Balance` reads
    // the native ERC20 token and its scale from these slots. Skipped when zero: no token ever matches an empty slot.
    if (address(NATIVE_ERC20) != address(0)) {
      TransientTracking.store(MetarouterState.NATIVE_ERC20_SLOT, uint256(uint160(address(NATIVE_ERC20))));
      TransientTracking.store(MetarouterState.NATIVE_ERC20_SCALE_SLOT, NATIVE_ERC20_SCALE);
    }
  }

  /**
   * @notice Returns every tracked ERC20 balance and any batch ETH to the recipient, verifies no tracked NFT remains,
   *         then clears custody and the locker.
   * @dev Tracked ERC20s are swept back to the recipient. The native ERC20 is skipped: its balance is the
   *      router's native balance, so the native refund below already returns the batch's portion, and sweeping it
   *      through the ERC20 entry point would drain the pre-batch native — or revert outright on an implementation
   *      that demands a value-carrying `transfer`. A recipient that rejects the native refund is paid through the
   *      native ERC20's entry point instead, so a custody-holding contract without a payable receiver still gets the batch
   *      native back; without a native ERC20 the rejection reverts the closure. NFTs are checked rather than swept: a
   *      position still owned by
   *      the router means the route left it stranded, so closure reverts; a command that transferred it out (staked,
   *      deposited, transferred) leaves the router as its non-owner, so the check passes. `BURN_CL_POSITION` untracks a
   *      position it burns, so the ownership check skips it. A recipient may instead burn a transferred position from
   *      its receiver hook while its custody flag remains set; in that case `ownerOf` reverting at closure proves that
   *      the canonical position no longer exists and is treated as having left. Closure deliberately does not touch the
   *      in-flight slots: every command that moves a tracked position out of the router must call
   *      `MetarouterState.consumeInFlightNft` itself. Miss that and the stale pair survives into a later batch of the
   *      same transaction, where the next producer command reverts with `InFlightNftPresent`.
   * @param _recipient Address receiving the swept balances and ETH refund at closure.
   */
  function _endExecution(address _recipient) internal virtual {
    uint256 _length = TransientTracking.length(MetarouterState.ERC20_ARRAY_SLOT);
    for (uint256 _i; _i < _length; ++_i) {
      address _token = TransientTracking.at(MetarouterState.ERC20_ARRAY_SLOT, _i);
      TransientTracking.untrack(MetarouterState.TRACKED_SLOT, _token);
      // The native ERC20's batch portion is native value the refund below already returns, and some native ERC20
      // implementations reject a zero-value `transfer`, so its entry point is never swept.
      if (_token == address(NATIVE_ERC20)) continue;
      uint256 _balance = IERC20(_token).balanceOf(address(this));
      if (_balance > 0) IERC20(_token).safeTransfer(_recipient, _balance);
    }
    TransientTracking.clear(MetarouterState.ERC20_ARRAY_SLOT);

    uint256 _nativeRefund = MetarouterState.availableNativeBalance();
    // slither-disable-next-line uninitialized-local
    uint256 _allowedDust;
    if (_nativeRefund > 0) {
      (bool _success, bytes memory _data) = payable(_recipient).call{value: _nativeRefund}('');
      if (!_success) {
        // A rejecting recipient is paid through the native ERC20's entry point instead, which moves the same native
        // without running their code; without a native ERC20 the rejection surfaces. The refund floors to raw
        // native ERC20 units: the untransferable remainder is tolerated below and absorbed by the next batch's snapshot.
        // If the native ERC20 also rejects, the native failure is re-raised with its original data.
        if (address(NATIVE_ERC20) == address(0)) revert NativeTransferFailed(_data);
        uint256 _refundAmount = _nativeRefund / NATIVE_ERC20_SCALE;
        if (_refundAmount > 0 && !NATIVE_ERC20.trySafeTransfer(_recipient, _refundAmount)) {
          revert NativeTransferFailed(_data);
        }
        _allowedDust = NATIVE_ERC20_SCALE - 1;
      }
    }
    // A recipient that bounced native back into the router during the refund would leave a spendable balance behind;
    // reject it so no native survives the batch beyond the remainder a native ERC20 refund cannot express.
    // Post-refund the balance can only be at or above the pre-batch snapshot, so any residual surfaces as a non-zero
    // available balance.
    if (MetarouterState.availableNativeBalance() > _allowedDust) revert NativeBalanceNotCleared();

    // The arrays are an append-only log of every position the batch touched; the per-NFT flag is the live "still the
    // router's responsibility" bit. `trackNft` appends only when the flag is unset, so every entry is unique, and a
    // command that releases a position clears its flag while its array entry stays behind.
    uint256 _nftLength = MetarouterState.trackedNftLength();
    for (uint256 _i; _i < _nftLength; ++_i) {
      (address _collection, uint256 _tokenId) = MetarouterState.trackedNftAt(_i);
      // Flag already cleared: the position was released mid-batch. Today only `BURN_CL_POSITION` does that, so the
      // token no longer exists and `ownerOf` would revert on it. Nothing left to verify.
      if (!MetarouterState.isNftInCustody(_collection, _tokenId)) continue;
      try IERC721(_collection).ownerOf(_tokenId) returns (address _closureOwner) {
        // Still owned by the router: the route brought the position in and never sent it on, so revert the whole batch
        // rather than close and leave it trapped here.
        if (_closureOwner == address(this)) revert NftNotCleared();
      } catch {
        // Custody admits only the canonical position manager and staking escrow. Their `ownerOf` implementations have
        // no application-level revert path for an existing token, so a revert is treated as the position having burned.
      }
      // It left the router. Clearing the flag is load-bearing, not housekeeping: `clearNftArrays` resets only the
      // array lengths, so a flag surviving into a later batch of the same transaction would make that batch's
      // `trackNft` dedupe the position away, leaving it out of the array and unverified at that batch's closure.
      MetarouterState.untrackNft(_collection, _tokenId);
    }
    MetarouterState.clearNftArrays();

    TransientTracking.store(MetarouterState.NATIVE_BALANCE_BEFORE_SLOT, 0);
    TransientTracking.store(MetarouterState.LOCKER_SLOT, 0);
  }

  // ============================== Dispatch ==============================

  /**
   * @notice Routes a command to its handler, keeping control-flow commands inline and delegating group commands
   *         to their libraries.
   * @dev This function is the single validated boundary: an unknown command reverts here.
   * @param _commandType Command ID with flags removed.
   * @param _input ABI-encoded arguments for the command.
   */
  function _dispatch(uint256 _commandType, bytes calldata _input) internal virtual {
    // Swaps stay inline because this hot path fits, other command groups use libraries to stay within the size limit.
    if (_commandType == Commands.CL_SWAP_EXACT_IN) {
      _clSwapExactIn(_input);
    } else if (_commandType == Commands.CL_SWAP_EXACT_OUT) {
      _clSwapExactOut(_input);
    } else if (_commandType == Commands.V2_SWAP_EXACT_IN) {
      _v2SwapExactIn(_input);
    } else if (_commandType == Commands.V2_SWAP_EXACT_OUT) {
      _v2SwapExactOut(_input);
    }
    // Control flow
    else if (_commandType == Commands.EXECUTE_SUB_PLAN) {
      _executeSubPlan(_input);
    } else if (_commandType == Commands.BALANCE_CHECK) {
      _balanceCheck(_input);
    }
    // Payments
    else if (_commandType == Commands.SWEEP) {
      PaymentsLib.sweep(_input);
    } else if (_commandType == Commands.TRANSFER) {
      PaymentsLib.transfer(_input);
    } else if (_commandType == Commands.FUND_ERC20) {
      PaymentsLib.fundErc20(_input);
    } else if (_commandType == Commands.WRAP_ETH) {
      if (address(WETH) == address(0)) revert CommandDisabled(_commandType);
      PaymentsLib.wrapEth(_input, WETH);
    } else if (_commandType == Commands.UNWRAP_WETH) {
      if (address(WETH) == address(0)) revert CommandDisabled(_commandType);
      PaymentsLib.unwrapWeth(_input, WETH);
    } else if (_commandType == Commands.TRANSFER_NFT) {
      PaymentsLib.transferNft(_input);
    }
    // CL positions
    else if (_commandType == Commands.MINT_CL_POSITION) {
      ClPositionLib.mintClPosition(_input, POSITION_MANAGER);
    } else if (_commandType == Commands.INCREASE_CL_LIQUIDITY) {
      ClPositionLib.increaseClLiquidity(_input, POSITION_MANAGER);
    } else if (_commandType == Commands.DECREASE_CL_LIQUIDITY) {
      ClPositionLib.decreaseClLiquidity(_input, POSITION_MANAGER);
    } else if (_commandType == Commands.COLLECT_CL_FEES) {
      ClPositionLib.collectClFees(_input, POSITION_MANAGER);
    } else if (_commandType == Commands.BURN_CL_POSITION) {
      ClPositionLib.burnClPosition(_input, POSITION_MANAGER);
    }
    // V2 liquidity
    else if (_commandType == Commands.ADD_LIQUIDITY) {
      LiquidityLib.addLiquidity(_input, FACTORY_REGISTRY);
    } else if (_commandType == Commands.REMOVE_LIQUIDITY) {
      LiquidityLib.removeLiquidity(_input, FACTORY_REGISTRY);
    }
    // Staking
    else if (_commandType == Commands.STAKE_GAUGE) {
      if (address(LEAF_VOTER) == address(0)) revert CommandDisabled(_commandType);
      StakingLib.stakeGauge(_input, LEAF_VOTER, POSITION_MANAGER);
    } else if (_commandType == Commands.UNSTAKE_GAUGE) {
      if (address(LEAF_VOTER) == address(0)) revert CommandDisabled(_commandType);
      StakingLib.unstakeGauge(_input, LEAF_VOTER, EMISSION_TOKEN);
    }
    // Claims
    else if (_commandType == Commands.CLAIM_GAUGE_REWARDS) {
      if (address(LEAF_VOTER) == address(0)) revert CommandDisabled(_commandType);
      ClaimsLib.claimGaugeRewards(_input, LEAF_VOTER, EMISSION_TOKEN);
    } else if (_commandType == Commands.CLAIM_V2_POOL_FEES) {
      ClaimsLib.claimV2PoolFees(_input, FACTORY_REGISTRY);
    }
    // Cross-chain
    else if (_commandType == Commands.BRIDGE_TOKEN) {
      CrosschainLib.bridgeToken(_input, ICA_ROUTER);
    } else if (_commandType == Commands.EXECUTE_CROSS_CHAIN) {
      if (address(ICA_ROUTER) == address(0)) revert CommandDisabled(_commandType);
      CrosschainLib.executeCrosschain(_input, ICA_ROUTER);
    }
    // `REDEEM` is leaf-only: root pays gauge emissions in `TOKEN` directly, so it holds no receipt to redeem and
    // `EMISSION_TOKEN` is the canonical `TOKEN` there, not the `ReceiptToken` the leaf Voter burns.
    else if (_commandType == Commands.REDEEM) {
      if (address(LEAF_VOTER) == address(0)) revert CommandDisabled(_commandType);
      if (IS_ROOT) revert NotLeaf(_commandType);
      CrosschainLib.redeem(_input, LEAF_VOTER, EMISSION_TOKEN);
    }
    // sAERO / relay
    // `CREATE_STAKE` and `DEPOSIT_RELAY` are root-only: the `VotingEscrow` and the relays exist only on the root
    // deployment. On a leaf `IS_ROOT` is false, so `!IS_ROOT` is true and the command reverts.
    else if (_commandType == Commands.CREATE_STAKE) {
      if (!IS_ROOT) revert NotRoot(_commandType);
      StakeRelayLib.createStake(_input, STAKING_ESCROW, STAKING_TOKEN);
    } else if (_commandType == Commands.DEPOSIT_RELAY) {
      if (!IS_ROOT) revert NotRoot(_commandType);
      StakeRelayLib.depositRelay(_input, STAKING_ESCROW, RELAY_FACTORY);
    } else {
      revert InvalidCommandType(_commandType);
    }
  }

  // ============================== Swaps ==============================

  /**
   * @notice Executes a forward-ordered exact-input CL route.
   * @dev The CL pool applies its contextual swap fee, including any configured MEV fee, and reports the resulting
   *      input/output deltas through the callback and return values. Fee-on-transfer and other nonstandard pool
   *      tokens are unsupported; routing and the minimum-output check use the canonical pool-reported deltas.
   * @param _input ABI-encoded `SwapExactInParams`.
   */
  function _clSwapExactIn(bytes calldata _input) internal {
    SwapExactInParams memory _params = abi.decode(_input, (SwapExactInParams));
    // A user payer must specify an exact amount given wallet percentages are not resolvable.
    if (_params.payerIsUser && _params.amountIn.mode != SpendMode.Amount) revert InvalidSpendMode();

    (address[] memory _tokens, bool[] memory _zeroForOne) =
      _checkAndResolveRoute(_params.pools, _params.tokenIn, true, _params.recipient);
    uint256 _length = _params.pools.length;

    // The user pays the first pool directly, or the execution address funds it.
    uint256 _amountIn =
      _params.payerIsUser ? _params.amountIn.value : FundsLib.fund(_params.tokenIn, _params.amountIn, false);
    // Reverts if the first hop's user-supplied or funded input does not fit the pool's signed input type.
    if (_amountIn > uint256(type(int256).max)) revert AmountOverflow();
    address _payer = _params.payerIsUser ? MetarouterState.msgSender() : address(this);

    // Exact-input callbacks never recurse through an earlier pool, so every hop reuses the same empty route arrays.
    address[] memory _emptyPools = new address[](0);
    bool[] memory _emptyZeroForOne = new bool[](0);

    // Execute the swaps route.
    for (uint256 _i; _i < _length; ++_i) {
      // Send intermediate outputs to the metarouter and the final output to the recipient.
      address _recipient = _i + 1 == _length ? _params.recipient : address(this);
      if (_recipient == address(this)) MetarouterState.trackERC20(_tokens[_i + 1]);

      // Authorize the pool callback, bound what it may pay, and execute the swap.
      ClSwapCallbackData memory _callback = ClSwapCallbackData({
        pools: _emptyPools,
        zeroForOne: _emptyZeroForOne,
        remaining: 0,
        tokenIn: _tokens[_i],
        payer: _payer,
        maxAmountIn: _amountIn
      });
      (int256 _amount0, int256 _amount1) =
        _clSwap(_params.pools[_i], _zeroForOne[_i], int256(_amountIn), _recipient, abi.encode(_callback));

      // The negative output delta (amount out we swapped) magnitude becomes the next hop's input.
      int256 _outputDelta = _zeroForOne[_i] ? _amount1 : _amount0;
      if (_outputDelta > 0) revert InvalidSwapDeltas();
      // Convert into positive and cast (safe to negate: no pool can send close to `type(int256).min`).
      _amountIn = uint256(-_outputDelta);

      // The execution address pays the following pools.
      _payer = address(this);
    }

    // Reverts if the minimum received amount out is not met.
    if (_amountIn < _params.minAmountOut) revert TooLittleReceived(_params.minAmountOut, _amountIn);
  }

  /**
   * @notice Executes a forward-ordered exact-output CL route.
   * @dev The last pool executes first and each pool's invoice is settled inside its callback by swapping the
   *      previous route pool straight to it, so the payer only pays the first pool's invoice. That payment happens
   *      lazily inside the callback with no upfront funding: the execution owner pays directly, or the execution
   *      address pays from custody. Fee-on-transfer and other nonstandard pool tokens are unsupported.
   * @param _input ABI-encoded `SwapExactOutParams`.
   */
  function _clSwapExactOut(bytes calldata _input) internal {
    SwapExactOutParams memory _params = abi.decode(_input, (SwapExactOutParams));

    (address[] memory _tokens, bool[] memory _zeroForOne) =
      _checkAndResolveRoute(_params.pools, _params.tokenIn, true, _params.recipient);
    uint256 _lastIndex = _params.pools.length - 1;

    // If the final recipient is the Metarouter, track the output token.
    if (_params.recipient == address(this)) MetarouterState.trackERC20(_tokens[_lastIndex + 1]);

    // Reverts if the output amount does not fit the pool's signed amount type.
    if (_params.amountOut > uint256(type(int256).max)) revert AmountOverflow();

    // The user pays the first pool's invoice directly, or the execution address pays it from custody.
    address _payer = _params.payerIsUser ? MetarouterState.msgSender() : address(this);
    // Track custody-funded inputs so any unspent residual is swept back at batch closure.
    if (!_params.payerIsUser) MetarouterState.trackERC20(_params.tokenIn);

    // The route before the last pool settles its invoice recursively through the callback.
    ClSwapCallbackData memory _callback = ClSwapCallbackData({
      pools: _params.pools,
      zeroForOne: _zeroForOne,
      remaining: _lastIndex,
      tokenIn: _params.tokenIn,
      payer: _payer,
      maxAmountIn: _params.maxAmountIn
    });
    (int256 _amount0, int256 _amount1) = _clSwap(
      _params.pools[_lastIndex],
      _zeroForOne[_lastIndex],
      -int256(_params.amountOut),
      _params.recipient,
      abi.encode(_callback)
    );

    // Reverts if the pool delivers a different output than the exact requested amount.
    int256 _outputDelta = _zeroForOne[_lastIndex] ? _amount1 : _amount0;
    if (uint256(-_outputDelta) != _params.amountOut) revert InvalidAmountOut();
  }

  /**
   * @notice Executes a forward-ordered exact-input V2 route through stable and volatile pools.
   * @dev Each hop measures the input its pool actually received. Slippage is checked twice against `minAmountOut`:
   *      the final hop's quote, before the swap runs, which an inflow to the recipient cannot inflate, and the
   *      recipient balance delta as a backstop for an output token that under-delivers on transfer. Fee-on-transfer
   *      and other nonstandard output tokens are unsupported: for them the quote is not a delivery guarantee and the
   *      delta backstop might not be enough.
   * @param _input ABI-encoded `SwapExactInParams`.
   */
  // slither-disable-start reentrancy-balance
  function _v2SwapExactIn(bytes calldata _input) internal {
    SwapExactInParams memory _params = abi.decode(_input, (SwapExactInParams));
    // A user payer must specify an exact amount given wallet percentages are not resolvable.
    if (_params.payerIsUser && _params.amountIn.mode != SpendMode.Amount) revert InvalidSpendMode();

    (address[] memory _tokens, bool[] memory _zeroForOne) =
      _checkAndResolveRoute(_params.pools, _params.tokenIn, false, _params.recipient);

    // If the final recipient is the Metarouter, track the output token.
    uint256 _length = _params.pools.length;
    address _tokenOut = _tokens[_length];
    if (_params.recipient == address(this)) MetarouterState.trackERC20(_tokenOut);

    // The user pays the first pool directly, or the execution address funds it.
    uint256 _amountIn =
      _params.payerIsUser ? _params.amountIn.value : FundsLib.fund(_params.tokenIn, _params.amountIn, false);
    FundsLib.pay(
      _params.tokenIn, _params.payerIsUser ? MetarouterState.msgSender() : address(this), _params.pools[0], _amountIn
    );

    uint256 _balanceBefore = 0;

    // Execute the swaps route.
    for (uint256 _i; _i < _length; ++_i) {
      uint256 _actualAmountIn;
      {
        // Measure the input amount received by the pool.
        // slither-disable-next-line unused-return
        (uint256 _reserve0, uint256 _reserve1,) = IPool(_params.pools[_i]).getReserves();
        uint256 _reserveIn = _zeroForOne[_i] ? _reserve0 : _reserve1;
        uint256 _poolBalance = IERC20(_tokens[_i]).balanceOf(_params.pools[_i]);
        if (_poolBalance < _reserveIn) revert InvalidReserves(_params.pools[_i]);
        _actualAmountIn = _poolBalance - _reserveIn;
      }

      // Route intermediate output to the next pool and final output to the recipient after snapshotting its balance.
      uint256 _amountOut = IPool(_params.pools[_i]).getAmountOutWithTotalFee(_actualAmountIn, _tokens[_i]);
      address _recipient;
      if (_i + 1 < _length) {
        _recipient = _params.pools[_i + 1];
      } else {
        // The quote cannot be inflated by an inflow to the recipient, so it enforces the minimum before the swap runs.
        if (_amountOut < _params.minAmountOut) revert TooLittleReceived(_params.minAmountOut, _amountOut);
        _recipient = _params.recipient;
        // Snapshot immediately before the final swap so earlier route inflows cannot inflate the received amount.
        _balanceBefore = IERC20(_tokenOut).balanceOf(_recipient);
      }
      _v2Swap(_params.pools[_i], _zeroForOne[_i], _amountOut, _recipient);
    }

    // Reverts if the minimum received amount out is not met.
    uint256 _received = IERC20(_tokenOut).balanceOf(_params.recipient) - _balanceBefore;
    if (_received < _params.minAmountOut) revert TooLittleReceived(_params.minAmountOut, _received);
  }

  // slither-disable-end reentrancy-balance

  /**
   * @notice Executes a forward-ordered exact-output V2 route through stable and volatile pools.
   * @dev Each hop's required input is quoted backwards from the exact output by the pool itself, which applies its
   *      own curve and total contextual fee, so both stable and volatile pools are supported. All hops are quoted
   *      upfront; if an earlier hop increases a later hop's fee, that hop is underfunded and the route reverts.
   *      The final recipient's balance delta must cover the exact requested output, so nonstandard output tokens that
   *      under-deliver revert.
   * @param _input ABI-encoded `SwapExactOutParams`.
   */
  // slither-disable-start reentrancy-balance
  function _v2SwapExactOut(bytes calldata _input) internal {
    SwapExactOutParams memory _params = abi.decode(_input, (SwapExactOutParams));

    (address[] memory _tokens, bool[] memory _zeroForOne) =
      _checkAndResolveRoute(_params.pools, _params.tokenIn, false, _params.recipient);
    uint256 _length = _params.pools.length;
    address _tokenOut = _tokens[_length];

    // If the final recipient is the Metarouter, track the output token.
    if (_params.recipient == address(this)) MetarouterState.trackERC20(_tokenOut);

    // Quote each hop's required input backwards from the exact output.
    uint256[] memory _amounts = new uint256[](_length + 1);
    _amounts[_length] = _params.amountOut;
    for (uint256 _i = _length; _i > 0;) {
      --_i;
      // The pool quotes the exact input its curve and total fee require for this hop's output.
      _amounts[_i] = IPool(_params.pools[_i]).getAmountInWithTotalFee(_amounts[_i + 1], _tokens[_i + 1]);
    }

    // Reverts if the route requires more input than the authorized maximum.
    if (_amounts[0] > _params.maxAmountIn) revert TooMuchRequested();

    // The payer sends the quoted input straight to the first pool.
    address _payer = _params.payerIsUser ? MetarouterState.msgSender() : address(this);
    // Track custody-funded inputs so any unspent residual is swept back at batch closure.
    if (!_params.payerIsUser) MetarouterState.trackERC20(_params.tokenIn);
    FundsLib.pay(_params.tokenIn, _payer, _params.pools[0], _amounts[0]);

    uint256 _balanceBefore = 0;

    // Execute the swaps route.
    for (uint256 _i; _i < _length; ++_i) {
      // Route intermediate output to the next pool and final output to the recipient after snapshotting its balance.
      address _recipient;
      if (_i + 1 < _length) {
        _recipient = _params.pools[_i + 1];
      } else {
        _recipient = _params.recipient;
        // Snapshot immediately before the final swap so earlier route inflows cannot inflate the received amount.
        _balanceBefore = IERC20(_tokenOut).balanceOf(_recipient);
      }
      _v2Swap(_params.pools[_i], _zeroForOne[_i], _amounts[_i + 1], _recipient);
    }

    // Reverts if the recipient did not receive the exact requested output.
    uint256 _received = IERC20(_tokenOut).balanceOf(_params.recipient) - _balanceBefore;
    if (_received < _params.amountOut) revert TooLittleReceived(_params.amountOut, _received);
  }

  // slither-disable-end reentrancy-balance

  /**
   * @notice Executes a V2 pool swap using the precomputed output amount.
   * @param _pool Pool to execute against.
   * @param _zeroForOne Whether token0 is exchanged for token1.
   * @param _amountOut Output amount requested from the pool.
   * @param _recipient Address that receives the output.
   */
  function _v2Swap(address _pool, bool _zeroForOne, uint256 _amountOut, address _recipient) internal {
    (uint256 _amount0Out, uint256 _amount1Out) = _zeroForOne ? (uint256(0), _amountOut) : (_amountOut, uint256(0));
    IPool(_pool).swap(_amount0Out, _amount1Out, _recipient, '');
  }

  /**
   * @notice Executes a CL pool swap with the pool authorized as the only callback caller.
   * @dev Arms the callback slot for the pool, swaps, and requires the pool to have consumed the authorization by
   *      paying through the callback.
   * @param _pool Pool to execute against.
   * @param _zeroForOne Whether token0 is exchanged for token1.
   * @param _amountSpecified Exact input amount, or negated exact output amount.
   * @param _recipient Address that receives the output.
   * @param _data Callback payment authorization forwarded to the pool.
   * @return _amount0 Signed token0 balance change of the pool.
   * @return _amount1 Signed token1 balance change of the pool.
   */
  function _clSwap(
    address _pool,
    bool _zeroForOne,
    int256 _amountSpecified,
    address _recipient,
    bytes memory _data
  ) internal returns (int256 _amount0, int256 _amount1) {
    // Check the callback caller slot is empty, and then set the pool as the only accepted one.
    address _current = address(uint160(TransientTracking.load(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT)));
    if (_current != address(0)) revert CallbackNotCleared(_current);
    TransientTracking.store(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT, uint256(uint160(_pool)));

    // Selling token0 moves the price down and selling token1 up, so the boundary acts as no price limit at this point.
    uint160 _sqrtRatioX96 = _zeroForOne ? _MIN_SQRT_RATIO_PLUS_ONE : _MAX_SQRT_RATIO_MINUS_ONE;
    // Execute the swap.
    (_amount0, _amount1) = ICLPool(_pool).swap(_recipient, _zeroForOne, _amountSpecified, _sqrtRatioX96, _data);

    // The pool must consume its authorization by paying through the callback.
    if (TransientTracking.load(MetarouterState.EXPECTED_CALLBACK_CALLER_SLOT) != 0) revert CallbackNotCleared(_pool);
  }

  // ============================== Control Flow ==============================

  /**
   * @notice Runs a nested command list in a call frame whose failure can be caught.
   * @param _input ABI-encoded sub-plan commands and inputs.
   */
  function _executeSubPlan(bytes calldata _input) internal virtual {
    (bytes memory _subCommands, bytes[] memory _subInputs) = abi.decode(_input, (bytes, bytes[]));
    try this.execute(_subCommands, _subInputs, type(uint256).max) {}
    catch (bytes memory _output) {
      _revert(_output);
    }
  }

  /**
   * @notice Checks a forward-ordered pool route and its recipient, and resolves its token sequence and directions.
   * @param _pools Pools in the route.
   * @param _tokenIn Input token for the first pool.
   * @param _clRoute Whether the route must consist of CL pools instead of V2 pools.
   * @param _recipient Address that receives the route's final output.
   * @return _tokens Route tokens, including the initial input and final output tokens.
   * @return _zeroForOne Whether token0 is exchanged for token1 for each pool.
   */
  function _checkAndResolveRoute(
    address[] memory _pools,
    address _tokenIn,
    bool _clRoute,
    address _recipient
  ) internal view returns (address[] memory _tokens, bool[] memory _zeroForOne) {
    if (_recipient == address(0)) revert InvalidRecipient();
    uint256 _length = _pools.length;
    if (_length == 0) revert InvalidPath();
    _tokens = new address[](_length + 1);
    _zeroForOne = new bool[](_length);
    _tokens[0] = _tokenIn;

    for (uint256 _i; _i < _length; ++_i) {
      address _pool = _pools[_i];
      // Resolve the permanent creation record so existing pools remain usable if their factory is later unapproved.
      address _factory = FACTORY_REGISTRY.targetToFactory(_pool);
      if (_factory == address(0)) revert InvalidPool(_pool);
      if (!IPoolFactory(_factory).isPool(_pool)) revert InvalidPool(_pool);
      bytes32 _poolType = _clRoute ? ICLPool(_pool).POOL_TYPE() : IPool(_pool).POOL_TYPE();
      // Reject any pool outside the route's family.
      if (_clRoute) {
        if (_poolType != _CL_POOL_TYPE) revert InvalidPool(_pool);
      } else if (_poolType != _V2_VOLATILE_POOL_TYPE && _poolType != _V2_STABLE_POOL_TYPE) {
        revert InvalidPool(_pool);
      }

      // Check which one of token0 or token1 is the input token.
      (address _token0, address _token1) = (IPool(_pool).token0(), IPool(_pool).token1());
      bool _isZeroForOne = _tokens[_i] == _token0;
      if (!_isZeroForOne && _tokens[_i] != _token1) revert InvalidPath();
      _zeroForOne[_i] = _isZeroForOne;

      // Derive this hop's output token, which becomes the next hop's input.
      _tokens[_i + 1] = _isZeroForOne ? _token1 : _token0;
    }
  }

  /**
   * @notice Rejects delegatecalls: the router re-enters itself by address, so it must run at its deployment address.
   * @dev Sub-plans and allow-revert commands re-enter via `address(this).call(execute)`. Under a delegatecall
   *      `address(this)` is not Metarouter, which implies `execute()` may not be available, so an allow-revert
   *      command would silently no-op. Fail fast instead.
   */
  function _checkExecutionContext() internal view virtual {
    if (address(this) != _IMPLEMENTATION) revert DirectCallRequired();
  }

  /**
   * @notice Balance assertion whose failure can be handled with ALLOW_REVERT.
   * @dev Address zero selects native ETH. For the execution address, a balance means only what is available to the
   *      active batch: native ETH excludes what was held before the batch began, and the native ERC20 — whose
   *      `balanceOf` is the native balance — applies the same exclusion. Other owners use their live account balance.
   * @param _input ABI-encoded asset, owner, and minimum balance.
   */
  function _balanceCheck(bytes calldata _input) internal view virtual {
    (address _asset, address _owner, uint256 _minBalance) = abi.decode(_input, (address, address, uint256));
    uint256 _balance;
    if (_asset == address(0)) {
      _balance = _owner == address(this) ? MetarouterState.availableNativeBalance() : _owner.balance;
    } else {
      _balance =
        _owner == address(this) ? MetarouterState.availableErc20Balance(_asset) : IERC20(_asset).balanceOf(_owner);
    }
    if (_balance < _minBalance) revert InsufficientBalance(_asset);
  }

  /**
   * @notice Splits a command byte into its command ID and allow-revert flag.
   * @param _commandByte Encoded command ID and flags.
   * @return _commandType Command ID with flags removed.
   * @return _allowRevert Whether failure of the command may be ignored.
   */
  function _decode(bytes1 _commandByte) internal pure virtual returns (uint256 _commandType, bool _allowRevert) {
    _commandType = uint256(uint8(_commandByte & Commands.COMMAND_TYPE_MASK));
    _allowRevert = _commandByte & Commands.FLAG_ALLOW_REVERT != 0;
  }

  /**
   * @notice Bubbles revert data returned by a failed child frame.
   * @param _output Raw revert data to re-throw.
   */
  function _revert(bytes memory _output) private pure {
    assembly ('memory-safe') {
      revert(add(_output, 0x20), mload(_output))
    }
  }
}
