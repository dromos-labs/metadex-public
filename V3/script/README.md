# Deploy scripts

Scripts are grouped by deployment _unit_. Each unit has an abstract fixture holding the deploy logic together with one parameters class per chain. Deployed addresses are written to `deployment-addresses/`.

Current units:

- `V3/script/DeployPoolsFixture.s.sol` (`Pools`) deploys the pool implementations, factories, pool tape, discount registry and fee modules. Its chain classes live in `V3/script/deployParameters/<chain>/DeployPools.s.sol`.
- `V3/script/DeployRelayStackFixture.s.sol` (`RelayStack`) deploys both satellite-token implementations, the vote adapter, one implementation per tier and the `RelayFactory`. Root only; entrypoints are their own unit. Its chain class lives in `V3/script/deployParameters/base/DeployRelayStack.s.sol`.

## Unit order

Units are independent broadcasts, but each one reads the previous ones' output. The grants sit between the steps because each one unblocks the step that follows.

| Step | Unit or action | Why here |
| --- | --- | --- |
| 1 | Core (`Token`, `VotingEscrow`, `Voter`, `Minter`, `Splitter`, `VeArtProxy`, `VoterPaymentsModule`) | Everything below reads its addresses |
| 2 | `VotingEscrow.grantRole(VPM_ROLE, <module>)` | The escrow refuses weight moves from an unauthorized module, so without it no Relay ever takes a deposit |
| 3 | `FactoryRegistry`, then `registerMetaRouter` for each approved router | Every entrypoint swap checks the router against it |
| 4 | `Pools` | Independent of the relay; ordered here only because the router the entrypoints use routes through them |
| 5 | `RelayStack` | Needs step 1's addresses in its parameters |
| 6 | `Voter.grantRole(RELAY_DEPLOYER_ROLE, <deployer>)` | The factory reads it off the Voter; without it no Relay can be created |
| 7 | Entrypoints, per strategy | Take the step 3 registry; which ones a Relay gets is named when that Relay is created |

The core unit has no script on `V3` yet, so the relay unit's parameters stay at their placeholders until it lands.

## 1. Environment setup

Copy `.env.example` into a new `.env` and set the RPC URL plus the Etherscan pair for the target chain:

```
BASE_RPC_URL=...
BASE_ETHERSCAN_API_KEY=...
BASE_ETHERSCAN_VERIFIER_URL=...
```

The Etherscan variables are needed for contract verification. Variable names match the values in the `[etherscan]` section of `foundry.toml`.

## 2. Chain parameters

Fill in the parameters class of the target chain and unit at `V3/script/deployParameters/<chain>/Deploy<Unit>.s.sol`. Placeholders are zero on purpose and the script reverts with `InvalidInput` until every value is set. The `chainId` field guards against deploying one chain's parameters to another.

## 3. Validate the configuration

Run the suite, then simulate the deployment for the target chain. The simulation runs the real script with the chain parameters against a fork of that chain:

```
yarn test
./V3/script/deploy.sh <chain> <unit>
```

Without a verifier type the deploy script only simulates. Deploy only once both are green.

## 4. Deploy

```
./V3/script/deploy.sh <chain> <unit> [verifier-type] [additional-args]
```

The chain name matches both the `deployParameters` directory and the rpc alias in `foundry.toml` (`base`, `optimism`, `ethereum`); the unit matches the parameters class name (`Pools`, `RelayStack`). A unit is resolved by path, so adding a chain class is all it takes for `deploy.sh` to know a unit. Without a verifier type the script only simulates. With `etherscan` or `blockscout` it simulates first, then broadcasts with verification enabled. Pass signing flags through the additional args, such as `"--account deployer"` for an encrypted keystore imported via `cast wallet import` or `"--ledger"` for a hardware wallet. The signer must be the `DEPLOYER` address from `script/Constants.sol`, since the CREATE3 addresses derive from it. The same deployer and entropy values produce the same addresses on every chain.

Deployed addresses are written to `deployment-addresses/` under the `outputFilename` set in the parameters class.

## 5. Verify pending contracts

If any contract misses verification during the deploy, run the following to verify any pending contract:

```
./V3/script/verify.sh <chain> <unit> [verifier-type]
```

Addresses are read from the deployment output JSON and constructor args are recovered from each creation transaction.

## 6. Grant the roles the deployed unit needs

A deploy leaves some contracts inert until governance hands out roles. Nothing checks them at deploy time: a missing grant reverts the first time somebody uses the unit.

### Relay stack

| Step | Call | Held by | Unblocks |
| --- | --- | --- | --- |
| 1 | `Voter.grantRole(RELAY_DEPLOYER_ROLE, <relay deployer>)` | `CONFIG_ADMIN_ROLE` on the Voter | Creating Relays through the factory |
| 2 | `Voter.grantRole(FACTORY_REGISTRY_ADMIN_ROLE, <registry admin>)` | `CONFIG_ADMIN_ROLE` on the Voter | Registering routers |
| 3 | `FactoryRegistry.registerMetaRouter(<meta router>)` | `FACTORY_REGISTRY_ADMIN_ROLE` | Entrypoint swaps (a second router is the recovery path) |
| 4 | `VotingEscrow.grantRole(VPM_ROLE, <payments module>)` | `VPM_ADMIN_ROLE` on the VotingEscrow | Deposits and withdrawals (an authorized spare is the recovery path) |

The `FactoryRegistry` has no deployment unit yet; an instance serving the relay entrypoints on root passes the root `Voter` as its `LEAF_VOTER` authority.
