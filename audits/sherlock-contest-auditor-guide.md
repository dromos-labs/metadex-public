<!-- SPDX-License-Identifier: LicenseRef-Dromos-Restricted-Use-1.0 -->

# MetaDEX03 Sherlock Audit Contest Guide

**This document is a summary of the MetaDEX03 codebase. The goal is to give a starting point for understanding the code for the August/September Sherlock audit-engine contest.**

## Scope

### Repos

The codebase is split across two main repositories:

- [**`dromos-labs/metadex-public`**](https://github.com/dromos-labs/metadex-public): contains the majority of the protocol code.
- [**`dromos-labs/metadex-slipstream-public`**](https://github.com/dromos-labs/metadex-slipstream-public): contains the code relating to concentrated liquidity.

### File Tree

```text
metadex/
└── V3
    └── src
        ├── access
        │   └── GuardedAccessControlEnumerable.sol
        ├── art
        │   ├── BokkyPooBahsDateTimeLibrary.sol
        │   └── VeArtProxy.sol
        ├── bridge
        │   ├── hyperlane
        │   │   └── HyperlaneAdapter.sol
        │   ├── LeafMessageOrchestrator.sol
        │   ├── MessageOrchestrator.sol
        │   ├── RootLocalAdapter.sol
        │   └── RootMessageOrchestrator.sol
        ├── core
        │   └── VotingEscrow.sol
        ├── factories
        │   ├── FactoryRegistry.sol
        │   ├── GaugeFactory.sol
        │   ├── PoolFactory.sol
        │   ├── StablePoolFactory.sol
        │   └── VolatilePoolFactory.sol
        ├── fees
        │   ├── CustomFeeModule.sol
        │   ├── DiscountRegistry.sol
        │   ├── FlatFeeQuoter.sol
        │   └── PriorityFeeMevTaxModule.sol
        ├── gauge-creation
        │   ├── DefaultGaugeCreationModule.sol
        │   ├── GaugeManager.sol
        │   └── GovernanceCreationModule.sol
        ├── gauges
        │   ├── Gauge.sol
        │   └── V2Gauge.sol
        ├── handlers
        │   ├── LeafEmissionsHandler.sol
        │   └── RootEmissionsHandler.sol
        ├── hooks
        │   └── dynamic
        │       ├── libraries
        │       │   └── TransientMevTaxLib.sol
        │       └── DynamicSwapFeeHook.sol
        ├── interfaces
        │   ├── access
        │   │   └── IGuardedAccessControlEnumerable.sol
        │   ├── art
        │   │   └── IVeArtProxy.sol
        │   ├── bridge
        │   │   ├── hyperlane
        │   │   │   └── IHyperlaneAdapter.sol
        │   │   ├── ILeafMessageOrchestrator.sol
        │   │   ├── IMessageAdapter.sol
        │   │   ├── IMessageOrchestrator.sol
        │   │   ├── IRootLocalAdapter.sol
        │   │   └── IRootMessageOrchestrator.sol
        │   ├── core
        │   │   ├── IVotes.sol
        │   │   └── IVotingEscrow.sol
        │   ├── external
        │   │   ├── IInterchainAccountRouter.sol
        │   │   ├── INonfungiblePositionManager.sol
        │   │   ├── ITokenRouter.sol
        │   │   └── IWETH.sol
        │   ├── factories
        │   │   ├── ICLFactory.sol
        │   │   ├── IFactoryRegistry.sol
        │   │   ├── IGaugeFactory.sol
        │   │   └── IPoolFactory.sol
        │   ├── fees
        │   │   ├── ICustomFeeModule.sol
        │   │   ├── IDiscountRegistry.sol
        │   │   ├── IExactOutFeeQuoter.sol
        │   │   ├── IFeeModule.sol
        │   │   └── IMevTaxModule.sol
        │   ├── gauge-creation
        │   │   ├── IDefaultGaugeCreationModule.sol
        │   │   ├── IGaugeCreationModule.sol
        │   │   ├── IGaugeManager.sol
        │   │   └── IGovernanceCreationModule.sol
        │   ├── gauges
        │   │   ├── ICLGauge.sol
        │   │   ├── IGauge.sol
        │   │   └── IV2Gauge.sol
        │   ├── governor
        │   │   └── IGovernor.sol
        │   ├── handlers
        │   │   ├── IEmissionsHandler.sol
        │   │   ├── ILeafEmissionsHandler.sol
        │   │   └── IRootEmissionsHandler.sol
        │   ├── hooks
        │   │   ├── dynamic
        │   │   │   └── IDynamicSwapFeeHook.sol
        │   │   └── ISwapHook.sol
        │   ├── metarouter
        │   │   └── IMetarouter.sol
        │   ├── migration
        │   │   ├── v2
        │   │   │   ├── IV2EmergencyCouncil.sol
        │   │   │   ├── IV2EpochGovernor.sol
        │   │   │   ├── IV2Minter.sol
        │   │   │   ├── IV2RootVotingReward.sol
        │   │   │   ├── IV2RootVotingRewardsFactory.sol
        │   │   │   ├── IV2Voter.sol
        │   │   │   └── IV2VotingEscrow.sol
        │   │   ├── IAerodromeMigration.sol
        │   │   ├── IMigration.sol
        │   │   ├── IVelodromeMigration.sol
        │   │   └── IVelodromeMigrationEntrypoint.sol
        │   ├── minter
        │   │   ├── IMinter.sol
        │   │   └── IToken.sol
        │   ├── pools
        │   │   ├── tape
        │   │   │   ├── IBasePoolTape.sol
        │   │   │   ├── ICLPoolTape.sol
        │   │   │   └── IPoolTape.sol
        │   │   ├── ICLPool.sol
        │   │   ├── ICLPoolConstants.sol
        │   │   ├── ICLPoolDerivedState.sol
        │   │   ├── ICLPoolState.sol
        │   │   ├── IPool.sol
        │   │   ├── IPoolCallee.sol
        │   │   ├── IPoolFactoryIndexation.sol
        │   │   └── IStablePool.sol
        │   ├── relay
        │   │   ├── entrypoints
        │   │   │   ├── IBaseEntrypoint.sol
        │   │   │   ├── ICompounder.sol
        │   │   │   ├── IMultiConverter.sol
        │   │   │   ├── IMultiEntrypoint.sol
        │   │   │   ├── IMultiHybrid.sol
        │   │   │   ├── ISingleConverter.sol
        │   │   │   └── ISingleHybrid.sol
        │   │   ├── IRelay.sol
        │   │   ├── IRelayEntrypoint.sol
        │   │   ├── IRelayFactory.sol
        │   │   ├── IRelayGovernanceHost.sol
        │   │   ├── IRelayState.sol
        │   │   ├── IRelayToken.sol
        │   │   ├── IRelayTokenVotes.sol
        │   │   └── IRelayVoteAdapter.sol
        │   ├── rewards
        │   │   ├── IFeeDistribution.sol
        │   │   ├── IIncentiveStreaming.sol
        │   │   ├── IVotingCheckpoints.sol
        │   │   ├── IVotingRewardsFactory.sol
        │   │   └── IVotingRewardsManager.sol
        │   ├── splitter
        │   │   └── ISplitter.sol
        │   ├── token
        │   │   ├── IBaseTokenExtensions.sol
        │   │   ├── IReceiptTokenExtensions.sol
        │   │   ├── IToken.sol
        │   │   └── ITokenExtensions.sol
        │   ├── tokenRegistry
        │   │   ├── ITokenNFT.sol
        │   │   └── ITokenRegistry.sol
        │   ├── voter
        │   │   ├── ILeafVoter.sol
        │   │   ├── IVoter.sol
        │   │   └── IVoterCommon.sol
        │   └── vpm
        │       └── IVoterPaymentsModule.sol
        ├── libraries
        │   ├── AllocationLogicLibrary.sol
        │   ├── BalanceLogicLibrary.sol
        │   ├── CheckpointLogicLibrary.sol
        │   ├── CreateXLibrary.sol
        │   ├── DelegationLogicLibrary.sol
        │   ├── LeafAllocationLibrary.sol
        │   ├── ParamsLib.sol
        │   ├── PoolOracle.sol
        │   ├── ProtocolConstants.sol
        │   ├── RewardsLogicLibrary.sol
        │   ├── Roles.sol
        │   ├── SafeCastLibrary.sol
        │   ├── VelodromeTimeLibrary.sol
        │   ├── VolatilityRingLibrary.sol
        │   └── VotingRewardsFactoryLibrary.sol
        ├── metarouter
        │   ├── libraries
        │   │   ├── ClaimsLib.sol
        │   │   ├── ClPositionLib.sol
        │   │   ├── Commands.sol
        │   │   ├── CrosschainLib.sol
        │   │   ├── FundsLib.sol
        │   │   ├── GaugeLib.sol
        │   │   ├── LiquidityLib.sol
        │   │   ├── MetarouterState.sol
        │   │   ├── PaymentsLib.sol
        │   │   ├── StakeRelayLib.sol
        │   │   └── StakingLib.sol
        │   ├── Metarouter.sol
        │   └── TransientTracking.sol
        ├── migration
        │   ├── AerodromeMigration.sol
        │   ├── Migration.sol
        │   ├── VelodromeMigration.sol
        │   └── VelodromeMigrationEntrypoint.sol
        ├── minter
        │   └── Minter.sol
        ├── pools
        │   ├── tape
        │   │   ├── BasePoolTape.sol
        │   │   ├── CLPoolTape.sol
        │   │   └── PoolTape.sol
        │   ├── Pool.sol
        │   ├── PoolFactoryIndexation.sol
        │   ├── PoolFees.sol
        │   ├── StablePool.sol
        │   └── VolatilePool.sol
        ├── relay
        │   ├── entrypoints
        │   │   ├── BaseEntrypoint.sol
        │   │   ├── Compounder.sol
        │   │   ├── MultiConverter.sol
        │   │   ├── MultiEntrypoint.sol
        │   │   ├── MultiHybrid.sol
        │   │   ├── SingleConverter.sol
        │   │   └── SingleHybrid.sol
        │   ├── libraries
        │   │   ├── AllocationLib.sol
        │   │   ├── DenseQueue.sol
        │   │   ├── QueueLib.sol
        │   │   ├── RelayConfigLib.sol
        │   │   ├── RelayGovernanceLib.sol
        │   │   ├── RelayInitLib.sol
        │   │   └── RelayRewardsLib.sol
        │   ├── MaxiRelay.sol
        │   ├── ProtocolRelay.sol
        │   ├── RelayBase.sol
        │   ├── RelayFactory.sol
        │   ├── RelayRoles.sol
        │   ├── RelayToken.sol
        │   ├── RelayTokenVotes.sol
        │   └── RelayVoteAdapter.sol
        ├── rewards
        │   ├── FeeDistribution.sol
        │   ├── IncentiveStreaming.sol
        │   ├── VotingCheckpoints.sol
        │   ├── VotingRewardsFactory.sol
        │   └── VotingRewardsManager.sol
        ├── splitter
        │   └── Splitter.sol
        ├── token
        │   ├── BaseToken.sol
        │   ├── ReceiptToken.sol
        │   └── Token.sol
        ├── tokenRegistry
        │   ├── TokenNFT.sol
        │   └── TokenRegistry.sol
        ├── voter
        │   ├── LeafVoter.sol
        │   ├── LeafVoterStorageBase.sol
        │   ├── LeafVoterStorageLayout.sol
        │   ├── Voter.sol
        │   ├── VoterStorageBase.sol
        │   └── VoterStorageLayout.sol
        └── vpm
            └── VoterPaymentsModule.sol

metadex-slipstream/
└── contracts
    ├── core
    │   ├── fees
    │   │   └── CustomUnstakedFeeModule.sol
    │   ├── indexation
    │   │   └── CLFactoryIndexation.sol
    │   ├── interfaces
    │   │   ├── callback
    │   │   │   ├── ICLFlashCallback.sol
    │   │   │   ├── ICLMintCallback.sol
    │   │   │   └── ICLSwapCallback.sol
    │   │   ├── fees
    │   │   │   ├── ICustomFeeModule.sol
    │   │   │   ├── IDiscountRegistry.sol
    │   │   │   └── IFeeModule.sol
    │   │   ├── hook
    │   │   │   └── ISwapHook.sol
    │   │   ├── indexation
    │   │   │   └── ICLFactoryIndexation.sol
    │   │   ├── pool
    │   │   │   ├── ICLPoolActions.sol
    │   │   │   ├── ICLPoolConstants.sol
    │   │   │   ├── ICLPoolDerivedState.sol
    │   │   │   ├── ICLPoolEvents.sol
    │   │   │   ├── ICLPoolOwnerActions.sol
    │   │   │   └── ICLPoolState.sol
    │   │   ├── tape
    │   │   │   ├── IBasePoolTape.sol
    │   │   │   └── ICLPoolTape.sol
    │   │   ├── ICLFactory.sol
    │   │   ├── ICLPool.sol
    │   │   ├── IERC20Minimal.sol
    │   │   ├── IFactoryRegistry.sol
    │   │   ├── IMinter.sol
    │   │   ├── IPool.sol
    │   │   ├── IPoolFactory.sol
    │   │   ├── IVoter.sol
    │   │   └── IVotingEscrow.sol
    │   ├── libraries
    │   │   ├── hook
    │   │   │   └── SwapHookLib.sol
    │   │   ├── BitMath.sol
    │   │   ├── FixedPoint128.sol
    │   │   ├── FixedPoint96.sol
    │   │   ├── FullMath.sol
    │   │   ├── LiquidityMath.sol
    │   │   ├── LowGasSafeMath.sol
    │   │   ├── Oracle.sol
    │   │   ├── Position.sol
    │   │   ├── SafeCast.sol
    │   │   ├── SqrtPriceMath.sol
    │   │   ├── SwapMath.sol
    │   │   ├── Tick.sol
    │   │   ├── TickBitmap.sol
    │   │   ├── TickMath.sol
    │   │   ├── TransferHelper.sol
    │   │   └── UnsafeMath.sol
    │   ├── CLFactory.sol
    │   └── CLPool.sol
    ├── gauge
    │   ├── interfaces
    │   │   ├── IAccessControl.sol
    │   │   ├── ICLGauge.sol
    │   │   ├── ICLGaugeFactory.sol
    │   │   ├── ICLPool.sol
    │   │   ├── IGauge.sol
    │   │   ├── ILeafVoter.sol
    │   │   ├── INonfungiblePositionManager.sol
    │   │   ├── IReward.sol
    │   │   ├── IVotingRewardsFactory.sol
    │   │   └── IVotingRewardsManager.sol
    │   ├── libraries
    │   │   └── Roles.sol
    │   ├── CLGauge.sol
    │   ├── CLGaugeFactory.sol
    │   └── Gauge.sol
    ├── libraries
    │   ├── EnumerableSet.sol
    │   ├── ProtocolConstants.sol
    │   └── VelodromeTimeLibrary.sol
    └── periphery
        ├── base
        │   ├── BlockTimestamp.sol
        │   ├── ERC721Permit.sol
        │   ├── LiquidityManagement.sol
        │   ├── Multicall.sol
        │   ├── PeripheryImmutableState.sol
        │   ├── PeripheryPayments.sol
        │   ├── PeripheryPaymentsWithFee.sol
        │   ├── PeripheryValidation.sol
        │   └── SelfPermit.sol
        ├── interfaces
        │   ├── external
        │   │   ├── IERC1271.sol
        │   │   ├── IERC20PermitAllowed.sol
        │   │   └── IWETH9.sol
        │   ├── IERC20Metadata.sol
        │   ├── IERC4906.sol
        │   ├── IERC721Permit.sol
        │   ├── ILpMigrator.sol
        │   ├── IMetaquoter.sol
        │   ├── IMixedRouteQuoterV1.sol
        │   ├── IMixedRouteQuoterV2.sol
        │   ├── IMulticall.sol
        │   ├── INonfungiblePositionManager.sol
        │   ├── INonfungibleTokenPositionDescriptor.sol
        │   ├── IPeripheryImmutableState.sol
        │   ├── IPeripheryPayments.sol
        │   ├── IPeripheryPaymentsWithFee.sol
        │   ├── IPoolFactoryV3.sol
        │   ├── IQuoter.sol
        │   ├── IQuoterV2.sol
        │   ├── ISelfPermit.sol
        │   ├── ISwapRouter.sol
        │   ├── ITickLens.sol
        │   ├── IV2Pool.sol
        │   └── IV3FactoryRegistry.sol
        ├── lens
        │   ├── CLInterfaceMulticall.sol
        │   ├── Metaquoter.sol
        │   ├── MixedRouteQuoterV1.sol
        │   ├── MixedRouteQuoterV2.sol
        │   ├── MixedRouteQuoterV3.sol
        │   ├── Quoter.sol
        │   ├── QuoterV2.sol
        │   └── TickLens.sol
        ├── libraries
        │   ├── BytesLib.sol
        │   ├── CallbackValidation.sol
        │   ├── ChainId.sol
        │   ├── HexStrings.sol
        │   ├── LiquidityAmounts.sol
        │   ├── MetaquoterLib.sol
        │   ├── NFTDescriptor.sol
        │   ├── NFTSVG.sol
        │   ├── OracleLibrary.sol
        │   ├── Path.sol
        │   ├── PoolAddress.sol
        │   ├── PoolTicksCounter.sol
        │   ├── PositionKey.sol
        │   ├── PositionValue.sol
        │   ├── SqrtPriceMathPartial.sol
        │   ├── TokenRatioSortOrder.sol
        │   └── TransferHelper.sol
        ├── LpMigrator.sol
        ├── NonfungiblePositionManager.sol
        ├── NonfungibleTokenPositionDescriptor.sol
        └── SwapRouter.sol
```



## Protocol overview

MetaDEX03 is a modern evolution of ve(3,3) architecture, building on previous versions of Velodrome and Aerodrome. Familiarity with those codebases, as well as AMMs and voting-escrow systems more generally, will be useful when reviewing it. Many of the same concepts remain, but several have been substantially reworked in MetaDEX03.

At a high level, the system combines AMMs with voting and emissions. Users lock the protocol token to receive voting power, which they use to direct token emissions toward gauges. Liquidity providers earn those emissions, while voters are incentivized through trading fees and external incentives associated with the gauges they vote for. This is only a brief primer, auditors unfamiliar with the underlying model may want to review previous Velodrome and Aerodrome implementations and documentation for additional background.

These are some high-level changes in MetaDEX03 worth introducing before going into the individual components:

- **A new canonical AERO token and migration path.** As before, users can lock this new AERO token to receive voting power. Token holders and locked token positions from previous Velodrome and Aerodrome protocols can migrate into MetaDEX03 for the new token. The migration contracts are in scope of the contest.
- **More dynamic timing and continuous accounting.** Weekly epochs are no longer the core timing mechanism of the system. Votes can be changed on a much more dynamic schedule, and the voting and emissions accounting has been reworked to support this.
- **A multi-chain architecture.** Base will act as the "root" chain and contains the main coordination contracts. Other supported chains will operate as "leaf" chains, with their own local contracts and accounting. Communication between the root and leaf chains is handled through Hyperlane.
- **Several new protocol components.** For example, the Metarouter is a new high-level entrypoint for combining many protocol actions into a single transaction. The new Token Registry provides a system for registering tokens and their relevant metadata. The AMMs also introduce new modular fee and hook infrastructure.

## Supported Blockchains

MetaDEX03 is designed for deployment across multiple EVM chains. **Base, Ethereum mainnet, Arc, and OP Mainnet are confirmed launch chains and should be considered when reviewing the code for chain-specific compatibility issues.** Base serves as the protocol's root chain, while the others operate as leaf chains.

Additional chains will be supported in the future, but the final deployment set has not yet been determined. Researchers are welcome to report chain-specific compatibility concerns outside the confirmed set, although findings that depend on behavior unique to a chain the protocol does not ultimately support may be considered out of scope or have reduced severity.

## Detailed Breakdown

The sections below organize the codebase into its major components.

### AMM Contracts + Fee Modules/Hooks + AMM Periphery

```text
metadex/
└── V3
    └── src
        ├── factories/  (*)
        ├── fees/
        ├── hooks/
        ├── libraries/  (*)
        └── pools/

metadex-slipstream/
└── contracts
    ├── core/
    ├── libraries/
    └── periphery/

(*) = contains files from other groups
```

The codebase currently has two core AMM families:

- The `metadex-public` repo contains the "V2 pools". This includes volatile pools using the `x*y=k` invariant and stable pools using the `x³y+y³x=k` invariant.
- The `metadex-slipstream-public` repo contains the concentrated-liquidity AMM implementation.

Both versions have their associated factory contracts in-scope. The underlying AMM math is largely inherited from previous implementations. However there are some notable changes to the core contracts:

- Stable pools now validate an invariant in `burn()`, this addresses a security concern involving extremely low reserves.
- The contracts have been updated to integrate with MetaDEX03's new gauges.
- Concentrated-liquidity pools now support swap hooks.
- The pool fee system is modular and has several new plug-in components, including: `PriorityFeeMevTaxModule` (adds a MEV-related fee based on transaction priority fees), `DynamicSwapFeeHook` (CL dynamic fees hook, also includes the priority-fee MEV tax), and `DiscountRegistry` (applies fee discounts for eligible addresses).

There are also the familiar AMM periphery contracts, such as the `NonfungiblePositionManager`.

Other contracts in this section are the `PoolTape` contracts and `PoolFactoryIndexation`. The `PoolTape` contracts record historical pool data such as fees, volume, and MEV-related activity. `PoolFactoryIndexation` maintains on-chain indexes of the pools and tokens created by each factory.

### Voting + Emissions + Messaging


```text
metadex/
└── V3
    └── src
        ├── bridge/
        ├── core/
        ├── handlers/
        ├── libraries/  (*)
        ├── minter/
        ├── splitter/
        ├── token/
        ├── voter/
        └── vpm/

(*) = contains files from other groups
```

These are the core contracts containing the new ERC20 tokens, the new `VotingEscrow` contract for locking the token, the root `Voter` and per-chain `LeafVoter` contracts which manage voting allocations and emissions accounting, and the `VoterPaymentsModule` which handles stake rebalancing between positions. There is also the `Minter` which handles token emission rates, the `Splitter` which is the recipient of the team's share of emissions, and the Hyperlane adapter/orchestrator `bridge/` contracts which handle cross-chain messaging.

Some notable details about this section are:

- `VotingEscrow` positions are now referred to as sAERO in the code.
- The old merge, split, and managed-NFT logic has been removed from `VotingEscrow`. The `VoterPaymentsModule` now moves stake between one or more sAERO positions and can charge fees for these operations. The managed-NFT concept is superseded by the new Relay system.
- MetaDEX03 no longer has rebasing emissions distributed to `VotingEscrow` positions. Emissions are only directed to gauges and a team share minted to the `Splitter`. Also note that unallocated emissions accrue as governance-spendable surplus.
- Protocol fees collected by the `VoterPaymentsModule` accumulate in the permanent token ID 0 position.
- Unallocated voting power defaults allocation to `CHAIN0` on the root or `ZERO_GAUGE` on a leaf, which do not result in emissions.
- The root `Voter` keeps track of how much voting power and emissions are allocated to each chain, while each `LeafVoter` handles how that chain's allocation is split between its gauges.
- The root chain (Base) will also have its own leaf contract deployments, but their messaging adapters use direct calls instead of sending cross-chain messages. This is a design choice to make all chains share the same leaf logic and interfaces.
- A notable design choice is that deallocations on leaf chains must first be confirmed back to the root through the `DEALLOC_GAUGE` flow before that voting power can be reused on another chain. This prevents the root from reusing voting power that may still be allocated on a leaf if a cross-chain message fails.
- The `Minter` exposes a token-per-second emission rate rather than a raw weekly emission amount.
- There are two accumulators: `∫ emissionsPerVP(t) dt` and `∫ t * emissionsPerVP(t) dt`. The second is needed to account for changes to `emissionsPerVP` while voting power is decaying. For a decaying segment ending at `T`, the chain's weight at time `t` can be written as `endWeight + slope * (T - t)`. Therefore: `∫ chainAllocationVP(t) * emissionsPerVP(t) dt = endWeight * ∫ emissionsPerVP(t) dt + slope * (T * ∫ emissionsPerVP(t) dt - ∫ t * emissionsPerVP(t) dt)`. In the implementation, `timeIndex` actually stores twice the second integral, `∫ 2t * emissionsPerVP(t) dt`. Since the antiderivative of `2t` is `t²`, each interval can be accumulated as `emissionsPerVP * (tEnd² - tStart²)`, with the factor of two divided out later.

### Gauges

```text
metadex/
└── V3
    └── src
        ├── factories/  (*)
        ├── gauge-creation/
        └── gauges/

metadex-slipstream/
└── contracts
    └── gauge/

(*) = contains files from other groups
```

Gauges are the contracts responsible for distributing emissions to LPs who stake their positions. As in previous implementations, V2-style pools distribute emissions over time to all staked LP tokens, while CL pools distribute emissions based on staked liquidity while a position is within the active liquidity range.

In MetaDEX03, emissions are minted lazily. Most of the accounting tracks how many emissions each chain and gauge is entitled to, while the actual tokens are only minted when a user claims them. On the root chain, claims mint canonical the AERO token, and on leaf chains, claims mint a local `ReceiptToken`, which can be burned on the leaf chain to redeem AERO on the root chain.

### Rewards

```text
metadex/
└── V3
    └── src
        ├── libraries/  (*)
        └── rewards/

(*) = contains files from other groups
```

The rewards contracts allow `VotingEscrow` positions to claim two types of rewards associated with the gauges they voted for: *fees*, which are the LP fees that were forfeited by staked LPs in exchange for emissions, and *incentives* (sometimes referred to as bribes), which are rewards streamed directly to voters to attract voting power.

Rewards are no longer accounted for purely on weekly vote snapshots. The contracts maintain individual voter checkpoints and global checkpoints representing total voting power, including the decay of non-permanent positions. Claims effectively integrate each position's share of total voting power over the time period. To handle linearly decaying voting power, this integral is decomposed into a base accumulator and a time-weighted accumulator, which are then combined with the position's bias and slope. Fees are allocated according to this share as they accrue, while streamed incentives are allocated over the duration of the incentive program.

### Migration

```text
metadex/
└── V3
    └── src
        └── migration/
```

The migration contracts facilitate migrations of AERO and VELO from the previous Aerodrome and Velodrome protocols into the new AERO token. Liquid token holders can migrate directly into new AERO, while active locked positions can migrate into new VotingEscrow positions with approximately the same remaining duration. Permanent positions remain permanent, while expired positions are settled as liquid AERO.

AERO migrates 1:1 into the new AERO token, while VELO migrates at a fixed ratio of 0.055 AERO per VELO. When a locked position is migrated, the old veNFT is merged into a permanent migration veNFT that the migration contract owns in the previous protocol. The migration contracts are funded with fixed amounts of new AERO, and migrations will fail once the budget is exhausted (although additional AERO can be transferred into the contract later).

When a locked position is migrated, its current locked amount is used for conversion and the old veNFT is atomically merged into a permanent migration veNFT owned by the migration contract. Deposits with active votes are rejected, and users are expected to claim any outstanding rewards and rebases before migrating.

The migration also includes a wind-down process for the previous protocols. This includes actions such as setting the old team rate to zero, limiting further emissions, killing gauges, and recovering remaining fees, incentives, and rebases. Fee recovery is more involved because fees in the previous system are only claimable after a delay and killed gauges do not flush fees, so gauges will need to be temporarily revived for voting or distribution before being killed again and rewards claimed later. Once the process is complete, unused migration funds are burned.

### Relay

```text
metadex/
  └── V3
      └── src
          └── relay/
```

The Relay contracts pool staking weight from many sAERO positions into a single Relay-owned sAERO position. Users deposit staking weight into the Relay and receive share tokens representing their position in the pool. The pooled sAERO can then be allocated and managed as one larger position.

Deposits and withdrawals are processed asynchronously through queues. When a user deposits, the weight moves into the Relay's sAERO and is parked on `CHAIN0`, but no shares are minted yet. Pending deposits can then be processed by the Relay keeper, or permissionlessly after a configured delay, at which point the corresponding shares are minted. Withdrawals are processed through a strict FIFO queue once enough weight is available on `CHAIN0` to cover the next request.

A Relay can also be permanently closed, after which new deposits and allocations are disabled and allocated weight can be evacuated back to `CHAIN0` to service outstanding withdrawals. If the next withdrawal in the queue cannot be processed because too much Relay weight remains allocated elsewhere, then after the configured evacuation window anyone can close the Relay, allowing that weight to be pulled back and the withdrawal queue to continue.

Each Relay issues two corresponding ERC20 share tokens: a principal token (`PT`) and a yield token (`YT`). `PT` represents the underlying position accounting, while `YT` is used for reward accounting.

There are two main Relay implemenations. `MaxiRelay` is more permissionless and open to any depositor. `ProtocolRelay` restricts participation through an allowlist and adds controls for removing users and managing the Relay. Protocol Relays have two permission levels, with level 2 providing additional administrative features that are not available at level 1.

### Metarouter

```text
metadex/
└── V3
    └── src
        └── metarouter/
```

The Metarouter is an entrypoint contract for batching multiple protocol actions together. The concept of a router-style entrypoint exists in previous versions of the protocol, but the MetaDEX03 Metarouter supports a much broader set of functionality, including:

- Swaps across V2-style and CL pools
- Adding/removing V2 liquidity and creating/managing CL positions
- Staking and unstaking LP positions in gauges
- Claiming gauge rewards, LP incentives, and pool fees
- Creating sAERO positions and depositing into Relays
- Token and NFT transfers, payments, wrapping/unwrapping, and balance checks
- Bridging assets, redeeming leaf-chain receipt tokens, and executing actions cross-chain
- Executing nested sub-plans within a single batch

### Token Registry

```text
metadex/
└── V3
    └── src
        └── tokenRegistry/
```

The token registry provides a shared on-chain source of token metadata and listing status. Token information is recorded through the `TokenNFT` contract.

Anyone can permissionlessly submit token information by posting the required deposit, but an authorized delegate address must accept the submission before it is recorded, and listing the token is a separate permissioned action.

Within MetaDEX, the registry is used by the permissionless gauge-creation system, where both tokens in a pool must be listed before its gauge can be activated, and by the rewards system, where tokens used to create external incentive programs must be listed.

## Previous Audits

- [**Sherlock Blackthorn "phase 1" review**](reports/BlackthornPhase1.pdf) *(early implementation stage)*
- [**Sherlock Blackthorn "phase 2" review**](reports/BlackthornPhase2.pdf) *(later implementation stage + expanded scope)*
- [**ChainSecurity application layer audit**](reports/ChainSecurityApplicationLayer.pdf) *(AMMs, fees, gauges, rewards)*
- [**ChainSecurity Slipstream application layer audit**](reports/ChainSecurityApplicationLayerSlipstream.pdf) *(CL pools, fee hooks, gauges, periphery, and staking)*
- [**ChainSecurity coordination layer audit**](reports/ChainSecurityCoordinationLayer.pdf) *(voting, emissions, messaging, migration, and tokens)*
- [**Grego AI audit scan**](reports/GregoAIScan.pdf)
- [**Riley Holterhus solo audit**](reports/RileyHolterhusSoloAudit.pdf)

**Note:** Security work with all listed teams is ongoing. We have received permission to publish reports that are still marked as drafts. Some findings may already be resolved even when the published PDF does not record the resolution.

## Known Issues

Note that all issues mentioned in the above audit reports are also considered known issues. The list below is non-exhaustive and highlights some of the more relevant ones.

#### AMM Contracts + Fee Modules/Hooks + AMM Periphery

- The new invariant check in V2 stable pool `burn()` can prevent LPs from withdrawing the final reserves. This is an accepted tradeoff to prevent the pool from reaching a zero-invariant state after initialization. Any amount left behind should only be dust.
- `PriorityFeeMevTaxModule` can revert when `tx.gasprice` is zero in niche situations, such as for OP Stack deposit transactions. Note that this failure would be caught and handled gracefully so swaps still execute but receive no MEV tax.
- `PriorityFeeMevTaxModule` should not be enabled on chains that support non-native fee currencies, such as Celo. In those cases `tx.gasprice` and `block.basefee` can be denominated in different assets, making the MEV-tax calculation invalid.
- The `initialFee` mechanism in `DynamicSwapFeeHook` can be bypassed. For example, a trader can consume it with a small swap, then execute a much larger swap against the same pool later in the same block to avoid the fee (perhaps using a MEV bundle).
- A CL swap hook cannot express a genuine 0% swap fee. If `beforeSwap()` returns zero, `SwapHookLib` treats this as though the hook provided no fee and falls back to the pool's static tick-spacing fee.
- With the default V3 compiler configuration, `CLPool` exceeds the EIP-170 runtime code-size limit by 5,303 bytes and `NonfungiblePositionManager` has only 60 bytes of headroom. Production deployments must use appropriate compiler settings or do further size reductions.

#### Voting + Emissions + Messaging

- Emissions can drift from the actual amount implied by the protocol state. For example, a stake change updates `emissionsPerVP` on root, but untouched leaf chains continue using the old value until a later allocation message arrives, meaning there's a gap that's settled using the stale scalar. Another example is that `emissionsPerVP` should in theory change continuously as decaying voting power reduces its denominator, while in practice it is only updated on protocol interactions. It is expected that normal protocol usage will keep values sufficiently synced, and this can be enforced using a keeper.
- Transferring a `VotingEscrow` position does not clear its existing per-leaf operator assignments. A previous operator can therefore continue managing gauge allocations and claiming leaf rewards until the new owner replaces or clears the operator on each leaf and those messages are delivered. Pending reward-claim messages addressed to the previous owner also remain valid after the transfer. This is partially mitigated by the expiration applied to such messages.
- Suspending and resuming a leaf chain requires careful handling of in-flight cross-chain messages. Governance is expected to follow the procedure documented in the code comments, such as waiting for all outstanding deallocation messages from the leaf to be received before resuming the chain.
- A gauge-allocation message can become permanently undeliverable if the remaining leaf `allocationCooldown` outlasts its root-stamped `maxAllocationAge`.
- Cross-chain ordering can invalidate an in-flight gauge allocation. If a later `AllocateChain` increase reaches the leaf before an earlier gauge allocation, the leaf budget becomes larger than the total frozen into the gauge message. The exact-budget check then reverts.
- If a gauge settlement spans a period where leaf emissions were frozen, such as while the chain was in a suspended state, the frozen seconds still count toward its cap allowance, over-crediting the gauge at the expense of surplus. Operationally settling all gauges during chain state transitions helps mitigate this.

#### Rewards

- Incentive rewards use each position's voting-power share at the end of a checkpoint interval rather than integrating its exact share throughout the interval. This introduces an approximation error as voting power decays, disadvantaging decaying positions because their end-of-interval weight is applied across the entire interval. Fees have a related timing issue: fees are attributed using voting supply when they are flushed into the VRM, which isn't necessarily the exact time they accrued in the underlying pool. This disadvantages decaying locks and can cause zero rewards if a lock expires before the flush.

#### Gauges

- On CL gauges, `depositFor()` allows a caller to assign a position they own to an arbitrary account. A third party can therefore add many dust positions to another user's staked-position set, eventually making the account-wide `earned()` and `claimEmissions()` functions too expensive to execute. The bounded overloads that take explicit token IDs remain usable.

#### Migration

- Migration does not claim outstanding legacy rewards or rebases on the user's behalf. Users are expected to claim them before migrating, as the old veNFT is atomically merged into the migration-owned permanent position.
- For Velodrome migrations from Optimism to Base, cross-chain delivery delays that cross an epoch boundary can extend the migrated position's lock, since its remaining duration is restarted when the message settles on Base.
- Optimism migrations can be initiated even if there is not enough AERO available on Base to settle them, causing the message to revert on Base until the entrypoint is replenished.


#### Relay

- In normal circumstances, withdrawals require both PT and YT. If a holder transfers away their YT, they must reacquire the corresponding amount before they can withdraw, which may be costly or impossible if the YT is no longer recoverable.
- A Relay deposit can mint zero shares if the share price increases enough between the deposit request and when it is processed.
- Protocol Relay allowlists are checked when a deposit is requested but not again when it is processed. A user removed from the allowlist while their deposit is pending can therefore still receive PT and YT.
- For transferable YT, anyone can call a zero-value `transferFrom(holder, holder, 0)` to force the holder's rewards to be settled. This does not change the amount they are owed and only costs the caller gas.
- Relay governance can be pointed at a Governor or vote adapter that ignores or miscounts votes.
- Anyone can extend the lock of a closed Relay that uses a custom lock period. This can extend the lock on sAERO later received by withdrawing users.
- A deposit processed after an allocation but before its rewards are notified will share in that reward batch, even though its shares did not exist when the allocation was made. The keeper can mitigate this by processing rewards before admitting new deposits.
- The Relay creator can set the `bootstrapOwner` to an address where the initial PT/YT pair cannot be recovered, such as the Relay or one of its satellite tokens. This is accepted because the creator also provides the seed and bears the loss.
- If a Relay is closed while deposits are still pending, those deposits are processed into PT only and receive no YT, even if their weight had already contributed to an allocation. Operationally draining the deposit queue before closing the Relay avoids this.
- Transferable YT can be sent to an address where it becomes permanently stuck while still remaining in the reward denominator.
- Changing a Relay's leaf reward recipient is delayed but not prevented by the timelock. The delay only gives holders time to claim outstanding rewards or queue an exit; only the Relay owner can cancel the pending change.

#### Metarouter

- CL swaps through the Metarouter do not support a caller-supplied `sqrtPriceLimitX96`, the router always uses the extreme price boundary.

#### Misc

- **Arc Blockchain Compatibility:**
    - `VotingRewardsFactory` rejects `wrappedNative == address(0)`, preventing the no-wrapper mode supported by `VotingRewardsManager`. On Arc, configuring USDC as the wrapper instead causes USDC claims to call the unsupported `withdraw()` function and revert.
    - Slipstream's `refundETH()` is incompatible with Arc's native/ERC-20 USDC duality because ERC-20 USDC transfers also increase the contract's native balance. This can cause unrelated USDC to be refunded, transfers to nonpayable recipients to revert, or router custody flows to break.
