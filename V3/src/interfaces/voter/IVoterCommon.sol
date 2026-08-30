// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

/**
 * @title IVoterCommon
 * @notice Types shared by `IVoter` (root) and `ILeafVoter` (leaf), so the same struct crosses chains unchanged.
 */
interface IVoterCommon {
  /*//////////////////////////////////////////////////////////////
                                  ENUMS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Per-chain operational status shared by root and leaf voters.
   * @dev `None` is the enum default (0), so an unregistered chain never passes a status check; registration
   *      (root) and construction (leaf) set `Active`, and `setChainStatus` cannot set `None`. `Active` allows
   *      everything, `Paused` blocks the chain's operations.
   * @dev `Suspended` is the emissions kill switch: root rejects inbound messages and sends the chain's accrual to
   *      surplus, the leaf blocks outbound dispatch and user entrypoints but still applies root messages at rate
   *      zero, so its mirror repairs itself without accruing unfunded emissions.
   * @dev `Sunset` is the wind-down. Root stops accepting chain allocations, sends the chain's accrual to
   *      surplus like `Suspended`, and keeps processing redeems and deallocations. Gauge votes, operator
   *      updates and cooldown reductions still dispatch so booked voting power can exit through `DEALLOC_GAUGE`;
   *      the chain accrues nothing, so they move no emissions. The leaf parks its scalar at zero but keeps
   *      `allocateGauges`, `mintEmissions` and `redeem` open, so everything already earned stays claimable and
   *      redeemable. Its only exit is `Suspended`, the kill switch for a compromised or unreachable sunset
   *      chain and the mandatory first leg of a reactivation (see `IVoter.setChainStatus`).
   * @param None Uninitialized sentinel, the state of an unregistered chain.
   * @param Active Fully operational.
   * @param Paused Chain operations blocked on both sides; accrual continues.
   * @param Suspended Emissions kill switch; accrual goes to surplus and user entrypoints close.
   * @param Sunset Wind-down; accrual goes to surplus, exits stay open, chain allocations close.
   */
  enum ChainStatus {
    None,
    Active,
    Paused,
    Suspended,
    Sunset
  }

  /*//////////////////////////////////////////////////////////////
                                 STRUCTS
  //////////////////////////////////////////////////////////////*/

  /**
   * @notice Snapshot of decaying voting power at a point in time.
   * @param bias Current voting power; decays linearly.
   * @param slope Rate of decay per second.
   * @param ts Timestamp of last resolution.
   * @param permanentStakeBalance Non-decaying voting power from permanent stakes.
   */
  struct Point {
    int128 bias;
    int128 slope;
    uint48 ts;
    uint128 permanentStakeBalance;
  }

  /**
   * @notice One gauge leg of a tokenId's vote. Sent to the leaf in the dispatch payload; root keeps no copy.
   * @param gauge Target gauge address.
   * @param allocated Absolute AERO for this gauge, not a percentage; Σ within a chain equals that chain's total.
   * @param data Opaque per-gauge payload forwarded unchanged to the leaf.
   */
  struct GaugeAllocation {
    address gauge;
    uint128 allocated;
    bytes data;
  }

  /**
   * @notice VE state at dispatch, so the leaf can rebuild the tokenId's contribution shape locally.
   * @dev The leaf derives bias, slope and permanent balance from `_contribution(allocated, stakeEnd, isPermanent)`,
   *      settled at its own `block.timestamp`. `isPermanent` is the permanence discriminator, not `stakeEnd == 0`.
   * @param staked AERO staked in the veNFT at dispatch time.
   * @param stakeEnd Week-aligned stake expiry; `0` for a permanent stake.
   * @param isPermanent True for a permanent stake; the permanence signal the leaf reads.
   */
  struct TokenSnapshot {
    uint128 staked;
    uint48 stakeEnd;
    bool isPermanent;
  }

  /**
   * @notice Chain-level allocation from root to a leaf: sets the tokenId's budget on the chain and the chain's
   *         emissions scalar. No gauges and no cooldown — chain assignment always applies.
   * @dev Applied additively on the leaf, so it can never bring back a budget the leaf-first `deallocate` removed.
   *      Reductions go leaf-first through `deallocate`, never through this message.
   * @dev The MessageOrchestrator stamps `chainNonce` and `dispatchedAt` and wraps every message body below in
   *      the `(MessageType, chainNonce, dispatchedAt, bytes)` transport envelope; these structs are the
   *      Voter→Orchestrator body only.
   * @param tokenId Originating tokenId.
   * @param allocationDelta Voting power added to the token's budget here, drawn from `CHAIN0`; always an increase.
   * @param emissionsPerVP Global emissions per unit voting power, `PRECISION`-scaled; the leaf's index rate.
   * @param snapshot Live VE shape at dispatch, which anchors the token's booked shape on the leaf.
   */
  struct AllocateChainMessage {
    uint256 tokenId;
    uint128 allocationDelta;
    uint256 emissionsPerVP;
    TokenSnapshot snapshot;
  }

  /**
   * @notice Gauge distribution from root to a leaf, spreading the tokenId's chain budget across gauges.
   * @dev Cooldown-gated on the leaf: it reverts while the cooldown still runs and the transport redelivers later.
   * @param tokenId Originating tokenId.
   * @param expiry Absolute deadline stamped by root; past it the leaf reverts `AllocationExpired`.
   * @param emissionsPerVP Emissions per unit voting power, `PRECISION`-scaled; only the leaf's newest message
   *                       refreshes its scalar.
   * @param tokenSnapshot Live VE state at dispatch, used to shape each gauge's contribution.
   * @param allocations Per-gauge allocations on this chain. Empty clears the tokenId's gauge weight.
   */
  struct AllocateGaugeMessage {
    uint256 tokenId;
    uint48 expiry;
    uint256 emissionsPerVP;
    TokenSnapshot tokenSnapshot;
    GaugeAllocation[] allocations;
  }

  /**
   * @notice Cooldown reduction from root to a leaf. The leaf accrues it and the token's next gauge allocation,
   *         bridged or local, spends it clamped to `allocationCooldown`.
   * @dev Reductions accrue additively, so message order does not matter and no reduction-specific nonce gate is
   *      needed; the global replay gate applies each one exactly once.
   * @param tokenId veNFT id whose pending cooldown reduction is being increased.
   * @param reduction Seconds added to the tokenId's pending cooldown reduction on this chain.
   */
  struct ReduceCooldownMessage {
    uint256 tokenId;
    uint48 reduction;
  }

  /**
   * @notice Emergency unwind from root to a leaf after root drained `amount` from a `Suspended` chain: the leaf
   *         clears the tokenId's gauges and re-parks the surviving budget (`budget - amount`) on `ZERO_GAUGE`.
   * @dev It subtracts a fixed amount instead of zeroing, so `AllocateChain` deltas booked before the drain need
   *      no ordering gate; the leaf drops stale pre-drain deltas by message nonce.
   * @dev It over-subtracts if a POST-resume delta lands first, so resume is gated on delivery — see the
   *      precondition on `IVoter.setChainStatus`.
   * @param tokenId veNFT id whose position on the chain is being reduced.
   * @param amount Chain budget root drained to `CHAIN0`; the leaf subtracts it, clamped at zero.
   */
  struct EmergencyDeallocateMessage {
    uint256 tokenId;
    uint128 amount;
  }

  /**
   * @notice Redeem payload dispatched from a leaf to root.
   * @param amount Amount of `ReceiptToken` burned on the leaf and `TOKEN` to mint on root.
   * @param recipient Address that receives the minted `TOKEN` on root.
   * @param surplusAccrued Cumulative surplus accumulator snapshot reported by the leaf.
   */
  struct RedeemMessageBody {
    uint256 amount;
    address recipient;
    uint256 surplusAccrued;
  }

  /**
   * @notice Deallocation confirmation from a leaf to root, so root credits `CHAIN0` only once the leaf confirms.
   * @param tokenId veNFT id whose voting power was deallocated on the leaf.
   * @param amount Voting power deallocated on the leaf, to credit back to `CHAIN0` on root.
   */
  struct DeallocationMessageBody {
    uint256 tokenId;
    uint128 amount;
  }

  /**
   * @notice Operator assignment from root to a leaf, keeping the leaf's `operators[tokenId]` mirror in sync.
   * @param tokenId veNFT id whose operator is being set.
   * @param expiry Absolute deadline stamped by root; past it the leaf drops the message with
   * `ExpiredMessageDropped`.
   * @param operator New operator address. Zero clears the slot.
   */
  struct OperatorMessage {
    uint256 tokenId;
    uint48 expiry;
    address operator;
  }

  /*//////////////////////////////////////////////////////////////
                                 ERRORS
  //////////////////////////////////////////////////////////////*/

  /// @notice Thrown when `setChainStatus` is called with the chain's current status, a no-op write.
  error ChainStatusUnchanged();

  /**
   * @notice Thrown when `setChainStatus` moves a `Suspended` chain to `Paused`, or a `Sunset` chain to
   *         anything but `Suspended`. A `None` target reverts with `InvalidStatus` first.
   * @dev A `Paused` exit restarts ceiling accrual at the stored rate while the leaf still distributes nothing,
   *      and `Paused` blocks the vote pipeline, so no message could resync the leaf for that whole period.
   *      `Sunset` exits only through `Suspended`, so a reactivation always drains the in-flight deallocation
   *      set before any resume and a dead sunset chain keeps its kill switch.
   */
  error InvalidChainStatusTransition();

  /// @notice Thrown when `setChainStatus` is called with `None`, the uninitialized sentinel status.
  error InvalidStatus();

  /// @notice Thrown when a constructor receives a zero address argument.
  error ZeroAddress();

  /// @notice Thrown when the token's stake is expired.
  error StakeExpired();

  /// @notice Thrown when a vote on a sunset chain carries anything but the lone `DEALLOC_GAUGE` return.
  error SunsetDeallocOnly();

  /// @notice Thrown when an allocation entry carries a zero `allocated` amount.
  error ZeroAllocation();

  /// @notice Thrown when `msg.value` is attached but there is no return message to fund.
  error UnexpectedValue();

  /// @notice Thrown when an allocation's gauges are not strictly ascending by address, which also rejects
  ///         duplicates.
  error GaugesNotStrictlyAscending();
}
