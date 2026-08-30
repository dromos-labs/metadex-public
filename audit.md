# Notes for auditors

This file documents behaviors we have reviewed and accepted as known and out of scope. Its purpose is to give auditors additional context and prevent these known behaviors from being reported as vulnerabilities.

## StablePool final burn can revert with `KIsZero`

`StablePool.burn` runs a post-burn check (`_kThresholdValidation`) that reverts with `KIsZero` when the remaining reserves make the cubic invariant `_k` round down to zero. The guard exists because a pool left at `_k == 0` is exploitable. The swap check only requires that `_k` does not decrease, so assets can be drained for free.

As a side effect, the last liquidity provider cannot withdraw all the way down to the locked `MINIMUM_LIQUIDITY` dust in a single burn. Once the residual reserves fall below the level where `_k > 0`, the burn reverts.

We consider this acceptable because no value is at risk and the workaround is straightforward. If a final LP withdrawal would reduce `_k` to zero, anyone can first deposit a small dust amount to keep the post-burn `_k` above zero, allowing the burn to succeed.

## MEV tax module is unsupported on chains with fee currencies

Celo CIP-64 transactions pay gas in a fee currency chosen by the sender. For those transactions `tx.gasprice` is denominated in that fee currency while `block.basefee` remains denominated in the native token, so the subtraction in `getMevTax` mixes units during the calculations, that return an invalid mev tax. The fee currency of the transaction is not exposed to contracts, so no accurate conversion is possible on chain.

The module must not be enabled on Celo or any chain with fee currency support until the chain exposes a priority fee signal that accounts for the fee currency. With the module unset the factory returns the base fee only, matching the documented behavior for chains without priority fee ordering.

## A Relay deposit repriced at admission can floor to zero shares

`QueueLib.registerDeposit` rejects a request that would mint zero shares at the price of that moment. Admission happens later, and the drain prices the entry again against the backing and supply it finds then. If the price per share grew in between, through a compound or a recognized donation, the same entry can floor to zero shares. The drain still pops it and still adds its weight to the backing, so the deposit becomes a donation to the current holders.

We keep this behavior. The deposit queue is shared, so the drain must never revert on one entry: a revert would pin the FIFO head and block every entry behind it. Refunding inside the drain would move value from the same call, which brings the same wedge risk back through a failing refund.

The trigger needs the price per share to grow above the entire net deposit between request and admission, so with the production dust floor (`minDeposit` at or above `1e18`) it takes an extreme change in the backing. The behavior is pinned by `V3/test/unit/relay/libraries/QueueLib/processDeposits/processDeposits.t.sol::test_WhenThePricingFloorsToZeroShares`.

The milder case, where the repricing mints a nonzero amount that lands under `minWithdrawal`, is not accepted: the exit floor is `min(free position, minWithdrawal)`, so a holder can always queue their whole free position whatever it prices at.

## The Relay allow list is not re-checked when a deposit is admitted

On the Protocol tiers `requestDeposit` checks that the share recipient is on the allow list. The drain that admits the entry does not check it again, so a recipient removed while its deposit waits still receives its PT/YT pair.

We keep this behavior for the same reason as above: the drain must not revert on a single entry. The minted position is contained anyway. The Protocol tier's yield token is soulbound and the principal token never moves holder to holder, so a de-listed holder can only exit, and `kick` lets ADMIN settle its rewards and send its whole free position to the withdraw queue. The behavior is pinned by `V3/test/unit/relay/RelayProtocol.t.sol::test_WhenTheAllowListIsRemovedBeforeProcessing`.

## A zero-value self-transfer of a transferable yield token forces a reward settle

`RelayToken` fires the Relay's transfer hook on every move, and the hook settles the sender's and the recipient's rewards. When the yield token is transferable, anyone can call `transferFrom(holder, holder, 0)` and force that settle for a holder who did not ask for it.

This changes nothing about what is owed. A settle only moves a holder's accrued amount from the index into `pendingReward`, and the caller pays the gas. The soulbound tiers cannot reach the path at all.

## Governor rotation can misdirect Relay votes, never its custody

`setGovernor` is ADMIN gated and takes any nonzero Governor with any adapter. The Relay sends the adapter's bytes to that Governor from its own context, and the Relay owns the pooled sAERO and is the only minter of its satellite clones. The cast therefore pins the selector of those bytes to the fractional cast, so a rotation cannot make the Relay call anything else as itself.

What remains is a vote-quality risk: an ADMIN can point the Relay at a Governor that ignores or miscounts the casts. That is the same trust the role already carries for the allocation intent, and no depositor funds move. The pin has a cost worth stating: the Relay only speaks the `castVoteWithReasonAndParams` dialect, so a Governor with a different cast signature needs a change in `RelayGovernanceLib`, not only a new adapter.

## Anyone can refresh the lock of a closed custom-period Relay

`extendLock` is permissionless and stays that way after the closure. On a custom-period Relay (`lockWeeks != 0`) `AllocationLib.extendLock` recomputes its target from the current week, so a caller can push the unlock one week further every week. The escrow enforces the monotonic-unlock rule in `rebalanceUnderlying`, and a minted destination inherits the source unlock, so exits settled afterwards carry the Relay's unlock: the holder either receives a fresh sAERO locked to that horizon or, when the named destination falls short, loses the named destination and gets the fresh one.

We keep this behavior. A closed Relay still holds weight allocated to gauges and chains until each one is evacuated, and that weight keeps earning while it stands. An expired stake has no voting power, so letting the lock lapse would cut the reward tail for the holders who have not exited yet; the refresh is what keeps it alive through the wind-down.

Nothing about the accounting changes and no funds move: the backing, the share supply and the reward accumulator are untouched, and an exiting holder still receives their full weight. The cost falls on that holder as a longer unlock on the sAERO they receive, which is the same lock they were exposed to while holding the position. A lapsed lock is also not a dead end: `increaseStakingPeriod` accepts an expired stake (it extends from the later of the current end and now) and `rebalanceUnderlying` carries no expiry guard, so exits drain either way.

## A deposit admitted between an allocation and its reward batch shares in that batch

`notifyReward` prices its index bump against the live yield-token supply, and the rewards an allocation earns land later, in a call of their own. A deposit admitted in between mints a pair that enlarges that supply, so it takes a slice of a batch it did not vote for.

The index accounting still protects every batch already notified. The mint settles the new holder against a zero balance and checkpoints it at the current index, so it can never reach rewards that landed before it. Only the batch still on its way is shared.

We keep this behavior. The drain carried an allocation cutoff before, which admitted an entry only after an allocation that followed its request. That cutoff also gated `processOverduePending`, the permissionless drain that stops a keeper from withholding share creation: while allocations are stopped the cutoff admits nothing, so the fallback does nothing exactly when it is needed. The weight is already inside the Relay's sAERO from the request, so those depositors would hold no shares against weight the Relay keeps voting with, and no permissionless way out. That failure is permanent, while the shared batch costs one cycle of yield.

The keeper controls the ordering that avoids it: run the entrypoints first, so the standing holders capture the batch, then drain the deposits, so the fresh pairs mint at the settled ratio. `keeperWindow` sets how long an entry waits before anyone can admit it, so a window at or above the allocation cadence keeps the permissionless path out of the batch too.

## A bootstrap owner the creator cannot recover is accepted

`initialize` refuses a zero `bootstrapOwner` and checks nothing else, so the seed pair can be minted to the Relay itself or to either satellite clone, where it can never move again. The deposit path refuses those same three recipients.

We keep the asymmetry. A guard earns its bytecode when the party that makes the mistake is not the party that pays for it. `bootstrapOwner` is named by the creator, in the same call that names every other parameter, and the creator holds the seed, so the loss falls on whoever made the error. A deposit names a recipient that can be somebody else, so there the two parties come apart and the ban stays.

The check belongs in the deployment script, which reads the same parameters before it sends them.

## A closed drain mints the principal alone, whatever the entry already earned

A drain on a closed Relay mints the principal token and no yield token. The rule carries no exception, so it also covers an entry whose weight a real allocation already moved: if the keeper leaves that entry pending across `close`, it mints the principal alone, and the rewards that allocation earns later go entirely to the holders who already held the yield side.

We keep this behavior. Nothing about the principal changes. The holder receives shares for its full weight and keeps the whole withdraw right, and the exit floor is `min(free position, minWithdrawal)`, so it can always queue everything it holds. What moves is the yield tail, and it stays with the holders who were in the reward denominator while that weight was allocated.

The exact alternative is to keep the last allocation timestamp at closure and split the queue against it, so an entry an allocation already covered still mints the pair. We reject it. That cutoff is the state the deposit drain used to carry, and removing it is what closed two earlier findings: a drain with a cutoff can stop on an entry that sits on the wrong side of a timestamp comparison, and the permissionless drain admits nothing at all once allocations stop. Buying back a yield redistribution at that price is the wrong trade.

The operational rule that removes the case in practice: drain the deposit queue before calling `close`. A queue drained first holds no pending entry to reprice, so no holder reaches the closed branch with allocated weight behind it.

## Yield tokens sent to the Relay or to a satellite stay in the reward denominator

A holder-initiated transfer of a transferable yield token refuses the zero address and nothing else. It can name the Relay, either satellite clone, or any other address the sender does not control. The tokens are unreachable from there: a satellite cannot move a balance it holds, and a claim pays `msg.sender`, so the Relay can never claim as a holder either. Only the Maxi tier reaches this, because the Protocol tiers refuse a transferable yield token at initialization.

We keep it. The sender both errs and pays, the same criterion the bootstrap owner follows above, and a ban could only ever name three addresses out of the whole space: the identical loss follows a transfer to any other address without a key. The mint path is a different case and keeps its ban, because a deposit names a recipient that can be somebody else.

One part is not only self-harm. That balance stays inside the yield-token supply `notifyReward` divides by, so every later batch routes a slice to an address that never claims, and the slice sits in its pending reward forever. It shrinks what the live holders receive, and it shrinks the un-accounted headroom that the Relay's own pull, sweep and compound paths are bounded by.

The circular case is closed rather than accepted: the reward registry refuses the Relay together with its own principal and yield tokens, so a Relay cannot distribute its own shares as a reward.

## The leaf recipient delay is a window, not a wall

Re-pointing the recipient a chain's reward claim lands at runs through `proposeLeafRecipient` and `executeLeafRecipient`, separated by `entrypointTimelock`. An ADMIN that waits the delay out still moves reward custody. The delay does not stop that, and it is not meant to.

It buys three things instead. `LeafRecipientProposed` announces the move together with the timestamp it becomes executable. `claimRewards` carries no role, so during the window anyone can claim the outstanding accrual to the custody that stands today. And a holder that does not accept the new custody has the window to queue an exit. `clearLeafRecipient` is immediate and also cancels a pending proposal, so a proposal made in error costs nothing to withdraw.

This is the same shape as the Governor rotation above: the role keeps a power that the delay makes visible and answerable, rather than one the code takes away.
