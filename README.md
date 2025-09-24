# Metadex

Smart contracts for [Metadex](https://aero.xyz): AMM pools, voting escrow, gauges, rewards, cross-chain messaging, Metarouter, and Relay.

Concentrated-liquidity contracts live in [`metadex-slipstream-public`](https://github.com/dromos-labs/metadex-slipstream-public).

Solidity `0.8.36`, Prague EVM. Source is under `V3/src`.

## Setup

1. Install [Foundry](https://github.com/foundry-rs/foundry#installation).
2. Copy `.env.example` to `.env` and set RPC / explorer variables as needed.
3. `yarn install`

For NatSpec and bulloak lint scripts, also install:

```bash
cargo install lintspec
cargo install bulloak
```

If Foundry commands fail after install, run `foundryup` and retry.

## Build

```bash
yarn build
```

Optimized (via IR):

```bash
yarn build:optimized
```

## Lint

```bash
yarn lint:check
yarn lint:fix
yarn lint:natspec
```

## Deploy

Deployment addresses are in `deployment-addresses/`.

## Audits

Prior reports are under [`audits/reports`](audits/reports). `audit.md` records accepted known behaviors.

## Licensing

This project follows the [Apache Foundation](https://infra.apache.org/licensing-howto.html) guideline for licensing. See `LICENSE` and `NOTICE`. Each source file declares its governing license in an `SPDX-License-Identifier` header; the header controls for that file.

New protocol files use the Dromos Restricted Use License 1.0 (`LicenseRef-Dromos-Restricted-Use-1.0`). That license does not allow production use. Each version converts to GPL-2.0-or-later five years after its first public distribution; see `VERSIONS`. Interfaces are MIT unless they inherit GPL. Inherited files keep their original license (`LICENSE.MIT`, `LICENSE.GPL3`).
